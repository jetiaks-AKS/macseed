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
        }
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
        HStack(spacing: 12) {
            if model.state == .running {
                Button("Cancel") { model.cancel() }.disabled(runtime.stopping)
                Spacer()
            } else {
                Button(model.reference == nil ? "Choose Saved Environment…" : "Choose a Different Environment…", action: chooseReference).disabled(busy)
                if model.state != .choose { Spacer() }
                if model.restoreReviewBundle != nil, let reviewInRestore {
                    Button("Review in Restore", action: reviewInRestore).buttonStyle(.bordered)
                        .disabled(busy || handoffBlocked)
                }
                if model.reference != nil {
                    Button(model.state == .choose ? "Compare This Mac" : "Compare Again") { model.compare() }
                        .buttonStyle(.borderedProminent).disabled(busy)
                }
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
    @ReferenceViewState<Set<String>> private var expandedCategories = []
    private var expandedIDs: Set<String> { categoryExpansion?.wrappedValue ?? expandedCategories }
    private var categoryIDs: Set<String> { Set(result.sections.flatMap(\.entries).map(\.id)) }
    static func toggledCategories(_ expanded: Set<String>, ids: Set<String>) -> Set<String> {
        ids.isSubset(of: expanded) ? [] : ids
    }
    static func summaryOutcomes(_ result: EnvironmentStatusPresentation) -> [ComparisonOutcome] {
        ComparisonOutcome.allCases.filter { $0 != .notApplicable || $0.count(result) > 0 }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if Self.summaryOutcomes(result).count == 3 {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        ForEach(Self.summaryOutcomes(result)) { outcome in
                            ComparisonMetricCard(outcome: outcome, count: outcome.count(result)).frame(minWidth: 220)
                        }
                    }
                    VStack(spacing: 10) {
                        ForEach(Self.summaryOutcomes(result)) { outcome in
                            ComparisonMetricCard(outcome: outcome, count: outcome.count(result))
                        }
                    }
                }
            } else {
            WorkspaceMetricLayout {
                ForEach(ComparisonOutcome.allCases) { outcome in
                    ComparisonMetricCard(outcome: outcome, count: outcome.count(result))
                }
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
            ForEach(result.sections) { section in
                WorkspaceSectionHeader(title: section.id)
                VStack(spacing: 0) {
                    ForEach(section.entries) { entry in
                        EnvironmentComparisonDomain(category: entry.category, children: entry.children, technicalFacts: result.technicalFacts, counts: Dictionary(uniqueKeysWithValues: ComparisonOutcome.allCases.map { ($0, result.categoryCount($0, category: entry.category, children: entry.children)) }), expansion: Binding(
                            get: { expandedIDs.contains(entry.id) },
                            set: { value in
                                var ids = expandedIDs
                                if value { ids.insert(entry.id) } else { ids.remove(entry.id) }
                                if let categoryExpansion { categoryExpansion.wrappedValue = ids } else { expandedCategories = ids }
                            }), childExpansion: settingsExpansion)
                        if entry.id != section.entries.last?.id { Divider() }
                    }
                }.modifier(WorkspaceCardSurface())
            }
            Text("Nothing will be removed or changed.").font(.callout).foregroundStyle(.secondary)
        }
    }
}

struct EnvironmentComparisonDomain: View {
    let category: DisplayCategory
    var children: [DisplayCategory] = []
    var technicalFacts: [String: [ComparisonTechnicalFact]] = [:]
    var counts: [ComparisonOutcome: Int]? = nil
    var expansion: Binding<Bool>? = nil
    var childExpansion: Binding<Bool>? = nil
    @ReferenceViewState<Bool> private var expanded = false
    var body: some View {
        DisclosureGroup(isExpanded: expansion ?? $expanded) {
            VStack(alignment: .leading, spacing: 0) {
                if !children.isEmpty {
                    ForEach(children) { child in
                        EnvironmentComparisonDomain(category: child, expansion: childExpansion)
                    }
                } else {
                    ForEach(category.items) { item in EnvironmentComparisonItem(item: item, facts: technicalFacts[item.id] ?? []) }
                }
            }.padding(.leading, 36).padding(.vertical, 4)
        } label: {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { title; Spacer(); domainStatus }
                VStack(alignment: .leading, spacing: 8) { title; domainStatus }
            }.padding(.vertical, 6)
        }.disclosureGroupStyle(TaskDisclosureStyle()).padding(.horizontal, 16)
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
        return category.comparisonStatus
    }
    private var status: DisplayStatus { counts == nil ? category.comparisonStatus : Self.summaryStatus(category) }
    @ViewBuilder private var domainStatus: some View {
        if let counts {
            HStack(spacing: 6) {
                if ![.different, .missing].contains(status) { statusLabel }
                ForEach(Self.visibleOutcomes(counts)) { outcome in
                    Text(String(counts[outcome, default: 0])).font(.caption2.weight(.semibold)).monospacedDigit()
                        .padding(.horizontal, 8).frame(minWidth: 46, minHeight: 23)
                        .foregroundStyle(outcome.tint).background(outcome.tint.opacity(0.12), in: Capsule())
                        .accessibilityLabel(outcome.title).accessibilityValue(String(counts[outcome, default: 0]))
                }
            }.fixedSize()
        } else { statusLabel }
    }
    private var statusLabel: some View {
        Label {
            Text(counts == nil ? category.comparisonStatusText : status.rawValue)
        } icon: {
            Image(systemName: status.symbol)
        }.font(.callout).foregroundStyle(status == .matching ? RestoreStatusTone.success.color :
            (status == .missing ? Color.red : ([.noRequirement, .information, .extra].contains(status) ? Color.secondary : Color.orange)))
    }
}

struct EnvironmentComparisonItem: View {
    let item: DisplayItem
    var facts: [ComparisonTechnicalFact] = []
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                if let explanation = item.comparisonExplanation {
                    Text(explanation).font(.caption).foregroundStyle(.secondary)
                }
                if let reason = item.comparisonTechnicalDetails {
                    DisclosureGroup("Technical Details") {
                        if facts.isEmpty { Text(reason).font(.caption.monospaced()).textSelection(.enabled) }
                        else {
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
                                }.disclosureGroupStyle(TaskDisclosureStyle(minimumHeight: 22))
                            }.font(.caption).textSelection(.enabled)
                        }
                    }
                        .disclosureGroupStyle(TaskDisclosureStyle(minimumHeight: 22)).font(.caption)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if item.isNormalComparisonMatch {
                Image(systemName: "checkmark").foregroundStyle(RestoreStatusTone.success.color)
                    .accessibilityLabel("Already Matches")
            } else { EnvironmentComparisonStatusLabel(status: item.status) }
        }.padding(.vertical, 7).frame(minHeight: 28)
    }
    private func factDetails(_ fact: ComparisonTechnicalFact, showPhases: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text((fact.codes + [fact.recordID]).joined(separator: " · ")).font(.caption.monospaced())
            if showPhases && !fact.phases.isEmpty { Text("Phase: " + fact.phases.joined(separator: " · ")).foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct EnvironmentComparisonStatusLabel: View {
    let status: DisplayStatus
    private var color: Color {
        switch status {
        case .matching, .verified: RestoreStatusTone.success.color
        case .missing: .red
        case .different, .unverified, .unresolved, .attention, .unsupported: .orange
        default: .secondary
        }
    }
    var body: some View {
        Label(status.rawValue, systemImage: status.symbol).font(.callout).foregroundStyle(color)
    }
}

enum ComparisonOutcome: String, CaseIterable, Identifiable {
    case match, different, missing, notApplicable
    var id: String { rawValue }
    var title: String {
        switch self { case .match: "Match"; case .different: "Different"; case .missing: "Missing"; case .notApplicable: "Not Applicable" }
    }
    var status: DisplayStatus {
        switch self { case .match: .matching; case .different: .different; case .missing: .missing; case .notApplicable: .noRequirement }
    }
    var tint: Color {
        switch self { case .match: RestoreStatusTone.success.color; case .different: .orange; case .missing: .red; case .notApplicable: .secondary }
    }
    var symbol: String {
        switch self { case .match: "checkmark.circle.fill"; case .different: "exclamationmark.triangle.fill"; case .missing: "xmark.circle.fill"; case .notApplicable: "minus.circle.fill" }
    }
    var explanation: String {
        switch self { case .match: "Items match"; case .different: "Items differ"; case .missing: "Not found on this Mac"; case .notApplicable: "No requirement in selected scope" }
    }
    func count(_ result: EnvironmentStatusPresentation) -> Int {
        switch self {
        case .match: result.counts["matching"] ?? 0
        case .different: result.counts["differing"] ?? 0
        case .missing: result.counts["missing"] ?? 0
        case .notApplicable: result.categories.flatMap(\.items).filter { $0.status == .noRequirement }.count
        }
    }
}

struct ComparisonMetricCard: View {
    let outcome: ComparisonOutcome
    let count: Int
    var body: some View {
        WorkspaceMetricCard(title: outcome.title, value: String(count), symbol: outcome.symbol,
            tint: outcome.tint, explanation: outcome.explanation)
    }
}
