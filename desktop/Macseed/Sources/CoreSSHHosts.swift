import CryptoKit
import Foundation

// Optional private display evidence. Never enters requests, logs or Apply decisions.
struct CoreSSHHosts: Decodable, Equatable, Sendable, CustomStringConvertible {
    let version: Int
    let snapshotID: String
    let observationID: String
    let comparisonRecordID: String?
    let preparedPlanID: String?
    let planItemID: String?
    let hosts: [Host]
    var description: String { "CoreSSHHosts(redacted)" }
    enum CodingKeys: String, CodingKey {
        case version, hosts, snapshotID = "snapshot_id", observationID = "observation_id"
        case comparisonRecordID = "comparison_record_id", preparedPlanID = "prepared_plan_id", planItemID = "plan_item_id"
    }
    private struct Field: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    private static func checkKeys(_ decoder: Decoder, allowed: Set<String>) throws {
        let keys = try decoder.container(keyedBy: Field.self).allKeys.map(\.stringValue)
        guard Set(keys).isSubset(of: allowed) else { throw CoreRuntimeError.malformedEvent }
    }
    init(from decoder: Decoder) throws {
        try Self.checkKeys(decoder, allowed: ["version", "snapshot_id", "observation_id", "comparison_record_id", "prepared_plan_id", "plan_item_id", "hosts"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        snapshotID = try values.decode(String.self, forKey: .snapshotID)
        observationID = try values.decode(String.self, forKey: .observationID)
        comparisonRecordID = try values.decodeIfPresent(String.self, forKey: .comparisonRecordID)
        preparedPlanID = try values.decodeIfPresent(String.self, forKey: .preparedPlanID)
        planItemID = try values.decodeIfPresent(String.self, forKey: .planItemID)
        hosts = try values.decode([Host].self, forKey: .hosts)
    }
    struct Host: Decodable, Equatable, Sendable, CustomStringConvertible {
        let itemID: String
        let label: String
        let state: String
        let reason: String?
        let disposition: String?
        var description: String { "SSHHost(redacted)" }
        enum CodingKeys: String, CodingKey { case itemID = "item_id", label, state, reason, disposition }
        init(from decoder: Decoder) throws {
            try CoreSSHHosts.checkKeys(decoder, allowed: ["item_id", "label", "state", "reason", "disposition"])
            let values = try decoder.container(keyedBy: CodingKeys.self)
            itemID = try values.decode(String.self, forKey: .itemID)
            label = try values.decode(String.self, forKey: .label)
            state = try values.decode(String.self, forKey: .state)
            reason = try values.decodeIfPresent(String.self, forKey: .reason)
            disposition = try values.decodeIfPresent(String.self, forKey: .disposition)
        }
    }
    static func identity(_ alias: String) -> String {
        "restore:" + SHA256.hash(data: Data(("ssh-configuration\0" + alias).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func validate() throws {
        guard version == 1, (1...2048).contains(hosts.count),
              [snapshotID, observationID].allSatisfy({ $0.range(of: "^[0-9a-f]{64}\\z", options: .regularExpression) != nil }),
              Set(hosts.map(\.itemID)).count == hosts.count,
              Set(hosts.map { $0.label.lowercased() }).count == hosts.count,
              hosts.allSatisfy({ host in
                  host.label.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,159}\\z", options: .regularExpression) != nil
                    && host.itemID == Self.identity(host.label)
                    && ["matching", "missing", "differing", "unsupported", "unverified"].contains(host.state)
                    && host.reason == (host.state == "differing" ? "target_conflict" : host.state == "unsupported" ? "unsupported_target" : host.state == "unverified" ? "observation_failed" : nil)
              }) else { throw CoreRuntimeError.malformedEvent }
        let states = Set(hosts.map(\.state))
        guard states.isDisjoint(with: ["unsupported", "unverified"]) || states.count == 1 else { throw CoreRuntimeError.malformedEvent }
    }
    func validate(comparison: CoreComparisonResult) throws {
        try validate()
        let rows = comparison.comparisonRecords.filter { $0.domain == "ssh-configuration" && $0.itemID == "config" }
        let owners = comparison.records.verificationRecords.filter { $0.recordID == comparisonRecordID }
        let states = Set(hosts.map(\.state))
        let kind = !states.isDisjoint(with: ["unsupported", "unverified"]) ? "unverified"
            : states.contains("differing") ? "differing" : states.contains("missing") ? "missing" : "matching"
        guard preparedPlanID == nil, planItemID == nil, hosts.allSatisfy({ $0.disposition == nil }),
              rows.count == 1, rows[0].recordID == comparisonRecordID, rows[0].comparisonKind == kind,
              (rows[0].support == "unsupported") == states.contains("unsupported"),
              owners.count == 1, owners[0].domain == "ssh-configuration", owners[0].itemID == "config",
              owners[0].predicate == "supported_config_match" else { throw CoreRuntimeError.malformedEvent }
    }
    func validate(plan: CoreRestorePreparation, catalog: CoreRestoreInspection.Inventory) throws {
        let selected = plan.selection.items["ssh-configuration"] ?? []
        let expected = (catalog.inventory.first { $0.domain == "ssh-configuration" }?.items ?? []).filter {
            plan.selection.categories.contains("ssh-configuration") || selected.contains($0.id)
        }
        try validate(plan: plan, expectedIDs: expected.map(\.id), labels: expected.map(\.label))
    }
    func validate(update: CoreSecureComparison, plan: CoreRestorePreparation) throws {
        guard let original = plan.sshHostPresentation, snapshotID == original.snapshotID,
              observationID == original.observationID, hosts.map(\.state) == original.hosts.map(\.state),
              update.decision != .conflict || !hosts.contains(where: { $0.disposition == "planned" }) else {
            throw CoreRuntimeError.malformedEvent
        }
        var current = plan
        current.sshResolution = update.sshResolution ?? plan.sshResolution
        try validate(plan: current, expectedIDs: original.hosts.map(\.itemID), labels: original.hosts.map(\.label))
    }
    private func validate(plan: CoreRestorePreparation, expectedIDs: [String], labels: [String]) throws {
        try validate()
        let rows = plan.plan.filter { $0.domain == "ssh-configuration" }
        let owners = rows.filter { ["config", "missing-profiles"].contains($0.itemID) }
        guard comparisonRecordID == nil, preparedPlanID == plan.preparedPlanID,
              owners.count == 1, owners[0].itemID == planItemID,
              hosts.map(\.itemID) == expectedIDs, hosts.map(\.label) == labels,
              hosts.allSatisfy({ host in
                  switch host.state {
                  case "matching": return host.disposition == "satisfied"
                  case "missing": return ["planned", "blocked"].contains(host.disposition ?? "")
                  default: return host.disposition == "blocked"
                  }
              }), owners[0].disposition != "satisfied" || hosts.allSatisfy({ $0.state == "matching" }) else {
            throw CoreRuntimeError.malformedEvent
        }
        let expectedState = ["target_conflict": "differing", "missing_profiles": "missing", "unsupported_predicate": "unsupported", "observation_failed": "unverified"]
        if let state = owners[0].reason.flatMap({ expectedState[$0] }), !hosts.contains(where: { $0.state == state }) {
            throw CoreRuntimeError.malformedEvent
        }
        if hosts.contains(where: { $0.disposition == "planned" }) {
            guard plan.readiness.ready, plan.errorCount == 0, owners[0].action == "create", owners[0].disposition == "planned",
                  plan.sshResolution?.ready != false,
                  hosts.allSatisfy({ ["matching", "missing"].contains($0.state) }),
                  rows.allSatisfy({ ["planned", "satisfied"].contains($0.disposition)
                    || ($0.itemID == "scope" && $0.disposition == "warning" && $0.reason == "partial_source_coverage")
                    || ($0.isSSHDependency && plan.sshResolution?.ready == true) }) else {
                throw CoreRuntimeError.malformedEvent
            }
        }
    }
}
