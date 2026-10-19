import Foundation

// The only privileged operations. No Bundle, command, path, UID or environment.
@objc protocol MASServiceProtocol {
    func install(_ appStoreID: String, reply: @escaping (String) -> Void)
    func admission(_ appStoreID: String, reply: @escaping (String) -> Void)
    func readiness(reply: @escaping (String) -> Void)
    func status(reply: @escaping (String) -> Void)
    func recovery(_ operationID: String, action: String, confirmed: Bool, reviewID: String, appStoreIDs: [String], downloadsClear: Bool, reply: @escaping (String) -> Void)
}

// Typed, account-free recovery projection. Raw MAS output never crosses XPC.
struct MASRecoveryReport: Codable {
    var version = 2
    var operationID = ""
    var appStoreID = ""
    var journalState = "unavailable"
    var childState = "unproven"
    var installation = "not_checked"
    var appleServices = "unproven"
    var retryAllowed = false
    var canTerminate = false
    var canForceTerminate = false
    var canReconcile = false
    var canReconcileObservation = false
    var reason = "recovery_unavailable"
    var evidence = ""
    var reviewID = ""
    var canAcceptRisk = false
    var ownership = "unproven"
    var receipt = "unverified"
    var signature = "unverified"
    var completeness = "unverified"
    var allowedAppStoreIDs = [String]()
    func encoded() -> String { (try? String(decoding: JSONEncoder().encode(self), as: UTF8.self)) ?? "{}" }
}
