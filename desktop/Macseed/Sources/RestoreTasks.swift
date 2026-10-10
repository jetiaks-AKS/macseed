import Foundation

// A read-only projection of the accepted Preview and existing structured evidence.
// No readiness, mutation or Verification decisions belong here.
enum TaskRowState: String, CaseIterable {
    case completed = "Completed", partial = "Partial Success", attention = "Needs Attention"
    case skipped = "Skipped", failed = "Failed", working = "Working", waiting = "Waiting"
    case planned = "Changes Planned", matching = "Already Matches", unverified = "Unverified"
    case awaitingVerification = "Awaiting Verification", notRun = "Not Run"
    var symbol: String {
        switch self {
        case .completed, .matching: "checkmark.circle.fill"
        case .partial, .attention, .unverified: "exclamationmark.triangle.fill"
        case .skipped, .notRun: "minus.circle.fill"
        case .failed: "xmark.circle.fill"
        case .working: "arrow.triangle.2.circlepath"
        case .waiting, .awaitingVerification: "clock"
        case .planned: "arrow.down.circle"
        }
    }
    static func aggregate(_ states: [Self]) -> Self {
        guard !states.isEmpty else { return .unverified }
        if states.contains(.working) { return .working }
        let success = states.contains(.completed) || states.contains(.matching)
        if states.contains(.failed) { return success ? .partial : .failed }
        if states.contains(.attention) || states.contains(.unverified) {
            return success ? .partial : states.contains(.attention) ? .attention : .unverified
        }
        if states.contains(.skipped) { return success ? .partial : .skipped }
        if states.contains(.waiting) { return .waiting }
        if states.contains(.awaitingVerification) { return .awaitingVerification }
        if states.contains(.planned) { return .planned }
        if states.allSatisfy({ $0 == .notRun }) { return .notRun }
        return states.allSatisfy { $0 == .matching } ? .matching : .completed
    }
}

struct TaskItemPresentation: Identifiable {
    let id: String
    let item: DisplayItem
    let state: TaskRowState
    var diagnostic: CoreRestorePreparation.Diagnostic? = nil
    var technicalName: String? = nil
    var executionAction: String? = nil
}
struct TaskDomainPresentation: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let items: [TaskItemPresentation]
    var activityState: TaskRowState? = nil
    var previewOnly = false
    var confirmedFinalState: TaskRowState? = nil
    var executionStatus: TaskRowState {
        if confirmedFinalState == .notRun { return .notRun }
        if RestoreOperationSummary(domains: [self]).attention > 0 || confirmedFinalState == .attention { return .attention }
        if let confirmedFinalState, [.completed, .matching].contains(confirmedFinalState) { return confirmedFinalState }
        if state == .working { return .working }
        if let confirmedFinalState { return confirmedFinalState }
        switch state {
        case .attention: return .attention
        case .matching, .completed, .awaitingVerification: return .awaitingVerification
        default: return .waiting
        }
    }
    var state: TaskRowState {
        if let activityState { return activityState }
        if previewOnly {
            if items.contains(where: { $0.state == .attention }) { return .attention }
            if items.contains(where: { $0.state == .unverified }) { return .unverified }
            return items.contains(where: { $0.state == .planned }) ? .planned : .matching
        }
        return .aggregate(items.map(\.state))
    }
    var summary: String {
        let counts = Dictionary(grouping: items, by: \.state)
        return TaskRowState.allCases.compactMap { state in
            counts[state].map { "\($0.count) \(state.rawValue.lowercased())" }
        }.joined(separator: " · ")
    }
}

struct RestoreTaskPresentation {
    let domains: [TaskDomainPresentation]
    var counters: [(state: TaskRowState, count: Int)] {
        TaskRowState.allCases.compactMap { state in
            let count = domains.filter { $0.state == state }.count
            return count > 0 ? (state, count) : nil
        }
    }
    init(preview: RestorePreviewPresentation, plan: CoreRestorePreparation, events: [CoreEvent] = [],
         result: RestoreExecutionPresentation? = nil, executing: Bool = false, operationProgress: Bool = false) {
        let evidence = result?.structuredEvidence?["verification"]?.object?["details"]?.object
        func records(_ key: String) -> [[String: CoreJSON]] {
            if case .array(let rows) = evidence?[key] { return rows.compactMap(\.object) }
            return []
        }
        let operations = events.filter { $0.type == "operation_record" }.compactMap(\.data) + records("operation_records")
        let verification = events.filter { $0.type == "verification_record" }.compactMap(\.data) + records("verification_records")
        // Core executes sequentially. A new activity replaces the previous one;
        // finishing an operation clears activity without claiming conformity.
        var currentActivity: (domain: String, itemID: String)?
        for event in events {
            guard let domain = event.data?["domain"]?.string,
                  let itemID = event.data?["item_id"]?.string else { continue }
            if event.type == "execution_event" {
                if ["started", "applying", "verifying"].contains(event.data?["state"]?.string ?? "") {
                    currentActivity = (domain, itemID)
                } else if currentActivity?.domain == domain && (currentActivity?.itemID == itemID || itemID == "scope") {
                    currentActivity = nil
                }
            } else if ["operation_record", "verification_record"].contains(event.type) && currentActivity?.domain == domain && currentActivity?.itemID == itemID {
                currentActivity = nil
            }
        }
        let verifying = events.contains { $0.phase == "verification" || $0.data?["domain"]?.string == "verification" }
        let progress = executing && result == nil ? RestoreProgressRow.freeze(preview: preview, plan: plan) : []
        var output: [TaskDomainPresentation] = []
        for category in preview.sections.flatMap(\.rows) {
            let domainID = category.id
            let domainScope = Set(preview.categories.filter { row in
                row.items.contains { item in category.items.contains { $0.id == item.id } }
            }.map(\.id))
            let domainActive = currentActivity.map { domainScope.contains($0.domain) ||
                ($0.domain == "workspace" && !domainScope.isDisjoint(with: ["workspace-folders", "git-repositories"])) } ?? false
            let active = progress.first { $0.id == category.id }?.project(events: events)
            let activityState: TaskRowState? = active.flatMap {
                if operationProgress && domainActive && !verifying { return .working }
                if $0.status == .working || $0.restoreActivity != nil { return domainActive && !verifying ? .working : nil }
                return $0.status == .complete ? .completed : $0.status == .attention ? .attention : nil
            }
            let items = category.items.filter { item in
                guard executing, result == nil, !operationProgress else { return true }
                guard let index = Int(item.id.replacingOccurrences(of: "restore-", with: "")), plan.plan.indices.contains(index) else { return false }
                return progress.contains { $0.id == category.id } && plan.plan[index].disposition != "satisfied"
            }.map { item -> TaskItemPresentation in
                let index = Int(item.id.replacingOccurrences(of: "restore-", with: ""))
                let entry = index.flatMap { plan.plan.indices.contains($0) ? plan.plan[$0] : nil }
                func belongs(_ row: [String: CoreJSON]) -> Bool {
                    row["domain"]?.string == entry?.domain && row["item_id"]?.string == entry?.itemID
                }
                let operation = operations.last(where: belongs)
                let observed = verification.last(where: belongs)
                let activity = events.last { $0.type == "execution_event" && belongs($0.data ?? [:]) }
                let completedOperation = operation?["outcome"]?.string == "success"
                    && operation?["action"]?.string == entry?.action
                let completedActivity = events.contains { event in
                    event.type == "execution_event" && belongs(event.data ?? [:]) &&
                        event.data?["state"]?.string == "changed" && event.data?["action"]?.string == entry?.action
                }
                let state: TaskRowState
                if !executing && result == nil {
                    state = item.status == .matching ? .matching : item.status == .ready ? .planned
                        : item.status == .unverified ? .unverified : .attention
                } else if operation?["reason"]?.string == "cancelled" {
                    state = .waiting
                } else if operation?["outcome"]?.string == "skipped" {
                    state = .skipped
                } else if operation?["outcome"]?.string == "failure" {
                    state = .failed
                } else if operationProgress && (operation?["outcome"]?.string == "warning" ||
                    ["warning", "failed", "conflict", "blocked", "interrupted"].contains(activity?.data?["state"]?.string ?? "")) {
                    state = activity?.data?["state"]?.string == "failed" ? .failed : .attention
                } else if operationProgress && (observed?["conformity"]?.string == "mismatch" || (result != nil && ["unverified", "unresolved", "unsupported"].contains(observed?["conformity"]?.string ?? ""))) {
                    state = .attention
                } else if operationProgress && (completedOperation || completedActivity) {
                    state = .completed
                } else if operationProgress && (operation?["outcome"]?.string == "noop" || ["already_satisfied", "satisfied"].contains(activity?.data?["state"]?.string ?? "")) {
                    state = .matching
                } else if !operationProgress && (observed?["conformity"]?.string == "verified" || result?.outcome == .clean) {
                    state = .completed
                } else if !operationProgress && observed != nil {
                    state = .unverified
                } else if item.status == .matching {
                    // Preserve the known Preview observation, without claiming final Verification.
                    state = .matching
                } else if item.requiresAttention {
                    state = item.status == .unverified ? .unverified : .attention
                } else if result != nil || (operationProgress && verifying) {
                    state = .unverified
                } else if let currentActivity, let entry,
                          currentActivity.domain == entry.domain && currentActivity.itemID == entry.itemID {
                    state = .working
                } else if operation?["outcome"]?.string == "success" {
                    state = .awaitingVerification
                } else if activity != nil || operation != nil {
                    state = .unverified
                } else {
                    state = .waiting
                }
                let reason = operation?["reason"]?.string ?? activity?.data?["reason"]?.string ?? observed?["reason"]?.string ?? item.reason
                let message: String
                switch reason {
                case "cask_execution_requirements_unsupported": message = "This application's installation requirements are not supported."
                case "item_stalled_timeout": message = "No observable progress. Check the network or VPN, then Refresh Preview."
                case "dependency_failed": message = "A required dependency did not complete."
                case "privileged_lifecycle_unknown": message = "Privileged work may continue. Inspect Homebrew before another Rebuild."
                case "cask_authorization_required": message = "Administrator authorization was not completed."
                default: message = state == .completed ? (operationProgress ? "Core confirmed operation completion." : "Verified against the saved environment.")
                    : operationProgress && state == .unverified ? "Core has not confirmed completion of this operation."
                    : executing && state == .working
                        ? (entry?.action == "reinstall" ? "Repairing or verifying this item…" : "Applying or verifying this item…")
                    : state == .awaitingVerification
                        ? "Awaiting Verification." : item.action
                }
                return TaskItemPresentation(id: item.id,
                    item: DisplayItem(id: item.id, title: operationProgress ? Self.operationTitle(item.title, entry: entry) : item.title, status: item.status, action: message, reason: reason), state: state, diagnostic: entry?.diagnostic,
                    technicalName: operationProgress ? entry.flatMap { $0.itemID.hasPrefix("opaque:") ? nil : "\($0.domain) / \($0.itemID)" } : nil,
                    executionAction: operationProgress ? entry?.action.replacingOccurrences(of: "_", with: " ").capitalized : nil)
            }
            if items.isEmpty { continue }
            var domain = TaskDomainPresentation(id: domainID, title: category.title,
                symbol: Self.symbol(category.id), items: items, activityState: operationProgress ? Self.executionState(items, activity: result == nil ? activityState : nil) : activityState, previewOnly: !executing && result == nil)
            if operationProgress {
                let entries = category.items.compactMap { item -> CoreRestorePreparation.Row? in
                    guard let index = Int(item.id.replacingOccurrences(of: "restore-", with: "")), plan.plan.indices.contains(index) else { return nil }
                    return plan.plan[index]
                }
                let scopedVerification = verification.filter { domainScope.contains($0["domain"]?.string ?? "") }
                // Preserve each predicate independently. Later evidence may replace an earlier observation.
                var latest: [String: [String: CoreJSON]] = [:]
                for record in scopedVerification {
                    let key = (record["domain"]?.string ?? "") + "|" + (record["item_id"]?.string ?? "") + "|" + (record["predicate"]?.string ?? "")
                    latest[key] = record
                }
                let coverage = (events.filter { $0.type == "coverage_record" }.compactMap(\.data) + records("coverage_records"))
                    .filter { domainScope.contains($0["domain"]?.string ?? "") }
                let finalComplete = result?.structuredEvidence?["verification"]?.object?["status"]?.string == "complete"
                    && evidence?["status"]?.string == "complete"
                    && result?.structuredEvidence?["prepared_plan_id"]?.string == plan.preparedPlanID
                    && result?.outcome != .interrupted
                let problem = latest.values.contains { $0["conformity"]?.string != "verified" }
                    || coverage.contains { $0["disposition"]?.string == "unresolved" }
                let allVerified = entries.count == category.items.count && Self.hasVerifiedRequirements(entries: entries, observations: Array(latest.values), operations: operations)
                let untouchedStalePlan = result?.outcome == .failedBeforeMutation
                    && result?.structuredEvidence?["code"]?.string == "stale_plan"
                    && result?.structuredEvidence?["execution_status"]?.string == "failed_before_mutation"
                    && result?.structuredEvidence?["target_mutation_may_have_started"]?.boolean == false
                    && result?.structuredEvidence?["verification"]?.object?["status"]?.string == "not_run"
                    && !operations.contains { domainScope.contains($0["domain"]?.string ?? "") }
                    && scopedVerification.isEmpty && coverage.isEmpty
                    && !events.contains { $0.type == "execution_event" && domainScope.contains($0.data?["domain"]?.string ?? "") }
                if untouchedStalePlan {
                    domain.confirmedFinalState = .notRun
                } else if result != nil {
                    if problem { domain.confirmedFinalState = .attention }
                    else if result?.outcome == .clean || (finalComplete && allVerified) {
                        domain.confirmedFinalState = category.items.allSatisfy { $0.status == .matching } ? .matching : .completed
                    } else {
                        domain.confirmedFinalState = .unverified
                    }
                } else if problem {
                    domain.confirmedFinalState = .attention
                } else if allVerified && !latest.isEmpty {
                    domain.confirmedFinalState = category.items.allSatisfy { $0.status == .matching } ? .matching : .completed
                } else if verifying || events.contains(where: { event in
                    domainScope.contains(event.data?["domain"]?.string ?? "") &&
                        ((event.type == "execution_event" && ["started", "applying", "verifying", "changed", "already_satisfied", "satisfied"].contains(event.data?["state"]?.string ?? "")) ||
                         (event.type == "operation_record" && ["success", "noop", "failure", "warning", "skipped"].contains(event.data?["outcome"]?.string ?? "")))
                }) {
                    domain.confirmedFinalState = .awaitingVerification
                }
            } else if result?.outcome == .clean {
                domain.confirmedFinalState = category.items.allSatisfy { $0.status == .matching } ? .matching : .completed
            }
            output.append(domain)
        }
        domains = output
    }
    static func hasVerifiedRequirements(entries: [CoreRestorePreparation.Row], observations: [[String: CoreJSON]], operations: [[String: CoreJSON]]) -> Bool {
        !entries.isEmpty && entries.allSatisfy { entry in
            if entry.action == "restart_process" && entry.domain.hasPrefix("macos-") {
                // Restart is an execution step, not a selected final-state predicate.
                // Core verifies the stored preferences and emits no restart receipt.
                let preferences = entries.filter { $0.domain == entry.domain && $0.action != "restart_process" }
                return !preferences.isEmpty && hasVerifiedRequirements(entries: preferences, observations: observations, operations: operations)
            }
            if entry.action == "restart_process" {
                return operations.contains { $0["domain"]?.string == entry.domain && $0["item_id"]?.string == entry.itemID && $0["action"]?.string == entry.action && $0["outcome"]?.string == "success" }
            }
            let observed = observations.filter { $0["domain"]?.string == entry.domain && $0["item_id"]?.string == entry.itemID }
            return !observed.isEmpty && (!entry.domain.hasPrefix("macos-") || observed.contains { $0["predicate"]?.string == "stored_preference" }) && observed.allSatisfy { $0["conformity"]?.string == "verified" }
        }
    }
    static func executionState(_ items: [TaskItemPresentation], activity: TaskRowState?) -> TaskRowState {
        if activity == .working || items.contains(where: { $0.state == .working }) { return .working }
        let summary = RestoreOperationSummary(domains: [.init(id: "execution", title: "", symbol: "", items: items)])
        if summary.attention > 0 { return .attention }
        if summary.unconfirmed > 0 { return .unverified }
        return items.allSatisfy { $0.state == .matching } ? .matching : .completed
    }
    private static func operationTitle(_ fallback: String, entry: CoreRestorePreparation.Row?) -> String {
        guard let entry, entry.domain.hasPrefix("macos-") else { return fallback }
        if entry.action == "restart_process" { return "Restart " + entry.itemID }
        let parts = entry.itemID.split(separator: "/")
        guard let key = parts.last, parts.count == 2 else { return fallback }
        let labels = ["tilesize": "Icon Size", "location": "Save Location", "autohide": "Automatically Hide", "show-recents": "Recent Applications", "magnification": "Magnification", "largesize": "Magnified Icon Size", "mineffect": "Minimize Effect"]
        let area = entry.domain.replacingOccurrences(of: "macos-", with: "").capitalized
        return area + " — " + (labels[String(key)] ?? String(key).replacingOccurrences(of: "-", with: " ").capitalized)
    }
    private static func symbol(_ id: String) -> String {
        switch id {
        case "homebrew-casks": "app"
        case "homebrew-packages": "shippingbox"
        case "git-configuration", "git-repositories": "point.3.connected.trianglepath.dotted"
        case "workspace-folders": "folder"
        case "app-store": "app.badge"
        case "macOS Settings", "vscode-settings": "gearshape"
        case "vscode-extensions": "puzzlepiece.extension"
        case "shell-zsh": "terminal"
        case "ssh-configuration": "lock.shield"
        default: "square.stack"
        }
    }
}

// Counts operations, never Verification requirements or inferred category completion.
struct RestoreOperationSummary {
    let completed: Int
    let working: Int
    let attention: Int
    let unconfirmed: Int
    init(domains: [TaskDomainPresentation]) {
        let items = domains.flatMap(\.items)
        completed = items.filter { $0.state == .completed }.count
        working = items.filter { $0.state == .working }.count
        attention = items.filter { item in
            [.failed, .attention, .partial].contains(item.state) ||
                (item.state == .skipped && item.item.reason.map {
                    !["not_applicable", "not_selected", "already_satisfied", "no_requirement", "cancelled"].contains($0)
                } == true)
        }.count
        unconfirmed = items.filter { [.waiting, .unverified, .awaitingVerification].contains($0.state) }.count
    }
}

struct RestoreVerificationSummary {
    let status: String
    let verified: Int?
    let mismatch: Int?
    let unverified: Int?
    let unresolved: Int?
    var complete: Bool {
        status == "complete" && [verified, mismatch, unverified, unresolved].allSatisfy { $0.map { $0 >= 0 } == true }
    }
    func overallResult(outcome: RestoreExecutionPresentation.Outcome) -> String {
        switch outcome {
        case .failedBeforeMutation, .failedAfterMutation: return "Failed"
        case .stoppedBeforeMutation, .stoppedAfterMutation: return "Stopped"
        case .interrupted: return "Interrupted"
        default: break
        }
        guard complete else { return "Incomplete" }
        if outcome != .clean || mismatch != 0 || unverified != 0 || unresolved != 0 { return "Needs Attention" }
        return "OK"
    }
    var title: String {
        if complete { return "Verification Complete" }
        if status == "not_run" { return "Verification Not Run" }
        if status == "Not reported" { return "Verification Not Reported" }
        return "Verification Incomplete"
    }
    init(payload: [String: CoreJSON]?) {
        let evidence = payload?["verification"]?.object
        status = evidence?["status"]?.string ?? "Not reported"
        verified = evidence?["verified_count"]?.integer
        mismatch = evidence?["mismatch_count"]?.integer
        unverified = evidence?["unverified_count"]?.integer
        unresolved = evidence?["unresolved_count"]?.integer
    }
}

extension TaskDomainPresentation {
    var executionMessages: [String] {
        var seen = Set<String>()
        return items.filter { [.failed, .attention, .partial, .skipped].contains($0.state) && !["cancelled", "not_applicable", "not_selected", "already_satisfied", "no_requirement"].contains($0.item.reason ?? "") }.compactMap { item in
            let message: String
            switch item.item.reason {
            case "cask_execution_requirements_unsupported", "item_stalled_timeout", "dependency_failed", "privileged_lifecycle_unknown", "cask_authorization_required": message = item.item.action
            case "target_conflict": message = "The current value differs from the saved environment and is preserved."
            default: message = item.state == .failed ? "Some selected changes could not be completed." : "Some selected requirements need attention. Refresh Preview to inspect current state."
            }
            return seen.insert(message).inserted ? message : nil
        }
    }
}
