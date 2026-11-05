import AppKit
import SwiftUI

private typealias SettingsViewState<Value> = SwiftUI.State<Value>

struct FoundationSettingsView: View {
    @ObservedObject var homebrew: HomebrewSetupModel = .shared
    var showAbout: () -> Void = {}
    @StateObject private var age = BundledAgeSettingsModel()
    @SettingsViewState private var selectedTab = "general"
    var body: some View {
        TabView(selection: $selectedTab) {
            FoundationGeneralSettings(showAbout: showAbout)
                .tabItem { Label("General", systemImage: "gearshape") }.tag("general")
            FoundationToolsSettings(homebrew: homebrew, age: age)
                .tabItem { Label("Tools & Dependencies", systemImage: "wrench.and.screwdriver") }.tag("tools")
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
            Button("About Macseed…", action: showAbout)
                .buttonStyle(.link).font(.callout)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(24)
    }
}


struct FoundationToolsSettings: View {
    @ObservedObject var homebrew: HomebrewSetupModel
    @ObservedObject var age: BundledAgeSettingsModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HomebrewDependencySection(model: homebrew)
            GroupBox("Built-in Tools") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("age").font(.body.weight(.medium))
                            Text(age.identity).font(.caption).foregroundStyle(.secondary)
                            Text(age.status).font(.callout).foregroundStyle(.secondary)
                                .accessibilityIdentifier("age.status")
                        }
                        Spacer()
                        Button("Check Again") { Task { await age.check() } }
                            .disabled(age.checking).accessibilityIdentifier("age.checkAgain")
                    }
                    Text("Used to encrypt and decrypt SSH identities. Included with Macseed. No separate installation is required.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let explanation = age.explanation {
                        Text(explanation).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(8)
            }
        }
        .padding(24)
        .task { await age.checkIfNeeded() }
    }
}

struct BundledAgeObservation: Equatable, Sendable {
    enum Status: String, Decodable, Sendable {
        case available, missing, invalid, unableToVerify = "unable_to_verify"
        var title: String {
            switch self {
            case .available: "Available"
            case .missing: "Missing"
            case .invalid: "Invalid"
            case .unableToVerify: "Unable to Verify"
            }
        }
    }
    let status: Status
    var version: String?
    var architecture: String?
    static let unableToVerify = Self(status: .unableToVerify)

    static func decode(_ result: NativeHomebrewRead.Result) -> Self {
        struct Record: Decodable {
            let schema_version: Int
            let status: Status
            let version: String?
            let architecture: String?
        }
        guard result.complete, result.exitCode == 0, result.output.utf8.count <= 1024,
              let record = try? JSONDecoder().decode(Record.self, from: Data(result.output.utf8)),
              record.schema_version == 1 else { return .unableToVerify }
        func safeMetadata(_ value: String?) -> Bool {
            guard let value, !value.isEmpty, value.utf8.count <= 48 else { return false }
            return value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95, 43].contains($0) }
        }
        if record.status == .available {
            guard safeMetadata(record.version), safeMetadata(record.architecture) else { return .unableToVerify }
        } else if record.version != nil || record.architecture != nil { return .unableToVerify }
        return Self(status: record.status, version: record.version, architecture: record.architecture)
    }
}

enum BundledAgeSettingsProbe {
    static func observe() async -> BundledAgeObservation {
        await Task.detached(priority: .userInitiated) {
            guard let location = try? CoreLocationResolver().resolve() else { return .unableToVerify }
            return inspect(location: location)
        }.value
    }
    static func inspect(location: CoreLocation) -> BundledAgeObservation {
        guard let application = location.applicationBundle,
              (try? location.validate(for: CoreCommand.capabilities)) != nil else { return .unableToVerify }
        // Use the existing bounded, owned read process. Python's isolated mode
        // ignores inherited Python configuration; -B prevents bytecode writes.
        // Core's single validator owns paths, architecture, provenance and integrity.
        let result = NativeHomebrewRead.run(location.python.path,
            arguments: ["-I", "-B", location.root.appendingPathComponent("modules/migration/age_runtime.py").path,
                        "--inspect-bundle", application.path], timeout: 5)
        return BundledAgeObservation.decode(result)
    }
}

@MainActor final class BundledAgeSettingsModel: ObservableObject {
    @Published private(set) var observation: BundledAgeObservation?
    @Published private(set) var checking = false
    private let inspect: () async -> BundledAgeObservation
    init(inspect: @escaping () async -> BundledAgeObservation = BundledAgeSettingsProbe.observe) { self.inspect = inspect }
    var identity: String {
        guard let observation, observation.status == .available,
              let version = observation.version, let architecture = observation.architecture else { return "Bundled" }
        return "Bundled · \(version) · \(architecture)"
    }
    var status: String { checking ? "Checking…" : observation?.status.title ?? "Not Checked" }
    var explanation: String? {
        switch observation?.status {
        case .missing: "The built-in tool is missing. Rebuild or reinstall Macseed, then Check Again."
        case .invalid: "The built-in tool could not pass validation. Rebuild or reinstall Macseed, then Check Again."
        case .unableToVerify: "Macseed could not verify its built-in tool. Check Again; if this continues, rebuild or reinstall Macseed."
        default: nil
        }
    }
    func checkIfNeeded() async { if observation == nil { await check() } }
    func check() async {
        guard !checking else { return }
        checking = true; observation = nil
        observation = await inspect()
        checking = false
    }
}
