import AppKit
import SwiftUI
import UniformTypeIdentifiers

private typealias ReferenceViewState<Value> = SwiftUI.State<Value>

struct EnvironmentStatusView: View {
    @ObservedObject var model: EnvironmentStatusModel
    @ObservedObject var runtime: CoreRuntime
    var showsActions = true
    private var busy: Bool { runtime.isActive || model.state == .running }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            switch model.state {
            case .choose:
                WorkspacePrimaryActionCard(title: "Choose Saved Environment", symbol: ProductTask.status.symbol, tint: WorkspaceIdentity.tint(.status),
                    message: "Select a Macseed Saved Environment (.mbt) to compare with this Mac.", notice: "Read-only comparison. Nothing will be installed, removed or changed.") {
                    if showsActions { EnvironmentStatusActions(model: model, runtime: runtime) }
                    referenceDetails
                }

            case .running:
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 16) {
                        ProgressView().controlSize(.large).frame(width: 40, height: 40).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Comparing Your Mac").font(.title2.weight(.bold))
                            Text(runtime.stopping ? "Stopping comparison…" : (runtime.currentPhase == "bundle_validation" ? "Validating the saved environment…" : "Comparing supported requirements…"))
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                    Label("Read-only comparison. Nothing will be installed, removed or changed.", systemImage: "checkmark.shield")
                        .font(.callout).foregroundStyle(.secondary)
                }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
                if showsActions { EnvironmentStatusActions(model: model, runtime: runtime) }
            case .result:
                referenceDetails
                if let result = model.presentation {
                    Text(result.headline).font(.title2.weight(.semibold))
                    EnvironmentComparisonView(result: result).id(model.operationID)
                }
                if showsActions { EnvironmentStatusActions(model: model, runtime: runtime) }
            case .failed, .cancelled:
                OperationSummaryHeader(title: model.state == .cancelled ? "Comparison Cancelled" : "Needs Attention",
                    message: model.failure?.message ?? "No complete comparison is available.",
                    state: model.state == .cancelled ? .skipped : .attention, counters: [], suppliedMetrics: [], scopeSummary: "Read-only comparison")
                if let reason = model.failure?.technicalReason {
                    DisclosureGroup("Technical Details") { Text(reason).font(.caption.monospaced()).textSelection(.enabled) }
                        .disclosureGroupStyle(TaskDisclosureStyle(minimumHeight: 22))
                }
                if showsActions { EnvironmentStatusActions(model: model, runtime: runtime) }
                referenceDetails
            }
        }.modifier(OperationLogPresenter(runtime: runtime))
    }

    @ViewBuilder private var referenceDetails: some View {
        if let bundle = model.reference?.bundle { Label(bundle.lastPathComponent, systemImage: "shippingbox").font(.headline) }
    }
}

struct EnvironmentStatusActions: View {
    @ObservedObject var model: EnvironmentStatusModel
    @ObservedObject var runtime: CoreRuntime
    var reviewInRestore: (() -> Void)? = nil
    var handoffBlocked = false
    private var busy: Bool { runtime.isActive || model.state == .running }
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { actions(horizontal: true) }
            VStack(alignment: .leading, spacing: 8) { actions(horizontal: false) }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    @ViewBuilder private func actions(horizontal: Bool) -> some View {
        if let reference = runtime.operationLogReference(matching: model.operationID),
           OperationLogVisibility.status(model.state, active: runtime.isActive, reference: reference, terminal: runtime.termination != nil && runtime.operationID == model.operationID) {
            OperationLogButton(runtime: runtime, reference: reference).fixedSize()
        }
        if model.state == .running {
            Button("Cancel") { model.cancel() }.disabled(runtime.stopping).fixedSize()
            if horizontal { Spacer() }
        } else {
            Button(model.reference == nil ? "Choose Saved Environment…" : "Choose a Different Environment…", action: chooseReference).disabled(busy).fixedSize()
            if model.state != .choose && horizontal { Spacer() }
            if model.restoreReviewBundle != nil, let reviewInRestore {
                Button("Review in Restore", action: reviewInRestore).buttonStyle(.bordered)
                    .disabled(busy || handoffBlocked).fixedSize()
            }
            if model.reference != nil {
                Button(model.state == .choose ? "Compare This Mac" : "Compare Again") { model.compare() }
                    .buttonStyle(.borderedProminent).disabled(busy).fixedSize()
            }
        }
    }
    private func chooseReference() {
        let panel = NSOpenPanel()
        panel.title = "Choose Saved Environment"
        panel.message = "Select a Macseed Saved Environment (.mbt) to compare with this Mac."
        panel.prompt = "Choose Saved Environment"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [UTType(filenameExtension: "mbt") ?? .data]
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        let selected: (NSApplication.ModalResponse) -> Void = { response in
            if response == .OK, let url = panel.url { model.selectBundle(url) }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: selected) }
        else { panel.begin(completionHandler: selected) }
    }
}

// Comparison retains its own truthful status vocabulary, using shared surfaces/disclosures.
struct EnvironmentComparisonView: View {
    let result: EnvironmentStatusPresentation
    var categoryExpansion: Binding<Set<String>>? = nil
    var settingsExpansion: Binding<Bool>? = nil
    var technicalExpansion: Binding<Bool>? = nil
    @ReferenceViewState<Set<String>> private var expandedCategories = []
    private var expandedIDs: Set<String> { categoryExpansion?.wrappedValue ?? expandedCategories }
    private var categoryIDs: Set<String> { Set(Self.visibleSections(result).flatMap(\.entries).map(\.id)) }
    private var categoryCounts: [String: [ComparisonOutcome: Int]] {
        Dictionary(uniqueKeysWithValues: result.categories.map { category in
            (category.id, Dictionary(uniqueKeysWithValues: ComparisonOutcome.allCases.map {
                ($0, result.categoryCount($0, category: category))
            }))
        })
    }
    // Extra evidence remains in the result and diagnostics; only its window projection is hidden.
    static func visibleCategory(_ category: DisplayCategory) -> DisplayCategory {
        DisplayCategory(id: category.id, title: category.title, symbol: category.symbol,
            items: category.items.filter { $0.status != .extra && !$0.id.hasPrefix("extra-availability:") })
    }
    static func visibleSections(_ result: EnvironmentStatusPresentation) -> [EnvironmentStatusSection] {
        result.sections.compactMap { section in
            let entries = section.entries.compactMap { entry -> EnvironmentStatusSection.Entry? in
                let category = visibleCategory(entry.category)
                guard !category.items.isEmpty else { return nil }
                return .init(category: category, children: entry.children.map(visibleCategory).filter { !$0.items.isEmpty })
            }
            return entries.isEmpty ? nil : .init(id: section.id, entries: entries)
        }
    }
    static func toggledCategories(_ expanded: Set<String>, ids: Set<String>) -> Set<String> {
        ids.isSubset(of: expanded) ? [] : ids
    }
    static func summaryOutcomes(_ result: EnvironmentStatusPresentation) -> [ComparisonSummaryOutcome] {
        ComparisonSummaryOutcome.allCases.filter { $0 == .needsAttention ? result.needsAttention : ($0.count(result) ?? 0) > 0 }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            EnvironmentComparisonMetricsLayout {
                ForEach(Self.summaryOutcomes(result)) { outcome in
                    ComparisonMetricCard(outcome: outcome, count: outcome.count(result), explanation: outcome.explanation(result))
                }
            }
            if result.needsAttention || result.counts["extra", default: 0] > 0 || result.counts["unverified", default: 0] > 0 || result.counts["unresolved", default: 0] > 0 {
                Text(result.message).font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Text("Details by Category").font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                if !categoryIDs.isEmpty {
                    Button(categoryIDs.isSubset(of: expandedIDs) ? "Collapse All" : "Expand All") {
                        let ids = Self.toggledCategories(expandedIDs, ids: categoryIDs)
                        if let categoryExpansion { categoryExpansion.wrappedValue = ids } else { expandedCategories = ids }
                    }.buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            ForEach(Self.visibleSections(result)) { section in
                WorkspaceSectionHeader(title: section.id)
                VStack(spacing: 0) {
                    ForEach(section.entries) { entry in
                        EnvironmentComparisonDomain(category: entry.category, children: entry.children, technicalFacts: result.technicalFacts, counts: Dictionary(uniqueKeysWithValues: ComparisonOutcome.allCases.map { ($0, result.categoryCount($0, category: entry.category, children: entry.children)) }), expansion: Binding(
                            get: { expandedIDs.contains(entry.id) },
                            set: { value in
                                var ids = expandedIDs
                                if value { ids.insert(entry.id) } else { ids.remove(entry.id) }
                                if let categoryExpansion { categoryExpansion.wrappedValue = ids } else { expandedCategories = ids }
                            }), childExpansion: settingsExpansion, categoryCounts: categoryCounts, technicalExpansion: technicalExpansion)
                        if entry.id != section.entries.last?.id { Divider() }
                    }
                }.modifier(WorkspaceCardSurface())
            }
            Text("Nothing will be removed or changed.").font(.callout).foregroundStyle(.secondary)
        }
    }
}

// Every depth receives the same row width. Only the title content carries indentation.
struct EnvironmentComparisonRowLayout: Layout {
    var depth = 0
    var itemIndent = false
    var spansStatusColumn = false

    static func widths(_ width: CGFloat) -> (text: CGFloat, status: CGFloat) {
        let available = max(0, width - 12)
        let status = min(available, min(240, max(160, available * 0.46)))
        return (available - status, status)
    }
    static func leadingInset(_ width: CGFloat, depth: Int, item: Bool) -> CGFloat {
        let step: CGFloat = widths(width).text < 180 ? 8 : 24
        return CGFloat(depth) * step + (item && depth > 0 ? 34 : 0)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let proposed = proposal.width ?? 520
        let width = proposed.isFinite ? max(0, proposed) : 520
        let rowWidth = spansStatusColumn ? max(0, width - 26) : width
        let columns = Self.widths(rowWidth)
        let inset = Self.leadingInset(rowWidth, depth: depth, item: itemIndent)
        let text = subviews[0].sizeThatFits(.init(width: max(0, (spansStatusColumn ? width : columns.text) - inset), height: nil))
        if spansStatusColumn { return CGSize(width: width, height: text.height) }
        let status = subviews[1].sizeThatFits(.init(width: columns.status, height: nil))
        return CGSize(width: width, height: max(text.height, status.height))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rowWidth = spansStatusColumn ? max(0, bounds.width - 26) : bounds.width
        let columns = Self.widths(rowWidth)
        let inset = Self.leadingInset(rowWidth, depth: depth, item: itemIndent)
        subviews[0].place(at: CGPoint(x: bounds.minX + inset, y: bounds.minY), anchor: .topLeading,
            proposal: .init(width: max(0, (spansStatusColumn ? bounds.width : columns.text) - inset), height: nil))
        if spansStatusColumn { return }
        subviews[1].place(at: CGPoint(x: bounds.maxX - columns.status, y: bounds.minY), anchor: .topLeading,
            proposal: .init(width: columns.status, height: nil))
    }
}

struct EnvironmentComparisonDomain: View {
    let category: DisplayCategory
    var children: [DisplayCategory] = []
    var technicalFacts: [String: [ComparisonTechnicalFact]] = [:]
    var counts: [ComparisonOutcome: Int]? = nil
    var expansion: Binding<Bool>? = nil
    var childExpansion: Binding<Bool>? = nil
    var categoryCounts: [String: [ComparisonOutcome: Int]] = [:]
    var technicalExpansion: Binding<Bool>? = nil
    var depth = 0
    @ReferenceViewState<Bool> private var expanded = false
    var body: some View {
        DisclosureGroup(isExpanded: expansion ?? $expanded) {
            VStack(alignment: .leading, spacing: 0) {
                if !children.isEmpty {
                    ForEach(children) { child in
                        EnvironmentComparisonDomain(category: child, technicalFacts: technicalFacts,
                            counts: categoryCounts[child.id], expansion: childExpansion, categoryCounts: categoryCounts,
                            technicalExpansion: technicalExpansion, depth: depth + 1)
                    }
                } else {
                    ForEach(EnvironmentComparisonView.visibleCategory(category).items) { item in
                        EnvironmentComparisonItem(item: item, facts: technicalFacts[item.id] ?? [],
                            depth: depth + 1, technicalExpansion: technicalExpansion)
                    }
                }
            }.padding(.vertical, 4)
        } label: {
            EnvironmentComparisonRowLayout(depth: depth) {
                title
                domainStatus
            }.padding(.vertical, 6)
        }.disclosureGroupStyle(TaskDisclosureStyle(contentTrailingInset: 0))
            .padding(.horizontal, depth == 0 ? 16 : 0)
    }
    private var title: some View {
        HStack(spacing: 12) {
            WorkspaceCategoryIcon(symbol: category.symbol)
            Text(category.title).font(.body.weight(.medium))
        }
    }
    static func visibleOutcomes(_ counts: [ComparisonOutcome: Int]) -> [ComparisonOutcome] {
        ComparisonOutcome.allCases.filter { counts[$0, default: 0] > 0 }
    }
    static func summaryStatus(_ category: DisplayCategory) -> DisplayStatus {
        return EnvironmentComparisonView.visibleCategory(category).comparisonStatus
    }
    private var status: DisplayStatus { Self.summaryStatus(category) }
    @ViewBuilder private var domainStatus: some View {
        if let counts {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    statusLabel.frame(width: 152, alignment: .leading)
                    badges(counts)
                }.fixedSize()
                VStack(alignment: .leading, spacing: 4) {
                    statusLabel
                    badges(counts)
                }
            }
        } else { statusLabel }
    }
    private func badges(_ counts: [ComparisonOutcome: Int]) -> some View {
        HStack(spacing: 4) {
            ForEach(Self.visibleOutcomes(counts)) { outcome in
                Text(String(counts[outcome, default: 0])).font(.caption2.weight(.semibold)).monospacedDigit()
                    .padding(.horizontal, 6).frame(minWidth: 24, minHeight: 23)
                    .foregroundStyle(outcome.tint).background(outcome.tint.opacity(0.12), in: Capsule())
                    .help(outcome.title).accessibilityLabel(outcome.title).accessibilityValue(String(counts[outcome, default: 0]))
            }
        }
    }
    private var statusLabel: some View {
        EnvironmentComparisonStatusLabel(status: status,
            title: EnvironmentComparisonView.visibleCategory(category).comparisonStatusText)
    }
}

struct EnvironmentComparisonItem: View {
    let item: DisplayItem
    var facts: [ComparisonTechnicalFact] = []
    var depth = 0
    var technicalExpansion: Binding<Bool>? = nil
    @ReferenceViewState<Bool> private var technicalExpanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            EnvironmentComparisonRowLayout(depth: depth, itemIndent: true) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                    if let explanation = item.comparisonExplanation {
                        Text(explanation).font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                if item.isNormalComparisonMatch {
                    Image(systemName: "checkmark").foregroundStyle(EnvironmentComparisonPalette.color(for: .matching))
                        .accessibilityLabel("Already Matches")
                } else { EnvironmentComparisonStatusLabel(status: item.status) }
            }.padding(.trailing, 26)
            if let reason = item.comparisonTechnicalDetails {
                EnvironmentComparisonRowLayout(depth: depth, itemIndent: true, spansStatusColumn: true) {
                    DisclosureGroup("Technical Details", isExpanded: technicalExpansion ?? $technicalExpanded) {
                        if facts.isEmpty {
                            Text(reason).font(.caption.monospaced()).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            VStack(alignment: .leading, spacing: 6) {
                                let phases = Set(facts.flatMap(\.phases))
                                if phases.count == 1, let phase = phases.first { Text("Phase: " + phase).foregroundStyle(.secondary) }
                                ForEach(facts) { fact in
                                    ViewThatFits(in: .horizontal) {
                                        HStack(alignment: .top, spacing: 12) {
                                            Text(fact.predicateTitle).frame(width: 70, alignment: .leading)
                                            Text(fact.resultTitle).frame(width: 80, alignment: .leading)
                                            factDetails(fact, showPhases: phases.count > 1)
                                        }
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(fact.predicateTitle + " · " + fact.resultTitle)
                                            factDetails(fact, showPhases: phases.count > 1)
                                        }
                                    }
                                }
                                DisclosureGroup("Full Diagnostic Details") {
                                    Text(reason).font(.caption.monospaced()).textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }.disclosureGroupStyle(TaskDisclosureStyle(minimumHeight: 22))
                            }.font(.caption).textSelection(.enabled)
                        }
                    }
                        .disclosureGroupStyle(TaskDisclosureStyle(minimumHeight: 22, contentTrailingInset: 0)).font(.caption)
                }
            }
        }.padding(.vertical, 7).frame(minHeight: 28)
    }
    private func factDetails(_ fact: ComparisonTechnicalFact, showPhases: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text((fact.codes + [fact.recordID]).joined(separator: " · ")).font(.caption.monospaced())
            if showPhases && !fact.phases.isEmpty { Text("Phase: " + fact.phases.joined(separator: " · ")).foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
    }
}

// Status owns one palette for summary, category, leaf and badge presentation.
enum EnvironmentComparisonPalette {
    static func color(for status: DisplayStatus) -> Color {
        switch status {
        case .matching, .verified: RestoreStatusTone.success.color
        case .missing, .different: .red
        case .unverified, .unresolved, .attention, .unsupported: .orange
        default: .secondary
        }
    }
}

private struct EnvironmentComparisonStatusLabel: View {
    let status: DisplayStatus
    var title: String? = nil
    var body: some View {
        Label(title ?? status.rawValue, systemImage: status.symbol).font(.callout)
            .foregroundStyle(EnvironmentComparisonPalette.color(for: status))
    }
}

enum ComparisonOutcome: String, CaseIterable, Identifiable {
    case match, different, missing, notApplicable, needsAttention
    var id: String { rawValue }
    var title: String {
        switch self { case .match: "Match"; case .different: "Different"; case .missing: "Missing"; case .notApplicable: "Not Applicable"; case .needsAttention: "Needs Attention" }
    }
    var status: DisplayStatus {
        switch self { case .match: .matching; case .different: .different; case .missing: .missing; case .notApplicable: .noRequirement; case .needsAttention: .attention }
    }
    var tint: Color {
        EnvironmentComparisonPalette.color(for: status)
    }
    var symbol: String {
        switch self { case .match: "checkmark.circle.fill"; case .different: "exclamationmark.triangle.fill"; case .missing: "xmark.circle.fill"; case .notApplicable: "minus.circle.fill"; case .needsAttention: "questionmark.circle.fill" }
    }
    var explanation: String {
        switch self { case .match: "Checks match"; case .different: "Checks differ"; case .missing: "Not found on this Mac"; case .notApplicable: "No requirement in selected scope"; case .needsAttention: "Unsupported or incomplete checks" }
    }
    func count(_ result: EnvironmentStatusPresentation) -> Int {
        switch self {
        case .match: result.counts["matching"] ?? 0
        case .different: result.counts["differing"] ?? 0
        case .missing: result.counts["missing"] ?? 0
        case .notApplicable: result.categories.flatMap(\.items).filter { $0.status == .noRequirement }.count
        case .needsAttention: result.attentionCount ?? 0
        }
    }
}

// Summary aggregation does not change the separate category/leaf outcomes above.
enum ComparisonSummaryOutcome: String, CaseIterable, Identifiable {
    case match, differences, notApplicable, needsAttention
    var id: String { rawValue }
    private var outcome: ComparisonOutcome {
        switch self {
        case .match: .match
        case .differences: .different
        case .notApplicable: .notApplicable
        case .needsAttention: .needsAttention
        }
    }
    var title: String { self == .differences ? "Differences Found" : outcome.title }
    var tint: Color { outcome.tint }
    var symbol: String { outcome.symbol }
    func count(_ result: EnvironmentStatusPresentation) -> Int? {
        switch self {
        case .differences: ComparisonOutcome.different.count(result) + ComparisonOutcome.missing.count(result)
        case .needsAttention: result.attentionCount
        default: outcome.count(result)
        }
    }
    func explanation(_ result: EnvironmentStatusPresentation) -> String {
        guard self == .differences else { return outcome.explanation }
        return [ComparisonOutcome.different, .missing].compactMap { kind in
            let count = kind.count(result)
            return count > 0 ? "\(count) \(kind.title)" : nil
        }.joined(separator: " · ")
    }
}

struct ComparisonMetricCard: View {
    let outcome: ComparisonSummaryOutcome
    let count: Int?
    let explanation: String
    var body: some View {
        WorkspaceMetricCard(title: outcome.title, value: count.map(String.init), symbol: outcome.symbol,
            tint: outcome.tint, explanation: explanation)
    }
}

// Status owns this layout: only applicable metrics, with no empty placeholder slots.
struct EnvironmentComparisonMetricsLayout: Layout {
    static func columns(_ width: CGFloat, count: Int) -> Int {
        guard width.isFinite else { return max(1, count) }
        return Int(max(1, min(CGFloat(count), (width + 10) / 190)))
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let proposed = proposal.width ?? 785
        let width = proposed.isFinite ? max(0, proposed) : CGFloat(subviews.count) * 190 - 10
        let columns = Self.columns(width, count: subviews.count)
        let itemWidth = max(0, (width - CGFloat(columns - 1) * 10) / CGFloat(columns))
        let height = subviews.map { $0.sizeThatFits(.init(width: itemWidth, height: nil)).height }.max() ?? 0
        let rows = (subviews.count + columns - 1) / columns
        return CGSize(width: width, height: CGFloat(rows) * height + CGFloat(rows - 1) * 10)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let columns = Self.columns(bounds.width, count: subviews.count)
        let width = (bounds.width - CGFloat(columns - 1) * 10) / CGFloat(columns)
        let height = subviews.map { $0.sizeThatFits(.init(width: width, height: nil)).height }.max() ?? 0
        for (index, view) in subviews.enumerated() {
            let rowStart = (index / columns) * columns
            let rowColumns = min(columns, subviews.count - rowStart)
            let rowWidth = (bounds.width - CGFloat(rowColumns - 1) * 10) / CGFloat(rowColumns)
            view.place(at: CGPoint(x: bounds.minX + CGFloat(index % columns) * (rowWidth + 10), y: bounds.minY + CGFloat(index / columns) * (height + 10)),
                anchor: .topLeading, proposal: .init(width: rowWidth, height: height))
        }
    }
}
