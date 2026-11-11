import Foundation

// One logical package requirement, projected from Core's validated importer receipt.
// Neither an exit code nor a phase-completed event proves imported-state conformity.
struct CoreSecureRestoreEvidence {
    let operation: [String: CoreJSON]?
    let observation: [String: CoreJSON]?
    let coverage: [String: CoreJSON]?
    let contradictoryObservation: Bool
    init(events: [CoreEvent] = [], payload: [String: CoreJSON]? = nil) {
        let details = payload?["verification"]?.object?["details"]?.object
        func records(_ type: String, _ bucket: String) -> [[String: CoreJSON]] {
            let saved: [[String: CoreJSON]]
            if case .array(let rows) = details?[bucket] { saved = rows.compactMap(\.object) } else { saved = [] }
            return (events.filter { $0.type == type }.compactMap(\.data) + saved)
                .filter { $0["domain"]?.string == CoreRestorePreparation.secureDomain }
        }
        func package(_ row: [String: CoreJSON]) -> Bool { row["item_id"]?.string == CoreRestorePreparation.secureItem }
        operation = records("operation_record", "operation_records").last {
            package($0) && $0["action"]?.string == "validate_and_import"
        }
        let observations = records("verification_record", "verification_records")
        observation = observations.last { package($0) && $0["predicate"]?.string == "identity_set_matches_package" }
        coverage = records("coverage_record", "coverage_records").last(where: package)
        contradictoryObservation = observations.contains { !package($0) && $0["conformity"]?.string != "verified" }
    }
    var verified: Bool {
        ["success", "noop"].contains(operation?["outcome"]?.string ?? "") && operation?["reason"]?.string == "match"
            && observation?["conformity"]?.string == "verified" && observation?["support"]?.string == "supported"
            && observation?["observed_at"]?.string?.isEmpty == false && !contradictoryObservation
            && coverage?["disposition"]?.string == "resolved" && coverage?["source_status"]?.string == "observed_present"
    }
    var available: Bool { operation != nil || observation != nil || coverage != nil }
}

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

struct CoreSecureComparison: Codable, Equatable, Sendable {
    enum Decision: String, Codable, Sendable { case allMatch = "all_match", importRequired = "import_required", conflict }
    let decision: Decision
    let targetState: String?
    let sourceFingerprint: String
    let preparedPlanID: String
    let selection: CoreRestoreSelection
    let includeSecure: Bool
    let comparisonOperationID: String
    var sshResolution: CoreSSHResolution? = nil
    var sshHostPresentation: CoreSSHHosts? = nil
    enum CodingKeys: String, CodingKey {
        case sshHostPresentation = "ssh_host_presentation"
        case sshResolution = "ssh_resolution"
        case decision, selection, targetState = "target_state", sourceFingerprint = "source_fingerprint"
        case preparedPlanID = "prepared_plan_id", includeSecure = "include_secure", comparisonOperationID = "comparison_operation_id"
    }
    func validate(plan: CoreRestorePreparation, operationID: String, requestSelection: CoreRestoreSelection? = nil) throws {
        try sshHostPresentation?.validate(update: self, plan: plan)
        func digest(_ value: String?) -> Bool { value?.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil }
        guard sshResolution?.valid != false, (plan.sshResolution == nil || sshResolution != nil), plan.includeSecure, includeSecure, selection == (requestSelection ?? plan.selection), preparedPlanID == plan.preparedPlanID,
              sourceFingerprint == plan.planDiagnostics?["bundle"], digest(sourceFingerprint), digest(preparedPlanID),
              comparisonOperationID == operationID, operationID.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil,
              decision == .conflict ? targetState == nil : digest(targetState) else { throw CoreRuntimeError.malformedEvent }
    }
    // Display aliases never return in an Execute receipt or ordinary request.
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(decision, forKey: .decision)
        try values.encodeIfPresent(targetState, forKey: .targetState)
        try values.encode(sourceFingerprint, forKey: .sourceFingerprint)
        try values.encode(preparedPlanID, forKey: .preparedPlanID)
        try values.encode(selection, forKey: .selection)
        try values.encode(includeSecure, forKey: .includeSecure)
        try values.encode(comparisonOperationID, forKey: .comparisonOperationID)
        try values.encodeIfPresent(sshResolution, forKey: .sshResolution)
    }
}

struct CoreRestorePreparation: Decodable {
    var sshHostPresentation: CoreSSHHosts? = nil
    var effectiveSSHHosts: CoreSSHHosts? { includeSecure ? secureComparison?.sshHostPresentation : sshHostPresentation }
    var secureComparison: CoreSecureComparison? = nil
    var sshResolution: CoreSSHResolution? = nil
    var effectiveSSHResolution: CoreSSHResolution? { includeSecure ? secureComparison?.sshResolution : sshResolution }
    var sshDependenciesReady: Bool {
        // Selected SSH conflicts are never an item-local skip, including legacy v1.
        guard !plan.contains(where: { $0.domain == "ssh-configuration" && ["conflict", "blocked", "unknown"].contains($0.disposition) }) else { return false }
        guard sshResolution != nil else { return true }
        return effectiveSSHResolution?.valid == true && effectiveSSHResolution?.ready == true
            && (!includeSecure || secureComparedReady)
    }
    enum SecureDestinationScope: String, Decodable { case defaultLocation = "default", custom, mixed }
    var secureDestinationScope: SecureDestinationScope? = nil
    var secureComparedReady: Bool { secureExecutable && secureComparison.map { [.allMatch, .importRequired].contains($0.decision) } == true }
    var hasComparedExecutableChanges: Bool {
        includeSecure ? (secureComparison?.decision == .importRequired || plan.contains { !$0.isSecureImport && $0.disposition == "planned" }) : hasExecutableChanges
    }
    static let secureDomain = "secure-ssh-identities"
    static let secureItem = "encrypted_identity_set"
    var secureExecutable: Bool {
        includeSecure && secureRestoreStatus == "selected_pending" && readiness.ready && errorCount == 0
            && plan.filter(\.isSecureImport).count == 1
            && readiness.conditions.filter(\.isSecureLaunchRequirement).count == 1
            && readiness.conditions.filter { $0.domain == Self.secureDomain }.allSatisfy {
                $0.isSecureLaunchRequirement || ["satisfied", "safely_satisfiable"].contains($0.status)
            }
    }
    static let workspacePreviewReasons: [String: String] = [
        "workspace_restore_not_enabled": "Rebuild Preview completed. Rebuild for Git worktree topology is not yet available.",
        "workspace_git_unsupported": "Unsupported: Git is unavailable or the required inspection capability is not qualified.",
        "workspace_file_count_limit": "Unsupported: planning a Git change exceeds the 4,096-file inspection limit. Existing files will be preserved.",
        "workspace_file_bytes_limit": "Unsupported: planning a Git change exceeds the 16 MiB file inspection limit. Existing files will be preserved.",
        "workspace_symlink_unsupported": "Unsupported: a symbolic link prevents safe inspection of the selected checkout. Existing files will be preserved.",
        "workspace_file_unsupported": "Unsupported: file inspection encountered a special or replaced file. Existing files will be preserved.",
        "workspace_configuration_unsupported": "Unsupported: this repository uses Git configuration that Preview cannot safely qualify.",
        "workspace_index_unsupported": "Unsupported: Git index flags can hide local changes, so this checkout cannot be qualified safely.",
        "workspace_hooks_unsupported": "Unsupported: a Git hook or hook configuration could run external code during this action.",
        "workspace_tree_unsupported": "Unsupported: the requested Git tree contains a symbolic link or submodule that this action cannot safely restore.",
        "workspace_submodule_unsupported": "Unsupported: the checkout contains a submodule that topology Rebuild does not yet support.",
        "workspace_git_metadata_unsupported": "Unsupported: the Git directory metadata contains an unsafe link or an unqualified format.",
        "workspace_worktree_unsupported": "Unsupported: Git worktree relationships could not be qualified from the available metadata.",
        "workspace_path_unsupported": "Unsupported: a required Git path is outside HOME or cannot be qualified safely.",
        "workspace_observation_failed": "Workspace state could not be inspected reliably. Existing files will be preserved.",
        "workspace_observation_changed": "Workspace state changed during inspection. Refresh Preview.",
        "workspace_descriptor_conflict": "The existing workspace descriptor has different folder relationships or is unsafe. It will be preserved without merging.",
        "workspace_relationship_missing": "A referenced folder is missing. Select its Workspace Folder or restore its checkout, then refresh Preview.",
        "workspace_descriptor_write_failed": "The workspace descriptor could not be created and verified safely. Review its retained state before retrying.",
        "workspace_destination_conflict": "The destination is occupied, aliased or unsafe. Existing files will be preserved.",
        "workspace_topology_conflict": "The checkout belongs to a different Git repository or worktree relationship.",
        "workspace_origin_conflict": "The existing repository origin differs from the saved environment.",
        "workspace_branch_occupied": "The requested branch is already used by another worktree.",
        "workspace_branch_unavailable": "The requested branch is not available locally. Preview cannot promise branch creation or remote availability.",
        "workspace_commit_unavailable": "The exact detached commit is not available locally.",
        "workspace_dependency_pending": "Conditional: selected folders and base or parent checkouts must be restored first. Macseed will recheck their state before continuing.",
        "workspace_commit_after_clone": "Conditional: after cloning, Macseed must find the exact detached commit locally. It will not fetch missing objects.",
        "git_ssh_local_ready": "Local SSH dependencies are satisfied. Remote authentication has not been tested.",
        "git_ssh_restore_pending": "Conditional: selected dependencies must be restored and SSH key evidence rechecked before cloning. Remote authentication has not been tested.",
        "git_ssh_identity_unresolved": "A required SSH key could not be qualified. Restore or resolve the key, then refresh Preview. Remote authentication has not been tested.",
        "git_ssh_configuration_conflict": "Required SSH configuration conflicts with local state. Existing settings will be preserved.",
        "git_ssh_configuration_unsupported": "Required SSH configuration could not be safely qualified. Review it before cloning.",
        "workspace_partial_checkout": "A previous Git operation left unresolved state at this destination. Inspect the retained checkout before retrying.",
        "workspace_verification_failed": "Git finished, but the requested checkout could not be verified. Its retained state needs attention.",
        "workspace_preservation_unconfirmed": "Other checkout state could not be confirmed unchanged. Further Rebuild is blocked pending inspection.",
        "workspace_execution_failed": "Workspace restoration could not complete safely. Review its operation and verification results.",
        "workspace_not_authorized": "This action was not included in the confirmed Rebuild plan. Refresh Preview.",
        "workspace_dependency_missing": "A selected workspace descriptor or checkout requires its folders and base or parent repositories. Review Selection and include them, or deselect the dependent item.",
        "workspace_path_conflict": "Selected Workspace destinations conflict. Review Selection before preparing Rebuild.",
        "workspace_local_changes": "Tracked or staged changes prevent a safe branch switch. Existing files will be preserved.",
        "workspace_protected_files": "Untracked or ignored files conflict with the requested branch. Existing files will be preserved.",
        "workspace_local_changes_preserved": "The requested checkout already matches. Local changes will be preserved.",
        "workspace_operation_in_progress": "A Git operation or lock is present. Complete it outside Macseed, then Refresh Preview.",
        "workspace_checkout_destination": "This folder shares the repository destination; no separate folder creation is planned."
    ]
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
                return "Repair cannot confirm ownership of the components it would change. Review the installation or use the official installer, then Refresh Preview."
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
                return "This application requires Rosetta. Install it manually with softwareupdate --install-rosetta, then Refresh Preview."
            }
            if automationRequirement {
                return condition == "application_unavailable"
                    ? "Macseed cannot inspect login items without System Events permission. Choose Fix Issues… to allow access and check the current state again."
                    : condition == "authorization_denied"
                        ? "Allow Macseed → System Events in System Settings → Privacy & Security → Automation, then Refresh Preview."
                        : "Macseed cannot inspect login items without System Events permission. Choose Fix Issues… to allow access and check the current state again."
            }
            switch condition {
            case "provider_conflict": return "Homebrew and App Store ownership is uncertain for this app. Exclude this Homebrew item or resolve its installation source."
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
            default: "application component"
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
        var isSSHDependency: Bool {
            domain == "ssh-configuration" && itemID == "identity-references" && action == "none"
                && disposition == "warning" && reason == "identity_dependencies_unresolved"
        }
        var isSecureImport: Bool {
            domain == CoreRestorePreparation.secureDomain && itemID == CoreRestorePreparation.secureItem
                && action == "validate_and_import" && disposition == "pending_unlock" && reason == "secure_unlock_required"
                && displayName == nil && selectionItemID == nil && diagnostic == nil && installerPreparationID == nil
                && headKind == nil && authorizationRequired == nil
        }
        let domain: String
        let itemID: String
        let action: String
        let disposition: String
        let reason: String?
        let displayName: String?
        let selectionItemID: String?
        var headKind: String? = nil
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
        enum CodingKeys: String, CodingKey { case headKind = "head_kind", installerPreparationID = "installer_preparation_id", diagnostic, domain, itemID = "item_id", action, disposition, reason, displayName = "display_name", selectionItemID = "selection_item_id", authorizationRequired = "authorization_required" }
    }
    struct Readiness: Decodable {
        let ready: Bool
        let readyScope: String
        let conditions: [Condition]
        let reentry: String
        enum CodingKeys: String, CodingKey { case ready, readyScope = "ready_scope", conditions, reentry }
    }
    struct Condition: Decodable, Identifiable {
        var isSecureLaunchRequirement: Bool {
            domain == CoreRestorePreparation.secureDomain && code == "secure_bridge_required"
                && status == "external_action_required" && scope == "execution_launch"
                && selectedItemIndex == nil && diagnostic == nil
        }
        let domain: String
        let code: String
        let status: String
        let selectedItemIndex: Int?
        let scope: String?
        var diagnostic: Diagnostic? = nil
        var isPreviewOnlyLimitation: Bool {
            domain == "Workspace" && code == "workspace_restore_not_enabled"
                && status == "unsupported" && scope == "operation" && selectedItemIndex == nil && diagnostic == nil
        }
        var isItemLocal: Bool {
            scope == "item" && domain == "homebrew-casks" && ["cask_execution_requirements_unsupported", "cask_target_conflict", "cask_rosetta_required"].contains(code)
                && (status == "unsupported" || (code == "cask_rosetta_required" && status == "external_action_required")) && (selectedItemIndex ?? 0) > 0
        }
        var id: String { domain + ":" + code + ":" + String(selectedItemIndex ?? 0) }
        enum CodingKeys: String, CodingKey { case diagnostic, domain, code, status, scope, selectedItemIndex = "selected_item_index" }
    }
    enum CodingKeys: String, CodingKey {
        case effectiveSelection = "effective_selection", applicationDuplicates = "application_duplicates"
        case sshHostPresentation = "ssh_host_presentation"
        case sshResolution = "ssh_resolution"
        case secureDestinationScope = "secure_destination_scope"
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
    func validate(expected: CoreRestoreSelection, catalog: CoreRestoreInspection.Inventory, expectedIncludeSecure: Bool = false) throws {
        guard sshResolution?.valid != false else { throw CoreRuntimeError.malformedEvent }
        try sshHostPresentation?.validate(plan: self, catalog: catalog)
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
              includeSecure == expectedIncludeSecure, secureRestoreStatus == (includeSecure ? "selected_pending" : "not_selected"),
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
            (includeSecure && row.isSecureImport) || ((row.diagnostic?.valid ?? true) && domains.contains(row.domain) && (row.selectionItemID == nil || effective.items[row.domain]?.contains(row.selectionItemID!) == true))
        }), effective.items.allSatisfy({ selectedItemCounts[$0.key] == $0.value.count }),
        selectedItemCounts.allSatisfy({ (effective.items[$0.key]?.count ?? 0) == $0.value }) else { throw CoreRuntimeError.malformedEvent }
        guard readiness.conditions.allSatisfy({ condition in
            (condition.diagnostic?.valid ?? true) && (condition.scope == nil || condition.scope == "operation" || (includeSecure && condition.isSecureLaunchRequirement) ||
                (condition.isItemLocal && (condition.selectedItemIndex ?? 0) <= (selectedItemCounts[condition.domain] ?? 0)))
        }), executableChanges == nil || hasExecutableChanges == (includeSecure || plan.contains(where: { $0.disposition == "planned" })) else {
            throw CoreRuntimeError.malformedEvent
        }
        guard plan.filter({ $0.domain == Self.secureDomain }).count == (includeSecure ? 1 : 0),
              readiness.conditions.filter(\.isSecureLaunchRequirement).count == (includeSecure ? 1 : 0),
              includeSecure || !readiness.conditions.contains(where: { $0.domain == Self.secureDomain }) else { throw CoreRuntimeError.malformedEvent }
        if readiness.ready && readiness.conditions.contains(where: { ["external_action_required", "unsupported"].contains($0.status) && !$0.isItemLocal && !(includeSecure && $0.isSecureLaunchRequirement) }) {
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
