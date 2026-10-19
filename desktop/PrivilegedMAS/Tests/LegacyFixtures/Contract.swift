import Foundation

@objc protocol MASDiagnostics {
    func qualifyLifetimeVersion(reply: @escaping (String) -> Void)
    func lifetimeQualificationStatus(reply: @escaping (String) -> Void)
    func observeProcesses(reply: @escaping (String) -> Void)
    func perform(_ operation: String, reply: @escaping (String) -> Void)
    func preflight(_ appStoreID: String, reply: @escaping (String) -> Void)
    func install(_ appStoreID: String, confirmed: Bool, reply: @escaping (String) -> Void)
    func reconcileLegacyDiagnostic(_ acknowledged: Bool, reply: @escaping (String) -> Void)
}

enum Contract {
    static let app = "org.macseed.development.TrustedMAS"
    static let helper = app + ".helper"
    static let certificate = "E898826915F0BFAD30789097118EDBBF619BC07E"
    // Reviewed build provenance, not a hash supplied by an XPC caller.
    static let digest = "d10cc734ca3e3af8b403a5b30215dbb6b8b179632451e9bb381376061a0808bf"
    static let source = "/Library/Application Support/MacseedTrustedMASPoC-App/MacseedTrustedMASPoC.app/Contents/Helpers/mas"
    static let directory = "/Library/Application Support/MacseedTrustedMASPoC"
    static let lifetimeQualificationOnly = false
    static let lifetimeDirectoryName = "MacseedTrustedMASPoC-Lifetime-v5"
    static let targetID = "425264550" // Development test selection, not the adapter contract.
    static let installAllowlist: Set<String> = [targetID]
    static let suspendedMASLaunchQualified = true // v6 root version gate; install remains experimental.
    static let liveInstallEnabled = true // Development candidate only; explicit live gate still required.
    static let legacyEvidenceID = "TrustedMAS/LIVE-RESULTS-2026-10-18.md"
    static let legacyEvidenceSHA256 = "5589d4a589d945f7209c82a88e015656380d4c71f1747f0cdbacfbcbffc391f8"
    static let evidencePath = "/Library/Application Support/MacseedTrustedMASPoC-App/MacseedTrustedMASPoC.app/Contents/Resources/legacy-evidence.md"
    static func installDecision(id: String, confirmed: Bool, present: Bool) -> String {
        guard validID(id) else { return "invalid_app_store_id" }
        guard installAllowlist.contains(id) else { return "unqualified_app_store_id" }
        guard confirmed else { return "explicit_confirmation_required" }
        return present ? "already_present_no_reinstall" : "admitted"
    }
    static func permitsInstallID(_ id: String) -> Bool { validID(id) && installAllowlist.contains(id) }
    static let executableName = "mas"
    static func validID(_ id: String) -> Bool {
        guard !id.isEmpty, id.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }), let number = UInt64(id), number > 0 else { return false }
        return String(number) == id
    }
    static let operations: Set<String> = ["deploy", "version", "list", "state"]
    static func requirement(_ identifier: String) -> String {
        "anchor apple generic and identifier \"\(identifier)\" and certificate leaf = H\"\(certificate)\""
    }
    static func admission(_ operation: String, uid: UInt32, console: UInt32, graphical: Bool) -> Bool {
        operations.contains(operation) && uid > 0 && uid == console && graphical
    }
    static func allowsStart(_ state: String) -> Bool {
        ["idle", "completed", "failed", "operator_reconciled_legacy_diagnostic"].contains(state)
    }
}
