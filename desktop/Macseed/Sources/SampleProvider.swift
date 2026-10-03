#if DEBUG
import Foundation

// Deterministic fixtures, never an observer/planner or production fallback.
enum SampleProvider {
    static let capture: [DisplayCategory] = [
        category("applications", "Applications", "app", ["Firefox", "IINA"]),
        category("homebrew", "Homebrew", "shippingbox", ["git", "ffmpeg", "jq"]),
        category("macos", "macOS Settings", "slider.horizontal.3", ["Show filename extensions", "Tap to click", "Screenshot format"]),
        category("git", "Git", "arrow.triangle.branch", ["Global Git settings"]),
        category("ssh", "SSH", "network", ["SSH host configuration"]),
        category("vscode", "VS Code", "chevron.left.forwardslash.chevron.right", ["Settings", "Extensions"]),
        category("workspace", "Workspace", "folder", ["Project folders", "Sample repository"])
    ]
    static let identities = ["Personal SSH key", "Work SSH key"]
    static let prerequisite = DisplayPrerequisite(
        title: "Homebrew is required for selected items.",
        instructions: "In the real app, install Homebrew externally, then check again. This preview runs no commands. Check Again loads a sample where Homebrew is available.",
        reason: "homebrew_unavailable")

    static func category(_ id: String, _ title: String, _ symbol: String,
                         _ names: [String]) -> DisplayCategory {
        DisplayCategory(id: id, title: title, symbol: symbol, items: names.enumerated().map {
            DisplayItem(id: "\(id)-\($0.offset)", title: $0.element, status: .ready, action: "Include in Bundle")
        })
    }

    // Exactly the Protocol V1 Restore groups. Item rows are read-only.
    static func restore(_ bundle: String) -> [DisplayCategory] {
        let groups: [(String, String, String, DisplayStatus, String)] = [
            ("Applications", "app", bundle == "A" ? "Firefox" : "IINA", .matching, "No change needed"),
            ("VS Code Settings", "chevron.left.forwardslash.chevron.right", "Editor settings", .ready, "Replace with backup"),
            ("Homebrew", "shippingbox", "ffmpeg", .ready, "Install"),
            ("macOS Settings", "slider.horizontal.3", "Keyboard preference", .ready, "Set preference"),
            ("Shell", "terminal", "Zsh configuration", .matching, "No change needed"),
            ("Git", "arrow.triangle.branch", "Global Git settings", .matching, "No change needed"),
            ("SSH Configuration", "network", "SSH host configuration", .matching, "No change needed"),
            ("Workspace", "folder", "Sample repository", .attention, "Inspect existing destination")
        ]
        return groups.map { group in
            DisplayCategory(id: group.0, title: group.0, symbol: group.1, items: [
                DisplayItem(id: group.0, title: group.2, status: group.3, action: group.4,
                            reason: group.3 == .attention ? "destination_conflict" : nil)
            ])
        }
    }

    static let progress: [DisplayProgress] = [
        DisplayProgress(phase: "Rebuilding", subject: "Preparing selected changes", processed: 0, categories: [
            DisplayItem(id: "apps", title: "Applications", status: .working, action: "Inspecting"),
            DisplayItem(id: "brew", title: "Homebrew", status: .waiting, action: "Waiting"),
            DisplayItem(id: "settings", title: "macOS Settings", status: .waiting, action: "Waiting")
        ]),
        DisplayProgress(phase: "Rebuilding", subject: "Installing ffmpeg…", processed: 2, categories: [
            DisplayItem(id: "apps", title: "Applications", status: .complete, action: "Processed"),
            DisplayItem(id: "brew", title: "Homebrew", status: .working, action: "Installing ffmpeg"),
            DisplayItem(id: "settings", title: "macOS Settings", status: .waiting, action: "Waiting")
        ]),
        DisplayProgress(phase: "Checking results", subject: "Checking selected supported requirements", processed: 3, categories: [
            DisplayItem(id: "apps", title: "Applications", status: .complete, action: "Processed"),
            DisplayItem(id: "brew", title: "Homebrew", status: .complete, action: "Processed"),
            DisplayItem(id: "settings", title: "macOS Settings", status: .complete, action: "Processed")
        ])
    ]

    static func completion(selection: Set<String>) -> DisplayResult {
        // Project fixed per-group sample evidence, never observe or verify the Mac.
        let details = restore("A").filter { selection.contains($0.id) }.map { category in
            DisplayItem(id: category.id, title: category.title,
                        status: category.id == "Workspace" ? .attention : .verified,
                        action: category.id == "Workspace" ? "Existing destination needs inspection" : "Selected supported requirement checked",
                        reason: category.id == "Workspace" ? "destination_conflict" : nil)
        }
        let attention = selection.contains("Workspace")
        return DisplayResult(title: attention ? "Rebuild completed with attention needed." : "Your environment is ready.",
                             message: attention ? "Review the remaining issue before another rebuild." : "Everything selected was restored successfully.",
                             readyCount: details.filter { $0.status == .verified }.count,
                             attentionCount: attention ? 1 : 0, details: details)
    }

    static let status: [DisplayCategory] = [
        DisplayCategory(id: "apps", title: "Applications", symbol: "app", items: [
            DisplayItem(id: "firefox", title: "Firefox", status: .matching, action: "Matches saved requirement")]),
        DisplayCategory(id: "macos", title: "macOS Settings", symbol: "slider.horizontal.3", items: [
            DisplayItem(id: "keyboard", title: "Keyboard preference", status: .attention,
                        action: "Different from saved requirement", reason: "stored_preference_mismatch")]),
        DisplayCategory(id: "ssh", title: "SSH", symbol: "network", items: [
            DisplayItem(id: "identity", title: "SSH authentication", status: .unsupported,
                        action: "Network authentication is not checked", reason: "runtime_authentication_not_supported")])
    ]
}
#endif
