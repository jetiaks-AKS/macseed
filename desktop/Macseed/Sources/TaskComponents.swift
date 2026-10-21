import SwiftUI

private typealias TaskViewState<Value> = SwiftUI.State<Value>

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

struct TaskStatusLabel: View {
    let state: TaskRowState
    var title: String? = nil
    var body: some View {
        HStack(spacing: 7) {
            if state == .working { ProgressView().controlSize(.small).frame(width: TaskRowLayout.iconWidth).accessibilityHidden(true) }
            else { Image(systemName: state.symbol).frame(width: TaskRowLayout.iconWidth).accessibilityHidden(true) }
            Text(title ?? state.rawValue)
        }.font(.callout).foregroundStyle(state == .planned ? Color.primary : state.tone.color)
            .accessibilityElement(children: .ignore).accessibilityLabel(title ?? state.rawValue)
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
    @TaskViewState<Set<String>> private var expanded = []
    private var expandedIDs: Set<String> { expansion?.wrappedValue ?? expanded }
    private func setExpanded(_ ids: Set<String>) {
        if let expansion { expansion.wrappedValue = ids } else { expanded = ids }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text(title).font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                if !restoreSettingsPreview { expandAllButton }
            }
            if let leadingContent { leadingContent }
            if restoreSettingsPreview && !domains.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    WorkspaceSectionHeader(title: "Automatic Restore Tasks", prominent: true)
                    expandAllButton.fixedSize()
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
        }.transformEnvironment(\.restoreTrailingSamples) { samples in
            if restoreSettingsPreview {
                let rows = domains + settingsCategories
                let headers = rows.map { RestoreTrailingSample(title: stateTitles[$0.state] ?? $0.state.rawValue) }
                let items = rows.flatMap(\.items).map { RestoreTrailingSample(title: $0.assistedAppStore?.status.rawValue ?? stateTitles[$0.state] ?? $0.state.rawValue, disclosure: false) }
                // Every visible row uses this hidden width reference. Retaining one
                // copy per item made expansion build a quadratic number of views.
                // Equal status text + disclosure measures identically; keep it once.
                var seen = Set<String>()
                samples += (headers + items).filter {
                    seen.insert(($0.disclosure ? "header:" : "item:") + $0.title).inserted
                }
            }
        }
    }

    private var expandAllButton: some View {
        Button(expandedIDs.count == domains.count ? "Collapse All" : "Expand All") {
            setExpanded(expandedIDs.count == domains.count ? [] : Set(domains.map(\.id)))
        }.buttonStyle(.plain).foregroundStyle(.secondary)
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
                            settingLabels: settingLabels[child.id] ?? [], itemTitles: itemTitles, expansion: settingsExpansion,
                            restorePreview: restoreSettingsPreview, captureResultLayout: captureResultLayout)
                    }
                    let known = Set(settingsCategories.flatMap(\.items).map(\.id))
                    let remaining = domain.items.filter { !known.contains($0.id) }
                    if !remaining.isEmpty {
                        TaskDomainItems(domain: TaskDomainPresentation(id: domain.id, title: domain.title, symbol: domain.symbol, items: remaining),
                            stateTitles: stateTitles, compactReadyItems: compactReadyItems, itemTitles: itemTitles, restorePreview: restoreSettingsPreview)
                    }
                }.padding(.leading, restoreSettingsPreview ? 0 : 36).padding(.trailing, captureResultLayout ? -26 : 0).padding(.vertical, 4)
            } else {
                TaskDomainItems(domain: domain, stateTitles: stateTitles, compactReadyItems: compactReadyItems, itemTitles: itemTitles, restorePreview: restoreSettingsPreview)
            }
        } label: {
            if restoreSettingsPreview {
                RestorePreviewRow(title: domainTitle(domain),
                    status: TaskStatusLabel(state: domain.state, title: stateTitles[domain.state]),
                    expanded: expandedIDs.contains(domain.id)).padding(.vertical, 6)
            } else { ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { domainTitle(domain); Spacer(); domainStatus(domain) }
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

// Same parent-provided measurement reference for Preview categories and leaves.
// Only title contents receive indentation; every row retains the full container width.
struct RestorePreviewRow<Title: View, Status: View>: View {
    let title: Title
    let status: Status
    var titleInset: CGFloat = 0
    var expanded: Bool? = nil
    var body: some View {
        RestoreResultColumns {
            title.padding(.leading, titleInset).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                status.fixedSize(horizontal: false, vertical: true)
                if let expanded { RestoreDisclosureIndicator(expanded: expanded) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            RestoreTrailingReference()
        }
    }
}

struct TaskDomainItems: View {
    let domain: TaskDomainPresentation
    var stateTitles: [TaskRowState: String] = [:]
    var compactReadyItems = false
    var itemTitles: [String: String] = [:]
    var restorePreview = false
    static func showsTechnicalDetails(_ item: TaskItemPresentation) -> Bool {
        item.assistedAppStore == nil && item.state != .working && item.item.reason != nil
    }
    var body: some View {
        if compactReadyItems {
            CaptureConfirmationItems(domain: domain)
        } else {
            VStack(spacing: 0) {
                ForEach(domain.items) { item in
                    if restorePreview {
                        RestorePreviewRow(title: details(item),
                            status: TaskStatusLabel(state: item.state, title: item.assistedAppStore?.status.rawValue ?? stateTitles[item.state]),
                            titleInset: 36).padding(.vertical, 7)
                    } else { TaskTextStatusLayout {
                        details(item).fixedSize(horizontal: false, vertical: true)
                        TaskStatusLabel(state: item.state, title: item.assistedAppStore?.status.rawValue ?? stateTitles[item.state])
                            .fixedSize(horizontal: false, vertical: true)
                    }.padding(.vertical, 7) }
                }
            }.padding(.leading, restorePreview ? 0 : 36).padding(.vertical, 4)
        }
    }
    private func details(_ item: TaskItemPresentation) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(itemTitles[item.id] ?? item.item.title)
            Text(item.assistedAppStore?.message ?? item.item.action).font(.caption).foregroundStyle(.secondary)
            if let url = item.assistedAppStore?.productURL { AppStoreProductButton(url: url) }
            if Self.showsTechnicalDetails(item), let reason = item.item.reason {
                DisclosureGroup("Technical Details") {
                    Text(reason).font(.caption.monospaced()).textSelection(.enabled)
                    if let diagnostic = item.diagnostic {
                        Text(diagnostic.technicalDescription).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }.disclosureGroupStyle(TaskDisclosureStyle(minimumHeight: 22)).font(.caption)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PendingOperationLogButton: View {
    var body: some View {
        Button {} label: { Label("View Log", systemImage: "doc.text") }
            .disabled(true).help("Persistent Desktop operation logs are not available in this build.")
            .accessibilityHint("Persistent Desktop operation logs are not available in this build.")
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
                TaskDomainItems(domain: domain, stateTitles: stateTitles, compactReadyItems: compactReadyItems, itemTitles: itemTitles)
            }
            if !settingLabels.isEmpty {
                if compactReadyItems {
                    CaptureIncludedSettingsList(labels: settingLabels)
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
                RestorePreviewRow(title: title, status: TaskStatusLabel(state: domain.state, title: stateTitles[domain.state]),
                    titleInset: 36, expanded: expansion?.wrappedValue ?? expanded).padding(.vertical, 6)
            } else { ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { title; Spacer(); TaskStatusLabel(state: domain.state, title: stateTitles[domain.state]).frame(width: restorePreview || captureResultLayout ? TaskRowLayout.statusWidth : nil, alignment: .leading) }
                VStack(alignment: .leading, spacing: 8) { title; TaskStatusLabel(state: domain.state, title: stateTitles[domain.state]).frame(width: restorePreview || captureResultLayout ? TaskRowLayout.statusWidth : nil, alignment: .leading).frame(maxWidth: .infinity, alignment: restorePreview || captureResultLayout ? .trailing : .leading) }
            }.padding(.vertical, 6) }
        }.disclosureGroupStyle(TaskDisclosureStyle(includesIndicator: !restorePreview, contentTrailingInset: restorePreview ? 0 : 26))
    }
    private var title: some View { WorkspaceCategoryTitle(id: domain.id, title: domain.title, fallbackSymbol: domain.symbol) }
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
            if let reason = item.item.reason {
                DisclosureGroup("Technical Details") {
                    Text(reason).font(.caption.monospaced()).textSelection(.enabled)
                    if let diagnostic = item.diagnostic {
                        Text(diagnostic.technicalDescription).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }.disclosureGroupStyle(TaskDisclosureStyle(minimumHeight: 22))
            } else if let diagnostic = item.diagnostic {
                DisclosureGroup("Technical Details") {
                    Text(diagnostic.technicalDescription).font(.caption.monospaced()).textSelection(.enabled)
                }.disclosureGroupStyle(TaskDisclosureStyle(minimumHeight: 22))
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var status: some View {
        Group {
            if compactMatch {
                Image(systemName: "checkmark").foregroundStyle(RestoreStatusTone.success.color)
                    .frame(width: TaskRowLayout.iconWidth).accessibilityLabel("Already Matches")
            } else { TaskStatusLabel(state: item.state, title: stateTitles[item.state]) }
        }
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
