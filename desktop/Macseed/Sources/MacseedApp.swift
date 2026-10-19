import SwiftUI
import Darwin

@main struct MacseedApp: App {
    @NSApplicationDelegateAdaptor(CoreAppLifecycle.self) private var lifecycle
    init() {
        #if DEBUG
        if CommandLine.arguments.contains("--mas-helper-status") {
            print(MASAuthorization.developmentStatus)
            exit(0)
        }
        #endif
    }
    var body: some Scene {
        WindowGroup("Macseed") {
            ContentView()
                .frame(minWidth: MainWindowPolicy.minimum.width,
                       minHeight: MainWindowPolicy.minimum.height)
                .background(MainWindowConfiguration())
        }
        .defaultSize(width: MainWindowPolicy.preferred.width, height: MainWindowPolicy.preferred.height)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) { }
            #if DEBUG
            RestoreScenarioCommands()
            #endif
        }
        Settings { FoundationSettingsView() }
    }
}

private typealias SettingsViewState<Value> = SwiftUI.State<Value>

struct FoundationSettingsView: View {
    @AppStorage(DesktopAppearance.preferenceKey) private var appearanceValue = DesktopAppearance.system.rawValue
    @SettingsViewState private var selectedTab = "general"
    #if DEBUG
    @SettingsViewState private var helperStatus = "Not inspected"
    #endif
    var body: some View {
        TabView(selection: $selectedTab) {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("Appearance") {
                    Picker("Appearance", selection: Binding(
                        get: { appearanceValue },
                        set: { value in
                            appearanceValue = value
                            DesktopAppearance(storedValue: value).apply(to: NSApp)
                        })) {
                        ForEach(DesktopAppearance.allCases) { mode in Text(mode.title).tag(mode.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    .padding(8)
                }
                Text("Macseed Desktop Foundation").font(.headline)
                Text("Use Capture, Restore and Environment Status from the main window.")
                #if DEBUG
                Text("Use --design-preview for the DEBUG sample experience. Normal launch checks the real Core.")
                #else
                Text("Capture, Restore Preview and Environment Status use the real Macseed Core runtime.")
                #endif
            }
            .padding(24)
            .tabItem { Label("General", systemImage: "gearshape") }.tag("general")
            #if DEBUG
            VStack(alignment: .leading, spacing: 12) {
                Text(helperStatus).textSelection(.enabled)
                Button("Refresh helper status") { helperStatus = MASAuthorization.developmentStatus }
                Button("Unregister App Store helper") {
                    Task { helperStatus = await MASAuthorization.developmentUnregister() }
                }
                Text("Unregister preserves operation journals and does not stop Apple services. An unknown operation still blocks retry.")
                    .font(.caption)
            }
            .padding(24)
            .tabItem { Label("App Store Helper", systemImage: "lock.shield") }.tag("helper")
            #endif
            Color.clear
                .tabItem { Label("Operation Logs", systemImage: "clock") }.tag("logs")
        }
        .onChange(of: selectedTab) { _, tab in
            if tab == "logs" {
                OperationLogWindowController.shared.open(runtime: CoreRuntime.shared, target: nil)
                selectedTab = "general"
            }
        }
        .frame(width: 440, height: 300)
    }
}

// Quit waits for real owned-process cancellation; closing a window does not
// terminate the application or detach the shared runtime. RestoreModel.shared retains
// the operation/result context when a window is closed and reopened.
@MainActor final class CoreAppLifecycle: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        DesktopAppearance(storedValue: UserDefaults.standard.string(forKey: DesktopAppearance.preferenceKey)).apply(to: NSApp)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Use the packaged Hero-derived icon for this running app, independent of Dock caching.
        if let icon = MacseedBundleIcon.load() { NSApp.applicationIconImage = icon }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let runtime = CoreRuntime.shared
        guard runtime.isActive else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Stop the operation and quit?"
        if runtime.operation == .restorePrepare || runtime.operation == .bundleInspect {
            alert.informativeText = "The read-only inspection will stop. Prepare a fresh Restore Preview before rebuilding."
        } else if runtime.operation == .capturePrepare {
            alert.informativeText = "The scan will stop. Scan this Mac again before another attempt."
        } else if runtime.operation == .captureExecute {
            alert.informativeText = "Capture will stop. A published file or temporary state may remain. Scan again before another attempt."
        } else {
            alert.informativeText = runtime.operation == .environmentCompare || runtime.operation == .capabilities
                ? "The read-only check will stop. Check again to inspect current state."
                : "Completed changes may remain. Inspect current state before another rebuild."
        }
        alert.addButton(withTitle: "Keep Working")
        alert.addButton(withTitle: "Stop and Quit")
        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        runtime.cancel()
        Task {
            await runtime.waitForCompletion()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

#if DEBUG
struct RestoreScenarioCommands: Commands {
    @ObservedObject private var scenarios = RestoreDebugScenarios.shared
    @ObservedObject private var runtime = CoreRuntime.shared
    var body: some Commands {
        CommandMenu("Debug") {
            Picker("Restore Scenario", selection: $scenarios.selected) {
                ForEach(RestoreDebugScenario.allCases) { Text($0.rawValue).tag($0) }
            }.disabled(runtime.isActive)
        }
    }
}
#endif
