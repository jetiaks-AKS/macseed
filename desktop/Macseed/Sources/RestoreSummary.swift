import SwiftUI

private typealias RestoreSummaryState<Value> = SwiftUI.State<Value>

// Presentation only: retain the supplied findings and their evidence status.
struct RestoreIssueSummaryPresentation {
    struct Area: Identifiable {
        let id: String
        let title: String
        let items: [DisplayItem]
        var unverifiedCount: Int { items.filter { $0.status == .unverified || $0.status == .unresolved }.count }
    }
    let areas: [Area]
    var count: Int { areas.reduce(0) { $0 + $1.items.count } }
    var attentionCount: Int { areas.flatMap(\.items).filter { $0.status != .unverified && $0.status != .unresolved }.count }
    var unverifiedCount: Int { count - attentionCount }
    var detailsInitiallyExpanded: Bool { false }
    var title: String {
        if unverifiedCount == 0 { return "\(count) \(count == 1 ? "item needs" : "items need") attention" }
        if attentionCount == 0 { return "\(count) \(count == 1 ? "item is" : "items are") unverified" }
        return "\(attentionCount) need attention · \(unverifiedCount) unverified"
    }
    init(categories: [DisplayCategory]) {
        var order: [String] = []
        var titles: [String: String] = [:]
        var items: [String: [DisplayItem]] = [:]
        for category in categories {
            for item in category.items where item.requiresAttention {
                if items[category.id] == nil { order.append(category.id); titles[category.id] = category.title }
                if items[category.id]?.contains(where: { $0.id == item.id && $0.status == item.status && $0.reason == item.reason }) != true {
                    items[category.id, default: []].append(Self.readable(item))
                }
            }
        }
        areas = order.map { Area(id: $0, title: titles[$0]!, items: items[$0]!) }
    }
    static func result(_ findings: [DisplayItem], catalog: CoreRestoreInspection.Inventory?) -> Self {
        var categories: [DisplayCategory] = []
        for item in findings {
            let domain = catalog?.inventory.first { item.id == $0.id || item.id.hasPrefix($0.id + ":") }
            let group = catalog?.groups.first { $0.id == "macOS Settings" && $0.domains.contains(domain?.id ?? "") }
            let id = group?.id ?? domain?.id ?? item.id
            let title = group?.id ?? domain?.label ?? item.title
            let concrete = findings.contains {
                $0.id.hasPrefix(id + ":") && $0.status == item.status
                    && (item.reason == nil || $0.reason == item.reason)
            }
            // The existing normalizer may supply both an area and its concrete
            // item. Keep separate Unverified evidence; suppress only repetition.
            if item.id == id && item.status == .attention && concrete { continue }
            categories.append(DisplayCategory(id: id, title: title, symbol: "exclamationmark.triangle", items: [item]))
        }
        return Self(categories: categories)
    }
    private static func readable(_ item: DisplayItem) -> DisplayItem {
        let message: String
        switch item.reason {
        case "cask_execution_requirements_unsupported": message = "This application's installation requirements are not supported."
        case "target_conflict": message = "The current value differs from the saved environment and is preserved."
        default: message = item.action
        }
        return DisplayItem(id: item.id, title: item.title, status: item.status, action: message, reason: item.reason)
    }
}

struct RestorePrerequisiteSummaryPresentation {
    let conditions: [CoreRestorePreparation.Condition]
    let ready: Bool
    var hasInstallerPreparations = false
    var operationAvailabilityMessage: String? {
        conditions.contains(where: { $0.isPreviewOnlyLimitation })
            ? CoreRestorePreparation.workspacePreviewReasons["workspace_restore_not_enabled"] : nil
    }
    var needsAttention: Bool {
        (!ready && operationAvailabilityMessage == nil) || !blockers.isEmpty || hasInstallerPreparations
    }
    var canFixIssues: Bool { hasInstallerPreparations || blockers.contains { $0.diagnostic?.automationPreparationAvailable == true } }
    var isVisible: Bool { !isTerminalReady || hasInstallerPreparations }
    var displayConditions: [CoreRestorePreparation.Condition] {
        blockers + conditions.filter { hasInstallerPreparations && $0.isItemLocal
            && $0.diagnostic?.primitive == "pkgutil" && $0.diagnostic?.condition == "preparation_required" }
    }
    var blockers: [CoreRestorePreparation.Condition] {
        let actionable = conditions.filter { ["external_action_required", "unsupported"].contains($0.status)
            && !$0.isItemLocal && !$0.isPreviewOnlyLimitation }
        var seen = Set<String>()
        return actionable.filter { condition in
            // An aggregate inspection consequence is not another root cause.
            // Keep every supplied condition unchanged for support/Core evidence.
            if condition.code == "preview_observation_failed" && actionable.contains(where: {
                $0.domain == condition.domain && $0.code != condition.code && $0.diagnostic?.valid == true
                    && ["authorization_required", "authorization_denied", "application_unavailable",
                        "observation_failed", "malformed_observation", "observation_limit", "identity_ambiguous"]
                        .contains($0.diagnostic?.condition ?? "")
            }) { return false }
            // Only shared tool prerequisites lose their item index. Item-local
            // conflicts/ownership/installer requirements keep their identity.
            let shared = condition.scope != "item" && condition.diagnostic == nil
                && ["homebrew_unavailable", "homebrew_installation_requires_interaction",
                    "homebrew_capability_unavailable", "vscode_cli_required", "vscode_cli_unavailable",
                    "git_required", "git_unavailable", "internet_required", "command_line_tools_required"].contains(condition.code)
            let identity = [condition.domain, condition.scope ?? "", condition.status, condition.code,
                shared ? "shared" : String(condition.selectedItemIndex ?? 0),
                condition.diagnostic?.technicalDescription ?? ""].joined(separator: "\u{0}")
            return seen.insert(identity).inserted
        }
    }
    var affectedDomains: [String] {
        displayConditions.reduce(into: []) { if !$0.contains($1.domain) { $0.append($1.domain) } }
    }
    var preparationCount: Int {
        let installers = displayConditions.filter { $0.isItemLocal }
        let installerCount = Set(installers.map { $0.domain + ":" + String($0.selectedItemIndex ?? 0) }).count
        return max(installerCount, hasInstallerPreparations ? 1 : 0)
            + blockers.filter { $0.diagnostic?.automationPreparationAvailable == true }.count
    }
    var preparationMessage: String {
        "\(preparationCount) preparation \(preparationCount == 1 ? "requirement needs" : "requirements need") attention."
    }
    var manualConditions: [CoreRestorePreparation.Condition] {
        blockers.filter { $0.diagnostic?.automationPreparationAvailable != true }
    }
    var manualDomains: [String] {
        manualConditions.reduce(into: []) { if !$0.contains($1.domain) { $0.append($1.domain) } }
    }
    var sharedReasons: [String: Set<String>] {
        Dictionary(grouping: manualConditions.filter { $0.scope != "item" && $0.diagnostic == nil }, by: \.domain)
            .mapValues { Set($0.map(\.code)) }
    }
    static func status(_ conditions: [CoreRestorePreparation.Condition]) -> String {
        if conditions.contains(where: { ["authorization_required", "cask_authorization_required"].contains($0.code) }) { return "Authorization Required" }
        if conditions.contains(where: { $0.status == "unsupported" && $0.diagnostic?.condition != "preparation_required" }) { return "Unsupported" }
        if conditions.contains(where: { $0.diagnostic?.condition == "preparation_required" }) { return "Preparation Required" }
        return "Action Required"
    }
    var isTerminalReady: Bool { ready && blockers.isEmpty }
    var title: String {
        canFixIssues ? "Needs Preparation" : needsAttention ? "Needs Attention"
            : operationAvailabilityMessage != nil ? "Preview completed" : "Ready"
    }
    var detailsInitiallyExpanded: Bool { false }
}

struct RestoreIssueSummaryView: View {
    let summary: RestoreIssueSummaryPresentation
    let isResult: Bool
    @RestoreSummaryState<Bool> private var detailsExpanded = false
    var body: some View {
        if summary.count > 0 {
            VStack(alignment: .leading, spacing: 6) {
                Label(isResult ? "\(summary.count) \(summary.count == 1 ? "issue" : "issues") to review" : summary.title,
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(RestoreStatusTone.warning.color)
                ForEach(summary.areas) { area in
                    HStack {
                        Text(area.title + " · " + String(area.items.count))
                        if area.unverifiedCount > 0 { Text("Unverified · " + String(area.unverifiedCount)).foregroundStyle(.secondary) }
                    }.font(.callout)
                }
                DisclosureGroup("Show Details", isExpanded: $detailsExpanded) {
                    ForEach(summary.areas) { area in
                        Text(area.title).font(.headline)
                        RestorePreviewItemDetails(items: area.items)
                    }
                }.disclosureGroupStyle(HeaderDisclosureStyle())
            }
        }
    }
}

struct RestorePrerequisiteSummaryView: View {
    let summary: RestorePrerequisiteSummaryPresentation
    let areas: [CoreRestoreInspection.Area]
    var body: some View {
        if !summary.manualConditions.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                if !summary.manualConditions.isEmpty {
                    Text("Prerequisites").font(.headline)
                    ForEach(summary.manualDomains, id: \.self) { domain in
                        RestoreBlockingPrerequisiteAreaView(
                            title: areas.first { $0.id == domain }?.label ?? "Selected work",
                            conditions: summary.manualConditions.filter { $0.domain == domain })
                    }
                }
            }.padding(.horizontal, 16)
        }
    }
}

private struct RestoreBlockingPrerequisiteAreaView: View {
    let title: String
    let conditions: [CoreRestorePreparation.Condition]
    @RestoreSummaryState<Bool> private var expanded = true
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            if expanded {
                ForEach(Array(conditions.enumerated()), id: \.offset) { _, condition in
                    RestorePrerequisiteView(condition: condition, label: title, showsHeading: false)
                }
            }
        } label: {
            HStack {
                Image(systemName: "exclamationmark.triangle")
                    .frame(width: TaskRowLayout.iconWidth)
                    .foregroundStyle(RestoreStatusTone.warning.color)
                    .accessibilityHidden(true)
                Text(title)
                Spacer()
                Text(status).foregroundStyle(RestoreStatusTone.warning.color)
                    .frame(width: TaskRowLayout.statusWidth, alignment: .leading)
            }
        }.disclosureGroupStyle(TaskDisclosureStyle())
            .accessibilityLabel(title)
            .accessibilityValue(status + ", " + (expanded ? "expanded" : "collapsed"))
    }
    private var status: String { RestorePrerequisiteSummaryPresentation.status(conditions) }
}

// Preview owns area/count summaries only; domain sections own item details.
struct RestorePreviewAttentionSummaryView: View {
    let summary: RestoreIssueSummaryPresentation
    var body: some View {
        if !summary.areas.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Needs Attention").font(.headline).accessibilityAddTraits(.isHeader)
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    ForEach(summary.areas) { area in
                        RestorePreviewAttentionAreaView(area: area)
                    }
                }
            }
        }
    }
}

private struct RestorePreviewAttentionAreaView: View {
    let area: RestoreIssueSummaryPresentation.Area
    var body: some View {
        GridRow {
            HStack {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(RestoreStatusTone.warning.color)
                    .accessibilityHidden(true)
                Text(area.title)
            }
            HStack {
                Text(String(area.items.count)).foregroundStyle(.secondary).monospacedDigit()
                if area.unverifiedCount > 0 { Text("Unverified · " + String(area.unverifiedCount)).foregroundStyle(.secondary) }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(area.title)
        .accessibilityValue("\(area.items.count) affected items, \(area.unverifiedCount) unverified")
    }
}
