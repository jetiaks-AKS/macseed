import SwiftUI

// Status consumes real read-only Core data. Capture/Restore remain later slices.
struct ProductionWorkspace: View {
    @ObservedObject var runtime: CoreRuntime
    @SwiftUI.StateObject private var status: EnvironmentStatusModel
    @Environment(\.colorScheme) private var colorScheme
    @SwiftUI.StateObject private var navigation = ProductionNavigation()
    private var busy: Bool { runtime.isActive || status.state == .running }
    init(runtime: CoreRuntime) {
        self.runtime = runtime
        _status = SwiftUI.StateObject(wrappedValue: EnvironmentStatusModel(runtime: runtime))
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
            .background {
                Color(nsColor: .controlBackgroundColor)
                    .overlay(Color(nsColor: .systemBlue).opacity(colorScheme == .dark ? 0.055 : 0.035))
            }
            .disabled(busy)
            .navigationSplitViewColumnWidth(min: 200, ideal: 215)
        } detail: {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if let task = navigation.task {
                            Label(task.rawValue, systemImage: task.symbol).font(.largeTitle.weight(.semibold))
                            Text(task.subtitle).foregroundStyle(.secondary)
                            Divider()
                            if task == .status {
                                EnvironmentStatusView(model: status, runtime: runtime)
                            } else {
                                Text("This task is not connected yet.").font(.title3)
                                Text("Task integration follows in later Desktop slices. No task is run from this screen.")
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            TaskHome { task in if !busy { navigation.task = task } }
                                .disabled(busy)
                        }
                        if runtime.isActive && runtime.operation == .capabilities {
                            ProgressView(runtime.stopping ? "Stopping…" : "Checking Macseed Core…")
                            Button("Cancel") { runtime.cancel() }.disabled(runtime.stopping)
                        } else if runtime.operation == .capabilities, let error = runtime.error {
                            Label("Needs Attention", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                            Text(error.message)
                            Button("Check Again") { runtime.checkCapabilities() }
                        } else if runtime.operation == .capabilities && runtime.state == .cancelled {
                            Text("Core check cancelled.")
                            Button("Check Again") { runtime.checkCapabilities() }
                        }
                    }
                    .padding(28).frame(maxWidth: 800, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                HStack {
                    if let capabilities = runtime.capabilities {
                        Label("Ready · Macseed Core " + capabilities.productVersion, systemImage: "checkmark.circle")
                    } else { Text(runtime.operation == .environmentCompare ? "Macseed Core · Read-only comparison" : "Macseed Core") }
                    Spacer()
                }.font(.caption).foregroundStyle(.secondary).padding(12)
            }
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button { navigation.task = nil } label: { Label("Back", systemImage: "chevron.backward") }
                        .disabled(navigation.task == nil || busy)
                        .keyboardShortcut("[", modifiers: .command)
                }
            }
        }
        .task { if runtime.state == .idle { runtime.checkCapabilities() } }
    }
}

@MainActor final class ProductionNavigation: ObservableObject {
    @Published var task: ProductTask?
}
