import Foundation


enum Contract {
    static let app = "org.macseed.desktop"
    static let helper = "org.macseed.desktop.mas-helper"
    static let certificate = "E898826915F0BFAD30789097118EDBBF619BC07E"
    // Reviewed build provenance, not a hash supplied by an XPC caller.
    static let digest = "d10cc734ca3e3af8b403a5b30215dbb6b8b179632451e9bb381376061a0808bf"
    static let source = "/Library/Application Support/MacseedDesktop/Macseed.app/Contents/Helpers/mas"
    static let directory = "/Library/Application Support/MacseedMAS"
    static let lifetimeQualificationOnly = false
    static let lifetimeDirectoryName = "MacseedMAS"
    static let executableName = "mas-" + digest
    static let suspendedMASLaunchQualified = true // v6 root version gate; install remains experimental.
    static let liveInstallEnabled = true // Execute only after native Desktop approval.
    static let legacyEvidenceID = "TrustedMAS/LIVE-RESULTS-2026-10-18.md"
    static let legacyEvidenceSHA256 = "5589d4a589d945f7209c82a88e015656380d4c71f1747f0cdbacfbcbffc391f8"
    static let evidencePath = "/Library/Application Support/MacseedDesktop/Macseed.app/Contents/Resources/legacy-evidence.md"
    static func permitsInstallID(_ id: String) -> Bool { validID(id) }
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
