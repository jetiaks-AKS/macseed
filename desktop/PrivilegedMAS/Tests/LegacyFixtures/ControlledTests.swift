import Foundation
import Darwin

@main enum ControlledTests {
    static func main() throws {
        for id in ["", "0", "-1", "01", "425264550;id", "１２３"] {
            precondition(Contract.installDecision(id: id, confirmed: true, present: false) == "invalid_app_store_id")
        }
        precondition(Contract.installDecision(id: "1024640650", confirmed: true, present: false) == "unqualified_app_store_id")
        precondition(Contract.installDecision(id: Contract.targetID, confirmed: false, present: false) == "explicit_confirmation_required")
        precondition(Contract.installDecision(id: Contract.targetID, confirmed: true, present: true) == "already_present_no_reinstall")
        precondition(Contract.installDecision(id: Contract.targetID, confirmed: true, present: false) == "admitted")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Fixture.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/_MASReceipt"), withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "org.macseed.fixture", "CFBundleShortVersionString": "1.2", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        try Data("fixture receipt presence only".utf8).write(to: app.appendingPathComponent("Contents/_MASReceipt/receipt"))
        let row: [String: Any] = ["adamID": 425264550, "bundleID": "org.macseed.fixture", "version": "1.2", "path": app.path]
        let bytes = try JSONSerialization.data(withJSONObject: row)
        let verified = try UserVerification.validate(bytes, id: Contract.targetID)
        precondition(verified.contains("bundle_and_receipt_present"))
        for invalid in [Data(), Data("bad".utf8), try JSONSerialization.data(withJSONObject: ["adamID": 425264550]), bytes + Data([10]) + bytes] {
            do { _ = try UserVerification.validate(invalid, id: Contract.targetID); preconditionFailure("verification mismatch accepted") } catch {}
        }
        // Distinct rootless journals: an untouched legacy unknown cannot affect the new scope.
        let legacy = root.appendingPathComponent("legacy"); let fresh = root.appendingPathComponent("fresh")
        for dir in [legacy, fresh] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false) }
        try JournalFile.legacyBytes.write(to: legacy.appendingPathComponent("state.json"))
        let fd = open(fresh.path, O_RDONLY | O_DIRECTORY); precondition(fd >= 0); defer { close(fd) }
        let file = JournalFile(fd, owner: geteuid())
        try file.withExclusiveLock {
            let initial = try file.load(); precondition(initial != nil)
            let boot = try Child.bootIdentity(); precondition(OwnedAdmission.reason(initial, boot: boot) == nil)
            do { try file.withExclusiveLock {}; preconditionFailure("concurrent owner admitted") } catch {}
        }
        let unchanged = try Data(contentsOf: legacy.appendingPathComponent("state.json")); precondition(unchanged == JournalFile.legacyBytes)
        precondition(CommandLine.arguments.count == 2)
        let executable = CommandLine.arguments[1]
        for mode in ["error", "timeout"] {
            let directory = root.appendingPathComponent(mode)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY); precondition(descriptor >= 0); defer { close(descriptor) }
            let journalFile = JournalFile(descriptor, owner: geteuid())
            var journal = Journal(); try journal.begin("install", id: Contract.targetID, caller: Caller(uid: getuid(), gid: getgid(), auditSession: 1))
            journal.operations[0].ownership = OperationOwnership(bootIdentity: try Child.bootIdentity())
            journal.transition("launching", reason: "fixture_only"); try journalFile.save(journal)
            if mode == "error" {
                let result = try OwnedExecution.run(file: journalFile, command: .fixture(executable, "error"), role: "install", mutation: true, environment: [], connected: { true })
                precondition(result.0 == 73)
            } else {
                let child = try SuspendedOwnedChild(command: .fixture(executable, "slow"), environment: [])
                try child.resume()
                do { _ = try child.wait(deadline: ProcessInfo.processInfo.systemUptime, connected: { true }); preconditionFailure("timeout ignored") }
                catch LifetimeFault.timeout {} // Actual owned child, no signal after resume.
            }
            journal = try journalFile.load()!; journal.transition("unknown", reason: mode + "_fixture_no_retry"); try journalFile.save(journal)
            let reopened = try journalFile.load(); let boot = try Child.bootIdentity()
            precondition(OwnedAdmission.reason(reopened, boot: boot) == "unknown_no_retry")
        }
        Thread.sleep(forTimeInterval: 0.2)
        print("native fixture nonzero exit / bounded wait timeout + persistent no-retry PASS; no actual MAS")
        print("controlled ID/confirmation/already-present, independent verification/mismatch, isolated legacy and concurrent lock PASS; MAS launches=0")
    }
}
