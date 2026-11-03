#if DEBUG
import AppKit
import SwiftUI

// Explicit opt-in for the real Debug application's startup acceptance tests.
// Only the setup model is injected. No Core environment, capability, selection,
// prerequisite or Execute result is overridden. Release contains none of this.
@MainActor enum HomebrewSetupDebug {
    @MainActor final class Configuration {
        let directory: URL
        let preferences: UserDefaults
        let suite: String
        let host: HomebrewHost
        var state: String
        var actions: [String] = []
        let appearance: String
        let packageScenario: String
        var packagePhase: String
        init?() {
            guard let index = CommandLine.arguments.firstIndex(of: "--homebrew-setup-test"), CommandLine.arguments.indices.contains(index + 1) else { return nil }
            let path = URL(fileURLWithPath: CommandLine.arguments[index + 1]).standardizedFileURL
            guard let data = try? Data(contentsOf: path),
                  let input = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let suite = input["suite"] as? String, suite.hasPrefix("org.macseed.homebrew-test."),
                  let preferences = UserDefaults(suiteName: suite),
                  let state = input["state"] as? String else { return nil }
            self.directory = path.deletingLastPathComponent(); self.preferences = preferences; self.suite = suite; self.state = state
            self.appearance = input["appearance"] as? String ?? "light"
            self.packageScenario = input["packageScenario"] as? String ?? "verification-failed"
            self.packagePhase = input["packagePhase"] as? String ?? "finish"
            host = HomebrewHost(architecture: HomebrewHost.Architecture(rawValue: input["architecture"] as? String ?? "appleSilicon") ?? .unknown,
                majorVersion: input["macOS"] as? Int ?? 26, version: String(input["macOS"] as? Int ?? 26))
            if let enabled = input["reminders"] as? Bool { preferences.set(enabled, forKey: HomebrewSetupModel.reminderKey) }
        }
        func makeModel() -> HomebrewSetupModel {
            HomebrewSetupModel(host: state == "real" ? .current() : host, preferences: preferences, detect: { [self] in
                if state == "real" { return await HomebrewSetupProbe.observe() }
                if state == "timeout" { try? await Task.sleep(nanoseconds: 150_000_000); return .unknown }
                return Self.observation(state)
            }, openPage: { [self] url in actions.append("page:" + url.absoluteString); return state != "open-failed" },
            openTerminal: { [self] in actions.append("terminal"); return true },
            copy: { [self] value in actions.append("copy:" + value); return true },
            packageService: packageService(), packageStagingBase: directory)
        }
        func packageService() -> HomebrewPackageService {
            // Every debug startup fixture has inert package dependencies, even
            // when it observes real Homebrew. Never fall through to live launch.
            HomebrewPackageService(resolve: {
                let input: [String: Any] = ["id": 1, "tag_name": "1.2.3", "draft": false, "prerelease": false,
                    "published_at": "2026-11-03T00:00:00Z", "url": "https://api.github.com/repos/Homebrew/brew/releases/1",
                    "html_url": "https://github.com/Homebrew/brew/releases/tag/1.2.3", "assets_url": "https://api.github.com/repos/Homebrew/brew/releases/1/assets",
                    "assets": [["id": 2, "name": "Homebrew.pkg", "state": "uploaded", "size": 4096,
                        "digest": "sha256:" + String(repeating: "0", count: 64), "url": "https://api.github.com/repos/Homebrew/brew/releases/assets/2",
                        "browser_download_url": "https://github.com/Homebrew/brew/releases/download/1.2.3/Homebrew.pkg"]]]
                return try HomebrewDownloadPlan.parse(JSONSerialization.data(withJSONObject: input))
            }, download: { [self] plan, file, progress in
                progress(plan.size * 4 / 10)
                while packagePhase == "downloading" { try await Task.sleep(nanoseconds: 50_000_000) }
                try Task.checkCancellation()
                try Data(repeating: 0, count: Int(plan.size)).write(to: file, options: .withoutOverwriting)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                progress(plan.size)
            }, verify: { [self] _, _ in
                while packagePhase == "verifying" { try await Task.sleep(nanoseconds: 50_000_000) }
                try Task.checkCancellation()
                guard packageScenario == "verified" else {
                    throw HomebrewPackageVerifier.assessmentUnavailable
                }
            }, openInstaller: { [self] _ in actions.append("installer:simulated") })
        }
        static func observation(_ state: String) -> HomebrewObservation {
            switch state {
            case "absent", "open-failed": .absent
            case "usable": .usable
            case "broken": .broken
            default: .unknown
            }
        }
    }
    static let configuration = Configuration()
    private static var snapshots: [[String: Any]] = []
    private static var lastSignature = ""
    private static var lastCommand = ""
    private static var commandResult = ""
    static func start() {
        guard let configuration else { return }
        NSApp.appearance = NSAppearance(named: configuration.appearance == "dark" ? .darkAqua : .aqua)
        NSApp.activate(ignoringOtherApps: true)
        Task {
            while !Task.isCancelled {
                if let data = try? Data(contentsOf: configuration.directory.appendingPathComponent("command.json")),
                   let command = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                   let id = command["id"], id != lastCommand {
                    lastCommand = id
                    commandResult = perform(command, configuration)
                }
                snapshot(configuration)
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }
    private static func nodes(_ value: Any, depth: Int = 0) -> [any NSAccessibilityProtocol] {
        guard depth < 35, let node = value as? any NSAccessibilityProtocol else { return [] }
        return [node] + (node.accessibilityChildren() ?? []).flatMap { nodes($0, depth: depth + 1) }
    }
    private static func perform(_ command: [String: String], _ configuration: Configuration) -> String {
        let windows = NSApp.windows.filter(\.isVisible)
        switch command["action"] {
        case "state": configuration.state = command["value"] ?? "unknown"; return "ok"
        case "packagePhase": configuration.packagePhase = command["value"] ?? "finish"; return "ok"
        case "appearance":
            NSApp.appearance = NSAppearance(named: command["value"] == "dark" ? .darkAqua : .aqua)
            return "ok"
        case "press":
            for window in windows {
                if let node = nodes(window).first(where: { $0.accessibilityIdentifier() == command["value"] }) {
                    return node.accessibilityPerformPress() ? "pressed" : "not actionable"
                }
            }
            return "not found"
        case "close":
            guard let window = windows.first(where: { $0.title == "Set Up Homebrew" }) else { return "not found" }
            window.performClose(nil); return "closed"
        case "key":
            guard let window = NSApp.keyWindow else { return "no key window" }
            let tab = command["value"] == "tab"
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: tab ? "\t" : "\u{1b}",
                charactersIgnoringModifiers: tab ? "\t" : "\u{1b}", isARepeat: false, keyCode: tab ? 48 : 53)!
            NSApp.sendEvent(event); return "sent"
        case "settings":
            // Exercise the app's public Settings menu item, not a fixture window.
            func open(_ menu: NSMenu) -> Bool {
                for item in menu.items {
                    if item.title.hasPrefix("Settings"), item.action != nil { NSApp.sendAction(item.action!, to: item.target, from: item); return true }
                    if let submenu = item.submenu, open(submenu) { return true }
                }
                return false
            }
            return NSApp.mainMenu.map { open($0) } == true ? "opened" : "not found"
        case "cleanup": configuration.preferences.removePersistentDomain(forName: configuration.suite); return "cleared"
        case "quit": NSApp.terminate(nil); return "quit"
        default: return "unknown command"
        }
    }
    private static func snapshot(_ configuration: Configuration) {
        func rect(_ value: NSRect) -> [String: CGFloat] {
            ["x": value.minX, "y": value.minY, "width": value.width, "height": value.height]
        }
        let windows: [[String: Any]] = NSApp.windows.filter(\.isVisible).map { window in
            let elements: [[String: Any]] = nodes(window).compactMap { node in
                guard let id = node.accessibilityIdentifier(), id.hasPrefix("homebrew.") else { return nil }
                return ["id": id, "enabled": node.isAccessibilityEnabled(), "focused": node.isAccessibilityFocused(), "label": node.accessibilityLabel() ?? "",
                        "value": String(describing: node.accessibilityValue() ?? ""), "frame": rect(node.accessibilityFrame())]
            }
            return ["title": window.title, "id": window.windowNumber, "key": window.isKeyWindow,
                    "main": window.isMainWindow, "elements": elements,
                    "frame": rect(window.frame), "contentFrame": rect(window.contentLayoutRect.offsetBy(dx: window.frame.minX, dy: window.frame.minY)),
                    "setupText": window.title == "Set Up Homebrew" ? nodes(window).filter { $0.accessibilityRole() == .staticText }.map { String(describing: $0.accessibilityValue() ?? $0.accessibilityLabel() ?? "") } : [],
                    "responder": String(describing: type(of: window.firstResponder)), "occluded": !window.occlusionState.contains(.visible)]
        }
        let model = HomebrewSetupModel.shared
        let row: [String: Any] = ["windows": windows, "status": model.status, "reminders": model.remindersEnabled,
            "packageState": model.packageState.title,
            "startupPending": model.startupPending, "canInstall": model.canInstall, "active": NSApp.isActive,
            "command": lastCommand, "commandResult": commandResult, "actions": configuration.actions,
            "coreOperation": CoreRuntime.shared.operation?.rawValue ?? "none", "coreActive": CoreRuntime.shared.isActive,
            "homeWindowsCreated": NSApp.windows.filter { $0.title == "Macseed" }.count]
        if let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]),
           let signature = String(data: data, encoding: .utf8) {
            if signature != lastSignature { snapshots.append(row); lastSignature = signature }
            try? data.write(to: configuration.directory.appendingPathComponent("state.json"), options: .atomic)
        }
        if let data = try? JSONSerialization.data(withJSONObject: snapshots, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: configuration.directory.appendingPathComponent("trace.json"), options: .atomic)
        }
    }
}
#endif
