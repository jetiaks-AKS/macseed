import Foundation
import CoreFoundation
import Darwin

extension Store {
    func markUnknown(_ reason: String) throws {
        guard var journal = try journalFile.load() else { throw Failure.refused }
        journal.transition("unknown", reason: reason); try journalFile.save(journal)
    }
    func recordExit(_ pid: Int32, status: Int32, reason: String, role: String) throws {
        guard var journal = try journalFile.load(), !journal.operations.isEmpty else { throw Failure.refused }
        let operation = journal.operations.count - 1
        guard let index = journal.operations[operation].observedChildren.lastIndex(where: { $0.identity.pid == pid && $0.role == role }) else { throw Failure.refused }
        journal.operations[operation].observedChildren[index].exitStatus = status
        journal.operations[operation].observedChildren[index].terminationReason = reason
        if role == "install" || journal.operations[operation].exitStatus == nil { journal.operations[operation].exitStatus = status }
        journal.operations[operation].transitions.append(Transition(at: Journal.timestamp(), state: "running", reason: "child_exit_" + role))
        try journalFile.save(journal)
    }
    func recordChild(_ pid: Int32, role: String) throws {
        let child = try Child.observe(pid)
        guard var journal = try journalFile.load(), !journal.operations.isEmpty else { throw Failure.refused }
        journal.operations[journal.operations.count - 1].observedChildren.append(ChildObservation(role: role, identity: child, at: Journal.timestamp()))
        if role == "install" || journal.operations[journal.operations.count - 1].child == nil { journal.operations[journal.operations.count - 1].child = child }
        journal.operations[journal.operations.count - 1].transitions.append(Transition(at: Journal.timestamp(), state: "running", reason: "child_observed"))
        try journalFile.save(journal)
    }
}

// No shell or client-supplied executable/environment. This runner is private to
// the qualified fixed operations; it cannot run arbitrary commands.
enum ControlledRunner {
    static func invoke(_ arguments: [String], store: Store, session: Session, install: Bool) throws -> (Int32, Data) {
        try require(arguments == ["list", "--json"] || (install && arguments.count == 2 && arguments[0] == "install" && Contract.validID(arguments[1]) && Contract.installAllowlist.contains(arguments[1]) && Contract.liveInstallEnabled))
        // Root version qualified in v6; App Store mutation context is experimental.
        try require(Contract.suspendedMASLaunchQualified)
        _ = try Store(scope: .legacy, create: false).installed()
        guard let account = getpwuid(session.uid) else { throw Failure.refused }
        let environment = ["PATH=/usr/bin:/bin:/usr/sbin:/sbin", "HOME=" + String(cString: account.pointee.pw_dir), "MAS_NO_AUTO_INDEX=1", "SUDO_UID=\(session.uid)", "SUDO_GID=\(session.gid)"]
        return try OwnedExecution.run(file: store.journalFile, command: install ? .install(arguments[1]) : .inventory,
            role: install ? "install" : "inventory", mutation: install, environment: environment,
            connected: {
                session.lock.lock(); defer { session.lock.unlock() }
                return session.valid() && !session.lost
            }, resumeWhileAdmitted: { child in
                session.lock.lock(); defer { session.lock.unlock() }
                guard session.valid() && !session.lost else { throw LifetimeFault.disconnected }
                try child.resume()
            })
    }
    static func ids(_ bytes: Data) throws -> Set<String> {
        var result = Set<String>()
        for line in bytes.split(separator: 10) where !line.isEmpty {
            let object = try JSONSerialization.jsonObject(with: Data(line))
            let rows = (object as? [[String: Any]]) ?? (object as? [String: Any]).map { [$0] } ?? []
            try require(!rows.isEmpty)
            for row in rows {
                guard let id = row["adamID"] as? NSNumber else { throw Failure.refused }
                try require(CFGetTypeID(id) != CFBooleanGetTypeID() && Contract.validID(id.stringValue)); result.insert(id.stringValue)
            }
        }
        return result
    }
}

extension Coordinator {
    private func lockedStore<T>(_ body: (Store) throws -> T) throws -> T {
        let store = try Store(scope: .lifetimeQualification)
        return try store.journalFile.withExclusiveLock { try body(store) }
    }
    func reconcile(_ session: Session, acknowledged: Bool) -> String {
        guard session.valid() else { return "wrong_user_or_session" }
        guard acknowledged else { return "operator_acknowledgement_required" }
        guard operationLock.try() else { return "operation_busy" }; defer { operationLock.unlock() }
        do {
            return try lockedStore { store in
                guard try store.journalFile.read("state.json") == JournalFile.legacyBytes else { return "legacy_bytes_mismatch_no_reconciliation" }
                let evidence = try Data(contentsOf: URL(fileURLWithPath: Contract.evidencePath))
                guard JournalFile.hash(evidence) == Contract.legacyEvidenceSHA256 else { return "evidence_mismatch_legacy_preserved" }
                // Legacy has no ownership identity. A global scan cannot make
                // noActiveOwnedWork true; a separate residual-risk policy is needed.
                return "legacy_preserved_separate_operator_policy_required"
            }
        } catch { return "legacy_reconciliation_refused_history_preserved" }
    }
    func controlled(_ id: String, session: Session, preflightOnly: Bool, confirmed: Bool = false) -> String {
        if !preflightOnly {
            let decision = Contract.installDecision(id: id, confirmed: confirmed, present: false)
            guard decision == "admitted" else { return decision }
        }
        guard Contract.validID(id) else { return "invalid_app_store_id" }
        guard Contract.installAllowlist.contains(id) else { return "unqualified_app_store_id" }
        guard session.valid() else { return "wrong_user_or_session" }
        guard operationLock.try() else { return "operation_busy" }; defer { operationLock.unlock() }
        do {
            return try lockedStore { store in
                if try OwnedExecution.recoverInterruptedOwner(file: store.journalFile) { return "unknown_no_retry" }
                var journal = try store.journalFile.load()
                session.lock.lock(); let connected = !session.lost; session.lock.unlock()
                if let reason = InstallAdmission.reason(id: id, journal: journal, sessionValid: session.valid(), connected: connected, busy: false, executableTrusted: true) { return reason }
                _ = try Store(scope: .legacy, create: false).installed()
                if !preflightOnly && !Contract.liveInstallEnabled { return "live_install_disabled_separate_permission_required" }
                let boot = try Child.bootIdentity()
                if let reason = OwnedAdmission.reason(journal, boot: boot) { return reason }
                guard Contract.suspendedMASLaunchQualified else { return "suspended_mas_launch_requires_system_qualification" }
                try journal!.begin(preflightOnly ? "preflight" : "install", id: preflightOnly ? nil : id, caller: session.caller)
                journal!.operations[journal!.operations.count - 1].ownership = OperationOwnership(bootIdentity: boot)
                journal!.transition("launching", reason: "durable_owned_intent")
                try store.journalFile.save(journal!)
                do {
                    let observed = try ControlledRunner.invoke(["list", "--json"], store: store, session: session, install: false)
                    try require(observed.0 == 0)
                    let present = try ControlledRunner.ids(observed.1).contains(id)
                    journal = try store.journalFile.load()
                    if !preflightOnly && Contract.installDecision(id: id, confirmed: confirmed, present: present) == "admitted" {
                        // Durable admission BEFORE any potentially mutating spawn.
                        journal!.operations[journal!.operations.count - 1].mutationMayHaveStarted = true
                        journal!.transition("launching", reason: "mutation_launch_admitted")
                        try store.journalFile.save(journal!)
                        let installed = try ControlledRunner.invoke(["install", id], store: store, session: session, install: true)
                        journal = try store.journalFile.load()
                        journal!.operations[journal!.operations.count - 1].exitStatus = installed.0
                        try store.journalFile.save(journal!)
                        try require(installed.0 == 0)
                        let verified = try ControlledRunner.invoke(["list", "--json"], store: store, session: session, install: false)
                        try require(verified.0 == 0 && ControlledRunner.ids(verified.1).contains(id))
                        journal = try store.journalFile.load()
                    }
                    session.lock.lock(); defer { session.lock.unlock() }
                    try require(!session.lost && session.valid())
                    journal!.operations[journal!.operations.count - 1].verification = preflightOnly ? (present ? "already_present" : "absent") : "inventory_id_present"
                    if journal!.operations.last!.mutationMayHaveStarted {
                        journal!.transition("unknown", reason: "inventory_verified_apple_service_lifetime_unqualified")
                        try store.journalFile.save(journal!)
                        return "unknown_no_retry; inventory_verified; service_lifetime_unqualified"
                    }
                    journal!.transition("completed", reason: preflightOnly ? "dry_run_only" : "independent_inventory_verified")
                    try store.journalFile.save(journal!)
                    return preflightOnly ? "preflight_only; \(present ? "already_present_no_reinstall" : "absent_would_install"); no_mutation; gui_bootstrap_unproven" : "inventory_verified; no_apple_service_quiescence_claim"
                } catch {
                    if var uncertain = try store.journalFile.load() {
                        uncertain.transition("unknown", reason: "timeout_disconnect_observation_or_execution_failure")
                        try store.journalFile.save(uncertain)
                    }
                    return "unknown_no_retry"
                }
            }
        } catch { return "controlled_admission_or_journal_refused" }
    }
}
