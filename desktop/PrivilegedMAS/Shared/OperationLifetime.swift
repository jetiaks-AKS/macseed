import Foundation
import Darwin

enum LifetimeFault: String, Error {
    case forkObserved = "owned_child_fork_descendants_unqualified"
    case execObserved = "owned_child_exec_identity_changed"
    case disconnected = "xpc_disconnect_child_may_continue"
    case timeout = "owned_child_timeout_may_continue"
    case identityChanged = "owned_child_identity_changed"
}

struct OwnedLaunchRecord: Codable, Equatable {
    let id: UUID
    let role: String
    var child: Child?
    var resumeAuthorized = false
    var exitStatus: Int32?
    var uncertainty: String?
    var helperPID: Int32?
}
struct OperationOwnership: Codable, Equatable {
    let bootIdentity: String
    var launches: [OwnedLaunchRecord] = []
    // Direct-child events cannot establish completion of Apple service work.
    var serviceLifetime = "unqualified"
}

struct LateChildExitEvidence: Codable {
    let operationID: UUID
    let launchID: UUID
    let child: Child
    let rawWaitStatus: Int32
    let at: String
    var appleServices = "unproven"
}

extension Child {
    static func bootIdentity() throws -> String {
        var bytes = [CChar](repeating: 0, count: 128); var size = bytes.count
        try require(sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0)
        let value = String(cString: bytes); try require(!value.isEmpty); return value
    }
    static func observe(_ pid: Int32) throws -> Child {
        var info = proc_bsdinfo(); let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        try require(proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size && info.pbi_pid == UInt32(pid))
        return Child(pid: pid, startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec, bootSession: try bootIdentity())
    }
}

enum OwnedAdmission {
    static func reason(_ journal: Journal?, boot: String) -> String? {
        guard let journal else { return "legacy_unknown_requires_separate_operator_policy" }
        guard !["launching", "running", "unknown"].contains(journal.state) else { return "unknown_no_retry" }
        if !journal.blockers.isEmpty {
            // Legacy explicit no-mutation resolution remains readable.
            if journal.state == "operator_reconciled_no_mutation", journal.operations.allSatisfy({ !$0.mutationMayHaveStarted && $0.qualifiedLifetime }) { return nil }
            return "historical_lifetime_unqualified"
        }
        return nil
    }
}

// No XPC-supplied executable, arguments or environment. Test commands are not
// present in the helper build. MAS execution stays behind a separate qualification.
enum OwnedCommand {
    case qualificationVersion
    case inventory
    case install(String)
    #if LIFETIME_TESTING
    case fixture(String, String)
    #endif
    func validateAdmission() throws {
        switch self {
        case .qualificationVersion: try require(Contract.lifetimeQualificationOnly)
        case .inventory: try require(Contract.suspendedMASLaunchQualified)
        case let .install(id): try require(Contract.suspendedMASLaunchQualified && Contract.liveInstallEnabled && Contract.validID(id) && Contract.permitsInstallID(id))
        #if LIFETIME_TESTING
        case .fixture: break
        #endif
        }
    }
    var path: String {
        switch self {
        case .qualificationVersion, .inventory, .install: return Contract.directory + "/" + Contract.executableName
        #if LIFETIME_TESTING
        case let .fixture(path, _): return path
        #endif
        }
    }
    var arguments: [String] {
        switch self {
        case .qualificationVersion: return ["version"]
        case .inventory: return ["list", "--json"]
        case let .install(id): return ["install", id]
        #if LIFETIME_TESTING
        case let .fixture(_, mode): return [mode]
        #endif
        }
    }
}

// A direct child remains unreaped until all signals are finished, preventing PID
// reuse during the owned suspend/resume phase. No signal is sent after resume.
final class SuspendedOwnedChild {
    let pid: Int32
    let identity: Child
    private let events: Int32
    private let output: Int32
    private var resumed = false
    private var reaped = false
    var lateExit: ((Child, Int32) -> Void)?
    init(command: OwnedCommand, environment: [String]) throws {
        try command.validateAdmission()
        var pipeFD: [Int32] = [0, 0]
        try require(pipe(&pipeFD) == 0)
        var readFD = pipeFD[0]; var writeFD = pipeFD[1]
        defer { if readFD >= 0 { close(readFD) }; if writeFD >= 0 { close(writeFD) } }
        try require(fcntl(readFD, F_SETFD, FD_CLOEXEC) == 0 && fcntl(writeFD, F_SETFD, FD_CLOEXEC) == 0)
        try require(fcntl(readFD, F_SETFL, O_NONBLOCK) == 0)
        var actions: posix_spawn_file_actions_t?; var attributes: posix_spawnattr_t?
        try require(posix_spawn_file_actions_init(&actions) == 0)
        defer { posix_spawn_file_actions_destroy(&actions) }
        try require(posix_spawnattr_init(&attributes) == 0)
        defer { posix_spawnattr_destroy(&attributes) }
        try require(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_START_SUSPENDED | POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0)
        try require(posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0) == 0)
        try require(posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0) == 0)
        try require(posix_spawn_file_actions_adddup2(&actions, writeFD, 1) == 0)
        let argv = ([command.path] + command.arguments).map { strdup($0) } + [nil]
        let env = environment.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) }; env.forEach { free($0) } }
        var childPID: Int32 = 0
        let result = argv.withUnsafeBufferPointer { a in env.withUnsafeBufferPointer { e in
            posix_spawn(&childPID, command.path, &actions, &attributes, a.baseAddress!, e.baseAddress!)
        } }
        try require(result == 0 && childPID > 0)
        close(writeFD); writeFD = -1
        // On setup failure only this still-unresumed direct child may be killed.
        var owned = false; var queue: Int32 = -1
        defer {
            if !owned {
                if queue >= 0 { close(queue) }
                kill(childPID, SIGKILL); var status: Int32 = 0
                while waitpid(childPID, &status, 0) < 0 && errno == EINTR {}
            }
        }
        let first = try Self.heldIdentity(childPID)
        queue = kqueue(); try require(queue >= 0)
        try require(fcntl(queue, F_SETFD, FD_CLOEXEC) == 0)
        var change = kevent(ident: UInt(childPID), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ENABLE), fflags: UInt32(NOTE_EXIT) | UInt32(NOTE_EXEC) | UInt32(NOTE_FORK), data: 0, udata: nil)
        try require(kevent(queue, &change, 1, nil, 0, nil) == 0)
        try require(first == Self.heldIdentity(childPID))
        pid = childPID; identity = first; events = queue; output = readFD
        readFD = -1; owned = true
    }
    private static func heldIdentity(_ pid: Int32) throws -> Child {
        var info = proc_bsdinfo(); let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        try require(proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size)
        try require(info.pbi_pid == UInt32(pid) && info.pbi_ppid == UInt32(getpid()) && info.pbi_status == UInt32(SSTOP))
        return try Child.observe(pid)
    }
    static func sameInstance(_ expected: Child, _ observed: Child) -> Bool { expected == observed }
    func resume() throws {
        try require(!resumed && !reaped)
        guard Self.sameInstance(identity, try Self.heldIdentity(pid)) else { throw LifetimeFault.identityChanged }
        try require(kill(pid, SIGCONT) == 0); resumed = true
    }
    func wait(deadline: TimeInterval, connected: () -> Bool) throws -> (Int32, Data) {
        try require(resumed)
        var bytes = Data(); var status: Int32 = 0; var exited = false; var eof = false
        var observedExit = false
        while ProcessInfo.processInfo.systemUptime < deadline {
            guard connected() else { throw LifetimeFault.disconnected }
            var event = kevent(); var timeout = timespec(tv_sec: 0, tv_nsec: 0)
            let count = kevent(events, nil, 0, &event, 1, &timeout)
            try require(count >= 0)
            if count > 0 {
                try require(event.flags & UInt16(EV_ERROR) == 0)
                // Fork/reparenting or exec invalidates this bounded direct-child
                // lifetime contract. Never attempt to enumerate away uncertainty.
                if event.fflags & UInt32(NOTE_FORK) != 0 { throw LifetimeFault.forkObserved }
                if event.fflags & UInt32(NOTE_EXEC) != 0 { throw LifetimeFault.execObserved }
                observedExit = observedExit || event.fflags & UInt32(NOTE_EXIT) != 0
            }
            var chunk = [UInt8](repeating: 0, count: 8192)
            let length = read(output, &chunk, chunk.count)
            if length > 0 { bytes.append(contentsOf: chunk.prefix(length)); try require(bytes.count <= 2 * 1024 * 1024) }
            else if length == 0 { eof = true }
            else { try require(errno == EAGAIN || errno == EINTR) }
            if !exited {
                let result = waitpid(pid, &status, WNOHANG)
                try require(result == 0 || result == pid || (result < 0 && errno == EINTR))
                if result == pid { exited = true; reaped = true }
            }
            if exited && eof && observedExit {
                if status & 0x7f != 0 { lateExit?(identity, status) }
                try require(status & 0x7f == 0) // signal exit is uncertain, never success
                return ((status >> 8) & 0xff, bytes)
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
        throw LifetimeFault.timeout
    }
    deinit {
        close(events); close(output)
        guard !reaped else { return }
        let childPID = pid
        if !resumed {
            kill(childPID, SIGKILL); var status: Int32 = 0
            while waitpid(childPID, &status, 0) < 0 && errno == EINTR {}
        } else {
            // Separate evidence only. Reaping never rewrites the mutation journal.
            let callback = lateExit; let identity = identity
            DispatchQueue.global().async {
                var status: Int32 = 0; var result: Int32
                repeat { result = waitpid(childPID, &status, 0) } while result < 0 && errno == EINTR
                if result == childPID { callback?(identity, status) }
            }
        }
    }
}

// Caller holds the existing coordinator lock AND JournalFile exclusive flock
// throughout this synchronous invocation. No alternative journal is introduced.
enum OwnedExecution {
    // Only while holding the exclusive journal lock: a live owner prevents entry.
    static func recoverInterruptedOwner(file: JournalFile) throws -> Bool {
        guard var journal = try file.load(), ["launching", "running"].contains(journal.state) else { return false }
        journal.transition("unknown", reason: "owner_restart_incomplete_lifetime_no_retry")
        try file.save(journal)
        return true
    }
    static func run(file: JournalFile, command: OwnedCommand, role: String, mutation: Bool,
                    environment: [String], connected: () -> Bool,
                    resumeWhileAdmitted: (SuspendedOwnedChild) throws -> Void = { try $0.resume() },
                    checkpoint: (String) throws -> Void = { _ in }) throws -> (Int32, Data) {
        guard var journal = try file.load(), let ownership = journal.operations.last?.ownership else { throw Failure.refused }
        try require(["launching", "running"].contains(journal.state) && ownership.bootIdentity == Child.bootIdentity())
        let index = journal.operations.count - 1
        journal.operations[index].ownership!.launches.append(OwnedLaunchRecord(id: UUID(), role: role))
        let launch = journal.operations[index].ownership!.launches.count - 1
        journal.transition("launching", reason: "spawn_intent_before_native_launch")
        try file.save(journal) // Failure here guarantees no spawn.
        do {
            try checkpoint("intent_saved"); try require(connected())
            let child = try SuspendedOwnedChild(command: command, environment: environment)
            try checkpoint("spawned_suspended")
            journal.operations[index].ownership!.launches[launch].child = child.identity
            journal.operations[index].ownership!.launches[launch].helperPID = getpid()
            if role == "install" || journal.operations[index].child == nil { journal.operations[index].child = child.identity }
            journal.operations[index].observedChildren.append(ChildObservation(role: role, identity: child.identity, at: Journal.timestamp()))
            journal.transition("launching", reason: "suspended_child_identity_bound")
            try file.save(journal)
            let evidenceFD = dup(file.directory); try require(evidenceFD >= 0)
            try require(fcntl(evidenceFD, F_SETFD, FD_CLOEXEC) == 0)
            let heldDirectory = FileHandle(fileDescriptor: evidenceFD, closeOnDealloc: true)
            let operationID = journal.operations[index].id
            let launchID = journal.operations[index].ownership!.launches[launch].id
            let owner = file.owner
            child.lateExit = { identity, status in
                let evidence = LateChildExitEvidence(operationID: operationID, launchID: launchID, child: identity, rawWaitStatus: status, at: Journal.timestamp())
                let evidenceFile = JournalFile(heldDirectory.fileDescriptor, owner: owner)
                // Missing evidence on I/O failure remains unproven/no-retry.
                try? evidenceFile.atomic(JSONEncoder().encode(evidence), name: "child-exit-" + launchID.uuidString + ".json", exclusive: true)
            }
            try checkpoint("child_saved"); try require(connected())
            // This write is intent to resume, not a claim SIGCONT has happened.
            journal.operations[index].ownership!.launches[launch].resumeAuthorized = true
            journal.operations[index].mutationMayHaveStarted = journal.operations[index].mutationMayHaveStarted || mutation
            journal.transition("running", reason: "resume_authorized_before_signal")
            try file.save(journal)
            try checkpoint("resume_saved"); try require(connected())
            try resumeWhileAdmitted(child)
            try checkpoint("resumed")
            let result = try child.wait(deadline: ProcessInfo.processInfo.systemUptime + (mutation ? 900 : 30), connected: connected)
            journal.operations[index].ownership!.launches[launch].exitStatus = result.0
            let last = journal.operations[index].observedChildren.count - 1
            journal.operations[index].observedChildren[last].exitStatus = result.0
            journal.operations[index].observedChildren[last].terminationReason = "exit"
            journal.transition("running", reason: "owned_direct_child_reaped_no_fork_or_exec_observed")
            try file.save(journal)
            return result
        } catch {
            // If storage itself is broken, durable launching/running still blocks
            // restart. Never claim unknown was written when save fails.
            journal.operations[index].ownership!.launches[launch].uncertainty = (error as? LifetimeFault)?.rawValue ?? "launch_identity_storage_disconnect_or_lifetime_failure"
            journal.transition("unknown", reason: "owned_lifetime_uncertain_no_retry")
            try? file.save(journal)
            throw error
        }
    }
}
