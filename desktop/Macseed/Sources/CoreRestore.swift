import Foundation

// Existing Protocol V1 projections only. No Bundle parsing or planning in Swift.
struct CoreRestoreInspection: Decodable {
    let formatVersion: Int
    let selectedCategories: [String]
    let selectedItemCounts: [String: Int]
    let secureComponent: Bool
    let restoreSelection: Inventory?
    enum CodingKeys: String, CodingKey {
        case formatVersion = "format_version", selectedCategories = "selected_categories"
        case selectedItemCounts = "selected_item_counts", secureComponent = "secure_component", restoreSelection = "restore_selection"
    }
    struct Inventory: Decodable {
        let groups: [Group]
        let inventory: [Area]
    }
    struct Group: Decodable, Identifiable {
        let id: String
        let domains: [String]
    }
    struct Area: Decodable, Identifiable {
        let domain: String
        let label: String
        let selectionMode: String
        let availability: String
        let reason: String?
        let items: [Item]
        var id: String { domain }
        var selectable: Bool { availability == "available" && (selectionMode == "category" || (selectionMode == "items" && !items.isEmpty)) }
        enum CodingKeys: String, CodingKey { case domain, label, selectionMode = "selection_mode", availability, reason, items }
    }
    struct Item: Decodable, Identifiable {
        let itemID: String
        let label: String
        var id: String { itemID }
        enum CodingKeys: String, CodingKey { case itemID = "item_id", label }
    }
    func validate() throws {
        guard formatVersion == 1, Set(selectedCategories).count == selectedCategories.count,
              selectedCategories.count <= 128, selectedItemCounts.count <= 128,
              selectedItemCounts.values.allSatisfy({ (0...2048).contains($0) }) else { throw CoreRuntimeError.malformedEvent }
        guard let catalog = restoreSelection, !catalog.inventory.isEmpty,
              Set(catalog.inventory.map(\.id)).count == catalog.inventory.count,
              Set(catalog.groups.map(\.id)).count == catalog.groups.count,
              catalog.inventory.count <= 128, catalog.groups.count <= 128,
              catalog.inventory.allSatisfy({ !$0.domain.isEmpty && !$0.label.isEmpty && $0.items.count <= 2048 && Set($0.items.map(\.id)).count == $0.items.count
                  && $0.items.allSatisfy { !$0.id.isEmpty && !$0.label.isEmpty } }),
              catalog.groups.allSatisfy({ !$0.id.isEmpty && Set($0.domains).count == $0.domains.count }),
              Set(catalog.groups.flatMap(\.domains)) == Set(catalog.inventory.map(\.id)),
              catalog.groups.flatMap(\.domains).count == catalog.inventory.count else {
            throw CoreRuntimeError.malformedEvent
        }
    }
}

struct CoreRestorePreparation: Decodable {
    let preparedPlanID: String
    let planDiagnostics: [String: String]?
    let selection: CoreRestoreSelection
    let selectedGroups: [String]
    let selectedCategories: [String]
    let selectedItemCounts: [String: Int]
    let includeSecure: Bool
    let secureRestoreStatus: String
    let plan: [Row]
    let readiness: Readiness
    let hasPlannedChanges: Bool
    let warningCount: Int
    let errorCount: Int
    var hasExecutableChanges: Bool { executableChanges ?? hasPlannedChanges }
    let executableChanges: Bool?
    struct Diagnostic: Decodable, Equatable {
        let primitive: String
        let condition: String
        var valid: Bool {
            [primitive, condition].allSatisfy { $0.range(of: "^[a-z][a-z0-9_]{0,63}$", options: .regularExpression) != nil }
        }
        var automationRequirement: Bool {
            primitive == "login_item" && ["authorization_required", "authorization_denied", "application_unavailable"].contains(condition)
        }
        var explanation: String {
            if automationRequirement {
                return condition == "application_unavailable"
                    ? "Macseed cannot inspect login items without System Events permission. Choose Check Again to allow access and check the current state again."
                    : condition == "authorization_denied"
                        ? "Allow Macseed → System Events in System Settings → Privacy & Security → Automation, then Check Again."
                        : "Macseed cannot inspect login items without System Events permission. Choose Check Again to allow access and check the current state again."
            }
            switch condition {
            case "foreign_target": return "This " + primitiveName + " points outside the expected application. Existing state will be preserved."
            case "conflicting_plist": return "The launch service has conflicting configuration ownership. Existing state will be preserved."
            case "identity_ambiguous", "ownership_ambiguous": return "Ownership of this " + primitiveName + " is ambiguous. Existing state will be preserved."
            case "live_ownership_unproven": return "A running launch service cannot be safely attributed to the missing application."
            case "malformed_observation", "observation_failed", "observation_limit": return "Macseed could not reliably inspect this " + primitiveName + ". Check the current state before rebuilding."
            case "unsupported_capability": return "This application requires an unsupported " + primitiveName + " capability."
            default: return "Ownership of this " + primitiveName + " could not be proven. Existing state will be preserved."
            }
        }
        private var primitiveName: String {
            switch primitive {
            case "login_item": "login item"
            case "launchctl": "launch service"
            case "payload": "application payload"
            case "historical_metadata": "installed lifecycle contract"
            default: primitive.replacingOccurrences(of: "_", with: " ")
            }
        }
        var technicalDescription: String { "primitive: " + primitive + "\ncondition: " + condition }
    }
    struct Row: Decodable {
        let domain: String
        let itemID: String
        let action: String
        let disposition: String
        let reason: String?
        let displayName: String?
        let selectionItemID: String?
        var authorizationRequired: Bool? = nil
        var diagnostic: Diagnostic? = nil
        enum CodingKeys: String, CodingKey { case diagnostic, domain, itemID = "item_id", action, disposition, reason, displayName = "display_name", selectionItemID = "selection_item_id", authorizationRequired = "authorization_required" }
    }
    struct Readiness: Decodable {
        let ready: Bool
        let readyScope: String
        let conditions: [Condition]
        let reentry: String
        enum CodingKeys: String, CodingKey { case ready, readyScope = "ready_scope", conditions, reentry }
    }
    struct Condition: Decodable, Identifiable {
        let domain: String
        let code: String
        let status: String
        let selectedItemIndex: Int?
        let scope: String?
        var diagnostic: Diagnostic? = nil
        var isItemLocal: Bool {
            scope == "item" && domain == "homebrew-casks" && code == "cask_execution_requirements_unsupported"
                && status == "unsupported" && (selectedItemIndex ?? 0) > 0
        }
        var id: String { domain + ":" + code + ":" + String(selectedItemIndex ?? 0) }
        enum CodingKeys: String, CodingKey { case diagnostic, domain, code, status, scope, selectedItemIndex = "selected_item_index" }
    }
    enum CodingKeys: String, CodingKey {
        case planDiagnostics = "plan_diagnostics"
        case selection, preparedPlanID = "prepared_plan_id", selectedGroups = "selected_groups", selectedCategories = "selected_categories"
        case selectedItemCounts = "selected_item_counts", includeSecure = "include_secure", secureRestoreStatus = "secure_restore_status"
        case plan, readiness, hasPlannedChanges = "has_planned_changes", executableChanges = "has_executable_changes", warningCount = "warning_count", errorCount = "error_count"
    }
    func isItemLocalSkip(_ row: Row) -> Bool {
        row.disposition == "blocked" && row.domain == "homebrew-casks"
            && row.reason == "cask_execution_requirements_unsupported"
            && readiness.conditions.contains { $0.isItemLocal && $0.domain == row.domain && $0.code == row.reason }
    }
    func validate(expected: CoreRestoreSelection, catalog: CoreRestoreInspection.Inventory) throws {
        guard preparedPlanID.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              !includeSecure, secureRestoreStatus == "not_selected",
              Set(selectedGroups).count == selectedGroups.count,
              selection == expected,
              Set(selectedGroups) == Set(catalog.groups.filter { !Set($0.domains).isDisjoint(with: Set(expected.categories).union(expected.items.keys)) }.map(\.id)),
              Set(selectedCategories).count == selectedCategories.count,
              selectedItemCounts.values.allSatisfy({ (0...2048).contains($0) }),
              warningCount >= 0, errorCount >= 0, plan.count <= 65536,
              readiness.readyScope == "environment", readiness.reentry == "restore_prepare",
              readiness.conditions.allSatisfy({ ["satisfied", "safely_satisfiable", "external_action_required", "unsupported"].contains($0.status) }),
              plan.allSatisfy({ ["satisfied", "planned", "blocked", "conflict", "warning", "unknown", "pending_unlock"].contains($0.disposition) }) else {
            throw CoreRuntimeError.malformedEvent
        }
        let domains = Set(expected.categories).union(expected.items.keys)
        guard plan.allSatisfy({ row in
            (row.diagnostic?.valid ?? true) && domains.contains(row.domain) && (row.selectionItemID == nil || expected.items[row.domain]?.contains(row.selectionItemID!) == true)
        }), expected.items.allSatisfy({ selectedItemCounts[$0.key] == $0.value.count }),
        selectedItemCounts.allSatisfy({ (expected.items[$0.key]?.count ?? 0) == $0.value }) else { throw CoreRuntimeError.malformedEvent }
        guard readiness.conditions.allSatisfy({ condition in
            (condition.diagnostic?.valid ?? true) && (condition.scope == nil || condition.scope == "operation" ||
                (condition.isItemLocal && (condition.selectedItemIndex ?? 0) <= (selectedItemCounts[condition.domain] ?? 0)))
        }), executableChanges == nil || hasExecutableChanges == plan.contains(where: { $0.disposition == "planned" }) else {
            throw CoreRuntimeError.malformedEvent
        }
        if readiness.ready && readiness.conditions.contains(where: { ["external_action_required", "unsupported"].contains($0.status) && !$0.isItemLocal }) {
            throw CoreRuntimeError.malformedEvent
        }
    }
}
