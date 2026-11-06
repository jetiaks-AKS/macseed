import SwiftUI

private typealias CapturePresentationState<Value> = SwiftUI.State<Value>

enum CaptureItemRole { case wholeCategory, categoryWarning, selectedSubdomain, configuration }

// Capture's macOS row is already aggregated; it is a display alias, not a Core ID.
enum CaptureHierarchy {
    typealias Group = WorkspacePresentationTaxonomy.Group
    static let initialExpansion: Set<String> = []
    static let ordinaryGroups: [Group] = [.applicationsTools, .macOSSettings, .vscode]
    static let secureTransferID = "presentation.capture.secure-transfer"
    static func symbol(_ group: Group) -> String {
        switch group {
        case .applicationsTools: "square.stack.3d.up"
        case .macOSSettings: "slider.horizontal.3"
        case .vscode: "puzzlepiece.extension"
        case .advanced: "wrench.and.screwdriver"
        case .otherFindings: "questionmark.folder"
        }
    }
    static func group(for id: String) -> Group {
        ["macos-settings", "macOS Settings"].contains(id) ? .macOSSettings : WorkspacePresentationTaxonomy.group(for: id)
    }
    static func sectionID(_ group: Group) -> String {
        group == .vscode ? group.section.id : group == .macOSSettings ? "macos-settings" : group.id
    }
    static func sectionTitle(_ group: Group) -> String {
        group == .advanced ? "Advanced" : group.section.title
    }
    static func project<Row: Identifiable>(_ rows: [Row]) -> [WorkspacePresentationTaxonomy.Projection<Row>] where Row.ID == String {
        Group.allCases.compactMap { group in
            let members = rows.filter { Self.group(for: $0.id) == group }
            return members.isEmpty ? nil : .init(group: group, rows: members)
        }
    }
    static func title(_ id: String, fallback: String) -> String {
        ["vscode-extensions": "Extensions", "vscode-settings": "Settings", "git-repositories": "Git Repositories / Worktrees",
         "shell-zsh": "Shell / Zsh", "vscode-workspaces": "VS Code Workspace"][id] ?? fallback
    }
    static func selectionDescription(_ id: String) -> String? {
        switch id {
        case "workspace-folders": "Saves folder structure only. Files aren't included."
        case "git-repositories": "Saves repository and worktree setup. Local changes aren't transferred."
        case "ssh-configuration": "Saves supported SSH host profiles. SSH keys use Secure Transfer."
        case "vscode-workspaces": "Saves supported workspace references, not project files."
        default: nil
        }
    }
    static func disclosureIDs(_ ids: [String], scope: CaptureSelectionScope) -> Set<String> {
        var result = Set(ids.filter { scope.contains($0) || (scope == .ordinary && ["macos-settings", "macOS Settings"].contains($0)) })
        let groups = Set(result.map { Self.group(for: $0) })
        for group in Group.allCases where groups.contains(group) {
            result.insert(sectionID(group))
            if group == .vscode { result.insert(group.id) }
        }
        // Experienced disclosure includes the secure sibling without adding it
        // to Advanced's ordinary selection taxonomy or counters.
        if scope == .advanced && ids.contains(secureTransferID) { result.insert(secureTransferID) }
        return result
    }
    static func childDisclosureIDs(_ ids: [String], group: Group) -> Set<String> {
        var result = Set(ids.filter { Self.group(for: $0) == group })
        if group == .vscode && !result.isEmpty { result.insert(group.id) }
        return result
    }
    static func toggled(_ expanded: Set<String>, ids: Set<String>) -> Set<String> {
        expanded.subtracting(ids).union(WorkflowExpansion.toggled(expanded.intersection(ids), available: ids))
    }
}

// Presentation over the existing model maps, never a dependency graph or selection store.
@MainActor enum CaptureReviewPresentation {
    static let hierarchyStep: CGFloat = 12
    static func experiencedSelectionSummary(_ model: CaptureModel) -> String? {
        let categories = model.categories.filter { CaptureHierarchy.group(for: $0.id) == .advanced && model.selectionState($0) != .none }.count
        let identities = model.selectedSecureIdentities.count
        var parts: [String] = []
        if categories > 0 { parts.append("\(categories) advanced \(categories == 1 ? "category" : "categories") selected") }
        if identities > 0 { parts.append("\(identities) SSH \(identities == 1 ? "identity" : "identities") selected") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
    static func bulkCategories(_ categories: [CaptureCategory], group: CaptureHierarchy.Group) -> [CaptureCategory] {
        // Explicit bulk selection covers the same domains as the group summary;
        // the existing model filters eligibility without inferring dependencies.
        categories.filter { CaptureHierarchy.group(for: $0.id) == group }
    }
    static func selectionLabel(_ category: CaptureCategory, model: CaptureModel) -> String {
        guard model.selectionState(category) != .none else { return "Not Selected" }
        if category.itemSelectable {
            return "\(model.selectedItems[category.id]?.count ?? 0) of \(category.row.items.count) selected"
        }
        return "Selected"
    }
    static func attention(_ categories: [CaptureCategory], model: CaptureModel) -> String? {
        if categories.contains(where: { $0.row.status == "observation_error" }) { return "Scan Incomplete" }
        if categories.contains(where: { model.selectionState($0) != .none && !$0.notices.isEmpty }) { return "Selected Requirements Need Attention" }
        return nil
    }
    static func summary(_ categories: [CaptureCategory], model: CaptureModel) -> String {
        guard categories.contains(where: \.selectable) else { return "Unavailable" }
        switch model.bulkState(for: categories) {
        case .all: return "All Selected"
        case .mixed: return "Partially Selected"
        case .none: return "Not Selected"
        }
    }
}

struct CaptureExpandButton: View {
    let ids: Set<String>
    let title: String
    @Binding var expanded: Set<String>
    var body: some View {
        if !ids.isEmpty {
            Button(WorkflowExpansion.allExpanded(expanded, available: ids) ? "Collapse All" : "Expand All") {
                expanded = CaptureHierarchy.toggled(expanded, ids: ids)
            }.buttonStyle(.plain).foregroundStyle(.secondary)
                .accessibilityLabel((WorkflowExpansion.allExpanded(expanded, available: ids) ? "Collapse All " : "Expand All ") + title)
        }
    }
}

// Only leading content is indented. All Capture headers reserve the same trailing
// status column and the existing native disclosure indicator, at every depth.
struct CaptureRowColumns<Title: View, Status: View>: View {
    let title: Title
    let status: Status
    var body: some View {
        HStack(spacing: TaskRowLayout.columnSpacing) {
            title.frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            status.frame(width: TaskRowLayout.statusWidth, alignment: .leading)
        }.padding(.vertical, 6)
    }
}

// Reserve the status icon slot even for neutral selection text, so labels and
// their secondary counts align with Not Supported and Needs Attention rows.
struct CaptureStatusText: View {
    let title: String
    var state: TaskRowState? = nil
    var secondary = false
    static let textInset = TaskRowLayout.iconWidth + 7
    var body: some View {
        if let state { TaskStatusLabel(state: state, title: title) }
        else {
            HStack(spacing: 7) {
                Color.clear.frame(width: TaskRowLayout.iconWidth, height: 1).accessibilityHidden(true)
                Text(title).font(.callout).foregroundStyle(secondary ? .secondary : .primary)
            }
        }
    }
}

struct CaptureGroupStatus: View {
    let summary: String
    var attention: String? = nil
    var body: some View {
        CaptureStatusText(title: summary, secondary: true)
            .overlay(alignment: .leading) {
                if attention != nil {
                    Image(systemName: "exclamationmark.triangle").frame(width: TaskRowLayout.iconWidth)
                        .foregroundStyle(.orange).accessibilityHidden(true)
                }
            }
            .help(attention ?? summary).accessibilityElement(children: .ignore)
            .accessibilityLabel(summary + (attention.map { ". " + $0 } ?? ""))
    }
}

// Native button semantics and disclosure value, with a leading indicator for
// presentation containers only. Domain rows retain their trailing indicators.
struct CaptureAccordionStyle: DisclosureGroupStyle {
    var selection: AnyView? = nil
    var selectionLeadingInset: CGFloat = 0
    func makeBody(configuration: Configuration) -> some View {
        if let selection {
            HStack(spacing: 12) {
                Button { configuration.isExpanded.toggle() } label: {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .frame(width: 12, height: 48).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityHidden(true)
                selection.frame(width: 28, height: 28).padding(.leading, selectionLeadingInset)
                Button { configuration.isExpanded.toggle() } label: {
                    configuration.label.frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
            }.frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        } else {
            Button { configuration.isExpanded.toggle() } label: {
                HStack(spacing: 12) {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .frame(width: 12).accessibilityHidden(true)
                    configuration.label.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
        }
        if configuration.isExpanded { configuration.content }
    }
}

struct CaptureGroupHeader: View {
    let title: String
    let summary: String
    var symbol = "square.stack.3d.up"
    var tint: Color = .blue
    var titleTint: Color = .primary
    var attention: String? = nil
    var nested = false
    var selection: AnyView? = nil
    var expanded: Binding<Bool>?
    private var label: some View {
        CaptureRowColumns(title: HStack(spacing: selection == nil ? 8 : 12) {
            Image(systemName: symbol).foregroundStyle(tint)
                .frame(width: selection == nil ? 20 : TaskRowLayout.iconWidth).accessibilityHidden(true)
            Text(title).font(nested ? .body.weight(.medium) : .headline).foregroundStyle(titleTint)
        }, status: CaptureGroupStatus(summary: summary, attention: attention))
            .padding(.trailing, 26)
    }
    var body: some View {
        Group {
            if let expanded {
                DisclosureGroup(isExpanded: expanded) { EmptyView() } label: { label }
                    .disclosureGroupStyle(CaptureAccordionStyle(selection: selection,
                        selectionLeadingInset: nested ? CaptureReviewPresentation.hierarchyStep : 0))
                    .accessibilityIdentifier("capture.disclosure." + title)
            } else {
                HStack(spacing: 12) {
                    Color.clear.frame(width: 12).accessibilityHidden(true)
                    if let selection { selection.frame(width: 28, height: 28) }
                    label
                }.frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            }
        }.padding(.leading, 16).padding(.trailing, 16)
    }
}

// Layout only: ordinary sections and independent expert groups, original rows exactly once. The same
// projection serves editable Review and authoritative read-only saved scope.
struct CaptureGroupedContent<Row: Identifiable, RowContent: View>: View where Row.ID == String {
    @Environment(\.colorScheme) private var colorScheme
    let rows: [Row]
    @Binding var expanded: Set<String>
    var selection: ((CaptureHierarchy.Group, [Row]) -> AnyView?)? = nil
    var vscodeSelection: AnyView? = nil
    var ordinaryTitle: String? = nil
    var ordinaryControls: AnyView? = nil
    var advancedControls: AnyView? = nil
    var experiencedVisibility: Binding<Bool>? = nil
    var hiddenSelectionSummary: String? = nil
    var secureTransferGroup: AnyView? = nil
    let summary: ([Row]) -> String
    let attention: ([Row]) -> String?
    @ViewBuilder let rowContent: (Row) -> RowContent
    private var sections: [WorkspacePresentationTaxonomy.Projection<Row>] { CaptureHierarchy.project(rows) }
    private var advancedTint: Color {
        colorScheme == .dark ? Color(red: 0.95, green: 0.52, blue: 0.34) : Color(red: 0.72, green: 0.26, blue: 0.13)
    }
    var body: some View {
        let ordinary = sections.filter { CaptureHierarchy.ordinaryGroups.contains($0.group) }
        VStack(alignment: .leading, spacing: 12) {
            if !ordinary.isEmpty {
                if let ordinaryTitle {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        WorkspaceSectionHeader(title: ordinaryTitle)
                        if let ordinaryControls { ordinaryControls.padding(.trailing, 42) }
                    }
                }
                VStack(spacing: 0) {
                    ForEach(ordinary, id: \.group.id) { section in
                        accordion(section.group, rows: section.rows)
                        if section.group != ordinary.last?.group { Divider().padding(.horizontal, 16) }
                    }
                }.modifier(WorkspaceCardSurface()).accessibilityIdentifier("capture.container.ordinary")
            }
            let advanced = sections.first { $0.group == .advanced }?.rows ?? []
            if !advanced.isEmpty || secureTransferGroup != nil {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        let heading = WorkspaceSectionHeader(title: "For Experienced Users")
                        if let experiencedVisibility {
                            DisclosureGroup(isExpanded: experiencedVisibility) { EmptyView() } label: { heading }
                                .disclosureGroupStyle(HeaderDisclosureStyle())
                                .accessibilityIdentifier("capture.experienced.disclosure")
                                .help("Show Advanced and Secure Transfer. Collapsing keeps your selections.")
                        } else {
                            heading
                        }
                        if experiencedVisibility?.wrappedValue == false, let hiddenSelectionSummary {
                            Text(hiddenSelectionSummary).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("capture.experienced.hiddenSelection")
                        }
                    }
                    if experiencedVisibility?.wrappedValue != false, let advancedControls { advancedControls.padding(.trailing, 42) }
                }
                if experiencedVisibility?.wrappedValue != false {
                    VStack(alignment: .leading, spacing: 0) {
                        if experiencedVisibility != nil {
                            Text("Git, SSH, shell, and developer workspaces.")
                                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 16).padding(.vertical, 8)
                        }
                        if !advanced.isEmpty { accordion(.advanced, rows: advanced) }
                        if !advanced.isEmpty && secureTransferGroup != nil { Divider().padding(.horizontal, 16) }
                        if let secureTransferGroup { secureTransferGroup }
                    }
                    .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
                    .modifier(WorkspaceCardSurface()).accessibilityIdentifier("capture.container.experienced")
                }
            }
            if let unknown = sections.first(where: { $0.group == .otherFindings }) {
                WorkspaceSectionHeader(title: unknown.group.title)
                members(unknown.rows)
            }
        }
    }
    private func accordion(_ group: CaptureHierarchy.Group, rows: [Row]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            CaptureGroupHeader(title: CaptureHierarchy.sectionTitle(group), summary: summary(rows),
                symbol: CaptureHierarchy.symbol(group), tint: group == .advanced ? advancedTint : .blue,
                titleTint: group == .advanced ? advancedTint : .primary,
                attention: attention(rows), selection: selection?(group, rows),
                expanded: WorkflowExpansion.binding(CaptureHierarchy.sectionID(group), in: $expanded))
            if expanded.contains(CaptureHierarchy.sectionID(group)) {
                if group == .vscode {
                    CaptureGroupHeader(title: "VS Code", summary: summary(rows), symbol: "curlybraces", attention: attention(rows), nested: true,
                        selection: vscodeSelection,
                        expanded: WorkflowExpansion.binding(group.id, in: $expanded))
                    if expanded.contains(group.id) { members(rows) }
                } else {
                    members(rows)
                }
            }
        }
    }
    private func members(_ rows: [Row]) -> some View {
        VStack(spacing: 0) {
            ForEach(rows) { row in
                rowContent(row)
                if row.id != rows.last?.id { Divider().padding(.horizontal, 16) }
            }
        }
    }
}

// Read-only presentation of existing selection, preparation and publication facts.
struct CaptureTaskPresentation {
    enum Phase { case confirmation, progress, result }
    let domains: [TaskDomainPresentation]
    init(categories: [CaptureCategory], selection: CoreCaptureSelection, phase: Phase,
         capturedDomains: Set<String>? = nil, publication: CoreCapturePublication? = nil, notices: [DisplayCategory] = [],
         secureIdentities: [CoreCaptureSecureInventory.Identity] = []) {
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
        if phase == .confirmation, !selection.secureIdentities.isEmpty {
            let items = secureIdentities.filter { selection.secureIdentities.contains($0.itemID) }.map { identity in
                TaskItemPresentation(id: identity.itemID, item: DisplayItem(id: identity.itemID, title: identity.label,
                    status: .ready, action: "The SSH key pair will be validated and encrypted during saving."), state: .planned)
            }
            output.append(TaskDomainPresentation(id: CaptureHierarchy.secureTransferID, title: "Secure Transfer",
                symbol: "lock.shield", items: items))
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
    var secureIdentityCount = 0
    var metrics: [OperationMetric] {
        var values = [OperationMetric(title: captured ? "Captured Domains" : "Selected Domains", count: domainCount, symbol: "square.stack", tone: .neutral),
                      OperationMetric(title: captured ? "Captured Items" : "Selected Items", count: itemCount, symbol: "checklist", tone: .neutral)]
        if attentionCount > 0 { values.append(OperationMetric(title: "Needs Attention", count: attentionCount, symbol: "exclamationmark.triangle.fill", tone: .warning)) }
        if unsupportedCount > 0 { values.append(OperationMetric(title: "Not Supported", count: unsupportedCount, symbol: "minus.circle.fill", tone: .warning)) }
        return values
    }
    var scope: String { "\(domainCount) domains · \(itemCount) items " + (captured ? "captured" : "selected") }
    static func review(categories: [CaptureCategory], domainCount: Int, itemCount: Int, selectedDomains: Set<String>? = nil,
                       secureIdentityCount: Int = 0) -> Self {
        Self(domainCount: domainCount, itemCount: itemCount,
             attentionCount: categories.filter { $0.row.status == "observation_error" || (!$0.notices.isEmpty && (selectedDomains?.contains($0.id) ?? true)) }.count,
             unsupportedCount: categories.filter { $0.row.status == "unsupported" || !["category", "items"].contains($0.row.selectionMode) }.count,
             secureIdentityCount: secureIdentityCount)
    }
}

struct CaptureCategorySelectionView: View {
    @ObservedObject var model: CaptureModel
    let category: CaptureCategory
    var expansion: Binding<Bool>? = nil
    var displayTitle: String? = nil
    var leadingInset: CGFloat = 0
    var hierarchyIndent: CGFloat = CaptureReviewPresentation.hierarchyStep
    @CapturePresentationState<Bool> private var expanded = false
    static func hasDisclosure(_ category: CaptureCategory) -> Bool {
        !(category.id == "vscode-settings" && category.selectable && !category.itemSelectable
            && category.row.reason == nil && (category.row.includedSettings?.isEmpty ?? true))
    }
    private var header: some View {
        CaptureRowColumns(title: title, status: status)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                // Checkbox and disclosure are independent native controls.
                if category.selectable {
                    NativeSelectionCheckbox("", state: model.selectionState(category), accessibilityTitle: "Select " + (displayTitle ?? category.title)) {
                        model.selectCategory(category.id, included: $0)
                    }.frame(width: 28, height: 28).padding(.leading, hierarchyIndent)
                } else { Color.clear.frame(width: 28, height: 28).padding(.leading, hierarchyIndent).accessibilityHidden(true) }
                if Self.hasDisclosure(category) {
                    DisclosureGroup(isExpanded: expansion ?? $expanded) { EmptyView() } label: { header }
                        .disclosureGroupStyle(TaskDisclosureStyle())
                } else { header.padding(.trailing, 26).frame(minHeight: 48) }
            }
            if Self.hasDisclosure(category) && (expansion?.wrappedValue ?? expanded) {
                if let description = CaptureHierarchy.selectionDescription(category.id) {
                    Text(description).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, hierarchyIndent + 40).padding(.vertical, 4)
                }
                if category.itemSelectable {
                    ForEach(category.display.items) { item in
                        CaptureItemSelectionRow(title: item.title, included: Binding(
                            get: { model.selectedItems[category.id]?.contains(item.id) == true },
                            set: { model.selectItem(category.id, item: item.id, included: $0) }))
                            .padding(.leading, hierarchyIndent + CaptureReviewPresentation.hierarchyStep)
                    }
                } else {
                    CaptureNoticeDetails(items: category.display.items).padding(.leading, hierarchyIndent)
                    if let settings = category.row.includedSettings, !settings.isEmpty {
                        IncludedSettingsText(settings: settings).padding(.leading, hierarchyIndent + CaptureReviewPresentation.hierarchyStep)
                    }
                }
                CaptureNoticeDetails(items: category.notices, suppressedDiagnosticIDs: CaptureReviewDiagnostics.repeatedNoticeIDs(category))
                    .padding(.leading, hierarchyIndent)
            }
        }.padding(.leading, 16 + leadingInset).padding(.trailing, 16)
    }
    private var title: some View {
        WorkspaceCategoryTitle(id: category.id, title: displayTitle ?? category.title, fallbackSymbol: category.symbol)
    }
    private var status: some View {
        VStack(alignment: .leading, spacing: 3) {
            if !category.selectable {
                CaptureStatusText(title: category.headerSummary, state: category.row.status == "observation_error" ? .attention : .skipped)
            } else if model.selectionState(category) != .none && !category.notices.isEmpty { CaptureStatusText(title: "Needs Attention", state: .attention) }
            else if category.itemSelectable && model.selectionState(category) != .none {
                CaptureStatusText(title: CaptureReviewPresentation.selectionLabel(category, model: model))
            } else { Color.clear.frame(height: 1).accessibilityHidden(true) }
            if category.itemSelectable && model.selectionState(category) != .none && !category.notices.isEmpty {
                Text(CaptureReviewPresentation.selectionLabel(category, model: model))
                    .font(.caption).foregroundStyle(.secondary).padding(.leading, CaptureStatusText.textInset)
            }
        }.frame(width: TaskRowLayout.statusWidth, alignment: .leading)
    }
}

// Keep AppKit's checkbox and accessibility contract; SwiftUI wraps long labels.
struct CaptureItemSelectionRow: View {
    let title: String
    @Binding var included: Bool
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            NativeSelectionCheckbox("", isOn: $included, accessibilityTitle: title).frame(width: 20, height: 28)
            Text(title).font(.body).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .contentShape(Rectangle()).onTapGesture { included.toggle() }.accessibilityHidden(true)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 2)
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
            }.padding(.leading, 40).padding(.vertical, 4)
        }
    }
}

struct CaptureSecureTransferView: View {
    var inventory: CoreCaptureSecureInventory = .unavailable
    var selected: Set<String> = []
    var editable = false
    var select: (String, Bool) -> Void = { _, _ in }
    var selectAll: (Bool) -> Void = { _ in }
    var expansion: Binding<Bool>? = nil
    var addIdentity: (() -> Void)? = nil
    var removeIdentity: (String) -> Void = { _ in }
    var manualIDs: Set<String> = []
    var checkingIdentity = false
    var identityError: String? = nil
    var cancelIdentity: () -> Void = {}
    @CapturePresentationState<Bool> private var expanded = false
    private var selectedCount: Int { inventory.items.filter { selected.contains($0.id) }.count }
    var selectionState: SelectionState {
        selectedCount == 0 ? .none : selectedCount == inventory.items.count ? .all : .mixed
    }
    var selectionStatus: String {
        if inventory.status == "observation_error" { return "Needs Attention" }
        if inventory.items.isEmpty { return "Unavailable" }
        switch selectionState {
        case .none: return "Off"
        case .mixed: return "\(selectedCount) of \(inventory.items.count) selected"
        case .all: return "All Selected"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CaptureGroupHeader(title: "Secure Transfer", summary: selectionStatus, symbol: "lock.shield",
                selection: AnyView(master), expanded: expansion ?? $expanded)
            if expansion?.wrappedValue ?? expanded {
                VStack(alignment: .leading, spacing: 0) {
                    Text(inventory.status == "observation_error" ? "SSH identity candidates could not be read. Scan again before selecting identities."
                        : inventory.items.isEmpty ? "No eligible SSH identity pairs were found. Ordinary SSH Configuration is separate and remains selectable."
                        : "Choose SSH identity pairs to encrypt. Transfer is off until you select an identity. Candidates are fully validated during saving; ordinary SSH Configuration is separate.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, CaptureReviewPresentation.hierarchyStep * 2).padding(.bottom, 8)
                    if let addIdentity {
                        HStack {
                            Button("Add SSH Identity…", action: addIdentity).disabled(!editable)
                                .accessibilityIdentifier("capture.addSSHIdentity")
                            if checkingIdentity {
                                Text("Checking…").font(.caption).foregroundStyle(.secondary)
                                Button("Cancel", action: cancelIdentity)
                            }
                        }.padding(.leading, CaptureReviewPresentation.hierarchyStep * 2).padding(.bottom, 8)
                    }
                    if let identityError {
                        Text(identityError).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            .padding(.leading, CaptureReviewPresentation.hierarchyStep * 2).padding(.bottom, 8)
                    }
                    if !manualIDs.isEmpty {
                        Text("Manually added pairs restore to ~/.ssh using these names. SSH configuration is not rewritten; review IdentityFile if it expects another location.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            .padding(.leading, CaptureReviewPresentation.hierarchyStep * 2).padding(.bottom, 8)
                    }
                    ForEach(inventory.items) { identity in
                        HStack(alignment: .top, spacing: 8) {
                            NativeSelectionCheckbox("", state: selected.contains(identity.id) ? .all : .none,
                                accessibilityTitle: "Include SSH identity " + identity.label) { select(identity.id, $0) }
                                .frame(width: 20, height: 28)
                                .disabled(!editable)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(identity.label).font(.callout.weight(.medium))
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                                Text(identity.keyType + (manualIDs.contains(identity.id) ? " · Manually Added" : "")).font(.caption).foregroundStyle(.secondary)
                                Text(identity.fingerprint).font(.caption.monospaced()).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            if manualIDs.contains(identity.id) {
                                Button("Remove") { removeIdentity(identity.id) }.buttonStyle(.link).disabled(!editable)
                                    .accessibilityLabel("Remove manually added SSH identity " + identity.label)
                            }
                        }.padding(.leading, CaptureReviewPresentation.hierarchyStep * 2).padding(.vertical, 2)
                    }
                }.padding(.leading, 16 + CaptureChildRowGrid.leadingInset).padding(.trailing, 16)
            }
        }
    }
    @ViewBuilder private var master: some View {
        if !inventory.items.isEmpty {
            NativeSelectionCheckbox("", state: selectionState, accessibilityTitle: "Select Secure Transfer", setIncluded: selectAll)
                .disabled(!editable)
        } else { Color.clear.frame(width: 28, height: 28).accessibilityHidden(true) }
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
        let order = WorkspacePresentationTaxonomy.Group.allCases.flatMap { group in
            group == .macOSSettings ? ["macos-settings"] : group.domains
        }
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
        if summary.domainCount > 0 || summary.attentionCount > 0 || summary.secureIdentityCount > 0 {
            WorkspaceThreeMetrics { cards }
        }
    }
    @ViewBuilder private var cards: some View {
        if summary.domainCount > 0 {
            WorkspaceMetricCard(title: "\(summary.domainCount) Selected Domains", value: nil, symbol: "square.stack", tint: .blue,
                explanation: "\(summary.itemCount) Selected Items")
        }
        if summary.secureIdentityCount > 0 {
            WorkspaceMetricCard(title: "\(summary.secureIdentityCount) Selected SSH \(summary.secureIdentityCount == 1 ? "Identity" : "Identities")",
                value: nil, symbol: "lock.shield", tint: .blue, explanation: "Encrypted during saving")
        }
        if summary.attentionCount > 0 {
            CaptureMetricCard(title: "Needs Attention", count: summary.attentionCount, symbol: "exclamationmark.triangle", attention: true)
        }
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
                    }.padding(.vertical, 3)
                }
            }
        }.padding(.leading, 36).padding(.vertical, 8)
    }
}

// Publication is validated by CaptureModel before this presentation is available.
// Retain distinct structured issues; repeated event evidence is not another issue.
struct CaptureResultPresentation {
    let destination: URL
    let scope: String
    let attention: [DisplayCategory]
    var affectedCount: Int { attention.count }
    var attentionSummary: String { "\(affectedCount) affected \(affectedCount == 1 ? "category" : "categories")" }
    init(publication: CoreCapturePublication, notices: [DisplayCategory], secureIdentityCount: Int = 0) {
        destination = URL(fileURLWithPath: publication.destination)
        let domains = publication.bundle.capturedDomains.count
        let items = publication.bundle.itemCount
        scope = "\(domains) \(domains == 1 ? "domain" : "domains") · \(items) \(items == 1 ? "item" : "items") saved"
            + (publication.bundle.secureComponent ? " · \(secureIdentityCount) SSH \(secureIdentityCount == 1 ? "identity" : "identities") encrypted" : "")
        var grouped: [DisplayCategory] = []
        for notice in notices where publication.bundle.capturedDomains.contains(notice.id) {
            let index = grouped.firstIndex { $0.id == notice.id }
            var issues = index.map { grouped[$0].items } ?? []
            for item in notice.items where item.requiresAttention && !issues.contains(item) { issues.append(item) }
            guard !issues.isEmpty else { continue }
            let category = DisplayCategory(id: notice.id, title: CaptureCategory.title(for: notice.id), symbol: notice.symbol, items: issues)
            if let index { grouped[index] = category } else { grouped.append(category) }
        }
        attention = grouped
    }
    static func explanation(_ item: DisplayItem) -> String {
        // Event reasons stay in the log; never expose raw diagnostic content.
        if item.status == .unverified { return "The selected category's capture details could not be confirmed." }
        return switch item.reason {
        case "source_partial": "Some supported state could not be included."
        case "tool_unavailable": "A required tool was unavailable for part of this category."
        case "observation_failed": "Some selected state could not be read."
        default: "Some selected state may be unavailable in this saved category."
        }
    }
}

struct CaptureOutcomeCard: View {
    let title: String
    let detail: String
    let symbol: String
    let tint: Color
    var body: some View {
        HStack(spacing: 12) {
            WorkspaceCircleIcon(symbol: symbol, tint: tint, size: 44)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .combine)
    }
}

struct CaptureResultOutcomes: View {
    let result: CaptureResultPresentation
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) { cards.frame(minWidth: 280) }
            VStack(spacing: 12) { cards }
        }
    }
    @ViewBuilder private var cards: some View {
        CaptureOutcomeCard(title: "Save Complete", detail: result.scope, symbol: "checkmark", tint: .green)
            .accessibilityIdentifier("capture.result.completion")
        if !result.attention.isEmpty {
            CaptureOutcomeCard(title: "Needs Attention", detail: result.attentionSummary,
                symbol: "exclamationmark.triangle", tint: .orange)
                .accessibilityIdentifier("capture.result.attention")
        }
    }
}

struct CaptureResultContent: View {
    let result: CaptureResultPresentation
    var body: some View {
        WorkflowList {
            CaptureResultOutcomes(result: result)
            CaptureBundleLocationView(destination: result.destination, showsReveal: true)
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            if !result.attention.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(result.attention) { category in
                        VStack(alignment: .leading, spacing: 4) {
                            Label { Text(category.title).font(.callout.weight(.semibold)) } icon: {
                                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                            }
                            Text(category.items.map(CaptureResultPresentation.explanation).joined(separator: "\n") + " See View Log for details.")
                                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("capture.result.affected-categories")
            }
        }
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
            if editable && category.selectable {
                NativeSelectionCheckbox("", state: model.selectionState(category), accessibilityTitle: "Select " + category.title) {
                    model.selectCategory(category.id, included: $0)
                }.frame(width: 28, height: 48).padding(.leading, CaptureReviewPresentation.hierarchyStep)
            } else if editable {
                Color.clear.frame(width: 28, height: 48).padding(.leading, CaptureReviewPresentation.hierarchyStep).accessibilityHidden(true)
            }
            DisclosureGroup(isExpanded: expansion ?? $expanded) {
                VStack(alignment: .leading, spacing: 0) {
                    if !category.selectable {
                        CaptureNoticeDetails(items: category.display.items)
                    } else if let labels = CaptureSettingsPresentation.labels([category.row])[category.id], !labels.isEmpty {
                        CaptureIncludedSettingsList(labels: labels)
                    }
                    CaptureNoticeDetails(items: category.notices)
                }
            } label: {
                CaptureRowColumns(title: title, status: status)
            }.disclosureGroupStyle(TaskDisclosureStyle())
        }
    }
    private var title: some View { WorkspaceCategoryTitle(id: category.id, title: category.title, fallbackSymbol: category.symbol) }
    private var status: some View {
        Group {
            if !category.selectable {
                CaptureStatusText(title: category.headerSummary, state: category.row.status == "observation_error" ? .attention : .skipped)
            } else if model.selectionState(category) != .none && !category.notices.isEmpty { CaptureStatusText(title: "Needs Attention", state: .attention) }
            else if !editable || (category.itemSelectable && model.selectionState(category) != .none) {
                CaptureStatusText(title: CaptureReviewPresentation.selectionLabel(category, model: model))
            } else { Color.clear.frame(height: 1).accessibilityHidden(true) }
        }.frame(width: TaskRowLayout.statusWidth, alignment: .leading)
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
