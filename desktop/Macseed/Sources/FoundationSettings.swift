import AppKit
import SwiftUI

private typealias SettingsViewState<Value> = SwiftUI.State<Value>

struct FoundationSettingsView: View {
    @ObservedObject var homebrew: HomebrewSetupModel = .shared
    var showAbout: () -> Void = {}
    @SettingsViewState private var selectedTab = "general"
    var body: some View {
        TabView(selection: $selectedTab) {
            FoundationGeneralSettings(homebrew: homebrew, showAbout: showAbout)
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

// The same General content is used by the Settings scene and isolated renders.
struct FoundationGeneralSettings: View {
    @ObservedObject var homebrew: HomebrewSetupModel
    let showAbout: () -> Void
    @AppStorage(DesktopAppearance.preferenceKey) private var appearanceValue = DesktopAppearance.system.rawValue
    var body: some View {
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
            HomebrewDependencySection(model: homebrew)
            Button("About Macseed…", action: showAbout)
                .buttonStyle(.link).font(.callout)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(24)
    }
}
