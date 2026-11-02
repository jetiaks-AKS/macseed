import SwiftUI

@main struct MacseedApp: App {
    @NSApplicationDelegateAdaptor(CoreAppLifecycle.self) private var lifecycle
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
            CommandGroup(replacing: .appInfo) {
                Button("About Macseed") {
                    MacseedAbout.show(coreVersion: CoreRuntime.shared.capabilities?.productVersion)
                }
            }
            #if DEBUG
            RestoreScenarioCommands()
            #endif
        }
        Settings { FoundationSettingsView() }
    }
}

@MainActor enum MacseedAbout {
    static func show(coreVersion: String?) {
        NSApp.orderFrontStandardAboutPanel(options: options(coreVersion: coreVersion))
    }
    static func options(bundle: Bundle = .main, coreVersion: String?) -> [NSApplication.AboutPanelOptionKey: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineSpacing = 3
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
        let credits = NSMutableAttributedString(string: "A smarter way to capture, rebuild, and check your Mac setup.\n\n", attributes: attributes)
        if let coreVersion, !coreVersion.isEmpty {
            credits.append(NSAttributedString(string: "Macseed Core \(coreVersion)\n\n", attributes: attributes))
        }
        credits.append(NSAttributedString(string: "MIT License\n", attributes: attributes))
        for (title, address) in [
            ("GitHub Project", "https://github.com/jetiaks-AKS/macseed"),
            ("Report an Issue", "https://github.com/jetiaks-AKS/macseed/issues")
        ] {
            var link = attributes
            link[.link] = URL(string: address)!
            credits.append(NSAttributedString(string: title + "\n", attributes: link))
        }
        var result: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Macseed",
            .credits: credits]
        if let icon = MacseedBundleIcon.load(bundle: bundle) { result[.applicationIcon] = icon }
        if let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            result[.applicationVersion] = version
        }
        if let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String { result[.version] = build }
        return result
    }
}

private typealias SettingsViewState<Value> = SwiftUI.State<Value>

struct FoundationSettingsView: View {
    @AppStorage(DesktopAppearance.preferenceKey) private var appearanceValue = DesktopAppearance.system.rawValue
    @SettingsViewState private var selectedTab = "general"
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
                Button("About Macseed…") {
                    MacseedAbout.show(coreVersion: CoreRuntime.shared.capabilities?.productVersion)
                }
                .buttonStyle(.link).font(.callout)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(24)
            .tabItem { Label("General", systemImage: "gearshape") }.tag("general")
            Color.clear
                .tabItem { Label("Operation Logs", systemImage: "clock") }.tag("logs")
        }
        .onChange(of: selectedTab) { _, tab in
            if tab == "logs" {
                OperationLogWindowController.shared.open(runtime: CoreRuntime.shared, target: nil)
                selectedTab = "general"
            }
        }
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
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
            alert.informativeText = "The read-only inspection will stop. Prepare a fresh Rebuild Preview before rebuilding."
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
            Picker("Rebuild Scenario", selection: $scenarios.selected) {
                ForEach(RestoreDebugScenario.allCases) { Text($0.rawValue).tag($0) }
            }.disabled(runtime.isActive)
        }
    }
}
#endif
