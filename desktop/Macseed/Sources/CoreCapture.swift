import Foundation

// Existing V1 payloads only; Discovery, validation and publication remain Core-owned.
struct CoreCapturePreparation: Decodable {
    let preparedCaptureID: String
    let inventory: [CoreCaptureInventoryRow]
    let secureIdentities: CoreJSON
    let selection: CoreCaptureSelection?
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
    }
    func validate(expected: CoreCaptureSelection?) throws {
        guard preparedCaptureID.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              Set(inventory.map(\.domain)).count == inventory.count, !inventory.isEmpty,
              inventory.allSatisfy({ row in
                  ["present", "unavailable", "observation_error", "unsupported"].contains(row.status)
                    && row.items.count <= 2048 && Set(row.items.map(\.itemID)).count == row.items.count
                    && (row.includedSettings ?? []).count <= 2048
                    && Set((row.includedSettings ?? []).map(\.id)).count == (row.includedSettings ?? []).count
                    && (row.includedSettings ?? []).allSatisfy { !$0.id.isEmpty && !$0.label.isEmpty && $0.label.count <= 160 && !$0.label.contains("\n") }
              }), selection == expected, summary.secureIdentityCount == 0,
              (selection?.secureIdentities ?? []).isEmpty else { throw CoreRuntimeError.malformedEvent }
        guard let expected else {
            guard summary.selectedDomains == 0, summary.selectedItems == 0 else { throw CoreRuntimeError.malformedEvent }
            return
        }
        let domains = Set(expected.categories).union(expected.items.keys)
        guard domains.count == expected.categories.count + expected.items.count,
              summary.selectedDomains == domains.count,
              expected.categories.allSatisfy({ domain in inventory.contains { $0.domain == domain && CaptureCategorySelectionMode.supportsWhole($0) } }),
              expected.items.allSatisfy({ domain, items in
                  inventory.contains { row in row.domain == domain && row.status == "present" && row.selectionMode == "items"
                      && !items.isEmpty && Set(items).count == items.count && Set(items).isSubset(of: Set(row.items.map(\.itemID))) }
              }) else { throw CoreRuntimeError.malformedEvent }
        let itemCount = expected.items.values.reduce(0) { $0 + $1.count }
            + inventory.filter { expected.categories.contains($0.domain) }.reduce(0) { $0 + $1.items.count }
        guard summary.selectedItems == itemCount else { throw CoreRuntimeError.malformedEvent }
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
        guard let selection = preparation.selection, publicationOccurred, self.destination == destination.path,
              preparedCaptureID == preparation.preparedCaptureID, bundle.formatVersion == 1, !bundle.secureComponent,
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
