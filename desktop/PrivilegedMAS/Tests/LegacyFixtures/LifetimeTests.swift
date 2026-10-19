import Foundation
import Darwin

@main enum LifetimeTests {
    static func refuse(_ body: () throws -> Void) {
        do { try body(); preconditionFailure("unexpected success") } catch {}
    }
    static func main() throws {
        precondition(geteuid() != 0 && CommandLine.arguments.count == 2)
        let executable = CommandLine.arguments[1]
        let boot = try Child.bootIdentity()
        let caller = Caller(uid: getuid(), gid: getgid(), auditSession: 1)
        var nativeRuns = 0
        func scenario(_ mode: String, fault: String? = nil, disconnect: String? = nil, writeFailure: Bool = false, intentWriteFailure: Bool = false, terminateHeld: Bool = false) throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lifetime-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { chmod(directory.path, 0o700); try? FileManager.default.removeItem(at: directory) }
            let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW); precondition(fd >= 0); defer { close(fd) }
            let file = JournalFile(fd, owner: geteuid())
            let marker = directory.appendingPathComponent("marker")
            var journal = Journal()
            try journal.begin("preflight", id: nil, caller: caller)
            journal.operations[0].ownership = OperationOwnership(bootIdentity: boot)
            journal.transition("launching", reason: "test_intent"); try file.save(journal)
            var connected = true; var spawned: Child?
            var success = false
            try file.withExclusiveLock {
                refuse { try file.withExclusiveLock {} }
                DispatchQueue.concurrentPerform(iterations: 8) { _ in
                    refuse { try file.withExclusiveLock {} }
                }
                if intentWriteFailure { precondition(chmod(directory.path, 0o500) == 0) }
                do {
                    _ = try OwnedExecution.run(file: file, command: .fixture(executable, mode), role: "inventory", mutation: false,
                        environment: ["PATH=/usr/bin:/bin", "LIFETIME_MARKER=" + marker.path], connected: { connected }, resumeWhileAdmitted: { child in
                            if terminateHeld {
                                precondition(child.identity == (try? Child.observe(child.pid)))
                                precondition(kill(child.pid, SIGKILL) == 0)
                                let deadline = ProcessInfo.processInfo.systemUptime + 1
                                while ProcessInfo.processInfo.systemUptime < deadline {
                                    var info = proc_bsdinfo()
                                    let count = proc_pidinfo(child.pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
                                    if count == 0 || info.pbi_status == UInt32(SZOMB) { break }
                                    Thread.sleep(forTimeInterval: 0.005)
                                }
                            }
                            try child.resume()
                        }, checkpoint: { point in
                            if point != "resumed" { precondition(!FileManager.default.fileExists(atPath: marker.path)) }
                            if point == "child_saved" {
                                let saved = try file.load()!
                                precondition(saved.state == "launching" && saved.operations[0].ownership!.launches.last!.child != nil)
                                spawned = saved.operations[0].ownership!.launches.last!.child
                            }
                            if point == "resume_saved" {
                                let saved = try file.load()!
                                precondition(saved.state == "running" && saved.operations[0].ownership!.launches.last!.resumeAuthorized)
                            }
                            if point == disconnect { connected = false }
                            if writeFailure && point == "spawned_suspended" { precondition(chmod(directory.path, 0o500) == 0) }
                            if point == fault { throw Failure.refused }
                        })
                    success = true
                } catch {}
            }
            chmod(directory.path, 0o700)
            let saved = try file.load()!
            if fault == nil && disconnect == nil && !writeFailure && !intentWriteFailure && !terminateHeld && mode == "fast" {
                precondition(success && FileManager.default.fileExists(atPath: marker.path))
                precondition(saved.operations[0].ownership!.launches.last!.exitStatus == 0)
                nativeRuns += 1
            } else {
                precondition(!success && ["unknown", "launching", "running"].contains(saved.state))
                if mode == "exec" { precondition(saved.operations[0].ownership!.launches.last!.uncertainty == LifetimeFault.execObserved.rawValue) }
                if mode == "fork" { precondition(saved.operations[0].ownership!.launches.last!.uncertainty == LifetimeFault.forkObserved.rawValue) }
                precondition(OwnedAdmission.reason(saved, boot: boot) != nil)
                try file.withExclusiveLock { _ = try OwnedExecution.recoverInterruptedOwner(file: file) }
                let recovered = try file.load()!; precondition(recovered.state == "unknown")
                // Simulated helper restart/reboot cannot clear durable uncertainty.
                let reopened = try JournalFile(fd, owner: geteuid()).load()
                precondition(OwnedAdmission.reason(reopened, boot: "new-boot") != nil)
                if fault != "resumed" && disconnect != "resumed" && mode == "fast" { precondition(!FileManager.default.fileExists(atPath: marker.path)) }
            }
            if let child = spawned, !success && mode == "fast" && disconnect != "resumed" { // pre-resume rollback reaps only its own held child
                errno = 0; precondition(kill(child.pid, 0) == -1 && errno == ESRCH)
            }
        }
        for _ in 0..<5 { try scenario("fast") }
        for point in ["intent_saved", "spawned_suspended", "child_saved", "resume_saved"] { try scenario("fast", fault: point) }
        try scenario("fast", writeFailure: true)
        try scenario("fast", intentWriteFailure: true)
        try scenario("fast", terminateHeld: true)
        try scenario("fast", disconnect: "child_saved")
        try scenario("slow", disconnect: "resumed")
        try scenario("exec")
        try scenario("fork")
        // These are deliberately model fixtures: no real PID reuse or reboot.
        let expected = Child(pid: 123, startSeconds: 1, startMicroseconds: 1, bootSession: boot)
        precondition(!SuspendedOwnedChild.sameInstance(expected, Child(pid: 123, startSeconds: 2, startMicroseconds: 1, bootSession: boot)))
        precondition(!SuspendedOwnedChild.sameInstance(expected, Child(pid: 123, startSeconds: 1, startMicroseconds: 1, bootSession: "new-boot")))
        precondition(OwnedAdmission.reason(nil, boot: boot) != nil)
        precondition(OwnedAdmission.reason(Journal(), boot: boot) == nil)
        var uncertain = Journal(); try uncertain.begin("install", id: Contract.targetID, caller: caller)
        uncertain.operations[0].ownership = OperationOwnership(bootIdentity: boot)
        uncertain.operations[0].mutationMayHaveStarted = true
        uncertain.transition("unknown", reason: "fixture_crash_or_identity_mismatch")
        precondition(OwnedAdmission.reason(uncertain, boot: boot) != nil)
        refuse { try uncertain.begin("install", id: Contract.targetID, caller: caller) }
        Thread.sleep(forTimeInterval: 0.2) // fixture children finish; no signal to resumed child
        print("native held-launch/fast-exit (\(nativeRuns)), child death before resume, fs write failure, phase failures, disconnect, exec/fork, lock/reopen PASS; restart/reboot/mutation-unknown fixtures PASS; MAS launches=0")
    }
}
