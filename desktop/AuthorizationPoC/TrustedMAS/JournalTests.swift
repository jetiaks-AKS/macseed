import Foundation
import Darwin

@main enum Tests {
    static func refuses(_ body: () throws -> Void) {
        do { try body(); preconditionFailure("unsafe admission unexpectedly succeeded") } catch {}
    }
    static func main() throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("controlled-journal-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: scratch) }
        let fd = open(scratch.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        precondition(fd >= 0); defer { close(fd) }
        let file = JournalFile(fd, owner: geteuid())
        let caller = Caller(uid: 501, gid: 20, auditSession: 100024)
        let evidence = try Data(contentsOf: URL(fileURLWithPath: "LIVE-RESULTS-2026-10-18.md"))
        try file.atomic(JournalFile.legacyBytes, name: "state.json")
        let legacy = try file.load(); precondition(legacy == nil)
        refuses { try file.save(Journal()) } // Cannot erase legacy history.
        try file.atomic(JournalFile.legacyBytes + Data([10]), name: "state.json")
        refuses { _ = try file.load() } // Exact source bytes required.
        try file.atomic(JournalFile.legacyBytes, name: "state.json")
        for (ack, inactive, bytes) in [(false, true, evidence), (true, false, evidence), (true, true, Data("wrong".utf8))] {
            refuses { _ = try file.reconcile(caller: caller, acknowledged: ack, noActiveOwnedWork: inactive, evidence: bytes) }
            let unchanged = try file.read("state.json"); precondition(unchanged == JournalFile.legacyBytes)
        }
        try file.withExclusiveLock {
            refuses { try file.withExclusiveLock {} }
            _ = try file.reconcile(caller: caller, acknowledged: true, noActiveOwnedWork: true, evidence: evidence)
        }
        let archived = scratch.appendingPathComponent("legacy-" + JournalFile.hash(JournalFile.legacyBytes))
        let original = try Data(contentsOf: archived.appendingPathComponent("journal.original.json")); precondition(original == JournalFile.legacyBytes)
        let decision = try JSONDecoder().decode(LegacyDecision.self, from: Data(contentsOf: archived.appendingPathComponent("decision.json")))
        precondition(decision.originalSHA256 == JournalFile.hash(JournalFile.legacyBytes))
        precondition(decision.historicalOperationID == nil && decision.historicalChildIdentity == nil)
        precondition(decision.appleServices == "quiescence_not_proven")
        var journal = try file.load()!
        precondition(journal.state == "operator_reconciled_legacy_diagnostic")
        refuses { _ = try file.reconcile(caller: caller, acknowledged: true, noActiveOwnedWork: true, evidence: evidence) }
        for id in ["", "0", "-1", "01", "1;id", "1e3", "１２３", "18446744073709551616"] { precondition(!Contract.validID(id)) }
        func reason(_ id: String = Contract.targetID, _ state: Journal? = journal, session: Bool = true, connected: Bool = true, busy: Bool = false, trusted: Bool = true) -> String? {
            InstallAdmission.reason(id: id, journal: state, sessionValid: session, connected: connected, busy: busy, executableTrusted: trusted)
        }
        precondition(reason() == nil)
        precondition(reason("0") == "invalid_app_store_id")
        precondition(reason("123") == "unqualified_app_store_id")
        precondition(reason(Contract.targetID, nil) == "legacy_unknown_requires_operator_reconciliation")
        precondition(reason(session: false) == "wrong_user_or_session")
        precondition(reason(connected: false) == "wrong_user_or_session")
        precondition(reason(busy: true) == "operation_busy")
        precondition(reason(trusted: false) == "untrusted_mas")
        precondition(Contract.liveInstallEnabled)
        try journal.begin("install", id: Contract.targetID, caller: caller)
        journal.operations[0].mutationMayHaveStarted = true
        try file.save(journal)
        // Fake launcher observes durable ownership BEFORE launch; no MAS process.
        let beforeLaunch = try JournalFile(fd, owner: geteuid()).load()!
        precondition(beforeLaunch.state == "running" && beforeLaunch.operations[0].appStoreID == Contract.targetID && beforeLaunch.operations[0].caller == caller)
        precondition(beforeLaunch.operations[0].mutationMayHaveStarted)
        precondition(reason(Contract.targetID, beforeLaunch) == "unknown_no_retry")
        journal.transition("unknown", reason: "simulated_xpc_interruption")
        try file.save(journal)
        let reopened = try JournalFile(fd, owner: geteuid()).load()!
        precondition(reopened.state == "unknown" && reopened.operations[0].transitions.last?.reason == "simulated_xpc_interruption")
        precondition(reason(Contract.targetID, reopened) == "unknown_no_retry")
        refuses { try file.save(Journal()) }
        refuses { var erased = reopened; erased.operations[0].transitions = []; try file.save(erased) }
        refuses { var erased = reopened; erased.state = "completed"; try file.save(erased) }
        refuses { var blocked = reopened; try blocked.begin("install", id: Contract.targetID, caller: caller) }
        refuses { _ = try file.reconcile(caller: caller, acknowledged: true, noActiveOwnedWork: true, evidence: evidence) }
        // Symlinked journal is refused without following it or changing archive.
        let link = scratch.appendingPathComponent("state.json")
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: archived.appendingPathComponent("journal.original.json"))
        refuses { _ = try file.load() }
        print("legacy archive, exclusive lock, admission, durable launch, interruption and symlink checks passed; MAS launches=0")
    }
}
