import Foundation

// A read-only projection of the accepted Preview and existing structured evidence.
// No readiness, mutation or Verification decisions belong here.
enum TaskRowState: String, CaseIterable {
    case completed = "Completed", partial = "Partial Success", attention = "Needs Attention"
    case skipped = "Skipped", failed = "Failed", working = "Working", waiting = "Waiting"
    case planned = "Changes Planned", matching = "Already Matches", unverified = "Unverified"
    case awaitingVerification = "Awaiting Verification"
    var symbol: String {
        switch self {
        case .completed, .matching: "checkmark.circle.fill"
        case .partial, .attention, .unverified: "exclamationmark.triangle.fill"
        case .skipped: "minus.circle.fill"
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
        return states.allSatisfy { $0 == .matching } ? .matching : .completed
    }
}

struct TaskItemPresentation: Identifiable {
    let id: String
    let item: DisplayItem
    let state: TaskRowState
    var diagnostic: CoreRestorePreparation.Diagnostic? = nil
}
struct TaskDomainPresentation: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let items: [TaskItemPresentation]
    var activityState: TaskRowState? = nil
    var previewOnly = false
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
         result: RestoreExecutionPresentation? = nil, executing: Bool = false) {
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
                if $0.status == .working || $0.restoreActivity != nil { return domainActive ? .working : nil }
                return $0.status == .complete ? .completed : $0.status == .attention ? .attention : nil
            }
            let items = category.items.filter { item in
                guard executing, result == nil else { return true }
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
                let state: TaskRowState
                if !executing && result == nil {
                    state = item.status == .matching ? .matching : item.status == .ready ? .planned
                        : item.status == .unverified ? .unverified : .attention
                } else if operation?["outcome"]?.string == "skipped" {
                    state = .skipped
                } else if operation?["outcome"]?.string == "failure" {
                    state = .failed
                } else if observed?["conformity"]?.string == "verified" || result?.outcome == .clean {
                    state = .completed
                } else if observed != nil {
                    state = .unverified
                } else if item.status == .matching {
                    // Preserve the known Preview observation, without claiming final Verification.
                    state = .matching
                } else if item.requiresAttention {
                    state = item.status == .unverified ? .unverified : .attention
                } else if result != nil {
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
                let reason = operation?["reason"]?.string ?? observed?["reason"]?.string ?? item.reason
                let message: String
                switch reason {
                case "cask_execution_requirements_unsupported": message = "This application's installation requirements are not supported."
                case "item_stalled_timeout": message = "No observable progress. Check the network or VPN, then Refresh Preview."
                case "dependency_failed": message = "A required dependency did not complete."
                case "privileged_lifecycle_unknown": message = "Privileged work may continue. Inspect Homebrew before another Rebuild."
                case "cask_authorization_required": message = "Administrator authorization was not completed."
                default: message = state == .completed ? "Verified against the saved environment."
                    : executing && state == .working
                        ? (entry?.action == "reinstall" ? "Repairing or verifying this item…" : "Applying or verifying this item…")
                    : state == .awaitingVerification
                        ? "Awaiting Verification." : item.action
                }
                return TaskItemPresentation(id: item.id,
                    item: DisplayItem(id: item.id, title: item.title, status: item.status, action: message, reason: reason), state: state, diagnostic: entry?.diagnostic)
            }
            if items.isEmpty { continue }
            output.append(TaskDomainPresentation(id: domainID, title: category.title,
                symbol: Self.symbol(category.id), items: items, activityState: activityState, previewOnly: !executing && result == nil))
        }
        domains = output
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
