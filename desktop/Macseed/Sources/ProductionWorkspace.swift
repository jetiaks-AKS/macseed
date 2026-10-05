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
            List(selection: Binding<String?>(get: { navigation.task?.rawValue ?? "All Tasks" }, set: { value in
                guard !busy, let value else { return }
                navigation.task = ProductTask(rawValue: value)
            })) {
                Label("All Tasks", systemImage: "square.grid.2x2").tag("All Tasks")
                ForEach(ProductTask.allCases) { task in Label(task.rawValue, systemImage: task.symbol).tag(task.rawValue) }
            }
            .listStyle(.sidebar).scrollContentBackground(.hidden)
            .modifier(InsetSidebarSurface())
            .disabled(busy)
            .navigationSplitViewColumnWidth(min: 200, ideal: 215)
        } detail: {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if let task = navigation.task {
                            if task != .status || status.state != .result {
                                WorkspaceHeader(title: task.rawValue, subtitle: task.subtitle, symbol: task.symbol)
                            }
                            if task == .status {
                                EnvironmentStatusView(model: status, runtime: runtime)
                            } else if task == .capture {
                                CaptureView(model: capture, runtime: runtime, showsActions: false)
                            } else {
                                #if DEBUG
                                if syntheticRestore { RestoreDebugScenarioView(scenario: scenarios.selected) }
                                else { RestoreView(model: restore, runtime: runtime, showsRebuildActions: false) }
                                #else
                                RestoreView(model: restore, runtime: runtime, showsRebuildActions: false)
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
                if navigation.task == .capture && capture.state != .idle {
                    Divider()
                    CaptureActionsView(model: capture, runtime: runtime).padding(.horizontal, WorkspaceGeometry.margin).padding(.vertical, 12)
                }
                if navigation.task == .restore {
                    #if DEBUG
                    if syntheticRestore {
                        if scenarios.selected == .rebuilding { rebuildActionArea(synthetic: true) }
                    } else if restore.state == .rebuilding { rebuildActionArea(synthetic: false) }
                    #else
                    if restore.state == .rebuilding { rebuildActionArea(synthetic: false) }
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
                        else if navigation.task == .restore && restore.state == .preview { restore.back() }
                        else { navigation.task = nil }
                    } label: { Label("Back", systemImage: "chevron.backward") }
                        .disabled(navigation.task == nil || busy)
                        .keyboardShortcut("[", modifiers: .command)
                }
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
    private func rebuildActionArea(synthetic: Bool) -> some View {
        VStack(spacing: 0) {
            Divider()
            RestoreRebuildActions(stopping: runtime.stopping, stop: synthetic ? nil : { restore.requestStop() })
                .padding(.horizontal, WorkspaceGeometry.margin).padding(.vertical, 12)
        }
    }
}

@MainActor final class ProductionNavigation: ObservableObject {
    @Published var task: ProductTask?
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
