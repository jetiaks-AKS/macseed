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

// A native Button owns the whole disclosure header, including its empty space.
struct TaskDisclosureStyle: DisclosureGroupStyle {
    var minimumHeight: CGFloat = 48
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { configuration.isExpanded.toggle() } label: {
                HStack(spacing: 14) {
                    configuration.label.frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .frame(width: 12).accessibilityHidden(true)
                }.frame(maxWidth: .infinity, minHeight: minimumHeight, alignment: .leading)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
            if configuration.isExpanded { configuration.content.padding(.trailing, 26) }
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
        }.font(.callout.weight(.medium)).foregroundStyle(state == .planned ? Color.primary : state.tone.color)
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
    @TaskViewState<Set<String>> private var expanded = []
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Tasks").font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                Button(expanded.count == domains.count ? "Collapse All" : "Expand All") {
                    expanded = expanded.count == domains.count ? [] : Set(domains.map(\.id))
                }.buttonStyle(.plain).foregroundStyle(.secondary)
            }.padding(.bottom, 12)
            VStack(spacing: 0) {
                ForEach(domains) { domain in
                    DisclosureGroup(isExpanded: Binding(get: { expanded.contains(domain.id) }, set: { value in
                        if value { expanded.insert(domain.id) } else { expanded.remove(domain.id) }
                    })) {
                        TaskDomainItems(domain: domain, stateTitles: stateTitles)
                    } label: {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 12) { domainTitle(domain); Spacer(); domainStatus(domain) }
                            VStack(alignment: .leading, spacing: 8) { domainTitle(domain); domainStatus(domain) }
                        }.padding(.vertical, 6)
                    }.disclosureGroupStyle(TaskDisclosureStyle()).padding(.horizontal, 16)
                    if domain.id != domains.last?.id { Divider() }
                }
            }.background(.background, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
        }
    }
    private func domainSummary(_ domain: TaskDomainPresentation) -> String {
        guard !stateTitles.isEmpty else { return domain.summary }
        let counts = Dictionary(grouping: domain.items, by: \.state)
        return TaskRowState.allCases.compactMap { state in
            counts[state].map { "\($0.count) \((stateTitles[state] ?? state.rawValue).lowercased())" }
        }.joined(separator: " · ")
    }
    private func domainTitle(_ domain: TaskDomainPresentation) -> some View {
        HStack(spacing: 12) {
            Image(systemName: domain.symbol).frame(width: TaskRowLayout.iconWidth).accessibilityHidden(true)
            Text(domain.title).font(.body.weight(.medium))
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func domainStatus(_ domain: TaskDomainPresentation) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            TaskStatusLabel(state: domain.state, title: stateTitles[domain.state])
            Text(domainSummary(domain)).font(.caption).foregroundStyle(.secondary)
        }.frame(width: TaskRowLayout.statusWidth, alignment: .leading)
    }
}

struct TaskDomainItems: View {
    let domain: TaskDomainPresentation
    var stateTitles: [TaskRowState: String] = [:]
    var body: some View {
VStack(spacing: 0) {
                            ForEach(domain.items) { item in
                                HStack(alignment: .top, spacing: 12) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(item.item.title)
                                        Text(item.item.action).font(.caption).foregroundStyle(.secondary)
                                        if item.state != .working, let reason = item.item.reason {
                                            DisclosureGroup("Technical Details") {
                                                Text(reason).font(.caption.monospaced()).textSelection(.enabled)
                                            }.disclosureGroupStyle(TaskDisclosureStyle(minimumHeight: 22)).font(.caption)
                                        }
                                    }
                                    Spacer()
                                    TaskStatusLabel(state: item.state, title: stateTitles[item.state]).frame(width: TaskRowLayout.statusWidth, alignment: .leading)
                                }.padding(.vertical, 7)
                            }
                        }.padding(.leading, 36).padding(.vertical, 4)
    }
}

struct PendingOperationLogButton: View {
    var body: some View {
        Button {} label: { Label("View Log", systemImage: "doc.text") }
            .disabled(true).help("Persistent Desktop operation logs are not available in this build.")
            .accessibilityHint("Persistent Desktop operation logs are not available in this build.")
    }
}
