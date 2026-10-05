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
    var body: some View {
        HStack(spacing: 7) {
            if state == .working { ProgressView().controlSize(.small).frame(width: TaskRowLayout.iconWidth).accessibilityHidden(true) }
            else { Image(systemName: state.symbol).frame(width: TaskRowLayout.iconWidth).accessibilityHidden(true) }
            Text(state.rawValue)
        }.font(.callout.weight(.medium)).foregroundStyle(state.tone.color)
            .accessibilityElement(children: .ignore).accessibilityLabel(state.rawValue)
    }
}

struct OperationSummaryHeader: View {
    let title: String
    let message: String
    let state: TaskRowState
    let counters: [(state: TaskRowState, count: Int)]
    var startedAt: Date? = nil
    var finishedAt: Date? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 28) { heading.frame(minWidth: 300); horizontalMetrics }
                VStack(alignment: .leading, spacing: 20) { heading; metrics }
            }
            Text("\(counters.reduce(0) { $0 + $1.count }) selected domains")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }
    private var heading: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: state.symbol).font(.system(size: 30, weight: .medium)).foregroundStyle(state.tone.color).accessibilityHidden(true)
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
    private var horizontalMetrics: some View {
        HStack(spacing: 10) {
            ForEach(counters, id: \.state) { counter in
                metric(counter.state, count: counter.count).frame(width: 112)
            }
        }.fixedSize(horizontal: true, vertical: false)
    }
    private var metrics: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), alignment: .leading)], alignment: .leading, spacing: 10) {
            ForEach(counters, id: \.state) { counter in metric(counter.state, count: counter.count) }
        }
    }
    private func metric(_ state: TaskRowState, count: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: state.symbol).foregroundStyle(state.tone.color).accessibilityHidden(true)
                Text(String(count)).font(.title2.weight(.bold)).monospacedDigit()
            }
            Text(state.rawValue).font(.caption.weight(.medium)).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, minHeight: 52, alignment: .leading).padding(10)
            .background(.background.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(state.rawValue).accessibilityValue(String(count))
    }
    static func elapsed(_ start: Date, _ end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        return "\(seconds / 60)m \(seconds % 60)s"
    }
}

struct TaskDomainList: View {
    let domains: [TaskDomainPresentation]
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
                        TaskDomainItems(domain: domain)
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
    private func domainTitle(_ domain: TaskDomainPresentation) -> some View {
        HStack(spacing: 12) {
            Image(systemName: domain.symbol).frame(width: TaskRowLayout.iconWidth).accessibilityHidden(true)
            Text(domain.title).font(.body.weight(.medium))
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func domainStatus(_ domain: TaskDomainPresentation) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            TaskStatusLabel(state: domain.state)
            Text(domain.summary).font(.caption).foregroundStyle(.secondary)
        }.frame(width: TaskRowLayout.statusWidth, alignment: .leading)
    }
}

struct TaskDomainItems: View {
    let domain: TaskDomainPresentation
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
                                    TaskStatusLabel(state: item.state).frame(width: TaskRowLayout.statusWidth, alignment: .leading)
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
