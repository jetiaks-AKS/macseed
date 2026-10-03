import SwiftUI

@main struct MacseedApp: App {
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
                Text("This build previews the design with sample data. It does not change your Mac.")
                #else
                Text("Core integration is not available in this foundation build.")
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
