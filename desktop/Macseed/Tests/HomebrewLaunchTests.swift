import Foundation

// Mirrors the real app's synchronous entry stack, including an actually suspended
// MainActor observation. The full app startup/geometry gate is a separate test.
@main struct HomebrewLaunchTests {
    @MainActor static func main() {
        let suite = "org.macseed.homebrew-test.launch." + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let host = HomebrewHost(architecture: .appleSilicon, majorVersion: 26, version: "26")
        let model = HomebrewSetupModel(host: host, preferences: preferences, detect: {
            try? await Task.sleep(nanoseconds: 50_000_000)
            return .absent
        })
        HomebrewStartupGate.prepare(model)
        precondition(Thread.isMainThread && model.launchOffersSetup && model.observation == .absent)
        var responsive = false
        Task { responsive = true }
        let deadline = Date().addingTimeInterval(1)
        while !responsive && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        precondition(responsive, "The startup observation must release MainActor before App.main")
        let timeout = HomebrewSetupModel(host: host, preferences: preferences, detect: {
            try? await Task.sleep(nanoseconds: 100_000_000)
            return .absent
        })
        HomebrewStartupGate.prepare(timeout, timeout: 0.02)
        precondition(timeout.observation == .unknown && !timeout.launchOffersSetup)
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        precondition(!timeout.launchOffersSetup && !timeout.startupPending, "Late completion cannot present setup over Home")
        print("PASS: suspended startup check releases MainActor on main-thread entry; finite deadline opens Home as Unknown; late completion cannot offer setup")
    }
}
