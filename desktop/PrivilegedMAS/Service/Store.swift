import Foundation
import Darwin
import Security
import SystemConfiguration
import CryptoKit

// All ancestors are opened separately without following links. The deployment
// directory and all children stay private to root; no caller-supplied paths.
final class Store {
    let fd: Int32
    init(create: Bool = true) throws {
        var current = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        try require(current >= 0)
        do {
            for component in ["Library", "Application Support", "MacseedMAS"] {
                if component == "MacseedMAS" && create {
                    if mkdirat(current, component, 0o700) != 0 { try require(errno == EEXIST) }
                }
                let next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                try require(next >= 0)
                close(current); current = next
                var info = stat(); try require(fstat(current, &info) == 0)
                try require(info.st_uid == 0 && info.st_mode & 0o022 == 0)
                // Mode bits do not describe extended ACL grants.
                try requireNoACL(current)
                if component == "MacseedMAS" { try require(info.st_mode & 0o077 == 0) }
            }
            fd = current
        } catch { close(current); throw error }
    }
    deinit { close(fd) }
    var journalFile: JournalFile { JournalFile(fd) }
    func installed() throws -> String {
        let input = openat(fd, Contract.executableName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        try require(input >= 0)
        defer { close(input) }
        var info = stat(); try require(fstat(input, &info) == 0)
        try require(info.st_uid == 0 && info.st_mode & S_IFMT == S_IFREG && info.st_mode & 0o777 == 0o500 && info.st_nlink == 1)
        try requireNoACL(input)
        let path = Contract.directory + "/" + Contract.executableName
        try checkCode(path)
        return path
    }
    func deploy() throws {
        // Immutable digest-addressed generations. Existing generations are never
        // overwritten; shared ownership journal survives updates/rollback.
        var existing = stat()
        if fstatat(fd, Contract.executableName, &existing, AT_SYMLINK_NOFOLLOW) == 0 { _ = try installed(); return }
        try require(errno == ENOENT)
        try protectedApp()
        let input = open(Contract.source, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        try require(input >= 0)
        defer { close(input) }
        var info = stat(); try require(fstat(input, &info) == 0)
        try require(info.st_mode & S_IFMT == S_IFREG && info.st_size > 0 && info.st_size < 32 * 1024 * 1024)
        let name = ".staging-" + UUID().uuidString
        let output = openat(fd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o500)
        try require(output >= 0)
        defer { close(output); unlinkat(fd, name, 0) }
        let source = FileHandle(fileDescriptor: input, closeOnDealloc: false)
        let target = FileHandle(fileDescriptor: output, closeOnDealloc: false)
        var total = 0
        while let bytes = try source.read(upToCount: 65536), !bytes.isEmpty {
            total += bytes.count; try require(total <= 32 * 1024 * 1024)
            try target.write(contentsOf: bytes)
        }
        try require(fsync(output) == 0)
        try checkCode(Contract.directory + "/" + name)
        try require(renameatx_np(fd, name, fd, Contract.executableName, UInt32(RENAME_EXCL)) == 0 && fsync(fd) == 0)
        _ = try installed()
    }
}

final class Session {
    let lock = NSLock()
    var lost = false
    let uid: uid_t
    let gid: gid_t
    let asid: au_asid_t
    let isDesktop: Bool
    init(_ connection: NSXPCConnection) {
        isDesktop = Self.desktop(connection)
        uid = connection.effectiveUserIdentifier; gid = connection.effectiveGroupIdentifier
        asid = connection.auditSessionIdentifier
    }
    private static func desktop(_ connection: NSXPCConnection) -> Bool {
        var code: SecCode?; var requirement: SecRequirement?
        let attributes = [kSecGuestAttributePid: NSNumber(value: connection.processIdentifier)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
              SecRequirementCreateWithString(Contract.requirement(Contract.app) as CFString, [], &requirement) == errSecSuccess else { return false }
        return SecCodeCheckValidity(code!, [], requirement) == errSecSuccess
    }
    var caller: Caller { Caller(uid: uid, gid: gid, auditSession: UInt32(asid)) }
    func disconnect() { lock.lock(); lost = true; lock.unlock() }
    func valid() -> Bool {
        var console: uid_t = 0
        _ = SCDynamicStoreCopyConsoleUser(nil, &console, nil)
        var session = SecuritySessionId(asid)
        var attributes: SessionAttributeBits = []
        let graphic = SessionGetInfo(session, &session, &attributes) == errSecSuccess && attributes.contains(.sessionHasGraphicAccess)
        return Contract.admission("version", uid: uid, console: console, graphical: graphic)
    }
}

