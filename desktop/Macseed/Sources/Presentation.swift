import Foundation

// Display values only. Future Protocol mapping belongs outside the views.
enum ProductTask: String, CaseIterable, Identifiable {
    case capture = "Capture this Mac"
    case restore = "Restore a Mac"
    case status = "Environment Status"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .capture: "shippingbox"
        case .restore: "arrow.down.doc"
        case .status: "checkmark.circle"
        }
    }
    var subtitle: String {
        switch self {
        case .capture: "Save supported settings and tools for another Mac."
        case .restore: "Review a saved environment and rebuild this Mac."
        case .status: "Compare this Mac with a saved configuration."
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
}

struct DisplayCategory: Identifiable, Equatable {
    let id: String
    let title: String
    let symbol: String
    let items: [DisplayItem]
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
