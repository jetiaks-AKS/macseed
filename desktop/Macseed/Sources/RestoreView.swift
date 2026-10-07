import AppKit
import CoreServices
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
                    if !["satisfied", "safely_satisfiable"].contains(condition.status) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(RestoreStatusTone.prerequisite(condition.status).color)
                    }
                    Text(label).foregroundStyle(.primary)
                    Text("· " + status).foregroundStyle(RestoreStatusTone.prerequisite(condition.status).color)
                }
            }
            if condition.status != "satisfied" {
                Text(message).font(.callout)
                DisclosureGroup(technicalTitle) {
                    Text(condition.code).font(.caption.monospaced()).textSelection(.enabled)
                    if let diagnostic = condition.diagnostic {
                        Text(diagnostic.technicalDescription).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
                    .disclosureGroupStyle(TaskDisclosureStyle(minimumHeight: 22))
            }
        }
    }
    private var status: String {
        switch condition.status {
        case "satisfied": "Ready"
        case "safely_satisfiable": "Ready during Rebuild"
        case "unsupported": "Unsupported"
        default: condition.code.contains("authorization_required") ? "Authorization Required" : "Action Required"
        }
    }
    private var message: String {
        if let diagnostic = condition.diagnostic { return diagnostic.explanation }
        return switch condition.code {
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
    var showsPreviewActions = true
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            switch model.state {
            case .choose:
                WorkspacePrimaryActionCard(title: "Choose a Saved Environment", symbol: ProductTask.restore.symbol, tint: WorkspaceIdentity.tint(.restore),
                    message: "Choose a captured environment to inspect a read-only Preview before rebuilding this Mac.",
                    notice: "Nothing changes until you explicitly choose Rebuild.") {
                    Button("Choose Saved Environment…", action: chooseBundle).buttonStyle(.borderedProminent).disabled(runtime.isActive)
                }
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
                        areas: model.areas,
                        selectionStates: Dictionary(model.areas.map { ($0.id, model.previewSelectionState($0.id)) } + tasks.domains.map { ($0.id, model.previewSelectionState($0.id)) }, uniquingKeysWith: { first, _ in first }),
                        excludedAreas: model.areas.filter { $0.selectable && !prepared.selection.categories.contains($0.id) && prepared.selection.items[$0.id] == nil },
                        selectDomain: { model.selectPreviewDomain($0, included: $1) },
                        showsActions: showsPreviewActions, needsRefresh: model.previewNeedsRefresh, retryMessage: model.prerequisiteRetryMessage, retrying: model.retryingPrerequisites,
                        checkAgain: { Task { await model.checkPrerequisites() } },
                        back: { model.back() }, refresh: { model.refreshPreview() }, rebuild: { model.requestRebuild() }, canRebuild: model.canRebuild)
                }
            case .rebuilding:
                if let preview = model.executionPreview, let plan = model.executionPlan {
                    let tasks = RestoreTaskPresentation(preview: preview, plan: plan, events: runtime.events, executing: true)
                    RestoreRebuildProgressContent(tasks: tasks, activity: model.activity,
                        stopping: runtime.stopping, activities: model.executionActivities)
                }
                if showsRebuildActions {
                    RestoreRebuildActions(stopping: runtime.stopping, stop: { model.requestStop() })
                }
            case .result:
                if let result = model.executionResult {
                    RestoreResultContent(result: result,
                        refresh: { model.checkCurrentState() }, done: { model.finish() })
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
                Text("Macseed will apply the changes shown in this Preview. Items that already match will not be changed.")
                if model.preparation?.plan.contains(where: { $0.authorizationRequired == true }) == true {
                    Text("Some changes may require administrator authorization.")
                        .foregroundStyle(.secondary)
                }
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
    var selectionStates: [String: SelectionState] = [:]
    var excludedAreas: [CoreRestoreInspection.Area] = []
    var selectDomain: ((String, Bool) -> Void)? = nil
    var showsActions = true
    var needsRefresh = false
    var retryMessage: String? = nil
    var retrying = false
    var checkAgain: (() -> Void)? = nil
    var back: (() -> Void)? = nil
    var refresh: (() -> Void)? = nil
    var rebuild: (() -> Void)? = nil
    var canRebuild = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title).font(.title2.weight(.bold)).accessibilityAddTraits(.isHeader)
            if needsRefresh {
                Label("Selection changed. Refresh Preview to update counts and prerequisites. The current Preview shows the previous selection.", systemImage: "arrow.clockwise")
                    .font(.callout).foregroundStyle(.secondary)
            }
            RestorePreviewMetrics(domains: domains)
            if alreadyMatches { Text("Selected requirements already match this Mac.") }
            RestorePrerequisiteSummaryView(summary: prerequisites, areas: areas)
            if !prerequisites.blockers.isEmpty {
                Button(retrying ? "Checking…" : "Check Again") { checkAgain?() }.disabled(checkAgain == nil || needsRefresh || retrying)
                if let retryMessage { Text(retryMessage).font(.callout).foregroundStyle(.secondary) }
            }
            TaskDomainList(domains: domains.map { domain in
                var previewDomain = domain
                previewDomain.previewOnly = true
                return previewDomain
            }, selectionStates: selectionStates, selectDomain: selectDomain)
            if let selectDomain {
                ForEach(excludedAreas) { area in
                    HStack {
                        NativeSelectionCheckbox(area.label, state: selectionStates[area.id] ?? .none, accessibilityTitle: "Select " + area.label) {
                            selectDomain(area.id, $0)
                        }
                        Spacer()
                        Text((selectionStates[area.id] ?? SelectionState.none) == SelectionState.none ? "Not selected" : "Selected").font(.callout).foregroundStyle(.secondary)
                    }.padding(.vertical, 7)
                }
            }
            if showsActions {
                RestorePreviewActions(back: back, refresh: refresh, rebuild: rebuild, canRebuild: canRebuild)
            }
        }
    }
}

struct RestorePreviewActions: View {
    var back: (() -> Void)? = nil
    var refresh: (() -> Void)? = nil
    var rebuild: (() -> Void)? = nil
    var canRebuild = false
    var body: some View {
        HStack {
            Button("Back") { back?() }.disabled(back == nil)
            Button("Refresh Preview") { refresh?() }.disabled(refresh == nil)
            Button("Rebuild") { rebuild?() }.buttonStyle(.borderedProminent).disabled(!canRebuild || rebuild == nil)
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

// Execution content deliberately has no Preview summary or readiness inventory.
struct RestoreRebuildProgressContent: View {
    let tasks: RestoreTaskPresentation
    let activity: String
    let stopping: Bool
    let activities: [DisplayItem]
    private var verifying: Bool { activity.hasPrefix("Verifying") }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Rebuilding this Mac").font(.title.weight(.bold)).accessibilityAddTraits(.isHeader)
            Text(stopping ? "Stopping… Completed changes may remain." : activity).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                ProgressView()
                Text(stopping ? "Stopping Rebuild…" : verifying ? activity
                     : activities.compactMap(\.restoreActivity).first ?? activity).font(.title2)
            }.accessibilityElement(children: .combine)
            ForEach(tasks.domains) { domain in
                Text(domain.title).font(.headline)
                ForEach(domain.items) { item in
                    HStack {
                        Text(item.item.title).foregroundStyle(item.state == .completed ? .secondary : .primary)
                        Spacer()
                        TaskStatusLabel(state: item.state)
                    }.padding(.vertical, 3)
                    if [.failed, .skipped, .attention].contains(item.state) {
                        Text(item.item.action).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Divider()
            HStack {
                Text("Verification").font(.headline)
                Spacer()
                TaskStatusLabel(state: verifying ? .working : .waiting,
                    title: verifying ? "Verifying restored environment…" : "Waiting")
            }
        }
    }
}

struct RestoreResultContent: View {
    let result: RestoreExecutionPresentation
    let refresh: () -> Void
    let done: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(result.title).font(.title.weight(.bold)).accessibilityAddTraits(.isHeader)
            Text(result.message).foregroundStyle(.secondary)
            if !result.successfulAreas.isEmpty {
                Text("Verified selected work: " + result.successfulAreas.joined(separator: ", ")).font(.callout)
            }
            if !result.findings.isEmpty {
                Text("Needs Attention").font(.headline)
                RestorePreviewItemDetails(items: result.findings)
            }
            if result.outcome != .clean {
                DisclosureGroup("View Details") { RestorePreviewItemDetails(items: result.details) }
                    .disclosureGroupStyle(HeaderDisclosureStyle())
            }
            HStack {
                Button("Done", action: done).buttonStyle(.borderedProminent)
                if result.outcome != .clean { Button("Refresh Preview", action: refresh) }
                PendingOperationLogButton()
            }
        }
    }
}


struct RestorePreviewMetrics: View {
    let domains: [TaskDomainPresentation]
    static func counts(_ domains: [TaskDomainPresentation]) -> (changes: Int, attention: Int, matching: Int) {
        let items = domains.flatMap(\.items)
        return (items.filter { $0.state == .planned }.count,
                items.filter { [.attention, .unverified].contains($0.state) }.count,
                items.filter { $0.state == .matching }.count)
    }
    var body: some View {
        let counts = Self.counts(domains)
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { cards(counts) }
            VStack(spacing: 8) { cards(counts) }
        }
    }
    @ViewBuilder private func cards(_ counts: (changes: Int, attention: Int, matching: Int)) -> some View {
        metric("Changes Planned", count: counts.changes, symbol: "arrow.down.circle", color: .primary)
        metric("Need Attention", count: counts.attention, symbol: "exclamationmark.triangle", color: counts.attention > 0 ? RestoreStatusTone.warning.color : .secondary)
        metric("Already Match", count: counts.matching, symbol: "checkmark.circle", color: RestoreStatusTone.success.color)
    }
    private func metric(_ title: String, count: Int, symbol: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(String(count), systemImage: symbol).font(.title2.weight(.semibold)).monospacedDigit()
            Text(title).font(.callout)
        }.foregroundStyle(color).frame(minWidth: 140, maxWidth: .infinity, alignment: .leading).padding(14)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .ignore).accessibilityLabel(title).accessibilityValue(String(count))
    }
}

// Called only from the user's prerequisite retry, never from Prepare.
enum RestoreAutomationPermission {
    enum Outcome: Equatable {
        case available, denied, unavailable
        var message: String? {
            switch self {
            case .available: nil
            case .denied: "Allow Macseed → System Events in System Settings → Privacy & Security → Automation, then Check Again. Access may be restricted by your administrator."
            case .unavailable: "System Events access is unavailable. Resolve the system restriction, then Check Again."
            }
        }
    }
    static func resolve(check: () async -> OSStatus, prompt: () async -> OSStatus,
                        start: () async throws -> Void) async -> Outcome {
        var status = await check()
        if status == OSStatus(procNotFound) {
            do { try await start(); status = await check() }
            catch { return .unavailable }
        }
        // errAEEventWouldRequireUserConsent is returned by the nonprompting check.
        if status == OSStatus(-1744) { status = await prompt() }
        if status == noErr { return .available }
        if status == OSStatus(errAEEventNotPermitted) { return .denied }
        return .unavailable
    }
    @MainActor static func requestAccess() async -> Outcome {
        await resolve(check: { await permission(ask: false) }, prompt: { await permission(ask: true) }, start: {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            _ = try await NSWorkspace.shared.openApplication(
                at: URL(fileURLWithPath: "/System/Library/CoreServices/System Events.app"), configuration: configuration)
        })
    }
    private static func permission(ask: Bool) async -> OSStatus {
        await Task.detached {
            let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.systemevents")
            return AEDeterminePermissionToAutomateTarget(target.aeDesc, AEEventClass(kCoreEventClass), AEEventID(kAEGetData), ask)
        }.value
    }
}
