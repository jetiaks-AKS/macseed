import Foundation

// Decodes the existing V1 projection. No observers or comparison predicates live here.
struct CoreComparisonResult: Decodable {
    let readOnly: Bool
    let publicationOccurred: Bool
    let targetMutationMayHaveStarted: Bool
    let comparison: Summary
    let comparisonRecords: [Row]
    let verification: Verification
    let records: Records
    let extra: Extras
    enum CodingKeys: String, CodingKey {
        case readOnly = "read_only", publicationOccurred = "publication_occurred"
        case targetMutationMayHaveStarted = "target_mutation_may_have_started"
        case comparison, comparisonRecords = "comparison_records", verification, records, extra
    }
    struct Summary: Decodable {
        let status: String
        let verdict: String
        let alsoIncomplete: Bool
        let counts: [String: Int]
        enum CodingKeys: String, CodingKey { case status, verdict, alsoIncomplete = "also_incomplete", counts }
    }
    struct Row: Decodable {
        let recordID: String
        let domain: String
        let itemID: String
        let comparisonKind: String
        let reason: String?
        let phase: String?
        let support: String
        enum CodingKeys: String, CodingKey {
            case recordID = "record_id", domain, itemID = "item_id", comparisonKind = "comparison_kind", reason, phase, support
        }
    }
    struct Verification: Decodable { let status: String }
    struct Owner: Decodable {
        let recordID: String
        let domain: String
        let itemID: String
        enum CodingKeys: String, CodingKey { case recordID = "record_id", domain, itemID = "item_id" }
    }
    struct Coverage: Decodable {
        let recordID: String
        let domain: String
        let itemID: String
        let disposition: String
        let sourceStatus: String
        enum CodingKeys: String, CodingKey {
            case recordID = "record_id", domain, itemID = "item_id", disposition, sourceStatus = "source_status"
        }
    }
    struct Diagnostic: Decodable {
        let recordID: String
        let code: String
        let severity: String
        let phase: String
        enum CodingKeys: String, CodingKey { case recordID = "record_id", code, severity, phase }
    }
    struct Records: Decodable {
        let status: String
        let verificationRecords: [Owner]
        let coverageRecords: [Coverage]
        let operationRecords: [Owner]
        let diagnostics: [Diagnostic]
        enum CodingKeys: String, CodingKey {
            case status, verificationRecords = "verification_records", coverageRecords = "coverage_records"
            case operationRecords = "operation_records", diagnostics
        }
    }
    struct Extras: Decodable {
        let domains: [Domain]
        let items: [Item]
        struct Domain: Decodable {
            let domain: String
            let status: String
            let count: Int?
            let reason: String?
        }
        struct Item: Decodable {
            let domain: String
            let itemID: String
            enum CodingKeys: String, CodingKey { case domain, itemID = "item_id" }
        }
    }

    // Presentation must fail closed on incomplete/contradictory evidence, especially extras.
    // This checks the wire projection, never derives a replacement Core verdict.
    func validate() throws {
        let keys = ["matching", "missing", "differing", "unverified", "unsupported", "unresolved", "extra", "unknown_difference"]
        guard readOnly, !publicationOccurred, !targetMutationMayHaveStarted,
              records.status == "complete", comparison.status == "complete", verification.status == "complete",
              keys.allSatisfy({ (comparison.counts[$0] ?? -1) >= 0 }),
              ["incomplete", "differences_detected", "no_differences_detected", "no_comparable_requirements"].contains(comparison.verdict),
              Set(comparisonRecords.map(\.recordID)).count == comparisonRecords.count,
              comparisonRecords.allSatisfy({ ["matching", "missing", "differing", "unverified"].contains($0.comparisonKind)
                  && ["supported", "unsupported"].contains($0.support) }),
              records.coverageRecords.allSatisfy({ ["resolved", "unresolved", "excluded", "no_requirement"].contains($0.disposition) }) else {
            throw CoreRuntimeError.malformedEvent
        }
        for kind in ["matching", "missing", "differing", "unverified"] {
            guard comparison.counts[kind] == comparisonRecords.filter({ $0.comparisonKind == kind }).count else {
                throw CoreRuntimeError.malformedEvent
            }
        }
        guard comparison.counts["unsupported"] == comparisonRecords.filter({ $0.support == "unsupported" }).count,
              comparison.counts["unknown_difference"] == comparisonRecords.filter({ $0.reason == "unknown_difference" }).count,
              comparison.counts["unresolved"] == records.coverageRecords.filter({ $0.disposition == "unresolved" }).count,
              Set(extra.domains.map(\.domain)).count == extra.domains.count else { throw CoreRuntimeError.malformedEvent }
        let supportedExtras = ["homebrew-casks", "app-store", "vscode-extensions"]
        for domain in extra.domains {
            guard supportedExtras.contains(domain.domain), ["available", "unavailable", "not_applicable"].contains(domain.status) else {
                throw CoreRuntimeError.malformedEvent
            }
            let count = extra.items.filter { $0.domain == domain.domain }.count
            guard domain.status == "available" ? domain.count == count : (domain.count == nil && count == 0) else {
                throw CoreRuntimeError.malformedEvent
            }
        }
        guard extra.items.allSatisfy({ item in extra.domains.contains { $0.domain == item.domain && $0.status == "available" } }),
              comparison.counts["extra"] == extra.items.count else { throw CoreRuntimeError.malformedEvent }
        if ["no_differences_detected", "no_comparable_requirements"].contains(comparison.verdict) {
            guard !comparison.alsoIncomplete,
                  ["missing", "differing", "unverified", "unresolved", "extra"].allSatisfy({ comparison.counts[$0] == 0 }) else {
                throw CoreRuntimeError.malformedEvent
            }
            guard comparison.verdict == "no_differences_detected" ? (comparison.counts["matching"] ?? 0) > 0 : comparison.counts["matching"] == 0 else {
                throw CoreRuntimeError.malformedEvent
            }
        }
    }
}
