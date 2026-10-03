import SwiftUI

@main struct MacseedApp: App {
    @NSApplicationDelegateAdaptor(CoreAppLifecycle.self) private var lifecycle
    var body: some Scene {
        WindowGroup("Macseed") {
            ContentView()
                .frame(minWidth: 760, minHeight: 600)
        }
        .defaultSize(width: 920, height: 740)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
        Settings { FoundationSettingsView() }
    }
}

struct FoundationSettingsView: View {
    var body: some View {
        TabView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Macseed Desktop Foundation").font(.headline)
                Text("Use Capture, Restore and Environment Status from the main window.")
                #if DEBUG
                Text("Use --design-preview for the DEBUG sample experience. Normal launch checks the real Core.")
                #else
                Text("Environment Status uses the real Macseed Core runtime. Capture and Restore integration follows in later slices.")
                #endif
            }
            .padding(24)
            .tabItem { Label("General", systemImage: "gearshape") }
            VStack(alignment: .leading, spacing: 16) {
                Text("Privacy / Diagnostics").font(.headline)
                Text("This foundation does not save operation logs, export reports or send telemetry.")
                Text("Diagnostic controls will appear when structured logging is implemented.")
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .tabItem { Label("Privacy / Diagnostics", systemImage: "hand.raised") }
        }
        .frame(width: 440, height: 220)
    }
}

// Quit waits for real owned-process cancellation; closing a window does not
// terminate the application or detach the shared runtime.
@MainActor final class CoreAppLifecycle: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let runtime = CoreRuntime.shared
        guard runtime.isActive else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Stop the operation and quit?"
        alert.informativeText = runtime.operation == .environmentCompare || runtime.operation == .capabilities
            ? "The read-only check will stop. Check again to inspect current state."
            : "Completed changes may remain. Inspect current state before another rebuild."
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
