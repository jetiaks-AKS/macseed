import AppKit
import SwiftUI

// Capture, Restore Prepare and Status consume structured Core data.
struct ProductionWorkspace: View {
    @ObservedObject var runtime: CoreRuntime
    @SwiftUI.StateObject private var status: EnvironmentStatusModel
    @SwiftUI.StateObject private var capture: CaptureModel
    @SwiftUI.StateObject private var restore: RestoreModel
    @SwiftUI.StateObject private var navigation = ProductionNavigation()
    #if DEBUG
    @ObservedObject private var scenarios = RestoreDebugScenarios.shared
    private var syntheticRestore: Bool { scenarios.selected != .real }
    #else
    private var syntheticRestore: Bool { false }
    #endif
    private var busy: Bool { runtime.isActive || status.state == .running || capture.busy || restore.busy }
    init(runtime: CoreRuntime) {
        self.runtime = runtime
        _status = SwiftUI.StateObject(wrappedValue: EnvironmentStatusModel(runtime: runtime))
        _capture = SwiftUI.StateObject(wrappedValue: CaptureModel(runtime: runtime))
        _restore = SwiftUI.StateObject(wrappedValue: runtime === CoreRuntime.shared ? RestoreModel.shared : RestoreModel(runtime: runtime))
    }
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                List(selection: Binding<String?>(get: { navigation.task?.rawValue ?? "All Tasks" }, set: { value in
                    guard !busy, let value else { return }
                    navigation.task = ProductTask(rawValue: value)
                })) {
                    MacseedSidebarBrand()
                    Label { Text("All Tasks") } icon: { Image(systemName: "house").foregroundStyle(.blue) }.tag("All Tasks")
                    ForEach(ProductTask.allCases) { task in MacseedTaskLabel(task: task).tag(task.rawValue) }
                }
                .listStyle(.sidebar).scrollContentBackground(.hidden)
                Spacer(minLength: 0)
                Divider().padding(.horizontal, 12)
                SettingsLink { Label("Settings", systemImage: "gearshape") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).padding(16)
            }
            .modifier(InsetSidebarSurface())
            .disabled(busy)
            .navigationSplitViewColumnWidth(min: 200, ideal: 215)
        } detail: {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if let task = navigation.task {
                            Group {
                                WorkspaceHeader(title: task.rawValue, subtitle: task == .status ? "Compare your Mac with a saved environment." : task.subtitle, symbol: task.symbol)
                            }
                            if task == .status {
                                EnvironmentStatusView(model: status, runtime: runtime, showsActions: status.state != .result)
                            } else if task == .capture {
                                CaptureView(model: capture, runtime: runtime, showsActions: false)
                            } else {
                                #if DEBUG
                                if syntheticRestore { RestoreDebugScenarioView(scenario: scenarios.selected) }
                                else { RestoreView(model: restore, runtime: runtime, showsRebuildActions: false, showsPreviewActions: false, showsSelectionActions: false, showsPreparationActions: false, showsResultActions: false) }
                                #else
                                RestoreView(model: restore, runtime: runtime, showsRebuildActions: false, showsPreviewActions: false, showsSelectionActions: false, showsPreparationActions: false, showsResultActions: false)
                                #endif
                            }
                        } else {
                            TaskHome { task in if !busy { navigation.task = task } }
                                .disabled(busy)
                        }
                        if !syntheticRestore && runtime.isActive && runtime.operation == .capabilities {
                            ProgressView(runtime.stopping ? "Stopping…" : "Checking Macseed Core…")
                            Button("Cancel") { runtime.cancel() }.disabled(runtime.stopping)
                        } else if !syntheticRestore && runtime.operation == .capabilities, let error = runtime.error {
                            Label("Needs Attention", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                            Text(error.message)
                            Button("Check Again") { runtime.checkCapabilities() }
                        } else if !syntheticRestore && runtime.operation == .capabilities && runtime.state == .cancelled {
                            Text("Core check cancelled.")
                            Button("Check Again") { runtime.checkCapabilities() }
                        }
                    }
                    .modifier(WorkspaceContentGeometry())
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if navigation.task == .status && status.state == .result {
                    Divider()
                    EnvironmentStatusActions(model: status, runtime: runtime, reviewInRestore: reviewStatusInRestore, handoffBlocked: busy || syntheticRestore)
                        .modifier(WorkspaceFooterPadding())
                }
                if navigation.task == .capture && capture.state != .idle {
                    Divider()
                    CaptureActionsView(model: capture, runtime: runtime).modifier(WorkspaceFooterPadding())
                }
                if navigation.task == .restore && restore.showingAppStore {
                    Divider()
                    AppStoreRestoreActions(model: restore).modifier(WorkspaceFooterPadding())
                } else if navigation.task == .restore {
                    #if DEBUG
                    if syntheticRestore {
                        if scenarios.selected == .rebuilding { rebuildActionArea(synthetic: true) }
                    } else if restore.state == .rebuilding { rebuildActionArea(synthetic: false) }
                    else if restore.state == .result { resultActionArea }
                    else if restore.state == .inspecting || restore.state == .preparing { preparationActionArea }
                    else if restore.state == .review { selectionActionArea }
                    else if restore.state == .preview || restore.state == .confirming { previewActionArea }
                    #else
                    if restore.state == .rebuilding { rebuildActionArea(synthetic: false) }
                    else if restore.state == .result { resultActionArea }
                    else if restore.state == .inspecting || restore.state == .preparing { preparationActionArea }
                    else if restore.state == .review { selectionActionArea }
                    else if restore.state == .preview || restore.state == .confirming { previewActionArea }
                    #endif
                }
                Divider()
                HStack {
                    if let capabilities = runtime.capabilities {
                        Label("Ready · Macseed Core " + capabilities.productVersion, systemImage: "checkmark.circle")
                    } else { Text(runtime.operation == .environmentCompare ? "Macseed Core · Read-only comparison" : "Macseed") }
                    Spacer()
                }.font(.caption).foregroundStyle(.secondary).padding(12)
            }
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button {
                        if navigation.task == .capture && capture.state == .confirmation { capture.editSelection() }
                        else if navigation.task == .restore && restore.showingAppStore { restore.closeAppStore() }
                        else if navigation.task == .restore && restore.state == .preview { restore.back() }
                        else { navigation.task = nil }
                    } label: { Label("Back", systemImage: "chevron.backward") }
                        .disabled(navigation.task == nil || busy)
                        .keyboardShortcut("[", modifiers: .command)
                }
            }
        }
        .modifier(OperationLogPresenter(runtime: runtime))
        .alert("Replace Current Restore Session?", isPresented: Binding(
            get: { navigation.pendingRestoreBundle != nil },
            set: { if !$0 { navigation.cancelRestoreReplacement() } })) {
                Button("Cancel", role: .cancel) { navigation.cancelRestoreReplacement() }
                Button("Use Selected Environment") {
                    guard !busy, !syntheticRestore, let bundle = status.restoreReviewBundle else { navigation.cancelRestoreReplacement(); return }
                    navigation.confirmRestoreReplacement(bundle, restore: restore)
                }
            } message: {
                Text("The selected Saved Environment will replace your current Restore selection and prepared Preview. Nothing will be restored automatically.")
            }
        .onChange(of: navigation.task) { _, task in
            if task == .status, status.reference == nil, let source = restore.source, !busy {
                status.selectBundle(source)
            }
        }
        .task { if !syntheticRestore && runtime.state == .idle { runtime.checkCapabilities() } }
        #if DEBUG
        .onChange(of: scenarios.selected) { _, scenario in
            if busy { scenarios.selected = .real; return }
            if scenario != .real { navigation.task = .restore }
        }
        #endif
    }
    private func reviewStatusInRestore() {
        guard !busy, !syntheticRestore, let bundle = status.restoreReviewBundle else { return }
        navigation.reviewInRestore(bundle, restore: restore)
    }
    private var resultActionArea: some View {
        VStack(spacing: 0) {
            Divider()
            if let result = restore.executionResult {
                RestoreResultActions(result: result, refresh: { restore.checkCurrentState() }, done: { restore.finish() }, logRuntime: runtime)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .modifier(WorkspaceFooterPadding())
            }
        }
    }
    private var preparationActionArea: some View {
        VStack(spacing: 0) {
            Divider()
            RestorePreparationActions(stopping: runtime.stopping, cancel: { restore.cancel() })
                .frame(maxWidth: .infinity, alignment: .leading)
                .modifier(WorkspaceFooterPadding())
        }
    }
    private var selectionActionArea: some View {
        VStack(spacing: 0) {
            Divider()
            RestoreSelectionActions(status: restore.selectionSummary, canPreview: restore.canPreview, preview: { restore.refreshPreview() }, reviewModel: restore)
                .frame(maxWidth: .infinity, alignment: .leading)
                .modifier(WorkspaceFooterPadding())
        }
    }
    private var previewActionArea: some View {
        VStack(spacing: 0) {
            Divider()
            RestorePreviewActions(back: { restore.back() }, refresh: { restore.refreshPreview() },
                                  rebuild: { restore.requestRebuild() }, canRebuild: restore.canRebuild, showsRebuild: restore.hasAutomaticSelection)
                .frame(maxWidth: .infinity, alignment: .leading)
                .modifier(WorkspaceFooterPadding())
                .disabled(restore.busy || runtime.isActive)
        }
    }
    private func rebuildActionArea(synthetic: Bool) -> some View {
        VStack(spacing: 0) {
            Divider()
            RestoreRebuildActions(stopping: runtime.stopping, stop: synthetic ? nil : { restore.requestStop() }, force: synthetic ? nil : { restore.requestForceStop() }, gracefulWaiting: runtime.gracefulStopRequested, logRuntime: synthetic ? nil : runtime)
                .modifier(WorkspaceFooterPadding())
        }
    }
}

@MainActor final class ProductionNavigation: ObservableObject {
    @Published var task: ProductTask?
    @Published private(set) var pendingRestoreBundle: URL?

    func reviewInRestore(_ bundle: URL, restore: RestoreModel) {
        guard !restore.busy, !restore.runtime.isActive else { return }
        if restore.source == bundle { task = .restore; return }
        let hasContext = restore.state != .choose || restore.source != nil || restore.inspection != nil
            || restore.preparation != nil || restore.preview != nil || restore.executionResult != nil
            || !restore.selectedCategories.isEmpty || !restore.selectedItems.isEmpty
        if hasContext { pendingRestoreBundle = bundle; return }
        restore.choose(bundle)
        task = .restore
    }
    func cancelRestoreReplacement() { pendingRestoreBundle = nil }
    func confirmRestoreReplacement(_ bundle: URL, restore: RestoreModel) {
        guard pendingRestoreBundle == bundle, !restore.busy, !restore.runtime.isActive else { return }
        pendingRestoreBundle = nil
        if restore.source != bundle { restore.choose(bundle) }
        task = .restore
    }
}

// Applied only to the main scene; sheets and Settings retain native sizing.
enum MainWindowPolicy {
    static let minimum = NSSize(width: 1000, height: 700)
    static let preferred = NSSize(width: 1200, height: 800)
    static func apply(to window: NSWindow) {
        window.contentMinSize = minimum
        window.collectionBehavior.remove(.fullScreenNone)
        window.collectionBehavior.insert(.fullScreenPrimary)
    }
}

struct MainWindowConfiguration: NSViewRepresentable {
    final class WindowView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { MainWindowPolicy.apply(to: window) }
        }
    }
    func makeNSView(context: Context) -> WindowView { WindowView() }
    func updateNSView(_ view: WindowView, context: Context) {
        if let window = view.window { MainWindowPolicy.apply(to: window) }
    }
}
