import Foundation

struct CoreSecureCheckAvailability: Decodable {
    let version: Int
    let bundleID: String
    let status: String
    enum CodingKeys: String, CodingKey { case version, bundleID = "bundle_id", status }
    func validate() throws {
        guard version == 1, CoreRestoreDestinations.validID(bundleID), ["available", "absent"].contains(status) else {
            throw CoreRuntimeError.malformedEvent
        }
    }
}

// A private observation, never a Restore receipt or import authorization.
struct CoreSecureCheckResult: Decodable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    struct Item: Decodable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
        var description: String { "SecureCheckItem(redacted)" }
        var debugDescription: String { description }
        var customMirror: Mirror { Mirror(self, children: [:]) }
        let identityID: String
        let comparisonKind: String
        let reason: String
        let targetState: String?
        let privateBytesMatch: Bool?
        let publicBytesMatch: Bool?
        enum CodingKeys: String, CodingKey {
            case identityID = "identity_id", comparisonKind = "comparison_kind", reason, targetState = "target_state"
            case privateBytesMatch = "private_bytes_match", publicBytesMatch = "public_bytes_match"
        }
    }
    struct Context: Decodable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
        var description: String { "SecureCheckContext(redacted)" }
        var debugDescription: String { description }
        var customMirror: Mirror { Mirror(self, children: [:]) }
        let mapping: CoreRestoreDestinations
        let targetState: String
        let sshReferenceCoverage: String
        let sourceValidation: String
        let observedAt: String
        let readOnly: Bool
        let publicationOccurred: Bool
        let targetMutationMayHaveStarted: Bool
        enum CodingKeys: String, CodingKey {
            case sshReferenceCoverage = "ssh_reference_coverage"
            case mapping, targetState = "target_state", sourceValidation = "source_validation", observedAt = "observed_at"
            case readOnly = "read_only", publicationOccurred = "publication_occurred", targetMutationMayHaveStarted = "target_mutation_may_have_started"
        }
    }
    let version: Int
    let operationID: String
    let bundleID: String
    let items: [Item]
    let context: Context
    enum CodingKeys: String, CodingKey { case version, operationID = "operation_id", bundleID = "bundle_id", items, context }
    var description: String { "SecureCheck(redacted)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: [:]) }
    static func validateFields(_ data: Data) throws {
        func object(_ value: Any?, keys: Set<String>) throws -> [String: Any] {
            guard let value = value as? [String: Any], Set(value.keys) == keys else { throw CoreRuntimeError.secureChannelInvalid }
            return value
        }
        let root = try object(JSONSerialization.jsonObject(with: data), keys: ["version", "operation_id", "bundle_id", "items", "context"])
        let context = try object(root["context"], keys: ["mapping", "target_state", "source_validation", "ssh_reference_coverage", "observed_at",
            "read_only", "publication_occurred", "target_mutation_may_have_started"])
        let mapping = try object(context["mapping"], keys: ["version", "bundle_id", "items"])
        guard let destinations = mapping["items"] as? [Any], let items = root["items"] as? [Any] else { throw CoreRuntimeError.secureChannelInvalid }
        for row in destinations { _ = try object(row, keys: ["identity_id", "directory", "selected"]) }
        for row in items { _ = try object(row, keys: ["identity_id", "comparison_kind", "reason", "target_state", "private_bytes_match", "public_bytes_match"]) }
    }
    func validate(operationID: String, mapping: CoreRestoreDestinations) throws {
        try mapping.validate()
        guard version == 1, self.operationID == operationID, bundleID == mapping.bundleID,
              mapping.version == 2, context.mapping == mapping, context.readOnly, !context.publicationOccurred,
              !context.targetMutationMayHaveStarted, context.sourceValidation == "saved_files",
              ["not_selected", "resolved", "unresolved"].contains(context.sshReferenceCoverage),
              CoreRestoreDestinations.validID(context.targetState),
              context.observedAt.count <= 40, ISO8601DateFormatter.fractional.date(from: context.observedAt) != nil,
              (1...32).contains(items.count), Set(items.map(\.identityID)).count == items.count,
              items.map(\.identityID).sorted() == mapping.items.filter({ $0.selected == true }).map(\.identityID) else { throw CoreRuntimeError.secureChannelInvalid }
        let reasons = ["matching": ["pair_identical"], "missing": ["pair_absent"],
                       "differing": ["private_bytes_differ", "public_bytes_differ", "pair_bytes_differ"],
                       "unverified": ["partial_pair", "unsafe_target", "target_unavailable", "target_changed"]]
        for item in items {
            guard reasons[item.comparisonKind]?.contains(item.reason) == true,
                  item.targetState.map(CoreRestoreDestinations.validID) ?? true else { throw CoreRuntimeError.secureChannelInvalid }
            if ["matching", "differing"].contains(item.comparisonKind) {
                guard let a = item.privateBytesMatch, let b = item.publicBytesMatch, item.targetState != nil,
                      (a && b) == (item.comparisonKind == "matching"),
                      item.reason == (a && b ? "pair_identical" : !a && !b ? "pair_bytes_differ" : !a ? "private_bytes_differ" : "public_bytes_differ") else { throw CoreRuntimeError.secureChannelInvalid }
            } else {
                guard item.privateBytesMatch == nil, item.publicBytesMatch == nil,
                      item.comparisonKind != "missing" || item.targetState != nil else { throw CoreRuntimeError.secureChannelInvalid }
            }
        }
    }
}

private extension ISO8601DateFormatter {
    static var fractional: ISO8601DateFormatter {
        let value = ISO8601DateFormatter(); value.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return value
    }
}
