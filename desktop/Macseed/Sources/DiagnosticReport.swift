import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Darwin

// The export schema is intentionally independent of the persistent sanitizer.
// No dictionaries, aliases, Core payloads or arbitrary text are serialized.
enum DiagnosticReportPrivacy {
    static let events: Set<String> = ["started", "phase_started", "phase_completed", "capture_category", "secure_packaging",
        "secure_publication_started", "execution_event", "operation_record", "verification_record", "coverage_record",
        "diagnostic_record", "result", "completed", "failed", "cancelled", "secret_required", "secret_accepted"]
    static let vocabularies: [String: Set<String>] = [
        "phase": ["discovery", "preparation", "validation", "publication", "bundle_creation", "bundle_validation", "bootstrap", "verification", "comparison", "secure_export", "secure_import", "preview", "execute", "readiness", "capture", "scope", "observation", "apply", "post_apply", "orchestration"],
        "domain": ["orchestration", "verification", "workspace", "workspace-folders", "git-repositories", "git-configuration", "homebrew-packages", "homebrew-casks", "app-store", "vscode-extensions", "vscode-settings", "shell-zsh", "ssh-configuration", "ssh-identities", "ssh-prerequisites", "secure-migration", "launcher", "macos-finder", "macos-dock", "macos-windows", "macos-keyboard", "macos-trackpad", "macos-screenshots"],
        "action": ["execute", "inspect", "install", "reinstall", "configure", "restore", "clone", "add_worktree", "switch_branch", "checkout", "verify", "compare", "skip", "noop", "import", "export", "create"],
        "state": ["started", "completed", "failed", "blocked", "conflict", "interrupted", "skipped", "running", "warning", "changed", "already_satisfied", "graceful_stop_accepted", "graceful_stop_unavailable"],
        "status": ["complete", "partial", "not_run", "unavailable", "invalid", "truncated", "present", "absent", "unsupported", "observation_error", "satisfied", "safely_satisfiable", "external_action_required", "not_selected", "completed", "failed", "cancelled"],
        "outcome": ["success", "failure", "warning", "skipped", "noop", "not_run", "cancelled"],
        "execution_status": ["not_started", "started", "completed", "failed", "cancelled"],
        "bootstrap_status": ["not_run", "success", "warning", "failure"],
        "verdict": ["selected_requirements_verified", "incomplete", "requirements_not_verified", "selected_requirements_not_verified", "differences_detected", "no_differences_detected", "no_comparable_requirements", "no_managed_requirements"],
        "conformity": ["verified", "mismatch", "unverified", "unsupported", "unresolved", "not_applicable"],
        "support": ["supported", "unsupported", "unresolved", "not_applicable"],
        "disposition": ["satisfied", "planned", "blocked", "unresolved", "selected", "excluded", "supported", "unsupported", "resolved", "no_requirement"],
        "source_status": ["present", "absent", "unavailable", "observation_error", "unsupported", "valid", "invalid", "observed_present", "observed_absent", "partial", "unobserved", "unknown"],
        "severity": ["info", "warning", "error"],
        "comparison_kind": ["matching", "missing", "differing", "unverified", "unsupported", "unresolved", "extra", "unknown_difference"],
        "predicate": ["exists", "installed", "configured", "matching", "repository", "branch", "remote", "identity", "settings", "folder_exists", "package_installed", "configuration_matches", "identity_pair_matches_package", "directory", "file_content", "stored_preference", "direct_global_value", "supported_config_match", "worktree", "origin", "revision"],
        "scope": ["operation", "item"],
        "tool": ["homebrew", "other"],
        "probe": ["version", "prefix", "inventory", "metadata", "capability", "read"],
        "primitive": ["payload", "metadata", "historical_metadata", "lifecycle", "requirements", "rosetta", "replacement", "launchctl", "login_item", "pkgutil"],
        "condition": ["provider_conflict", "ownership_unproven", "unsupported_capability", "observation_failed", "malformed_observation", "observation_limit", "ownership_ambiguous", "foreign_target", "conflicting_plist", "live_ownership_unproven", "identity_ambiguous", "authorization_required", "authorization_denied", "application_unavailable", "installation_required", "preparation_required"],
        "section": ["observation_diagnostics", "summary", "verification", "verification_details", "comparison", "records", "readiness", "operation_records", "verification_records", "coverage_records", "diagnostics", "module_outcomes", "operation_failures", "conditions", "inventory", "comparison_records", "plan"],
    ]
    static let reasons: Set<String> = Set(["git_clone_authentication_failed", "git_clone_host_key_failed", "git_clone_branch_unavailable", "git_clone_remote_unavailable", "git_clone_ssh_configuration_unavailable", "git_clone_failed", "git_clone_admission_failed", "git_clone_observation_failed", "git_clone_worker_interrupted", "git_clone_deadline", "git_clone_no_progress", "git_clone_quiescence_unconfirmed", "git_clone_state_failed", "external_observation_process", "external_observation_launch", "external_observation_failed", "external_observation_deadline", "external_observation_limit", "external_observation_worker", "external_observation_unquiescent", "external_observation_native", "cancelled", "secure_cancelled", "internal_error", "invalid_request", "unsupported_operation", "unsupported_protocol",
        "bundle_invalid", "bundle_unavailable", "unsupported_bundle", "recovery_required", "invalid_selection", "preview_failed", "stale_plan", "stale_prepared_capture",
        "publication_failed", "bootstrap_failed", "process_observation_unavailable", "privileged_lifecycle_unknown", "item_stalled_timeout", "item_install_failed",
        "progress_observation_failed", "observation_failed", "observation_error", "prerequisite_unmet", "unsupported_predicate", "confirmed_mismatch", "unknown_difference",
        "reference_changed", "reference_unavailable", "comparison_unavailable", "capture_failed", "capture_discovery_failed", "capture_inventory_invalid", "capture_validation_failed",
        "capture_source_unavailable", "invalid_workspace_selection", "workspace_dependency_missing", "workspace_path_conflict",
        "invalid_destination", "destination_exists", "destination_changed", "secure_bridge_required", "age_unavailable", "secure_bridge_unavailable", "secure_timeout",
        "secure_import_failed", "secure_export_failed", "secure_input_invalid", "invalid_secure_selection", "readiness_failed", "cask_authorization_required",
        "cask_execution_requirements_unsupported", "cask_target_conflict", "cask_rosetta_required", "rosetta", "installation_required", "cask_observation_failed", "cask_not_ready", "homebrew_unavailable", "homebrew_broken",
        "homebrew_platform_incompatible", "formula_dependency_unavailable", "dependency_unavailable", "unsupported_capability", "authorization_denied", "authorization_unavailable",
        "provider_conflict", "manual_installation_required", "launcher_destination_conflict", "launcher_inspection_failed", "launcher_install_failed", "launcher_verification_failed",
        "foreign_target", "conflicting_plist", "identity_ambiguous", "ownership_ambiguous", "live_ownership_unproven", "malformed_observation", "observation_limit",
        "ssh_configuration_not_ready", "ssh_configuration_observation_failed", "prerequisite_failed", "input_missing", "input_invalid", "unsupported", "not_selected", "redacted",
        "module_failed", "module_warning", "selected_input_unresolved", "operation_failed", "partial_source_coverage", "external_management", "input_changed", "network_reset", "unknown",
        "ready", "authorization_required", "unsupported_interactive_operation", "vscode_cli_required", "vscode_cli_unavailable", "vscode_cli_ambiguous",
        "git_required", "git_unavailable", "repository_target_conflict", "mas_required", "mas_unavailable", "age_required", "homebrew_installation_requires_interaction",
        "homebrew_capability_unavailable", "homebrew_metadata_incompatible", "cask_launchctl_observation_failed", "missing_required_dependency", "secure_bridge_required",
        "invalid_selected_input", "cask_metadata_unavailable", "cask_repair_not_supported", "internet_required", "command_line_tools_required"]).union(CoreRestorePreparation.workspacePreviewReasons.keys)
    static let countKeys: Set<String> = ["duration_ms", "native_exit_code", "native_signal", "warning_count", "error_count", "verified_count", "mismatch_count", "unverified_count", "unsupported_count", "unresolved_count",
        "selected_count", "selected_domains", "selected_items", "secure_identity_count", "matching", "missing", "differing", "unverified", "unsupported", "unresolved", "extra", "unknown_difference"]
    static let flagKeys: Set<String> = ["quiescent", "read_only", "publication_occurred", "target_mutation_may_have_started", "unknown_consequences", "independent_work_completed", "also_incomplete", "ready", "authorization_required"]

    static let runtimeReasons: Set<String> = ["runtime_unavailable", "invalid_runtime_configuration", "python_unavailable", "writable_core_required", "request_too_large", "launch_failed", "io_failed", "malformed_event", "incompatible_protocol", "operation_mismatch", "sequence_order", "invalid_lifecycle", "event_too_large", "incomplete_stream", "missing_terminal", "exit_mismatch", "interrupted"]
    static func code(_ value: String?, key: String) -> String? {
        guard let value, value.utf8.count <= 64 else { return nil }
        return (key == "reason" || key == "code") ? (reasons.contains(value) || runtimeReasons.contains(value) ? value : nil) : (vocabularies[key]?.contains(value) == true ? value : nil)
    }
    static func version(_ value: String?) -> String? {
        guard let value, value.utf8.count <= 32,
              value.range(of: "^[0-9]+(\\.[0-9]+){0,3}$", options: .regularExpression) != nil else { return nil }
        return value
    }
    static func facts(_ input: OperationLogFacts) -> OperationLogFacts {
        var output = OperationLogFacts()
        for key in Array(vocabularies.keys) + ["reason", "code"] {
            if let value = code(input.codes[key], key: key) { output.codes[key] = value }
        }
        for key in countKeys {
            if let count = input.counts[key], (0...1_000_000_000).contains(count) { output.counts[key] = count }
        }
        for key in flagKeys { output.flags[key] = input.flags[key] }
        // Even local anonymized identities are unnecessary for this report.
        return output
    }
    static func text(_ facts: OperationLogFacts) -> String {
        (facts.codes.keys.sorted().map { "\($0)=\(facts.codes[$0]!)" } +
         facts.counts.keys.sorted().map { "\($0)=\(facts.counts[$0]!)" } +
         facts.flags.keys.sorted().map { "\($0)=\(facts.flags[$0]! ? "true" : "false")" }).joined(separator: "; ")
    }
}

struct DiagnosticReportEnvironment: Sendable {
    let version: String?
    let build: String?
    let macOS: OperatingSystemVersion
    let architecture: String
    static func current() -> Self {
        var arm: Int32 = 0, size = MemoryLayout<Int32>.size
        let observed = sysctlbyname("hw.optional.arm64", &arm, &size, nil, 0) == 0
        let architecture: String
        if observed { architecture = arm == 1 ? "arm64" : "x86_64" }
        else {
            #if arch(arm64)
            architecture = "arm64"
            #elseif arch(x86_64)
            architecture = "x86_64"
            #else
            architecture = "Unknown"
            #endif
        }
        return Self(version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                    build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
                    macOS: ProcessInfo.processInfo.operatingSystemVersion, architecture: architecture)
    }
}

struct DiagnosticReportSnapshot: Sendable {
    let operationID: UUID // Store identity selected at opening, not current UI selection.
    let generatedAt: Date
    let utf8: Data
    var text: String { String(decoding: utf8, as: UTF8.self) }
    fileprivate init(operationID: UUID, generatedAt: Date, text: String) {
        self.operationID = operationID; self.generatedAt = generatedAt; utf8 = Data(text.utf8)
    }
}

// Streaming, bounded projection. Only a small summary and bounded chronology
// survive each page; source records are discarded after projection.
struct DiagnosticReportBuilder {
    static let maximumBytes = 256 * 1024
    static let maximumInputBytes: Int64 = 8 * 1024 * 1024
    private let id: UUID
    private let environment: DiagnosticReportEnvironment
    private let date: Date
    private var header: OperationLogRecord?
    private var finish: OperationLogRecord?
    private var verification = OperationLogFacts()
    private var execution = OperationLogFacts()
    private var diagnosticFlags: [String: Bool] = [:]
    private var reason: String?
    private var chronology = ""
    private var omittedLines = 0
    private var projectedOmissions = false
    var damaged = false
    var unavailable = false
    var truncated = false
    var incomplete = false
    var active = false
    var readLimit = false
    private let formatter: ISO8601DateFormatter = {
        let value = ISO8601DateFormatter(); value.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return value
    }()
    init(id: UUID, environment: DiagnosticReportEnvironment, date: Date = Date()) {
        self.id = id; self.environment = environment; self.date = date
    }
    private func timestamp(_ value: Date) -> String {
        let seconds = value.timeIntervalSince1970
        guard seconds.isFinite, (0...253402300799).contains(seconds) else { return "Unknown" }
        return formatter.string(from: value)
    }
    private mutating func append(_ line: String) {
        // Reserve 32 KiB for metadata, summaries and honest limitations.
        if chronology.utf8.count + line.utf8.count + 1 <= Self.maximumBytes - 32 * 1024 { chronology += line + "\n" }
        else { omittedLines += 1 }
    }
    mutating func receive(_ record: OperationLogRecord) {
        guard record.schema == 1 else { projectedOmissions = true; return }
        incomplete = incomplete || record.incomplete == true || record.omitted == true
        if record.kind == .header {
            guard record.storageID == id else { damaged = true; return }
            var safe = OperationLogRecord(.header, time: record.time)
            safe.operationID = record.operationID; safe.operation = record.operation
            safe.desktopVersion = DiagnosticReportPrivacy.version(record.desktopVersion)
            safe.desktopBuild = DiagnosticReportPrivacy.version(record.desktopBuild)
            safe.coreVersion = DiagnosticReportPrivacy.version(record.coreVersion)
            header = safe; return
        }
        if record.kind == .finish {
            var safe = OperationLogRecord(.finish, time: record.time)
            safe.exitCode = record.exitCode; safe.signalled = record.signalled; safe.signalNumber = record.signalNumber
            safe.terminalValid = record.terminalValid
            safe.eventType = ["completed", "failed", "cancelled"].contains(record.eventType ?? "") ? record.eventType : nil
            safe.runtimeError = DiagnosticReportPrivacy.code(record.runtimeError, key: "reason")
            safe.verificationStatus = DiagnosticReportPrivacy.code(record.verificationStatus, key: "status")
            safe.detailStatus = DiagnosticReportPrivacy.code(record.detailStatus, key: "status")
            finish = safe
            append("\(timestamp(record.time)) client finish; terminal_valid=\(record.terminalValid.map { $0 ? "true" : "false" } ?? "Unknown")")
            return
        }
        if record.kind == .client, let client = record.client {
            truncated = truncated || client == .truncated
            incomplete = incomplete || client == .eventSkipped || client == .truncated
            // Delivery/request evidence, never a claim of rollback or safe termination.
            append("\(timestamp(record.time)) client \(client.rawValue)"); return
        }
        guard record.kind == .event, let type = record.eventType, DiagnosticReportPrivacy.events.contains(type),
              let sequence = record.sequence, (1...1_000_000_000).contains(sequence) else { projectedOmissions = true; return }
        if ["result", "failed", "cancelled"].contains(type), let root = record.facts {
            // An item/Verification reason must never replace the process reason.
            reason = DiagnosticReportPrivacy.code(root.codes["reason"], key: "reason") ?? DiagnosticReportPrivacy.code(root.codes["code"], key: "code") ?? reason
        }
        append("\(timestamp(record.time)) Core #\(sequence) \(type)")
        for input in [record.facts].compactMap({ $0 }) + Array((record.evidence ?? []).prefix(20)) {
            let safe = DiagnosticReportPrivacy.facts(input)
            projectedOmissions = projectedOmissions || safe.codes.count != input.codes.count || safe.counts.count != input.counts.count || safe.flags.count != input.flags.count || !input.references.isEmpty
            let section = safe.codes["section"]
            diagnosticFlags.merge(safe.flags) { _, new in new }
            if section == "verification" || type == "verification_record" {
                verification.codes.merge(safe.codes) { _, new in new }
                verification.counts.merge(safe.counts) { _, new in new }
            } else if section == "summary" { execution.counts.merge(safe.counts) { _, new in new } }
            let details = DiagnosticReportPrivacy.text(safe)
            if !details.isEmpty { append("  " + details) }
        }
        if (record.evidence?.count ?? 0) > 20 { projectedOmissions = true }
    }
    func snapshot() -> DiagnosticReportSnapshot {
        let valid = finish?.terminalValid == true
        let process: String
        if valid {
            switch finish?.eventType {
            case "completed": process = "Completed"
            case "cancelled": process = "Cancelled"
            case "failed": process = finish?.exitCode == 130 || ["cancelled", "secure_cancelled"].contains(finish?.runtimeError ?? "") ? "Cancelled" : "Failed"
            default: process = "Unknown"
            }
        } else { process = finish == nil && active && !unavailable ? "Running" : "Unknown" }
        var lines = ["Macseed Diagnostic Report", "Report schema: 1", "Generated: " + timestamp(date),
            "App version (report host): " + (DiagnosticReportPrivacy.version(environment.version) ?? "Unknown")]
        if let build = DiagnosticReportPrivacy.version(environment.build) { lines.append("App build (report host): " + build) }
        let os = environment.macOS
        if [os.majorVersion, os.minorVersion, os.patchVersion].allSatisfy({ (0...9999).contains($0) }) {
            lines.append("macOS (report host): \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
        }
        lines += ["Mac architecture: " + (["arm64", "x86_64"].contains(environment.architecture) ? environment.architecture : "Unknown"),
                  "", "Operation store ID: " + id.uuidString,
                  "Operation: " + (header?.operation.map { DiagnosticReportBuilder.operation($0) } ?? "Unknown")]
        if let value = header?.operationID { lines.append("Core operation ID: " + value.uuidString) }
        lines.append("Started: " + (header.map { timestamp($0.time) } ?? "Unknown"))
        lines.append("Finished: " + (finish.map { timestamp($0.time) } ?? "Unknown"))
        if let value = header?.desktopVersion { lines.append("App version (operation): " + value) }
        if let value = header?.desktopBuild { lines.append("App build (operation): " + value) }
        if let value = header?.coreVersion { lines.append("Core version (operation): " + value) }
        lines += ["", "Process Result: " + process, "Terminal validity: " + (finish?.terminalValid.map { $0 ? "Valid" : "Invalid" } ?? "Unknown")]
        if let value = finish?.exitCode { lines.append("Exit code: \(value)") }
        if let value = finish?.signalled { lines.append("Signalled: \(value ? "true" : "false")") }
        if let value = finish?.signalNumber { lines.append("Signal: \(value)") }
        if let value = finish?.runtimeError ?? reason { lines.append("Reason: " + value) }
        for key in diagnosticFlags.keys.sorted() { lines.append("\(key): \(diagnosticFlags[key]! ? "true" : "false")") }
        lines += ["", "Verification status: " + (finish?.verificationStatus ?? verification.codes["status"] ?? "Unknown"),
                  "Verification details completeness: " + (finish?.detailStatus ?? "Unknown")]
        if let value = verification.codes["verdict"] { lines.append("Verification verdict: " + value) }
        for key in verification.counts.keys.sorted() { lines.append("Verification \(key): \(verification.counts[key]!)") }
        for key in execution.counts.keys.sorted() { lines.append("Execution \(key): \(execution.counts[key]!)") }
        let logIncomplete = incomplete || damaged || unavailable || header == nil || finish == nil || !valid || readLimit
        lines += ["", "Log completeness: " + (logIncomplete ? "Incomplete" : "Complete"),
                  "Log availability: " + (unavailable ? "Unavailable" : "Available"),
                  "Log truncation: " + (truncated ? "Truncated" : "Not recorded"),
                  "Log damage: " + (damaged ? "Detected; only valid prefix included" : "Not detected")]
        if active && finish == nil { lines.append("Active snapshot: operation may continue; use Refresh Report explicitly.") }
        if finish == nil { lines.append("No finish record: successful completion is not established.") }
        if projectedOmissions { lines.append("Privacy projection: non-exportable fields omitted; object identities excluded.") }
        if incomplete { lines.append("Saved diagnostics include omissions or incomplete evidence.") }
        if readLimit { lines.append("Report input limit reached; later saved records may not be included.") }
        if omittedLines > 0 { lines.append("Report chronology capped: \(omittedLines) lines omitted; this is separate from log truncation.") }
        lines += ["", "Chronology (UTC client receipt times; Core sequences only on Core events)", chronology,
                  "Source: Desktop Operation Log only. No Core/CLI technical logs, payloads or raw process output."]
        return DiagnosticReportSnapshot(operationID: id, generatedAt: date, text: lines.joined(separator: "\n") + "\n")
    }
    private static func operation(_ value: CoreOperation) -> String {
        switch value {
        case .capturePrepare: return "Capture / Prepare"
        case .captureExecute: return "Capture / Execute"
        case .bundleInspect: return "Restore / Inspect"
        case .restorePrepare: return "Restore / Prepare"
        case .restoreExecute: return "Restore / Execute"
        case .environmentCompare: return "Compare / Environment Status"
        case .capabilities: return "Capabilities"
        }
    }
    static func generate(id: UUID, environment: DiagnosticReportEnvironment,
        read: @Sendable (UUID, OperationLogCursor?) async throws -> OperationLogPage) async throws -> DiagnosticReportSnapshot {
        var builder = Self(id: id, environment: environment)
        var cursor: OperationLogCursor?
        for _ in 0..<4096 {
            try Task.checkCancellation()
            do {
                let page = try await read(id, cursor)
                builder.active = page.active; builder.damaged = builder.damaged || page.damaged
                for record in page.records { builder.receive(record) }
                let progressed = page.cursor.offset > (cursor?.offset ?? 0)
                cursor = page.cursor
                if page.atEnd || page.damaged || !progressed { return builder.snapshot() }
                if page.cursor.offset >= maximumInputBytes { builder.readLimit = true; return builder.snapshot() }
            } catch is CancellationError { throw CancellationError() }
            catch { builder.unavailable = true; return builder.snapshot() }
        }
        builder.readLimit = true; return builder.snapshot()
    }
}

@MainActor final class DiagnosticReportModel: ObservableObject {
    @Published private(set) var snapshot: DiagnosticReportSnapshot?
    @Published private(set) var loading = false
    @Published private(set) var saving = false
    @Published private(set) var saveFailed = false
    private let id: UUID
    private let environment: DiagnosticReportEnvironment
    private let read: @Sendable (UUID, OperationLogCursor?) async throws -> OperationLogPage
    private var worker: Task<DiagnosticReportSnapshot, Error>?
    private var epoch = UUID()
    init(id: UUID, store: OperationLogStore?, environment: DiagnosticReportEnvironment = .current(),
         read: (@Sendable (UUID, OperationLogCursor?) async throws -> OperationLogPage)? = nil) {
        self.id = id; self.environment = environment
        self.read = read ?? { id, cursor in
            guard let store else { throw OperationLogError.storageUnavailable }
            return try await store.page(id, after: cursor)
        }
    }
    func refresh() async {
        guard !saving else { return }
        worker?.cancel(); let token = UUID(); epoch = token; loading = true
        let id = id, environment = environment, read = read
        let task = Task.detached(priority: .utility) { try await DiagnosticReportBuilder.generate(id: id, environment: environment, read: read) }
        worker = task
        do {
            let result = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
            guard epoch == token, !Task.isCancelled else { return }
            snapshot = result; loading = false; worker = nil
        } catch { if epoch == token { loading = false; worker = nil } }
    }
    func close() { epoch = UUID(); worker?.cancel(); worker = nil; loading = false }
    @discardableResult func copy(to pasteboard: NSPasteboard = .general) -> Bool {
        guard let snapshot else { return false }
        pasteboard.clearContents(); return pasteboard.setData(snapshot.utf8, forType: .string)
    }
    func save(to destination: URL?) async {
        guard let destination, let snapshot, !saving, !loading else { return } // Panel cancellation writes nothing.
        saving = true; saveFailed = false
        let bytes = snapshot.utf8
        do { try await Task.detached(priority: .utility) { try bytes.write(to: destination, options: .atomic) }.value }
        catch { saveFailed = true }
        saving = false
    }
    func presentSavePanel() async {
        guard snapshot != nil, !saving, !loading else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.plainText]; panel.allowsOtherFileTypes = false
        panel.nameFieldStringValue = "Macseed-Diagnostic-Report.txt"
        // Freeze report refresh while the standard asynchronous panel is open.
        saving = true
        let response = await withCheckedContinuation { continuation in
            panel.begin { continuation.resume(returning: $0) }
        }
        saving = false
        if response == .OK { await save(to: panel.url) }
    }
}

// TextKit owns layout/selection in a fixed scroll viewport, never SwiftUI Text
// sized to the full report. Re-layout happens only on explicit snapshot replacement.
struct DiagnosticReportText: NSViewRepresentable {
    let utf8: Data
    final class Coordinator { var bytes: Data? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = false
        scroll.borderType = .bezelBorder
        let text = NSTextView(frame: scroll.contentView.bounds)
        text.isEditable = false; text.isSelectable = true; text.isRichText = false
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.autoresizingMask = [.width]; text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: .greatestFiniteMagnitude)
        text.textContainerInset = NSSize(width: 8, height: 8)
        scroll.documentView = text; return scroll
    }
    func updateNSView(_ view: NSScrollView, context: Context) {
        guard let text = view.documentView as? NSTextView else { return }
        guard context.coordinator.bytes != utf8 else { return }
        context.coordinator.bytes = utf8
        let value = String(decoding: utf8, as: UTF8.self)
        if text.string != value { text.string = value; view.contentView.scroll(to: .zero) }
    }
}

struct DiagnosticReportView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: DiagnosticReportModel
    init(id: UUID, store: OperationLogStore?) { _model = StateObject(wrappedValue: DiagnosticReportModel(id: id, store: store)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Diagnostic Report").font(.headline)
            if model.loading { ProgressView("Preparing report…") }
            if let snapshot = model.snapshot { DiagnosticReportText(utf8: snapshot.utf8).frame(maxWidth: .infinity, maxHeight: .infinity) }
            if model.saveFailed { Text("Report could not be saved. The snapshot remains available.").foregroundStyle(.red).font(.callout) }
            HStack {
                Button("Refresh Report") { Task { await model.refresh() } }.disabled(model.loading || model.saving)
                Spacer()
                Button("Copy Report") { model.copy() }.disabled(model.snapshot == nil || model.loading)
                Button("Save Report…") { Task { await model.presentSavePanel() } }.disabled(model.snapshot == nil || model.saving || model.loading)
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }.padding(20).frame(minWidth: 640, idealWidth: 720, minHeight: 440, idealHeight: 520)
        .task { await model.refresh() }
        .onDisappear { model.close() }
    }
}
