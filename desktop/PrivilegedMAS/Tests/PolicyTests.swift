import Foundation
import Darwin
import Security

@main enum Tests {
    static func rejected(_ body: () throws -> Void) {
        do { try body(); preconditionFailure("unsafe input accepted") } catch {}
    }
    static func signed(_ path: String, identifier: String) -> Bool {
        var code: SecStaticCode?; var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess,
              SecRequirementCreateWithString(Contract.requirement(identifier) as CFString, [], &requirement) == errSecSuccess else { return false }
        return SecStaticCodeCheckValidity(code!, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures), requirement) == errSecSuccess
    }
    static func main() throws {
        precondition(geteuid() != 0 && CommandLine.arguments.count == 2)
        let app = CommandLine.arguments[1]
        for id in ["1", "425264550", "1024640650", "999999999"] { precondition(Contract.permitsInstallID(id)) }
        for id in ["0", "-1", "01", "1;id", "１", "18446744073709551616", ""] { precondition(!Contract.permitsInstallID(id)) }
        precondition(signed(app, identifier: Contract.app))
        precondition(signed(app + "/Contents/Helpers/MASClient", identifier: Contract.app + ".mas-client"))
        precondition(!signed("/bin/echo", identifier: Contract.app))
        precondition(!signed(app + "/Contents/Helpers/MASHelper", identifier: Contract.app + ".mas-client"))
        precondition(!Contract.admission("version", uid: 501, console: 502, graphical: true))
        precondition(!Contract.admission("version", uid: 501, console: 501, graphical: false))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: dir) }
        let adhoc = dir.appendingPathComponent("adhoc-client")
        try FileManager.default.copyItem(atPath: app + "/Contents/Helpers/MASClient", toPath: adhoc.path)
        let signer = Process(); signer.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        signer.arguments = ["--force", "--sign", "-", adhoc.path]
        signer.standardOutput = FileHandle.nullDevice; signer.standardError = FileHandle.nullDevice
        try signer.run(); signer.waitUntilExit(); precondition(signer.terminationStatus == 0)
        precondition(!signed(adhoc.path, identifier: Contract.app + ".mas-client"))
        let fd = open(dir.path, O_RDONLY | O_DIRECTORY); precondition(fd >= 0); defer { close(fd) }
        let file = JournalFile(fd, owner: geteuid()); let boot = try Child.bootIdentity()
        try file.withExclusiveLock {
            rejected { try file.withExclusiveLock {} }
            for id in ["425264550", "1024640650"] {
                var journal = try file.load()!; try journal.begin("install", id: id, caller: Caller(uid: getuid(), gid: getgid(), auditSession: 1))
                journal.operations[journal.operations.count - 1].ownership = OperationOwnership(bootIdentity: boot)
                journal.transition("completed", reason: "fixture_already_present_no_mutation"); try file.save(journal)
            }
            var journal = try file.load()!; precondition(journal.operations.count == 2)
            precondition(OwnedAdmission.reason(journal, boot: boot) == nil)
            try journal.begin("install", id: "999999999", caller: Caller(uid: getuid(), gid: getgid(), auditSession: 1))
            journal.operations[journal.operations.count - 1].ownership = OperationOwnership(bootIdentity: boot)
            journal.transition("launching", reason: "fixture_launch_intent"); try file.save(journal)
            journal.transition("unknown", reason: "fixture_disconnect"); try file.save(journal)
            let persisted = try file.load()!; precondition(OwnedAdmission.reason(persisted, boot: boot) == "unknown_no_retry")
            rejected { var retry = persisted; try retry.begin("install", id: "2", caller: Caller(uid: getuid(), gid: getgid(), auditSession: 1)) }
        }
        let bundle = dir.appendingPathComponent("Fixture.app")
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents/_MASReceipt"), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier":"org.macseed.fixture", "CFBundleShortVersionString":"1"], format: .xml, options: 0).write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        let row: [String: Any] = ["adamID":425264550, "bundleID":"org.macseed.fixture", "version":"1", "path":bundle.path]
        let bytes = try JSONSerialization.data(withJSONObject: row)
        rejected { try MASInventory.verify(bytes, id: "425264550") }
        try Data("fixture receipt".utf8).write(to: bundle.appendingPathComponent("Contents/_MASReceipt/receipt"))
        rejected { try MASInventory.verify(bytes, id: "425264550") } // fabricated receipt / unsigned bundle
        rejected { try MASInventory.verify(bytes, id: "1024640650") }
        rejected { _ = try MASInventory.contains(Data("{\"adamID\":true}".utf8), id: "1") }
        print("PASS: universal ID policy, exact signed identities/foreign code rejection, session policy, serial journal/no-retry, receipt/bundle verification mismatch; no service registration or MAS execution")
    }
}
