import SwiftUI

private typealias CapturePresentationState<Value> = SwiftUI.State<Value>

enum CaptureItemRole { case wholeCategory, categoryWarning, selectedSubdomain, configuration }

// Read-only presentation of existing selection, preparation and publication facts.
struct CaptureTaskPresentation {
    enum Phase { case confirmation, progress, result }
    let domains: [TaskDomainPresentation]
    init(categories: [CaptureCategory], selection: CoreCaptureSelection, phase: Phase,
         capturedDomains: Set<String>? = nil, publication: CoreCapturePublication? = nil, notices: [DisplayCategory] = []) {
        let selected = phase == .result ? publication?.bundle.capturedDomains ?? capturedDomains ?? [] : Set(selection.categories).union(selection.items.keys)
        var output: [TaskDomainPresentation] = []
        let ordered = phase != .progress ? CaptureReviewRow.project(categories).flatMap(\.categories) : categories
        for category in ordered where selected.contains(category.id) {
            let isMacOS = CaptureMacOSSettingsGroup.domainIDs.contains(category.id)
            let domainID = isMacOS ? "macos-settings" : category.id
            let chosen = Set(selection.items[category.id] ?? category.row.items.map(\.itemID))
            let resultBound = publication?.publicationOccurred == true && publication?.bundle.capturedDomains.contains(category.id) == true
            let exactItems = resultBound && publication?.bundle.selectedItemCounts[category.id] == chosen.count
            let realCategoryItems = phase != .progress && category.row.selectionMode == "category" && !category.row.items.isEmpty
            let facts = realCategoryItems ? category.row.items.map {
                DisplayItem(id: $0.itemID, title: $0.label.hasPrefix("opaque:") ? "Private item" : $0.label,
                            status: .ready, action: "Supported state available to save.")
            } : category.display.items.filter { !category.itemSelectable || chosen.contains($0.id) }
            let resultKnown = resultBound && (category.row.selectionMode == "category" || exactItems)
            let state: TaskRowState = phase == .progress ? .waiting : phase == .result ? (resultKnown ? .completed : .unverified) : .planned
            let wholeCategory = phase != .progress && category.row.selectionMode == "category" && !realCategoryItems
            let role: CaptureItemRole? = wholeCategory ? (isMacOS ? .selectedSubdomain : category.id == "vscode-settings" ? .configuration : .wholeCategory) : nil
            var items = facts.map { item in
                TaskItemPresentation(id: category.id + ":" + item.id,
                    item: DisplayItem(id: category.id + ":" + item.id, title: role == .configuration ? "JSON configuration" : item.title, status: item.status,
                        action: role == .configuration ? (phase == .result ? "Supported VS Code settings were saved. Included file: settings.json." : "Supported VS Code settings will be included in this saved environment. Included file: settings.json.")
                            : role == .wholeCategory ? (phase == .result ? "The whole supported configuration was saved." : "The whole supported configuration will be included in this saved environment.")
                            : phase == .progress ? "Waiting for the saved environment to be created."
                            : phase == .result ? "Included in the published saved environment." : item.action,
                        reason: nil), state: state,
                    captureRole: role)
            }
            if phase == .result && !resultKnown {
                items = [TaskItemPresentation(id: category.id + ":content-evidence", item: DisplayItem(id: category.id + ":content-evidence",
                    title: category.title, status: .information, action: "The category was saved, but its exact item contents were not reported."),
                    state: .unverified, captureRole: .wholeCategory)]
            }
            let warnings = phase == .result ? notices.filter { $0.id == category.id }.flatMap(\.items)
                : phase == .confirmation ? category.notices : []
            items += warnings.map { item in TaskItemPresentation(id: category.id + ":" + item.id + ":notice", item: item, state: .attention,
                captureRole: phase != .progress ? .categoryWarning : nil) }
            if let index = output.firstIndex(where: { $0.id == domainID }) {
                let old = output[index]
                output[index] = TaskDomainPresentation(id: old.id, title: old.title, symbol: old.symbol, items: old.items + items, activityState: phase == .result ? (!warnings.isEmpty || old.state == .attention ? .attention : old.state == .unverified ? .unverified : state) : nil)
            } else {
                output.append(TaskDomainPresentation(id: domainID, title: isMacOS ? "macOS Settings" : category.title,
                    symbol: isMacOS ? "slider.horizontal.3" : category.symbol, items: items, activityState: phase == .result ? (!warnings.isEmpty ? .attention : state) : nil))
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
    var expansion: Binding<Bool>? = nil
    @CapturePresentationState<Bool> private var expanded = false
    static func hasDisclosure(_ category: CaptureCategory) -> Bool {
        !(category.id == "vscode-settings" && category.selectable && !category.itemSelectable
            && category.row.reason == nil && (category.row.includedSettings?.isEmpty ?? true))
    }
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { title; Spacer(); status }
            VStack(alignment: .leading, spacing: 8) { title; status }
        }.padding(.vertical, 6)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                // Checkbox and disclosure are independent native controls.
                NativeSelectionCheckbox("", state: model.selectionState(category), accessibilityTitle: "Select " + category.title) {
                    model.selectCategory(category.id, included: $0)
                }.frame(width: 28, height: 28).disabled(!category.selectable)
                if Self.hasDisclosure(category) {
                    DisclosureGroup(isExpanded: expansion ?? $expanded) { EmptyView() } label: { header }
                        .disclosureGroupStyle(TaskDisclosureStyle())
                } else { header.padding(.trailing, 26).frame(minHeight: 48) }
            }
            if Self.hasDisclosure(category) && (expansion?.wrappedValue ?? expanded) {
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
                CaptureNoticeDetails(items: category.notices, suppressedDiagnosticIDs: CaptureReviewDiagnostics.repeatedNoticeIDs(category))
            }
        }.padding(.horizontal, 16)
    }
    private var title: some View {
        WorkspaceCategoryTitle(id: category.id, title: category.title, fallbackSymbol: category.symbol)
    }
    private var status: some View {
        VStack(alignment: .leading, spacing: 3) {
            if !category.selectable {
                TaskStatusLabel(state: category.row.status == "observation_error" ? .attention : .skipped, title: category.headerSummary)
            } else if !category.notices.isEmpty { TaskStatusLabel(state: .attention) }
            else { Text(model.selectionState(category).captureTitle).font(.callout.weight(.medium)).foregroundStyle(.primary) }
            if category.selectable {
                Text(category.itemSelectable ? "\(model.selectedItems[category.id]?.count ?? 0) of \(category.row.items.count) selected" : category.headerSummary)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.frame(width: TaskRowLayout.statusWidth, alignment: .leading)
    }
}

// The category placeholder and warning are two projections of one row.reason.
// Only that known presentation duplicate is suppressed; records/items remain intact.
enum CaptureReviewDiagnostics {
    static func repeatedNoticeIDs(_ category: CaptureCategory) -> Set<String> {
        guard !category.itemSelectable, let reason = category.row.reason,
              category.display.items.contains(where: { $0.id == "category-state:" + category.id && $0.reason == reason }) else { return [] }
        return Set(category.notices.filter { $0.id == "category-warning:" + category.id && $0.reason == reason }.map(\.id))
    }
}

struct CaptureNoticeDetails: View {
    let items: [DisplayItem]
    var suppressedDiagnosticIDs: Set<String> = []
    var body: some View {
        ForEach(items) { item in
            VStack(alignment: .leading, spacing: 4) {
                Text(item.action).font(.caption).foregroundStyle(.secondary)
                if let reason = item.reason, !suppressedDiagnosticIDs.contains(item.id) {
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
            DisclosureGroup(isExpanded: $expanded) {
                Text("Private SSH identity transfer is not available in this build. No private SSH identities will be captured. Ordinary SSH Configuration is separate and remains selectable.")
                    .font(.callout).foregroundStyle(.secondary)
            } label: {
                HStack {
                    Label("Secure Transfer", systemImage: "lock.shield")
                    Spacer()
                    Text("Unavailable").font(.callout.weight(.medium)).foregroundStyle(.secondary).frame(width: TaskRowLayout.statusWidth, alignment: .leading)
                }
            }.disclosureGroupStyle(TaskDisclosureStyle())
        }.padding(.horizontal, 16)
    }
}

extension SelectionState {
    var captureTitle: String {
        switch self {
        case .all: "Selected"
        case .mixed: "Partially Selected"
        case .none: "Not Selected"
        }
    }
}

// Review ordering only; the macOS row retains its six independent Core domains.
struct CaptureReviewRow: Identifiable {
    let id: String
    let categories: [CaptureCategory]
    var needsAttention: Bool {
        categories.contains { $0.row.status == "observation_error" || !$0.notices.isEmpty }
    }
    static func project(_ categories: [CaptureCategory]) -> [Self] {
        let order = ["homebrew-casks", "app-store", "homebrew-packages", "vscode-extensions", "macos-settings",
                     "vscode-settings", "shell-zsh", "git-configuration", "ssh-configuration", "workspace-folders", "git-repositories"]
        let known = Set(order + CaptureMacOSSettingsGroup.domainIDs)
        var rows = order.compactMap { id -> Self? in
            let members = categories.filter { id == "macos-settings" ? CaptureMacOSSettingsGroup.domainIDs.contains($0.id) : $0.id == id }
            return members.isEmpty ? nil : Self(id: id, categories: members)
        }
        rows += categories.filter { !known.contains($0.id) }.map { Self(id: $0.id, categories: [$0]) }
        return rows
    }
    static func attentionMessage(_ rows: [Self]) -> String? {
        let count = rows.filter(\.needsAttention).count
        guard count > 0 else { return nil }
        return count == 1 ? "1 category needs attention" : "\(count) categories need attention"
    }
}

// Capture retains its metric meanings and attention tones on the shared Status geometry.
struct CaptureMetricCard: View {
    let title: String
    let count: Int
    let symbol: String
    var attention = false
    enum Tone { case blue, amber, neutral }
    static func tone(attention: Bool, count: Int) -> Tone {
        attention ? (count > 0 ? .amber : .neutral) : .blue
    }
    var body: some View {
        let tone = Self.tone(attention: attention, count: count)
        WorkspaceMetricCard(title: title, value: String(count), symbol: symbol,
            tint: tone == .blue ? .blue : tone == .amber ? .orange : .secondary)
    }
}

struct CaptureReviewMetrics: View {
    let summary: CaptureSummaryPresentation
    var body: some View {
        WorkspaceThreeMetrics { cards }
    }
    @ViewBuilder private var cards: some View {
        CaptureMetricCard(title: "Selected Domains", count: summary.domainCount, symbol: "square.stack")
        CaptureMetricCard(title: "Selected Items", count: summary.itemCount, symbol: "checklist")
        CaptureMetricCard(title: "Needs Attention", count: summary.attentionCount, symbol: "exclamationmark.triangle", attention: true)
    }
}

// Presentation partition only; neither selection nor prepared evidence is modified.
struct CaptureConfirmationContents {
    let ordinary: [TaskItemPresentation]
    let itemProblems: [TaskItemPresentation]
    let categoryProblems: [TaskItemPresentation]
    let explanations: [TaskItemPresentation]
    var problems: [TaskItemPresentation] { itemProblems + categoryProblems }
    init(_ items: [TaskItemPresentation]) {
        func needsAttention(_ item: TaskItemPresentation) -> Bool {
            ![.planned, .completed].contains(item.state) || item.item.requiresAttention || item.item.reason != nil || item.diagnostic != nil
        }
        ordinary = items.filter { $0.captureRole != .wholeCategory && !needsAttention($0) }
        explanations = items.filter { ($0.captureRole == .wholeCategory || $0.captureRole == .configuration) && !needsAttention($0) }
        var seen = Set<String>()
        let candidates = items.filter(needsAttention)
        // Prefer the item representation only when both carry the same structured fact identity.
        let ordered = candidates.filter { $0.captureRole != .categoryWarning }
            + candidates.filter { $0.captureRole == .categoryWarning }
        let unique = ordered.filter { item in
            guard !item.item.id.isEmpty else { return true }
            let identity = [item.item.id, item.item.title, item.item.action, item.item.reason ?? "",
                            item.item.status.rawValue, item.state.rawValue,
                            item.diagnostic?.technicalDescription ?? ""].joined(separator: "\u{0}")
            return seen.insert(identity).inserted
        }
        itemProblems = unique.filter { $0.captureRole != .categoryWarning }
        categoryProblems = unique.filter { $0.captureRole == .categoryWarning }
    }
}

struct CaptureCompactLabel: View {
    let title: String
    var body: some View {
        Text(title).font(.callout).fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 5))
    }
}

struct CaptureIncludedSettingsList: View {
    let labels: [String]
    var body: some View {
        SettingsFlowLayout {
            ForEach(Array(labels.enumerated()), id: \.offset) { _, label in CaptureCompactLabel(title: label) }
        }.padding(.leading, 36).padding(.vertical, 8)
    }
}

struct CaptureConfirmationItems: View {
    let domain: TaskDomainPresentation
    var body: some View {
        let contents = CaptureConfirmationContents(domain.items)
        VStack(alignment: .leading, spacing: 10) {
            SettingsFlowLayout {
                ForEach(contents.ordinary) { item in
                    CaptureCompactLabel(title: item.item.title)
                }
            }
            ForEach(contents.explanations) { item in
                Text(item.item.action).font(.callout).foregroundStyle(.secondary)
            }
            if !contents.problems.isEmpty {
                ForEach(contents.problems) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        if item.captureRole != .categoryWarning && item.captureRole != .wholeCategory {
                            Text(item.item.title).font(.callout.weight(.medium))
                        }
                        if !item.item.action.isEmpty {
                            Text(item.item.action).font(.callout).foregroundStyle(.secondary)
                        }
                        if item.item.reason != nil || item.diagnostic != nil {
                            DisclosureGroup("Technical Details") {
                                if let reason = item.item.reason { Text(reason).font(.caption.monospaced()).textSelection(.enabled) }
                                if let diagnostic = item.diagnostic { Text(diagnostic.technicalDescription).font(.caption.monospaced()).textSelection(.enabled) }
                            }.disclosureGroupStyle(TaskDisclosureStyle(minimumHeight: 22)).font(.caption)
                        }
                    }.padding(.vertical, 3)
                }
            }
        }.padding(.leading, 36).padding(.vertical, 8)
    }
}

struct CaptureSavedMetrics: View {
    let publication: CoreCapturePublication
    let notices: [DisplayCategory]
    var body: some View {
        let attention = Set(notices.filter { !$0.items.isEmpty && publication.bundle.capturedDomains.contains($0.id) }.map(\.id)).count
        WorkspaceThreeMetrics { cards(attention) }
    }
    @ViewBuilder private func cards(_ attention: Int) -> some View {
        CaptureMetricCard(title: "Domains Saved", count: publication.bundle.capturedDomains.count, symbol: "square.stack")
        CaptureMetricCard(title: "Items Saved", count: publication.bundle.itemCount, symbol: "checklist")
        CaptureMetricCard(title: "Needs Attention", count: attention, symbol: "exclamationmark.triangle", attention: true)
    }
}

// Wording only; the failure, stale-plan guards and publication evidence remain Model-owned.
extension CaptureFailure {
    var isOutdatedPreparation: Bool {
        self == .runtime(.coreFailure("stale_prepared_capture"))
    }
    var presentationTitle: String {
        isOutdatedPreparation ? "Capture Preparation Is Outdated" : "Needs Attention"
    }
    var presentationMessage: String {
        isOutdatedPreparation
            ? "The selected environment has changed since confirmation. Scan this Mac again to prepare an updated capture."
            : message
    }
}

struct CaptureSettingsSubcategoryView: View {
    @ObservedObject var model: CaptureModel
    let category: CaptureCategory
    var editable = true
    var expansion: Binding<Bool>? = nil
    @CapturePresentationState<Bool> private var expanded = false
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if editable {
                NativeSelectionCheckbox("", state: model.selectionState(category), accessibilityTitle: "Select " + category.title) {
                    model.selectCategory(category.id, included: $0)
                }.frame(width: 28, height: 48).disabled(!category.selectable)
            }
            DisclosureGroup(isExpanded: expansion ?? $expanded) {
                VStack(alignment: .leading, spacing: 0) {
                    if !category.selectable {
                        CaptureNoticeDetails(items: category.display.items)
                    } else if let settings = category.row.includedSettings {
                        ForEach(settings, id: \.id) { setting in Text(setting.label).padding(.vertical, 7) }
                    }
                    CaptureNoticeDetails(items: category.notices)
                }.padding(.leading, 36).padding(.vertical, 4)
            } label: {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { title; Spacer(); status }
                    VStack(alignment: .leading, spacing: 8) { title; status }
                }.padding(.vertical, 6)
            }.disclosureGroupStyle(TaskDisclosureStyle())
        }
    }
    private var title: some View { WorkspaceCategoryTitle(id: category.id, title: category.title, fallbackSymbol: category.symbol) }
    private var status: some View {
        Group {
            if !category.selectable {
                TaskStatusLabel(state: category.row.status == "observation_error" ? .attention : .skipped, title: category.headerSummary)
            } else if !category.notices.isEmpty { TaskStatusLabel(state: .attention) }
            else { Text(model.selectionState(category).captureTitle).font(.callout) }
        }
    }
}

// Presentation partition uses existing domain-prefixed Capture item IDs unchanged.
enum CaptureSettingsPresentation {
    static func children(_ domains: [TaskDomainPresentation]) -> [TaskDomainPresentation] {
        let items = domains.first { $0.id == "macos-settings" }?.items ?? []
        return CaptureMacOSSettingsGroup.domainIDs.compactMap { id in
            let members = items.filter { $0.id.hasPrefix(id + ":") }
            return members.isEmpty ? nil : TaskDomainPresentation(id: id, title: CaptureCategory.title(for: id),
                symbol: WorkspaceCategoryStyle.symbol(id), items: members)
        }
    }
    static func labels(_ inventory: [CoreCaptureInventoryRow]) -> [String: [String]] {
        Dictionary(uniqueKeysWithValues: inventory.filter { CaptureMacOSSettingsGroup.domainIDs.contains($0.domain) }
            .map { ($0.domain, ($0.includedSettings ?? []).map(\.label)) })
    }
}
