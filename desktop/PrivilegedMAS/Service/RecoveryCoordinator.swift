import Foundation
import Darwin

extension Coordinator {
    // Recovery never registers a service, installs an app or silently changes unknown.
    func recovery(_ id: String, action: String, confirmed: Bool, session: Session, reviewID: String = "", appStoreIDs: [String] = [], downloadsClear: Bool = false) -> MASRecoveryReport {
        var report = MASRecoveryReport()
        if action == "prepareUnregister" {
            report.reason = confirmed ? prepareUnregister(session) : "explicit_confirmation_required"
            return report
        }
        guard session.valid(), session.isDesktop else { report.reason = "session_or_desktop_identity_refused"; return report }
        guard ["status", "verify", "terminate", "forceTerminate", "reconcile", "acceptRetry", "acceptRemaining", "reconcileObservation"].contains(action),
              action == "status" || confirmed else { report.reason = "explicit_confirmation_required"; return report }
        guard lock.try() else { report.reason = "owned_operation_running_wait_for_stop_or_timeout"; return report }
        defer { lock.unlock() }
        guard !retiring else { report.reason = "helper_retiring_no_new_work"; return report }
        do {
            try protectedApp()
            let store = try Store(create: false)
            return try store.journalFile.withExclusiveLock {
                let file = store.journalFile
                if action != "status" { try file.checkpointHistory() }
                guard let raw = try file.read("state.json"), let journal = try file.load(),
                      let operation = id.isEmpty ? (journal.blockers.first ?? journal.operations.last) : journal.operations.first(where: { $0.id.uuidString == id }) else { return report }
                let boot = try Child.bootIdentity()
                let original = try recoveryOriginal(file: file, journal: journal, operation: operation, current: raw)
                try require(RecoveryPolicy.requestAllowed(id: id, action: action, confirmed: confirmed, operation: operation,
                    caller: session.caller, desktop: session.isDesktop, session: session.valid()))
                report.operationID = operation.id.uuidString; report.appStoreID = operation.appStoreID ?? ""
                report.journalState = journal.state
                report.reason = "apple_service_completion_evidence_required_no_retry"
                if journal.blockers.isEmpty {
                    report.retryAllowed = journal.permits(nil, caller: session.caller, boot: boot)
                    report.reason = report.retryAllowed ? "fresh_preview_required" : "historical_lifetime_unresolved"
                    return report
                }
                _ = try store.installed()
                let state = operation.child.map(RecoveryProcess.inspect) ?? .unproven
                let provenExit = try recordedExit(file: file, operation: operation, raw: original)
                report.childState = provenExit ? "exit_observed" : state.rawValue
                report.ownership = recoveryOwnership(operation, boot: boot)
                report.reason = report.ownership == "unproven" ? "ownership_gap_restart_mac_then_review" : "fresh_review_required"
                if let review = journal.reviews?.last(where: { $0.source == operation.id && $0.caller == session.caller && $0.boot == boot && $0.expires > Date() && $0.uptimeExpiration > ProcessInfo.processInfo.systemUptime && $0.operationSHA256 == operation.digest }) {
                    report.reviewID = review.id.uuidString; report.installation = review.installation
                    report.canAcceptRisk = report.ownership != "unproven" && review.appleServices != "possible_active_download" && ["verified_present", "absent_in_observed_scope"].contains(review.installation)
                }
                let grants = (journal.grants ?? []).filter { journal.eligibleGrant($0, caller: session.caller, boot: boot) }
                report.allowedAppStoreIDs = grants.flatMap { $0.entries.filter { !$0.consumed }.map(\.appStoreID) }
                report.retryAllowed = !report.allowedAppStoreIDs.isEmpty
                if report.retryAllowed { report.reason = "scoped_permission_refresh_preview_no_automatic_install" }
                report.canReconcile = RecoveryPolicy.noMutationResolution(operation, child: provenExit ? .exited : state)
                if let child = operation.child, state == .alive,
                   let metadata = try? RecoveryProcess.metadata(child),
                   RecoveryPolicy.cancellationAllowed(operation, child: state, parent: Int32(metadata.pbi_ppid), helper: getpid(), trusted: true, sessionValid: session.valid()) {
                    // Probe the actual process-bound capability; do not advertise PID-only cancellation.
                    if let _ = try? RecoveryProcess(child, expectedParent: getpid(), expectedVersion: nil) {
                        report.canTerminate = true
                    }
                }
                let existing = try recoveryDirectory(file: file, operation: operation.id)
                if existing >= 0 {
                    defer { close(existing) }
                    let previous = JournalFile(existing)
                    if let diagnostic = try previous.load(), ["unknown", "running", "launching"].contains(diagnostic.state) {
                        report.reason = "diagnostic_interruption_restart_mac_then_review"
                        report.canAcceptRisk = false; report.retryAllowed = false; report.canReconcile = false
                        report.canReconcileObservation = !diagnostic.operations.isEmpty && diagnostic.operations.allSatisfy {
                            !$0.mutationMayHaveStarted && $0.type == "list" && $0.ownership != nil && $0.ownership!.bootIdentity != boot
                        }
                    }
                    let termIntent = try previous.read("sigterm-intent.json")
                    let killIntent = try previous.read("sigkill-intent.json")
                    report.canForceTerminate = report.canTerminate && termIntent != nil && killIntent == nil
                    if let bytes = try previous.read("sigterm-result.json"), let result = try? JSONDecoder().decode(RecoverySignalEvidence.self, from: bytes) {
                        report.canForceTerminate = report.canForceTerminate && result.child == operation.child && result.delivered && !result.exitObserved && result.result == "timeout_no_retry"
                    } else { report.canForceTerminate = false }
                    report.canTerminate = report.canTerminate && termIntent == nil
                }
                if action == "status" { return report }
                let archive = try RecoveryArchive(parent: file, operation: operation.id, original: original)
                report.evidence = "recovery-" + operation.id.uuidString
                if action == "reconcileObservation" {
                    try require(report.canReconcileObservation)
                    try archive.file.withExclusiveLock { try archive.file.reconcileObservationAfterReboot(caller: session.caller, boot: boot) }
                    report.canReconcileObservation = false; report.reason = "read_only_observation_reconciled_check_installation_again"
                } else if action == "terminate" || action == "forceTerminate" {
                    try require(action == "terminate" ? report.canTerminate : report.canForceTerminate)
                    guard let child = operation.child else { throw Failure.refused }
                    let target = try RecoveryProcess(child, expectedParent: getpid(), expectedVersion: nil)
                    let signal: Int32 = action == "terminate" ? SIGTERM : SIGKILL
                    let initial = RecoverySignalEvidence(operationID: operation.id, journalSHA256: JournalFile.hash(raw), caller: session.caller,
                        child: child, parent: getpid(), auditPIDVersion: target.pidVersion, signal: signal, at: Journal.timestamp())
                    let evidence = try RecoveryCancellation.perform(file: file, archive: archive, original: raw, evidence: initial, revalidate: {
                        try require(session.valid()); try target.revalidate()
                    }, send: {
                        session.lock.lock(); defer { session.lock.unlock() }
                        try require(!session.lost && session.valid())
                        return try target.signalOnce(signal)
                    })
                    report.childState = evidence.exitObserved ? "exit_observed" : "unproven"
                    report.reason = evidence.result; report.canTerminate = false; report.canForceTerminate = false
                } else if action == "verify" || action == "acceptRetry" || action == "acceptRemaining" {
                    if action == "verify" {
                        var invalidated = try file.load()!; invalidated.reviews = nil
                        try file.save(invalidated) // Revoke stale review before a new observation can fail.
                    }
                    let observation = try recoveryInventory(archive: archive, store: store, session: session, id: report.appStoreID)
                    report.installation = observation.result; report.appleServices = observation.appleServices
                    report.signature = observation.signature; report.receipt = observation.receipt; report.completeness = observation.completeness
                    try archive.append(observation, name: "verification-" + UUID().uuidString + ".json")
                    var updated = try file.load()!
                    // Revalidate under the same global lock after read-only observation.
                    let ownership = recoveryOwnership(operation, boot: boot)
                    let safe = ownership != "unproven" && observation.appleServices != "possible_active_download" &&
                        ["verified_present", "absent_in_observed_scope"].contains(observation.result) && session.valid() && !session.lost
                    if action == "verify" {
                        let review = AdmissionReview(id: UUID(), source: operation.id, operationSHA256: operation.digest,
                            caller: session.caller, boot: boot, expires: Date().addingTimeInterval(600), ownership: ownership,
                            installation: observation.result, appleServices: observation.appleServices)
                        updated.reviews = [review]; try file.save(updated)
                        report.reviewID = review.id.uuidString; report.canAcceptRisk = safe
                        report.reason = safe ? "review_ready_residual_apple_service_risk" : ownership == "unproven" ? "ownership_gap_restart_mac_then_review" : "verification_or_active_download_blocks_retry"
                    } else {
                        try require(safe)
                        guard let review = UUID(uuidString: reviewID) else { throw Failure.refused }
                        let ids = action == "acceptRetry" ? [report.appStoreID] : appStoreIDs
                        try updated.issueGrant(reviewID: review, source: operation.id, ids: ids,
                            scope: action == "acceptRetry" ? "retry" : "remaining", caller: session.caller, boot: boot,
                            confirmed: confirmed, downloadsClear: downloadsClear)
                        try file.save(updated)
                        try archive.append(updated.grants!.last!, name: "admission-" + updated.grants!.last!.id.uuidString + ".json")
                        report.retryAllowed = true; report.allowedAppStoreIDs = ids; report.canAcceptRisk = false
                        report.reason = "scoped_permission_refresh_preview_no_automatic_install"
                    }
                } else if action == "reconcile" {
                    // Mutations stay blocked: neither inventory nor a user checkbox proves Apple-service completion.
                    if report.canReconcile {
                        try file.reconcileNoMutation(operationID: operation.id, original: raw, caller: session.caller)
                        report.journalState = "operator_reconciled_no_mutation"
                        report.retryAllowed = true; report.reason = "non_mutation_reconciled_refresh_preview"
                    } else { report.reason = "operator_review_recorded_apple_service_completion_still_unproven" }
                    try archive.append(RecoveryReviewEvidence(report: report, caller: session.caller, at: Journal.timestamp()), name: "operator-review-" + UUID().uuidString + ".json")
                }
                return report
            }
        } catch { report.reason = "recovery_identity_storage_or_observation_refused_no_retry"; report.retryAllowed = false; return report }
    }

    // Freeze admission under the same coordinator lock before native unregister.
    // Apple-service uncertainty is preserved; only direct owned work is checked.
    private func prepareUnregister(_ session: Session) -> String {
        guard session.valid(), session.isDesktop else { return "session_or_desktop_identity_refused" }
        guard lock.try() else { return "owned_operation_running_unregister_blocked" }
        defer { lock.unlock() }
        if retiring { return "unregister_admitted_no_new_work" }
        do {
            try protectedApp()
            var metadata = stat()
            if lstat(Contract.directory, &metadata) != 0 {
                try require(errno == ENOENT); retiring = true; return "unregister_admitted_no_new_work"
            }
            let store = try Store(create: false); let file = store.journalFile
            return try file.withExclusiveLock {
                guard let journal = try file.load() else { return "legacy_ownership_unproven_unregister_blocked" }
                let raw = try file.read("state.json") ?? Data()
                for operation in journal.operations {
                    guard let ownership = operation.ownership else { return "ownership_unproven_unregister_blocked" }
                    let original = try recoveryOriginal(file: file, journal: journal, operation: operation, current: raw)
                    for launch in ownership.launches {
                        if ownership.bootIdentity != (try Child.bootIdentity()) { continue }
                        guard let child = launch.child else { return "unbound_child_unregister_blocked" }
                        let state = RecoveryProcess.inspect(child)
                        guard ![.alive, .exiting, .unproven].contains(state) else { return "owned_child_active_or_unproven_unregister_blocked" }
                        if launch.exitStatus == nil {
                            guard child == operation.child, try recordedExit(file: file, operation: operation, raw: original) else {
                                return "owned_exit_evidence_missing_unregister_blocked"
                            }
                        }
                    }
                    let dir = try recoveryDirectory(file: file, operation: operation.id)
                    if dir >= 0 {
                        defer { close(dir) }
                        guard let diagnostic = try JournalFile(dir).load(),
                              OwnedAdmission.reason(diagnostic, boot: try Child.bootIdentity()) == nil else {
                            return "recovery_observation_unresolved_unregister_blocked"
                        }
                    }
                }
                retiring = true
                return "unregister_admitted_no_new_work"
            }
        } catch { return "ownership_observation_failed_unregister_blocked" }
    }

    func recoveryObservationsReady(file: JournalFile, journal: Journal, boot: String) throws -> Bool {
        for operation in journal.operations {
            let fd = try recoveryDirectory(file: file, operation: operation.id)
            if fd < 0 { continue }
            defer { close(fd) }
            guard let diagnostic = try JournalFile(fd).load(), OwnedAdmission.reason(diagnostic, boot: boot) == nil else { return false }
        }
        return true
    }

    private func recoveryDirectory(file: JournalFile, operation: UUID) throws -> Int32 {
        let fd = openat(file.directory, "recovery-" + operation.uuidString, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 { try require(errno == ENOENT); return -1 }
        do {
            var info = stat(); try require(fstat(fd, &info) == 0 && info.st_uid == 0 && info.st_mode & 0o777 == 0o700)
            try requireNoACL(fd); return fd
        } catch { close(fd); throw error }
    }

    private struct RecoveryReviewEvidence: Encodable { let report: MASRecoveryReport; let caller: Caller; let at: String }

    private func recordedExit(file: JournalFile, operation: OperationRecord, raw: Data) throws -> Bool {
        if let last = operation.ownership?.launches.last(where: { $0.child == operation.child && $0.child != nil }) {
            if last.child != nil, last.exitStatus != nil { return true }
            if let data = try file.read("child-exit-" + last.id.uuidString + ".json"),
               let evidence = try? JSONDecoder().decode(LateChildExitEvidence.self, from: data),
               evidence.operationID == operation.id, evidence.launchID == last.id, evidence.child == last.child { return true }
        }
        let fd = try recoveryDirectory(file: file, operation: operation.id)
        if fd >= 0 {
            defer { close(fd) }; let record = JournalFile(fd)
            for name in ["sigterm-result.json", "sigkill-result.json"] {
                if let bytes = try record.read(name), let result = try? JSONDecoder().decode(RecoverySignalEvidence.self, from: bytes),
                   result.operationID == operation.id, result.child == operation.child, result.journalSHA256 == JournalFile.hash(raw), result.exitObserved {
                    return true
                }
            }
        }
        return try ExternalRecoveryEvidence.exitObserved(parent: file, operation: operation, original: raw)
    }

    private func recoveryInventory(archive: RecoveryArchive, store: Store, session: Session, id: String) throws -> InstallationEvidence {
        try require(Contract.validID(id))
        let file = archive.file
        return try file.withExclusiveLock {
            try file.checkpointHistory()
            if try OwnedExecution.recoverInterruptedOwner(file: file) { throw Failure.refused }
            guard var journal = try file.load(), OwnedAdmission.reason(journal, boot: try Child.bootIdentity()) == nil else { throw Failure.refused }
            guard session.valid(), let account = getpwuid(session.uid) else { throw Failure.refused }
            try journal.begin("list", id: nil, caller: session.caller)
            journal.operations[journal.operations.count - 1].ownership = OperationOwnership(bootIdentity: try Child.bootIdentity())
            journal.transition("launching", reason: "recovery_read_only_inventory"); try file.save(journal)
            let environment = ["PATH=/usr/bin:/bin:/usr/sbin:/sbin", "HOME=" + String(cString: account.pointee.pw_dir), "SUDO_UID=\(session.uid)", "SUDO_GID=\(session.gid)", "MAS_NO_AUTO_INDEX=1"]
            let result = try OwnedExecution.run(file: file, command: .inventory, role: "inventory", mutation: false, environment: environment, connected: {
                session.lock.lock(); defer { session.lock.unlock() }; return !session.lost && session.valid()
            })
            journal = try file.load()!
            journal.transition("completed", reason: "read_only_inventory_child_exited"); try file.save(journal)
            try require(result.0 == 0)
            return try MASInventory.inspect(result.1, id: id, home: String(cString: account.pointee.pw_dir))
        }
    }

    // No global PID scan. A reboot closes OS process lifetime, not Apple queues.
    func recoveryOwnership(_ operation: OperationRecord, boot: String) -> String {
        RecoveryPolicy.ownership(operation, boot: boot)
    }

    private func recoveryOriginal(file: JournalFile, journal: Journal, operation: OperationRecord, current: Data) throws -> Data {
        let dir = try recoveryDirectory(file: file, operation: operation.id)
        if dir >= 0 {
            defer { close(dir) }
            guard let raw = try JournalFile(dir).read("journal.original.json") else { throw Failure.refused }
            return raw
        }
        if let digest = journal.migrationSHA256, let raw = try file.read("history-" + digest + ".json") {
            try require(JournalFile.hash(raw) == digest)
            if let old = try JSONDecoder().decode(Journal.self, from: raw).operations.first(where: { $0.id == operation.id }), old.digest == operation.digest { return raw }
        }
        return current
    }
}
