import Foundation
import CryptoKit

// Protocol Capture aggregation: functional Scripts is independent of the
// physical Shell domain. Alias definitions and selected files count separately.
enum CoreCaptureCounts {
    static func domains(categories: Set<String>, items: [String: Set<String>], scripts: Set<String>) -> Int {
        categories.union(items.filter { !$0.value.isEmpty }.keys).count + (scripts.isEmpty ? 0 : 1)
    }
}

// Core-qualified per-file consent, separate from alias selection and item counts.
struct CoreShellScript: Decodable, Identifiable, Equatable {
    let id: String
    let path: String
    var aliasIDs: [String]? = nil
    var observationID: String? = nil
    var independent: Bool? = nil
    enum CodingKeys: String, CodingKey { case id, path, independent, aliasIDs = "alias_ids", observationID = "observation_id" }
    static func validateCandidates(_ rows: [Self]?, aliases: Set<String>) throws {
        try validate(rows)
        guard (rows ?? []).allSatisfy({ row in
            guard let ids = row.aliasIDs, let observation = row.observationID else { return false }
            return (!ids.isEmpty || row.independent == true) && ids.count <= 256 && Set(ids).count == ids.count && Set(ids).isSubset(of: aliases)
                && observation.range(of: "^[0-9a-f]{64}\\z", options: .regularExpression) != nil
        }) else { throw CoreRuntimeError.malformedEvent }
    }
    static func validate(_ rows: [Self]?) throws {
        guard let rows else { return }
        guard rows.count <= 128, Set(rows.map(\.id)).count == rows.count,
              rows.allSatisfy({ row in
                  row.path.utf8.count <= 512 && !row.path.isEmpty
                  && row.path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
                      $0.range(of: "^[A-Za-z0-9_. -]{1,128}\\z", options: .regularExpression) != nil
                      && ![".", "..", ".git"].contains(String($0)) && $0 == $0.trimmingCharacters(in: .whitespaces)
                  }
                  && row.id == SHA256.hash(data: Data(("shell-script:" + row.path).utf8)).map { String(format: "%02x", $0) }.joined()
              }) else { throw CoreRuntimeError.malformedEvent }
    }
}

struct CoreShellScriptInspection: Decodable, Equatable {
    let id: String
    let observationID: String
    let status: String
    let reason: String?
    enum CodingKeys: String, CodingKey { case id, status, reason, observationID = "observation_id" }
    static let reasons: Set<String> = ["script_format_unsupported", "script_sensitive_indicator", "script_sensitive_or_nonportable",
        "script_dynamic_or_dependency", "script_dependency_unqualified", "script_limit", "script_empty",
        "script_file_limit", "script_total_limit", "script_count_limit", "script_permissions_unsupported", "script_metadata_unsupported", "script_quarantine_invalid", "script_path_unsupported", "script_observation_failed", "script_changed"]
    static func validate(_ rows: [Self], expected: [String: String]) throws {
        guard rows.count == expected.count, Set(rows.map(\.id)) == Set(expected.keys),
              rows.allSatisfy({ row in
                  row.observationID == expected[row.id] && ["qualified", "unsupported", "unverified"].contains(row.status)
                  && (row.status == "qualified" ? row.reason == nil : row.reason.map { reasons.contains($0) } == true)
              }) else { throw CoreRuntimeError.malformedEvent }
    }
    var explanation: String {
        switch reason {
        case "script_file_limit": "Scripts can be up to 1 MiB each."
        case "script_total_limit": "Selected script content exceeds 16 MiB. Select fewer files."
        case "script_count_limit": "Select up to 128 script files."
        case "script_changed": "File changed. Scan again before selecting it."
        case "script_path_unsupported": "Protected file location. Recover it through its owner."
        case "script_observation_failed": "Use a regular file you own, without links or shared write access in its path."
        case "script_permissions_unsupported": "File permissions or flags are not supported for transfer."
        case "script_quarantine_invalid": "File has quarantine metadata that cannot be safely preserved."
        case "script_metadata_unsupported": "File has unsupported extended attributes. See details for the transfer policy."
        case "script_sensitive_indicator", "script_sensitive_or_nonportable": "May contain sensitive or nonportable data. Recover it separately."
        case "script_dynamic_or_dependency", "script_dependency_unqualified": "Script logic or dependencies are outside supported transfer. Use its repository or recover it separately."
        case "script_limit": "File exceeds the bounded script-transfer limits."
        case "script_empty", "script_format_unsupported": "File encoding or interpreter is outside supported transfer. Recover it separately."
        default: "Qualified for explicit file transfer."
        }
    }
}

struct CoreCaptureSecureInventory: Decodable {
    struct Identity: Decodable, Identifiable {
        let itemID: String
        let label: String
        let keyType: String
        let fingerprint: String
        let validation: String
        var source: String? = nil
        var id: String { itemID }
        enum CodingKeys: String, CodingKey { case itemID = "item_id", label, keyType = "key_type", fingerprint, validation, source }
    }
    let status: String
    let reason: String?
    let items: [Identity]
    static let unavailable = Self(status: "unavailable", reason: nil, items: [])
    func validate() throws {
        let types: Set<String> = ["ssh-ed25519", "ssh-rsa", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521"]
        guard ["present", "unavailable", "observation_error"].contains(status), items.count <= 32,
              (status == "present") == !items.isEmpty,
              Set(items.map(\.itemID)).count == items.count,
              Set(items.map(\.label)).count == items.count,
              items.allSatisfy({ item in
                  item.itemID.range(of: "^[0-9a-f]{64}\\z", options: .regularExpression) != nil
                  && item.label.range(of: "^[A-Za-z0-9][A-Za-z0-9_.-]{0,79}\\z", options: .regularExpression) != nil
                  && !item.label.hasSuffix(".pub") && types.contains(item.keyType)
                  && item.validation == "candidate_requires_pair_validation"
                  && (item.source == nil || item.source == "manual")
                  && item.fingerprint.range(of: "^SHA256:[A-Za-z0-9+/]{43}\\z", options: .regularExpression) != nil
                  && Data(base64Encoded: String(item.fingerprint.dropFirst(7)) + "=")?.count == 32
              }) else { throw CoreRuntimeError.malformedEvent }
    }
}

// Existing V1 payloads only; Discovery, validation and publication remain Core-owned.
struct CoreCaptureShellObservation: Decodable {
    enum Status: String, Decodable { case observed, unavailable, unsupported }
    let status: Status
    private let codes: Set<String>
    enum AliasExclusion: String, Decodable {
        case literal = "literal_required", restricted = "restricted_content", unsupported = "unsupported_declaration"
        case mode = "unsupported_mode", position = "unsupported_position"
        var explanation: String {
            switch self {
            case .literal: return "Excluded because the declaration needs a single, statically quoted command value."
            case .restricted: return "Excluded because the declaration contains a sensitive-content indicator."
            case .unsupported: return "Excluded because the declaration falls outside the supported name, content or portability limits."
            case .mode: return "Capture supports ordinary Aliases. This declaration uses a global or suffix Alias."
            case .position: return "Excluded because its exact declaration could not be isolated on a source line."
            }
        }
    }
    let excludedAliases: [String: AliasExclusion]
    enum CodingKeys: String, CodingKey { case status, codes, excludedAliases = "excluded_aliases" }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        status = try values.decode(Status.self, forKey: .status)
        let supplied = try values.decodeIfPresent([String].self, forKey: .codes) ?? []
        guard supplied.count <= 32, supplied.allSatisfy({ $0.utf8.count <= 80 }) else { throw CoreRuntimeError.malformedEvent }
        codes = Set(supplied)
        excludedAliases = try values.decodeIfPresent([String: AliasExclusion].self, forKey: .excludedAliases) ?? [:]
        guard excludedAliases.count <= 256, excludedAliases.keys.allSatisfy({
            $0.range(of: #"^[A-Za-z_][A-Za-z0-9_.-]{0,63}\z"#, options: .regularExpression) != nil
        }) else { throw CoreRuntimeError.malformedEvent }
    }
    var hasIncompleteScan: Bool {
        !codes.isDisjoint(with: ["alias_scope_unresolved", "ambiguous_alias", "ambiguous_function",
            "ambiguous_source_command", "unsafe_source", "source_changed", "source_unresolved"])
    }
    var selectionIssue: String? {
        if codes.contains("unsafe_source") { return "A Shell source failed safety checks. Review its ownership and permissions, then scan again." }
        if codes.contains("source_changed") { return "A Shell source changed during inspection. Scan again to refresh the list." }
        if codes.contains("source_unresolved") { return "A referenced Shell source could not be inspected. Check the source reference and scan again." }
        if codes.contains("alias_scope_unresolved") {
            return "Some Alias declarations could not be identified safely. Review the startup configuration if an expected Alias is missing."
        }
        if !codes.isDisjoint(with: ["ambiguous_alias", "ambiguous_function", "ambiguous_source_command"]) {
            return "Some definitions have conflicting names or ambiguous load relationships. Review duplicate declarations and source commands, then scan again."
        }
        if codes.isSubset(of: ["unsupported_context"]) && !excludedAliases.isEmpty { return nil }
        return notice ?? (qualifiedScopeLimitation ? nil : "Some Shell definitions could not be qualified. Review the startup configuration if an expected command is missing.")
    }
    var title: String { status == .unavailable ? "Functions unavailable" : "Functions excluded" }
    var qualifiedScopeLimitation: Bool {
        status == .observed && codes.isSubset(of: ["unsupported_context"])
    }
    var notice: String? {
        guard status != .observed else { return nil }
        // Fixed messages only. Unknown codes never become user-visible text.
        if status == .unavailable {
            if codes.contains("functions_unavailable") { return "Functions are excluded because protected parser launch is unavailable on this Mac." }
            if !codes.isDisjoint(with: ["helper_unavailable", "helper_untrusted"]) { return "Functions are excluded because the bundled parser could not be authenticated or started." }
            return "Functions observation is unavailable on this Mac; Functions are excluded."
        }
        if codes.contains("unsupported_context") { return "Functions are excluded because startup configuration contains unsupported commands or source relationships." }
        if codes.contains("unsafe_source") { return "Functions are excluded because a Shell source did not pass safety checks." }
        if codes.contains("source_changed") { return "Functions are excluded because a Shell source changed during observation. Scan again." }
        if !codes.isDisjoint(with: ["ambiguous_definition", "ambiguous_load"]) { return "Functions are excluded because definitions or load relationships are ambiguous." }
        return "Functions are excluded because this Shell configuration could not be safely qualified."
    }
    func coverageMessage(aliasCount: Int, saved: Bool = false) -> String? {
        if status == .observed && !codes.isEmpty {
            let scope = codes.isDisjoint(with: ["ambiguous_function", "ambiguous_alias", "ambiguous_source_command"])
                ? "Startup initialization and unsupported source relationships are outside the saved scope."
                : "Ambiguous definitions and unsupported source relationships are excluded."
            return (saved ? "Selected definitions were saved. " : "Listed definitions are eligible to save. ") + scope
                + " Tools, environment and runtime behavior are not verified."
        }
        guard let notice else { return nil }
        let aliases = "\(aliasCount) \(aliasCount == 1 ? "Alias" : "Aliases")"
        return (saved ? aliases + " saved. " : aliases + " eligible to save. ") + notice
            + " Other Shell settings and dependencies may remain outside the saved scope."
    }
}

struct CoreCapturePreparation: Decodable {
    var shellFunctions: CoreCaptureShellObservation? = nil
    var shellScriptPolicies: [String]? = nil
    var shellScriptPolicy: String? = nil
    var shellScriptSelection: [String]? = nil
    var shellScriptCandidates: [CoreShellScript]? = nil
    var shellScripts: [CoreShellScript]? = nil
    let preparedCaptureID: String
    let inventory: [CoreCaptureInventoryRow]
    let secureIdentities: CoreCaptureSecureInventory
    let selection: CoreCaptureSelection?
    var effectiveSelection: CoreCaptureSelection? = nil
    var applicationDuplicates: [CoreRestorePreparation.ApplicationDuplicate]? = nil
    var publicationSelection: CoreCaptureSelection? { effectiveSelection ?? selection }
    var standaloneScriptCount: Int {
        guard let selection = publicationSelection, ["opaque-file-v4", "opaque-file-v5"].contains(shellScriptPolicy ?? "") else { return 0 }
        let aliases = Set(selection.items["shell-zsh"] ?? (selection.categories.contains("shell-zsh")
            ? inventory.first { $0.domain == "shell-zsh" }?.items.map(\.itemID) ?? [] : []))
        return (shellScriptCandidates ?? []).filter { (shellScriptSelection ?? []).contains($0.id) && Set($0.aliasIDs ?? []).isDisjoint(with: aliases) }.count
    }
    let summary: Summary
    struct Summary: Decodable {
        let selectedDomains: Int
        let selectedItems: Int
        let secureIdentityCount: Int
        enum CodingKeys: String, CodingKey {
            case selectedDomains = "selected_domains", selectedItems = "selected_items", secureIdentityCount = "secure_identity_count"
        }
    }
    enum CodingKeys: String, CodingKey {
        case shellFunctions = "shell_functions"
        case shellScriptSelection = "shell_script_selection"
        case shellScriptPolicies = "shell_script_policies", shellScriptPolicy = "shell_script_policy"
        case shellScriptCandidates = "shell_script_candidates"
        case shellScripts = "shell_scripts"
        case preparedCaptureID = "prepared_capture_id", inventory, secureIdentities = "secure_identities", selection, summary
        case effectiveSelection = "effective_selection", applicationDuplicates = "application_duplicates"
    }
    func validate(expected: CoreCaptureSelection?, expectedScripts: [String]? = nil) throws {
        if ["opaque-file-v4", "opaque-file-v5"].contains(shellScriptPolicy ?? "") {
            guard shellScriptSelection == (expectedScripts ?? []).sorted(),
                  Set(expectedScripts ?? []).isSubset(of: Set((shellScriptCandidates ?? []).map(\.id))) else { throw CoreRuntimeError.malformedEvent }
        } else if shellScriptSelection != nil { throw CoreRuntimeError.malformedEvent }
        guard shellScriptPolicies == nil || shellScriptPolicies == ["opaque-file-v4"] || shellScriptPolicies == ["opaque-file-v4", "opaque-file-v5"],
              shellScriptPolicy == nil || ["opaque-file-v4", "opaque-file-v5"].contains(shellScriptPolicy ?? "") else { throw CoreRuntimeError.malformedEvent }
        try CoreShellScript.validateCandidates(shellScriptCandidates,
            aliases: Set(inventory.first { $0.domain == "shell-zsh" && $0.status == "present" && $0.selectionMode == "items" }?.items.map(\.itemID) ?? []))
        try CoreShellScript.validate(shellScripts)
        // Select All uses V1's compact whole-domain form; partial selection uses
        // item IDs. Consent metadata is valid for either selected alias scope.
        let shellSelected = (["opaque-file-v4", "opaque-file-v5"].contains(shellScriptPolicy ?? "") && !(expectedScripts ?? []).isEmpty) || expected?.categories.contains("shell-zsh") == true || expected?.items["shell-zsh"]?.isEmpty == false
        guard shellScripts == nil || (shellSelected && inventory.contains {
            $0.domain == "shell-zsh" && $0.status == "present" && $0.selectionMode == "items"
                && (!$0.items.isEmpty || (["opaque-file-v4", "opaque-file-v5"].contains(shellScriptPolicy ?? "") && !(expectedScripts ?? []).isEmpty))
        }) else { throw CoreRuntimeError.malformedEvent }
        try secureIdentities.validate()
        let identities = expected?.secureIdentities ?? []
        guard preparedCaptureID.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              Set(inventory.map(\.domain)).count == inventory.count, !inventory.isEmpty,
              inventory.allSatisfy({ row in
                  ["present", "unavailable", "observation_error", "unsupported"].contains(row.status)
                    && row.items.count <= 2048 && Set(row.items.map(\.itemID)).count == row.items.count
                    && (row.includedSettings ?? []).count <= 2048
                    && Set((row.includedSettings ?? []).map(\.id)).count == (row.includedSettings ?? []).count
                    && (row.includedSettings ?? []).allSatisfy { !$0.id.isEmpty && !$0.label.isEmpty && $0.label.count <= 160 && !$0.label.contains("\n") }
              }), selection == expected, summary.secureIdentityCount == identities.count,
              Set(identities).count == identities.count,
              Set(identities).isSubset(of: Set(secureIdentities.items.map(\.itemID))) else { throw CoreRuntimeError.malformedEvent }
        guard let expected else {
            guard summary.selectedDomains == 0, summary.selectedItems == 0,
                  effectiveSelection == nil, applicationDuplicates == nil else { throw CoreRuntimeError.malformedEvent }
            return
        }
        let domains = Set(expected.categories).union(expected.items.keys)
        guard domains.count == expected.categories.count + expected.items.count,
              expected.categories.allSatisfy({ domain in inventory.contains { $0.domain == domain && CaptureCategorySelectionMode.supportsWhole($0) } }),
              expected.items.allSatisfy({ domain, items in
                  inventory.contains { row in row.domain == domain && row.status == "present" && row.selectionMode == "items"
                      && !items.isEmpty && Set(items).count == items.count && Set(items).isSubset(of: Set(row.items.map(\.itemID))) }
              }) else { throw CoreRuntimeError.malformedEvent }
        if effectiveSelection != nil || applicationDuplicates != nil {
            guard let effectiveSelection, let duplicates = applicationDuplicates,
                  !duplicates.isEmpty, duplicates.count <= 50 else { throw CoreRuntimeError.malformedEvent }
            func selectedIDs(_ domain: String) -> [String] {
                expected.items[domain] ?? (expected.categories.contains(domain)
                    ? inventory.first { $0.domain == domain }?.items.map(\.itemID) ?? [] : [])
            }
            let removed = Set(duplicates.map(\.appStoreItemID))
            let retained = Set(duplicates.map(\.caskItemID))
            var items = expected.items
            let remaining = selectedIDs("app-store").filter { !removed.contains($0) }.sorted()
            items["app-store"] = remaining.isEmpty ? nil : remaining
            let effective = CoreCaptureSelection(categories: expected.categories.filter { $0 != "app-store" },
                items: items, secureIdentities: expected.secureIdentities)
            guard removed.count == duplicates.count, retained.count == duplicates.count,
                  removed.isSubset(of: Set(selectedIDs("app-store"))),
                  retained.isSubset(of: Set(selectedIDs("homebrew-casks"))),
                  effectiveSelection == effective else { throw CoreRuntimeError.malformedEvent }
        }
        let effective = effectiveSelection ?? expected
        let itemCount = effective.items.values.reduce(0) { $0 + $1.count }
            + inventory.filter { effective.categories.contains($0.domain) }.reduce(0) { $0 + $1.items.count }
        guard summary.selectedDomains == CoreCaptureCounts.domains(categories: Set(effective.categories), items: effective.items.mapValues(Set.init), scripts: Set(expectedScripts ?? [])),
              summary.selectedItems == itemCount + Set(expectedScripts ?? []).count else { throw CoreRuntimeError.malformedEvent }
    }
}

struct CoreCapturePublication: Decodable {
    let publicationOccurred: Bool
    let destination: String
    let preparedCaptureID: String
    let bundle: BundleInfo
    struct BundleInfo: Decodable {
        let formatVersion: Int
        let selectedCategories: [String]
        let selectedItemCounts: [String: Int]
        let secureComponent: Bool
        var requiredFeatures: [String: Int]? = nil
        var shellScriptCandidates: [CoreShellScript]? = nil
        var typedShell: Bool { requiredFeatures?["shell-state"] == 1 }
        enum CodingKeys: String, CodingKey {
            case formatVersion = "format_version", selectedCategories = "selected_categories"
            case selectedItemCounts = "selected_item_counts", secureComponent = "secure_component"
            case shellScriptCandidates = "shell_script_candidates"
            case requiredFeatures = "required_features"
        }
        var capturedDomains: Set<String> { Set(selectedCategories).union(selectedItemCounts.filter { $0.value > 0 }.map(\.key)) }
        var itemCount: Int { selectedItemCounts.values.reduce(0, +) }
        // Bundle inspection counts physical Restore requirements: a linked file
        // is represented there by its alias. Capture counts each saved object.
        // These file identities/associations come from the validated Bundle.
        private var standaloneScriptCount: Int { (shellScriptCandidates ?? []).filter { ($0.aliasIDs ?? []).isEmpty }.count }
        private var aliasCount: Int { (selectedItemCounts["shell-zsh"] ?? 0) - standaloneScriptCount }
        var capturedItemCount: Int {
            selectedItemCounts.filter { $0.key != "shell-zsh" }.values.reduce(0, +)
                + aliasCount + Set((shellScriptCandidates ?? []).map(\.id)).count
        }
        var functionalDomainCount: Int {
            let aliasesSelected = capturedDomains.contains("shell-zsh") && (selectedItemCounts["shell-zsh"] == nil || aliasCount > 0)
            return capturedDomains.subtracting(["shell-zsh"]).count + (aliasesSelected ? 1 : 0)
                + ((shellScriptCandidates ?? []).isEmpty ? 0 : 1)
        }
    }
    enum CodingKeys: String, CodingKey {
        case publicationOccurred = "publication_occurred", destination, preparedCaptureID = "prepared_capture_id", bundle
    }
    func validate(preparation: CoreCapturePreparation, destination: URL) throws {
        try preparation.validate(expected: preparation.selection, expectedScripts: preparation.shellScriptSelection)
        guard bundle.requiredFeatures?["shell-state"] == nil || bundle.typedShell,
              preparation.publicationSelection?.items["shell-zsh"]?.contains(where: { $0.hasPrefix("shell-function:") }) != true || bundle.typedShell else {
            throw CoreRuntimeError.malformedEvent
        }
        guard let selection = preparation.publicationSelection, publicationOccurred, self.destination == destination.path,
              preparedCaptureID == preparation.preparedCaptureID, bundle.formatVersion == 1,
              bundle.secureComponent == !selection.secureIdentities.isEmpty,
              bundle.selectedItemCounts.count <= preparation.inventory.count,
              bundle.selectedItemCounts.values.allSatisfy({ (0...2048).contains($0) }),
              bundle.capturedDomains == Set(selection.categories).union(selection.items.keys).union(preparation.standaloneScriptCount > 0 ? ["shell-zsh"] : []),
              bundle.capturedItemCount == preparation.summary.selectedItems,
              bundle.functionalDomainCount == preparation.summary.selectedDomains else { throw CoreRuntimeError.malformedEvent }
        try CoreShellScript.validate(bundle.shellScriptCandidates)
        let selectedAliases = Set(selection.items["shell-zsh"] ?? (selection.categories.contains("shell-zsh")
            ? preparation.inventory.first { $0.domain == "shell-zsh" }?.items.map(\.itemID) ?? [] : []))
        guard Set((bundle.shellScriptCandidates ?? []).map(\.id)) == Set(preparation.shellScriptSelection ?? []),
              (bundle.shellScriptCandidates ?? []).allSatisfy({ saved in
                  guard let candidate = preparation.shellScriptCandidates?.first(where: { $0.id == saved.id }),
                        let aliases = saved.aliasIDs else { return false }
                  return saved.path == candidate.path && Set(aliases).count == aliases.count
                      && (!bundle.typedShell || aliases.isEmpty)
                      && Set(aliases).isSubset(of: Set(candidate.aliasIDs ?? []).intersection(selectedAliases))
              }) else { throw CoreRuntimeError.malformedEvent }
        for (domain, count) in bundle.selectedItemCounts {
            let wholeCount = selection.categories.contains(domain)
                ? preparation.inventory.first(where: { $0.domain == domain && $0.selectionMode == "items" })?.items.count ?? 0 : 0
            // Typed state represents every explicitly selected file as its own
            // requirement. Legacy snapshots fold linked files into their aliases.
            let files = bundle.typedShell ? (preparation.shellScriptSelection ?? []).count : preparation.standaloneScriptCount
            guard count == (selection.items[domain]?.count ?? wholeCount) + (domain == "shell-zsh" ? files : 0) else { throw CoreRuntimeError.malformedEvent }
        }
    }
}

private enum CaptureCategorySelectionMode {
    static func supportsWhole(_ row: CoreCaptureInventoryRow) -> Bool {
        row.status == "present" && (row.selectionMode == "category" || (row.selectionMode == "items" && !row.items.isEmpty))
    }
}
