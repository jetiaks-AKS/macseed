import Foundation

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
struct CoreCapturePreparation: Decodable {
    let preparedCaptureID: String
    let inventory: [CoreCaptureInventoryRow]
    let secureIdentities: CoreCaptureSecureInventory
    let selection: CoreCaptureSelection?
    var effectiveSelection: CoreCaptureSelection? = nil
    var applicationDuplicates: [CoreRestorePreparation.ApplicationDuplicate]? = nil
    var publicationSelection: CoreCaptureSelection? { effectiveSelection ?? selection }
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
        case preparedCaptureID = "prepared_capture_id", inventory, secureIdentities = "secure_identities", selection, summary
        case effectiveSelection = "effective_selection", applicationDuplicates = "application_duplicates"
    }
    func validate(expected: CoreCaptureSelection?) throws {
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
        guard summary.selectedDomains == Set(effective.categories).union(effective.items.keys).count,
              summary.selectedItems == itemCount else { throw CoreRuntimeError.malformedEvent }
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
        enum CodingKeys: String, CodingKey {
            case formatVersion = "format_version", selectedCategories = "selected_categories"
            case selectedItemCounts = "selected_item_counts", secureComponent = "secure_component"
        }
        var capturedDomains: Set<String> { Set(selectedCategories).union(selectedItemCounts.filter { $0.value > 0 }.map(\.key)) }
        var itemCount: Int { selectedItemCounts.values.reduce(0, +) }
    }
    enum CodingKeys: String, CodingKey {
        case publicationOccurred = "publication_occurred", destination, preparedCaptureID = "prepared_capture_id", bundle
    }
    func validate(preparation: CoreCapturePreparation, destination: URL) throws {
        try preparation.validate(expected: preparation.selection)
        guard let selection = preparation.publicationSelection, publicationOccurred, self.destination == destination.path,
              preparedCaptureID == preparation.preparedCaptureID, bundle.formatVersion == 1,
              bundle.secureComponent == !selection.secureIdentities.isEmpty,
              bundle.selectedItemCounts.count <= preparation.inventory.count,
              bundle.selectedItemCounts.values.allSatisfy({ (0...2048).contains($0) }),
              bundle.capturedDomains == Set(selection.categories).union(selection.items.keys),
              bundle.itemCount == preparation.summary.selectedItems else { throw CoreRuntimeError.malformedEvent }
        for (domain, count) in bundle.selectedItemCounts {
            let wholeCount = selection.categories.contains(domain)
                ? preparation.inventory.first(where: { $0.domain == domain && $0.selectionMode == "items" })?.items.count ?? 0 : 0
            guard count == (selection.items[domain]?.count ?? wholeCount) else { throw CoreRuntimeError.malformedEvent }
        }
    }
}

private enum CaptureCategorySelectionMode {
    static func supportsWhole(_ row: CoreCaptureInventoryRow) -> Bool {
        row.status == "present" && (row.selectionMode == "category" || (row.selectionMode == "items" && !row.items.isEmpty))
    }
}
