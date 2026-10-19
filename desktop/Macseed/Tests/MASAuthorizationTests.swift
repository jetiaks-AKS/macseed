import Foundation
import ServiceManagement

@main enum MASAuthorizationTests {
    @MainActor static func main() async {
        var status = SMAppService.Status.notRegistered
        var registrations = 0; var settings = 0; var probes = 0
        let result = await MASAuthorization.prepare(status: { status }, register: {
            registrations += 1; status = .requiresApproval
        }, settings: { settings += 1 }, readiness: { probes += 1; return nil }, attempts: 4,
        pause: { status = .enabled })
        precondition(result == nil && registrations == 1 && settings == 1 && probes == 1)
        _ = await MASAuthorization.prepare(status: { .enabled }, register: { registrations += 1 },
            settings: { settings += 1 }, readiness: { nil })
        precondition(registrations == 1 && settings == 1)
        let pending = await MASAuthorization.prepare(status: { .requiresApproval }, register: { preconditionFailure() },
            settings: {}, readiness: { preconditionFailure() }, attempts: 2, pause: {})
        precondition(pending?.contains("Approval is still pending") == true)
        enum Refused: Error { case denied }
        let denied = await MASAuthorization.prepare(status: { .notRegistered }, register: { throw Refused.denied },
            settings: {}, readiness: { preconditionFailure() })
        precondition(denied?.contains("No installation started") == true)
        var n = 0
        let disabled = await MASAuthorization.prepare(status: { n += 1; return n == 1 ? .requiresApproval : .notRegistered },
            register: { preconditionFailure() }, settings: {}, readiness: { preconditionFailure() })
        precondition(disabled?.contains("declined or disabled") == true)
        let cancelled = Task { @MainActor in
            await MASAuthorization.prepare(status: { .requiresApproval }, register: { preconditionFailure() },
                settings: {}, readiness: { preconditionFailure() }, pause: { throw CancellationError() })
        }
        let cancelledResult = await cancelled.value
        precondition(cancelledResult != nil)
        precondition(MASAuthorization.readinessProblem("v2:ready") == nil)
        precondition(MASAuthorization.readinessProblem("v2:unavailable") == nil)
        for value in ["v2:unknown_no_retry", "v2:busy", "v2:session_refused", "v0:ready", "v1:ready", "unavailable"] {
            precondition(MASAuthorization.readinessProblem(value) != nil)
        }
        precondition(MASAuthorization.readinessProblem("v2:unknown_no_retry", recoveryOnly: true) == nil)
        precondition(MASAuthorization.readinessProblem("v2:unknown_no_retry") != nil)
        precondition(MASAuthorization.readinessProblem("v2:busy", recoveryOnly: true) != nil)
        var recovery = MASRecoveryReport(); recovery.journalState = "unknown"
        recovery.childState = "exit_observed"; recovery.installation = "inventory_bundle_receipt_match"
        precondition(MASRecoveryPresentation.guidance(recovery).contains("remain blocked"))
        precondition(MASRecoveryPresentation.installation(recovery.installation).contains("does not resolve"))
        precondition(MASRecoveryPresentation.child("replaced").contains("will not signal"))
        precondition(MASRecoveryPresentation.child("exiting").contains("wait"))
        recovery.retryAllowed = true
        precondition(MASRecoveryPresentation.guidance(recovery).contains("No installation will restart automatically"))
        print("PASS: registration once, native approval/continuation, ready fast path, decline, timeout, cancellation, version/session/unknown/busy fail-closed")
    }
}
