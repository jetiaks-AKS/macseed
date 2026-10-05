import AppKit
import SwiftUI
import UniformTypeIdentifiers

private typealias RestoreViewState<Value> = SwiftUI.State<Value>

// Restore peers share slots even when their domain has no disclosure or icon.
enum RestoreRowGrid {
    static let checkboxWidth: CGFloat = 28
    static let disclosureWidth: CGFloat = 12
    static let iconWidth: CGFloat = 20
    static let spacing: CGFloat = 8
    static let titleInset = checkboxWidth + disclosureWidth + iconWidth + spacing * 3
}

struct RestoreRowIcon: View {
    let symbol: String
    static func symbol(for domain: String) -> String {
        domain == "vscode-settings" ? "gearshape" : "square.stack"
    }
    var body: some View {
        Image(systemName: symbol).font(.body.weight(.regular))
            .frame(width: RestoreRowGrid.iconWidth, alignment: .center).foregroundStyle(.secondary)
            .accessibilityHidden(true)
    }
}

struct RestoreHeaderDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isExpanded.toggle() } label: {
            HStack(spacing: RestoreRowGrid.spacing) {
                Image(systemName: "chevron.right")
                    .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .frame(width: RestoreRowGrid.disclosureWidth)
                configuration.label
            }.frame(maxWidth: .infinity, minHeight: 28, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
    }
}

struct RestoreAreaSelectionView: View {
    @ObservedObject var model: RestoreModel
    let area: CoreRestoreInspection.Area
    @RestoreViewState<Bool> private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: RestoreRowGrid.spacing) {
                NativeSelectionCheckbox("", state: model.selectionState(area), accessibilityTitle: "Select " + area.label) {
                    model.selectArea(area.id, included: $0)
                }.frame(width: RestoreRowGrid.checkboxWidth, height: 28).disabled(!area.selectable)
                if area.selectionMode == "items" {
                    DisclosureGroup(isExpanded: $expanded) { EmptyView() } label: { header }
                        .disclosureGroupStyle(RestoreHeaderDisclosureStyle())
                } else {
                    Color.clear.frame(width: RestoreRowGrid.disclosureWidth, height: 1).accessibilityHidden(true)
                    Button { model.selectArea(area.id, included: model.selectionState(area) != .all) } label: { header }
                        .buttonStyle(.plain).disabled(!area.selectable)
                }
            }
            if expanded && area.selectionMode == "items" {
                ForEach(area.items) { item in
                    NativeSelectionCheckbox(item.label, isOn: Binding(
                        get: { model.selectedItems[area.id]?.contains(item.id) == true },
                        set: { model.selectItem(area.id, item: item.id, included: $0) }))
                        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading).disabled(!area.selectable)
                }.padding(.leading, CaptureChildRowGrid.leadingInset)
            }
            if !notices.isEmpty { ItemDetails(items: notices).padding(.leading, RestoreRowGrid.titleInset) }
        }.padding(.vertical, 7)
    }
    private var header: some View {
        HStack(spacing: RestoreRowGrid.spacing) {
            RestoreRowIcon(symbol: RestoreRowIcon.symbol(for: area.id))
            Text(area.label).font(.headline)
            Spacer()
            Text(!area.selectable ? "Unavailable" : area.selectionMode == "items"
                 ? "\(model.selectedItems[area.id]?.count ?? 0) of \(area.items.count) selected"
                 : model.selectionState(area) == .none ? "Not selected" : "Included")
                .font(.callout).foregroundStyle(.secondary)
            if !area.selectable || area.reason != nil {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityLabel("Needs Attention")
            }
        }.frame(maxWidth: .infinity, minHeight: 28, alignment: .leading).contentShape(Rectangle())
    }
    private var notices: [DisplayItem] {
        guard !area.selectable || area.reason != nil else { return [] }
        return [DisplayItem(id: area.id + ":availability", title: area.availability == "unsupported" ? "Unsupported" : "Unavailable",
            status: area.availability == "unsupported" ? .unsupported : .information,
            action: "No selectable supported content is available in this saved environment.", reason: area.reason)]
    }
}

// Only section placement is Desktop-owned; membership, modes and items stay Core-owned.
struct RestorePresentationSection: Identifiable {
    let id: String
    let groups: [CoreRestoreInspection.Group]
    static func project(_ groups: [CoreRestoreInspection.Group]) -> [Self] {
        let placement: [(String, [String])] = [
            ("Applications & Tools", ["Applications", "Homebrew"]),
            ("Settings", ["macOS Settings", "VS Code Settings"]),
            ("Shell", ["Shell"]), ("Git", ["Git"]),
            ("SSH Configuration", ["SSH Configuration"]), ("Workspace", ["Workspace"])]
        return placement.map { title, names in
            Self(id: title, groups: names.compactMap { name in groups.first { $0.id == name } })
        }
    }
    static func visible(_ groups: [CoreRestoreInspection.Group], inventory: [CoreRestoreInspection.Area]) -> [Self] {
        project(groups).filter { $0.areas(in: inventory).contains(where: \.selectable) }
    }
    func areas(in inventory: [CoreRestoreInspection.Area]) -> [CoreRestoreInspection.Area] {
        let domains = groups.flatMap(\.domains)
        let order = ["homebrew-casks", "app-store", "homebrew-packages", "vscode-extensions"]
        let arranged = id == "Applications & Tools"
            ? domains.sorted { (order.firstIndex(of: $0) ?? order.count) < (order.firstIndex(of: $1) ?? order.count) } : domains
        return arranged.compactMap { domain in inventory.first { $0.id == domain } }
    }
}

struct RestoreSectionHeader: View {
    let title: String
    var body: some View {
        HStack(spacing: 12) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1)
        }.padding(.top, 12).padding(.bottom, 4).accessibilityAddTraits(.isHeader)
    }
}

struct RestoreMacOSSelectionView: View {
    @ObservedObject var model: RestoreModel
    let group: CoreRestoreInspection.Group
    private var available: Bool { model.areas.contains { group.domains.contains($0.id) && $0.selectable } }
    var body: some View {
        HStack(spacing: RestoreRowGrid.spacing) {
            NativeSelectionCheckbox("", state: model.groupState(group), accessibilityTitle: "Select " + group.id) {
                model.selectGroup(group, included: $0)
            }.frame(width: RestoreRowGrid.checkboxWidth, height: 28).disabled(!available)
            Color.clear.frame(width: RestoreRowGrid.disclosureWidth, height: 1).accessibilityHidden(true)
            Button { model.selectGroup(group, included: model.groupState(group) != .all) } label: {
                HStack(spacing: RestoreRowGrid.spacing) {
                    RestoreRowIcon(symbol: "slider.horizontal.3")
                    Text(group.id).font(.headline)
                    Spacer()
                    Text(!available ? "Unavailable" : model.groupState(group) == .none ? "Not selected" : model.groupState(group) == .all ? "Included" : "Partially included")
                        .font(.callout).foregroundStyle(.secondary)
                    if model.areas.contains(where: { group.domains.contains($0.id) && (!$0.selectable || $0.reason != nil) }) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityLabel("Needs Attention")
                    }
                }.frame(maxWidth: .infinity, minHeight: 28, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(!available)
        }.padding(.vertical, 7)
    }
}

enum RestoreStatusTone: Equatable {
    case success, warning, error, neutral
    var color: Color {
        switch self {
        case .success:
            Color(nsColor: Self.successColor)
        case .warning: Color(nsColor: .systemOrange)
        case .error: Color(nsColor: .systemRed)
        case .neutral: .secondary
        }
    }
    // Retain the system hue, with readable small text on light surfaces.
    static var successColor: NSColor {
        NSColor(name: NSColor.Name("MacseedRestoreSuccess")) { appearance in
            var green = NSColor.systemGreen
            appearance.performAsCurrentDrawingAppearance { green = NSColor.systemGreen.usingColorSpace(.sRGB) ?? .systemGreen }
            return appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? green : green.blended(withFraction: 0.40, of: .black) ?? green
        }
    }
    static func status(_ status: DisplayStatus) -> Self {
        switch status {
        case .matching, .complete: .success
        case .attention, .missing, .different, .unverified, .unresolved: .warning
        default: .neutral
        }
    }
    static func domain(_ state: String) -> Self {
        switch state {
        case "Already Matches": .success
        case "Needs Attention": .warning
        case "Error", "Failed": .error
        default: .neutral
        }
    }
    static func prerequisite(_ state: String) -> Self {
        switch state {
        case "satisfied": .success
        case "external_action_required", "unsupported": .warning
        case "error", "failed": .error
        default: .neutral
        }
    }
}

struct RestorePreviewItemDetails: View {
    let items: [DisplayItem]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(items) { item in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title).foregroundStyle(.primary)
                        Text(item.action).font(.callout).foregroundStyle(.secondary)
                        if let reason = item.reason {
                            DisclosureGroup("Technical reason") {
                                Text(reason).font(.caption.monospaced()).textSelection(.enabled)
                            }.disclosureGroupStyle(TaskDisclosureStyle(minimumHeight: 22)).font(.caption)
                        }
                    }
                    Spacer()
                    if item.status == .matching || item.status == .ready {
                        Text(item.status == .matching ? "OK" : item.restoreReadyText ?? "Ready to Restore")
                            .font(.callout.weight(.medium)).foregroundStyle(RestoreStatusTone.status(item.status).color)
                    } else {
                        Label(item.status.rawValue, systemImage: item.status.symbol)
                            .font(.callout).foregroundStyle(RestoreStatusTone.status(item.status).color)
                    }
                }
            }
        }.padding(.vertical, 8)
    }
}

struct RestorePrerequisiteView: View {
    let condition: CoreRestorePreparation.Condition
    let label: String
    var showsHeading: Bool = true
    var technicalTitle: String = "Technical reason"
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if showsHeading {
                HStack {
                    if condition.status != "satisfied" {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(RestoreStatusTone.prerequisite(condition.status).color)
                    }
                    Text(label).foregroundStyle(.primary)
                    Text("· " + status).foregroundStyle(RestoreStatusTone.prerequisite(condition.status).color)
                }
            }
            if condition.status != "satisfied" {
                Text(message).font(.callout)
                DisclosureGroup(technicalTitle) { Text(condition.code).font(.caption.monospaced()).textSelection(.enabled) }
                    .disclosureGroupStyle(TaskDisclosureStyle(minimumHeight: 22))
            }
        }
    }
    private var status: String {
        switch condition.status {
        case "satisfied": "Already Satisfied"
        case "safely_satisfiable": "Can be prepared during Rebuild"
        case "unsupported": "Unsupported"
        default: "Prerequisite Required"
        }
    }
    private var message: String {
        switch condition.code {
        case "homebrew_installation_requires_interaction": "Install Homebrew outside Macseed, then Check Again. Macseed will not install it during Preview."
        case "homebrew_unavailable": "Make the existing Homebrew installation usable, then Check Again."
        case "vscode_cli_required", "vscode_cli_unavailable": "Make the Visual Studio Code command-line tool available, then Check Again."
        case "vscode_cli_ambiguous": "Resolve the multiple Visual Studio Code installations, then Check Again."
        case "git_required", "git_unavailable": "Make Git available, then Check Again."
        case "mas_required", "mas_unavailable": "Make the App Store command-line tool available, then Check Again."
        case "internet_required": "Connect this Mac to the internet, then Check Again."
        case "command_line_tools_required": "Install the macOS Command Line Tools outside Macseed, then Check Again."
        case "authorization_required", "cask_authorization_required": "Selected work requires external authorization. Resolve it outside this Preview, then Check Again."
        case "preview_observation_failed": "Current state could not be inspected reliably. Resolve the inspection issue, then Check Again."
        default:
            switch condition.status {
            case "safely_satisfiable": "Core can satisfy this condition later using its existing Rebuild behavior. Preview makes no changes."
            case "unsupported": "This selected requirement is not supported by the current application execution path."
            default: "Resolve this requirement outside Macseed, then Check Again to inspect the current state."
            }
        }
    }
}

struct RestoreView: View {
    @ObservedObject var model: RestoreModel
    @ObservedObject var runtime: CoreRuntime
    var showsRebuildActions = true
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            switch model.state {
            case .choose:
                Text("Choose a saved environment to prepare this Mac for Rebuild.")
                Button("Choose Saved Environment…", action: chooseBundle).buttonStyle(.borderedProminent).disabled(runtime.isActive)
            case .inspecting, .preparing:
                ProgressView(runtime.stopping ? "Stopping…" : (model.state == .inspecting ? "Inspecting saved environment…" : "Preparing Restore Preview…"))
                Button("Cancel", role: .cancel) { model.cancel() }.disabled(runtime.stopping)
            case .review, .preview, .confirming:
                if let source = model.source {
                    HStack {
                        Label(source.lastPathComponent, systemImage: "shippingbox").font(.headline)
                        Spacer()
                        Button("Change…", action: chooseBundle)
                    }
                }
                if model.inspection?.secureComponent == true {
                    Label("Secure Transfer is not available in this build.", systemImage: "lock.shield")
                    Text("This saved environment contains encrypted identity material. Private SSH identities will not be restored; ordinary SSH Configuration remains separate.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if model.state == .review {
                    HStack {
                        Text("Choose what to restore").font(.title2)
                        Spacer()
                        Button(model.bulkState.bulkActionTitle) { model.toggleAll() }.disabled(!model.areas.contains(where: \.selectable))
                    }
                    ForEach(RestorePresentationSection.visible(model.groups, inventory: model.areas)) { section in
                        RestoreSectionHeader(title: section.id)
                        if let macOS = section.groups.first(where: { $0.id == "macOS Settings" }) {
                            RestoreMacOSSelectionView(model: model, group: macOS)
                        }
                        ForEach(section.areas(in: model.areas).filter { area in
                            !section.groups.contains { $0.id == "macOS Settings" && $0.domains.contains(area.id) }
                        }) { RestoreAreaSelectionView(model: model, area: $0) }
                    }
                    Text(model.selectionSummary).font(.callout).foregroundStyle(.secondary)
                    Button("Preview Restore") { model.refreshPreview() }.buttonStyle(.borderedProminent).disabled(!model.canPreview)
                } else if let prepared = model.preparation, let preview = model.preview {
                    let tasks = RestoreTaskPresentation(preview: preview, plan: prepared)
                    let needsAttention = !model.ready || tasks.domains.contains { [.attention, .unverified, .partial].contains($0.state) }
                    RestorePreviewContent(
                        title: needsAttention ? "Needs Attention" : prepared.hasPlannedChanges ? "Ready to Rebuild" : "Everything already matches",
                        message: preview.summary, state: needsAttention ? .attention : prepared.hasExecutableChanges ? .planned : .matching,
                        domains: tasks.domains, counters: tasks.counters,
                        alreadyMatches: !prepared.hasPlannedChanges && prepared.plan.allSatisfy { $0.disposition == "satisfied" },
                        prerequisites: RestorePrerequisiteSummaryPresentation(conditions: prepared.readiness.conditions, ready: prepared.readiness.ready),
                        areas: model.areas, checkAgain: { model.refreshPreview() },
                        back: { model.back() }, refresh: { model.refreshPreview() }, rebuild: { model.requestRebuild() }, canRebuild: model.canRebuild)
                    if !prepared.hasPlannedChanges && prepared.plan.allSatisfy({ $0.disposition == "satisfied" }) {
                        Text("Everything already matches. No Rebuild is needed.").font(.callout).foregroundStyle(.secondary)
                    }
                }
            case .rebuilding:
                if let preview = model.executionPreview, let plan = model.executionPlan {
                    let tasks = RestoreTaskPresentation(preview: preview, plan: plan, events: runtime.events, executing: true)
                    OperationSummaryHeader(title: model.activity.hasPrefix("Verifying") ? "Verifying Your Mac" : "Rebuilding Your Mac",
                        message: runtime.stopping ? "Stopping… Completed changes may remain." : model.activity,
                        state: .working, counters: tasks.counters, startedAt: model.executionStartedAt)
                    TaskDomainList(domains: tasks.domains)
                }
                if showsRebuildActions {
                    RestoreRebuildActions(stopping: runtime.stopping, stop: { model.requestStop() })
                }
            case .result:
                if let result = model.executionResult {
                    if let preview = model.executionPreview, let plan = model.executionPlan {
                        let tasks = RestoreTaskPresentation(preview: preview, plan: plan, events: runtime.events, result: result)
                        OperationSummaryHeader(title: result.title, message: result.message,
                            state: result.outcome == .clean ? .completed : result.outcome == .partial ? .partial
                                : [.failedBeforeMutation, .failedAfterMutation].contains(result.outcome) ? .failed : .attention,
                            counters: tasks.counters, startedAt: model.executionStartedAt,
                            finishedAt: model.executionFinishedAt)
                        HStack {
                            PendingOperationLogButton()
                            Button("Refresh Preview") { model.checkCurrentState() }
                        }
                        TaskDomainList(domains: tasks.domains)
                    } else {
                        Text(result.title).font(.title2)
                        Text(result.message)
                    }
                    DisclosureGroup("View Details") { RestorePreviewItemDetails(items: result.details) }
                        .disclosureGroupStyle(HeaderDisclosureStyle())
                    Button("Done") { model.finish() }
                }
            case .failed, .cancelled:
                Label(model.state == .cancelled ? "Restore Preparation Cancelled" : "Can't Prepare Restore", systemImage: "exclamationmark.triangle").font(.title2)
                if let failure = model.failure { Text(failure) }
                if let reason = model.technicalReason {
                    DisclosureGroup("Technical reason") { Text(reason).font(.caption.monospaced()).textSelection(.enabled) }
                        .disclosureGroupStyle(HeaderDisclosureStyle())
                }
                HStack {
                    Button("Choose Saved Environment…", action: chooseBundle)
                    if model.canPreview { Button("Refresh Preview") { model.refreshPreview() } }
                    if model.inspection != nil { Button("Back") { model.back() } }
                }
            }
            if model.state != .rebuilding && model.state != .result {
                Text("Restore Preview is read-only. No packages, settings, repositories or SSH identities are changed.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: Binding(get: { model.state == .confirming }, set: { if !$0 { model.cancelRebuildConfirmation() } })) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Rebuild this Mac?").font(.title2)
                Text("Macseed will apply the changes shown in this Preview. Existing matching items will be left unchanged.")
                if model.preparation?.warningCount ?? 0 > 0 {
                    Text("This Preview includes attention conditions. Review them before continuing.").foregroundStyle(.orange)
                }
                HStack {
                    Button("Cancel", role: .cancel) { model.cancelRebuildConfirmation() }
                    Button("Rebuild") { model.confirmRebuild() }.buttonStyle(.borderedProminent)
                }
            }.padding(24).frame(width: 420).interactiveDismissDisabled()
        }
        .sheet(isPresented: $model.stopConfirmation) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Stop rebuilding?").font(.title2)
                Text("Completed changes will remain. Macseed will inspect the current state before you rebuild again.")
                HStack {
                    Button("Keep Working") { model.stopConfirmation = false }
                    Button("Stop Rebuild", role: .cancel) { model.confirmStop() }
                }
            }.padding(24).frame(width: 420).interactiveDismissDisabled()
        }
    }
    private func chooseBundle() {
        let panel = NSOpenPanel()
        panel.title = "Choose Saved Environment"
        panel.allowedContentTypes = [UTType(filenameExtension: "mbt", conformingTo: .data)!]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            if response == .OK, let url = panel.url { model.choose(url) }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }
}

// Real and synthetic Preview share the same presentation hierarchy and spacing.
struct RestorePreviewContent: View {
    let title: String
    let message: String
    let state: TaskRowState
    let domains: [TaskDomainPresentation]
    let counters: [(state: TaskRowState, count: Int)]
    let alreadyMatches: Bool
    let prerequisites: RestorePrerequisiteSummaryPresentation
    let areas: [CoreRestoreInspection.Area]
    var checkAgain: (() -> Void)? = nil
    var back: (() -> Void)? = nil
    var refresh: (() -> Void)? = nil
    var rebuild: (() -> Void)? = nil
    var canRebuild = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            OperationSummaryHeader(title: title, message: message, state: state, counters: counters)
            if alreadyMatches { Text("Selected requirements already match this Mac.") }
            RestorePreviewAttentionSummaryView(summary: RestoreIssueSummaryPresentation(categories: domains.map {
                DisplayCategory(id: $0.id, title: $0.title, symbol: $0.symbol, items: $0.items.map(\.item))
            }))
            RestorePrerequisiteSummaryView(summary: prerequisites, areas: areas)
            if !prerequisites.blockers.isEmpty {
                Button("Check Again") { checkAgain?() }.disabled(checkAgain == nil)
            }
            TaskDomainList(domains: domains)
            HStack {
                Button("Back") { back?() }.disabled(back == nil)
                Button("Refresh Preview") { refresh?() }.disabled(refresh == nil)
                Button("Rebuild") { rebuild?() }.buttonStyle(.borderedProminent).disabled(!canRebuild || rebuild == nil)
            }
        }
    }
}

struct RestoreRebuildActions: View {
    var stopping = false
    var stop: (() -> Void)? = nil
    var body: some View {
        HStack {
            PendingOperationLogButton()
            Spacer()
            Button("Stop Rebuild", role: .cancel) { stop?() }.disabled(stopping || stop == nil)
        }
    }
}
