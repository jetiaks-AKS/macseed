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
    var blockers: [CoreRestorePreparation.Condition] {
        conditions.filter { ["external_action_required", "unsupported"].contains($0.status) && !$0.isItemLocal }
    }
    var affectedDomains: [String] {
        blockers.reduce(into: []) { if !$0.contains($1.domain) { $0.append($1.domain) } }
    }
    static func status(_ conditions: [CoreRestorePreparation.Condition]) -> String {
        if conditions.contains(where: { ["authorization_required", "cask_authorization_required"].contains($0.code) }) { return "Authorization Required" }
        if conditions.contains(where: { $0.status == "unsupported" }) { return "Unsupported" }
        return "Prerequisite Required"
    }
    var title: String { ready && blockers.isEmpty ? "Ready" : "Needs Attention" }
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
    @RestoreSummaryState<Bool> private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if summary.title == "Ready" {
                DisclosureGroup(isExpanded: $expanded) {
                    if expanded {
                        ForEach(Array(summary.conditions.filter { !$0.isItemLocal }.enumerated()), id: \.offset) { _, condition in
                            RestorePrerequisiteView(condition: condition, label: label(condition), technicalTitle: "Technical Details")
                        }
                    }
                } label: {
                    HStack {
                        Text("Prerequisites").font(.headline)
                        Spacer()
                        Text("Ready").foregroundStyle(RestoreStatusTone.success.color)
                    }
                }.disclosureGroupStyle(HeaderDisclosureStyle())
                    .accessibilityLabel("Prerequisites")
                    .accessibilityValue("Ready, " + (expanded ? "expanded" : "collapsed"))
            } else {
                Text("Prerequisites").font(.headline)
                ForEach(summary.affectedDomains, id: \.self) { domain in
                    RestoreBlockingPrerequisiteAreaView(
                        title: areas.first { $0.id == domain }?.label ?? "Selected work",
                        conditions: summary.blockers.filter { $0.domain == domain })
                }
                if summary.blockers.isEmpty { Text("Needs Attention").foregroundStyle(RestoreStatusTone.warning.color) }
            }
        }
    }
    private func label(_ condition: CoreRestorePreparation.Condition) -> String {
        areas.first { $0.id == condition.domain }?.label ?? "Selected work"
    }
}

private struct RestoreBlockingPrerequisiteAreaView: View {
    let title: String
    let conditions: [CoreRestorePreparation.Condition]
    @RestoreSummaryState<Bool> private var expanded = false
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            if expanded {
                ForEach(Array(conditions.enumerated()), id: \.offset) { _, condition in
                    RestorePrerequisiteView(condition: condition, label: title, showsHeading: false, technicalTitle: "Technical Details")
                }
            }
        } label: {
            HStack {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(RestoreStatusTone.warning.color)
                    .accessibilityHidden(true)
                Text(title)
                Spacer()
                Text(status).foregroundStyle(RestoreStatusTone.warning.color)
            }
        }.disclosureGroupStyle(HeaderDisclosureStyle())
            .accessibilityLabel(title)
            .accessibilityValue(status + ", " + (expanded ? "expanded" : "collapsed"))
    }
    private var status: String { RestorePrerequisiteSummaryPresentation.status(conditions) }
}

// Preview owns area/count summaries only; domain sections own item details.
struct RestorePreviewAttentionSummaryView: View {
    let summary: RestoreIssueSummaryPresentation
    var body: some View {
        ForEach(summary.areas) { area in
            RestorePreviewAttentionAreaView(area: area)
        }
    }
}

private struct RestorePreviewAttentionAreaView: View {
    let area: RestoreIssueSummaryPresentation.Area
    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(RestoreStatusTone.warning.color)
                .accessibilityHidden(true)
            Text(area.title)
            Spacer()
            if area.unverifiedCount > 0 { Text("Unverified · " + String(area.unverifiedCount)).foregroundStyle(.secondary) }
            Text(String(area.items.count)).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(area.title)
        .accessibilityValue("\(area.items.count) affected items, \(area.unverifiedCount) unverified")
    }
}
