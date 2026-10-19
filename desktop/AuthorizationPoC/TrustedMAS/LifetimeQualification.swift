import Foundation
import Darwin

extension Coordinator {
    func qualificationStatus(_ session: Session) -> String {
        guard session.valid() else { return "wrong_user_or_session" }
        guard operationLock.try() else { return "operation_busy" }; defer { operationLock.unlock() }
        do {
            // Read only: no legacy Store, no creation, no automatic recovery.
            let store = try Store(scope: .lifetimeQualification, create: false)
            guard let journal = try store.journalFile.load() else { return "invalid_qualification_state" }
            return "qualification_state=\(journal.state); operations=\(journal.operations.count); legacy_untouched; retry_requires_admission"
        } catch { return "qualification_state_unavailable" }
    }
    func qualifyVersion(_ session: Session) -> String {
        guard session.valid() else { return "wrong_user_or_session" }
        guard operationLock.try() else { return "operation_busy" }; defer { operationLock.unlock() }
        do {
            // Opens only protected MAS, never the legacy state.json or lock.
            _ = try Store(scope: .legacy, create: false).installed()
            let store = try Store(scope: .lifetimeQualification)
            return try store.journalFile.withExclusiveLock {
                if try OwnedExecution.recoverInterruptedOwner(file: store.journalFile) { return "qualification_unknown_no_retry" }
                guard var journal = try store.journalFile.load() else { return "qualification_unknown_no_retry" }
                let boot = try Child.bootIdentity()
                if let reason = OwnedAdmission.reason(journal, boot: boot) { return reason }
                session.lock.lock(); let admitted = session.valid() && !session.lost; session.lock.unlock()
                guard admitted, let account = getpwuid(session.uid) else { return "caller_unavailable" }
                let environment = ["PATH=/usr/bin:/bin:/usr/sbin:/sbin", "HOME=" + String(cString: account.pointee.pw_dir), "MAS_NO_AUTO_INDEX=1", "SUDO_UID=\(session.uid)", "SUDO_GID=\(session.gid)"]
                try journal.begin("version", id: nil, caller: session.caller)
                journal.operations[journal.operations.count - 1].ownership = OperationOwnership(bootIdentity: boot)
                journal.transition("launching", reason: "read_only_version_qualification_intent")
                try store.journalFile.save(journal)
                do {
                    let result = try OwnedExecution.run(file: store.journalFile, command: .qualificationVersion, role: "version", mutation: false, environment: environment, connected: {
                        session.lock.lock(); defer { session.lock.unlock() }; return session.valid() && !session.lost
                    }, resumeWhileAdmitted: { child in
                        session.lock.lock(); defer { session.lock.unlock() }
                        guard session.valid() && !session.lost else { throw LifetimeFault.disconnected }
                        try child.resume()
                    })
                    let version = String(data: result.1, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    try require(result.0 == 0 && ["7.0.0", "7.0.0+"].contains(version))
                    session.lock.lock(); defer { session.lock.unlock() }
                    try require(session.valid() && !session.lost)
                    journal = try store.journalFile.load()!
                    journal.transition("completed", reason: "read_only_version_exit_and_output_verified")
                    try store.journalFile.save(journal)
                    return "qualification_completed; euid=\(geteuid()); version=\(version!); operation=\(journal.operations.last!.id); legacy_untouched; app_store_context_unproven"
                } catch {
                    if var failed = try store.journalFile.load() {
                        failed.transition("unknown", reason: "version_qualification_uncertain_no_retry")
                        try store.journalFile.save(failed)
                    }
                    return "qualification_unknown_no_retry"
                }
            }
        } catch { return "qualification_storage_or_trust_refused_no_success_claim" }
    }
}
