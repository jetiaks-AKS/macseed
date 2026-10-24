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
    var captureRole: CaptureItemRole? = nil
    var resultLabels: [String] = []
    var resultTechnicalDetails: String? = nil
    var auxiliaryCompletionUnreported = false
    var resultEvidenceAvailable: Bool? = nil
    var verificationEvidenceAvailable: Bool? = nil
    var resultNotRun = false
    var previewProblem: String? = nil
    var sourceDomain: String? = nil
    var sourceItemID: String? = nil
    var assistedAppStore: AssistedAppStoreItem? = nil
}
struct TaskDomainPresentation: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let items: [TaskItemPresentation]
    var activityState: TaskRowState? = nil
    var previewOnly = false
    var resultCategoryIssue = false
    var resultProblemDomains: Set<String> = []
    var resultCategoryMessage: String? = nil
    var resultProblemMessages: [String: String] = [:]
    var confirmedFinalState: TaskRowState? = nil
    var sharedObservationItemIDs: Set<String> {
        let candidates = items.filter { $0.diagnostic == nil && $0.assistedAppStore == nil
            && [.attention, .unverified, .failed].contains($0.state)
            && ["homebrew_unavailable", "observation_failed", "inspection_unavailable"].contains($0.item.reason ?? "") }
        guard let first = candidates.first else { return [] }
        let same = candidates.filter { $0.item.reason == first.item.reason && $0.state == first.state
            && $0.executionAction == first.executionAction && $0.sourceDomain == first.sourceDomain }
        return same.count > 1 ? Set(same.map(\.id)) : []
    }
    var sharedObservationReason: String? {
        let ids = sharedObservationItemIDs
        return items.first { ids.contains($0.id) }?.item.reason
    }
    var sharedObservationMessage: String? {
        guard sharedObservationReason != nil else { return nil }
        return id.hasPrefix("homebrew-") ? "Couldn’t read Homebrew state." : "Couldn’t read the current state of this category."
    }
    var executionStatusTitle: String {
        if activityState == .working && (RestoreOperationSummary(domains: [self]).attention > 0 || confirmedFinalState == .attention) { return "Working · Needs Attention" }
        return executionStatus.rawValue
    }
    var executionStatus: TaskRowState {
        if confirmedFinalState == .notRun { return .notRun }
        if activityState == .working { return .working }
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
    var automaticDomains: [TaskDomainPresentation] { domains.filter { $0.id != "app-store" } }
    var appStore: AppStoreRestorePresentation { AppStoreRestorePresentation(domains: domains) }
    var counters: [(state: TaskRowState, count: Int)] {
        TaskRowState.allCases.compactMap { state in
            let count = automaticDomains.filter { $0.state == state }.count
            return count > 0 ? (state, count) : nil
        }
    }
    var automaticAttentionCount: Int {
        automaticDomains.flatMap(\.items).filter { [.attention, .unverified].contains($0.state) }.count
    }
    static func scopeWarningMessages(_ plan: CoreRestorePreparation) -> [String] {
        (plan.scopeWarnings ?? []).map {
            "Preview reported a category-level warning for \(CaptureCategory.title(for: $0)). Review its details before rebuilding."
        }
    }
    func confirmationMessages(_ plan: CoreRestorePreparation) -> [String] {
        var messages = Self.scopeWarningMessages(plan)
        if automaticAttentionCount > 0 {
            messages.append("\(automaticAttentionCount) automatic requirements need attention. Review the category details; blocked items will remain unchanged.")
        }
        if !appStore.pending.isEmpty {
            messages.append("\(appStore.attentionCount) App Store requirements need manual review. Rebuild does not install App Store applications.")
        }
        return messages
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
                let operation = operations.last { belongs($0) && $0["action"]?.string == entry?.action }
                let observed = verification.last(where: belongs)
                let activity = events.last { $0.type == "execution_event" && belongs($0.data ?? [:]) && $0.data?["action"]?.string == entry?.action }
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
                if result == nil && !executing && !operationProgress, entry?.diagnostic?.condition == "provider_conflict" {
                    message = entry!.diagnostic!.explanation
                } else if result == nil && !executing && !operationProgress, entry?.diagnostic?.primitive == "rosetta" {
                    message = entry!.diagnostic!.explanation
                } else if result == nil && !executing && !operationProgress, let explanation = entry?.unsupportedRepairExplanation {
                    message = explanation
                } else {
                    switch reason {
                    case "cask_rosetta_required": message = entry?.diagnostic?.explanation ?? "Install Rosetta manually, then Refresh Preview."
                    case "cask_execution_requirements_unsupported":
                        message = result == nil && !executing && !operationProgress
                            && entry?.diagnostic?.primitive == "pkgutil" && entry?.diagnostic?.condition == "preparation_required"
                            ? "Installer preparation required before this application can be restored."
                            : "This application's installation requirements are not supported."
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
                }
                // Final labels describe independent evidence, never inferred installations.
                var labels: [String] = []
                let observations = verification.filter(belongs)
                var predicates: [String: [String: CoreJSON]] = [:]
                for row in observations { predicates[row["predicate"]?.string ?? "unknown"] = row }
                let conformities = Set(predicates.values.compactMap { $0["conformity"]?.string })
                if activity?.data?["state"]?.string == "failed" { labels.append("Failed") }
                else if ["blocked", "conflict", "warning", "interrupted"].contains(activity?.data?["state"]?.string ?? "") { labels.append("Needs Attention") }
                if operation?["outcome"]?.string == "failure" && !labels.contains("Failed") { labels.append("Failed") }
                if operation?["outcome"]?.string == "skipped" { labels.append("Skipped") }
                if operation?["outcome"]?.string == "warning" && !labels.contains("Needs Attention") { labels.append("Needs Attention") }
                if completedOperation || completedActivity { labels.append("Applied") }
                if operation?["outcome"]?.string == "noop" { labels.append("Already Matches") }
                if conformities.contains("mismatch") { labels.append("Mismatch") }
                if conformities.contains("unsupported") { labels.append("Unsupported") }
                if conformities.contains("unresolved") { labels.append("Unresolved") }
                if conformities.contains("unverified") { labels.append("Unverified") }
                if entry?.action != "restart_process" && !predicates.isEmpty && conformities == ["verified"] { labels.append("Verified") }
                if labels.isEmpty { labels = ["Unverified"] }
                let technical = ([operation, activity?.data].compactMap { $0 } + Array(predicates.values))
                    .map { row in ["domain", "item_id", "action", "state", "outcome", "predicate", "conformity", "reason", "record_id"].compactMap { key in row[key]?.string.map { key + ": " + $0 } }.joined(separator: " · ") }
                    .sorted().joined(separator: "\n")
                let assisted = entry?.assistedAppStoreItem.map { app in
                    guard executing || result != nil else { return app }
                    let status: AssistedAppStoreItem.Status
                    switch observed?["conformity"]?.string {
                    case "verified": status = .installed
                    case "mismatch": status = .missing
                    default: status = .unverified
                    }
                    return AssistedAppStoreItem(appID: app.appID, status: status)
                }
                return TaskItemPresentation(id: item.id,
                    item: DisplayItem(id: item.id, title: operationProgress ? (entry.flatMap { WorkspaceSettingLabels.title(domain: $0.domain, identity: $0.itemID) } ?? Self.operationTitle(item.title, entry: entry)) : item.title, status: item.status, action: message, reason: reason), state: state, diagnostic: entry?.diagnostic,
                    technicalName: operationProgress ? entry.flatMap { $0.itemID.hasPrefix("opaque:") ? nil : "\($0.domain) / \($0.itemID)" } : nil,
                    executionAction: operationProgress ? entry?.action.replacingOccurrences(of: "_", with: " ").capitalized : nil,
                    resultLabels: labels, resultTechnicalDetails: technical.isEmpty ? nil : technical,
                    auxiliaryCompletionUnreported: entry?.domain.hasPrefix("macos-") == true && entry?.action == "restart_process"
                        && operation == nil && !completedActivity && activity == nil,
                    resultEvidenceAvailable: operation != nil || activity != nil || observed != nil,
                    verificationEvidenceAvailable: observed != nil,
                    resultNotRun: result != nil && result?.outcome != .interrupted
                        && result?.structuredEvidence?["target_mutation_may_have_started"]?.boolean == false
                        && result?.structuredEvidence?["unknown_consequences"]?.boolean != true
                        && operation == nil && activity == nil && observed == nil,
                    previewProblem: entry.flatMap { ["blocked", "conflict", "warning"].contains($0.disposition) ? ($0.reason ?? $0.disposition) : nil },
                    sourceDomain: entry?.domain, sourceItemID: entry?.itemID, assistedAppStore: assisted)
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
                let diagnostics = events.filter { $0.type == "diagnostic_record" }.compactMap(\.data) + records("diagnostics")
                for scope in domainScope {
                    let scopedRecords = (operations + verification + coverage).filter { $0["domain"]?.string == scope }
                    let recordIDs = Set(scopedRecords.compactMap { $0["record_id"]?.string })
                    let scopeItems = items.filter { $0.sourceDomain == scope }
                    let explainedItemIDs = Set(scopeItems.filter { $0.resultGroup == "Needs Attention" }.compactMap { task -> String? in
                        guard let index = Int(task.id.replacingOccurrences(of: "restore-", with: "")), plan.plan.indices.contains(index) else { return nil }
                        return plan.plan[index].itemID
                    })
                    let unexplainedOperation = operations.contains { record in
                        record["domain"]?.string == scope && ["failure", "warning"].contains(record["outcome"]?.string ?? "")
                            && !entries.contains { $0.domain == scope && $0.itemID == record["item_id"]?.string && $0.action == record["action"]?.string }
                    }
                    let unresolvedCoverage = coverage.contains { $0["domain"]?.string == scope && $0["disposition"]?.string == "unresolved" }
                    let independentDiagnostics = diagnostics.filter { diagnostic in
                        guard ["error", "warning"].contains(diagnostic["severity"]?.string ?? ""),
                              let owner = diagnostic["record_id"]?.string, recordIDs.contains(owner) else { return false }
                        let linked = scopedRecords.first { $0["record_id"]?.string == owner }
                        let code = diagnostic["code"]?.string ?? ""
                        let explainedCode = ["operation_failed", "confirmed_mismatch", "observation_failed", "unsupported_predicate", "prerequisite_unmet"].contains(code)
                        return !explainedCode || !explainedItemIDs.contains(linked?["item_id"]?.string ?? "")
                    }
                    let independentDiagnostic = !independentDiagnostics.isEmpty
                    let unexplainedScope = events.contains { event in
                        guard event.type == "execution_event", event.data?["domain"]?.string == scope,
                              event.data?["item_id"]?.string == "scope", ["failed", "blocked", "conflict", "warning"].contains(event.data?["state"]?.string ?? "") else { return false }
                        return !Self.scopeProblemExplained(reason: event.data?["reason"]?.string,
                            hasItemProblems: !explainedItemIDs.isEmpty && (result == nil || evidence?["status"]?.string == "complete") && scopeItems.filter { !$0.auxiliaryCompletionUnreported }.allSatisfy { $0.resultGroup != nil }, independentProblem: unresolvedCoverage || unexplainedOperation || independentDiagnostic)
                    }
                    let hasProblem = unresolvedCoverage || unexplainedOperation || independentDiagnostic || unexplainedScope
                    if hasProblem {
                        domain.resultProblemDomains.insert(scope)
                        let message: String
                        if unresolvedCoverage { message = "Some selected requirements in this category could not be resolved." }
                        else if independentDiagnostic {
                            switch independentDiagnostics.first?["code"]?.string {
                            case "observation_failed": message = "This category's current state could not be inspected reliably."
                            case "input_invalid", "input_changed": message = "The selected input for this category could not be validated."
                            case "selected_input_unresolved": message = "Some selected input in this category could not be resolved."
                            case "unsupported_predicate": message = "Some requirements in this category cannot be verified."
                            default: message = "An additional problem needs review in this category."
                            }
                        }
                        else if unexplainedOperation { message = "Category-level work needs attention; the exact item was not reported." }
                        else { message = "The category operation did not complete; the exact failed step was not reported." }
                        domain.resultProblemMessages[scope] = message
                    }
                }
                domain.resultCategoryIssue = !domain.resultProblemDomains.isEmpty
                let messages = Set(domain.resultProblemMessages.values)
                domain.resultCategoryMessage = messages.count == 1 ? messages.first : messages.isEmpty ? nil : "Several independent category issues were reported. Expand the affected categories or review View Log."
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
    static func scopeProblemExplained(reason: String?, hasItemProblems: Bool, independentProblem: Bool) -> Bool {
        hasItemProblems && !independentProblem && ["module_failed", "module_warning"].contains(reason ?? "")
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
    let verdict: String?
    let verified: Int?
    let mismatch: Int?
    let unverified: Int?
    let unresolved: Int?
    var complete: Bool {
        status == "complete" && [verified, mismatch, unverified, unresolved].allSatisfy { $0.map { $0 >= 0 } == true }
    }
    var requirementsTitle: String {
        guard complete else { return "Not confirmed" }
        if (mismatch ?? 0) > 0 { return "Differences found" }
        guard verdict == "selected_requirements_verified", unverified == 0, unresolved == 0 else { return "Not fully verified" }
        return "Verified"
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
    var countsDescription: String {
        [(verified, "verified"), (mismatch, "mismatched"), (unverified, "unverified"), (unresolved, "unresolved")]
            .compactMap { count, label in count.flatMap { $0 > 0 ? "\($0) \(label)" : nil } }
            .joined(separator: " · ")
    }
    init(payload: [String: CoreJSON]?) {
        let evidence = payload?["verification"]?.object
        status = evidence?["status"]?.string ?? "Not reported"
        verdict = evidence?["verdict"]?.string
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

// Shared final-result classification. Counts selected plan rows, never predicates or apps.
extension TaskItemPresentation {
    var resultGroup: String? {
        let labels = Set(resultLabels)
        if state == .failed || !labels.isDisjoint(with: ["Failed", "Needs Attention", "Mismatch", "Unsupported"]) { return "Needs Attention" }
        if let assistedAppStore, !resultNotRun {
            if assistedAppStore.status == .installed { return "Success" }
            if resultEvidenceAvailable == true { return "Needs Attention" }
        }
        if previewProblem != nil && labels.isDisjoint(with: ["Applied", "Already Matches", "Verified"]) { return "Needs Attention" }
        if resultNotRun || auxiliaryCompletionUnreported { return nil }
        if labels.contains("Skipped") {
            return ["not_applicable", "not_selected", "no_requirement", "intentionally_skipped"].contains(item.reason ?? "") ? "Skipped" : "Needs Attention"
        }
        if !labels.isDisjoint(with: ["Applied", "Already Matches", "Verified"]) { return "Success" }
        if resultEvidenceAvailable == false || (labels == ["Unverified"] && verificationEvidenceAvailable == false) { return nil }
        if labels.isEmpty || (labels == ["Unverified"] && [.waiting, .notRun, .awaitingVerification].contains(state)) { return nil }
        return "Needs Attention"
    }
    var resultTitle: String {
        if let assistedAppStore, !resultNotRun { return assistedAppStore.status.rawValue }
        if resultGroup == "Needs Attention" {
            if resultLabels.contains("Failed") || state == .failed { return "Failed" }
            if resultLabels.contains("Mismatch") { return "Mismatch" }
            if resultLabels.contains("Unresolved") && previewProblem == nil { return "Unresolved" }
            if resultLabels == ["Unverified"] && resultEvidenceAvailable == true && previewProblem == nil { return "Unverified" }
            return "Needs Attention"
        }
        if resultNotRun { return "Not Run" }
        if auxiliaryCompletionUnreported { return "Completion Not Reported" }
        if resultGroup == "Skipped" { return "Skipped" }
        if resultGroup == "Success" {
            if resultLabels.contains("Applied") { return resultLabels.contains("Verified") ? "Verified" : "Applied, not verified" }
            if resultLabels.contains("Already Matches") { return resultLabels.contains("Verified") ? "Already Matches" : "Already Matches, not verified" }
            return "Verified"
        }
        return "Outcome Unknown"
    }
    var hasResultProblemDetails: Bool {
        resultGroup == "Needs Attention" || !Set(resultLabels).isDisjoint(with: ["Mismatch", "Unverified", "Unresolved", "Unsupported"]) && resultEvidenceAvailable != false
    }
    var resultExplanation: String? {
        if let assistedAppStore { return assistedAppStore.message }
        let reason = previewProblem ?? item.reason
        if diagnostic?.primitive == "pkgutil" && diagnostic?.condition == "preparation_required" {
            return "Installer preparation needs your approval and does not guarantee installation. Refresh Preview and choose Fix Issues…"
        }
        if reason == "cask_execution_requirements_unsupported" || resultLabels.contains("Unsupported") { return "This requirement's installation conditions are not supported." }
        if reason == "target_conflict" || reason == "conflict" { return "Existing state conflicts with the selected requirement and is preserved." }
        if resultLabels.contains("Mismatch") { return "Verification found a difference from the selected requirement." }
        if resultLabels.contains("Unresolved") { return "The selected requirement could not be resolved." }
        if resultLabels.contains("Unverified") && verificationEvidenceAvailable != false && resultEvidenceAvailable == true { return "Verification could not establish this requirement's final state." }
        if previewProblem != nil { return "A prerequisite or selected requirement needs attention." }
        if ["item_stalled_timeout", "dependency_failed", "privileged_lifecycle_unknown", "cask_authorization_required"].contains(reason ?? "") { return item.action }
        return nil
    }
    var resultBreakdown: String? {
        switch resultGroup {
        case "Success":
            if resultLabels.contains("Verified") { return "verified" }
            return resultLabels.contains("Applied") ? "applied, not verified" : "already matches, not verified"
        case "Skipped":
            return ["not_applicable", "no_requirement"].contains(item.reason ?? "") ? "not applicable" : "intentionally skipped"
        case "Needs Attention":
            if state == .failed || resultLabels.contains("Failed") { return "failed" }
            if let previewProblem {
                if previewProblem.contains("unsupported") { return "unsupported" }
                return previewProblem.contains("conflict") ? "conflict" : "prerequisite or blocked"
            }
            if resultLabels.contains("Mismatch") { return "mismatch" }
            if resultLabels.contains("Unsupported") { return "unsupported" }
            if resultLabels.contains("Needs Attention") || state == .attention && !resultLabels.contains("Unverified") { return "blocked or needs attention" }
            if resultLabels.contains("Unresolved") { return "unresolved" }
            if resultLabels.contains("Skipped") { return "problematic skip" }
            return "unverified"
        default: return nil
        }
    }
}

struct RestoreResultSummary {
    struct Issue: Identifiable {
        let id: String
        let title: String
        let message: String
        let nextAction: String
        var count: Int? = 1
        var appStore = false
    }
    struct Card: Identifiable {
        let id: String
        let count: Int
        let explanation: String
    }
    let cards: [Card]
    let uncounted: Int
    var successfulCount = 0
    var independentIssueTitles: [String] = []
    var issues: [Issue] = []
    var automaticAttentionCount: Int? = 0
    var manualAttentionCount = 0
    var manualMissingCount = 0
    var manualUnverifiedCount = 0
    var attentionCount: Int? { automaticAttentionCount.map { $0 + manualAttentionCount } }
    var attentionCaption: String {
        var parts: [String] = []
        if let count = automaticAttentionCount, count > 0 { parts.append("\(count) restore issue\(count == 1 ? "" : "s")") }
        else if automaticAttentionCount == nil { parts.append("Restore work needs review") }
        if manualMissingCount > 0 { parts.append("\(manualMissingCount) app\(manualMissingCount == 1 ? "" : "s") to install") }
        if manualUnverifiedCount > 0 { parts.append("\(manualUnverifiedCount) app\(manualUnverifiedCount == 1 ? "" : "s") to check") }
        return parts.joined(separator: " · ")
    }
    init(domains: [TaskDomainPresentation]) {
        // Identity is the plan row ID, even when several actions share an item name.
        var rows: [String: TaskItemPresentation] = [:]
        var notRun = Set<String>()
        for domain in domains {
            for item in domain.items {
                rows[item.id] = item
                if domain.resultTitle == "Not Run" { notRun.insert(item.id) }
            }
        }
        var groups: [String: [String: Int]] = [:]
        for item in rows.values where !notRun.contains(item.id) {
            if let group = item.resultGroup, let reason = item.resultBreakdown {
                groups[group, default: [:]][reason, default: 0] += 1
            }
        }
        cards = ["Success", "Needs Attention", "Skipped"].compactMap { group in
            guard let reasons = groups[group] else { return nil }
            let count = reasons.values.reduce(0, +)
            guard count > 0 else { return nil }
            return Card(id: group, count: count, explanation: reasons.keys.sorted().map { "\(reasons[$0]!) \($0)" }.joined(separator: " · "))
        }
        // Unreported auxiliary restarts are intentionally hidden, not unknown requirements.
        uncounted = rows.values.filter {
            !$0.auxiliaryCompletionUnreported && (notRun.contains($0.id) || $0.resultGroup == nil)
        }.count
    }

    // Consolidate existing row/category/findings projections; Core outcomes stay authoritative.
    init(domains: [TaskDomainPresentation], result: RestoreExecutionPresentation, appStore: AppStoreRestorePresentation?) {
        let automatic = domains.filter { $0.id != "app-store" }
        self.init(domains: automatic)
        var successful = Set<String>()
        var represented = Set<String>()
        var representedScopes = Set<String>()
        func requirement(_ item: TaskItemPresentation, domain: String) -> String {
            (item.sourceDomain ?? domain) + ":" + (item.sourceItemID ?? item.id)
        }
        for domain in automatic {
            for item in domain.items {
                let key = requirement(item, domain: domain.id)
                if item.resultGroup == "Success" && item.resultLabels.contains("Verified") && !item.resultNotRun {
                    successful.insert(key)
                }
                if item.hasResultProblemDetails && represented.insert(key).inserted {
                    successful.remove(key)
                    issues.append(Issue(id: key, title: item.item.title,
                        message: item.resultExplanation ?? "This requirement could not be completed or confirmed.",
                        nextAction: "Review its category details, then Refresh Preview.",
                        count: ["dependency_failed", "dependency_observation_failed"].contains(item.item.reason ?? "") ? nil : 1))
                }
            }
            if domain.resultCategoryIssue {
                let scopes = domain.resultProblemDomains.isEmpty ? [domain.id] : domain.resultProblemDomains.sorted()
                for scope in scopes where representedScopes.insert(scope).inserted {
                    issues.append(Issue(id: scope + ":category", title: CaptureCategory.title(for: scope),
                        message: domain.resultProblemMessages[scope] ?? domain.resultCategoryExplanation,
                        nextAction: "Review its category details, then Refresh Preview.", count: nil))
                }
            }
        }
        successful.subtract(represented)
        successfulCount = successful.count
        if let reason = RestoreExecutionPresentation.launcherFailureReason(events: result.diagnosticEvents, payload: result.structuredEvidence) {
            let message: String
            switch reason {
            case "launcher_destination_conflict": message = "An existing bs command prevents this launcher installation."
            case "launcher_inspection_failed": message = "The bs command installation could not be checked."
            case "launcher_verification_failed": message = "The bs command installation could not be confirmed."
            default: message = "Macseed Launcher could not be configured. The exact cause is available in View Log."
            }
            issues.insert(Issue(id: "launcher:scope", title: "Macseed Launcher", message: message,
                nextAction: "Review the launcher installation before retrying."), at: 0)
            representedScopes.insert("launcher")
        }
        // Stable finding identities retain independent operation failures outside plan rows.
        // Repeated module/terminal consequences do not manufacture extra issues.
        for finding in result.findings {
            let domain = String(finding.id.split(separator: ":").first ?? "")
            if domain == "app-store" || finding.id == "result-incomplete" { continue }
            if ["bootstrap_failed", "cancelled", "secure_cancelled"].contains(finding.reason ?? "") { continue }
            if representedScopes.contains(domain) || represented.contains(where: { finding.id.hasPrefix($0 + ":") }) { continue }
            if automatic.contains(where: { $0.id == domain || $0.items.contains(where: { $0.sourceDomain == domain }) }),
               represented.contains(where: { $0.hasPrefix(domain + ":") }), ["module_failed", "module_warning"].contains(finding.reason ?? "") { continue }
            guard represented.insert(finding.id).inserted else { continue }
            if !automatic.contains(where: { $0.id == domain || $0.items.contains(where: { $0.sourceDomain == domain }) }) {
                independentIssueTitles.append(finding.title)
            }
            issues.append(Issue(id: finding.id, title: finding.title, message: finding.action,
                nextAction: "Refresh Preview to check the remaining work.", count: nil))
        }
        if let appStore, !appStore.pending.isEmpty {
            let missing = Set(appStore.pending.filter { AppStoreRestorePresentation.status($0) == .missing }.map { $0.assistedAppStore?.appID ?? $0.id })
            let unverified = Set(appStore.pending.filter { AppStoreRestorePresentation.status($0) == .unverified }.map { $0.assistedAppStore?.appID ?? $0.id }).subtracting(missing)
            manualMissingCount = missing.count
            manualUnverifiedCount = unverified.count
            manualAttentionCount = missing.count + unverified.count
            issues.append(Issue(id: "app-store", title: "App Store Applications", message: appStore.resultSummary,
                nextAction: "", count: manualAttentionCount, appStore: true))
        }
        let complete = RestoreVerificationSummary(payload: result.structuredEvidence).complete
        let evidenceComplete = result.structuredEvidence?["verification"]?.object?["details"]?.object?["status"]?.string == "complete"
        let unknown = result.outcome == .interrupted || ((!complete || !evidenceComplete) && result.outcome != .clean)
        let unexplainedOutcome = [.attention, .partial, .failedBeforeMutation, .failedAfterMutation, .interrupted].contains(result.outcome)
        if issues.isEmpty && (unknown || unexplainedOutcome) {
            issues.append(Issue(id: "result-incomplete", title: complete ? "Rebuild result" : "Verification",
                message: complete ? "The remaining issue could not be identified precisely." : "Final requirement checks are unavailable.",
                nextAction: "Refresh Preview to inspect current state.", count: nil))
        }
        let automaticIssues = issues.filter { !$0.appStore }
        automaticAttentionCount = !unknown && automaticIssues.allSatisfy { $0.count != nil }
            ? automaticIssues.reduce(0) { $0 + ($1.count ?? 0) } : nil
    }
}

extension TaskDomainPresentation {
    var resultTitle: String {
        if resultCategoryIssue || items.contains(where: { $0.resultGroup == "Needs Attention" }) { return "Needs Attention" }
        if confirmedFinalState == .notRun || (!items.isEmpty && items.allSatisfy(\.resultNotRun)) { return "Not Run" }
        let requirements = items.filter { !$0.auxiliaryCompletionUnreported }
        if requirements.contains(where: { $0.resultGroup == "Success" }) && requirements.contains(where: { $0.resultGroup == nil && !$0.resultNotRun }) { return "Partial" }
        guard !requirements.isEmpty, requirements.allSatisfy({ $0.resultGroup == "Success" || $0.resultGroup == "Skipped" }) else { return "Outcome Unknown" }
        if requirements.allSatisfy({ ($0.resultLabels.contains("Already Matches") || $0.item.status == .matching) && !$0.resultLabels.contains("Applied") }) { return "Already Matches" }
        return "Completed"
    }
    var resultChildren: [TaskDomainPresentation] {
        guard id == "macOS Settings" || id == "macos-settings" else { return [] }
        let known = CaptureMacOSSettingsGroup.domainIDs
        let ids = known + Set(items.compactMap(\.sourceDomain)).subtracting(known).sorted()
        return ids.compactMap { domain in
            let members = items.filter { $0.sourceDomain == domain }
            guard !members.isEmpty else { return nil }
            return TaskDomainPresentation(id: domain, title: CaptureCategory.title(for: domain),
                symbol: WorkspaceCategoryStyle.symbol(domain), items: members, resultCategoryIssue: resultProblemDomains.contains(domain), resultCategoryMessage: resultProblemMessages[domain])
        }
    }
}

extension TaskDomainPresentation {
    var resultVisibleItems: [TaskItemPresentation] {
        items.filter { !$0.auxiliaryCompletionUnreported || resultCategoryIssue || $0.resultGroup == "Needs Attention" }
    }
    var resultCategoryExplanation: String {
        if let resultCategoryMessage { return resultCategoryMessage }
        return id.hasPrefix("macos-") || id == "macOS Settings"
            ? "Settings operation did not complete; the exact failed step was not reported."
            : "This category has an unresolved scope or an independent diagnostic issue. Review View Log for the reported cause."
    }
}

// A presentation partition only. Core plans and Global Verification retain every selected row.
struct AppStoreRestorePresentation {
    let items: [TaskItemPresentation]
    init(domains: [TaskDomainPresentation]) {
        items = domains.filter { $0.id == "app-store" }.flatMap(\.items)
    }
    static func status(_ item: TaskItemPresentation) -> AssistedAppStoreItem.Status {
        item.assistedAppStore?.status ?? .unverified
    }
    var installed: [TaskItemPresentation] { items.filter { Self.status($0) == .installed } }
    var pending: [TaskItemPresentation] {
        items.filter { Self.status($0) == .missing } + items.filter { Self.status($0) == .unverified }
    }
    var counts: [(String, Int)] {
        [("Installed", installed.count), ("Missing", missingCount), ("Unverified", unverifiedCount)].filter { $0.1 > 0 }
    }
    var categoryStatus: String {
        if allInstalled { return "All Installed" }
        if missingCount > 0 { return "Needs Attention" }
        return items.isEmpty ? "No applications selected" : "Unverified"
    }
    var categoryState: TaskRowState { allInstalled ? .matching : missingCount > 0 ? .attention : .unverified }
    var missingCount: Int { items.filter { Self.status($0) == .missing }.count }
    var unverifiedCount: Int { items.filter { Self.status($0) == .unverified }.count }
    var allInstalled: Bool { !items.isEmpty && pending.isEmpty }
    var attentionCount: Int { missingCount + unverifiedCount }
    var attentionBreakdown: String {
        [(missingCount, "missing"), (unverifiedCount, "unverified")].filter { $0.0 > 0 }
            .map { "\($0.0) \($0.1)" }.joined(separator: " · ")
    }
    var summary: String {
        var parts = ["\(installed.count) installed"]
        if missingCount > 0 { parts.append("\(missingCount) manual action\(missingCount == 1 ? "" : "s") required") }
        if unverifiedCount > 0 { parts.append("\(unverifiedCount) unverified") }
        return parts.joined(separator: " · ")
    }
    var resultSummary: String {
        var parts = ["\(installed.count) installed"]
        if missingCount > 0 { parts.append("\(missingCount) manual installation\(missingCount == 1 ? "" : "s") remaining") }
        if unverifiedCount > 0 { parts.append("\(unverifiedCount) unverified") }
        return parts.joined(separator: " · ")
    }
}
