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
        var sourcePresent: Bool? = nil
        var captureSelected: Bool? = nil
        let reason: String?
        let items: [Item]
        var id: String { domain }
        var selectable: Bool { availability == "available" && (selectionMode == "category" || (selectionMode == "items" && !items.isEmpty)) }
        enum CodingKeys: String, CodingKey { case domain, label, selectionMode = "selection_mode", availability, reason, items, sourcePresent = "source_present", captureSelected = "capture_selected" }
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
    var effectiveSelection: CoreRestoreSelection? = nil
    var applicationDuplicates: [ApplicationDuplicate]? = nil
    struct ApplicationDuplicate: Decodable {
        let appStoreItemID: String
        let caskItemID: String
        enum CodingKeys: String, CodingKey {
            case appStoreItemID = "app_store_item_id", caskItemID = "cask_item_id"
        }
    }
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
    var scopeWarnings: [String]? = nil
    var hasExecutableChanges: Bool { executableChanges ?? hasPlannedChanges }
    let executableChanges: Bool?
    struct Diagnostic: Decodable, Equatable {
        let primitive: String
        let condition: String
        var stage: String? = nil
        var predicate: String? = nil
        var reasonCode: String? = nil
        enum CodingKeys: String, CodingKey {
            case primitive, condition, stage, predicate, reasonCode = "reason_code"
        }
        private func safeCode(_ value: String?) -> String? {
            guard let value, value.range(of: "^[a-z][a-z0-9_]{0,63}$", options: .regularExpression) != nil else { return nil }
            return value
        }
        var repairExplanation: String? {
            if condition == "provider_conflict" { return explanation }
            if safeCode(reasonCode) == "script_effects_unbounded" {
                return "Macseed could not verify that the installer's scripts are safe to run again. Review the official installer’s instructions before restoring the application manually."
            }
            switch condition {
            case "ownership_unproven", "ownership_ambiguous", "live_ownership_unproven", "identity_ambiguous":
                return "Macseed could not verify ownership of components that Repair may change or remove. Review the existing installation or restore it manually using the official installer, then Refresh Preview."
            case "foreign_target", "conflicting_plist":
                return "Existing components conflict with the expected installation. Review the conflict before restoring the application manually using the official installer."
            default: return nil
            }
        }
        var valid: Bool {
            [primitive, condition].allSatisfy { $0.range(of: "^[a-z][a-z0-9_]{0,63}$", options: .regularExpression) != nil }
        }
        var automationRequirement: Bool {
            primitive == "login_item" && ["authorization_required", "authorization_denied", "application_unavailable"].contains(condition)
        }
        var automationPreparationAvailable: Bool {
            automationRequirement && condition != "authorization_denied"
        }
        var explanation: String {
            if primitive == "rosetta" && condition == "installation_required" {
                return "Rosetta is required for this application. Install it manually in Terminal with softwareupdate --install-rosetta, follow Apple's prompts, then Refresh Preview. Macseed does not install Rosetta."
            }
            if automationRequirement {
                return condition == "application_unavailable"
                    ? "Macseed cannot inspect login items without System Events permission. Choose Fix Issues… to allow access and check the current state again."
                    : condition == "authorization_denied"
                        ? "Allow Macseed → System Events in System Settings → Privacy & Security → Automation, then Refresh Preview."
                        : "Macseed cannot inspect login items without System Events permission. Choose Fix Issues… to allow access and check the current state again."
            }
            switch condition {
            case "provider_conflict": return "An App Store receipt marker exists at this Homebrew target. Distribution ownership is uncertain, so the application is preserved. Exclude this Homebrew item in Selection or resolve the installation source before retrying."
            case "preparation_required": return "Installer preparation required before this application can be restored."
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
            case "rosetta": "Rosetta availability"
            case "payload": "application payload"
            case "historical_metadata": "installed lifecycle contract"
            default: primitive.replacingOccurrences(of: "_", with: " ")
            }
        }
        var technicalDescription: String {
            var lines = ["primitive: " + primitive, "condition: " + condition]
            for (key, value) in [("stage", stage), ("predicate", predicate), ("reason_code", reasonCode)] {
                if let value = safeCode(value) { lines.append(key + ": " + value) }
            }
            return lines.joined(separator: "\n")
        }
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
        var installerPreparationID: String? = nil
        var unsupportedRepairExplanation: String? {
            guard domain == "homebrew-casks", action == "reinstall",
                  !["planned", "satisfied"].contains(disposition),
                  diagnostic?.automationRequirement != true,
                  diagnostic?.primitive != "rosetta",
                  diagnostic?.condition != "preparation_required" else { return nil }
            return diagnostic?.repairExplanation
                ?? "Automatic repair is unavailable. Macseed could not verify that the operation is safe."
        }
        enum CodingKeys: String, CodingKey { case installerPreparationID = "installer_preparation_id", diagnostic, domain, itemID = "item_id", action, disposition, reason, displayName = "display_name", selectionItemID = "selection_item_id", authorizationRequired = "authorization_required" }
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
            scope == "item" && domain == "homebrew-casks" && ["cask_execution_requirements_unsupported", "cask_target_conflict", "cask_rosetta_required"].contains(code)
                && (status == "unsupported" || (code == "cask_rosetta_required" && status == "external_action_required")) && (selectedItemIndex ?? 0) > 0
        }
        var id: String { domain + ":" + code + ":" + String(selectedItemIndex ?? 0) }
        enum CodingKeys: String, CodingKey { case diagnostic, domain, code, status, scope, selectedItemIndex = "selected_item_index" }
    }
    enum CodingKeys: String, CodingKey {
        case effectiveSelection = "effective_selection", applicationDuplicates = "application_duplicates"
        case scopeWarnings = "scope_warnings"
        case planDiagnostics = "plan_diagnostics"
        case selection, preparedPlanID = "prepared_plan_id", selectedGroups = "selected_groups", selectedCategories = "selected_categories"
        case selectedItemCounts = "selected_item_counts", includeSecure = "include_secure", secureRestoreStatus = "secure_restore_status"
        case plan, readiness, hasPlannedChanges = "has_planned_changes", executableChanges = "has_executable_changes", warningCount = "warning_count", errorCount = "error_count"
    }
    func isItemLocalSkip(_ row: Row) -> Bool {
        row.disposition == "blocked" && row.domain == "homebrew-casks"
            && ["cask_execution_requirements_unsupported", "cask_target_conflict", "cask_rosetta_required"].contains(row.reason ?? "")
            && readiness.conditions.contains { $0.isItemLocal && $0.domain == row.domain && $0.code == row.reason }
    }
    func validate(expected: CoreRestoreSelection, catalog: CoreRestoreInspection.Inventory) throws {
        let effective = effectiveSelection ?? selection
        if effectiveSelection != nil || applicationDuplicates != nil {
            let duplicates = applicationDuplicates ?? []
            let removed = Set(duplicates.map(\.appStoreItemID))
            var items = expected.items
            let remaining = (items["app-store"] ?? []).filter { !removed.contains($0) }
            items["app-store"] = remaining.isEmpty ? nil : remaining
            guard !duplicates.isEmpty, duplicates.count <= 2048,
                  removed.count == duplicates.count,
                  Set(duplicates.map(\.caskItemID)).count == duplicates.count,
                  duplicates.allSatisfy({
                      expected.items["app-store"]?.contains($0.appStoreItemID) == true &&
                      expected.items["homebrew-casks"]?.contains($0.caskItemID) == true
                  }),
                  effective == CoreRestoreSelection(categories: expected.categories, items: items) else {
                throw CoreRuntimeError.malformedEvent
            }
        }
        guard preparedPlanID.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              !includeSecure, secureRestoreStatus == "not_selected",
              Set(selectedGroups).count == selectedGroups.count,
              selection == expected,
              Set(selectedGroups) == Set(catalog.groups.filter { !Set($0.domains).isDisjoint(with: Set(expected.categories).union(expected.items.keys)) }.map(\.id)),
              Set(selectedCategories).count == selectedCategories.count,
              selectedItemCounts.values.allSatisfy({ (0...2048).contains($0) }),
              warningCount >= 0, errorCount >= 0, plan.count <= 65536,
              (scopeWarnings ?? []).count <= 128,
              (scopeWarnings ?? []).allSatisfy({ $0.range(of: "^[A-Za-z][A-Za-z -]{0,63}$", options: .regularExpression) != nil }),
              readiness.readyScope == "environment", readiness.reentry == "restore_prepare",
              readiness.conditions.allSatisfy({ ["satisfied", "safely_satisfiable", "external_action_required", "unsupported"].contains($0.status) }),
              plan.allSatisfy({ ["satisfied", "planned", "blocked", "conflict", "warning", "unknown", "pending_unlock"].contains($0.disposition) }) else {
            throw CoreRuntimeError.malformedEvent
        }
        let installers = plan.compactMap(\.installerPreparationID)
        guard Set(installers).count == installers.count, installers.count <= 2048,
              plan.allSatisfy({ row in
                  row.installerPreparationID == nil || (row.domain == "homebrew-casks" && row.disposition == "blocked"
                    && row.reason == "cask_execution_requirements_unsupported"
                    && row.diagnostic?.condition == "preparation_required"
                    && row.installerPreparationID!.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil)
              }) else { throw CoreRuntimeError.malformedEvent }
        let domains = Set(effective.categories).union(effective.items.keys)
        guard plan.allSatisfy({ row in
            (row.diagnostic?.valid ?? true) && domains.contains(row.domain) && (row.selectionItemID == nil || effective.items[row.domain]?.contains(row.selectionItemID!) == true)
        }), effective.items.allSatisfy({ selectedItemCounts[$0.key] == $0.value.count }),
        selectedItemCounts.allSatisfy({ (effective.items[$0.key]?.count ?? 0) == $0.value }) else { throw CoreRuntimeError.malformedEvent }
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

// Presentation of Core-owned observation. Opening a page never changes evidence.
struct AssistedAppStoreItem {
    enum Status: String { case installed = "Installed", missing = "Missing", unverified = "Unverified" }
    let appID: String
    let status: Status
    static func productURL(_ appID: String) -> URL? {
        guard !appID.isEmpty, appID.utf8.count <= 20,
              appID.utf8.allSatisfy({ (48...57).contains($0) }),
              appID.contains(where: { $0 != "0" }) else { return nil }
        return URL(string: "macappstore://apps.apple.com/app/id" + appID)
    }
    var productURL: URL? { status == .installed ? nil : Self.productURL(appID) }
    var statusTitle: String { status == .missing ? "Not in App Store" : status.rawValue }
    var message: String {
        switch status {
        case .installed: "Confirmed by the latest check."
        case .missing: "Install in App Store, then Refresh Status."
        case .unverified: "Installation could not be confirmed. Refresh Status to check again."
        }
    }
}

extension CoreRestorePreparation.Row {
    var assistedAppStoreItem: AssistedAppStoreItem? {
        guard domain == "app-store", action == "inspect", AssistedAppStoreItem.productURL(itemID) != nil else { return nil }
        let status: AssistedAppStoreItem.Status
        switch (disposition, reason) {
        case ("satisfied", nil): status = .installed
        case ("warning", "manual_installation_required"): status = .missing
        case ("unknown", "observation_failed"), ("unknown", "inspection_unavailable"): status = .unverified
        default: return nil
        }
        return AssistedAppStoreItem(appID: itemID, status: status)
    }
}
