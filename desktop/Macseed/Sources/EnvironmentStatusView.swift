import AppKit
import SwiftUI

private typealias ReferenceViewState<Value> = SwiftUI.State<Value>

struct EnvironmentStatusView: View {
    @ObservedObject var model: EnvironmentStatusModel
    @ObservedObject var runtime: CoreRuntime
    @ReferenceViewState<Bool> private var referenceDetailsExpanded = false
    private var busy: Bool { runtime.isActive || model.state == .running }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            switch model.state {
            case .choose:
                WorkspacePrimaryActionCard(title: "Compare This Mac", symbol: ProductTask.restore.symbol, tint: WorkspaceIdentity.tint(.status),
                    message: "Choose a saved environment to compare with this Mac.", notice: "Nothing will be removed or changed.") {
                    Button("Choose Saved Environment…", action: chooseReference).disabled(busy)
                    referenceDetails
                    Button("Compare") { model.compare() }.buttonStyle(.borderedProminent).disabled(model.reference == nil || busy)
                }

            case .running:
                OperationSummaryHeader(title: "Comparing This Mac", message: runtime.stopping ? "Stopping comparison…" : "Comparing saved environment…",
                    state: .working, counters: [], suppliedMetrics: [], scopeSummary: "Read-only comparison")
                Button("Cancel") { model.cancel() }.disabled(runtime.stopping)
            case .result:
                WorkspaceResultHeader(title: ProductTask.status.rawValue, subtitle: ProductTask.status.subtitle, symbol: ProductTask.status.symbol) {
                    comparisonActions
                }
                if let result = model.presentation { EnvironmentComparisonView(result: result).id(model.operationID) }
                referenceDetails
            case .failed, .cancelled:
                OperationSummaryHeader(title: model.state == .cancelled ? "Comparison Cancelled" : "Needs Attention",
                    message: model.failure?.message ?? "No complete comparison is available.",
                    state: model.state == .cancelled ? .skipped : .attention, counters: [], suppliedMetrics: [], scopeSummary: "Read-only comparison")
                if let reason = model.failure?.technicalReason {
                    DisclosureGroup("Technical Details") { Text(reason).font(.caption.monospaced()).textSelection(.enabled) }
                        .disclosureGroupStyle(TaskDisclosureStyle(minimumHeight: 22))
                }
                comparisonActions
                referenceDetails
            }
        }.onChange(of: model.reference) { _, _ in referenceDetailsExpanded = false }
    }

    private var comparisonActions: some View {
        HStack {
            Button("Choose a Different Environment…", action: chooseReference).disabled(busy)
            Divider().frame(height: 20)
            Button("Compare Again") { model.compare() }.buttonStyle(.borderedProminent).disabled(model.reference == nil || busy)
        }
    }

    @ViewBuilder private var referenceDetails: some View {
        if let reference = model.reference {
            VStack(alignment: .leading, spacing: 6) {
                Label(reference.generatedDirectory.lastPathComponent, systemImage: "folder").font(.headline)
                Text(reference.generatedDirectory.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                DisclosureGroup("Reference Details", isExpanded: $referenceDetailsExpanded) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Generated Configuration · " + (reference.blueprint == nil ? "No Blueprint" : "Selected Blueprint"))
                            .font(.callout).foregroundStyle(.secondary)
                        if let blueprint = reference.blueprint { Text(blueprint.path).font(.caption).textSelection(.enabled) }
                        HStack {
                            Button("Choose Blueprint…", action: chooseBlueprint)
                            if reference.blueprint != nil { Button("No Blueprint") { model.selectBlueprint(nil) } }
                        }.disabled(busy)
                    }
                }.disclosureGroupStyle(TaskDisclosureStyle(minimumHeight: 22))
            }
        }
    }

    private func chooseReference() {
        let panel = NSOpenPanel()
        panel.title = "Choose Saved Environment"
        panel.message = "Choose the folder containing your saved environment."
        panel.prompt = "Choose Saved Environment"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        present(panel) { model.selectReference($0) }
    }
    private func chooseBlueprint() {
        let panel = NSOpenPanel()
        panel.title = "Choose Blueprint"
        panel.message = "Choose an optional Blueprint to limit the comparison scope."
        panel.prompt = "Choose Blueprint"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        present(panel) { model.selectBlueprint($0) }
    }
    private func present(_ panel: NSOpenPanel, selected: @escaping (URL) -> Void) {
        // A native chooser is the only modal boundary; all result/error states stay inline.
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window) { response in
                if response == .OK, let url = panel.url { selected(url) }
            }
        } else {
            panel.begin { response in if response == .OK, let url = panel.url { selected(url) } }
        }
    }
}

// Comparison retains its own truthful status vocabulary, using shared surfaces/disclosures.
struct EnvironmentComparisonView: View {
    let result: EnvironmentStatusPresentation
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            WorkspaceMetricLayout {
                ForEach(ComparisonOutcome.allCases) { outcome in
                    ComparisonMetricCard(outcome: outcome, count: outcome.count(result))
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(result.message).font(.callout).foregroundStyle(.secondary)
                if !result.summary.isEmpty { Text(result.summary).font(.caption).foregroundStyle(.secondary) }
            }
            Text("Details by Domain").font(.headline).accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                ForEach(result.categories) { category in
                    EnvironmentComparisonDomain(category: category)
                    if category.id != result.categories.last?.id { Divider() }
                }
            }.modifier(WorkspaceCardSurface())
            Text("Nothing will be removed or changed.").font(.callout).foregroundStyle(.secondary)
        }
    }
}

struct EnvironmentComparisonDomain: View {
    let category: DisplayCategory
    @ReferenceViewState<Bool> private var expanded = false
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(category.items) { item in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title)
                            Text(item.action).font(.caption).foregroundStyle(.secondary)
                            if let reason = item.reason {
                                DisclosureGroup("Technical Details") { Text(reason).font(.caption.monospaced()).textSelection(.enabled) }
                                    .disclosureGroupStyle(TaskDisclosureStyle(minimumHeight: 22)).font(.caption)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        EnvironmentComparisonStatusLabel(status: item.status).frame(width: TaskRowLayout.statusWidth, alignment: .leading)
                    }.padding(.vertical, 7)
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
            Image(systemName: category.symbol).foregroundStyle(.blue).frame(width: TaskRowLayout.iconWidth).accessibilityHidden(true)
            Text(category.title).font(.body.weight(.medium))
        }
    }
    private var domainStatus: some View {
        HStack(spacing: 8) {
            ForEach(ComparisonOutcome.allCases) { outcome in
                Text(String(category.items.filter { $0.status == outcome.status }.count))
                    .font(.caption.weight(.medium)).monospacedDigit().foregroundStyle(outcome.tint)
                    .frame(width: 38, height: 20).background(outcome.tint.opacity(0.10), in: Capsule())
                    .accessibilityLabel(outcome.title).accessibilityValue(String(category.items.filter { $0.status == outcome.status }.count))
            }
            let other = category.items.filter { !ComparisonOutcome.allCases.map(\.status).contains($0.status) }
            if !other.isEmpty {
                let attention = other.contains { [.unverified, .unresolved, .unsupported, .attention].contains($0.status) }
                Image(systemName: attention ? "exclamationmark.triangle" : "info.circle")
                    .foregroundStyle(attention ? Color.orange : Color.secondary).frame(width: 18)
                    .accessibilityLabel(other.map { $0.status.rawValue }.joined(separator: ", "))
            } else { Color.clear.frame(width: 18, height: 1).accessibilityHidden(true) }
        }
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
        HStack(spacing: 12) {
            WorkspaceCircleIcon(symbol: outcome.symbol, tint: outcome.tint, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(String(count)).font(.title2.weight(.semibold)).monospacedDigit()
                Text(outcome.title).font(.callout.weight(.semibold))
                Text(outcome.explanation).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(outcome.tint.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .ignore).accessibilityLabel(outcome.title).accessibilityValue(String(count))
    }
}
