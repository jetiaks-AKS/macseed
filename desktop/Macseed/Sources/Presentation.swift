import Foundation
import SwiftUI
import AppKit

enum DesktopAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    static let preferenceKey = "desktopAppearance"
    init(storedValue: String?) { self = storedValue.flatMap(Self.init(rawValue:)) ?? .system }
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var appearanceName: NSAppearance.Name? {
        switch self { case .system: nil; case .light: .aqua; case .dark: .darkAqua }
    }
    @MainActor func apply(to application: NSApplication) {
        // AppKit owns appearance. SwiftUI hosts and native dialogs inherit it;
        // preferredColorScheme would introduce a second window-level override.
        application.appearance = appearanceName.flatMap(NSAppearance.init(named:))
        for window in application.windows { inheritAppearance(window) }
    }
    @MainActor private func inheritAppearance(_ window: NSWindow) {
        window.appearance = nil
        for sheet in window.sheets { inheritAppearance(sheet) }
    }
}

// Preserve existing navigation keys; user-facing copy comes from title/subtitle.
enum ProductTask: String, CaseIterable, Identifiable {
    case capture = "Capture this Mac"
    case restore = "Restore a Mac"
    case status = "Environment Status"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .capture: "Capture"
        case .restore: "Rebuild"
        case .status: "Check"
        }
    }
    var symbol: String {
        switch self {
        case .capture: "cube"
        case .restore: "arrow.down.doc"
        case .status: "checkmark.circle"
        }
    }
    var subtitle: String {
        switch self {
        case .capture: "Capture apps, settings, and workspace."
        case .restore: "Rebuild from a saved environment."
        case .status: "Check a saved environment."
        }
    }
}

enum DisplayStatus: String {
    case ready = "Ready"
    case matching = "Already Matches"
    case missing = "Missing"
    case different = "Different"
    case unverified = "Unverified"
    case unresolved = "Unresolved"
    case extra = "Extra"
    case excluded = "Excluded"
    case noRequirement = "No Requirement"
    case information = "Information"
    case attention = "Needs Attention"
    case verified = "Verified"
    case unsupported = "Not Supported"
    case waiting = "Waiting"
    case working = "Restoring"
    case complete = "Complete"
    var symbol: String {
        switch self {
        case .ready, .verified, .matching, .complete: "checkmark.circle"
        case .attention: "exclamationmark.triangle"
        case .missing, .different, .unverified, .unresolved: "exclamationmark.triangle"
        case .extra: "info.circle"
        case .excluded, .noRequirement: "minus.circle"
        case .information: "info.circle"
        case .unsupported: "minus.circle"
        case .waiting: "clock"
        case .working: "arrow.triangle.2.circlepath"
        }
    }
}

struct DisplayItem: Identifiable, Equatable {
    let id: String
    let title: String
    let status: DisplayStatus
    let action: String
    var reason: String? = nil
    var restoreReadyText: String? = nil
    var restoreActivity: String? = nil
    var pathHelp: String? = nil
}

// Only validated HOME-relative Script paths reach this display projection.
// Reuse the consent dialog's shortest unique suffix rule on every screen.
enum ShellScriptPresentation {
    static func title(_ path: String, paths: [String]) -> String {
        let parts = path.split(separator: "/")
        let unique = Set(paths)
        for count in 1...parts.count {
            let suffix = parts.suffix(count).joined(separator: "/")
            if unique.filter({ $0 == suffix || $0.hasSuffix("/" + suffix) }).count == 1 { return suffix }
        }
        return path
    }
}

struct DisplayCategory: Identifiable, Equatable {
    let id: String
    let title: String
    let symbol: String
    let items: [DisplayItem]
}

// Native display only. Never reorder Core records, selections or source bytes.
enum ShellDefinitionPresentation {
    static func kind(_ identity: String) -> String? {
        let id = identity.hasPrefix("shell-zsh:") ? String(identity.dropFirst("shell-zsh:".count)) : identity
        if id.range(of: "^shell-alias:[0-9a-f]{64}\\z", options: .regularExpression) != nil { return "Alias" }
        if id.range(of: "^shell-function:[0-9a-f]{64}\\z", options: .regularExpression) != nil { return "Function" }
        return nil
    }
    static func title(domain: String, id: String, name: String) -> String {
        guard domain == "shell-zsh", let kind = kind(id) else { return name }
        let prefix = kind + ": "
        if name.hasPrefix(prefix) { return name }
        let missing = ["Shell alias", "Shell function", "Private item", id].contains(name)
        return prefix + (missing ? "Name unavailable" : name)
    }
    static func ordered<T>(_ values: [T], domain: String, id: (T) -> String, name: (T) -> String) -> [T] {
        guard domain == "shell-zsh" else { return values }
        func key(_ value: T) -> (Int, String) {
            guard let kind = kind(id(value)) else { return (2, "") }
            let label = name(value), prefix = kind + ": "
            return (kind == "Alias" ? 0 : 1, label.hasPrefix(prefix) ? String(label.dropFirst(prefix.count)) : label)
        }
        return values.enumerated().sorted { left, right in
            let a = key(left.element), b = key(right.element)
            if a.0 != b.0 { return a.0 < b.0 }
            if a.0 == 2 { return left.offset < right.offset }
            if a.1 != b.1 { return a.1.utf8.lexicographicallyPrecedes(b.1.utf8) }
            if id(left.element) != id(right.element) { return id(left.element) < id(right.element) }
            return left.offset < right.offset
        }.map(\.element)
    }
}

extension CoreRestoreInspection.Area {
    var displayItems: [CoreRestoreInspection.Item] {
        ShellDefinitionPresentation.ordered(items, domain: id, id: { $0.id }, name: { $0.label }).map {
            .init(itemID: $0.id, label: ShellDefinitionPresentation.title(domain: id, id: $0.id, name: $0.label))
        }
    }
}

struct DisplayPrerequisite: Equatable {
    let title: String
    let instructions: String
    let reason: String
}

struct DisplayProgress: Equatable {
    let phase: String
    let subject: String
    let processed: Int
    let categories: [DisplayItem]
}

struct DisplayResult: Equatable {
    let title: String
    let message: String
    let readyCount: Int?
    let attentionCount: Int?
    let details: [DisplayItem]
}

enum BuildFeatures {
    static var sampleExperience: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }
}

// Checkbox presentation derived from selected child IDs, not Core selection semantics.
enum SelectionState: Equatable {
    case none, mixed, all
    static func summarize(selected: Set<String>, children: [String]) -> SelectionState {
        let count = children.filter { selected.contains($0) }.count
        if count == 0 { return .none }
        return count == children.count ? .all : .mixed
    }
}

extension DisplayResult {
    var attentionDetails: [DisplayItem] {
        details.filter(\.requiresAttention)
    }
    var detailsInitiallyExpanded: Bool { false }
}

extension SelectionState {
    var bulkActionTitle: String { self == .all ? "Deselect All" : "Select All" }
}

extension DisplayItem {
    var requiresAttention: Bool {
        [.attention, .unsupported, .missing, .different, .unverified, .unresolved, .extra].contains(status)
    }
}

extension DisplayCategory {
    var hasAttention: Bool { items.contains(where: \.requiresAttention) }
}
