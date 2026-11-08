import Foundation

// These references/approvals use the protected per-operation files, never JSONL.
struct CoreSSHApprovals: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    struct Item: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
        let hostID: String
        let index: Int
        let original: String
        let reference: String
        let identityID: String?
        let approved: Bool
        enum CodingKeys: String, CodingKey { case hostID = "host_id", index, original, reference, identityID = "identity_id", approved }
        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(hostID, forKey: .hostID); try values.encode(index, forKey: .index)
            try values.encode(original, forKey: .original); try values.encode(reference, forKey: .reference)
            try values.encode(approved, forKey: .approved)
            if let identityID { try values.encode(identityID, forKey: .identityID) }
            else { try values.encodeNil(forKey: .identityID) }
        }
        var description: String { "SSHApproval(redacted)" }
        var debugDescription: String { description }
        var customMirror: Mirror { Mirror(self, children: [:]) }
    }
    let version: Int
    let bundleID: String
    let items: [Item]
    enum CodingKeys: String, CodingKey { case version, bundleID = "bundle_id", items }
    var description: String { "SSHApprovals(redacted)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: [:]) }
    func validate(review: Bool = false) throws {
        guard version == 1, CoreRestoreDestinations.validID(bundleID), (1...32).contains(items.count),
              Set(items.map { "\($0.hostID):\($0.index)" }).count == items.count,
              items.allSatisfy({ $0.approved == !review && $0.hostID.hasPrefix("restore:") && CoreRestoreDestinations.validID(String($0.hostID.dropFirst(8)))
                  && (0..<32).contains($0.index) && Self.reference($0.original) && Self.reference($0.reference)
                  && ($0.identityID.map(CoreRestoreDestinations.validID) ?? true) }) else { throw CoreRuntimeError.invalidRequest }
    }
    static func reference(_ value: String) -> Bool {
        (value.hasPrefix("~/") || value.hasPrefix("/")) && value.utf8.count <= 1024
            && !value.unicodeScalars.contains { $0.value < 33 || $0.value > 126 }
    }
}

struct CoreSSHReview: Decodable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    struct Item: Decodable, Identifiable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
        let hostID: String
        let host: String
        let index: Int
        let reference: String
        let status: String
        let proposal: Proposal?
        struct Proposal: Decodable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
            let reference: String
            let identityID: String?
            let status: String
            enum CodingKeys: String, CodingKey { case reference, identityID = "identity_id", status }
            var description: String { "SSHProposal(redacted)" }
            var debugDescription: String { description }
            var customMirror: Mirror { Mirror(self, children: [:]) }
        }
        var id: String { "\(hostID):\(index)" }
        enum CodingKeys: String, CodingKey { case hostID = "host_id", host, index, reference, status, proposal }
        var description: String { "SSHReference(redacted)" }
        var debugDescription: String { description }
        var customMirror: Mirror { Mirror(self, children: [:]) }
    }
    let version: Int
    let operationID: String
    let bundleID: String
    let items: [Item]
    enum CodingKeys: String, CodingKey { case version, operationID = "operation_id", bundleID = "bundle_id", items }
    var description: String { "SSHReview(redacted)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: [:]) }
    func validate(operationID: String) throws {
        guard version == 1, self.operationID == operationID, CoreRestoreDestinations.validID(bundleID), items.count <= 32,
              Set(items.map(\.id)).count == items.count,
              items.allSatisfy({ $0.hostID.hasPrefix("restore:") && CoreRestoreDestinations.validID(String($0.hostID.dropFirst(8)))
                  && (0..<32).contains($0.index) && !$0.host.isEmpty && $0.host.utf8.count <= 128
                  && CoreSSHApprovals.reference($0.reference) && ["missing", "unresolved", "unsafe_target"].contains($0.status)
                  && ($0.proposal.map { CoreSSHApprovals.reference($0.reference)
                      && ["local_satisfied", "selected_expected"].contains($0.status)
                      && ($0.identityID.map(CoreRestoreDestinations.validID) ?? true) } ?? true) }) else { throw CoreRuntimeError.malformedEvent }
    }
}

// Aggregate advisory status is safe for ordinary Protocol events.
struct CoreSSHResolution: Codable, Equatable, Sendable {
    struct Dependencies: Codable, Equatable, Sendable { let version: Int; let findings: [String] }
    let version: Int
    let action: String
    let ready: Bool
    let pending: Bool
    let dependencies: Dependencies
    let remoteAuthentication: String
    enum CodingKeys: String, CodingKey { case version, action, ready, pending, dependencies, remoteAuthentication = "remote_authentication" }
    var valid: Bool {
        version == 1 && ["blocked", "noop", "create", "merge"].contains(action) && remoteAuthentication == "not_assessed"
            && !(ready && (pending || action == "blocked"))
            && dependencies.version == 1 && dependencies.findings.count <= 6 && dependencies.findings.allSatisfy {
                ["local_satisfied", "selected_expected", "missing", "unresolved", "unsafe_target", "no_file_dependency"].contains($0)
            }
    }
}
