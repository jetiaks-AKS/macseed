import SwiftUI
import AppKit

// Select the standard property wrapper explicitly: the current CLT SDK also
// exports a State macro whose plugin is available only with full Xcode.
private typealias ViewState<Value> = SwiftUI.State<Value>

struct ContentView: View {
    @ObservedObject var runtime = CoreRuntime.shared
    #if DEBUG
    @StateObject private var session = DemoSession()
    private let designPreview = CommandLine.arguments.contains("--design-preview")
    @ViewBuilder var body: some View {
        if designPreview { DemoWorkspace(session: session) }
        else { ProductionWorkspace(runtime: runtime) }
    }
    #else
    var body: some View { ProductionWorkspace(runtime: runtime) }
    #endif
}

struct TaskHome: View {
    let select: (ProductTask) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Macseed").font(.largeTitle.weight(.semibold))
                Text("Capture your environment. Rebuild with confidence.")
                    .font(.title3).foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(ProductTask.allCases) { task in
                Button { select(task) } label: {
                    HStack(spacing: 18) {
                        Image(systemName: task.symbol).font(.title).frame(width: 40)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(task.rawValue).font(.headline)
                            Text(task.subtitle).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(task.rawValue + ". " + task.subtitle)
                Divider()
            }
        }
    }
}

struct StatusLabel: View {
    let status: DisplayStatus
    var body: some View {
        Label(status.rawValue, systemImage: status.symbol)
            .font(.callout)
            .foregroundStyle([DisplayStatus.attention, .missing, .different, .unverified, .unresolved].contains(status) ? Color.orange : Color.secondary)
    }
}

struct ItemDetails: View {
    let items: [DisplayItem]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(items) { item in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title)
                        Text(item.action).font(.callout).foregroundStyle(.secondary)
                        if let reason = item.reason {
                            DisclosureGroup("Technical reason") {
                                Text(reason).font(.caption.monospaced()).textSelection(.enabled)
                            }.disclosureGroupStyle(HeaderDisclosureStyle()).font(.caption)
                        }
                    }
                    Spacer()
                    StatusLabel(status: item.status)
                }
            }
        }.padding(.vertical, 8)
    }
}

// A real AppKit checkbox supplies native mixed state and one non-overlapping
// hit target including its label. It never owns the disclosure gesture.
struct NativeSelectionCheckbox: NSViewRepresentable {
    let title: String
    let state: SelectionState
    let accessibilityTitle: String
    let setIncluded: (Bool) -> Void

    init(_ title: String, state: SelectionState, accessibilityTitle: String? = nil, setIncluded: @escaping (Bool) -> Void) {
        self.title = title
        self.state = state
        self.accessibilityTitle = accessibilityTitle ?? title
        self.setIncluded = setIncluded
    }
    init(_ title: String, isOn: Binding<Bool>, accessibilityTitle: String? = nil) {
        self.init(title, state: isOn.wrappedValue ? .all : .none, accessibilityTitle: accessibilityTitle,
                  setIncluded: { isOn.wrappedValue = $0 })
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSButton {
        makeButton(coordinator: context.coordinator)
    }
    func makeButton(coordinator: Coordinator) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: coordinator,
                              action: #selector(Coordinator.toggle(_:)))
        button.allowsMixedState = true
        button.state = state == .mixed ? .mixed : (state == .all ? .on : .off)
        button.setAccessibilityLabel(accessibilityTitle)
        button.alignment = .left
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.control = self
        button.title = title
        button.state = state == .mixed ? .mixed : (state == .all ? .on : .off)
        button.setAccessibilityLabel(accessibilityTitle)
    }
    final class Coordinator: NSObject {
        var control: NativeSelectionCheckbox
        init(_ control: NativeSelectionCheckbox) { self.control = control }
        @objc func toggle(_ sender: NSButton) {
            // Mixed -> all; all -> none, regardless of AppKit's three-state cycle.
            control.setIncluded(control.state != .all)
        }
    }
}

struct HeaderDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { configuration.isExpanded.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    configuration.label
                }
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
            if configuration.isExpanded { configuration.content.padding(.leading, 20) }
        }
    }
}

struct CategoryRow: View {
    let category: DisplayCategory
    var selected: Binding<Bool>?
    var captureState: SelectionState? = nil
    var selectCategory: ((Bool) -> Void)? = nil
    var itemSelected: ((String) -> Bool)? = nil
    var selectItem: ((String, Bool) -> Void)? = nil
    @ViewState<Bool> private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                if let captureState, let selectCategory {
                    NativeSelectionCheckbox("", state: captureState, accessibilityTitle: "Select " + category.title, setIncluded: selectCategory)
                        .frame(width: 28, height: 28)
                        .accessibilityLabel("Select " + category.title)
                } else if let selected {
                    NativeSelectionCheckbox("", isOn: selected, accessibilityTitle: "Select " + category.title)
                        .frame(width: 28, height: 28)
                        .accessibilityLabel("Select " + category.title)
                }
                DisclosureGroup(isExpanded: $expanded) { EmptyView() } label: {
                    HStack {
                        Label(category.title, systemImage: category.symbol).font(.headline)
                        Spacer()
                        Text("\(category.items.count) \(category.items.count == 1 ? "item" : "items")")
                            .font(.callout).foregroundStyle(.secondary)
                        if category.hasAttention {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .accessibilityLabel("Needs Attention")
                                .help("Needs Attention")
                        }
                    }
                }
                .disclosureGroupStyle(HeaderDisclosureStyle())
            }
            if expanded {
                if let itemSelected, let selectItem {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(category.items) { item in
                            NativeSelectionCheckbox(item.title, isOn: Binding(
                                get: { itemSelected(item.id) },
                                set: { selectItem(item.id, $0) }))
                                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                        }
                    }
                    .padding(.leading, 24).padding(.vertical, 8)
                } else { ItemDetails(items: category.items).padding(.leading, 24) }
            }
        }
        .padding(.vertical, 7)
    }
}

struct ResultSummary: View {
    let result: DisplayResult
    @ViewState<Bool> private var detailsExpanded: Bool
    init(result: DisplayResult) {
        self.result = result
        _detailsExpanded = ViewState(initialValue: result.detailsInitiallyExpanded)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(result.title).font(.title2.weight(.semibold))
            Text(result.message).foregroundStyle(.secondary)
            if let ready = result.readyCount { Text("\(ready) items are ready.") }
            if let attention = result.attentionCount, attention > 0 {
                Label("\(attention) \(attention == 1 ? "item needs" : "items need") attention.", systemImage: "exclamationmark.triangle")
            }
            if !result.attentionDetails.isEmpty {
                ItemDetails(items: result.attentionDetails)
            }
            DisclosureGroup("View Details", isExpanded: $detailsExpanded) {
                ItemDetails(items: result.details)
            }.disclosureGroupStyle(HeaderDisclosureStyle())
        }
    }
}

#if DEBUG
struct DemoWorkspace: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var session: DemoSession
    @ViewState<Bool> private var stopConfirmation = false
    var body: some View {
        NavigationSplitView {
            List(selection: Binding<String?>(
                get: { session.task?.rawValue ?? "All Tasks" },
                set: { selection in
                    guard let selection else { return }
                    if selection == "All Tasks" { session.navigate(nil) }
                    else if let task = ProductTask(rawValue: selection) { session.navigate(task) }
                })) {
                Label("All Tasks", systemImage: "square.grid.2x2").tag("All Tasks")
                ForEach(ProductTask.allCases) { task in
                    Label(task.rawValue, systemImage: task.symbol).tag(task.rawValue)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background {
                Color(nsColor: .controlBackgroundColor)
                    .overlay(Color(nsColor: .systemBlue).opacity(colorScheme == .dark ? 0.055 : 0.035))
            }
            .disabled(session.busy)
            .navigationSplitViewColumnWidth(min: 200, ideal: 215)
        } detail: {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if let task = session.task {
                            Label(task.rawValue, systemImage: task.symbol).font(.largeTitle.weight(.semibold))
                            Text(task.subtitle).foregroundStyle(.secondary)
                            Divider()
                            switch task {
                            case .capture: CaptureDemoView(session: session)
                            case .restore: RestoreDemoView(session: session, stop: { stopConfirmation = true })
                            case .status: StatusDemoView(session: session)
                            }
                        } else { TaskHome(select: { session.navigate($0) }) }
                    }
                    .padding(28)
                    .frame(maxWidth: 800, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                HStack {
                    Label("Design preview · Sample data only", systemImage: "eye")
                    Spacer()
                    Text("No changes to your Mac")
                }
                .font(.caption).foregroundStyle(.secondary).padding(12)
            }
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button { session.goBack() } label: {
                        Label("Back", systemImage: "chevron.backward")
                    }
                    .disabled(!session.canGoBack)
                    .keyboardShortcut("[", modifiers: .command)
                    .help("Back")
                }
                ToolbarItem {
                    Menu {
                        ForEach(DemoPreset.allCases) { preset in
                            Button(preset.rawValue) { session.load(preset) }
                        }
                    } label: { Label("Demo States", systemImage: "slider.horizontal.3") }
                    .disabled(session.busy)
                    .help("DEBUG-only deterministic design states")
                }
            }
        }
        .sheet(isPresented: $session.secureSheet) {
            SecureDemoSheet {
                session.completeSecureDemo()
            } cancel: {
                session.secureSheet = false
            }
        }
        .alert("Stop rebuilding?", isPresented: $stopConfirmation) {
            Button("Keep Working", role: .cancel) { }
            Button("Stop Rebuild", role: .destructive) { session.stop() }
        } message: {
            Text("Completed changes will remain. Macseed will inspect the current state before you rebuild again.")
        }
    }
}

struct CaptureDemoView: View {
    @ObservedObject var session: DemoSession
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            switch session.captureState {
            case .idle, .cancelled:
                if session.captureState == .cancelled { Text("Scan cancelled. No target changes occurred.") }
                Text("Choose which supported settings and tools to carry to another Mac.")
                Button("Scan this Mac") { session.scan() }.buttonStyle(.borderedProminent)
            case .scanning:
                ProgressView("Scanning supported environment…")
                Text("Checking applications, settings and workspace.").foregroundStyle(.secondary)
                HStack {
                    Button("Show Sample Scan Results") { session.finishScan() }
                    Button("Cancel", role: .cancel) { session.cancelCapture() }
                }
            case .review:
                HStack {
                    Text("Review and select").font(.title2)
                    Spacer()
                    Button(session.captureBulkState.bulkActionTitle) { session.toggleAllCapture() }
                }
                Text("Ordinary settings are private but unencrypted. Only supported reproducible state is included.")
                    .font(.callout).foregroundStyle(.secondary)
                ForEach(session.captureCategories) { category in
                    CategoryRow(category: category,
                                captureState: session.captureSelectionState(category),
                                selectCategory: { session.selectCapture(category.id, included: $0) },
                                itemSelected: { session.captureItemSelection.contains($0) },
                                selectItem: { session.selectCaptureItem($0, included: $1) })
                }
                Text("\(session.captureSelection.count) categories · \(session.selectedCaptureItemCount) items selected")
                    .font(.callout).foregroundStyle(.secondary)
                Divider()
                HStack {
                    Label("Secure Transfer", systemImage: "lock.shield").font(.headline)
                    Spacer()
                    Button(session.secureBulkState.bulkActionTitle) { session.toggleAllIdentities() }
                }
                HStack { Text("SSH identities"); Spacer(); Text("\(session.secureIdentityNames.count) available").foregroundStyle(.secondary) }
                Text("Encrypted separately · Optional").font(.callout).foregroundStyle(.secondary)
                ForEach(session.secureIdentityNames, id: \.self) { name in
                    NativeSelectionCheckbox(name, isOn: Binding(
                        get: { session.identitySelection.contains(name) },
                        set: { session.selectIdentity(name, included: $0) }))
                        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                }
                HStack {
                    Button("Create Bundle") { session.createCapture() }
                        .buttonStyle(.borderedProminent).disabled(!session.canCreate)
                    Button("Cancel") { session.cancelCapture() }
                }
                if !session.canCreate { Text("Choose supported state to capture.").foregroundStyle(.secondary) }
            case .result:
                Label("Bundle Created", systemImage: "checkmark.circle").font(.title2)
                Text("\(session.captureSelection.count) categories, \(session.selectedCaptureItemCount) items and \(session.identitySelection.count) SSH identities selected.")
                Text("Sample result only. No .mbt file was created.").foregroundStyle(.secondary)
                Button("Capture Again") { session.scan() }
            }
        }
    }
}

struct RestoreDemoView: View {
    @ObservedObject var session: DemoSession
    let stop: () -> Void
    @ViewState<Bool> private var instructions = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let previous = session.previousStoppedBundle {
                Label("A previous rebuild of Bundle \(previous) was stopped. This attempt uses a fresh Preview of current state.",
                      systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
            }
            if session.restoreState != .rebuilding {
                HStack {
                    Text("Sample Bundle").font(.headline)
                    Button("Choose Bundle A") { session.chooseBundle("A") }
                    Button("Choose Bundle B") { session.chooseBundle("B") }
                }
            }
            switch session.restoreState {
            case .choose:
                Text("Choose a sample Bundle to review its supported environment. No file is opened or parsed.")
                    .foregroundStyle(.secondary)
            case .review:
                Text("Bundle \(session.bundle ?? "") · Review + Preview").font(.title2)
                HStack {
                    Text("\(session.restoreSelection.count) groups selected").foregroundStyle(.secondary)
                    Spacer()
                    Button(session.restoreBulkState.bulkActionTitle) { session.toggleAllRestore() }
                }
                Text("Choose groups to restore. Expand a group to see changes and already matching items.")
                    .foregroundStyle(.secondary)
                if session.needsHomebrew {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(session.prerequisite.title, systemImage: "exclamationmark.triangle")
                        HStack {
                            Button("How to Resolve") { instructions.toggle() }
                            Button("Check Again") { session.checkAgain() }
                        }
                        if instructions {
                            Text(session.prerequisite.instructions).font(.callout)
                            DisclosureGroup("Technical reason") { Text(session.prerequisite.reason).font(.caption.monospaced()) }
                                .disclosureGroupStyle(HeaderDisclosureStyle())
                        }
                    }.padding(.vertical, 8)
                }
                ForEach(session.restoreCategories) { category in
                    CategoryRow(category: category, selected: Binding(
                        get: { session.restoreSelection.contains(category.id) },
                        set: { session.selectRestore(category.id, included: $0) }))
                }
                Text("Matching groups need no changes. Conflicts stay visible and are not overwritten.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("Rebuild") { session.rebuild() }.buttonStyle(.borderedProminent).disabled(!session.canRebuild)
                    Button("Cancel") { session.cancelRestore() }
                }
                Text("Rebuild confirms this selection and Preview. Nothing is changed in this design preview.")
                    .font(.caption).foregroundStyle(.secondary)
            case .rebuilding:
                ProgressView(session.progress.phase)
                Text(session.progress.subject).font(.headline)
                Text("\(session.progress.processed) sample changes processed").foregroundStyle(.secondary)
                ItemDetails(items: session.progress.categories)
                HStack {
                    Button("Next Sample Event") { session.nextEvent() }
                    Button("Stop Rebuild", role: .destructive, action: stop)
                }
            case .result, .stopped:
                if let result = session.result { ResultSummary(result: result).id(session.revision) }
                Text("Sample result for selected supported state.").font(.caption).foregroundStyle(.secondary)
                Button("Refresh Preview") { session.chooseBundle(session.bundle ?? "A") }
            }
        }
    }
}

struct StatusDemoView: View {
    @ObservedObject var session: DemoSession
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Reference: Sample saved configuration", systemImage: "folder")
            Text("Generated Configuration · No Blueprint · Read-only comparison").font(.callout).foregroundStyle(.secondary)
            if session.statusState == .choose {
                Text("Compare with this sample saved configuration. Bundle comparison is not supported.")
                Button("Compare") { session.compare() }.buttonStyle(.borderedProminent)
            } else {
                Text("Needs Attention").font(.title2)
                Text("1 matching · 1 different · 1 unverified")
                Text("The unverified item is not supported. Nothing will be removed or changed.")
                    .foregroundStyle(.secondary)
                ForEach(session.statusCategories) { category in CategoryRow(category: category) }
                Button("Check Again") { session.compare() }
            }
        }
    }
}

struct SecureDemoSheet: View {
    let complete: () -> Void
    let cancel: () -> Void
    @ViewState<String> private var passphrase = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Encrypt SSH identities", systemImage: "lock.shield").font(.title2)
            Text("Design preview: use any sample text, not a real password. No encryption is performed.")
                .foregroundStyle(.secondary)
            SecureField("Sample Bundle passphrase", text: $passphrase)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Sample Bundle encryption passphrase")
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { passphrase = ""; cancel() }.keyboardShortcut(.cancelAction)
                Button("Continue") { passphrase = ""; complete() }
                    .buttonStyle(.borderedProminent).disabled(passphrase.isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 440)
        .onDisappear { passphrase = "" }
    }
}
#endif
