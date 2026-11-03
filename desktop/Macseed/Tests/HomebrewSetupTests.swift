import AppKit
import SwiftUI

@main struct HomebrewSetupTests {
    @MainActor static func main() async throws {
        let suite = "org.macseed.homebrew-test.unit." + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let host = HomebrewHost(architecture: .appleSilicon, majorVersion: 26, version: "26")
        var next = HomebrewObservation.absent, opened: [String] = [], refreshes = 0
        let model = HomebrewSetupModel(host: host, preferences: preferences, detect: { next },
            openPage: { opened.append($0.absoluteString); return true },
            openTerminal: { opened.append("Terminal"); return true }, copy: { opened.append($0); return true })
        await model.prepareLaunch()
        precondition(model.launchOffersSetup && model.startupPending && model.remindersEnabled && !model.suppressReminder)
        precondition(model.finishSetup(notNow: true) && model.remindersEnabled && !model.launchOffersSetup)
        model.beginSetup(); model.suppressReminder = true
        _ = model.finishSetup(notNow: false)
        precondition(model.remindersEnabled, "Native close must not save suppression")
        model.beginSetup(); model.suppressReminder = true; _ = model.finishSetup(notNow: true)
        precondition(model.remindersEnabled, "Manual Done must not save a startup preference")
        await model.prepareLaunch()
        model.suppressReminder = true; _ = model.finishSetup(notNow: true)
        let relaunched = HomebrewSetupModel(host: host, preferences: preferences, detect: { .absent })
        await relaunched.prepareLaunch()
        precondition(!relaunched.remindersEnabled && !relaunched.launchOffersSetup)
        relaunched.beginSetup(); await relaunched.check()
        precondition(relaunched.canInstall, "Suppression never prevents manual setup")
        _ = relaunched.finishSetup(notNow: true)
        precondition(!relaunched.remindersEnabled, "Manual Done must preserve disabled reminders too")
        model.remindersEnabled = true
        model.beginSetup()
        precondition(model.installationMethod == nil && !model.closesWhenAvailable)
        model.selectMethod(.terminal)
        precondition(model.installationMethod == .terminal)
        model.selectMethod(.package)
        precondition(model.installationMethod == .package)
        model.beginSetup()
        precondition(model.installationMethod == nil && model.settingsAction == "Install…")
        for architecture in [HomebrewHost.Architecture.appleSilicon, .intel, .unknown] {
            for version in [14, 15, 26, 27, 28] {
                let platform = HomebrewHost(architecture: architecture, majorVersion: version, version: String(version))
                let supported = architecture == .appleSilicon && (15..<28).contains(version)
                precondition(platform.supportsPackage == supported && platform.supportsTerminal == supported)
                for observation in [HomebrewObservation.absent, .usable, .broken, .unknown] {
                    let fixture = HomebrewSetupModel(host: platform, preferences: preferences, detect: { observation })
                    await fixture.prepareLaunch()
                    precondition(fixture.launchOffersSetup == (supported && observation == .absent))
                    fixture.selectMethod(.terminal)
                    precondition((fixture.installationMethod != nil) == (supported && observation == .absent))
                }
            }
        }
        model.beginSetup(rechecked: { refreshes += 1 })
        next = .usable; await model.checkAgain()
        precondition(refreshes == 1 && model.observation == .usable && model.closesWhenAvailable)
        model.beginSetup()
        precondition(model.settingsAction == "Setup…" && !model.closesWhenAvailable && model.installationMethod == nil)
        await model.openDownloadPage(); await model.copyCommand(); await model.launchTerminal()
        precondition(opened.isEmpty, "Stale absence must not admit an install action")
        next = .absent
        await model.openDownloadPage(); await model.copyCommand(); await model.launchTerminal()
        precondition(opened == [HomebrewSetupModel.downloadPage.absoluteString, HomebrewSetupModel.terminalCommand, "Terminal"])
        precondition(model.observation == .absent)
        model.selectMethod(.package)
        precondition(model.actionMessage == nil, "Switching methods clears the previous method's feedback")
        next = .broken; await model.checkAgain(); precondition(!model.canInstall && model.status == "Broken")
        precondition(model.installationMethod == nil && model.settingsAction == "Details…")
        next = .unknown; await model.checkAgain(); precondition(!model.canInstall && model.status == "Unknown")
        let failed = HomebrewSetupModel(host: host, preferences: preferences, detect: { .absent }, openPage: { _ in false })
        await failed.openDownloadPage(); precondition(failed.actionMessage!.contains("Couldn’t"))

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("macseed-homebrew-native-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let installation = HomebrewSetupProbe.Installation(prefix: root.path, repository: root.path)
        precondition(HomebrewSetupProbe.inspect(installations: [installation], searchDirectories: []).state == .absent)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        precondition(HomebrewSetupProbe.inspect(installations: [installation], searchDirectories: []).state == .broken)
        for directory in ["bin", "Library/Homebrew"] { try FileManager.default.createDirectory(at: root.appendingPathComponent(directory), withIntermediateDirectories: true) }
        let executable = root.appendingPathComponent("bin/brew")
        func script(_ value: String) throws {
            try ("#!/bin/sh\n" + value).write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }
        try Data().write(to: root.appendingPathComponent("Library/Homebrew/brew.sh"))
        try script("case \"$1\" in --version) echo 'Homebrew fixture' ;; --prefix) echo '\(root.path)' ;; esac\n")
        precondition(HomebrewSetupProbe.inspect(installations: [installation], searchDirectories: []) == .usable)
        precondition(HomebrewSetupProbe.inspect(installations: [], searchDirectories: [root.appendingPathComponent("bin").path]) == .unknown,
                     "An untrusted PATH candidate must not become confirmed absence")
        try script("exit 2\n")
        precondition(HomebrewSetupProbe.inspect(installations: [installation], searchDirectories: []) == .broken)
        try script("sleep 5\n")
        let start = ProcessInfo.processInfo.systemUptime
        precondition(!NativeHomebrewRead.run(executable.path, "--version", timeout: 0.1).complete)
        precondition(ProcessInfo.processInfo.systemUptime - start < 2)
        try script("(trap '' TERM; sleep 5) &\necho 'Homebrew fixture'\n")
        precondition(!NativeHomebrewRead.run(executable.path, "--version", timeout: 0.1).complete)
        try script("while :; do echo 'unbounded-output'; done\n")
        precondition(!NativeHomebrewRead.run(executable.path, "--version", timeout: 0.2).complete)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: executable.path)
        precondition(HomebrewSetupProbe.inspect(installations: [installation], searchDirectories: []) == .unknown)
        try FileManager.default.removeItem(at: executable)
        try FileManager.default.createSymbolicLink(at: executable, withDestinationURL: URL(fileURLWithPath: "/bin/echo"))
        precondition(HomebrewSetupProbe.inspect(installations: [installation], searchDirectories: []) == .unknown)
        print("PASS: platform/state matrix; reminders and close semantics; shared fresh checks; explicit external actions; canonical installation trust; bounded native reads, output limits and child cleanup. No real installation.")
    }
}
