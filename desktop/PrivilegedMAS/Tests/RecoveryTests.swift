import Foundation
import Darwin

@main enum RecoveryTests {
    static var assertions = 0
    static func check(_ value: Bool) { assertions += 1; precondition(value) }
    static func rejects(_ body: () throws -> Void) {
        do { try body(); preconditionFailure("unsafe recovery accepted") } catch { assertions += 1 }
    }
    static func fixture(mutation: Bool = true) throws -> Journal {
        var journal = Journal()
        try journal.begin("install", id: "425264550", caller: Caller(uid: getuid(), gid: getgid(), auditSession: 1))
        let child = try Child.observe(getpid())
        journal.operations[0].child = child
        var ownership = OperationOwnership(bootIdentity: child.bootSession)
        ownership.launches = [OwnedLaunchRecord(id: UUID(), role: mutation ? "install" : "inventory", child: child, resumeAuthorized: true,
            exitStatus: mutation ? nil : 0, uncertainty: mutation ? "owned_child_timeout_may_continue" : nil, helperPID: getppid())]
        journal.operations[0].ownership = ownership
        journal.operations[0].mutationMayHaveStarted = mutation
        journal.transition("unknown", reason: "fixture_interruption")
        return journal
    }
    static func directory(_ body: (JournalFile) throws -> Void) throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false, attributes: [.posixPermissions:0o700])
        defer { try? FileManager.default.removeItem(at: path) }
        let fd = open(path.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC); check(fd >= 0); defer { close(fd) }
        try body(JournalFile(fd, owner: geteuid()))
    }
    static func main() throws {
        check(geteuid() != 0)
        let journal = try fixture(), operation = journal.operations[0], child = operation.child!
        check(RecoveryPolicy.requestAllowed(id: operation.id.uuidString, action: "terminate", confirmed: true, operation: operation, caller: operation.caller, desktop: true, session: true))
        for (id, action, confirmed, desktop, session) in [
            (UUID().uuidString, "terminate", true, true, true), ("", "terminate", true, true, true),
            (operation.id.uuidString, "terminate", false, true, true), (operation.id.uuidString, "shell", true, true, true),
            (operation.id.uuidString, "verify", true, false, true), (operation.id.uuidString, "verify", true, true, false)] {
            check(!RecoveryPolicy.requestAllowed(id: id, action: action, confirmed: confirmed, operation: operation, caller: operation.caller, desktop: desktop, session: session))
        }
        check(!RecoveryPolicy.requestAllowed(id: operation.id.uuidString, action: "verify", confirmed: true, operation: operation,
            caller: Caller(uid: operation.caller.uid + 1, gid: operation.caller.gid, auditSession: 1), desktop: true, session: true))
        check(RecoveryProcess.inspect(child) == .alive)
        check(RecoveryProcess.inspect(Child(pid: child.pid, startSeconds: child.startSeconds + 1, startMicroseconds: child.startMicroseconds, bootSession: child.bootSession)) == .replaced)
        check(RecoveryProcess.inspect(Child(pid: child.pid, startSeconds: child.startSeconds, startMicroseconds: child.startMicroseconds, bootSession: "previous-boot")) == .rebooted)
        for state in [RecoveryChildState.alive, .exiting, .absent, .replaced, .rebooted, .unproven, .exited] {
            check(!RecoveryPolicy.noMutationResolution(operation, child: state))
            if state != .alive { check(!RecoveryPolicy.cancellationAllowed(operation, child: state, parent: 10, helper: 10, trusted: true, sessionValid: true)) }
        }
        check(RecoveryPolicy.cancellationAllowed(operation, child: .alive, parent: getppid(), helper: getppid(), trusted: true, sessionValid: true))
        for (parent, helper, trusted, session) in [(1,2,true,true), (1,1,false,true), (1,1,true,false)] {
            check(!RecoveryPolicy.cancellationAllowed(operation, child: .alive, parent: Int32(parent), helper: Int32(helper), trusted: trusted, sessionValid: session))
        }
        let harmless = try fixture(mutation: false)
        check(RecoveryPolicy.noMutationResolution(harmless.operations[0], child: .exited))
        var incomplete = harmless.operations[0]; incomplete.ownership!.launches[0].uncertainty = "disconnect"
        check(!RecoveryPolicy.noMutationResolution(incomplete, child: .exited))
        try directory { file in
            try file.save(journal); let original = try file.read("state.json")!
            let archive = try RecoveryArchive(parent: file, operation: operation.id, original: original)
            var signals = 0
            func evidence(_ signal: Int32 = SIGTERM) -> RecoverySignalEvidence {
                RecoverySignalEvidence(operationID: operation.id, journalSHA256: JournalFile.hash(original), caller: operation.caller,
                    child: child, parent: getppid(), auditPIDVersion: 42, signal: signal, at: Journal.timestamp())
            }
            try file.withExclusiveLock { rejects { try file.withExclusiveLock {} } }
            rejects { try file.reconcileNoMutation(operationID: operation.id, original: original, caller: operation.caller) }
            rejects { _ = try RecoveryCancellation.perform(file: file, archive: archive, original: original, evidence: evidence(), revalidate: { throw Failure.refused }, send: { signals += 1; return (true, 15) }) }
            check(try signals == 0 && archive.file.read("sigterm-intent.json") == nil)
            rejects { _ = try RecoveryCancellation.perform(file: file, archive: archive, original: original, evidence: evidence(SIGKILL), revalidate: {}, send: { signals += 1; return (true, 9) }) }
            let term = try RecoveryCancellation.perform(file: file, archive: archive, original: original, evidence: evidence(), revalidate: {}, send: {
                check(try archive.file.read("sigterm-intent.json") != nil); signals += 1; return (false, nil)
            })
            check(signals == 1 && term.result == "timeout_no_retry" && term.delivered)
            rejects { _ = try RecoveryCancellation.perform(file: file, archive: archive, original: original, evidence: evidence(), revalidate: {}, send: { signals += 1; return (true, 15) }) }
            let kill = try RecoveryCancellation.perform(file: file, archive: archive, original: original, evidence: evidence(SIGKILL), revalidate: {}, send: { signals += 1; return (true, 9) })
            check(signals == 2 && kill.exitObserved && kill.rawExitStatus == 9)
            rejects { _ = try RecoveryCancellation.perform(file: file, archive: archive, original: original, evidence: evidence(SIGKILL), revalidate: {}, send: { signals += 1; return (true, 9) }) }
            check(signals == 2)
            check(try file.read("state.json") == original)
            check(try archive.file.read("journal.original.json") == original)
            check(OwnedAdmission.reason(try file.load(), boot: child.bootSession) == "unknown_no_retry")
        }
        try directory { file in
            try file.save(journal); let original = try file.read("state.json")!
            let archive = try RecoveryArchive(parent: file, operation: operation.id, original: original)
            // Storage/identity failure before signalling: zero sends. Failed result
            // observation after signalling: no success or second signal.
            let evidence = RecoverySignalEvidence(operationID: operation.id, journalSHA256: JournalFile.hash(original), caller: operation.caller, child: child, parent: 1, auditPIDVersion: 1, signal: SIGTERM, at: Journal.timestamp())
            try archive.file.atomic(Data(), name: "sigterm-intent.json", exclusive: true)
            var sends = 0
            rejects { _ = try RecoveryCancellation.perform(file: file, archive: archive, original: original, evidence: evidence, revalidate: {}, send: { sends += 1; return (true, 0) }) }
            check(try sends == 0 && file.read("state.json") == original)
        }
        try directory { file in
            try file.save(harmless); let original = try file.read("state.json")!
            rejects { try file.reconcileNoMutation(operationID: UUID(), original: original, caller: operation.caller) }
            try file.reconcileNoMutation(operationID: harmless.operations[0].id, original: original, caller: harmless.operations[0].caller)
            let resolved = try file.load()!
            check(resolved.state == "operator_reconciled_no_mutation")
            check(resolved.operations[0].outcome == "unknown_no_retry") // never backdated completed
            check(OwnedAdmission.reason(resolved, boot: child.bootSession) == nil)
            let archive = try RecoveryArchive(parent: file, operation: harmless.operations[0].id, original: original)
            check(try archive.file.read("journal.original.json") == original)
        }
        try directory { file in
            try file.save(journal); let original = try file.read("state.json")!
            let archive = try RecoveryArchive(parent: file, operation: operation.id, original: original)
            let evidence = RecoverySignalEvidence(operationID: operation.id, journalSHA256: JournalFile.hash(original), caller: operation.caller, child: child, parent: 1, auditPIDVersion: 42, signal: SIGTERM, at: Journal.timestamp())
            var validations = 0; var sends = 0
            let result = try RecoveryCancellation.perform(file: file, archive: archive, original: original, evidence: evidence, revalidate: {
                validations += 1; if validations == 2 { throw Failure.refused }
            }, send: { sends += 1; return (true, 0) })
            check(sends == 0 && !result.exitObserved)
            check(result.result == "signal_or_observation_uncertain_no_retry")
            check(try file.read("state.json") == original)
            rejects { _ = try RecoveryCancellation.perform(file: file, archive: archive, original: original, evidence: evidence, revalidate: {}, send: { sends += 1; return (true, 0) }) }
            check(sends == 0)
        }
        // Real rootless suspend/disconnect/reap test, harmless fixed sleep fixture.
        try directory { file in
            var live = Journal(); try live.begin("list", id: nil, caller: operation.caller)
            live.operations[0].ownership = OperationOwnership(bootIdentity: child.bootSession)
            try file.save(live)
            var connected = true
            rejects { _ = try OwnedExecution.run(file: file, command: .fixture("/bin/sleep", "0.1"), role: "inventory", mutation: false,
                environment: ["PATH=/usr/bin:/bin"], connected: { connected }, checkpoint: { if $0 == "resumed" { connected = false } }) }
            let unknown = try file.read("state.json")!
            let interrupted = try file.load()!
            check(interrupted.state == "unknown")
            let launch = interrupted.operations[0].ownership!.launches[0]
            var data: Data?
            for _ in 0..<200 {
                data = try file.read("child-exit-" + launch.id.uuidString + ".json")
                if data != nil { break }; Thread.sleep(forTimeInterval: 0.01)
            }
            let recorded = try JSONDecoder().decode(LateChildExitEvidence.self, from: data!)
            check(recorded.child == launch.child && recorded.rawWaitStatus == 0)
            check(try file.read("state.json") == unknown)
        }
        // External evidence must be bound to this exact journal and child, not just PID.
        let original = try JSONEncoder().encode(journal)
        let identity: [String: Any] = ["boot": child.bootSession, "birthSeconds":child.startSeconds, "birthMicroseconds":child.startMicroseconds,
            "ppid":555, "executable":Contract.directory + "/" + Contract.executableName, "sha256":Contract.digest, "auditPIDVersion":42]
        var external: [String: Any] = ["operationID":operation.id.uuidString,"originalJournalSHA256":JournalFile.hash(original), "appStoreID":"425264550", "pid":child.pid,
            "helperPID":555, "signal":"SIGKILL","identity":identity, "taskNameResult":0,"auditTokenResult":0,"exitObserverRegistered":true,
            "childExitObserved":true,"signalDelivered":true,"signalReturn":0,"journalUnchanged":true]
        let valid = try JSONSerialization.data(withJSONObject: external)
        check(ExternalRecoveryEvidence.matches(original: original, operation: operation, intent: valid, result: valid))
        external["originalJournalSHA256"] = "wrong"
        check(!ExternalRecoveryEvidence.matches(original: original, operation: operation, intent: valid, result: try JSONSerialization.data(withJSONObject: external)))
        print("PASS: \(assertions) recovery assertions; fixture-only signal gates, protected evidence, no-mutation reconciliation, native rootless late exit; no MAS invocation or root signals")
    }
}
