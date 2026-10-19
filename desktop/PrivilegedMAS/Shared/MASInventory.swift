import Foundation
import CoreFoundation
import Security
import Darwin

struct InstallationEvidence: Codable, Equatable {
    var inventory = "unverified"
    var bundle = "unverified"
    var signature = "unverified"
    var receipt = "unverified"
    var completeness = "unverified"
    var appleServices = "not_observable"
    var result = "unverified"
}

enum MASInventory {
    static func rows(_ bytes: Data) throws -> [[String: Any]] {
        var result = [[String: Any]]()
        for line in bytes.split(separator: 10) where !line.isEmpty {
            let value = try JSONSerialization.jsonObject(with: Data(line))
            guard let rows = (value as? [[String: Any]]) ?? (value as? [String: Any]).map({ [$0] }) else { throw Failure.refused }
            for row in rows {
                guard let number = row["adamID"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), Contract.validID(number.stringValue) else { throw Failure.refused }
            }
            result += rows
        }
        return result
    }
    static func contains(_ bytes: Data, id: String) throws -> Bool {
        try rows(bytes).contains { ($0["adamID"] as? NSNumber)?.stringValue == id }
    }
    static func verify(_ bytes: Data, id: String) throws {
        let matches = try rows(bytes).filter { ($0["adamID"] as? NSNumber)?.stringValue == id }
        try require(matches.count == 1)
        var evidence = InstallationEvidence()
        try verifyBundle(matches[0], evidence: &evidence)
    }
    static func inspect(_ bytes: Data, id: String, home: String) throws -> InstallationEvidence {
        var evidence = InstallationEvidence()
        let matches = try rows(bytes).filter { ($0["adamID"] as? NSNumber)?.stringValue == id }
        evidence.inventory = matches.isEmpty ? "not_found" : matches.count == 1 ? "present" : "duplicate"
        // Direct filesystem inspection complements Spotlight-backed MAS inventory.
        // It cannot prove Apple's private queues are idle. Partial downloads block.
        for path in ["/Applications", home + "/Applications"] {
            var directory = stat(); errno = 0
            if lstat(path, &directory) != 0 {
                try require(errno == ENOENT && path != "/Applications")
                continue
            }
            try require(directory.st_mode & S_IFMT == S_IFDIR && URL(fileURLWithPath: path).resolvingSymlinksInPath().path == path)
            var failed = false; var count = 0
            guard let walker = FileManager.default.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.isSymbolicLinkKey],
                options: [.skipsPackageDescendants], errorHandler: { _, _ in failed = true; return false }) else { return evidence }
            for case let url as URL in walker {
                count += 1; if count > 10000 { failed = true; break }
                if ["appdownload", "download"].contains(url.pathExtension) {
                    evidence.appleServices = "possible_active_download"; return evidence
                }
                if (try url.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink == true { walker.skipDescendants() }
            }
            if failed { return evidence }
        }
        evidence.completeness = "inventory_and_application_directories_observed_private_queue_unavailable"
        if matches.isEmpty { evidence.bundle = "target_not_identified"; evidence.result = "absent_in_observed_scope"; return evidence }
        guard matches.count == 1 else { return evidence }
        do {
            try verifyBundle(matches[0], evidence: &evidence)
            evidence.result = "verified_present"
        } catch { evidence.completeness = "verification_incomplete_or_changed" }
        return evidence
    }
    private static func regular(_ path: String) throws -> Data {
        try require(URL(fileURLWithPath: path).resolvingSymlinksInPath().path == path)
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC); try require(fd >= 0); defer { close(fd) }
        var before = stat(); try require(fstat(fd, &before) == 0 && before.st_mode & S_IFMT == S_IFREG && before.st_size > 0 && before.st_size <= 4 * 1024 * 1024)
        let bytes = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).readToEnd() ?? Data()
        var after = stat(); try require(fstat(fd, &after) == 0 && before.st_size == after.st_size && before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec && before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec)
        return bytes
    }
    private static func verifyBundle(_ row: [String: Any], evidence: inout InstallationEvidence) throws {
        guard let path = row["path"] as? String, path.hasSuffix(".app"),
              let bundleID = row["bundleID"] as? String, !bundleID.isEmpty,
              let version = row["version"] as? String, !version.isEmpty else { throw Failure.refused }
        let url = URL(fileURLWithPath: path)
        try require(url.standardizedFileURL.path == path && url.resolvingSymlinksInPath().path == path)
        var before = stat(); try require(lstat(path, &before) == 0 && before.st_mode & S_IFMT == S_IFDIR)
        let infoBytes = try regular(path + "/Contents/Info.plist")
        guard let info = try PropertyListSerialization.propertyList(from: infoBytes, format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == bundleID, info["CFBundleShortVersionString"] as? String == version else { throw Failure.refused }
        evidence.bundle = "identifier_version_match"
        var code: SecStaticCode?; var requirement: SecRequirement?
        try require(SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess)
        try require(SecRequirementCreateWithString("anchor apple generic" as CFString, [], &requirement) == errSecSuccess)
        try require(SecStaticCodeCheckValidity(code!, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures), requirement) == errSecSuccess)
        var signing: CFDictionary?
        try require(SecCodeCopySigningInformation(code!, SecCSFlags(rawValue: kSecCSSigningInformation), &signing) == errSecSuccess)
        try require((signing as? [String: Any])?[kSecCodeInfoIdentifier as String] as? String == bundleID)
        evidence.signature = "valid_apple_anchored_code"
        evidence.receipt = "unavailable"
        let receipt = try regular(path + "/Contents/_MASReceipt/receipt")
        evidence.receipt = "present_not_authenticated"
        try ReceiptVerification.verify(receipt, bundleID: bundleID, version: version)
        evidence.receipt = "cms_apple_receipt_policy_identifier_version_match_device_binding_not_checked"
        var after = stat(); try require(lstat(path, &after) == 0 && before.st_ino == after.st_ino && before.st_dev == after.st_dev)
        try require(regular(path + "/Contents/Info.plist") == infoBytes && regular(path + "/Contents/_MASReceipt/receipt") == receipt)
    }
}

// Bounded DER parsing of the signed receipt's identity/version/creation date.
// No entitlement/account assertion and no receipt/device hash claim.
enum ReceiptVerification {
    struct DER {
        var bytes: [UInt8]; var offset = 0
        mutating func value(_ tag: UInt8) throws -> [UInt8] {
            try require(offset + 2 <= bytes.count && bytes[offset] == tag); offset += 1
            var length = Int(bytes[offset]); offset += 1
            if length & 0x80 != 0 {
                let width = length & 0x7f; try require(width > 0 && width <= 4 && offset + width <= bytes.count)
                length = 0
                for _ in 0..<width { length = length * 256 + Int(bytes[offset]); offset += 1 }
            }
            try require(length <= bytes.count - offset)
            let result = Array(bytes[offset..<(offset + length)]); offset += length; return result
        }
        mutating func integer() throws -> Int {
            let value = try value(0x02); try require(!value.isEmpty && value.count <= 4 && value[0] < 128)
            return value.reduce(0) { $0 * 256 + Int($1) }
        }
    }
    static func attributes(_ bytes: Data) throws -> [Int: String] {
        var outer = DER(bytes: Array(bytes)); var set = try DER(bytes: outer.value(0x31))
        try require(outer.offset == outer.bytes.count)
        var result = [Int: String](); var count = 0
        while set.offset < set.bytes.count {
            count += 1; try require(count <= 4096)
            var attribute = try DER(bytes: set.value(0x30))
            let type = try attribute.integer(); _ = try attribute.integer()
            var content = try DER(bytes: attribute.value(0x04)); try require(attribute.offset == attribute.bytes.count)
            if [2, 3, 12].contains(type) {
                try require(result[type] == nil)
                let value = try content.value(type == 12 ? 0x16 : 0x0c)
                try require(content.offset == content.bytes.count)
                guard let string = String(bytes: value, encoding: .utf8), !string.isEmpty else { throw Failure.refused }
                result[type] = string
            }
        }
        return result
    }
    static func verify(_ bytes: Data, bundleID: String, version: String) throws {
        try require(!bytes.isEmpty)
        var decoder: CMSDecoder?; try require(CMSDecoderCreate(&decoder) == errSecSuccess)
        try require(bytes.withUnsafeBytes { CMSDecoderUpdateMessage(decoder!, $0.baseAddress!, $0.count) } == errSecSuccess)
        try require(CMSDecoderFinalizeMessage(decoder!) == errSecSuccess)
        var count = 0; try require(CMSDecoderGetNumSigners(decoder!, &count) == errSecSuccess && count == 1)
        var content: CFData?; try require(CMSDecoderCopyContent(decoder!, &content) == errSecSuccess)
        guard let content else { throw Failure.refused }
        let fields = try attributes(content as Data)
        try require(fields[2] == bundleID && fields[3] == version)
        guard let date = fields[12].flatMap({ ISO8601DateFormatter().date(from: $0) }), date <= Date(),
              let policy = SecPolicyCreateWithProperties(kSecPolicyMacAppStoreReceipt, nil) else { throw Failure.refused }
        var status = CMSSignerStatus(rawValue: 0)!; var trust: SecTrust?
        try require(CMSDecoderCopySignerStatus(decoder!, 0, policy, false, &status, &trust, nil) == errSecSuccess && status == .valid)
        guard let trust else { throw Failure.refused }
        try require(SecTrustSetVerifyDate(trust, date as CFDate) == errSecSuccess)
        try require(SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess)
        try require(SecTrustEvaluateWithError(trust, nil))
    }
}
