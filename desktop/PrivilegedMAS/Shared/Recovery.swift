import Foundation
import Darwin

// An observation is not a proof of Apple-service quiescence.
enum RecoveryChildState: String {
    case alive, exiting, exited, absent, replaced, rebooted, unproven
}
enum RecoveryPolicy {
    static func requestAllowed(id: String, action: String, confirmed: Bool, operation: OperationRecord, caller: Caller, desktop: Bool, session: Bool) -> Bool {
        guard desktop, session, caller.uid == operation.caller.uid, caller.gid == operation.caller.gid,
              ["status", "verify", "terminate", "forceTerminate", "reconcile", "acceptRetry", "acceptRemaining", "reconcileObservation"].contains(action) else { return false }
        return (action == "status" || confirmed) && (id == operation.id.uuidString || (action == "status" && id.isEmpty))
    }
    static func ownership(_ operation: OperationRecord, boot: String) -> String {
        guard let ownership = operation.ownership else { return "unproven" }
        if ownership.bootIdentity != boot { return "prior_boot_ended" }
        return operation.qualifiedLifetime ? "qualified_owned_exit" : "unproven"
    }
    static func noMutationResolution(_ operation: OperationRecord, child: RecoveryChildState) -> Bool {
        guard !operation.mutationMayHaveStarted, let ownership = operation.ownership,
              !ownership.launches.isEmpty, child == .exited else { return false }
        return ownership.launches.allSatisfy {
            $0.child != nil && $0.resumeAuthorized && $0.exitStatus != nil && $0.uncertainty == nil && $0.role != "install"
        }
    }
    static func cancellationAllowed(_ operation: OperationRecord, child: RecoveryChildState, parent: Int32,
                                    helper: Int32, trusted: Bool, sessionValid: Bool) -> Bool {
        guard sessionValid, trusted, child == .alive, parent == helper,
              let last = operation.ownership?.launches.last, last.role == "install",
              last.child == operation.child, last.resumeAuthorized, last.exitStatus == nil else { return false }
        // Old journals had no launcher PID. A restarted helper cannot adopt a live orphan.
        return last.helperPID == nil || last.helperPID == helper
    }
}

// Native process-bound signal address. A PID is never used as the signal target.
final class RecoveryProcess {
    let identity: Child
    let parent: Int32
    let pidVersion: UInt32
    private var token: audit_token_t
    private let queue: Int32
    private let port: mach_port_name_t

    static func inspect(_ child: Child) -> RecoveryChildState {
        guard let boot = try? Child.bootIdentity() else { return .unproven }
        if boot != child.bootSession { return .rebooted }
        var info = proc_bsdinfo(); let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        errno = 0
        guard proc_pidinfo(child.pid, PROC_PIDTBSDINFO, 0, &info, size) == size else {
            // ESRCH means no PID now; it does not establish historical exit or quiescence.
            return errno == ESRCH ? .absent : .unproven
        }
        guard info.pbi_pid == UInt32(child.pid), info.pbi_start_tvsec == child.startSeconds,
              info.pbi_start_tvusec == child.startMicroseconds else { return .replaced }
        if info.pbi_status == UInt32(SZOMB) { return .exited }
        if info.pbi_flags & UInt32(PROC_FLAG_INEXIT) != 0 { return .exiting }
        return .alive
    }
    static func metadata(_ child: Child) throws -> proc_bsdinfo {
        try require(inspect(child) == .alive)
        var info = proc_bsdinfo(); let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        try require(proc_pidinfo(child.pid, PROC_PIDTBSDINFO, 0, &info, size) == size)
        try require(info.pbi_start_tvsec == child.startSeconds && info.pbi_start_tvusec == child.startMicroseconds)
        return info
    }
    static func path(_ pid: Int32) throws -> String {
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        try require(proc_pidpath(pid, &path, UInt32(path.count)) > 0)
        return String(cString: path)
    }
    init(_ child: Child, expectedParent: Int32, expectedVersion: UInt32?) throws {
        let before = try Self.metadata(child)
        try require(before.pbi_ppid == UInt32(expectedParent))
        try require(Self.path(child.pid) == Contract.directory + "/" + Contract.executableName)
        var name: mach_port_name_t = 0
        try require(task_name_for_pid(mach_task_self_, child.pid, &name) == KERN_SUCCESS)
        var accepted = false; var events: Int32 = -1
        defer { if !accepted { mach_port_deallocate(mach_task_self_, name); if events >= 0 { close(events) } } }
        var audit = audit_token_t(); var count = mach_msg_type_number_t(MemoryLayout<audit_token_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &audit) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(name, task_flavor_t(TASK_AUDIT_TOKEN), $0, &count) }
        }
        try require(result == KERN_SUCCESS && count == 8)
        let values = withUnsafeBytes(of: audit) { Array($0.bindMemory(to: UInt32.self)) }
        try require(values[5] == UInt32(child.pid) && values[7] > 0)
        try require(expectedVersion == nil || expectedVersion == values[7])
        try require(values[1] == before.pbi_uid && values[2] == before.pbi_gid && values[3] == before.pbi_ruid && values[4] == before.pbi_rgid)
        events = kqueue(); try require(events >= 0 && fcntl(events, F_SETFD, FD_CLOEXEC) == 0)
        var change = kevent(ident: UInt(child.pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT),
                            fflags: UInt32(NOTE_EXIT) | UInt32(NOTE_EXITSTATUS), data: 0, udata: nil)
        try require(kevent(events, &change, 1, nil, 0, nil) == 0)
        identity = child; parent = expectedParent; pidVersion = values[7]; token = audit; queue = events; port = name
        accepted = true
    }
    func revalidate() throws {
        let info = try Self.metadata(identity)
        try require(info.pbi_ppid == UInt32(parent))
        try require(Self.path(identity.pid) == Contract.directory + "/" + Contract.executableName)
        var event = kevent(); var timeout = timespec(tv_sec: 0, tv_nsec: 0)
        try require(kevent(queue, nil, 0, &event, 1, &timeout) == 0)
    }
    func signalOnce(_ signal: Int32) throws -> (Bool, Int32?) {
        try require(signal == SIGTERM || signal == SIGKILL)
        try revalidate()
        guard proc_signal_with_audittoken(&token, signal) == 0 else { throw Failure.refused }
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        while ProcessInfo.processInfo.systemUptime < deadline {
            var event = kevent(); var timeout = timespec(tv_sec: 0, tv_nsec: 100_000_000)
            let count = kevent(queue, nil, 0, &event, 1, &timeout)
            if count < 0 && errno == EINTR { continue }
            try require(count >= 0)
            if count > 0 {
                try require(event.ident == UInt(identity.pid) && event.flags & UInt16(EV_ERROR) == 0 && event.fflags & UInt32(NOTE_EXIT) != 0)
                return (true, Int32(event.data))
            }
        }
        return (false, nil)
    }
    deinit { close(queue); mach_port_deallocate(mach_task_self_, port) }
}

// Append-only recovery records in a protected child of the existing Store.
// Original journal bytes remain untouched unless a proven non-mutation is reconciled.
final class RecoveryArchive {
    let fd: Int32
    let file: JournalFile
    init(parent: JournalFile, operation: UUID, original: Data) throws {
        let name = "recovery-" + operation.uuidString
        if mkdirat(parent.directory, name, 0o700) != 0 { try require(errno == EEXIST) }
        let opened = openat(parent.directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        try require(opened >= 0)
        let record = JournalFile(opened, owner: parent.owner)
        do {
            var info = stat(); try require(fstat(opened, &info) == 0 && info.st_uid == parent.owner && info.st_mode & 0o777 == 0o700)
            try requireNoACL(opened)
            if let previous = try record.read("journal.original.json") { try require(previous == original) }
            else { try record.atomic(original, name: "journal.original.json", exclusive: true) }
            try require(fsync(parent.directory) == 0)
        } catch { close(opened); throw error }
        fd = opened; file = record
    }
    func append<T: Encodable>(_ value: T, name: String) throws {
        try file.atomic(JSONEncoder().encode(value), name: name, exclusive: true)
    }
    deinit { close(fd) }
}

struct RecoverySignalEvidence: Codable {
    let operationID: UUID
    let journalSHA256: String
    let caller: Caller
    let child: Child
    let parent: Int32
    let auditPIDVersion: UInt32
    let signal: Int32
    let at: String
    var delivered = false
    var exitObserved = false
    var rawExitStatus: Int32?
    var result = "durable_intent_no_retry"
    var appleServices = "unproven"
}

// Import only protected, operation/hash/identity-bound exit evidence from the
// previously authorized recovery gate. Never accepts a caller-supplied path.
enum ExternalRecoveryEvidence {
    static func matches(original: Data, operation: OperationRecord, intent: Data, result: Data) -> Bool {
        guard let child = operation.child,
              let a = try? JSONSerialization.jsonObject(with: intent) as? [String: Any],
              let b = try? JSONSerialization.jsonObject(with: result) as? [String: Any] else { return false }
        for value in [a, b] {
            guard value["operationID"] as? String == operation.id.uuidString,
                  value["originalJournalSHA256"] as? String == JournalFile.hash(original),
                  value["appStoreID"] as? String == operation.appStoreID,
                  value["pid"] as? Int32 == child.pid,
                  value["signal"] as? String == "SIGKILL",
                  let identity = value["identity"] as? [String: Any],
                  identity["boot"] as? String == child.bootSession,
                  identity["birthSeconds"] as? UInt64 == child.startSeconds,
                  identity["birthMicroseconds"] as? UInt64 == child.startMicroseconds,
                  identity["executable"] as? String == Contract.directory + "/" + Contract.executableName,
                  identity["sha256"] as? String == Contract.digest,
                  let version = identity["auditPIDVersion"] as? UInt32, version > 0,
                  let parent = value["helperPID"] as? Int32, parent > 0,
                  identity["ppid"] as? Int32 == parent,
                  value["taskNameResult"] as? Int == 0, value["auditTokenResult"] as? Int == 0,
                  value["exitObserverRegistered"] as? Bool == true else { return false }
        }
        guard let ai = a["identity"] as? NSDictionary, let bi = b["identity"] as? NSDictionary, ai == bi else { return false }
        return b["childExitObserved"] as? Bool == true && b["signalDelivered"] as? Bool == true && b["signalReturn"] as? Int == 0 && b["journalUnchanged"] as? Bool == true
    }
    static func exitObserved(parent: JournalFile, operation: OperationRecord, original: Data) throws -> Bool {
        let fd = openat(parent.directory, "recovery-evidence", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 { try require(errno == ENOENT); return false }
        defer { close(fd) }
        func secure(_ fd: Int32) throws {
            var info = stat(); try require(fstat(fd, &info) == 0 && info.st_uid == parent.owner && info.st_mode & 0o777 == 0o700)
            try requireNoACL(fd)
        }
        try secure(fd)
        guard let listing = fdopendir(dup(fd)) else { throw Failure.refused }
        defer { closedir(listing) }
        var count = 0
        while let entry = readdir(listing) {
            count += 1; try require(count < 512)
            let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            guard name.hasPrefix(operation.id.uuidString + "-") else { continue }
            let dir = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            try require(dir >= 0); defer { close(dir) }; try secure(dir)
            let evidence = JournalFile(dir, owner: parent.owner)
            guard try evidence.read("journal.original.json") == original,
                  let intent = try evidence.read("sigkill-intent.json"), let result = try evidence.read("sigkill-result.json") else { continue }
            if matches(original: original, operation: operation, intent: intent, result: result) { return true }
        }
        return false
    }
}

extension JournalFile {
    func reconcileNoMutation(operationID: UUID, original: Data, caller: Caller) throws {
        try require(try read("state.json") == original)
        guard var journal = try load(), journal.state == "unknown", let last = journal.operations.last else { throw Failure.refused }
        try require(last.id == operationID && last.caller.uid == caller.uid)
        try require(RecoveryPolicy.noMutationResolution(last, child: .exited))
        try require(journal.operations.allSatisfy { !$0.mutationMayHaveStarted })
        let prior = openat(directory, "recovery-" + operationID.uuidString, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        var archived = original
        if prior >= 0 {
            defer { close(prior) }
            archived = try JournalFile(prior, owner: owner).read("journal.original.json") ?? original
        } else { try require(errno == ENOENT) }
        let archive = try RecoveryArchive(parent: self, operation: operationID, original: archived)
        let decision = ["decision": "operator_reconciled_no_mutation", "operationID": operationID.uuidString,
                        "originalSHA256": Self.hash(original), "callerUID": String(caller.uid), "at": Journal.timestamp()]
        try archive.append(decision, name: "no-mutation-decision.json")
        journal.decisions = (journal.decisions ?? []) + [AdmissionDecision(source: operationID, attempt: operationID,
            decision: "operator_reconciled_no_mutation", at: Journal.timestamp())]
        journal.transition("operator_reconciled_no_mutation", reason: "explicit_review_proven_no_mutation_original_archived")
        // This dedicated transition is not available through ordinary save().
        try require(OwnedAdmission.reason(journal, boot: try Child.bootIdentity()) == nil)
        try atomic(JSONEncoder().encode(journal), name: "state.json")
    }
}

// Testable signal gate; injected closures exist only inside the helper process,
// never in XPC. Intent is durable and exclusive before the single signal attempt.
enum RecoveryCancellation {
    static func perform(file: JournalFile, archive: RecoveryArchive, original: Data,
                        evidence initial: RecoverySignalEvidence, revalidate: () throws -> Void,
                        send: () throws -> (Bool, Int32?)) throws -> RecoverySignalEvidence {
        let prefix = initial.signal == SIGTERM ? "sigterm" : "sigkill"
        try require(initial.signal == SIGTERM || initial.signal == SIGKILL)
        try require(initial.journalSHA256 == JournalFile.hash(original))
        if initial.signal == SIGKILL {
            guard let bytes = try archive.file.read("sigterm-result.json"),
                  let term = try? JSONDecoder().decode(RecoverySignalEvidence.self, from: bytes) else { throw Failure.refused }
            try require(term.operationID == initial.operationID && term.child == initial.child && term.auditPIDVersion == initial.auditPIDVersion)
            try require(term.delivered && !term.exitObserved && term.result == "timeout_no_retry")
        }
        try revalidate()
        try archive.append(initial, name: prefix + "-intent.json")
        var evidence = initial
        do {
            try require(try file.read("state.json") == original)
            try revalidate()
            let result = try send()
            evidence.delivered = true; evidence.exitObserved = result.0; evidence.rawExitStatus = result.1
            evidence.result = result.0 ? "owned_child_exit_observed_no_retry" : "timeout_no_retry"
        } catch {
            // false means delivery unconfirmed, not proof that no signal occurred.
            evidence.result = "signal_or_observation_uncertain_no_retry"
        }
        try archive.append(evidence, name: prefix + "-result.json")
        return evidence
    }
}

// Explicit operator action on the read-only diagnostic ledger only. A changed
// boot proves its OS processes ended, never completion of an install or Apple work.
extension JournalFile {
    func reconcileObservationAfterReboot(caller: Caller, boot: String) throws {
        guard let raw = try read("state.json"), var journal = try load() else { throw Failure.refused }
        try require(["unknown", "running", "launching"].contains(journal.state) && !journal.blockers.isEmpty)
        try require(journal.operations.allSatisfy { !$0.mutationMayHaveStarted && $0.type == "list" &&
            $0.caller.uid == caller.uid && $0.ownership != nil && $0.ownership!.bootIdentity != boot })
        let digest = Self.hash(raw)
        if let previous = try read("history-" + digest + ".json") { try require(previous == raw) }
        else { try atomic(raw, name: "history-" + digest + ".json", exclusive: true, mode: 0o400) }
        journal.archiveHead = digest; journal.schemaVersion = 4
        journal.decisions = (journal.decisions ?? []) + journal.blockers.map {
            AdmissionDecision(source: $0.id, attempt: $0.id, decision: "operator_reconciled_no_mutation", at: Journal.timestamp())
        }
        // Do not modify the attempts or their unknown outcomes.
        journal.state = "operator_reconciled_no_mutation"
        try atomic(JSONEncoder().encode(journal), name: "state.json")
    }
}
