import SwiftUI

private typealias CapturePresentationState<Value> = SwiftUI.State<Value>

// Read-only presentation of existing selection, preparation and publication facts.
struct CaptureTaskPresentation {
    enum Phase { case confirmation, progress, result }
    let domains: [TaskDomainPresentation]
    init(categories: [CaptureCategory], selection: CoreCaptureSelection, phase: Phase,
         capturedDomains: Set<String>? = nil, notices: [DisplayCategory] = []) {
        let selected = capturedDomains ?? Set(selection.categories).union(selection.items.keys)
        var output: [TaskDomainPresentation] = []
        for category in categories where selected.contains(category.id) {
            let isMacOS = CaptureMacOSSettingsGroup.domainIDs.contains(category.id)
            let domainID = isMacOS ? "macos-settings" : category.id
            let chosen = Set(selection.items[category.id] ?? category.row.items.map(\.itemID))
            let facts = category.display.items.filter { !category.itemSelectable || chosen.contains($0.id) }
            let state: TaskRowState = phase == .progress ? .waiting : phase == .result ? .completed : .planned
            var items = facts.map { item in
                TaskItemPresentation(id: category.id + ":" + item.id,
                    item: DisplayItem(id: category.id + ":" + item.id, title: item.title, status: item.status,
                        action: phase == .progress ? "Waiting for the saved environment to be created."
                            : phase == .result ? "Included in the published saved environment." : item.action,
                        reason: nil), state: state)
            }
            let warnings = phase == .result ? notices.filter { $0.id == category.id }.flatMap(\.items)
                : phase == .confirmation ? category.notices : []
            items += warnings.map { item in TaskItemPresentation(id: category.id + ":" + item.id + ":notice", item: item, state: .attention) }
            if let index = output.firstIndex(where: { $0.id == domainID }) {
                let old = output[index]
                output[index] = TaskDomainPresentation(id: old.id, title: old.title, symbol: old.symbol, items: old.items + items)
            } else {
                output.append(TaskDomainPresentation(id: domainID, title: isMacOS ? "macOS Settings" : category.title,
                    symbol: isMacOS ? "slider.horizontal.3" : category.symbol, items: items))
            }
        }
        domains = output
    }
}

struct CaptureSummaryPresentation {
    let domainCount: Int
    let itemCount: Int
    let attentionCount: Int
    let unsupportedCount: Int
    var captured = false
    var metrics: [OperationMetric] {
        var values = [OperationMetric(title: captured ? "Captured Domains" : "Selected Domains", count: domainCount, symbol: "square.stack", tone: .neutral),
                      OperationMetric(title: captured ? "Captured Items" : "Selected Items", count: itemCount, symbol: "checklist", tone: .neutral)]
        if attentionCount > 0 { values.append(OperationMetric(title: "Needs Attention", count: attentionCount, symbol: "exclamationmark.triangle.fill", tone: .warning)) }
        if unsupportedCount > 0 { values.append(OperationMetric(title: "Not Supported", count: unsupportedCount, symbol: "minus.circle.fill", tone: .warning)) }
        return values
    }
    var scope: String { "\(domainCount) domains · \(itemCount) items " + (captured ? "captured" : "selected") }
    static func review(categories: [CaptureCategory], domainCount: Int, itemCount: Int) -> Self {
        Self(domainCount: domainCount, itemCount: itemCount,
             attentionCount: categories.filter { $0.row.status == "observation_error" || !$0.notices.isEmpty }.count,
             unsupportedCount: categories.filter { $0.row.status == "unsupported" || !["category", "items"].contains($0.row.selectionMode) }.count)
    }
}

struct CaptureCategorySelectionView: View {
    @ObservedObject var model: CaptureModel
    let category: CaptureCategory
    @CapturePresentationState<Bool> private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                // Checkbox and disclosure are independent native controls.
                NativeSelectionCheckbox("", state: model.selectionState(category), accessibilityTitle: "Select " + category.title) {
                    model.selectCategory(category.id, included: $0)
                }.frame(width: 28, height: 28).disabled(!category.selectable)
                DisclosureGroup(isExpanded: $expanded) { EmptyView() } label: {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) { title; Spacer(); status }
                        VStack(alignment: .leading, spacing: 6) { title; status }
                    }
                }.disclosureGroupStyle(TaskDisclosureStyle())
            }
            if expanded {
                if category.itemSelectable {
                    ForEach(category.display.items) { item in
                        NativeSelectionCheckbox(item.title, isOn: Binding(
                            get: { model.selectedItems[category.id]?.contains(item.id) == true },
                            set: { model.selectItem(category.id, item: item.id, included: $0) }))
                            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                    }
                } else {
                    CaptureNoticeDetails(items: category.display.items)
                    if let settings = category.row.includedSettings, !settings.isEmpty { IncludedSettingsText(settings: settings) }
                }
                CaptureNoticeDetails(items: category.notices)
            }
        }.padding(.horizontal, 16).padding(.vertical, 4)
    }
    private var title: some View {
        HStack(spacing: 12) {
            Image(systemName: category.symbol).frame(width: TaskRowLayout.iconWidth).accessibilityHidden(true)
            Text(category.title).font(.body.weight(.medium))
        }
    }
    private var status: some View {
        VStack(alignment: .leading, spacing: 3) {
            if !category.selectable {
                TaskStatusLabel(state: .attention, title: category.headerSummary)
            } else if !category.notices.isEmpty { TaskStatusLabel(state: .attention) }
            else { Text(model.selectionState(category) == .none ? "Not selected" : "Selected").font(.callout.weight(.medium)).foregroundStyle(.primary) }
            if category.selectable {
                Text(category.itemSelectable ? "\(model.selectedItems[category.id]?.count ?? 0) of \(category.row.items.count) selected" : category.headerSummary)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.frame(width: TaskRowLayout.statusWidth, alignment: .leading)
    }
}

struct CaptureNoticeDetails: View {
    let items: [DisplayItem]
    var body: some View {
        ForEach(items) { item in
            VStack(alignment: .leading, spacing: 4) {
                Text(item.action).font(.caption).foregroundStyle(.secondary)
                if let reason = item.reason {
                    DisclosureGroup("Technical Details") { Text(reason).font(.caption.monospaced()).textSelection(.enabled) }
                        .disclosureGroupStyle(TaskDisclosureStyle(minimumHeight: 22)).font(.caption)
                }
            }.padding(.leading, 40).padding(.vertical, 4)
        }
    }
}

struct CaptureSecureTransferView: View {
    @CapturePresentationState<Bool> private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Capabilities").font(.headline)
            DisclosureGroup(isExpanded: $expanded) {
                Text("Private SSH identity transfer is not available in this build. No private SSH identities will be captured. Ordinary SSH Configuration is separate and remains selectable.")
                    .font(.callout).foregroundStyle(.secondary)
            } label: {
                HStack {
                    Label("Secure Transfer", systemImage: "lock.shield")
                    Spacer()
                    TaskStatusLabel(state: .attention, title: "Not Supported").frame(width: TaskRowLayout.statusWidth, alignment: .leading)
                }
            }.disclosureGroupStyle(TaskDisclosureStyle())
        }.padding(.horizontal, 16)
    }
}
