import AppKit
import Foundation

@main struct SettingsTests {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        guard CommandLine.arguments.count == 4 else {
            fputs("Usage: SettingsTests <core-root> <python> <app-bundle>\n", stderr)
            exit(2)
        }
        let fm = FileManager.default
        let repository = URL(fileURLWithPath: CommandLine.arguments[1])
        let python = URL(fileURLWithPath: CommandLine.arguments[2])
        let sourceApplication = URL(fileURLWithPath: CommandLine.arguments[3])
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        let root = URL(fileURLWithPath: "/private/tmp/macseed-settings-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: root) }
        let application = root.appendingPathComponent("Fixture.app")
        let helper = application.appendingPathComponent("Contents/Helpers/age")
        let resources = application.appendingPathComponent("Contents/Resources")
        try fm.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: resources, withIntermediateDirectories: false)
        let original = try Data(contentsOf: sourceApplication.appendingPathComponent("Contents/Helpers/age"))
        try original.write(to: helper); try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let descriptor: [String: Any] = ["Version": 1, "Mode": "development", "CoreRoot": repository.path, "PythonExecutable": python.path]
        try PropertyListSerialization.data(fromPropertyList: descriptor, format: .xml, options: 0).write(to: resources.appendingPathComponent("CoreRuntime.plist"))
        let location = try CoreLocationResolver(resources: resources).resolve()
        func inspect() async -> BundledAgeObservation {
            await Task.detached { BundledAgeSettingsProbe.inspect(location: location) }.value
        }
        func snapshot() throws -> [String: Data] {
            var result: [String: Data] = [:]
            for url in [application] + ((fm.enumerator(at: application, includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? []) {
                var info = stat(); precondition(lstat(url.path, &info) == 0)
                var value = Data("\(info.st_dev):\(info.st_ino):\(info.st_mode):\(info.st_uid):\(info.st_nlink):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)".utf8)
                if info.st_mode & S_IFMT == S_IFREG { value += try Data(contentsOf: url) }
                result[url.path] = value
            }
            return result
        }
        let before = try snapshot()
        let observed = await inspect()
        precondition(observed == .init(status: .available, version: "v1.3.2", architecture: architecture))
        precondition(try! snapshot() == before, "Read-only inspection changed bundle")
        print("PASS: production CoreLocationResolver -> bounded reader -> Core age inspector reports verified v1.3.2 \(architecture) without modifying app")

        let fake = root.appendingPathComponent("age"), marker = root.appendingPathComponent("executed")
        try Data(("#!/bin/sh\ntouch '" + marker.path + "'\nexit 99\n").utf8).write(to: fake)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let path = ProcessInfo.processInfo.environment["PATH"]
        setenv("PATH", root.path + ":/opt/homebrew/bin:/usr/bin:/bin", 1)
        defer { if let path { setenv("PATH", path, 1) } else { unsetenv("PATH") } }
        let withFake = await inspect(); precondition(withFake == observed)
        try fm.removeItem(at: helper)
        let failure0 = await inspect(); precondition(failure0.status == .missing)
        try Data("tampered".utf8).write(to: helper); try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let failure1 = await inspect(); precondition(failure1.status == .invalid)
        try fm.removeItem(at: helper); try fm.createSymbolicLink(at: helper, withDestinationURL: fake)
        let failure2 = await inspect(); precondition(failure2.status == .invalid)
        precondition(!fm.fileExists(atPath: marker.path), "Inspector executed an external or untrusted age")
        try fm.removeItem(at: helper); try original.write(to: helper); try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let missingRuntime = CoreLocation(root: root, python: python, applicationBundle: application)
        precondition(BundledAgeSettingsProbe.inspect(location: missingRuntime).status == .unableToVerify)
        let unbound = CoreLocation(root: repository, python: python)
        precondition(BundledAgeSettingsProbe.inspect(location: unbound).status == .unableToVerify)
        print("PASS: Missing/Invalid/Unable to Verify are distinct; fake inherited PATH and linked age never execute; absent app binding cannot use CLI fallback")

        for output in ["not JSON", "{}", "{\"schema_version\":1,\"status\":\"available\"}",
                       "{\"schema_version\":1,\"status\":\"available\",\"version\":\"/private/path\",\"architecture\":\"arm64\"}",
                       "{\"schema_version\":1,\"status\":\"missing\",\"version\":\"v1.3.2\"}"] {
            precondition(BundledAgeObservation.decode(.init(output: output, exitCode: 0, complete: true)).status == .unableToVerify)
        }
        let valid = "{\"schema_version\":1,\"status\":\"available\",\"version\":\"v1.3.2\",\"architecture\":\"arm64\"}"
        precondition(BundledAgeObservation.decode(.init(output: valid, exitCode: 0, complete: false)).status == .unableToVerify)
        precondition(BundledAgeObservation.decode(.init(output: valid, exitCode: 2, complete: true)).status == .unableToVerify)
        var count = 0, next = observed
        var pause: CheckedContinuation<Void, Never>?
        var hold = false
        let model = BundledAgeSettingsModel {
            count += 1
            if hold { await withCheckedContinuation { pause = $0 } }
            return next
        }
        precondition(model.status == "Not Checked" && model.identity == "Bundled")
        await model.checkIfNeeded(); await model.checkIfNeeded()
        precondition(count == 1 && model.status == "Available" && model.identity == "Bundled · v1.3.2 · \(architecture)")
        next = .init(status: .invalid); hold = true
        let pending = Task { await model.check() }
        while !model.checking { await Task.yield() }
        precondition(model.observation == nil && model.status == "Checking…")
        await model.check(); pause!.resume(); await pending.value
        precondition(count == 2 && !model.checking && model.status == "Invalid" && model.identity == "Bundled")
        precondition(model.explanation != nil)
        print("PASS: strict diagnostic decoding; one initial check, explicit recheck, coalesced concurrent requests, no stale Available metadata")

        let suite = "macseed.settings.fixture." + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let host = HomebrewHost(architecture: .appleSilicon, majorVersion: 27, version: "27.2")
        var homebrewCalls = 0, externalActions = 0, brew = HomebrewObservation.usable
        let homebrew = HomebrewSetupModel(host: host, preferences: preferences,
            detect: { homebrewCalls += 1; return brew }, openPage: { _ in externalActions += 1; return true },
            openTerminal: { externalActions += 1; return true }, copy: { _ in externalActions += 1; return true }, packageStagingBase: root.appendingPathComponent("packages"))
        await homebrew.check()
        precondition(homebrew.status == "Available" && homebrew.settingsAction == "Setup…")
        homebrew.remindersEnabled = false
        let reopened = HomebrewSetupModel(host: host, preferences: preferences, detect: { .absent }, packageStagingBase: root.appendingPathComponent("packages"))
        precondition(!reopened.remindersEnabled)
        homebrew.beginSetup(); precondition(!homebrew.closesWhenAvailable && !homebrew.startupPending)
        precondition(homebrew.finishSetup(notNow: false) == false && !homebrew.remindersEnabled)
        brew = .absent; await homebrew.check()
        precondition(homebrew.settingsAction == "Install…")
        brew = .broken; await homebrew.check(); precondition(homebrew.settingsAction == "Details…")
        brew = .unknown; await homebrew.check(); precondition(homebrew.status == "Unknown")
        precondition(homebrewCalls == 4 && externalActions == 0)
        print("PASS: reused Homebrew status/Setup/Check Again model, manual return semantics and reminder persistence; no install/update action")
    }
}
