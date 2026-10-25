import SwiftUI

private typealias TaskViewState<Value> = SwiftUI.State<Value>

private struct WorkflowListViewportKey: EnvironmentKey {
    static let defaultValue = false
}
extension EnvironmentValues {
    var workflowListViewport: Bool {
        get { self[WorkflowListViewportKey.self] }
        set { self[WorkflowListViewportKey.self] = newValue }
    }
}

// The workspace supplies a bounded height. Standalone presentation renders keep
// their intrinsic size; only the list scrolls in a workflow window.
struct WorkflowList<Content: View>: View {
    @Environment(\.workflowListViewport) private var bounded
    @ViewBuilder let content: () -> Content
    var body: some View {
        if bounded {
            ScrollView {
                VStack(alignment: .leading, spacing: 20, content: content)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 1)
            }.frame(minHeight: 96, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 20, content: content)
        }
    }
}

enum WorkflowExpansion {
    static func allExpanded(_ expanded: Set<String>, available: Set<String>) -> Bool {
        !available.isEmpty && available.isSubset(of: expanded)
    }
    static func toggled(_ expanded: Set<String>, available: Set<String>) -> Set<String> {
        allExpanded(expanded, available: available) ? [] : available
    }
    static func binding(_ id: String, in tree: Binding<Set<String>>) -> Binding<Bool> {
        Binding(get: { tree.wrappedValue.contains(id) }, set: { value in
            if value { tree.wrappedValue.insert(id) } else { tree.wrappedValue.remove(id) }
        })
    }
}

// Retain the accepted Restore pill's dimensions, including a single-digit oval.
struct WorkflowCountPill: View {
    let count: Int
    let label: String
    let tint: Color
    var body: some View {
        Text(String(count)).font(.caption2.weight(.semibold)).monospacedDigit().lineLimit(1)
            .padding(.horizontal, 6).frame(minWidth: 32, minHeight: 23).fixedSize()
            .foregroundStyle(tint).background(tint.opacity(0.12), in: Capsule())
            .help(label).accessibilityLabel(label).accessibilityValue(String(count))
    }
}

// At most four measuring pills, independent of inventory size. Monospaced digits
// let the largest value in each visible position reserve that position's width.
struct WorkflowCountRailReference: View {
    let groups: [[Int]]
    private var values: [Int] {
        groups.reduce(into: [Int]()) { values, group in
            for (index, count) in group.enumerated() {
                if index == values.count { values.append(count) }
                else { values[index] = max(values[index], count) }
            }
        }
    }
    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, count in
                WorkflowCountPill(count: count, label: "", tint: .clear)
            }
        }.hidden().accessibilityHidden(true)
    }
}

// The existing outer layouts still own the status origin. This layout changes
// only the count rail and chevron, using the widest count group in this tree.
// If the rail cannot fit beside a status, counts wrap below without moving it.
struct WorkflowTrailingLayout: Layout {
    var showsCounts: Bool
    var showsChevron: Bool
    var statusWidth: CGFloat? = nil
    private func geometry(_ proposal: ProposedViewSize, _ views: Subviews) -> (width: CGFloat, status: CGSize, counts: CGSize, countX: CGFloat, stacked: Bool) {
        let idealStatus = views[0].sizeThatFits(.unspecified)
        let counts = views[1].sizeThatFits(.unspecified)
        let rail = max(counts.width, views[3].sizeThatFits(.unspecified).width)
        let arrow: CGFloat = showsChevron ? 20 : 0
        let ideal = (statusWidth ?? idealStatus.width) + (showsCounts ? 8 + counts.width : 0) + arrow
        let width = max(0, proposal.width ?? ideal)
        let countX = max(0, width - arrow - rail)
        let stacked = showsCounts && countX < (statusWidth ?? idealStatus.width) + 8
        let status = views[0].sizeThatFits(.init(width: stacked || !showsCounts ? max(0, width - arrow) : max(0, countX - 8), height: nil))
        return (width, status, counts, countX, stacked)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let g = geometry(proposal, subviews)
        let height = g.stacked ? g.status.height + 4 + g.counts.height : max(g.status.height, showsCounts ? g.counts.height : 0)
        return CGSize(width: g.width, height: max(height, showsChevron ? 12 : 0))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let g = geometry(.init(width: bounds.width, height: nil), subviews)
        let rowHeight = g.stacked ? g.status.height : bounds.height
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.minY + (rowHeight - g.status.height) / 2),
            anchor: .topLeading, proposal: .init(g.status))
        if showsCounts {
            subviews[1].place(at: CGPoint(x: bounds.minX + g.countX,
                y: bounds.minY + (g.stacked ? g.status.height + 4 : (rowHeight - g.counts.height) / 2)),
                anchor: .topLeading, proposal: .init(g.counts))
        }
        if showsChevron {
            subviews[2].place(at: CGPoint(x: bounds.maxX - 12, y: bounds.minY + rowHeight / 2),
                anchor: .leading, proposal: .init(width: 12, height: nil))
        }
        // Fourth child measures the rail only; it is never placed or accessible.
    }
}

struct RestoreTrailingControls<Status: View>: View {
    let status: Status
    let counts: [(String, Int)]
    var expanded: Bool? = nil
    var statusWidth: CGFloat? = nil
    @Environment(\.restoreTrailingSamples) private var samples
    var body: some View {
        WorkflowTrailingLayout(showsCounts: counts.contains { $0.1 > 0 }, showsChevron: expanded != nil, statusWidth: statusWidth) {
            status.fixedSize(horizontal: false, vertical: true)
            RestoreCountBadges(counts: counts)
            if let expanded { RestoreDisclosureIndicator(expanded: expanded) }
            else { Color.clear.frame(width: 0, height: 0).accessibilityHidden(true) }
            WorkflowCountRailReference(groups: counts.isEmpty ? [] : [counts.map(\.1)] + samples.map { $0.counts.filter { $0.1 > 0 }.map(\.1) })
        }
    }
}

extension TaskRowState {
    var tone: RestoreStatusTone {
        switch self {
        case .completed, .matching: .success
        case .partial, .attention, .unverified: .warning
        case .failed: .error
        default: .neutral
        }
    }
}

enum TaskRowLayout {
    static let statusWidth: CGFloat = 200
    static let iconWidth: CGFloat = 22
    static let columnSpacing: CGFloat = 12
    // Disclosure content ends at the header label's trailing edge. Reserve
    // the same status column and gap when wrapping Capture Result chips.
    static let contentStatusInset = statusWidth + columnSpacing
}

// Two bounded columns keep each status beside its own title at every row height.
struct TaskTextStatusLayout: Layout {
    static func widths(_ width: CGFloat) -> (text: CGFloat, status: CGFloat) {
        let available = max(0, width - 12)
        let status = min(TaskRowLayout.statusWidth, available * 0.42)
        return (available - status, status)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 520
        let columns = Self.widths(width)
        let text = subviews[0].sizeThatFits(.init(width: columns.text, height: nil))
        let status = subviews[1].sizeThatFits(.init(width: columns.status, height: nil))
        return CGSize(width: width, height: max(text.height, status.height))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let columns = Self.widths(bounds.width)
        subviews[0].place(at: bounds.origin, anchor: .topLeading,
                          proposal: .init(width: columns.text, height: nil))
        subviews[1].place(at: CGPoint(x: bounds.maxX - columns.status, y: bounds.minY), anchor: .topLeading,
                          proposal: .init(width: columns.status, height: nil))
    }
}

// A native Button owns the whole disclosure header, including its empty space.
struct TaskDisclosureStyle: DisclosureGroupStyle {
    var minimumHeight: CGFloat = 48
    var includesIndicator = true
    var contentTrailingInset: CGFloat = 26
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { configuration.isExpanded.toggle() } label: {
                HStack(spacing: 14) {
                    configuration.label.frame(maxWidth: .infinity, alignment: .leading)
                    if includesIndicator { Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .frame(width: 12).accessibilityHidden(true) }
                }.frame(maxWidth: .infinity, minHeight: minimumHeight, alignment: .leading)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
            if configuration.isExpanded { configuration.content.padding(.trailing, contentTrailingInset) }
        }
    }
}

// Preserve the existing Environment Status leaf appearance across workflows.
struct MatchedLeafIndicator: View {
    var body: some View {
        Image(systemName: "checkmark").foregroundStyle(RestoreStatusTone.success.color)
            .accessibilityLabel("Already Matches")
    }
}

struct TaskStatusLabel: View {
    let state: TaskRowState
    var title: String? = nil
    var tint: Color? = nil
    var showsTitle = true
    var body: some View {
        if state == .matching && !showsTitle {
            MatchedLeafIndicator().frame(width: TaskRowLayout.iconWidth)
        } else {
            HStack(spacing: 7) {
                if state == .working { ProgressView().controlSize(.small).frame(width: TaskRowLayout.iconWidth).accessibilityHidden(true) }
                else { Image(systemName: state.symbol).frame(width: TaskRowLayout.iconWidth).accessibilityHidden(true) }
                if showsTitle { Text(title ?? state.rawValue) }
            }.font(.callout).foregroundStyle(tint ?? (state == .planned ? Color.primary : state.tone.color))
                .accessibilityElement(children: .ignore).accessibilityLabel(title ?? state.rawValue)
        }
    }
}

struct OperationMetric: Identifiable {
    let title: String
    let count: Int
    let symbol: String
    let tone: RestoreStatusTone
    var id: String { title }
}

// Decisions depend only on the proposed width, never on content fitting feedback.
struct OperationSummaryLayout: Layout {
    let metricCount: Int
    static func metricWidth(_ count: Int) -> CGFloat { CGFloat(count) * 112 + CGFloat(max(0, count - 1)) * 10 }
    static func horizontal(width: CGFloat, count: Int) -> Bool { count == 0 || width >= 300 + 28 + metricWidth(count) }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 300 + 28 + Self.metricWidth(metricCount)
        let horizontal = Self.horizontal(width: width, count: metricCount)
        let metricsWidth = horizontal ? Self.metricWidth(metricCount) : width
        let headingWidth = horizontal && metricCount > 0 ? width - metricsWidth - 28 : width
        let heading = subviews[0].sizeThatFits(ProposedViewSize(width: headingWidth, height: nil))
        let metrics = subviews[1].sizeThatFits(ProposedViewSize(width: metricsWidth, height: nil))
        return CGSize(width: width, height: horizontal ? max(heading.height, metrics.height) : heading.height + 20 + metrics.height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let horizontal = Self.horizontal(width: bounds.width, count: metricCount)
        let metricsWidth = horizontal ? Self.metricWidth(metricCount) : bounds.width
        let headingWidth = horizontal && metricCount > 0 ? bounds.width - metricsWidth - 28 : bounds.width
        let headingSize = subviews[0].sizeThatFits(ProposedViewSize(width: headingWidth, height: nil))
        subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: headingWidth, height: nil))
        subviews[1].place(at: CGPoint(x: horizontal ? bounds.maxX - metricsWidth : bounds.minX,
                                     y: horizontal ? bounds.minY : bounds.minY + headingSize.height + 20),
                          anchor: .topLeading, proposal: ProposedViewSize(width: metricsWidth, height: nil))
    }
}

struct OperationMetricsLayout: Layout {
    static func columns(width: CGFloat, count: Int) -> Int { max(1, min(count, Int((max(0, width) + 10) / 122))) }
    private func geometry(width: CGFloat, subviews: Subviews) -> (Int, CGFloat) {
        let columns = Self.columns(width: width, count: subviews.count)
        let height = subviews.map { $0.sizeThatFits(ProposedViewSize(width: 112, height: nil)).height }.max() ?? 0
        return (columns, height)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let width = proposal.width ?? OperationSummaryLayout.metricWidth(subviews.count)
        let (columns, height) = geometry(width: width, subviews: subviews)
        let rows = (subviews.count + columns - 1) / columns
        return CGSize(width: width, height: CGFloat(rows) * height + CGFloat(rows - 1) * 10)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (columns, height) = geometry(width: bounds.width, subviews: subviews)
        for (index, view) in subviews.enumerated() {
            view.place(at: CGPoint(x: bounds.minX + CGFloat(index % columns) * 122, y: bounds.minY + CGFloat(index / columns) * (height + 10)),
                       anchor: .topLeading, proposal: ProposedViewSize(width: 112, height: height))
        }
    }
}

struct OperationSummaryHeader: View {
    let title: String
    let message: String
    let state: TaskRowState
    let counters: [(state: TaskRowState, count: Int)]
    var startedAt: Date? = nil
    var finishedAt: Date? = nil
    var suppliedMetrics: [OperationMetric]? = nil
    var scopeSummary: String? = nil
    private var metricValues: [OperationMetric] {
        suppliedMetrics ?? counters.map { OperationMetric(title: $0.state.rawValue, count: $0.count, symbol: $0.state.symbol, tone: $0.state.tone) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            OperationSummaryLayout(metricCount: metricValues.count) {
                heading
                OperationMetricsLayout { ForEach(metricValues) { value in metric(value) } }
            }
            Text(scopeSummary ?? "\(counters.reduce(0) { $0 + $1.count }) selected domains")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }
    private var heading: some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if state == .working { ProgressView().controlSize(.regular).frame(width: 30, height: 30) }
                else { Image(systemName: state.symbol).font(.system(size: 30, weight: .medium)).foregroundStyle(state.tone.color) }
            }.accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.title2.weight(.bold)).accessibilityAddTraits(.isHeader)
                Text(message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let startedAt {
                    if let finishedAt {
                        Text("Elapsed: \(Self.elapsed(startedAt, finishedAt)) · Finished: \(finishedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        TimelineView(.periodic(from: startedAt, by: 1)) { timeline in
                            Text("Elapsed: \(Self.elapsed(startedAt, timeline.date))").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func metric(_ value: OperationMetric) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: value.symbol).foregroundStyle(value.tone.color).accessibilityHidden(true)
                Text(String(value.count)).font(.title2.weight(.bold)).monospacedDigit()
            }
            Text(value.title).font(.caption.weight(.medium)).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, minHeight: 52, alignment: .leading).padding(10)
            .background(.background.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(value.title).accessibilityValue(String(value.count))
    }
    static func elapsed(_ start: Date, _ end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        return "\(seconds / 60)m \(seconds % 60)s"
    }
}

struct TaskDomainList: View {
    let domains: [TaskDomainPresentation]
    var stateTitles: [TaskRowState: String] = [:]
    var selectionStates: [String: SelectionState] = [:]
    var selectDomain: ((String, Bool) -> Void)? = nil
    var compactReadyItems = false
    var title = "Tasks"
    var leadingContent: AnyView? = nil
    var restoreSettingsPreview = false
    var captureResultLayout = false
    var settingsCategories: [TaskDomainPresentation] = []
    var settingLabels: [String: [String]] = [:]
    var itemTitles: [String: String] = [:]
    var expansion: Binding<Set<String>>? = nil
    var settingsExpansion: Binding<Bool>? = nil
    var prerequisiteReasons: [String: Set<String>] = [:]
    @TaskViewState<Set<String>> private var expanded = []
    static func disclosureIDs(_ domains: [TaskDomainPresentation], settings: [TaskDomainPresentation]) -> Set<String> {
        Set(domains.map(\.id) + (domains.contains { ["macos-settings", "macOS Settings"].contains($0.id) } ? settings.map(\.id) : []))
    }
    private var availableIDs: Set<String> { Self.disclosureIDs(domains, settings: settingsCategories) }
    private var treeExpansion: Binding<Set<String>> { Binding(get: { expandedIDs }, set: setExpanded) }
    private var expandedIDs: Set<String> { expansion?.wrappedValue ?? expanded }
    private func setExpanded(_ ids: Set<String>) {
        if let expansion { expansion.wrappedValue = ids } else { expanded = ids }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text(title).font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                expandAllButton
            }
            if !domains.isEmpty || leadingContent != nil {
                WorkflowList {
                    if let leadingContent { leadingContent }
                    if restoreSettingsPreview && !domains.isEmpty {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            WorkspaceSectionHeader(title: "Automatic Restore Tasks", prominent: true)
                        }
                    }
                    ForEach(WorkspaceCategoryStyle.sections(domains), id: \.title) { section in
                        WorkspaceSectionHeader(title: section.title)
                        VStack(spacing: 0) {
                            ForEach(section.rows) { domain in
                                if let selectDomain, let selection = selectionStates[domain.id] {
                                    HStack(alignment: .top, spacing: 0) {
                                        NativeSelectionCheckbox("", state: selection, accessibilityTitle: "Select " + domain.title) {
                                            selectDomain(domain.id, $0)
                                        }.frame(width: 28, height: 48).padding(.leading, 12)
                                        domainRow(domain)
                                    }
                                } else { domainRow(domain) }
                                if domain.id != section.rows.last?.id { Divider() }
                            }
                        }.modifier(WorkspaceCardSurface())
                    }
                }
            }
        }.transformEnvironment(\.restoreTrailingSamples) { samples in
            if restoreSettingsPreview {
                let rows = domains + settingsCategories
                let headers = rows.map {
                    RestoreTrailingSample(title: RestorePreviewCategoryStatus.title($0, stateTitles: stateTitles),
                        counts: RestorePreviewMetrics.badges($0))
                }
                let items = rows.flatMap(\.items).map { RestoreTrailingSample(title: $0.assistedAppStore?.status.rawValue ?? stateTitles[$0.state] ?? $0.state.rawValue, disclosure: false) }
                // Every visible row uses this hidden width reference. Retaining one
                // copy per item made expansion build a quadratic number of views.
                // Equal status, badge counts and disclosure measure identically.
                var seen = Set<String>()
                samples += (headers + items).filter {
                    let key = ($0.disclosure ? "header:" : "item:") + $0.title
                        + $0.counts.map { "|\($0.0):\($0.1)" }.joined()
                    return seen.insert(key).inserted
                }
            }
        }
    }

    @ViewBuilder private var expandAllButton: some View {
        if !availableIDs.isEmpty {
            Button(WorkflowExpansion.allExpanded(expandedIDs, available: availableIDs) ? "Collapse All" : "Expand All") {
                setExpanded(WorkflowExpansion.toggled(expandedIDs, available: availableIDs))
            }.buttonStyle(.plain).foregroundStyle(.secondary)
        }
    }

    private func domainRow(_ domain: TaskDomainPresentation) -> some View {
        DisclosureGroup(isExpanded: Binding(get: { expandedIDs.contains(domain.id) }, set: { value in
            var ids = expandedIDs
            if value { ids.insert(domain.id) } else { ids.remove(domain.id) }
            setExpanded(ids)
        })) {
            if ["macos-settings", "macOS Settings"].contains(domain.id), !settingsCategories.isEmpty {
                VStack(spacing: 0) {
                    ForEach(settingsCategories) { child in
                        TaskSettingsCategoryDetails(domain: child, stateTitles: stateTitles, compactReadyItems: compactReadyItems,
                            settingLabels: settingLabels[child.id] ?? [], itemTitles: itemTitles,
                            expansion: settingsExpansion ?? WorkflowExpansion.binding(child.id, in: treeExpansion),
                            restorePreview: restoreSettingsPreview, captureResultLayout: captureResultLayout)
                    }
                    let known = Set(settingsCategories.flatMap(\.items).map(\.id))
                    let remaining = domain.items.filter { !known.contains($0.id) }
                    if !remaining.isEmpty {
                        TaskDomainItems(domain: TaskDomainPresentation(id: domain.id, title: domain.title, symbol: domain.symbol, items: remaining),
                            stateTitles: stateTitles, compactReadyItems: compactReadyItems, itemTitles: itemTitles, restorePreview: restoreSettingsPreview,
                            captureResultLayout: captureResultLayout)
                    }
                }.padding(.leading, restoreSettingsPreview ? 0 : 36).padding(.trailing, restoreSettingsPreview ? 0 : -26).padding(.vertical, 4)
            } else {
                TaskDomainItems(domain: domain, stateTitles: stateTitles, compactReadyItems: compactReadyItems, itemTitles: itemTitles, restorePreview: restoreSettingsPreview,
                    captureResultLayout: captureResultLayout,
                    commonFailureInPrerequisites: prerequisiteReasons[domain.id]?.contains(domain.sharedObservationReason ?? "") == true)
            }
        } label: {
            if restoreSettingsPreview {
                RestorePreviewRow(title: domainTitle(domain),
                    status: RestorePreviewCategoryStatus(domain: domain, stateTitles: stateTitles),
                    counts: RestorePreviewMetrics.badges(domain),
                    expanded: expandedIDs.contains(domain.id)).padding(.vertical, 6)
            } else { ViewThatFits(in: .horizontal) {
                HStack(spacing: TaskRowLayout.columnSpacing) { domainTitle(domain); Spacer(); domainStatus(domain) }
                VStack(alignment: .leading, spacing: 8) { domainTitle(domain); domainStatus(domain).frame(maxWidth: .infinity, alignment: restoreSettingsPreview || captureResultLayout ? .trailing : .leading) }
            }.padding(.vertical, 6) }
        }.disclosureGroupStyle(TaskDisclosureStyle(includesIndicator: !restoreSettingsPreview, contentTrailingInset: restoreSettingsPreview ? 0 : 26)).padding(.horizontal, 16)
    }
    private func domainSummary(_ domain: TaskDomainPresentation) -> String {
        if compactReadyItems {
            let savedSubdomains = domain.items.filter { $0.captureRole == .selectedSubdomain && $0.state == .completed }.count
            if savedSubdomains > 0 { return "\(savedSubdomains) \(savedSubdomains == 1 ? "domain" : "domains") saved" }
            if domain.items.contains(where: { $0.captureRole == .configuration && $0.state == .completed }) { return "JSON configuration saved" }
            if domain.items.contains(where: { $0.captureRole == .wholeCategory && $0.state == .unverified }) { return "Item contents not reported" }
            if domain.items.contains(where: { $0.captureRole == .wholeCategory && $0.state == .completed }) { return "Supported configuration saved" }
            let count = domain.items.filter { [.planned, .completed].contains($0.state) }.count
            return "\(count) \(count == 1 ? "item" : "items") included"
        }
        guard !stateTitles.isEmpty else { return domain.summary }
        let counts = Dictionary(grouping: domain.items, by: \.state)
        return TaskRowState.allCases.compactMap { state in
            counts[state].map { "\($0.count) \((stateTitles[state] ?? state.rawValue).lowercased())" }
        }.joined(separator: " · ")
    }
    private func domainTitle(_ domain: TaskDomainPresentation) -> some View {
        WorkspaceCategoryTitle(id: domain.id, title: domain.title, fallbackSymbol: domain.symbol)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
    private func domainStatus(_ domain: TaskDomainPresentation) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            TaskStatusLabel(state: domain.state, title: stateTitles[domain.state])
            Text(domainSummary(domain)).font(.caption).foregroundStyle(.secondary)
        }.frame(width: TaskRowLayout.statusWidth, alignment: .leading)
    }
}

// Preview category labels retain attention priority; leaf statuses remain precise.
struct RestorePreviewCategoryStatus: View {
    let domain: TaskDomainPresentation
    let stateTitles: [TaskRowState: String]
    static func title(_ domain: TaskDomainPresentation, stateTitles: [TaskRowState: String]) -> String {
        guard !domain.items.isEmpty else { return "No Requirements" }
        return stateTitles[domain.state] ?? (domain.state == .unverified ? "Needs Attention" : domain.state.rawValue)
    }
    var body: some View {
        TaskStatusLabel(state: domain.items.isEmpty ? .notRun : domain.state,
            title: Self.title(domain, stateTitles: stateTitles),
            tint: !domain.items.isEmpty && domain.state == .planned ? .blue : nil)
    }
}

// Same parent-provided measurement reference for Preview categories and leaves.
// Only title contents receive indentation; every row retains the full container width.
struct RestorePreviewRow<Title: View, Status: View>: View {
    let title: Title
    let status: Status
    var counts: [(String, Int)] = []
    var titleInset: CGFloat = 0
    var expanded: Bool? = nil
    var body: some View {
        RestoreResultColumns {
            title.padding(.leading, titleInset).fixedSize(horizontal: false, vertical: true)
            RestoreTrailingControls(status: status, counts: counts, expanded: expanded, statusWidth: TaskRowLayout.statusWidth)
                .frame(maxWidth: .infinity, alignment: .leading)
            RestoreTrailingReference(statusWidth: TaskRowLayout.statusWidth)
        }
    }
}

struct TaskDomainItems: View {
    let domain: TaskDomainPresentation
    var stateTitles: [TaskRowState: String] = [:]
    var compactReadyItems = false
    var itemTitles: [String: String] = [:]
    var restorePreview = false
    var captureResultLayout = false
    var commonFailureInPrerequisites = false
    var body: some View {
        let sharedIDs = domain.sharedObservationItemIDs
        if compactReadyItems {
            CaptureConfirmationItems(domain: domain)
                .padding(.trailing, captureResultLayout ? TaskRowLayout.contentStatusInset : 0)
        } else {
            VStack(spacing: 0) {
                if !commonFailureInPrerequisites, let message = domain.sharedObservationMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                }
                ForEach(domain.items) { item in
                    if restorePreview {
                        RestorePreviewRow(title: details(item, suppressExplanation: sharedIDs.contains(item.id)),
                            status: TaskStatusLabel(state: item.state, title: item.assistedAppStore?.status.rawValue ?? stateTitles[item.state],
                                showsTitle: item.state != .matching),
                            titleInset: 36).padding(.vertical, 7)
                    } else { TaskTextStatusLayout {
                        details(item, suppressExplanation: sharedIDs.contains(item.id)).fixedSize(horizontal: false, vertical: true)
                        TaskStatusLabel(state: item.state, title: item.assistedAppStore?.status.rawValue ?? stateTitles[item.state])
                            .fixedSize(horizontal: false, vertical: true)
                    }.padding(.vertical, 7) }
                }
            }.padding(.leading, restorePreview ? 0 : 36).padding(.vertical, 4)
        }
    }
    private func details(_ item: TaskItemPresentation, suppressExplanation: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(itemTitles[item.id] ?? item.item.title)
            if !suppressExplanation, !item.item.action.isEmpty, item.state != .matching {
                Text(item.assistedAppStore?.message ?? item.item.action).font(.caption).foregroundStyle(.secondary)
            }
            if let url = item.assistedAppStore?.productURL { AppStoreProductButton(url: url) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PendingOperationLogButton: View {
    var body: some View {
        Text("Log unavailable").font(.caption).foregroundStyle(.secondary)
    }
}

// A read-only nested category over existing task items; no selection or lifecycle logic.
struct TaskSettingsCategoryDetails: View {
    let domain: TaskDomainPresentation
    let stateTitles: [TaskRowState: String]
    let compactReadyItems: Bool
    var settingLabels: [String] = []
    var itemTitles: [String: String] = [:]
    var expansion: Binding<Bool>? = nil
    var restorePreview = false
    var captureResultLayout = false
    @TaskViewState<Bool> private var expanded = false
    var body: some View {
        DisclosureGroup(isExpanded: expansion ?? $expanded) {
            if restorePreview {
                VStack(spacing: 0) {
                    ForEach(domain.items) { item in
                        RestoreSettingPreviewLeaf(item: item, title: itemTitles[item.id] ?? item.item.title, stateTitles: stateTitles)
                    }
                }.padding(.vertical, 4)
            } else if settingLabels.isEmpty || domain.items.contains(where: {
                $0.captureRole != .selectedSubdomain || ![.planned, .completed].contains($0.state)
                    || $0.item.reason != nil || $0.diagnostic != nil
            }) {
                TaskDomainItems(domain: domain, stateTitles: stateTitles, compactReadyItems: compactReadyItems, itemTitles: itemTitles,
                    captureResultLayout: captureResultLayout)
            }
            if !settingLabels.isEmpty {
                if compactReadyItems {
                    CaptureIncludedSettingsList(labels: settingLabels)
                        .padding(.trailing, captureResultLayout ? TaskRowLayout.contentStatusInset : 0)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(settingLabels.enumerated()), id: \.offset) { _, label in
                            Text(label).padding(.vertical, 7)
                        }
                    }.padding(.leading, 36).padding(.vertical, 4)
                }
            }
        } label: {
            if restorePreview {
                RestorePreviewRow(title: title, status: RestorePreviewCategoryStatus(domain: domain, stateTitles: stateTitles),
                    counts: RestorePreviewMetrics.badges(domain),
                    titleInset: 36, expanded: expansion?.wrappedValue ?? expanded).padding(.vertical, 6)
            } else { ViewThatFits(in: .horizontal) {
                HStack(spacing: TaskRowLayout.columnSpacing) { title; Spacer(); status }
                VStack(alignment: .leading, spacing: 8) { title; status.frame(maxWidth: .infinity, alignment: .trailing) }
            }.padding(.vertical, 6) }
        }.disclosureGroupStyle(TaskDisclosureStyle(includesIndicator: !restorePreview,
            contentTrailingInset: restorePreview ? 0 : 26))
    }
    private var title: some View { WorkspaceCategoryTitle(id: domain.id, title: domain.title, fallbackSymbol: domain.symbol) }
    private var status: some View {
        TaskStatusLabel(state: domain.state, title: stateTitles[domain.state])
            .frame(width: TaskRowLayout.statusWidth, alignment: .leading)
    }
}

// Restore-only compact leaves retain typed task diagnostics and nonmatching statuses.
struct RestoreSettingPreviewLeaf: View {
    let item: TaskItemPresentation
    let title: String
    var stateTitles: [TaskRowState: String] = [:]
    var compactMatch: Bool {
        item.state == .matching && item.item.status == .matching && item.item.reason == nil && item.diagnostic == nil
    }
    var body: some View {
        RestorePreviewRow(title: details, status: status, titleInset: 72)
            .padding(.vertical, 7).frame(minHeight: 28)
    }
    private var details: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            if !compactMatch && !item.item.action.isEmpty {
                Text(item.item.action).font(.caption).foregroundStyle(.secondary)
            }

        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var status: some View {
        TaskStatusLabel(state: item.state, title: stateTitles[item.state], showsTitle: item.state != .matching)
    }
}

// Fixed Apple product URLs come only from validated numeric Core identities.
// NSWorkspace opens the page; it cannot confirm installation or modify the plan.
struct AppStoreProductButton: View {
    let url: URL
    @TaskViewState<Bool> private var failed = false
    static func open(_ url: URL, using opener: (URL) -> Bool = NSWorkspace.shared.open) -> Bool {
        guard url.scheme == "macappstore", url.host == "apps.apple.com",
              url.query == nil, url.fragment == nil,
              url.path.hasPrefix("/app/id"),
              AssistedAppStoreItem.productURL(String(url.path.dropFirst(7))) == url else { return false }
        return opener(url)
    }
    var body: some View {
        Button("Open in App Store") { failed = !Self.open(url) }.buttonStyle(.bordered).controlSize(.small)
        if failed { Text("Could not open App Store. Try again.").font(.caption).foregroundStyle(.secondary) }
    }
}
