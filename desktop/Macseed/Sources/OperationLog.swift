import Foundation
import CryptoKit
import Darwin

// Desktop-owned projections only. This never reads Core logs or serializes CoreJSON.
enum OperationLogStatus: String, Sendable { case inactive, recording, complete, incomplete, unavailable }
enum OperationLogClient: String, Codable, Sendable {
    case gracefulStopDelivered, gracefulStopDeliveryFailed, forceStopRequested
    case eventSkipped, truncated
}

struct OperationLogFacts: Codable, Equatable, Sendable {
    var codes: [String: String] = [:]
    var counts: [String: Int] = [:]
    var flags: [String: Bool] = [:]
    var references: [String: String] = [:]
}

struct OperationLogRecord: Codable, Sendable {
    enum Kind: String, Codable { case header, event, client, finish }
    let schema: Int
    let kind: Kind
    let time: Date // Client receipt time, never Core observation time.
    var storageID: UUID?
    var operationID: UUID?
    var operation: CoreOperation?
    var desktopVersion: String?
    var desktopBuild: String?
    var coreVersion: String?
    var sequence: Int?
    var eventType: String?
    var client: OperationLogClient?
    var facts: OperationLogFacts?
    var evidence: [OperationLogFacts]?
    var omitted: Bool?
    var exitCode: Int32?
    var signalNumber: Int32?
    var signalled: Bool?
    var terminalValid: Bool?
    var runtimeError: String?
    var verificationStatus: String?
    var detailStatus: String?
    var droppedEvents: Int?
    var incomplete: Bool?

    init(_ kind: Kind, time: Date = Date()) { schema = 1; self.kind = kind; self.time = time }
}

struct OperationLogRead: Sendable {
    let records: [OperationLogRecord]
    let damaged: Bool
    var incomplete: Bool { damaged || records.last?.kind != .finish || records.last?.incomplete == true || records.last?.terminalValid != true }
}

struct OperationLogHistory: Sendable {
    let id: UUID
    let header: OperationLogRecord
    let finish: OperationLogRecord?
    let incomplete: Bool
}

struct OperationLogLimits: Sendable {
    var fileBytes = 8 * 1024 * 1024
    var recordBytes = 16 * 1024
    var operations = 100
    var totalBytes = 64 * 1024 * 1024
    var retention: TimeInterval = 30 * 24 * 60 * 60
    var pendingBytes = 8 * 1024 * 1024
    var pendingRecords = 256
    var reserve: Int { 2 * recordBytes }
}

enum OperationLogError: Error { case unsafeStorage, storageUnavailable, invalidRecord }

struct OperationLogCursor: Sendable {
    var offset: Int64 = 0
    var device: dev_t = 0
    var inode: ino_t = 0
    var lastSequence = 0
    var headerSeen = false
    var finishSeen = false
}
struct OperationLogPage: Sendable {
    let header: OperationLogRecord?
    let records: [OperationLogRecord]
    let cursor: OperationLogCursor
    let atEnd: Bool
    let damaged: Bool
    let active: Bool
    let bytesRead: Int
}

struct OperationLogSanitizer {
    private let salt = UUID().uuidString
    private(set) var verificationStatus: String?
    private(set) var detailStatus: String?
    static let events: Set<String> = ["started", "phase_started", "phase_completed", "capture_category", "secure_packaging",
        "secure_publication_started", "execution_event", "operation_record", "verification_record", "coverage_record",
        "diagnostic_record", "result", "completed", "failed", "cancelled", "secret_required", "secret_accepted"]
    // Closed vocabularies: a token-shaped arbitrary string is still private data.
    static let vocabularies: [String: Set<String>] = [
        "phase": ["discovery", "preparation", "validation", "publication", "bundle_creation", "bundle_validation", "bootstrap", "verification", "comparison", "secure_export", "secure_import", "preview", "execute", "readiness", "capture", "scope", "observation", "apply", "post_apply", "orchestration"],
        "domain": ["orchestration", "verification", "workspace", "workspace-folders", "git-repositories", "vscode-workspaces", "git-configuration", "homebrew-packages", "homebrew-casks", "app-store", "vscode-extensions", "vscode-settings", "shell-zsh", "ssh-configuration", "ssh-identities", "ssh-prerequisites", "secure-migration", "launcher", "macos-finder", "macos-dock", "macos-windows", "macos-keyboard", "macos-trackpad", "macos-screenshots"],
        "action": ["execute", "inspect", "install", "reinstall", "configure", "restore", "clone", "create_workspace", "add_worktree", "switch_branch", "checkout", "verify", "compare", "skip", "noop", "import", "export", "create"],
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
        "predicate": ["exists", "installed", "configured", "matching", "repository", "branch", "remote", "identity", "settings", "folder_exists", "package_installed", "configuration_matches", "identity_pair_matches_package", "directory", "file_content", "stored_preference", "direct_global_value", "supported_config_match", "worktree", "origin", "revision", "topology", "folder_relationships"],
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

    static func version(_ value: String?) -> String? {
        guard let value, value.utf8.count <= 32,
              value.range(of: "^[0-9]+(\\.[0-9]+){0,3}$", options: .regularExpression) != nil else { return nil }
        return value
    }

    private func project(_ data: [String: CoreJSON], omitted: inout Bool) -> OperationLogFacts {
        var facts = OperationLogFacts()
        for (key, allowed) in Self.vocabularies {
            guard let value = data[key], value != .null else { continue }
            if let text = value.string, text.utf8.count <= 64, allowed.contains(text) { facts.codes[key] = text }
            else { omitted = true }
        }
        for key in ["code", "reason"] {
            guard let value = data[key], value != .null else { continue }
            if let text = value.string, text.utf8.count <= 64, Self.reasons.contains(text) { facts.codes[key] = text }
            else { omitted = true }
        }
        for key in Self.countKeys {
            guard let value = data[key] else { continue }
            if let number = value.integer, (0...1_000_000_000).contains(number) { facts.counts[key] = number }
            else { omitted = true }
        }
        for key in Self.flagKeys {
            guard let value = data[key] else { continue }
            if let flag = value.boolean { facts.flags[key] = flag } else { omitted = true }
        }
        for key in ["item_id", "record_id"] {
            guard let value = data[key], value != .null else { continue }
            if let text = value.string, !text.isEmpty, text.utf8.count <= 1024 {
                // Per-operation random salt is never persisted. No identity map exists.
                let digest = SHA256.hash(data: Data((salt + key + text).utf8))
                facts.references[key] = "anon-" + digest.prefix(12).map { String(format: "%02x", $0) }.joined()
            } else { omitted = true }
        }
        return facts
    }

    mutating func event(_ event: CoreEvent, at time: Date) -> OperationLogRecord {
        guard Self.events.contains(event.type), event.sequence > 0 else {
            var record = OperationLogRecord(.client, time: time); record.client = .eventSkipped; record.omitted = true
            return record
        }
        var record = OperationLogRecord(.event, time: time)
        record.sequence = event.sequence; record.eventType = event.type
        var omitted = false
        var data = event.data ?? [:]
        if data["phase"] == nil { data["phase"] = event.fields["phase"] }
        record.facts = project(data, omitted: &omitted)
        var evidence: [OperationLogFacts] = []
        // Preserve the first failing layer even when a large item inventory fills
        // the existing bounded result projection. No raw process text is read.
        if case .array(let rows) = data["observation_diagnostics"] {
            for row in rows.prefix(8) {
                if let object = row.object {
                    var facts = project(object, omitted: &omitted)
                    facts.codes["section"] = "observation_diagnostics"
                    evidence.append(facts)
                } else { omitted = true }
            }
            if rows.count > 8 { omitted = true }
        }
        if event.type == "verification_record" {
            verificationStatus = verificationStatus ?? "partial"; detailStatus = detailStatus ?? "partial"
        }
        // Walk only known containers at fixed depth. Never recursively dump a payload.
        let verification = data["verification"]?.object
        if let verification {
            verificationStatus = Self.vocabularies["status"]!.contains(verification["status"]?.string ?? "") ? verification["status"]?.string : nil
        }
        if let details = verification?["details"]?.object ?? data["records"]?.object {
            detailStatus = Self.vocabularies["status"]!.contains(details["status"]?.string ?? "") ? details["status"]?.string : nil
        }
        let summaries = [("summary", data["summary"]?.object), ("verification", verification), ("comparison", data["comparison"]?.object),
                         ("verification_details", verification?["details"]?.object), ("records", data["records"]?.object), ("readiness", data["readiness"]?.object)]
        for (section, object) in summaries {
            if let object {
                var facts = project(object, omitted: &omitted); facts.codes["section"] = section; evidence.append(facts)
            }
            if let counts = object?["counts"]?.object {
                var facts = project(counts, omitted: &omitted); facts.codes["section"] = section; evidence.append(facts)
            }
        }
        let containers = [data, verification?["details"]?.object ?? [:], data["records"]?.object ?? [:], data["readiness"]?.object ?? [:]]
        for container in containers {
            for key in ["operation_records", "verification_records", "coverage_records", "diagnostics", "module_outcomes", "operation_failures", "conditions", "inventory", "comparison_records", "plan"] {
                guard let value = container[key] else { continue }
                guard case .array(let rows) = value else { omitted = true; continue }
                let available = max(0, 20 - evidence.count)
                for row in rows.prefix(available) {
                    if let object = row.object {
                        var facts = project(object, omitted: &omitted)
                        if let diagnostic = object["diagnostic"]?.object {
                            let detail = project(diagnostic, omitted: &omitted)
                            for field in ["primitive", "condition"] { facts.codes[field] = detail.codes[field] }
                        }
                        facts.codes["section"] = key; evidence.append(facts)
                    } else { omitted = true }
                }
                if rows.count > available { omitted = true }
            }
        }
        record.evidence = evidence.isEmpty ? nil : evidence
        record.omitted = omitted
        return record
    }

    static func runtimeCode(_ error: CoreRuntimeError?) -> String? {
        guard let error else { return nil }
        switch error {
        case .coreFailure(let code): return reasons.contains(code) ? code : "redacted"
        case .runtimeUnavailable: return "runtime_unavailable"
        case .invalidRuntimeConfiguration: return "invalid_runtime_configuration"
        case .pythonUnavailable: return "python_unavailable"
        case .writableCoreRequired: return "writable_core_required"
        case .invalidRequest: return "invalid_request"
        case .requestTooLarge: return "request_too_large"
        case .secureBridgeUnavailable: return "secure_bridge_unavailable"
        case .launchFailed: return "launch_failed"
        case .ioFailed: return "io_failed"
        case .malformedEvent: return "malformed_event"
        case .incompatibleProtocol: return "incompatible_protocol"
        case .operationMismatch: return "operation_mismatch"
        case .sequenceOrder: return "sequence_order"
        case .invalidLifecycle: return "invalid_lifecycle"
        case .eventTooLarge: return "event_too_large"
        case .incompleteStream: return "incomplete_stream"
        case .missingTerminal: return "missing_terminal"
        case .exitMismatch: return "exit_mismatch"
        case .interrupted: return "interrupted"
        }
    }

    static func valid(_ record: OperationLogRecord) -> Bool {
        guard record.schema == 1, record.time.timeIntervalSince1970.isFinite,
              record.evidence?.count ?? 0 <= 20,
              record.droppedEvents == nil || record.droppedEvents! >= 0 else { return false }
        let runtimeCodes: Set<String> = ["runtime_unavailable", "invalid_runtime_configuration", "python_unavailable", "writable_core_required", "request_too_large", "launch_failed", "io_failed", "malformed_event", "incompatible_protocol", "operation_mismatch", "sequence_order", "invalid_lifecycle", "event_too_large", "incomplete_stream", "missing_terminal", "exit_mismatch", "interrupted"]
        guard record.runtimeError == nil || reasons.contains(record.runtimeError!) || runtimeCodes.contains(record.runtimeError!) else { return false }
        for facts in [record.facts].compactMap({ $0 }) + (record.evidence ?? []) {
            for (key, value) in facts.codes {
                guard value.utf8.count <= 64,
                      (vocabularies[key]?.contains(value) == true || (["code", "reason"].contains(key) && reasons.contains(value))) else { return false }
            }
            guard facts.counts.allSatisfy({ countKeys.contains($0.key) && (0...1_000_000_000).contains($0.value) }),
                  facts.flags.keys.allSatisfy({ flagKeys.contains($0) }),
                  facts.references.allSatisfy({ ["item_id", "record_id"].contains($0.key) && $0.value.range(of: "^anon-[0-9a-f]{24}$", options: .regularExpression) != nil }) else { return false }
        }
        guard [record.desktopVersion, record.desktopBuild, record.coreVersion].allSatisfy({ $0 == nil || version($0) != nil }),
              record.eventType == nil || events.contains(record.eventType!),
              [record.verificationStatus, record.detailStatus].allSatisfy({ $0 == nil || vocabularies["status"]!.contains($0!) }) else { return false }
        switch record.kind {
        case .header: return record.storageID != nil && record.operation != nil && record.sequence == nil
        case .event: return events.contains(record.eventType ?? "") && (record.sequence ?? 0) > 0
        case .client: return record.client != nil && record.sequence == nil
        case .finish: return record.terminalValid != nil && record.incomplete != nil && record.sequence == nil
        }
    }
}

// All filesystem work is serialized off MainActor; ingress is bounded before enqueue.
final class OperationLogStore: @unchecked Sendable {
    static let shared = OperationLogStore()
    let directory: URL
    let limits: OperationLogLimits
    fileprivate let queue = DispatchQueue(label: "org.macseed.desktop.operations", qos: .utility)
    fileprivate let now: @Sendable () -> Date
    private var directoryFD: Int32 = -1
    private var lockFD: Int32 = -1

    init(directory: URL? = nil, limits: OperationLogLimits = OperationLogLimits(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("org.macseed.desktop/Operations", isDirectory: true) ?? URL(fileURLWithPath: "/dev/null")
        self.limits = limits; self.now = now
    }
    deinit { if lockFD >= 0 { Darwin.close(lockFD) }; if directoryFD >= 0 { Darwin.close(directoryFD) } }

    func begin(_ request: CoreRequest, coreVersion: String?, onStatus: @escaping @Sendable (OperationLogStatus) -> Void = { _ in }) -> OperationLogSession {
        let session = OperationLogSession(store: self, request: request, coreVersion: coreVersion, onStatus: onStatus)
        queue.async { session.open() }
        return session
    }

    private func prepare() throws {
        if directoryFD >= 0 {
            var directoryAttributes = stat(), lockAttributes = stat(), namedLock = stat()
            guard fstat(directoryFD, &directoryAttributes) == 0, directoryAttributes.st_uid == getuid(),
                  directoryAttributes.st_mode & 0o777 == 0o700,
                  fstat(lockFD, &lockAttributes) == 0,
                  fstatat(directoryFD, ".store-lock", &namedLock, AT_SYMLINK_NOFOLLOW) == 0,
                  namedLock.st_ino == lockAttributes.st_ino, namedLock.st_dev == lockAttributes.st_dev else { throw OperationLogError.unsafeStorage }
            try checkFile(lockFD)
            return
        }
        guard directory.path.hasPrefix("/"), !directory.path.contains("\0"), limits.fileBytes > limits.reserve,
              limits.recordBytes >= 1024, limits.recordBytes <= 16 * 1024, limits.operations > 0,
              limits.operations <= 100, limits.fileBytes <= 8 * 1024 * 1024, limits.totalBytes <= 64 * 1024 * 1024 else { throw OperationLogError.unsafeStorage }
        var fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw OperationLogError.storageUnavailable }
        defer { if fd >= 0 { Darwin.close(fd) } }
        for component in directory.path.split(separator: "/") {
            let name = String(component)
            guard name != ".", name != ".." else { throw OperationLogError.unsafeStorage }
            var next = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0 && errno == ENOENT {
                if mkdirat(fd, name, 0o700) != 0 && errno != EEXIST { throw OperationLogError.storageUnavailable }
                next = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard next >= 0 else { throw OperationLogError.unsafeStorage }
            Darwin.close(fd); fd = next
            var attributes = stat()
            guard fstat(fd, &attributes) == 0, attributes.st_uid == getuid() || attributes.st_uid == 0 else { throw OperationLogError.unsafeStorage }
        }
        var attributes = stat()
        guard fstat(fd, &attributes) == 0, attributes.st_uid == getuid(), attributes.st_mode & 0o777 == 0o700 else { throw OperationLogError.unsafeStorage }
        let lock = openat(fd, ".store-lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw OperationLogError.unsafeStorage }
        do { try checkFile(lock) } catch { Darwin.close(lock); throw error }
        directoryFD = fd; lockFD = lock; fd = -1
    }

    func checkFile(_ fd: Int32) throws {
        var attributes = stat()
        guard fstat(fd, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFREG,
              attributes.st_uid == getuid(), attributes.st_nlink == 1, attributes.st_mode & 0o777 == 0o600 else { throw OperationLogError.unsafeStorage }
    }
    fileprivate func locked<T>(_ body: () throws -> T) throws -> T {
        try prepare()
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw OperationLogError.storageUnavailable }
        defer { flock(lockFD, LOCK_UN) }
        return try body()
    }
    fileprivate func create(_ id: UUID) throws -> Int32 {
        let fd = openat(directoryFD, id.uuidString + ".jsonl", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw OperationLogError.storageUnavailable }
        do {
            try checkFile(fd)
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw OperationLogError.storageUnavailable }
            return fd
        } catch { Darwin.close(fd); throw error }
    }
    fileprivate func attached(_ fd: Int32, id: UUID) throws {
        try checkFile(fd)
        var current = stat(), named = stat()
        guard fstat(fd, &current) == 0,
              fstatat(directoryFD, id.uuidString + ".jsonl", &named, AT_SYMLINK_NOFOLLOW) == 0,
              current.st_ino == named.st_ino, current.st_dev == named.st_dev else { throw OperationLogError.unsafeStorage }
    }

    private struct Entry {
        let id: UUID
        let fd: Int32
        let bytes: Int
        let date: Date
        let active: Bool
        let owned: Bool
    }
    // Unknown names/foreign content are never cleanup candidates. Active files are
    // protected by flock across store instances and application processes.
    private func entries() throws -> [Entry] {
        var result: [Entry] = []
        do {
            for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
                guard name.hasSuffix(".jsonl"), let id = UUID(uuidString: String(name.dropLast(6))), name == id.uuidString + ".jsonl" else { continue }
                let fd = openat(directoryFD, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard fd >= 0 else { throw OperationLogError.unsafeStorage }
                do {
                    try checkFile(fd)
                    var attributes = stat(); guard fstat(fd, &attributes) == 0 else { throw OperationLogError.storageUnavailable }
                    let active = flock(fd, LOCK_EX | LOCK_NB) != 0
                    let head = try readFile(fd, headerOnly: true)
                    guard let header = head.records.first, header.kind == .header, header.storageID == id else {
                        // Count unrecognizable files against storage caps, but
                        // never delete or return them as trusted operation history.
                        result.append(Entry(id: id, fd: fd, bytes: Int(attributes.st_size), date: .distantFuture, active: active, owned: false))
                        continue
                    }
                    result.append(Entry(id: id, fd: fd, bytes: Int(attributes.st_size), date: header.time, active: active, owned: true))
                } catch { Darwin.close(fd); throw error }
            }
            return result.sorted { $0.date < $1.date }
        } catch { result.forEach { Darwin.close($0.fd) }; throw error }
    }

    fileprivate func room(bytes: Int, creating: Bool = false, finishing: UUID? = nil) throws {
        let existing = try entries()
        defer { existing.forEach { Darwin.close($0.fd) } }
        var total = existing.reduce(0) { $0 + $1.bytes }
        var count = existing.count
        let reserved = existing.filter { $0.active && $0.id != finishing }.count * limits.reserve + (creating ? limits.reserve : 0)
        for entry in existing where !entry.active && entry.owned {
            if now().timeIntervalSince(entry.date) > limits.retention || count + (creating ? 1 : 0) > limits.operations || total + bytes + reserved > limits.totalBytes {
                try attached(entry.fd, id: entry.id)
                guard unlinkat(directoryFD, entry.id.uuidString + ".jsonl", 0) == 0 else { throw OperationLogError.storageUnavailable }
                total -= entry.bytes; count -= 1
            }
        }
        guard count + (creating ? 1 : 0) <= limits.operations, total + bytes + reserved <= limits.totalBytes else { throw OperationLogError.storageUnavailable }
    }

    private func readFile(_ fd: Int32, headerOnly: Bool = false) throws -> OperationLogRead {
        var attributes = stat()
        guard fstat(fd, &attributes) == 0, attributes.st_size >= 0, attributes.st_size <= limits.fileBytes else { throw OperationLogError.unsafeStorage }
        guard lseek(fd, 0, SEEK_SET) >= 0 else { throw OperationLogError.storageUnavailable }
        var buffer = Data(), records: [OperationLogRecord] = []
        var bytes = [UInt8](repeating: 0, count: headerOnly ? 1024 : 32 * 1024)
        var total = 0, lastSequence = 0
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        while true {
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count < 0 { if errno == EINTR { continue }; throw OperationLogError.storageUnavailable }
            if count == 0 { return OperationLogRead(records: records, damaged: !buffer.isEmpty) }
            total += count; guard total <= limits.fileBytes else { throw OperationLogError.unsafeStorage }
            buffer.append(contentsOf: bytes.prefix(count))
            while let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                guard line.count + 1 <= limits.recordBytes, let record = try? decoder.decode(OperationLogRecord.self, from: line),
                      OperationLogSanitizer.valid(record), records.last?.kind != .finish,
                      (records.isEmpty ? record.kind == .header : record.kind != .header) else { return OperationLogRead(records: records, damaged: true) }
                if record.kind == .event {
                    guard let sequence = record.sequence, sequence > lastSequence else { return OperationLogRead(records: records, damaged: true) }
                    lastSequence = sequence
                }
                records.append(record)
                if headerOnly { return OperationLogRead(records: records, damaged: false) }
            }
            if buffer.count > limits.recordBytes { return OperationLogRead(records: records, damaged: true) }
        }
    }

    func read(_ id: UUID) async throws -> OperationLogRead {
        try await withCheckedThrowingContinuation { continuation in queue.async {
            do {
                let value = try self.locked {
                    let fd = openat(self.directoryFD, id.uuidString + ".jsonl", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                    guard fd >= 0 else { throw OperationLogError.unsafeStorage }
                    defer { Darwin.close(fd) }; try self.checkFile(fd)
                    let value = try self.readFile(fd)
                    guard value.records.first?.storageID == id else { throw OperationLogError.invalidRecord }
                    return value
                }
                continuation.resume(returning: value)
            } catch { continuation.resume(throwing: error) }
        } }
    }
    func history() async throws -> [OperationLogHistory] {
        try await withCheckedThrowingContinuation { continuation in queue.async {
            do {
                let value = try self.locked {
                    try self.room(bytes: 0)
                    let entries = try self.entries(); defer { entries.forEach { Darwin.close($0.fd) } }
                    return try entries.reversed().filter(\.owned).map { entry in
                        let value = try self.readFile(entry.fd)
                        guard let header = value.records.first else { throw OperationLogError.invalidRecord }
                        return OperationLogHistory(id: entry.id, header: header, finish: value.records.last?.kind == .finish ? value.records.last : nil, incomplete: value.incomplete)
                    }
                }
                continuation.resume(returning: value)
            } catch { continuation.resume(throwing: error) }
        } }
    }

    // Reads only a bounded new byte range. An unfinished line remains behind the
    // cursor until its newline is published; inactive crash tails are explicit.
    func page(_ id: UUID, after previous: OperationLogCursor? = nil, tail: Bool = false) async throws -> OperationLogPage {
        try await withCheckedThrowingContinuation { continuation in queue.async {
            do {
                let page = try self.locked {
                    let fd = openat(self.directoryFD, id.uuidString + ".jsonl", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                    guard fd >= 0 else { throw OperationLogError.unsafeStorage }
                    defer { Darwin.close(fd) }; try self.checkFile(fd)
                    var attributes = stat()
                    guard fstat(fd, &attributes) == 0, attributes.st_size <= self.limits.fileBytes else { throw OperationLogError.unsafeStorage }
                    let active = flock(fd, LOCK_EX | LOCK_NB) != 0
                    var cursor = previous ?? OperationLogCursor()
                    var header: OperationLogRecord?
                    if previous != nil {
                        guard cursor.device == attributes.st_dev, cursor.inode == attributes.st_ino,
                              cursor.offset >= 0, cursor.offset <= attributes.st_size else { throw OperationLogError.unsafeStorage }
                    } else {
                        let value = try self.readFile(fd, headerOnly: true)
                        guard let first = value.records.first, first.storageID == id else { throw OperationLogError.invalidRecord }
                        header = first; cursor.device = attributes.st_dev; cursor.inode = attributes.st_ino
                        if tail && attributes.st_size > 32 * 1024 {
                            cursor.offset = attributes.st_size - 32 * 1024
                            var boundary = [UInt8](repeating: 0, count: self.limits.recordBytes)
                            let count = pread(fd, &boundary, boundary.count, cursor.offset)
                            guard count > 0, let newline = boundary.prefix(count).firstIndex(of: 10) else { throw OperationLogError.invalidRecord }
                            cursor.offset += Int64(newline + 1); cursor.headerSeen = true
                        }
                    }
                    var bytes = [UInt8](repeating: 0, count: 64 * 1024)
                    let readOffset = cursor.offset
                    let count = pread(fd, &bytes, bytes.count, readOffset)
                    guard count >= 0 else { throw OperationLogError.storageUnavailable }
                    let data = Data(bytes.prefix(count))
                    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
                    var records: [OperationLogRecord] = [], position = 0, damaged = false
                    while records.count < 128, let newline = data[position...].firstIndex(of: 10) {
                        let line = Data(data[position..<newline])
                        guard line.count + 1 <= self.limits.recordBytes,
                              let record = try? decoder.decode(OperationLogRecord.self, from: line), OperationLogSanitizer.valid(record),
                              !cursor.finishSeen, cursor.headerSeen ? record.kind != .header : record.kind == .header else { damaged = true; break }
                        if record.kind == .header {
                            guard record.storageID == id else { throw OperationLogError.invalidRecord }
                            cursor.headerSeen = true
                        }
                        if record.kind == .event {
                            guard let sequence = record.sequence, sequence > cursor.lastSequence else { damaged = true; break }
                            cursor.lastSequence = sequence
                        }
                        cursor.finishSeen = record.kind == .finish
                        records.append(record); position = newline + 1
                    }
                    cursor.offset += Int64(position)
                    let remaining = attributes.st_size - cursor.offset
                    if records.count < 128 && remaining > 0 &&
                        (count - position > self.limits.recordBytes || (!active && readOffset + Int64(count) == attributes.st_size)) { damaged = true }
                    return OperationLogPage(header: header, records: records, cursor: cursor,
                        atEnd: cursor.offset == attributes.st_size, damaged: damaged, active: active, bytesRead: count)
                }
                continuation.resume(returning: page)
            } catch { continuation.resume(throwing: error) }
        } }
    }

    func clearInactive() async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in queue.async {
            do {
                let count = try self.locked {
                    let entries = try self.entries(); defer { entries.forEach { Darwin.close($0.fd) } }
                    var count = 0
                    for entry in entries where entry.owned && !entry.active {
                        try self.attached(entry.fd, id: entry.id)
                        guard unlinkat(self.directoryFD, entry.id.uuidString + ".jsonl", 0) == 0 else { throw OperationLogError.storageUnavailable }
                        count += 1
                    }
                    return count
                }
                continuation.resume(returning: count)
            } catch { continuation.resume(throwing: error) }
        } }
    }
}

final class OperationLogSession: @unchecked Sendable {
    let id = UUID()
    private let store: OperationLogStore
    private let request: CoreRequest
    private let coreVersion: String?
    private let started: Date
    private let onStatus: @Sendable (OperationLogStatus) -> Void
    private let ingress = NSLock()
    private var pendingBytes = 0, pendingRecords = 0, dropped = 0
    private var accepting = true
    private var fd: Int32 = -1, written = 0, unsynced = 0
    private var lastSync = Date()
    private var sanitizer = OperationLogSanitizer()
    private var incomplete = false, truncated = false, unavailable = false
    private var lastSequence = 0

    fileprivate init(store: OperationLogStore, request: CoreRequest, coreVersion: String?, onStatus: @escaping @Sendable (OperationLogStatus) -> Void) {
        self.store = store; self.request = request; self.coreVersion = coreVersion; self.onStatus = onStatus; started = store.now()
    }
    deinit { if fd >= 0 { Darwin.close(fd) } }
    fileprivate func open() {
        do {
            try store.locked {
                try store.room(bytes: 1024, creating: true)
                fd = try store.create(id)
                var record = OperationLogRecord(.header, time: started)
                record.storageID = id; record.operationID = UUID(uuidString: request.operationID); record.operation = request.command.operation
                record.desktopVersion = OperationLogSanitizer.version(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
                record.desktopBuild = OperationLogSanitizer.version(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
                record.coreVersion = OperationLogSanitizer.version(coreVersion)
                try append(record, reserved: false); try sync()
            }
            onStatus(.recording)
        } catch { fail() }
    }
    private func fail() {
        unavailable = true; incomplete = true
        if fd >= 0 { Darwin.close(fd); fd = -1 }
        onStatus(.unavailable)
    }
    private func sync() throws {
        guard fsync(fd) == 0 else { throw OperationLogError.storageUnavailable }
        unsynced = 0; lastSync = store.now()
    }
    private func append(_ record: OperationLogRecord, reserved: Bool) throws {
        guard OperationLogSanitizer.valid(record) else { throw OperationLogError.invalidRecord }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970; encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(record); data.append(10)
        guard data.count <= store.limits.recordBytes else { throw OperationLogError.invalidRecord }
        guard written + data.count <= store.limits.fileBytes - (reserved ? 0 : store.limits.reserve) else { throw OperationLogError.storageUnavailable }
        try store.attached(fd, id: id)
        try store.room(bytes: data.count, finishing: reserved ? id : nil)
        var offset = 0
        try data.withUnsafeBytes { bytes in
            while offset < bytes.count {
                let result = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if result < 0 && errno == EINTR { continue }
                guard result > 0 else { throw OperationLogError.storageUnavailable }
                offset += result
            }
        }
        written += data.count; unsynced += 1
        if unsynced >= 32 || store.now().timeIntervalSince(lastSync) >= 1 || record.kind == .finish ||
            ["completed", "failed", "cancelled"].contains(record.eventType ?? "") { try sync() }
    }
    private func write(_ record: OperationLogRecord) {
        guard !unavailable, !truncated else { return }
        do { try store.locked { try append(record, reserved: false) } }
        catch OperationLogError.invalidRecord { skip() }
        catch {
            // Size/budget exhaustion preserves room for a truncation marker/finish.
            do {
                try store.locked {
                    var marker = OperationLogRecord(.client, time: store.now()); marker.client = .truncated; marker.omitted = true
                    try append(marker, reserved: true); try sync()
                }
                truncated = true; incomplete = true; onStatus(.incomplete)
            } catch { fail() }
        }
    }
    private func skip() {
        incomplete = true; onStatus(.incomplete)
        var marker = OperationLogRecord(.client, time: store.now()); marker.client = .eventSkipped; marker.omitted = true
        write(marker)
    }
    // Called from the transport reader, off MainActor. Bound both work count and
    // retained input size; large/complex payloads produce a bounded skip fact.
    private func weight(_ value: CoreJSON, depth: Int = 0, budget: inout Int) -> Int {
        budget -= 1
        guard depth <= 8, budget >= 0 else { return store.limits.pendingBytes + 1 }
        switch value {
        case .string(let text): return text.utf8.count
        case .array(let values):
            var total = 0
            for value in values { total += weight(value, depth: depth + 1, budget: &budget); if total > store.limits.pendingBytes { break } }
            return total
        case .object(let values):
            var total = 0
            for (key, value) in values { total += key.utf8.count + weight(value, depth: depth + 1, budget: &budget); if total > store.limits.pendingBytes { break } }
            return total
        default: return 16
        }
    }
    func receive(_ event: CoreEvent, at time: Date = Date()) {
        var budget = 8192
        let bytes = weight(.object(event.fields), budget: &budget)
        ingress.lock()
        guard accepting else { ingress.unlock(); return }
        if pendingRecords >= store.limits.pendingRecords || pendingBytes + bytes > store.limits.pendingBytes {
            dropped += 1; ingress.unlock(); return
        }
        pendingBytes += bytes; pendingRecords += 1
        store.queue.async { [self] in
            drainDropped()
            if event.operationID != request.operationID || event.sequence <= lastSequence { skip() }
            else {
                lastSequence = event.sequence
                let record = sanitizer.event(event, at: time)
                if record.omitted == true { incomplete = true; onStatus(.incomplete) }
                write(record)
            }
            ingress.lock(); pendingBytes -= bytes; pendingRecords -= 1; ingress.unlock()
        }
        ingress.unlock()
    }
    private func drainDropped() {
        ingress.lock(); let count = dropped; ingress.unlock()
        if count > 0 && !incomplete { skip() }
    }
    func client(_ client: OperationLogClient) {
        ingress.lock(); defer { ingress.unlock() }
        guard accepting else { return }
        // Control facts have a fixed small representation and share the same queue.
        guard pendingRecords < store.limits.pendingRecords else { dropped += 1; return }
        pendingRecords += 1
        store.queue.async { [self] in
            var record = OperationLogRecord(.client, time: store.now()); record.client = client; write(record)
            ingress.lock(); pendingRecords -= 1; ingress.unlock()
        }
    }
    func finish(_ outcome: CoreProcessOutcome?, error: CoreRuntimeError?) async -> OperationLogStatus {
        await withCheckedContinuation { continuation in
            ingress.lock(); accepting = false
            store.queue.async { [self] in
                drainDropped()
                guard !unavailable else { continuation.resume(returning: .unavailable); return }
                var record = OperationLogRecord(.finish, time: store.now())
                record.signalled = outcome?.signalled
                if outcome?.signalled == true { record.signalNumber = outcome?.exitCode } else { record.exitCode = outcome?.exitCode }
                record.eventType = outcome?.terminal?.type
                record.terminalValid = outcome?.terminal != nil && outcome?.error == nil
                record.runtimeError = OperationLogSanitizer.runtimeCode(error)
                record.verificationStatus = sanitizer.verificationStatus ?? "not_run"; record.detailStatus = sanitizer.detailStatus ?? "not_run"
                ingress.lock(); record.droppedEvents = dropped; ingress.unlock()
                record.incomplete = incomplete || record.terminalValid != true
                do {
                    try store.locked { try append(record, reserved: true) }
                    Darwin.close(fd); fd = -1
                    let status: OperationLogStatus = record.incomplete == true ? .incomplete : .complete
                    onStatus(status); continuation.resume(returning: status)
                } catch { fail(); continuation.resume(returning: .unavailable) }
            }
            ingress.unlock()
        }
    }
}
