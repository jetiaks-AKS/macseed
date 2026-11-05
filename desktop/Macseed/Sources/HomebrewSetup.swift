import AppKit
import SwiftUI
import Darwin

struct HomebrewHost: Equatable, Sendable {
    enum Architecture: String, Sendable { case appleSilicon, intel, unknown }
    let architecture: Architecture
    let majorVersion: Int
    let version: String
    // Upstream Installation and pkg Distribution policy checked 2026-11-03.
    var supportsPackage: Bool { architecture == .appleSilicon && (15..<28).contains(majorVersion) }
    var supportsTerminal: Bool { supportsPackage }
    var installationPolicy: String {
        "Current official installers require Apple Silicon and macOS 15–27. Intel and older or unqualified future macOS versions are not offered installation."
    }
    var description: String {
        let chip = architecture == .appleSilicon ? "Apple Silicon" : architecture == .intel ? "Intel" : "Unknown architecture"
        return "\(chip) · macOS \(version)"
    }
    static func current() -> Self {
        var arm: Int32 = 0, size = MemoryLayout<Int32>.size
        let result = sysctlbyname("hw.optional.arm64", &arm, &size, nil, 0)
        var system = utsname(); let known = uname(&system) == 0
        let machine = withUnsafeBytes(of: &system.machine) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        let architecture: Architecture = result == 0 && arm == 1 ? .appleSilicon
            : known && machine == "x86_64" ? .intel : .unknown
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return Self(architecture: architecture, majorVersion: os.majorVersion,
                    version: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
    }
}

struct HomebrewObservation: Decodable, Equatable, Sendable {
    enum State: String, Decodable, Sendable { case absent, usable, broken, unknown }
    let state: State
    let reason: String?
    static let absent = Self(state: .absent, reason: "homebrew_installation_requires_interaction")
    static let usable = Self(state: .usable, reason: nil)
    static let broken = Self(state: .broken, reason: "homebrew_unavailable")
    static let unknown = Self(state: .unknown, reason: "homebrew_unavailable")
    var isConsistent: Bool {
        switch state {
        case .usable: reason == nil
        case .absent: reason == "homebrew_installation_requires_interaction"
        case .broken, .unknown: reason == "homebrew_unavailable"
        }
    }
}

// Keep App.main on the ordinary main-thread entry stack, outside a suspended
// Swift-concurrency job. Pump the run loop while the bounded reader works off-main.
// A hard fallback opens Home as Unknown; a late result cannot re-open setup.
@MainActor enum HomebrewStartupGate {
    static func prepare(_ model: HomebrewSetupModel, timeout: TimeInterval = 6) {
        var finished = false
        let work = Task { await model.prepareLaunch(); finished = true }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !finished && ProcessInfo.processInfo.systemUptime < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        if !finished { model.abandonLaunchCheck(); work.cancel() }
    }
}

@MainActor final class HomebrewSetupModel: ObservableObject {
    enum InstallationMethod { case package, terminal }
    static let shared: HomebrewSetupModel = {
        #if DEBUG
        if let configuration = HomebrewSetupDebug.configuration { return configuration.makeModel() }
        #endif
        return HomebrewSetupModel()
    }()
    static let reminderKey = "homebrewSetup.showStartupReminders"
    static let downloadPage = URL(string: "https://github.com/Homebrew/brew/releases/latest")!
    static let terminalCommand = #"/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)""#
    let host: HomebrewHost
    @Published private(set) var observation: HomebrewObservation?
    @Published private(set) var checking = false
    @Published var remindersEnabled: Bool { didSet { preferences.set(remindersEnabled, forKey: Self.reminderKey) } }
    @Published var suppressReminder = false
    @Published private(set) var installationMethod: InstallationMethod?
    @Published private(set) var actionMessage: String?
    @Published private(set) var packageState = HomebrewPackageState.idle
    private let packageService: HomebrewPackageService
    private let packageStagingBase: URL?
    private var packageTask: Task<Void, Never>?
    private var packageAttempt: UUID?
    private let detect: () async -> HomebrewObservation
    private let openPage: (URL) -> Bool
    private let openTerminal: () -> Bool
    private let copy: (String) -> Bool
    private let preferences: UserDefaults
    private var rechecked: (() -> Void)?
    private weak var returnFocusWindow: NSWindow?
    @Published private(set) var startupPending = false
    @Published private(set) var launchOffersSetup = false
    private var launchCheckAbandoned = false
    init(host: HomebrewHost = .current(), preferences: UserDefaults = .standard,
         detect: @escaping () async -> HomebrewObservation = { await HomebrewSetupProbe.observe() },
         openPage: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) },
         openTerminal: @escaping () -> Bool = {
             NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
         }, copy: @escaping (String) -> Bool = {
             NSPasteboard.general.clearContents(); return NSPasteboard.general.setString($0, forType: .string)
         }, packageService: HomebrewPackageService = .live, packageStagingBase: URL? = nil) {
        self.host = host; self.preferences = preferences; self.detect = detect
        self.openPage = openPage; self.openTerminal = openTerminal; self.copy = copy
        self.packageService = packageService; self.packageStagingBase = packageStagingBase
        HomebrewPackageStaging.cleanup(base: packageStagingBase)
        // Preserve explicit deferral from the initial, uncommitted implementation.
        remindersEnabled = preferences.object(forKey: Self.reminderKey) as? Bool
            ?? !preferences.bool(forKey: "homebrewSetup.deferred")
    }
    var canInstall: Bool { host.supportsPackage && observation?.state == .absent && !checking }
    var canDownloadPackage: Bool { canInstall && packageTask == nil && packageState != .opened && packageState != .opening }
    var closesWhenAvailable: Bool { startupPending || rechecked != nil }
    var settingsAction: String {
        if observation?.state == .usable { return "Setup…" }
        return observation?.state == .absent && host.supportsPackage ? "Install…" : "Details…"
    }
    var settingsExplanation: String {
        observation?.state == .absent && host.supportsPackage
            ? "Select Install… to choose an installation method. After installation, select Check Again."
            : explanation
    }
    var status: String {
        if checking { return "Checking…" }
        switch observation?.state {
        case .usable: return "Available"
        case .absent: return "Not Installed"
        case .broken: return "Broken"
        case .unknown: return "Unknown"
        case nil: return "Not Checked"
        }
    }
    var explanation: String {
        switch observation?.state {
        case .usable: return "Homebrew is available. Rebuild checks the requirements for your selected work separately."
        case .broken: return "An existing Homebrew installation is incomplete or failed its usability check. Macseed will not replace or repair it. Review the installation in Terminal, then Check Again."
        case .unknown: return "Homebrew could not be safely assessed. Access, location or the bounded check could not be confirmed. Check Again; do not reinstall over an uncertain installation."
        case .absent:
            return host.supportsPackage ? "Choose an installation method below. After the external installer finishes, select Check Again. Opening an installer or Terminal does not confirm installation." : host.installationPolicy
        case nil: return "Checking whether Homebrew is available on this Mac."
        }
    }
    func check() async {
        guard !checking else { return }
        checking = true
        let observed = await detect()
        observation = observed.isConsistent ? observed : .unknown
        if observation?.state != .absent {
            cancelPackageDownload()
            installationMethod = nil; actionMessage = nil
        }
        checking = false
    }
    func prepareLaunch() async {
        guard remindersEnabled && host.supportsPackage else { return }
        await check()
        guard !launchCheckAbandoned else { return }
        launchOffersSetup = canInstall
        startupPending = launchOffersSetup
        suppressReminder = !remindersEnabled
    }
    func abandonLaunchCheck() {
        launchCheckAbandoned = true; observation = .unknown
        startupPending = false; launchOffersSetup = false
    }
    func beginSetup(rechecked: (() -> Void)? = nil, returningTo window: NSWindow? = nil) {
        self.rechecked = rechecked
        returnFocusWindow = window
        suppressReminder = !remindersEnabled
        installationMethod = packageTask != nil || packageState == .opened ? .package : nil; actionMessage = nil
    }
    func selectMethod(_ method: InstallationMethod) {
        guard canInstall, method != .terminal || host.supportsTerminal else { return }
        if method == .terminal { cancelPackageDownload() }
        installationMethod = method; actionMessage = nil
    }
    func finishSetup(notNow: Bool) -> Bool {
        cancelPackageDownload()
        if startupPending && notNow { remindersEnabled = !suppressReminder }
        let openHome = startupPending
        startupPending = false; launchOffersSetup = false; rechecked = nil
        if !openHome, let window = returnFocusWindow {
            DispatchQueue.main.async { [weak window] in
                if let window, window.isVisible { window.makeKeyAndOrderFront(nil) }
            }
        }
        returnFocusWindow = nil
        return openHome
    }
    func checkAgain() async {
        cancelPackageDownload()
        await check()
        if packageTask == nil && packageState == .opened && observation?.state == .absent {
            // Installer cancellation is not observable as installation. A fresh
            // missing check permits another explicit attempt, never auto-retry.
            packageState = .idle; installationMethod = nil
        }
        rechecked?()
    }
    func installPackage() {
        guard canDownloadPackage else { return }
        installationMethod = .package; actionMessage = nil; packageState = .resolving
        let attempt = UUID(); packageAttempt = attempt
        packageTask = Task { [self] in
            var staging: HomebrewPackageStaging?
            var handedToInstaller = false
            defer {
                // Once launch has been requested, Installer may still read the
                // package even if Macseed closes or launch reports an error.
                if !handedToInstaller { staging?.remove() }
                packageTask = nil; packageAttempt = nil
            }
            do {
                await check()
                try Task.checkCancellation()
                guard canInstall else { throw HomebrewPackageError.verification("Homebrew is no longer confirmed missing. Installation was not started.") }
                let plan = try await packageService.resolve()
                try Task.checkCancellation()
                let location = try HomebrewPackageStaging(base: packageStagingBase); staging = location
                packageState = .downloading(received: 0, total: plan.size)
                try await packageService.download(plan, location.partial) { [weak self] received in
                    Task { @MainActor in
                        guard let self, self.packageAttempt == attempt,
                              case .downloading = self.packageState else { return }
                        self.packageState = .downloading(received: received, total: plan.size)
                    }
                }
                try Task.checkCancellation()
                try location.complete()
                packageState = .verifying
                try await packageService.verify(plan, location.package)
                try Task.checkCancellation()
                // A download may take minutes. Do not offer a reinstall if
                // Homebrew appeared or became uncertain while it was running.
                await check()
                try Task.checkCancellation()
                guard canInstall else { throw HomebrewPackageError.verification("Homebrew is no longer confirmed missing. Installer was not opened.") }
                // Persist retention before the non-cancellable external handoff.
                try location.retainForInstaller()
                packageState = .opening
                handedToInstaller = true
                try await packageService.openInstaller(location.package)
                packageState = .opened
            } catch is CancellationError {
                packageState = .cancelled
            } catch let error as HomebrewPackageError {
                packageState = Task.isCancelled ? .cancelled : .failed(error)
            } catch {
                packageState = Task.isCancelled ? .cancelled : .failed(handedToInstaller
                    ? .launch("Couldn’t open macOS Installer. The verified package has been retained. Try the official download page.")
                    : .download("Couldn’t prepare the download. Check your connection and free disk space, then retry."))
            }
        }
    }
    func cancelPackageDownload() {
        guard packageState.canCancel else { return }
        packageAttempt = nil
        packageTask?.cancel()
        packageState = .cancelled
    }
    func waitForPackageDownload() async { await packageTask?.value }
    func openDownloadPage() async {
        guard !checking else { return }
        await check()
        guard canInstall else { return }
        actionMessage = openPage(Self.downloadPage)
            ? "Download Homebrew.pkg from the official release page and complete the macOS Installer. If download or installation fails or is cancelled, Check Again will show the current state."
            : "Couldn’t open the official download page. Check your browser and connection, then try again."
    }
    func copyCommand() async {
        await check()
        guard canInstall && host.supportsTerminal else { return }
        actionMessage = copy(Self.terminalCommand) ? "Command copied. Paste and run it in Terminal when you are ready." : "Couldn’t copy the command."
    }
    func launchTerminal() async {
        await check()
        guard canInstall && host.supportsTerminal else { return }
        actionMessage = openTerminal() ? "Terminal opened. Paste and run the command yourself, then return to Check Again." : "Couldn’t open Terminal. Open it from Applications → Utilities."
    }
}

struct HomebrewSetupView: View {
    @ObservedObject var model: HomebrewSetupModel
    let notNow: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.observation?.state == .usable ? "Homebrew is installed and working."
                 : "Homebrew is needed to rebuild your applications and packages.")
                .font(.headline).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("homebrew.introduction")
            if model.observation?.state == .absent {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color(nsColor: .systemYellow)).accessibilityHidden(true)
                    Text("Homebrew is essential for restoring apps and packages. Without it, Macseed will have significantly limited functionality.")
                        .font(.callout.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(colorScheme == .dark ? Color(nsColor: .systemYellow) : Color(red: 0.44, green: 0.31, blue: 0.0))
                }.accessibilityElement(children: .combine).accessibilityIdentifier("homebrew.warning")
            }
            Text(model.host.description).font(.callout).foregroundStyle(.secondary)
            Label(model.status, systemImage: model.observation?.state == .usable ? "checkmark.circle" : "shippingbox")
                .foregroundStyle(model.observation?.state == .usable ? Color(nsColor: .systemGreen) : .primary)
                .accessibilityIdentifier("homebrew.status")
            if model.observation?.state != .absent || !model.host.supportsPackage {
                Text(model.explanation).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if model.observation?.state == .absent && model.host.supportsPackage {
                VStack(spacing: 8) {
                    Button { model.installPackage() } label: {
                        Label("Install with macOS Installer", systemImage: "arrow.down.circle")
                            .frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(!model.canDownloadPackage)
                        .accessibilityIdentifier("homebrew.packageMethod")
                    Button { model.selectMethod(.terminal) } label: {
                        Label("Install via Terminal", systemImage: "terminal")
                            .frame(maxWidth: .infinity)
                    }.buttonStyle(.bordered).controlSize(.large)
                        .disabled(!model.host.supportsTerminal).accessibilityIdentifier("homebrew.terminalMethod")
                }.disabled(!model.canInstall)
                switch model.installationMethod {
                case .package:
                    HomebrewPackageProgress(model: model)
                case .terminal:
                    VStack(alignment: .leading, spacing: 8) {
                        Text(HomebrewSetupModel.terminalCommand).font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("homebrew.command")
                        HStack {
                            Button("Copy Command") { Task { await model.copyCommand() } }.accessibilityIdentifier("homebrew.copy")
                            Button("Open Terminal") { Task { await model.launchTerminal() } }.accessibilityIdentifier("homebrew.openTerminal")
                        }.disabled(!model.canInstall)
                        Text("Paste and run the command in Terminal. The official installer explains its changes and handles authorization there.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("homebrew.terminalInstructions")
                    }
                case nil: EmptyView()
                }
            }
            if let message = model.actionMessage { Text(message).font(.callout).fixedSize(horizontal: false, vertical: true) }
            if model.startupPending {
                Toggle("Don't show this again on startup", isOn: $model.suppressReminder)
                    .toggleStyle(.checkbox).accessibilityIdentifier("homebrew.suppress")
            }
            HStack {
                Button(model.startupPending ? "Not Now" : "Done", action: notNow)
                    .keyboardShortcut(.cancelAction).accessibilityIdentifier("homebrew.notNow")
                Spacer()
                Button(model.checking ? "Checking…" : "Check Again") { Task { await model.checkAgain() } }
                    .disabled(model.checking).keyboardShortcut(.defaultAction).accessibilityIdentifier("homebrew.check")
            }
        }.padding(24).frame(width: 700).fixedSize(horizontal: false, vertical: true)
    }
}

private typealias HomebrewViewState<Value> = SwiftUI.State<Value>

struct HomebrewSetupWindow: View {
    @ObservedObject var model: HomebrewSetupModel = .shared
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @HomebrewViewState private var window: NSWindow?
    private func finish(notNow: Bool) {
        if model.finishSetup(notNow: notNow) { openWindow(id: "home") }
        dismissWindow(id: "homebrew-setup")
    }
    var body: some View {
        HomebrewSetupView(model: model, notNow: { finish(notNow: true) })
            .background(HomebrewWindowReference { native in
                window = native
                native.identifier = NSUserInterfaceItemIdentifier("homebrew-setup")
                native.isRestorable = false
                native.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            })
            .onChange(of: model.remindersEnabled) { _, enabled in model.suppressReminder = !enabled }
            .onChange(of: model.observation) { _, value in
                if value?.state == .usable && model.closesWhenAvailable { finish(notNow: false) }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
                guard let closed = notification.object as? NSWindow, closed === window else { return }
                // Native close dismisses this launch only; it never commits the checkbox.
                if model.finishSetup(notNow: false) { openWindow(id: "home") }
            }
    }
}

struct HomebrewWindowReference: NSViewRepresentable {
    let connected: (NSWindow) -> Void
    final class WindowView: NSView {
        var connected: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { DispatchQueue.main.async { [weak self, weak window] in if let window { self?.connected?(window) } } }
        }
    }
    func makeNSView(context: Context) -> WindowView { let view = WindowView(); view.connected = connected; return view }
    func updateNSView(_ view: WindowView, context: Context) { view.connected = connected }
}

struct HomebrewDependencySection: View {
    @ObservedObject var model: HomebrewSetupModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        GroupBox("External Dependencies") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Homebrew").font(.body.weight(.medium))
                        Text(model.status).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(model.settingsAction) {
                        model.beginSetup(returningTo: NSApp.keyWindow)
                        openWindow(id: "homebrew-setup")
                    }.accessibilityIdentifier("homebrew.settingsSetup")
                    Button("Check Again") { Task { await model.check() } }.disabled(model.checking)
                        .accessibilityIdentifier("homebrew.settingsCheck")
                }
                Toggle("Show Homebrew setup reminders on startup", isOn: $model.remindersEnabled)
                    .toggleStyle(.checkbox).accessibilityIdentifier("homebrew.reminders")
                if model.observation?.state != .usable {
                    Text(model.settingsExplanation).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }.padding(8)
        }.task { if model.observation == nil { await model.check() } }
    }
}

struct HomebrewPrerequisiteAction: View {
    @ObservedObject var model: HomebrewSetupModel = .shared
    @Environment(\.openWindow) private var openWindow
    let refreshPreview: () -> Void
    var body: some View {
        Button("Set Up Homebrew…") {
            model.beginSetup(rechecked: refreshPreview)
            openWindow(id: "homebrew-setup")
            Task { await model.check() }
        }.accessibilityIdentifier("homebrew.prerequisiteSetup")
    }
}

struct HomebrewPackageProgress: View {
    @ObservedObject var model: HomebrewSetupModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.packageState.title).font(.callout.weight(.medium))
                .accessibilityIdentifier("homebrew.packageState")
            switch model.packageState {
            case .downloading(let received, let total):
                ProgressView(value: Double(received), total: Double(total))
                    .accessibilityLabel("Homebrew download progress")
                    .accessibilityIdentifier("homebrew.downloadProgress")
                Text("\(ByteCountFormatter.string(fromByteCount: received, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))")
                    .font(.caption).foregroundStyle(.secondary)
            case .resolving, .verifying, .opening:
                ProgressView().controlSize(.small).accessibilityLabel(model.packageState.title)
            case .failed(let error):
                Text(error.message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            case .opened:
                Text("Complete installation in macOS Installer, which handles authorization. Then select Check Again.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            case .cancelled:
                Text("The download was cancelled. You can retry or use Terminal.")
                    .font(.callout).foregroundStyle(.secondary)
            case .idle: EmptyView()
            }
            HStack {
                if model.packageState.canCancel {
                    Button(model.packageState == .verifying ? "Cancel" : "Cancel Download") { model.cancelPackageDownload() }
                        .accessibilityIdentifier("homebrew.cancelDownload")
                } else if model.packageState.offersFallback || model.packageState == .cancelled {
                    Button("Retry") { model.installPackage() }.disabled(!model.canDownloadPackage)
                        .accessibilityIdentifier("homebrew.retryDownload")
                    if model.packageState.offersFallback {
                        Button("Open Official Download Page") { Task { await model.openDownloadPage() } }
                            .disabled(!model.canInstall).accessibilityIdentifier("homebrew.package")
                    }
                }
            }
        }
    }
}
