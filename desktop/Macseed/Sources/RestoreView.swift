import AppKit
import CoreServices
import SwiftUI
import UniformTypeIdentifiers

private typealias RestoreViewState<Value> = SwiftUI.State<Value>

// Restore peers share slots even when their domain has no disclosure or icon.
enum RestoreRowGrid {
    static let checkboxWidth: CGFloat = 28
    static let disclosureWidth: CGFloat = 12
    static let iconWidth: CGFloat = TaskRowLayout.iconWidth
    static let spacing: CGFloat = 12
    static let titleInset = checkboxWidth + disclosureWidth + iconWidth + spacing * 3
}

struct RestoreRowIcon: View {
    let symbol: String
    static func symbol(for domain: String) -> String {
        WorkspaceCategoryStyle.symbol(domain, fallback: "square.stack")
    }
    var body: some View {
        WorkspaceCategoryIcon(symbol: symbol)
    }
}

struct RestoreAreaSelectionView: View {
    @ObservedObject var model: RestoreModel
    let area: CoreRestoreInspection.Area
    var expansion: Binding<Bool>? = nil
    @RestoreViewState<Bool> private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: RestoreRowGrid.spacing) {
                NativeSelectionCheckbox("", state: model.selectionState(area), accessibilityTitle: "Select " + area.label) {
                    model.selectArea(area.id, included: $0)
                }.frame(width: RestoreRowGrid.checkboxWidth, height: 28).disabled(!area.selectable)
                if Self.hasDisclosure(area) {
                    DisclosureGroup(isExpanded: expansion ?? $expanded) { EmptyView() } label: { header.padding(.vertical, 6) }
                        .disclosureGroupStyle(TaskDisclosureStyle())
                } else {
                    header.padding(.vertical, 6).padding(.trailing, 26).frame(minHeight: 48)
                }
            }
            if Self.hasDisclosure(area) && (expansion?.wrappedValue ?? expanded) {
                if area.selectionMode == "items" {
                    ForEach(area.items) { item in
                        NativeSelectionCheckbox(item.label, isOn: Binding(
                            get: { model.selectedItems[area.id]?.contains(item.id) == true },
                            set: { model.selectItem(area.id, item: item.id, included: $0) }))
                            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading).disabled(!area.selectable)
                    }.padding(.leading, CaptureChildRowGrid.leadingInset)
                } else {
                    VStack(alignment: .leading, spacing: 7) { ForEach(area.items) { item in Text(item.label) } }
                        .padding(.leading, 36).padding(.vertical, 4)
                }
            }
            if !notices.isEmpty { ItemDetails(items: notices).padding(.leading, RestoreRowGrid.titleInset) }
        }.padding(.horizontal, 16)
    }
    static func hasDisclosure(_ area: CoreRestoreInspection.Area) -> Bool { !area.items.isEmpty }
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { title; Spacer(); status }
            VStack(alignment: .leading, spacing: 8) { title; status }
        }
    }
    private var title: some View {
        WorkspaceCategoryTitle(id: area.id, title: area.label, fallbackSymbol: RestoreRowIcon.symbol(for: area.id))
    }
    private var status: some View {
        HStack(spacing: 7) {
            if !area.selectable || area.reason != nil {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityLabel("Needs Attention")
            }
            Text(!area.selectable ? "Unavailable" : area.selectionMode == "items"
                 ? "\(model.selectedItems[area.id]?.count ?? 0) of \(area.items.count) selected"
                 : model.selectionState(area) == .none ? "Not selected" : "Included")
        }.font(.callout).foregroundStyle(.secondary)
    }
    private var notices: [DisplayItem] { Self.notices(area) }
    static func notices(_ area: CoreRestoreInspection.Area) -> [DisplayItem] {
        guard !area.selectable || area.reason != nil else { return [] }
        return [DisplayItem(id: area.id + ":availability", title: area.selectable ? "Needs Attention" : area.availability == "unsupported" ? "Unsupported" : "Unavailable",
            status: area.selectable ? .attention : area.availability == "unsupported" ? .unsupported : .information,
            action: area.selectable ? "This category has a reported warning. Review its diagnostic details."
                : "No selectable supported content is available in this saved environment.", reason: area.reason)]
    }
}

// Only section placement is Desktop-owned; membership, modes and items stay Core-owned.
struct RestorePresentationSection: Identifiable {
    let id: String
    let groups: [CoreRestoreInspection.Group]
    static func project(_ groups: [CoreRestoreInspection.Group]) -> [Self] {
        let known = Set(WorkspaceCategoryStyle.groups.flatMap { $0.1 })
        let fallbackGroups = ["Applications & Tools": ["Applications", "Homebrew"],
            "Settings": ["macOS Settings", "VS Code Settings"], "Git": ["Git"],
            "SSH Configuration": ["SSH Configuration"], "Workspace": ["Workspace"], "Shell": ["Shell"]]
        var claimed = Set<String>()
        var sections = WorkspaceCategoryStyle.groups.map { title, ids in
            Self(id: title, groups: groups.compactMap { group in
                // New/unknown IDs retain their Core-declared visual group. Known
                // IDs use Status placement, including repositories in Workspace.
                let candidates = ids.filter(group.domains.contains) + group.domains.filter {
                    !known.contains($0) && (fallbackGroups[title] ?? []).contains(group.id)
                }
                let domains = candidates.filter { claimed.insert($0).inserted }
                return domains.isEmpty ? nil : CoreRestoreInspection.Group(id: group.id, domains: domains)
            })
        }
        let used = Set(sections.flatMap(\.groups).flatMap(\.domains))
        let other = groups.compactMap { group -> CoreRestoreInspection.Group? in
            let domains = group.domains.filter { !used.contains($0) }
            return domains.isEmpty ? nil : CoreRestoreInspection.Group(id: group.id, domains: domains)
        }
        if !other.isEmpty { sections.append(Self(id: "Other Findings", groups: other)) }
        return sections
    }
    static func includedAreas(_ inventory: [CoreRestoreInspection.Area]) -> [CoreRestoreInspection.Area] {
        // Older adapters without presence evidence remain visible, including empty/unsupported state.
        inventory.filter { $0.sourcePresent != false && $0.captureSelected != false }
    }
    static func visible(_ groups: [CoreRestoreInspection.Group], inventory: [CoreRestoreInspection.Area]) -> [Self] {
        project(groups).filter { !$0.areas(in: inventory).isEmpty }
    }
    func areas(in inventory: [CoreRestoreInspection.Area]) -> [CoreRestoreInspection.Area] {
        let domains = groups.flatMap(\.domains)
        let preferred = WorkspaceCategoryStyle.groups.first { $0.0 == id }?.1 ?? []
        let order = preferred.filter(domains.contains) + domains.filter { !preferred.contains($0) }
        return order.compactMap { domain in inventory.first { $0.id == domain } }
    }
}

struct RestoreMacOSSelectionView: View {
    @ObservedObject var model: RestoreModel
    let group: CoreRestoreInspection.Group
    var expansion: Binding<Bool>? = nil
    var childExpansion: Binding<Bool>? = nil
    @RestoreViewState<Bool> private var expanded = false
    private var detailAreas: [CoreRestoreInspection.Area] {
        CaptureMacOSSettingsGroup.domainIDs.compactMap { id in
            model.areas.first { $0.id == id && group.domains.contains($0.id) && $0.sourcePresent != false && $0.captureSelected != false }
        }
    }
    private var available: Bool { model.areas.contains { group.domains.contains($0.id) && $0.selectable } }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                NativeSelectionCheckbox("", state: model.groupState(group), accessibilityTitle: "Select " + group.id) {
                    model.selectGroup(group, included: $0)
                }.frame(width: RestoreRowGrid.checkboxWidth, height: 48).disabled(!available)
                if !detailAreas.isEmpty {
                    DisclosureGroup(isExpanded: expansion ?? $expanded) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(detailAreas) { area in
                                HStack(alignment: .top, spacing: 12) {
                                    NativeSelectionCheckbox("", state: model.selectionState(area), accessibilityTitle: "Select " + area.label) {
                                        model.selectArea(area.id, included: $0)
                                    }.frame(width: RestoreRowGrid.checkboxWidth, height: 48).disabled(!area.selectable)
                                    RestoreMacOSAreaDetails(area: area, expansion: childExpansion)
                                }
                            }
                        }.padding(.leading, 36).padding(.vertical, 4)
                    } label: { header }
                        .disclosureGroupStyle(TaskDisclosureStyle())
                } else {
                    header.padding(.trailing, 26).frame(minHeight: 48)
                }
            }
        }.padding(.horizontal, 16)
    }
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { title; Spacer(); status }
            VStack(alignment: .leading, spacing: 8) { title; status }
        }.padding(.vertical, 6)
    }
    private var title: some View {
        WorkspaceCategoryTitle(id: "macos-settings", title: group.id, fallbackSymbol: "slider.horizontal.3")
    }
    private var status: some View {
        HStack(spacing: 7) {
            if model.areas.contains(where: { group.domains.contains($0.id) && $0.sourcePresent != false && $0.captureSelected != false && (!$0.selectable || $0.reason != nil) }) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityLabel("Needs Attention")
            }
            Text(!available ? "Unavailable" : model.groupState(group) == .none ? "Not selected" : model.groupState(group) == .all ? "Included" : "Partially included")
        }.font(.callout).foregroundStyle(.secondary)
    }
}

// Subdomains explain the existing category-only contract; no individual setting controls.
struct RestoreMacOSAreaDetails: View {
    let area: CoreRestoreInspection.Area
    var expansion: Binding<Bool>? = nil
    @RestoreViewState<Bool> private var expanded = false
    static func hasDetails(_ area: CoreRestoreInspection.Area) -> Bool {
        !area.items.isEmpty || area.reason != nil || !area.selectable
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !area.items.isEmpty {
                DisclosureGroup(isExpanded: expansion ?? $expanded) {
                    VStack(alignment: .leading, spacing: 7) { ForEach(area.items) { item in Text(item.label) } }
                        .padding(.leading, 36).padding(.vertical, 4)
                } label: { title }
                    .disclosureGroupStyle(TaskDisclosureStyle())
            } else { title.frame(minHeight: 48) }
            if !area.selectable {
                Text("No selectable supported content is available in this saved environment.")
                    .font(.callout).foregroundStyle(.secondary).padding(.leading, 36)
            }
            if let reason = area.reason {
                DisclosureGroup("Technical Details") { Text(reason).font(.caption.monospaced()).textSelection(.enabled) }
                    .disclosureGroupStyle(TaskDisclosureStyle(minimumHeight: 22)).padding(.leading, 36)
            }
        }
    }
    private var title: some View {
        WorkspaceCategoryTitle(id: area.id, title: area.label, fallbackSymbol: "slider.horizontal.3").padding(.vertical, 6)
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
        case "homebrew_installation_requires_interaction": "Install Homebrew outside Macseed, then Refresh Preview. Macseed will not install it during Preview."
        case "homebrew_unavailable": "Make the existing Homebrew installation usable, then Refresh Preview."
        case "vscode_cli_required", "vscode_cli_unavailable": "Make the Visual Studio Code command-line tool available, then Refresh Preview."
        case "vscode_cli_ambiguous": "Resolve the multiple Visual Studio Code installations, then Refresh Preview."
        case "git_required", "git_unavailable": "Make Git available, then Refresh Preview."
        case "mas_required", "mas_unavailable": "Make the App Store command-line tool available, then Refresh Preview."
        case "internet_required": "Connect this Mac to the internet, then Refresh Preview."
        case "command_line_tools_required": "Install the macOS Command Line Tools outside Macseed, then Refresh Preview."
        case "authorization_required", "cask_authorization_required": "Selected work requires external authorization. Resolve it outside this Preview, then Refresh Preview."
        case "preview_observation_failed": "Current state could not be inspected reliably. Resolve the inspection issue, then Refresh Preview."
        default:
            switch condition.status {
            case "safely_satisfiable": "Core can satisfy this condition later using its existing Rebuild behavior. Preview makes no changes."
            case "unsupported": "This selected requirement is not supported by the current application execution path."
            default: "Resolve this requirement outside Macseed, then Refresh Preview to inspect the current state."
            }
        }
    }
}

struct RestoreView: View {
    @ObservedObject var model: RestoreModel
    @ObservedObject var runtime: CoreRuntime
    var categoryExpansion: Binding<Bool>? = nil
    var showsRebuildActions = true
    var showsPreviewActions = true
    var showsSelectionActions = true
    var showsPreparationActions = true
    var showsResultActions = true
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            switch model.state {
            case .choose:
                WorkspacePrimaryActionCard(title: "Choose a Saved Environment", symbol: ProductTask.restore.symbol, tint: WorkspaceIdentity.tint(.restore),
                    message: "Choose a captured environment to inspect a read-only Preview before rebuilding this Mac.",
                    notice: "Nothing changes until you explicitly choose Rebuild.") {
                    Button("Choose Saved Environment…", action: chooseBundle).buttonStyle(.borderedProminent).disabled(runtime.isActive)
                }
            case .inspecting, .preparing:
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .center, spacing: 16) {
                        ProgressView().controlSize(.large)
                            .frame(width: 40, height: 40).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Preparing Restore Preview").font(.title2.weight(.bold))
                                .accessibilityAddTraits(.isHeader)
                            Text(runtime.stopping ? "Stopping Preview…" : "Inspecting the selected environment and checking prerequisites…")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                    Label("Read-only inspection — no changes will be made to this Mac.", systemImage: "checkmark.shield")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
                if showsPreparationActions { RestorePreparationActions(stopping: runtime.stopping, cancel: { model.cancel() }) }
            case .review, .preview, .confirming:
                if let source = model.source {
                    HStack {
                        Label(source.lastPathComponent, systemImage: "shippingbox").font(.headline)
                        Spacer()
                        Button("Change…", action: chooseBundle).disabled(model.busy || runtime.isActive)
                    }
                }
                if model.inspection?.secureComponent == true {
                    Label("Secure Transfer is not available in this build.", systemImage: "lock.shield")
                    Text("This saved environment contains encrypted identity material. Private SSH identities will not be restored; ordinary SSH Configuration remains separate.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if model.state == .review {
                    HStack {
                        Text("Choose what to restore").font(.headline)
                        Spacer()
                        Button(model.bulkState.bulkActionTitle) { model.toggleAll() }.buttonStyle(.plain).foregroundStyle(.secondary).disabled(!model.areas.contains(where: \.selectable))
                    }
                    let includedAreas = RestorePresentationSection.includedAreas(model.areas)
                    ForEach(RestorePresentationSection.visible(model.groups, inventory: includedAreas)) { section in
                        WorkspaceSectionHeader(title: section.id)
                        VStack(spacing: 0) {
                            if let macOS = section.groups.first(where: { $0.id == "macOS Settings" }), includedAreas.contains(where: { macOS.domains.contains($0.id) }) {
                                RestoreMacOSSelectionView(model: model, group: macOS, expansion: categoryExpansion, childExpansion: categoryExpansion)
                                if section.areas(in: includedAreas).contains(where: { !macOS.domains.contains($0.id) }) { Divider() }
                            }
                            let areas = section.areas(in: includedAreas).filter { area in
                                !section.groups.contains { $0.id == "macOS Settings" && $0.domains.contains(area.id) }
                            }
                            ForEach(areas) { area in
                                RestoreAreaSelectionView(model: model, area: area, expansion: categoryExpansion)
                                if area.id != areas.last?.id { Divider() }
                            }
                        }.modifier(WorkspaceCardSurface())
                    }
                    if showsSelectionActions {
                        RestoreSelectionActions(status: model.selectionSummary, canPreview: model.canPreview, preview: { model.refreshPreview() }, reviewModel: model)
                    }
                } else if let prepared = model.preparation, let preview = model.preview {
                    let tasks = RestoreTaskPresentation(preview: preview, plan: prepared)
                    let needsAttention = !model.ready || tasks.domains.contains { [.attention, .unverified, .partial].contains($0.state) }
                    RestorePreviewContent(
                        title: needsAttention ? "Needs Attention" : prepared.hasPlannedChanges ? "Ready to Rebuild" : "Everything already matches",
                        message: preview.summary, state: needsAttention ? .attention : prepared.hasExecutableChanges ? .planned : .matching,
                        domains: tasks.domains, counters: tasks.counters,
                        alreadyMatches: !prepared.hasPlannedChanges && prepared.plan.allSatisfy { $0.disposition == "satisfied" },
                        prerequisites: RestorePrerequisiteSummaryPresentation(conditions: prepared.readiness.conditions, ready: prepared.readiness.ready, hasInstallerPreparations: !model.installerPreparationRows.isEmpty),
                        areas: model.areas,
                        settingsCategories: RestoreSettingsPresentation.children(tasks.domains, categories: preview.categories),
                        itemTitles: RestoreSettingsPresentation.titles(prepared.plan),
                        categoryExpansion: categoryExpansion,
                        showsActions: showsPreviewActions, needsRefresh: model.previewNeedsRefresh, retryMessage: model.prerequisiteRetryMessage, retrying: model.retryingPrerequisites,
                        checkAgain: { Task { await model.checkPrerequisites() } },
                        back: { model.back() }, refresh: { model.refreshPreview() }, rebuild: { model.requestRebuild() }, canRebuild: model.canRebuild)
                }
            case .rebuilding:
                if let preview = model.executionPreview, let plan = model.executionPlan {
                    let tasks = RestoreTaskPresentation(preview: preview, plan: plan, events: model.categoryPresentationEvents, executing: true, operationProgress: true)
                    RestoreRebuildProgressContent(tasks: tasks, activity: model.activity,
                        stopping: runtime.stopping, gracefulWaiting: runtime.gracefulStopState == .accepted)
                }
                if let message = runtime.gracefulStopMessage { Text(message).font(.callout).foregroundStyle(.secondary) }
                if showsRebuildActions {
                    RestoreRebuildActions(stopping: runtime.stopping, stop: { model.requestStop() }, force: { model.requestForceStop() }, gracefulWaiting: runtime.gracefulStopRequested, logRuntime: runtime)
                }
            case .result:
                if let result = model.executionResult {
                    RestoreResultContent(result: result,
                        showsActions: showsResultActions,
                        tasks: model.executionPreview.flatMap { preview in model.executionPlan.map { plan in
                            RestoreTaskPresentation(preview: preview, plan: plan, events: model.categoryPresentationEvents,
                                result: result, executing: true, operationProgress: true)
                        } },
                        refresh: { model.checkCurrentState() }, done: { model.finish() }, logRuntime: runtime)
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
            if !runtime.isActive && !model.authorizingMAS {
                MASRecoveryView(remainingIDs: model.masRecoveryRemainingIDs, appNames: model.masRecoveryNames)
            }
            if model.state != .rebuilding && model.state != .result && model.state != .inspecting && model.state != .preparing {
                Text("Restore Preview is read-only. No packages, settings, repositories or SSH identities are changed.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .modifier(OperationLogPresenter(runtime: runtime))
        .sheet(isPresented: Binding(get: { model.installerConsent }, set: { if !$0 { model.cancelInstallerPreparation() } })) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Prepare installers?").font(.title2)
                Text("Macseed will download and inspect the following installers to determine their application payloads. Installer scripts will not run and no applications will be installed. Rebuild requires separate confirmation.")
                ForEach(model.installerPreparationRows, id: \.itemID) { row in Text(row.displayName ?? row.itemID) }
                HStack {
                    Button("Cancel", role: .cancel) { model.cancelInstallerPreparation() }
                    Button("Download and Inspect") { model.confirmInstallerPreparation() }.buttonStyle(.borderedProminent)
                }
            }.padding(24).frame(width: 460).interactiveDismissDisabled()
        }
        .sheet(isPresented: Binding(get: { model.state == .confirming }, set: { if !$0 { model.cancelRebuildConfirmation() } })) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Rebuild this Mac?").font(.title2)
                Text("Macseed will apply the changes shown in this Preview. Items that already match will not be changed.")
                if model.preparation?.plan.contains(where: { $0.authorizationRequired == true }) == true {
                    Text("Some changes may require administrator authorization.")
                        .foregroundStyle(.secondary)
                }
                if model.preparation?.plan.contains(where: { $0.domain == "app-store" && $0.disposition == "planned" }) == true {
                    Text("This build stops App Store work after the first new installation for a safety review. Remaining App Store apps will not be installed automatically.")
                        .foregroundStyle(.orange)
                }
                if model.preparation?.warningCount ?? 0 > 0 {
                    Text("This Preview includes attention conditions. Review them before continuing.").foregroundStyle(.orange)
                }
                if model.authorizingMAS {
                    ProgressView("Waiting for macOS App Store helper approval…")
                    Text("Complete the macOS confirmation or allow Macseed in System Settings → General → Login Items & Extensions. Rebuild continues automatically after approval. Cancel stops this request before installation.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Cancel", role: .cancel) { model.cancelRebuildConfirmation() }
                    Button("Rebuild") { model.confirmRebuild() }.buttonStyle(.borderedProminent).disabled(model.authorizingMAS)
                }
            }.padding(24).frame(width: 420).interactiveDismissDisabled()
        }
        .sheet(isPresented: Binding(get: { model.stopConfirmation }, set: { if !$0 { model.dismissStopConfirmation() } })) {
            VStack(alignment: .leading, spacing: 16) {
                Text(model.forceStopConfirmation ? "Force Stop Rebuild?" : "Stop rebuilding?").font(.title2).accessibilityAddTraits(.isHeader)
                Text(model.forceStopConfirmation ? "Force Stop will interrupt the current operation. This may leave some changes incomplete and require additional steps before rebuilding again." : "Rebuild is still in progress. Stopping it may leave some changes already applied to this Mac. A fresh Restore Preview will be required before another Rebuild.")
                HStack {
                    Button(model.forceStopConfirmation ? "Continue Waiting" : "Continue Rebuild") { model.dismissStopConfirmation() }.keyboardShortcut(.defaultAction)
                    Button(model.forceStopConfirmation ? "Force Stop" : "Stop Rebuild", role: model.forceStopConfirmation ? .destructive : nil) { model.confirmStop() }
                        .tint(model.forceStopConfirmation ? .red : .accentColor)
                        .foregroundStyle(model.forceStopConfirmation ? Color.red : Color.primary)
                }
            }.padding(24).frame(width: 420).interactiveDismissDisabled()
                .onExitCommand { model.dismissStopConfirmation() }
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
    var settingsCategories: [TaskDomainPresentation] = []
    var itemTitles: [String: String] = [:]
    var categoryExpansion: Binding<Bool>? = nil
    var showsActions = true
    var needsRefresh = false
    var retryMessage: String? = nil
    var retrying = false
    var checkAgain: (() -> Void)? = nil
    var back: (() -> Void)? = nil
    var refresh: (() -> Void)? = nil
    var rebuild: (() -> Void)? = nil
    var canRebuild = false
    var showsFixIssues: Bool { prerequisites.canFixIssues }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(title).font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
            if needsRefresh {
                Label("Selection changed. Refresh Preview to update counts and prerequisites. The current Preview shows the previous selection.", systemImage: "arrow.clockwise")
                    .font(.callout).foregroundStyle(.secondary)
            }
            RestorePreviewMetrics(domains: domains)
            if alreadyMatches { Text("Selected requirements already match this Mac.") }
            RestorePrerequisiteSummaryView(summary: prerequisites, areas: areas)
            if showsFixIssues {
                Button(retrying ? "Checking…" : "Fix Issues…") { checkAgain?() }.disabled(checkAgain == nil || needsRefresh || retrying)
                Text("Macseed will guide you through available fixes. Your approval may be required. No applications will be installed yet.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let retryMessage { Text(retryMessage).font(.callout).foregroundStyle(.secondary) }
            TaskDomainList(domains: domains.map { domain in
                var previewDomain = domain
                previewDomain.previewOnly = true
                return previewDomain
            }, restoreSettingsPreview: true, settingsCategories: settingsCategories, itemTitles: itemTitles,
                expansion: categoryExpansion.map { binding in Binding(get: { binding.wrappedValue ? Set(domains.map(\.id)) : [] }, set: { binding.wrappedValue = !$0.isEmpty }) },
                settingsExpansion: categoryExpansion)
            if showsActions {
                RestorePreviewActions(back: back, refresh: refresh, rebuild: rebuild, canRebuild: canRebuild)
            }
        }
    }
}

struct RestorePreparationActions: View {
    let stopping: Bool
    let cancel: () -> Void
    var body: some View {
        HStack {
            Button("Cancel", role: .cancel, action: cancel).disabled(stopping)
            Spacer()
        }
    }
}

struct RestoreSelectionActions: View {
    let status: String
    let canPreview: Bool
    let preview: () -> Void
    var reviewModel: RestoreModel? = nil
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                if let reviewModel { RestoreReviewCancelButton(model: reviewModel) }
                Text(status).font(.callout).foregroundStyle(.secondary)
                Spacer(); action
            }
            VStack(alignment: .leading, spacing: 8) {
                if let reviewModel { RestoreReviewCancelButton(model: reviewModel) }
                Text(status).font(.callout).foregroundStyle(.secondary); action
            }
        }
    }
    private var action: some View {
        Button("Preview Restore", action: preview).buttonStyle(.borderedProminent).disabled(!canPreview)
    }
}

struct RestoreReviewCancelButton: View {
    @ObservedObject var model: RestoreModel
    var body: some View {
        Button("Cancel", action: model.requestReviewCancellation).disabled(!model.canCancelReview)
            .alert("Discard Current Restore Selection?", isPresented: Binding(
                get: { model.reviewCancelConfirmation },
                set: { if !$0 { model.keepReviewSelection() } })) {
                    Button("Keep Selection", role: .cancel, action: model.keepReviewSelection).keyboardShortcut(.defaultAction)
                    Button("Discard and Cancel", role: .destructive, action: model.confirmReviewCancellation)
                        .disabled(!model.canCancelReview)
                } message: {
                    Text("The current Restore selection and any prepared Preview will be discarded. The saved environment file will not be changed.")
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
            Spacer()
            Button("Rebuild") { rebuild?() }.buttonStyle(.borderedProminent).disabled(!canRebuild || rebuild == nil)
        }
    }
}

struct RestoreRebuildActions: View {
    var stopping = false
    var stop: (() -> Void)? = nil
    var force: (() -> Void)? = nil
    var gracefulWaiting = false
    var logRuntime: CoreRuntime? = nil
    var body: some View {
        HStack {
            Spacer()
            Button("Stop Rebuild", role: .cancel) { stop?() }.disabled(stopping || gracefulWaiting || stop == nil)
            Button("Force Stop", role: .destructive) { force?() }.tint(.red).foregroundStyle(.red).disabled(stopping || force == nil)
        }
    }
}

// Execution content deliberately has no Preview summary or readiness inventory.
struct RestoreRebuildProgressContent: View {
    let tasks: RestoreTaskPresentation
    let activity: String
    let stopping: Bool
    var gracefulWaiting = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Rebuilding this Mac").font(.title.weight(.bold)).accessibilityAddTraits(.isHeader)
            HStack(spacing: 12) {
                ProgressView()
                Text(stopping ? "Force Stop Requested. Completed changes may remain." : gracefulWaiting ? "Stopping Rebuild…" : activity).foregroundStyle(.secondary)
            }
            RestoreExecutionCategories(domains: tasks.domains)
        }
    }
}

struct RestoreExecutionCategories: View {
    let domains: [TaskDomainPresentation]
    var showsWarnings = true
    var resultStatuses = false
    @RestoreViewState private var expandedCategories: Set<String> = []
    static func toggledCategories(_ expanded: Set<String>, ids: Set<String>) -> Set<String> {
        ids.isSubset(of: expanded) ? [] : ids
    }
    // Unknown rows retain their original grouping and position; only known runs are reordered.
    static func sections(_ domains: [TaskDomainPresentation]) -> [(title: String?, rows: [TaskDomainPresentation])] {
        let known = Set(WorkspaceCategoryStyle.groups.flatMap { $0.1 })
        var result: [(title: String?, rows: [TaskDomainPresentation])] = []
        var pending: [TaskDomainPresentation] = []
        func flush() {
            result.append(contentsOf: WorkspaceCategoryStyle.sections(pending).map { (Optional($0.title), $0.rows) })
            pending = []
        }
        for domain in domains {
            if known.contains(domain.id) { pending.append(domain) }
            else { flush(); result.append((nil, [domain])) }
        }
        flush()
        return result
    }
    private func categoryTitle(_ domain: TaskDomainPresentation) -> some View {
        WorkspaceCategoryTitle(id: domain.id, title: domain.title, fallbackSymbol: domain.symbol)
    }
    private func categoryStatus(_ domain: TaskDomainPresentation) -> some View {
        Group {
            if resultStatuses { RestoreResultStatusLabel(state: domain.executionStatus) }
            else { TaskStatusLabel(state: domain.executionStatus, title: domain.executionStatusTitle) }
        }.frame(width: TaskRowLayout.statusWidth, alignment: .leading)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if resultStatuses && !domains.isEmpty {
                HStack {
                    Text("Details by Category").font(.headline).accessibilityAddTraits(.isHeader)
                    Spacer()
                    let ids = Set(domains.map(\.id))
                    Button(ids.isSubset(of: expandedCategories) ? "Collapse All" : "Expand All") {
                        expandedCategories = Self.toggledCategories(expandedCategories, ids: ids)
                    }.buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            if resultStatuses {
                HStack(spacing: 12) {
                    ForEach(RestoreFinalDomain.outcomes, id: \.self) { label in
                        Label(label == "Success" ? "Successful" : label, systemImage: "circle.fill")
                            .font(.caption).foregroundStyle(RestoreFinalDomain.tone(label))
                    }
                }
            }
            ForEach(Array(Self.sections(domains).enumerated()), id: \.offset) { _, section in
                if let title = section.title { WorkspaceSectionHeader(title: title) }
                VStack(spacing: 0) {
                    ForEach(section.rows) { domain in
                        if resultStatuses {
                            RestoreFinalDomain(domain: domain, expansion: Binding(
                                get: { expandedCategories.contains(domain.id) },
                                set: { value in
                                    if value { expandedCategories.insert(domain.id) } else { expandedCategories.remove(domain.id) }
                                }))
                        } else {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 12) {
                                categoryTitle(domain)
                                Spacer()
                                categoryStatus(domain)
                            }
                            VStack(alignment: .leading, spacing: 8) {
                                categoryTitle(domain)
                                categoryStatus(domain).frame(maxWidth: .infinity, alignment: .trailing)
                            }
                        }.padding(.vertical, 6).frame(minHeight: 48).padding(.horizontal, 16)
                        }
                        if domain.id != section.rows.last?.id { Divider() }
                    }
                }.modifier(WorkspaceCardSurface())
            }
        }

    }
}

// Result-only columns reserve space even when count or disclosure is absent.
struct RestoreResultColumns: Layout {
    // Preserve the previous 36pt disclosure indentation plus 16pt child inset.
    static func titleInset(depth: Int, item: Bool = false) -> CGFloat {
        CGFloat(depth) * (36 + 16) + (item ? 36 : 0)
    }
    static func widths(_ width: CGFloat) -> [CGFloat] {
        let available = max(0, width - 36 - 46 - 12)
        let status = min(TaskRowLayout.statusWidth, available * 0.55)
        return [available - status, status, 46, 12]
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        let columns = Self.widths(width)
        return CGSize(width: width, height: zip(subviews, columns).map {
            $0.sizeThatFits(.init(width: $1, height: nil)).height
        }.max() ?? 0)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for (view, width) in zip(subviews, Self.widths(bounds.width)) {
            view.place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading,
                proposal: .init(width: width, height: nil))
            x += width + 12
        }
    }
}

// Existing category surfaces and density, with Result-only shared columns.
struct RestoreFinalDomain: View {
    let domain: TaskDomainPresentation
    var expansion: Binding<Bool>? = nil
    var depth = 0
    @RestoreViewState private var expanded = false
    static let outcomes = ["Success", "Needs Attention", "Skipped"]
    // One terminal item, one group. Operation and Verification evidence stay independent.
    static func group(_ item: TaskItemPresentation) -> String? {
        item.resultGroup
    }

    static func counts(_ domain: TaskDomainPresentation) -> [(String, Int)] {
        guard domain.resultTitle != "Not Run" else { return [] }
        return outcomes.compactMap { label in
            let count = domain.items.filter { group($0) == label }.count
            return count > 0 ? (label, count) : nil
        }
    }
    static func visibleLabels(_ item: TaskItemPresentation, notRun: Bool = false) -> [String] {
        notRun && item.resultGroup == nil ? ["Not Run"] : [item.resultTitle]
    }
    static func showsItemDetails(_ item: TaskItemPresentation) -> Bool {
        item.hasResultProblemDetails
    }
    static func finalStatus(_ domain: TaskDomainPresentation) -> TaskRowState {
        switch domain.resultTitle {
        case "Needs Attention": .attention
        case "Already Matches": .matching
        case "Completed": .completed
        case "Not Run": .notRun
        default: .unverified
        }
    }
    static func tone(_ label: String) -> Color {
        switch label {
        case "Success", "Applied", "Already Matches", "Verified": RestoreStatusTone.success.color
        case "Needs Attention", "Failed", "Mismatch", "Unverified", "Unsupported", "Unresolved": .orange
        default: .secondary
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if let expansion { expansion.wrappedValue.toggle() } else { expanded.toggle() }
            } label: {
                RestoreResultColumns {
                    title.padding(.leading, RestoreResultColumns.titleInset(depth: depth))
                    RestoreResultStatusLabel(state: Self.finalStatus(domain), title: domain.resultTitle)
                    counts
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees((expansion?.wrappedValue ?? expanded) ? 90 : 0))
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .frame(width: 12).accessibilityHidden(true)
                }.padding(.vertical, 6).frame(minHeight: 48).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityValue((expansion?.wrappedValue ?? expanded) ? "Expanded" : "Collapsed")
            if expansion?.wrappedValue ?? expanded {
                VStack(alignment: .leading, spacing: 0) {
                    if !domain.resultChildren.isEmpty {
                        ForEach(domain.resultChildren) { child in RestoreFinalDomain(domain: child, depth: depth + 1) }
                    } else {
                        ForEach(domain.resultVisibleItems) { item in
                            RestoreResultItemRow(item: item, notRun: domain.executionStatus == .notRun, depth: depth)
                        }
                    }
                    if domain.resultCategoryIssue {
                        Text(domain.resultCategoryExplanation)
                            .font(.caption).foregroundStyle(.orange).padding(.vertical, 4)
                    }
                }.padding(.vertical, 4)
            }
        }.padding(.horizontal, depth == 0 ? 16 : 0)
    }
    private var title: some View {
        WorkspaceCategoryTitle(id: domain.id, title: domain.title, fallbackSymbol: domain.symbol)
    }
    private var counts: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Self.counts(domain), id: \.0) { label, count in
                Text(String(count)).font(.caption2.weight(.semibold)).monospacedDigit()
                    .padding(.horizontal, 8).frame(minWidth: 46, minHeight: 23)
                    .foregroundStyle(Self.tone(label)).background(Self.tone(label).opacity(0.12), in: Capsule())
                    .help(label).accessibilityLabel(label).accessibilityValue(String(count))
            }
        }
    }
}

struct RestoreResultItemRow: View {
    let item: TaskItemPresentation
    let notRun: Bool
    let depth: Int
    @RestoreViewState private var expanded = false
    private var hasTechnicalDetails: Bool {
        RestoreFinalDomain.showsItemDetails(item) && (item.resultTechnicalDetails != nil || item.item.reason != nil)
    }
    var body: some View {
        RestoreResultColumns {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.item.title)
                if RestoreFinalDomain.showsItemDetails(item), let explanation = item.resultExplanation {
                    Text(explanation).font(.caption).foregroundStyle(.secondary)
                }
                if hasTechnicalDetails {
                    Button("Technical Details") { expanded.toggle() }
                        .buttonStyle(.plain).font(.caption)
                        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                    if expanded {
                        Text([item.item.reason, item.resultTechnicalDetails].compactMap { $0 }.joined(separator: "\n"))
                            .font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
            }.padding(.leading, RestoreResultColumns.titleInset(depth: depth, item: true))
                .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(RestoreFinalDomain.visibleLabels(item, notRun: notRun), id: \.self) { label in
                    HStack(spacing: 7) {
                        Image(systemName: label == "Verified" ? "checkmark.shield" : label == "Failed" || label == "Mismatch" ? "xmark.circle" : ["Unverified", "Outcome Unknown"].contains(label) ? "questionmark.circle" : "circle.fill")
                            .frame(width: TaskRowLayout.iconWidth).accessibilityHidden(true)
                        Text(label)
                    }.font(.callout).foregroundStyle(item.resultGroup == "Success" ? RestoreStatusTone.success.color : item.resultGroup == "Needs Attention" ? .orange : .secondary)
                        .accessibilityElement(children: .combine)
                }
            }
            Color.clear.frame(height: 0)
            if hasTechnicalDetails {
                Button { expanded.toggle() } label: {
                    Image(systemName: "chevron.right").rotationEffect(.degrees(expanded ? 90 : 0))
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(width: 12)
                }.buttonStyle(.plain).accessibilityLabel("Technical Details")
                    .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            } else { Color.clear.frame(height: 0) }
        }.padding(.vertical, 7).frame(minHeight: 28)
    }
}

// Result-only styling: absence of Verification remains distinct from an observed problem.
struct RestoreResultStatusLabel: View {
    let state: TaskRowState
    var title: String? = nil
    var symbol: String { title == "Partial" ? "circle.lefthalf.filled" : state == .unverified ? "questionmark.circle" : state.symbol }
    var tone: RestoreStatusTone { state == .unverified ? .neutral : state.tone }
    var body: some View {
        if state == .unverified {
            HStack(spacing: 7) {
                Image(systemName: symbol).frame(width: TaskRowLayout.iconWidth).accessibilityHidden(true)
                Text(title ?? state.rawValue)
            }.font(.callout).foregroundStyle(tone.color)
                .accessibilityElement(children: .ignore).accessibilityLabel(title ?? state.rawValue)
        } else { TaskStatusLabel(state: state, title: title) }
    }
}

struct RestoreVerificationResult: View {
    let outcome: RestoreExecutionPresentation.Outcome
    let payload: [String: CoreJSON]?
    var domains: [TaskDomainPresentation]? = nil
    static func resultTone(_ result: String) -> RestoreStatusTone {
        switch result {
        case "OK": .success
        case "Failed": .error
        case "Stopped": .neutral
        default: .warning
        }
    }
    static func countTone(_ count: Int?, problem: RestoreStatusTone) -> RestoreStatusTone {
        (count ?? 0) > 0 ? problem : .neutral
    }

    static func showsCount(_ count: Int?) -> Bool { count.map { $0 > 0 } ?? false }

    var body: some View {
        let summary = RestoreVerificationSummary(payload: payload)
        VStack(alignment: .leading, spacing: 8) {
            Label(summary.title, systemImage: "checkmark.shield").font(.headline)
            if let domains {
                let rows = RestoreResultSummary(domains: domains)
                if !rows.cards.isEmpty {
                    WorkspaceThreeMetrics {
                        ForEach(rows.cards) { card in
                            WorkspaceMetricCard(title: card.id == "Success" ? "Successful" : card.id,
                                value: String(card.count), symbol: card.id == "Success" ? "checkmark.circle" : card.id == "Skipped" ? "minus.circle" : "exclamationmark.triangle",
                                tint: RestoreFinalDomain.tone(card.id), explanation: card.explanation)
                        }
                    }
                }
                if rows.uncounted > 0 {
                    Text("Counts cover confirmed outcomes only. Some plan rows were not run or have no established outcome.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            } else {
                Text("Plan-row counts are unavailable.").font(.callout).foregroundStyle(.secondary)
            }
            if let count = summary.unresolved, count > 0, !(domains?.contains { $0.items.contains { $0.resultLabels.contains("Unresolved") } } ?? false) {
                Text("Some selected scope remains unresolved. Review the category details or View Log.")
                    .font(.callout).foregroundStyle(.orange)
            }

        }
    }
}

struct RestoreResultContent: View {
    let result: RestoreExecutionPresentation
    var showsActions = true
    var tasks: RestoreTaskPresentation? = nil
    let refresh: () -> Void
    let done: () -> Void
    var logRuntime: CoreRuntime? = nil
    private var hasOperationLog: Bool {
        guard let logRuntime, ![OperationLogStatus.unavailable, .inactive].contains(logRuntime.operationLogStatus),
              let reference = logRuntime.operationLogReference(matching: result.operationID) else { return false }
        return OperationLogVisibility.restore(.result, active: logRuntime.isActive, reference: reference,
            terminal: logRuntime.termination != nil && logRuntime.operationID == result.operationID)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 10) {
                Image(systemName: result.outcome == .clean ? "checkmark.circle" : [.stoppedBeforeMutation, .stoppedAfterMutation].contains(result.outcome) ? "stop.circle" : "exclamationmark.triangle")
                    .foregroundStyle(result.outcome == .clean ? RestoreStatusTone.success.color : .orange).accessibilityHidden(true)
                Text(result.title)
            }.font(.title.weight(.bold)).accessibilityAddTraits(.isHeader)
            Text(result.message).foregroundStyle(.secondary)
            ForEach(result.globalProblemMessages(knownDomains: Set(tasks?.domains.flatMap { $0.items.compactMap(\.sourceDomain) } ?? [])), id: \.self) { message in
                Text(message).font(.callout).foregroundStyle(.orange)
            }
            if let notice = result.stopNotice {
                Label(notice, systemImage: "stop.circle").font(.callout.weight(.semibold))
                if let explanation = result.stopRequestExplanation {
                    Text(explanation).font(.callout).foregroundStyle(.secondary)
                }
            }
            RestoreVerificationResult(outcome: result.outcome, payload: result.structuredEvidence, domains: tasks?.domains)
            if let tasks { RestoreExecutionCategories(domains: tasks.domains, showsWarnings: false, resultStatuses: true) }
            if !hasOperationLog && !result.technicalDetails.isEmpty {
                DisclosureGroup("Technical Details") {
                    ForEach(Array(result.compactTechnicalDetails.enumerated()), id: \.offset) { _, text in
                        Text(text).font(.caption.monospaced()).textSelection(.enabled)
                    }
                    Button("Copy Diagnostic Details") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(result.diagnosticReport, forType: .string)
                    }
                    .padding(.top, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }.disclosureGroupStyle(HeaderDisclosureStyle())
            }
            if showsActions { RestoreResultActions(result: result, refresh: refresh, done: done, logRuntime: logRuntime) }
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
        WorkspaceThreeMetrics { cards(counts) }
    }
    @ViewBuilder private func cards(_ counts: (changes: Int, attention: Int, matching: Int)) -> some View {
        Self.metric("Already Match", count: counts.matching, symbol: "checkmark.circle", color: RestoreStatusTone.success.color)
        Self.metric("Changes Planned", count: counts.changes, symbol: "arrow.down.circle", color: .blue)
        Self.metric("Need Attention", count: counts.attention, symbol: "exclamationmark.triangle", color: counts.attention > 0 ? RestoreStatusTone.warning.color : .secondary)
    }
    static func metric(_ title: String, count: Int?, symbol: String, color: Color, value: String? = nil) -> some View {
        WorkspaceMetricCard(title: title, value: value ?? count.map(String.init) ?? "—", symbol: symbol, tint: color)
            .accessibilityValue(value ?? count.map(String.init) ?? "Not reported")
    }
}

// Called only from the user's prerequisite retry, never from Prepare.
enum RestoreAutomationPermission {
    enum Outcome: Equatable {
        case available, denied, unavailable
        var message: String? {
            switch self {
            case .available: nil
            case .denied: "Allow Macseed → System Events in System Settings → Privacy & Security → Automation, then Refresh Preview. Access may be restricted by your administrator."
            case .unavailable: "System Events access is unavailable. Resolve the system restriction, then Refresh Preview."
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

struct RestoreResultActions: View {
    let result: RestoreExecutionPresentation
    let refresh: () -> Void
    let done: () -> Void
    var logRuntime: CoreRuntime? = nil
    var body: some View {
        HStack {
            Button("Done", action: done).buttonStyle(.borderedProminent)
            if result.outcome != .clean { Button("Refresh Preview", action: refresh) }
            if let logRuntime,
               let reference = logRuntime.operationLogReference(matching: result.operationID),
               OperationLogVisibility.restore(.result, active: logRuntime.isActive, reference: reference, terminal: logRuntime.termination != nil && logRuntime.operationID == result.operationID) {
                OperationLogButton(runtime: logRuntime, reference: reference)
            }
        }
    }
}

// Only names and nesting are projected here. Plan rows, predicates and task states are unchanged.
enum RestoreSettingsPresentation {
    static func children(_ domains: [TaskDomainPresentation], categories: [DisplayCategory]) -> [TaskDomainPresentation] {
        let items = domains.first { $0.id == "macOS Settings" || $0.id == "macos-settings" }?.items ?? []
        return CaptureMacOSSettingsGroup.domainIDs.compactMap { id in
            guard let category = categories.first(where: { $0.id == id }) else { return nil }
            let ids = Set(category.items.map(\.id))
            let members = items.filter { ids.contains($0.id) }
            return members.isEmpty ? nil : TaskDomainPresentation(id: id, title: category.title,
                symbol: WorkspaceCategoryStyle.symbol(id), items: members, previewOnly: true)
        }
    }
    static func titles(_ plan: [CoreRestorePreparation.Row]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: plan.enumerated().compactMap { index, row in
            guard row.action != "restart_process", let title = WorkspaceSettingLabels.title(domain: row.domain, identity: row.itemID) else { return nil }
            return ("restore-\(index)", title)
        })
    }
}

// Recovery lives in Restore, including after app restart without a selected Bundle.
struct MASRecoveryView: View {
    var remainingIDs: [String] = []
    var appNames: [String: String] = [:]
    @RestoreViewState private var downloadsClear = false
    @RestoreViewState private var consentIDs: [String] = []
    @RestoreViewState private var report: MASRecoveryReport?
    @RestoreViewState private var busy = false
    @RestoreViewState private var pending: String?
    var body: some View {
        DisclosureGroup("App Store Recovery") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Inspect an interrupted App Store operation. Recovery never restarts an installation automatically.")
                if let report {
                    Text(appNames[report.appStoreID] ?? ("App Store application " + report.appStoreID)).font(.headline)
                    Text(MASRecoveryPresentation.child(report.childState))
                    Text(MASRecoveryPresentation.installation(report.installation))
                    Text(MASRecoveryPresentation.guidance(report)).foregroundStyle(report.retryAllowed ? Color.secondary : .orange)
                    DisclosureGroup("Technical details") {
                        Text("Operation: " + report.operationID).textSelection(.enabled)
                        Text("Journal: " + report.journalState)
                        Text(report.reason).textSelection(.enabled)
                        Text("Receipt: " + report.receipt)
                        Text("Observation: " + report.completeness)
                        Text("Protected evidence: " + report.evidence)
                    }.font(.caption)
                    if report.canAcceptRisk && !report.retryAllowed {
                        Toggle("I checked App Store downloads; no related download or installation is active", isOn: $downloadsClear)
                        Button("Allow One Retry…") { consentIDs = [report.appStoreID]; pending = "acceptRetry" }.disabled(!downloadsClear)
                        let remaining = remainingIDs.filter { $0 != report.appStoreID }
                        if !remaining.isEmpty {
                            Text("Selected remaining apps: " + remaining.map { appNames[$0] ?? $0 }.joined(separator: ", "))
                            Button("Allow Selected Remaining Apps…") { consentIDs = remaining; pending = "acceptRemaining" }.disabled(!downloadsClear)
                        }
                    }
                    if report.retryAllowed {
                        Text("Approved App Store IDs: " + report.allowedAppStoreIDs.joined(separator: ", "))
                        Text("Refresh Preview and select only these approved apps before Rebuild.")
                    }
                    if report.reason == "helper_not_enabled_recovery_does_not_register" {
                        Button("Enable Helper for Recovery…") { pending = "enableRecovery" }
                    }
                    HStack {
                        Button("Check Installation") { pending = "verify" }
                        if report.canReconcileObservation { Button("Resolve Interrupted Read-only Check") { pending = "reconcileObservation" } }
                        if report.canReconcile { Button("Resolve Attempt Without Installation") { pending = "reconcile" } }
                        if report.canTerminate { Button("Cancel Owned Child…", role: .destructive) { pending = "terminate" } }
                        if report.canForceTerminate { Button("Force End Owned Child…", role: .destructive) { pending = "forceTerminate" } }
                    }.disabled(report.operationID.isEmpty || report.retryAllowed)
                }
                HStack {
                    Button("Refresh Recovery Status") { perform("status") }
                    if busy { ProgressView().controlSize(.small) }
                }
            }.disabled(busy).padding(.vertical, 8)
        }
        .confirmationDialog("Confirm App Store recovery action", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
            if let action = pending {
                Button(action == "acceptRetry" ? "Accept Risk for One Retry" : action == "acceptRemaining" ? "Accept Risk for Listed Apps" : action == "terminate" ? "Request Cancellation" : action == "forceTerminate" ? "Force End Installation Process" : action == "verify" ? "Check and Save Evidence" : action == "enableRecovery" ? "Request Native Approval" : "Record Review",
                       role: ["terminate", "forceTerminate"].contains(action) ? .destructive : nil) { pending = nil; perform(action) }
                Button("Cancel", role: .cancel) { pending = nil }
            }
        } message: {
            Text(pending == "acceptRetry" || pending == "acceptRemaining"
                ? "Apple may still complete background work from the interrupted attempt. Approve one attempt per listed app only: " + consentIDs.joined(separator: ", ") + ". No install starts now. Permission expires in ten minutes. A new uncertain result stops the sequence. The original history is preserved."
                : "Recovery does not restart installation. Cancellation targets only this attempt's verified process, never Apple services. Check Installation reads current state and saves evidence.")
        }
    }
    private func perform(_ action: String) {
        guard !busy else { return }; busy = true
        let id = action == "status" ? "" : (report?.operationID ?? "")
        Task {
            if action == "enableRecovery" {
                if let problem = await MASAuthorization.enableRecovery() {
                    var refused = MASRecoveryReport(); refused.reason = problem; report = refused
                } else { report = await MASAuthorization.recovery() }
            } else {
                report = await MASAuthorization.recovery(operationID: id, action: action, confirmed: action != "status",
                    reviewID: report?.reviewID ?? "", appStoreIDs: consentIDs, downloadsClear: downloadsClear)
                if action == "verify" || action == "status" { downloadsClear = false }
            }
            busy = false
        }
    }
}
