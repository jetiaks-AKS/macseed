import Foundation
import Darwin

@main enum AdmissionTests {
    static var count = 0
    static func check(_ value: Bool, _ message: String = "") { count += 1; precondition(value, message) }
    static func rejects(_ body: () throws -> Void) { do { try body(); preconditionFailure("unsafe admission") } catch { count += 1 } }
    static let caller = Caller(uid: getuid(), gid: getgid(), auditSession: 42)
    static func directory(_ body: (JournalFile) throws -> Void) throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: path) }
        let fd = open(path.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW); defer { close(fd) }; check(fd >= 0)
        try body(JournalFile(fd, owner: geteuid()))
    }
    static func launches(_ journal: inout Journal, mutation: Bool = true) {
        let i = journal.operations.count - 1
        let boot = journal.operations[i].ownership?.bootIdentity ?? "boot"
        let child = Child(pid: 123, startSeconds: 1, startMicroseconds: 2, bootSession: boot)
        journal.operations[i].ownership = OperationOwnership(bootIdentity: boot)
        journal.operations[i].ownership!.launches = [OwnedLaunchRecord(id: UUID(), role: mutation ? "install" : "inventory", child: child, resumeAuthorized: true, exitStatus: 0)]
        journal.operations[i].mutationMayHaveStarted = mutation
    }
    static func interrupted() throws -> Journal {
        var journal = Journal(); try journal.admitInstall("425264550", caller: caller, boot: "boot")
        launches(&journal); journal.operations[0].ownership!.launches[0].exitStatus = nil
        journal.operations[0].ownership!.launches[0].uncertainty = "owned_child_timeout_may_continue"
        journal.transition("unknown", reason: "fixture")
        return journal
    }
    static func review(_ journal: inout Journal, boot: String = "new-boot") -> AdmissionReview {
        let operation = journal.blockers.last!
        let review = AdmissionReview(id: UUID(), source: operation.id, operationSHA256: operation.digest, caller: caller,
            boot: boot, expires: Date().addingTimeInterval(300), ownership: RecoveryPolicy.ownership(operation, boot: boot),
            installation: "absent_in_observed_scope", appleServices: "not_observable")
        journal.reviews = [review]; return review
    }
    static func main() throws {
        check(geteuid() != 0)
        // Normal sequential installs and repeated verified no-op, without native MAS.
        try directory { file in
            for id in ["425264550", "1024640650"] {
                var journal = try file.load()!
                try journal.admitInstall(id, caller: caller, boot: "boot"); try file.save(journal)
                launches(&journal); try file.save(journal)
                try journal.finishVerified(present: false, verification: "verified_present"); try file.save(journal)
                check(journal.operations.last!.outcome == "succeeded_verified")
                check(OwnedAdmission.reason(journal, boot: "after-reboot") == nil)
            }
            var journal = try file.load()!
            try journal.admitInstall("425264550", caller: caller, boot: "after-reboot"); try file.save(journal)
            launches(&journal, mutation: false); try file.save(journal)
            try journal.finishVerified(present: true, verification: "verified_present"); try file.save(journal)
            check(journal.operations.last!.outcome == "already_present")
            // 70 attempts exceed the former permanent 64-record cap.
            for _ in 0..<70 {
                try file.checkpointHistory(); journal = try file.load()!
                try journal.admitInstall("425264550", caller: caller, boot: "boot"); try file.save(journal)
                launches(&journal); try file.save(journal); try journal.finishVerified(present: false, verification: "verified_present"); try file.save(journal)
            }
            check(try file.load()!.operations.count < 64)
            check(try file.load()!.archiveHead != nil)
            try file.withExclusiveLock { rejects { try file.withExclusiveLock {} } }
        }
        // v3 original bytes, hash, unknown and ownership survive migration exactly.
        try directory { file in
            var old = try interrupted(); old.schemaVersion = 3
            let raw = try JSONEncoder().encode(old); try file.atomic(raw, name: "state.json")
            try file.checkpointHistory(); var current = try file.load()!
            check(current.schemaVersion == 4 && current.operations == old.operations && current.state == "unknown")
            check(try file.read("history-" + JournalFile.hash(raw) + ".json") == raw)
            try file.checkpointHistory(); check(try file.load()!.migrationSHA256 == JournalFile.hash(raw))
            check(!current.permits("425264550", caller: caller, boot: "new-boot"))
            let sameBoot = review(&current, boot: "boot")
            check(sameBoot.ownership == "unproven")
            rejects { try current.issueGrant(reviewID: sameBoot.id, source: sameBoot.source, ids: ["425264550"], scope: "retry", caller: caller, boot: "boot", confirmed: true, downloadsClear: true) }
            let fresh = review(&current); try file.save(current)
            rejects { try current.issueGrant(reviewID: fresh.id, source: fresh.source, ids: ["2"], scope: "retry", caller: caller, boot: "new-boot", confirmed: true, downloadsClear: true) }
            rejects { try current.issueGrant(reviewID: fresh.id, source: fresh.source, ids: ["425264550"], scope: "retry", caller: caller, boot: "new-boot", confirmed: false, downloadsClear: true) }
            rejects { try current.issueGrant(reviewID: fresh.id, source: fresh.source, ids: ["425264550"], scope: "retry", caller: caller, boot: "new-boot", confirmed: true, downloadsClear: false) }
            try current.issueGrant(reviewID: fresh.id, source: fresh.source, ids: ["425264550"], scope: "retry", caller: caller, boot: "new-boot", confirmed: true, downloadsClear: true)
            try file.save(current)
            check(!current.permits("2", caller: caller, boot: "new-boot"))
            check(!current.permits("425264550", caller: Caller(uid: caller.uid, gid: caller.gid, auditSession: 43), boot: "new-boot"))
            check(!current.permits("425264550", caller: caller, boot: "new-boot", now: Date().addingTimeInterval(1000)))
            rejects { try current.issueGrant(reviewID: fresh.id, source: fresh.source, ids: ["425264550"], scope: "retry", caller: caller, boot: "new-boot", confirmed: true, downloadsClear: true) }
            try current.admitInstall("425264550", caller: caller, boot: "new-boot"); try file.save(current)
            check(try file.load()!.grants![0].entries[0].consumed)
            check(try file.load()!.operations[0] == old.operations[0])
            rejects { try current.admitInstall("425264550", caller: caller, boot: "new-boot") }
            // App appeared during review/execute: inventory-only owned invocation, no mutation.
            launches(&current, mutation: false); try file.save(current)
            try current.finishVerified(present: true, verification: "verified_present"); try file.save(current)
            check(current.operations[0].outcome == "unknown_no_retry")
            check(current.blockers.isEmpty && current.operations.last!.outcome == "already_present")
            check(try file.read("history-" + JournalFile.hash(raw) + ".json") == raw)
        }
        // Crash after durable grant consumption leaves launching, then unknown. No reuse.
        try directory { file in
            var journal = try interrupted(); let fresh = review(&journal)
            try file.save(journal)
            try journal.issueGrant(reviewID: fresh.id, source: fresh.source, ids: ["2", "3"], scope: "remaining", caller: caller, boot: "new-boot", confirmed: true, downloadsClear: true)
            try file.save(journal); try journal.admitInstall("2", caller: caller, boot: "new-boot"); try file.save(journal)
            check(try OwnedExecution.recoverInterruptedOwner(file: file))
            let restarted = try file.load()!
            check(!restarted.permits("3", caller: caller, boot: "new-boot"))
            check(restarted.blockers.count == 1 && restarted.blockers[0].appStoreID == "2")
            check(restarted.operations[0].outcome == "unknown_no_retry")
        }
        var mismatch = Journal(); try mismatch.admitInstall("425264550", caller: caller, boot: "boot"); launches(&mismatch)
        rejects { try mismatch.finishVerified(present: false, verification: "unverified") }
        // Identity mismatch, fork, exec, timeout and disconnect never qualify success.
        for fault in ["owned_child_fork_descendants_unqualified", "owned_child_exec_identity_changed", "owned_child_identity_changed", "owned_child_timeout_may_continue", "xpc_disconnect_child_may_continue"] {
            var journal = try interrupted(); journal.operations[0].ownership!.launches[0].uncertainty = fault
            check(!journal.operations[0].terminalVerified)
            check(RecoveryPolicy.ownership(journal.operations[0], boot: "boot") == "unproven")
            rejects { try journal.finishVerified(present: false, verification: "verified_present") }
        }
        // Read-only diagnostic recovery is a separate explicit decision after boot.
        try directory { file in
            var diagnostic = Journal(); try diagnostic.begin("list", id: nil, caller: caller)
            diagnostic.operations[0].ownership = OperationOwnership(bootIdentity: "boot")
            diagnostic.transition("unknown", reason: "fixture_read_only_interruption")
            try file.save(diagnostic); let raw = try file.read("state.json")!
            rejects { try file.reconcileObservationAfterReboot(caller: caller, boot: "boot") }
            check(try file.read("state.json") == raw)
            try file.reconcileObservationAfterReboot(caller: caller, boot: "new-boot")
            check(try file.load()!.operations[0].outcome == "unknown_no_retry")
            check(try file.read("history-" + JournalFile.hash(raw) + ".json") == raw)
            check(try file.load()!.permits(nil, caller: caller, boot: "new-boot"))
        }
        // Migration publication failure cannot discard the original or spawn work.
        try directory { file in
            var original = try interrupted(); original.schemaVersion = 3
            try file.save(original); let raw = try file.read("state.json")!
            let name = "history-" + JournalFile.hash(raw) + ".json"
            try file.atomic(Data("conflicting archive".utf8), name: name, exclusive: true)
            rejects { try file.checkpointHistory() }
            check(try file.read("state.json") == raw)
        }
        // A new review revokes unspent permissions from an earlier review.
        var stale = try interrupted(); let firstReview = review(&stale)
        try stale.issueGrant(reviewID: firstReview.id, source: firstReview.source, ids: ["425264550"], scope: "retry", caller: caller, boot: "new-boot", confirmed: true, downloadsClear: true)
        _ = review(&stale)
        check(!stale.permits("425264550", caller: caller, boot: "new-boot"))
        rejects { try stale.issueGrant(reviewID: firstReview.id, source: firstReview.source, ids: ["425264550"], scope: "retry", caller: caller, boot: "new-boot", confirmed: true, downloadsClear: true) }
        var emptyUnknown = Journal(); emptyUnknown.state = "unknown"
        check(!emptyUnknown.permits(nil, caller: caller, boot: "boot"))
        // Real suspended launch/reap of a harmless rootless fixture; verification
        // remains injected evidence, not a claim about a real App Store install.
        try directory { file in
            try file.withExclusiveLock {
                let boot = try Child.bootIdentity()
                for id in ["425264550", "2"] {
                    var journal = try file.load()!; try journal.admitInstall(id, caller: caller, boot: boot); try file.save(journal)
                    let result = try OwnedExecution.run(file: file, command: .fixture("/bin/sleep", "0.01"), role: "install", mutation: true,
                        environment: ["PATH=/usr/bin:/bin"], connected: { true })
                    check(result.0 == 0)
                    journal = try file.load()!; try journal.finishVerified(present: false, verification: "verified_present"); try file.save(journal)
                    check(journal.operations.last!.terminalVerified)
                }
            }
        }
        // Injected owner loss after native spawn, before child identity publication.
        try directory { file in
            let boot = try Child.bootIdentity()
            var journal = try interrupted(); let consent = review(&journal, boot: boot)
            try file.save(journal)
            try journal.issueGrant(reviewID: consent.id, source: consent.source, ids: ["425264550"], scope: "retry", caller: caller, boot: boot, confirmed: true, downloadsClear: true)
            try file.save(journal); try journal.admitInstall("425264550", caller: caller, boot: boot); try file.save(journal)
            rejects { _ = try OwnedExecution.run(file: file, command: .fixture("/bin/sleep", "0.01"), role: "install", mutation: true,
                environment: ["PATH=/usr/bin:/bin"], connected: { true }, checkpoint: { if $0 == "spawned_suspended" { throw Failure.refused } }) }
            journal = try file.load()!
            check(journal.state == "unknown" && journal.operations.last!.ownership!.launches.last!.child == nil)
            check(journal.grants![0].entries[0].consumed && journal.operations[0].outcome == "unknown_no_retry")
            check(!journal.permits("425264550", caller: caller, boot: try Child.bootIdentity()))
        }
        // Receipt presence, unsigned/fabricated CMS and inventory mismatch are not success.
        rejects { try MASInventory.verify(Data(), id: "425264550") }
        rejects { try ReceiptVerification.verify(Data("not a signed receipt".utf8), bundleID: "x", version: "1") }
        rejects { _ = try MASInventory.contains(Data("{\"adamID\":true}".utf8), id: "1") }
        rejects { _ = try ReceiptVerification.attributes(Data([0x31, 0x80])) }
        print("PASS: \(count) admission/history/recovery checks; sequential verified/no-op, v3 preservation, grant scope/expiry/session/single-use, crash, concurrent lock, ownership and verification refusal. Fixtures only; no MAS or system mutation.")
    }
}
