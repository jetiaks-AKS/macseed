import AppKit
import ServiceManagement
import Security
import Darwin


@MainActor enum MASAuthorization {
    static let helper = "org.macseed.desktop.mas-helper"
    static let installedApp = "/Library/Application Support/MacseedDesktop/Macseed.app"
    #if DEBUG
    static var developmentStatus: String {
        "Native registration status=\(SMAppService.daemon(plistName: helper + ".plist").status.rawValue)"
    }
    static func developmentUnregister() async -> String {
        guard Bundle.main.bundlePath == installedApp else { return "Open the protected installed app first." }
        guard !CoreRuntime.shared.isActive else { return "Finish the active operation first. No registration changed." }
        let admission = await recovery(action: "prepareUnregister", confirmed: true)
        guard admission.reason == "unregister_admitted_no_new_work" else {
            return "Unregister blocked: " + admission.reason + ". No journals changed."
        }
        do {
            try await SMAppService.daemon(plistName: helper + ".plist").unregister()
            return developmentStatus + "; operation journals preserved"
        } catch { return "Unregister failed; preserve deployment and journals." }
    }
    #endif
    static func deploymentProblem() -> String? {
        guard Bundle.main.bundlePath == installedApp else {
            return "App Store Restore requires the signed Macseed app in its protected installation location. See the MAS integration instructions; no helper was registered."
        }
        // The helper must never be registered from the user-writable checkout.
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return "Protected Macseed installation could not be inspected." }
        defer { close(fd) }
        for component in ["Library", "Application Support", "MacseedDesktop", "Macseed.app", "Contents", "MacOS"] {
            let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { return "Protected Macseed installation is unavailable." }
            close(fd); fd = next
            var metadata = stat()
            guard fstat(fd, &metadata) == 0, metadata.st_uid == 0, metadata.st_mode & 0o022 == 0 else {
                return "Macseed installation must be owned by root and protected against modification before App Store authorization."
            }
            if let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) {
                defer { acl_free(UnsafeMutableRawPointer(acl)) }
                var entry: acl_entry_t?; errno = 0
                guard acl_valid(acl) == 0, acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry) == -1, errno == EINVAL else { return "Macseed installation has unqualified access permissions." }
            } else if errno != ENOENT { return "Macseed permissions could not be inspected." }
        }
        return nil
    }

    static func ensureAvailable() async -> String? {
        if let problem = deploymentProblem() { return problem }
        let service = SMAppService.daemon(plistName: helper + ".plist")
        return await prepare(
            status: { service.status }, register: { try service.register() },
            settings: { SMAppService.openSystemSettingsLoginItems() },
            readiness: { await authenticatedReadiness() })
    }

    // Injectable native boundary: tests never register a service or run MAS.
    static func prepare(status: () -> SMAppService.Status, register: () throws -> Void,
                        settings: () -> Void, readiness: () async -> String?,
                        attempts: Int = 240, pause: () async throws -> Void = {
                            try await Task.sleep(for: .milliseconds(500))
                        }) async -> String? {
        do {
            try Task.checkCancellation()
            switch status() {
            case .notRegistered, .notFound: try register()
            case .enabled, .requiresApproval: break
            @unknown default: return "App Store helper status is unavailable. Restart Macseed and refresh Preview. No installation started."
            }
            var openedSettings = false
            for _ in 0..<attempts {
                try Task.checkCancellation()
                switch status() {
                case .enabled: return await readiness()
                case .requiresApproval:
                    if !openedSettings { settings(); openedSettings = true }
                case .notRegistered:
                    return "App Store authorization was declined or disabled. No installation started. Refresh Preview and choose Rebuild when ready."
                case .notFound:
                    return "The installed App Store helper is unavailable. Quit Macseed and update the protected installation, then reopen it and refresh Preview. No installation started."
                @unknown default: return "App Store helper status could not be confirmed. No installation started."
                }
                try await pause()
            }
            return "Approval is still pending. In macOS System Settings → General → Login Items & Extensions, allow the Macseed background helper. If macOS requests a restart, restart first. Then refresh Preview and choose Rebuild; no installation has started."
        } catch is CancellationError { return "Authorization cancelled. No installation started." }
        catch { return "macOS did not authorize the App Store helper. Allow Macseed in System Settings → General → Login Items & Extensions, then refresh Preview and choose Rebuild. No installation started." }
    }

    static func authenticatedReadiness(recoveryOnly: Bool = false) async -> String? {
        let connection = NSXPCConnection(machServiceName: helper, options: .privileged)
        connection.setCodeSigningRequirement("anchor apple generic and identifier \"org.macseed.desktop.mas-helper\" and certificate leaf = H\"E898826915F0BFAD30789097118EDBBF619BC07E\"")
        connection.remoteObjectInterface = NSXPCInterface(with: MASServiceProtocol.self)
        // A bounded main-actor wait; no registration retry or mutation here.
        final class Reply: @unchecked Sendable {
            let lock = NSLock(); var value: String?
            func set(_ value: String) { lock.lock(); defer { lock.unlock() }; if self.value == nil { self.value = value } }
            func get() -> String? { lock.lock(); defer { lock.unlock() }; return value }
        }
        let reply = Reply()
        connection.invalidationHandler = { reply.set("unavailable") }
        connection.interruptionHandler = { reply.set("unavailable") }
        connection.resume()
        defer { connection.invalidate() }
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in reply.set("unavailable") } as? MASServiceProtocol
        proxy?.readiness { reply.set($0) }
        for _ in 0..<100 {
            if Task.isCancelled { return "Authorization cancelled. No installation started." }
            if let value = reply.get() { return readinessProblem(value, recoveryOnly: recoveryOnly) }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return readinessProblem("unavailable")
    }

    static func readinessProblem(_ reply: String, recoveryOnly: Bool = false) -> String? {
        if recoveryOnly && reply == "v2:unknown_no_retry" { return nil }
        switch reply {
        case "v2:ready", "v2:unavailable": return nil // authenticated absence of first journal
        case "v2:unknown_no_retry": return "A previous App Store operation is unresolved. Retry is blocked. Open App Store Recovery in Restore to inspect or cancel the owned child and review evidence. No new installation started."
        case "v2:busy": return "The App Store helper is busy. Wait for the existing operation, then refresh Preview. No new installation started."
        default: return "The App Store helper could not confirm a compatible connection and user session. Quit and reopen the updated protected Macseed; restart macOS if requested, then refresh Preview. No installation started."
        }
    }
}

extension MASAuthorization {
    // Explicit recovery preparation uses the existing native approval flow.
    // Unknown is accepted only for inspection/recovery, never for install readiness.
    static func enableRecovery() async -> String? {
        if let problem = deploymentProblem() { return problem }
        let service = SMAppService.daemon(plistName: helper + ".plist")
        return await prepare(status: { service.status }, register: { try service.register() },
            settings: { SMAppService.openSystemSettingsLoginItems() },
            readiness: { await authenticatedReadiness(recoveryOnly: true) })
    }

    static func recovery(operationID: String = "", action: String = "status", confirmed: Bool = false, reviewID: String = "", appStoreIDs: [String] = [], downloadsClear: Bool = false) async -> MASRecoveryReport {
        var unavailable = MASRecoveryReport()
        guard deploymentProblem() == nil else { unavailable.reason = "open_protected_installed_macseed"; return unavailable }
        guard SMAppService.daemon(plistName: helper + ".plist").status == .enabled else {
            unavailable.reason = "helper_not_enabled_recovery_does_not_register"; return unavailable
        }
        let connection = NSXPCConnection(machServiceName: helper, options: .privileged)
        connection.setCodeSigningRequirement("anchor apple generic and identifier \"org.macseed.desktop.mas-helper\" and certificate leaf = H\"E898826915F0BFAD30789097118EDBBF619BC07E\"")
        connection.remoteObjectInterface = NSXPCInterface(with: MASServiceProtocol.self)
        final class Reply: @unchecked Sendable {
            let lock = NSLock(); var value: String?
            func set(_ value: String) { lock.lock(); defer { lock.unlock() }; if self.value == nil { self.value = value } }
            func get() -> String? { lock.lock(); defer { lock.unlock() }; return value }
        }
        let reply = Reply()
        connection.interruptionHandler = { reply.set("") }; connection.invalidationHandler = { reply.set("") }
        connection.resume(); defer { connection.invalidate() }
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in reply.set("") } as? MASServiceProtocol
        proxy?.recovery(operationID, action: action, confirmed: confirmed, reviewID: reviewID, appStoreIDs: appStoreIDs, downloadsClear: downloadsClear) { reply.set($0) }
        for _ in 0..<800 {
            if Task.isCancelled { break }
            if let value = reply.get() {
                if let report = try? JSONDecoder().decode(MASRecoveryReport.self, from: Data(value.utf8)), report.version == 2 { return report }
                break
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        unavailable.reason = "recovery_reply_missing_preserve_unknown_refresh_status_no_retry"
        return unavailable
    }
}

enum MASRecoveryPresentation {
    static func child(_ value: String) -> String {
        switch value {
        case "exit_observed", "exited": return "The installation process has ended. Its installation result is checked separately."
        case "alive": return "The installation process is still running."
        case "exiting": return "The owned child has started exiting; wait for confirmed termination."
        case "absent": return "PID is absent; historical completion is not proven."
        case "replaced": return "PID was reused; Macseed will not signal its replacement."
        case "rebooted": return "The Mac restarted; Apple services may have resumed work."
        default: return "Owned child identity or completion is unproven."
        }
    }
    static func installation(_ value: String) -> String {
        switch value {
        case "verified_present": return "The app, its signature and signed App Store receipt were verified. This does not rewrite the interrupted attempt."
        case "absent_in_observed_scope": return "The app was not found in the observed inventory. No partial download was found in the checked application folders; private App Store queues remain unobservable."
        case "inventory_bundle_receipt_match": return "App Store ID, installed bundle and receipt presence match. This does not resolve the interrupted operation."
        case "inventory_bundle_receipt_mismatch": return "Inventory, bundle or receipt verification does not match."
        case "absent_from_inventory_incomplete_download_not_excluded": return "The app is absent from inventory. An incomplete download or unindexed bundle cannot be excluded."
        case "inventory_interrupted_no_retry": return "The read-only inventory check was interrupted. Preserve its evidence; it will not be retried automatically."
        default: return "Installation result has not been verified."
        }
    }
    static func guidance(_ report: MASRecoveryReport) -> String {
        if report.retryAllowed { return "Recovery permits a fresh Preview for the approved apps only. No installation will restart automatically." }
        if report.reason == "diagnostic_interruption_restart_mac_then_review" { return report.canReconcileObservation ? "The Mac restarted after an interrupted read-only check. Resolve that check explicitly, then check the installation again. The installation's unknown history stays preserved." : "The previous read-only check was interrupted. Restart the Mac, then review and resolve that check before trying it again. No installation will restart." }
        if report.reason == "ownership_gap_restart_mac_then_review" { return "New App Store installations remain blocked. Restart the Mac, then check this operation again to close the previous process-lifetime gap. A restart does not prove App Store downloads have finished." }
        if report.canAcceptRisk { return "The installation result remains uncertain. Check App Store downloads before approving one attempt. Apple may still finish background work; permission expires in ten minutes and never retries automatically." }
        if report.canReconcile { return "All recorded children exited and no installation was authorized. Review the evidence to resolve this non-mutating attempt." }
        return "New App Store installations remain blocked. Check the installation and resolve any active process, download or incomplete verification before reviewing residual risk."
    }
}
