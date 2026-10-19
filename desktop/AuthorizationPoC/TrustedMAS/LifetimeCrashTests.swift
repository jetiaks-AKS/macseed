import Foundation
import Darwin

// Native process-level qualification only. No installed helper, MAS or root state.
@main enum LifetimeCrashTests {
    static func trace(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }
    struct Assertion: Error { let line: Int }
    static func testRequire(_ condition: Bool, line: Int = #line) throws { if !condition { throw Assertion(line: line) } }
    static func info(_ pid: Int32) throws -> proc_bsdinfo {
        var value = proc_bsdinfo(); let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        try testRequire(proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &value, size) == size)
        return value
    }
    static func fixtureIdentity(_ pid: Int32, executable: String) throws -> Child {
        var path = [CChar](repeating: 0, count: 4096)
        try testRequire(proc_pidpath(pid, &path, UInt32(path.count)) > 0 && String(cString: path) == executable)
        try testRequire(try info(pid).pbi_uid == getuid())
        return try Child.observe(pid)
    }
    static func waitFor(_ predicate: () throws -> Bool) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        while ProcessInfo.processInfo.systemUptime < deadline {
            if try predicate() { return }; Thread.sleep(forTimeInterval: 0.01)
        }
        throw Failure.refused
    }
    static func main() throws {
        precondition(geteuid() != 0)
        if CommandLine.arguments.count == 5 && CommandLine.arguments[1] == "--supervisor" {
            let executable = CommandLine.arguments[2], directory = CommandLine.arguments[3], phase = CommandLine.arguments[4]
            let fd = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW); try testRequire(fd >= 0); defer { close(fd) }
            let file = JournalFile(fd, owner: geteuid())
            try file.withExclusiveLock {
                var journal = Journal(); try journal.begin("preflight", id: nil, caller: Caller(uid: getuid(), gid: getgid(), auditSession: 1))
                journal.operations[0].ownership = OperationOwnership(bootIdentity: try Child.bootIdentity())
                journal.transition("launching", reason: "native_crash_fixture_intent"); try file.save(journal)
                _ = try OwnedExecution.run(file: file, command: .fixture(executable, phase == "before" ? "fast" : "crash-after"), role: "inventory", mutation: false,
                    environment: ["LIFETIME_MARKER=" + directory + "/marker"], connected: { true }, checkpoint: { point in
                        guard point == (phase == "before" ? "spawned_suspended" : "resumed") else { return }
                        var pids = [Int32](repeating: 0, count: 32)
                        let count = proc_listchildpids(getpid(), &pids, Int32(pids.count * MemoryLayout<Int32>.size))
                        try testRequire(count > 0 && count < pids.count)
                        let candidates = pids.prefix(Int(count)).filter { $0 > 0 }
                        try testRequire(candidates.count == 1)
                        let child = try fixtureIdentity(candidates[0], executable: executable)
                        // Out-of-band fixture cleanup evidence, NOT a journal backfill.
                        try JSONEncoder().encode(child).write(to: URL(fileURLWithPath: directory + "/test-child.json"), options: .atomic)
                        if phase == "after" { try waitFor { FileManager.default.fileExists(atPath: directory + "/marker") } }
                        try Data("ready".utf8).write(to: URL(fileURLWithPath: directory + "/ready"), options: .atomic)
                        while true { Thread.sleep(forTimeInterval: 0.05) } // parent kills this exact direct supervisor
                    })
            }
            return
        }
        try testRequire(CommandLine.arguments.count == 2)
        let executable = CommandLine.arguments[1]
        for phase in ["before", "after"] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lifetime-crash-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW); try testRequire(fd >= 0)
            let file = JournalFile(fd, owner: geteuid())
            let supervisor = Process(); supervisor.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]); supervisor.arguments = ["--supervisor", executable, directory.path, phase]
            var child: Child?
            defer {
                if supervisor.isRunning { supervisor.terminate(); supervisor.waitUntilExit() }
                if let expected = child, (try? fixtureIdentity(expected.pid, executable: executable)) == expected { kill(expected.pid, SIGKILL) }
                close(fd); try? FileManager.default.removeItem(at: directory)
            }
            try supervisor.run()
            let supervisorIdentity = try Child.observe(supervisor.processIdentifier)
            try waitFor { FileManager.default.fileExists(atPath: directory.appendingPathComponent("ready").path) }
            let expected = try JSONDecoder().decode(Child.self, from: Data(contentsOf: directory.appendingPathComponent("test-child.json")))
            child = expected
            try testRequire(expected == fixtureIdentity(expected.pid, executable: executable))
            let before = try file.load()!
            if phase == "before" {
                try testRequire(before.state == "launching" && before.operations[0].ownership!.launches[0].child == nil)
                try testRequire(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("marker").path))
                try testRequire(try info(expected.pid).pbi_status == UInt32(SSTOP))
            } else {
                try testRequire(before.state == "running" && before.operations[0].ownership!.launches[0].resumeAuthorized)
            }
            let raw = try file.read("state.json")!
            try testRequire(supervisor.isRunning && supervisorIdentity == Child.observe(supervisor.processIdentifier))
            try testRequire(kill(supervisor.processIdentifier, SIGKILL) == 0)
            supervisor.waitUntilExit()
            try testRequire(try file.read("state.json") == raw) // actual crash cannot retroactively write unknown
            var metadata = proc_bsdinfo(); errno = 0
            let metadataResult = proc_pidinfo(expected.pid, PROC_PIDTBSDINFO, 0, &metadata, Int32(MemoryLayout<proc_bsdinfo>.size))
            let metadataError = errno; errno = 0; let alive = kill(expected.pid, 0); let aliveError = errno
            let disposition: String
            if metadataResult == MemoryLayout<proc_bsdinfo>.size {
                try testRequire(expected == Child.observe(expected.pid))
                try testRequire(metadata.pbi_ppid != UInt32(supervisor.processIdentifier))
                disposition = "same_identity_reparented"
                if phase == "before" {
                    try testRequire(metadata.pbi_status == UInt32(SSTOP))
                    try testRequire(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("marker").path))
                    // Rootless fixture only, not a privileged signal-by-PID endpoint.
                    try testRequire(expected == fixtureIdentity(expected.pid, executable: executable))
                    try testRequire(kill(expected.pid, SIGKILL) == 0)
                }
            } else {
                try testRequire(metadataError == ESRCH && alive == -1 && aliveError == ESRCH)
                disposition = "not_present_ESRCH"
                if phase == "before" { try testRequire(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("marker").path)) }
                child = nil
            }
            try file.withExclusiveLock { try testRequire(try OwnedExecution.recoverInterruptedOwner(file: file)) }
            let recovered = try file.load()!; try testRequire(recovered.state == "unknown")
            try testRequire(OwnedAdmission.reason(recovered, boot: Child.bootIdentity()) != nil)
            try waitFor {
                if let current = try? Child.observe(expected.pid) {
                    if current != expected { return true }
                    return try info(expected.pid).pbi_status == UInt32(SZOMB)
                }
                return true
            }
            child = nil
            print("native supervisor SIGKILL \(phase) resume: journal preserved, child=\(disposition), recovery unknown/no-retry PASS")
        }
    }
}
