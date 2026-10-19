import Foundation
import CryptoKit
import Darwin

struct Caller: Codable, Equatable {
    let uid: UInt32
    let gid: UInt32
    let auditSession: UInt32
}
struct Child: Codable, Equatable {
    let pid: Int32
    let startSeconds: UInt64
    let startMicroseconds: UInt64
    let bootSession: String
}
struct ChildObservation: Codable, Equatable { let role: String; let identity: Child; let at: String; var exitStatus: Int32?; var terminationReason: String? }
struct Transition: Codable, Equatable {
    let at: String
    let state: String
    let reason: String
}
struct OperationRecord: Codable, Equatable {
    let id: UUID
    let type: String
    let appStoreID: String?
    let caller: Caller
    let startedAt: String
    var child: Child?
    var ownership: OperationOwnership?
    var observedChildren: [ChildObservation] = []
    var mutationMayHaveStarted = false
    var exitStatus: Int32?
    var verification: String?
    var outcome: String?
    var evidence: [String: String] = ["apple_services_quiescence": "not_proven", "gui_bootstrap": "not_proven", "mas_sha256": Contract.digest]
    var transitions: [Transition]
}
struct LegacyDecision: Codable, Equatable {
    let decision: String
    let originalSHA256: String
    let evidenceID: String
    let evidenceSHA256: String
    let attributionSource: String
    let historicalOperationID: String?
    let historicalChildIdentity: Child?
    let appleServices: String
    let caller: Caller
    let at: String
    init(originalSHA256: String, evidenceID: String, evidenceSHA256: String, caller: Caller, at: String) {
        self.originalSHA256 = originalSHA256; self.evidenceID = evidenceID; self.evidenceSHA256 = evidenceSHA256
        self.caller = caller; self.at = at
        decision = "operator_reconciled_legacy_diagnostic"
        attributionSource = "external_diagnostic_evidence_and_operator_attestation"
        historicalOperationID = nil; historicalChildIdentity = nil; appleServices = "quiescence_not_proven"
    }
}
struct Journal: Codable {
    var schemaVersion = 4
    var state = "idle"
    var legacy: LegacyDecision?
    var operations = [OperationRecord]()
    // Optional fields decode historical v2/v3 without inventing evidence.
    var archiveHead: String?
    var migrationSHA256: String?
    var reviews: [AdmissionReview]?
    var grants: [AdmissionGrant]?
    var decisions: [AdmissionDecision]?
    static func timestamp() -> String { ISO8601DateFormatter().string(from: Date()) }
    mutating func begin(_ type: String, id: String?, caller: Caller, attemptID: UUID = UUID(), recoveryAdmitted: Bool = false) throws {
        try require(recoveryAdmitted || ["idle", "completed", "failed", "operator_reconciled_legacy_diagnostic", "operator_reconciled_no_mutation"].contains(state))
        try require(operations.count < 64 && caller.uid > 0 && caller.auditSession > 0)
        try require(["deploy", "version", "list", "preflight", "install"].contains(type))
        try require(type == "install" ? id.map(Contract.permitsInstallID) == true : id == nil)
        state = "running"
        operations.append(OperationRecord(id: attemptID, type: type, appStoreID: id, caller: caller,
            startedAt: Self.timestamp(), transitions: [Transition(at: Self.timestamp(), state: state, reason: "admitted_before_launch")]))
    }
    mutating func transition(_ state: String, reason: String) {
        self.state = state
        if !operations.isEmpty {
            if ["completed", "failed", "unknown"].contains(state) {
                operations[operations.count - 1].outcome = state == "unknown" ? "unknown_no_retry" : state
            }
            operations[operations.count - 1].transitions.append(Transition(at: Self.timestamp(), state: state, reason: reason))
        }
    }
}

// The enclosing Store owns protected ancestry and a cross-process flock.
// owner is injected ONLY by unprivileged filesystem tests, never by XPC.
final class JournalFile {
    let directory: Int32
    let owner: uid_t
    static let legacyBytes = Data("{\"state\":\"unknown\"}".utf8)
    static func hash(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    init(_ directory: Int32, owner: uid_t = 0) { self.directory = directory; self.owner = owner }
    func read(_ name: String, at directory: Int32? = nil) throws -> Data? {
        let fd = openat(directory ?? self.directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 { try require(errno == ENOENT); return nil }
        defer { close(fd) }
        var info = stat(); try require(fstat(fd, &info) == 0)
        try require(info.st_uid == owner && info.st_mode & S_IFMT == S_IFREG && info.st_mode & 0o077 == 0 && info.st_nlink == 1 && info.st_size <= 1024 * 1024)
        try requireNoACL(fd)
        return try FileHandle(fileDescriptor: fd, closeOnDealloc: false).readToEnd() ?? Data()
    }
    func load() throws -> Journal? {
        guard let bytes = try read("state.json") else { return Journal() }
        if bytes == Self.legacyBytes { return nil }
        let journal = try JSONDecoder().decode(Journal.self, from: bytes)
        try require([2, 3, 4].contains(journal.schemaVersion) && journal.operations.count <= 64)
        try require(["idle", "launching", "running", "completed", "failed", "unknown", "operator_reconciled_legacy_diagnostic", "operator_reconciled_no_mutation"].contains(journal.state))
        if let head = journal.archiveHead {
            try require(head.count == 64 && head.allSatisfy { $0.isHexDigit })
            guard let bytes = try read("history-" + head + ".json") else { throw Failure.refused }
            try require(Self.hash(bytes) == head)
        }
        return journal
    }
    // Caller holds operation.lock. Archive first, publish the new head last.
    // A crash before head publication leaves an idempotently reusable archive.
    func checkpointHistory() throws {
        guard let raw = try read("state.json"), var journal = try load() else { return }
        let migrate = journal.schemaVersion < 4
        let compact = (journal.operations.count >= 32 || (journal.grants?.count ?? 0) >= 16) && !["launching", "running"].contains(journal.state)
        guard migrate || compact else { return }
        let digest = Self.hash(raw)
        let name = "history-" + digest + ".json"
        if let existing = try read(name) { try require(existing == raw) }
        else { try atomic(raw, name: name, exclusive: true, mode: 0o400) }
        if migrate { journal.migrationSHA256 = digest }
        if compact {
            // Unresolved barriers and the last attempt stay in the active window.
            let keep = Set(journal.blockers.map(\.id) + journal.operations.suffix(1).map(\.id))
            journal.operations.removeAll { !keep.contains($0.id) }
            journal.reviews = journal.reviews?.filter { keep.contains($0.source) }
            journal.grants = journal.grants?.filter { grant in
                keep.contains(grant.source) && grant.expires > Date() && grant.uptimeExpiration > ProcessInfo.processInfo.systemUptime &&
                    journal.reviews?.contains(where: { $0.id == grant.reviewID }) == true && grant.entries.contains(where: { !$0.consumed })
            }
            journal.decisions = journal.decisions?.filter { keep.contains($0.source) }
        }
        journal.schemaVersion = 4; journal.archiveHead = digest
        try atomic(JSONEncoder().encode(journal), name: "state.json")
    }
    func atomic(_ bytes: Data, name: String, at directory: Int32? = nil, exclusive: Bool = false, mode: mode_t = 0o600) throws {
        let dir = directory ?? self.directory
        let temporary = ".journal-" + UUID().uuidString
        let fd = openat(dir, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
        try require(fd >= 0)
        defer { close(fd); unlinkat(dir, temporary, 0) }
        try FileHandle(fileDescriptor: fd, closeOnDealloc: false).write(contentsOf: bytes)
        try require(fsync(fd) == 0)
        if exclusive { try require(renameatx_np(dir, temporary, dir, name, UInt32(RENAME_EXCL)) == 0) }
        else { try require(renameat(dir, temporary, dir, name) == 0) }
        try require(fsync(dir) == 0)
    }
    func withExclusiveLock<T>(create: Bool = true, _ body: () throws -> T) throws -> T {
        let fd = openat(directory, "operation.lock", O_RDWR | (create ? O_CREAT : 0) | O_NOFOLLOW | O_CLOEXEC, 0o600)
        try require(fd >= 0); defer { close(fd) }
        var info = stat(); try require(fstat(fd, &info) == 0)
        try require(info.st_uid == owner && info.st_mode & S_IFMT == S_IFREG && info.st_mode & 0o077 == 0 && info.st_nlink == 1)
        try requireNoACL(fd)
        try require(flock(fd, LOCK_EX | LOCK_NB) == 0)
        return try body()
    }
    func save(_ journal: Journal) throws {
        if let raw = try read("state.json") {
            if raw == Self.legacyBytes {
                try require(journal.state == "operator_reconciled_legacy_diagnostic" && journal.legacy?.originalSHA256 == Self.hash(raw))
                let archive = openat(directory, "legacy-" + Self.hash(raw), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                try require(archive >= 0); defer { close(archive) }
                try require(try read("journal.original.json", at: archive) == raw)
                try require(try read("decision.json", at: archive) != nil)
            } else {
                let previous = try JSONDecoder().decode(Journal.self, from: raw)
                try require(journal.schemaVersion >= previous.schemaVersion)
                try require(journal.operations.count >= previous.operations.count)
                try require(Array(journal.operations.prefix(previous.operations.count)).map { $0.id } == previous.operations.map { $0.id })
                try require(journal.legacy == previous.legacy)
                for index in previous.operations.indices {
                    let old = previous.operations[index]; let next = journal.operations[index]
                    if old.outcome == "unknown_no_retry" { try require(next.outcome == old.outcome) }
                    if (previous.state == "unknown" && journal.operations.count > previous.operations.count) || index < previous.operations.count - 1 || (!["launching", "running", "unknown"].contains(previous.state)) {
                        try require(old == next)
                    } else {
                        try require(old.type == next.type && old.appStoreID == next.appStoreID && old.caller == next.caller && old.startedAt == next.startedAt)
                        try require(next.transitions.count >= old.transitions.count && Array(next.transitions.prefix(old.transitions.count)) == old.transitions)
                        if let prior = old.ownership {
                            guard let current = next.ownership else { throw Failure.refused }
                            try require(prior.bootIdentity == current.bootIdentity && prior.serviceLifetime == current.serviceLifetime)
                            try require(current.launches.count >= prior.launches.count)
                            for index in prior.launches.indices {
                                let a = prior.launches[index], b = current.launches[index]
                                try require(a.id == b.id && a.role == b.role)
                                if let child = a.child { try require(b.child == child) }
                                if let pid = a.helperPID { try require(b.helperPID == pid) }
                                try require(!a.resumeAuthorized || b.resumeAuthorized)
                                if let status = a.exitStatus { try require(b.exitStatus == status) }
                                if let reason = a.uncertainty { try require(b.uncertainty == reason) }
                            }
                        }
                        try require(!old.mutationMayHaveStarted || next.mutationMayHaveStarted)
                        try require(next.observedChildren.count >= old.observedChildren.count)
                        for child in old.observedChildren.indices {
                            let a = old.observedChildren[child]; let b = next.observedChildren[child]
                            try require(a.role == b.role && a.identity == b.identity && a.at == b.at)
                            if let status = a.exitStatus { try require(status == b.exitStatus) }
                            if let reason = a.terminationReason { try require(reason == b.terminationReason) }
                        }
                    }
                }
                if previous.state == "unknown", journal.operations.count > previous.operations.count {
                    guard let added = journal.operations.last else { throw Failure.refused }
                    try require(previous.blockers.allSatisfy { barrier in
                        (journal.grants ?? []).contains { grant in
                            grant.source == barrier.id && grant.caller == added.caller &&
                            grant.entries.contains { $0.attemptID == added.id && $0.appStoreID == added.appStoreID && $0.consumed }
                        }
                    })
                } else if previous.state == "unknown" {
                    try require(journal.state == "unknown")
                }
                for old in previous.grants ?? [] {
                    guard let next = journal.grants?.first(where: { $0.id == old.id }) else { throw Failure.refused }
                    var normalized = next
                    try require(next.entries.count == old.entries.count)
                    for i in old.entries.indices {
                        try require(!old.entries[i].consumed || next.entries[i].consumed)
                        normalized.entries[i].consumed = old.entries[i].consumed
                    }
                    try require(normalized == old)
                }
                try require(Array((journal.decisions ?? []).prefix((previous.decisions ?? []).count)) == (previous.decisions ?? []))
            }
        }
        let bytes = try JSONEncoder().encode(journal)
        try require(bytes.count <= 1024 * 1024)
        try atomic(bytes, name: "state.json")
    }
    func reconcile(caller: Caller, acknowledged: Bool, noActiveOwnedWork: Bool, evidence: Data) throws -> Journal {
        try require(acknowledged && noActiveOwnedWork)
        try require(try read("state.json") == Self.legacyBytes)
        try require(Self.hash(evidence) == Contract.legacyEvidenceSHA256)
        let sha = Self.hash(Self.legacyBytes)
        let archive = "legacy-" + sha
        if mkdirat(directory, archive, 0o700) != 0 { try require(errno == EEXIST) }
        let dir = openat(directory, archive, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        try require(dir >= 0); defer { close(dir) }
        var info = stat(); try require(fstat(dir, &info) == 0)
        try require(info.st_uid == owner && info.st_mode & 0o077 == 0)
        try requireNoACL(dir)
        let decision = LegacyDecision(originalSHA256: sha, evidenceID: Contract.legacyEvidenceID,
            evidenceSHA256: Contract.legacyEvidenceSHA256, caller: caller, at: Journal.timestamp())
        // Resume only a matching private archive; never replace historical data.
        for (name, bytes) in [("journal.original.json", Self.legacyBytes), ("evidence.md", evidence)] {
            if let previous = try read(name, at: dir) { try require(previous == bytes) }
            else { try atomic(bytes, name: name, at: dir, exclusive: true, mode: 0o400) }
        }
        let manifest: LegacyDecision
        if let bytes = try read("decision.json", at: dir) {
            manifest = try JSONDecoder().decode(LegacyDecision.self, from: bytes)
            try require(manifest.decision == decision.decision && manifest.historicalOperationID == nil && manifest.historicalChildIdentity == nil && manifest.appleServices == decision.appleServices && manifest.attributionSource == decision.attributionSource)
            try require(manifest.originalSHA256 == sha && manifest.evidenceSHA256 == Contract.legacyEvidenceSHA256 && manifest.evidenceID == Contract.legacyEvidenceID)
        } else {
            manifest = decision
            try atomic(JSONEncoder().encode(decision), name: "decision.json", at: dir, exclusive: true, mode: 0o400)
        }
        try require(fsync(dir) == 0 && fsync(directory) == 0)
        var next = Journal(); next.state = decision.decision; next.legacy = manifest
        try save(next)
        return next
    }
}

enum InstallAdmission {
    static func reason(id: String, journal: Journal?, sessionValid: Bool, connected: Bool, busy: Bool, executableTrusted: Bool) -> String? {
        guard Contract.validID(id) else { return "invalid_app_store_id" }
        guard Contract.permitsInstallID(id) else { return "unqualified_app_store_id" }
        guard sessionValid && connected else { return "wrong_user_or_session" }
        guard !busy else { return "operation_busy" }
        guard let journal, [2, 3, 4].contains(journal.schemaVersion) else { return "legacy_unknown_requires_operator_reconciliation" }
        guard ["idle", "completed", "failed", "operator_reconciled_legacy_diagnostic", "operator_reconciled_no_mutation"].contains(journal.state) else { return "unknown_no_retry" }
        guard executableTrusted else { return "untrusted_mas" }
        return nil
    }
}

// Admission is separate from immutable attempt outcome. These are root-issued
// records, never capabilities supplied by Core or executable input from Desktop.
struct AdmissionReview: Codable, Equatable {
    let id: UUID
    let source: UUID
    let operationSHA256: String
    let caller: Caller
    let boot: String
    let expires: Date
    let ownership: String
    let installation: String
    let appleServices: String
    var uptimeExpiration = ProcessInfo.processInfo.systemUptime + 600
}
struct GrantEntry: Codable, Equatable {
    let appStoreID: String
    let attemptID: UUID
    var consumed = false
}
struct AdmissionGrant: Codable, Equatable {
    let id: UUID
    let source: UUID
    let reviewID: UUID
    let operationSHA256: String
    let caller: Caller
    let boot: String
    let expires: Date
    let scope: String
    let appleDownloadReview: String
    var entries: [GrantEntry]
    var uptimeExpiration = ProcessInfo.processInfo.systemUptime + 600
}
struct AdmissionDecision: Codable, Equatable {
    let source: UUID
    let attempt: UUID
    let decision: String
    let at: String
}
extension OperationRecord {
    var qualifiedLifetime: Bool {
        guard let ownership, !mutationMayHaveStarted || !ownership.launches.isEmpty else { return false }
        return ownership.launches.allSatisfy { $0.child?.bootSession == ownership.bootIdentity && $0.child != nil && $0.resumeAuthorized && $0.exitStatus != nil && $0.uncertainty == nil }
    }
    var terminalVerified: Bool {
        guard qualifiedLifetime else { return false }
        if !mutationMayHaveStarted { return ["completed", "already_present", "failed_before_mutation"].contains(outcome ?? "") }
        return outcome == "succeeded_verified" && verification == "inventory_bundle_signature_receipt_verified" &&
            ownership?.launches.contains(where: { $0.role == "install" && $0.exitStatus == 0 }) == true &&
            ownership?.launches.allSatisfy({ $0.exitStatus == 0 }) == true
    }
    var digest: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return (try? JournalFile.hash(encoder.encode(self))) ?? ""
    }
}
extension Journal {
    var blockers: [OperationRecord] {
        operations.filter { operation in
            if operation.terminalVerified { return false }
            // A new interrupted attempt replaces the reviewed barrier, not its history.
            // Its own ownership must be reviewed before another grant can be issued.
            if (grants ?? []).contains(where: { grant in
                grant.source == operation.id && grant.entries.contains { entry in
                    entry.consumed && operations.contains { $0.id == entry.attemptID && $0.outcome == "unknown_no_retry" }
                }
            }) { return false }
            // A later verified retry satisfies admission, never rewrites the old attempt.
            return !(decisions ?? []).contains { decision in
                decision.source == operation.id &&
                ["verified_retry_under_accepted_risk", "operator_reconciled_no_mutation"].contains(decision.decision)
            }
        }
    }
    func eligibleGrant(_ grant: AdmissionGrant, caller: Caller, boot: String, now: Date = Date()) -> Bool {
        guard grant.caller == caller, grant.boot == boot, now < grant.expires, ProcessInfo.processInfo.systemUptime < grant.uptimeExpiration,
              reviews?.contains(where: { $0.id == grant.reviewID && $0.source == grant.source }) == true,
              let source = blockers.first(where: { $0.id == grant.source }), source.digest == grant.operationSHA256,
              grant.appleDownloadReview == "operator_reports_no_related_active_download" else { return false }
        // A new unknown invalidates all remaining permissions from an older review.
        return blockers.allSatisfy { $0.id == grant.source }
    }
    func permits(_ id: String?, caller: Caller, boot: String, now: Date = Date()) -> Bool {
        guard !["launching", "running"].contains(state) else { return false }
        if blockers.isEmpty { return state != "unknown" }
        return (grants ?? []).contains { grant in
            eligibleGrant(grant, caller: caller, boot: boot, now: now) &&
            grant.entries.contains { !$0.consumed && (id == nil || $0.appStoreID == id) }
        }
    }
    mutating func issueGrant(reviewID: UUID, source: UUID, ids: [String], scope: String,
                             caller: Caller, boot: String, confirmed: Bool, downloadsClear: Bool, now: Date = Date()) throws {
        try require(confirmed && downloadsClear && !ids.isEmpty && ids.count <= 64 && Set(ids).count == ids.count && ids.allSatisfy(Contract.validID))
        guard let review = reviews?.first(where: { $0.id == reviewID && $0.source == source }),
              let operation = blockers.first(where: { $0.id == source }) else { throw Failure.refused }
        try require(blockers.count == 1 && review.caller == caller && review.boot == boot && review.expires > now && ProcessInfo.processInfo.systemUptime < review.uptimeExpiration)
        try require(review.operationSHA256 == operation.digest && ["prior_boot_ended", "qualified_owned_exit"].contains(review.ownership))
        try require(["verified_present", "absent_in_observed_scope"].contains(review.installation))
        try require(review.appleServices != "known_active")
        try require(scope == "retry" ? ids == [operation.appStoreID] : scope == "remaining" && !ids.contains(operation.appStoreID ?? ""))
        // One consent per review; a second click never mints another permission.
        try require(!(grants ?? []).contains { $0.reviewID == reviewID })
        var values = grants ?? []
        values.append(AdmissionGrant(id: UUID(), source: source, reviewID: reviewID, operationSHA256: operation.digest,
            caller: caller, boot: boot, expires: min(review.expires, now.addingTimeInterval(600)), scope: scope,
            appleDownloadReview: "operator_reports_no_related_active_download",
            entries: ids.map { GrantEntry(appStoreID: $0, attemptID: UUID()) }, uptimeExpiration: review.uptimeExpiration))
        grants = values
    }
    // Caller saves this entire head before any spawn. A lost reply cannot unspend it.
    mutating func admitInstall(_ id: String, caller: Caller, boot: String, now: Date = Date()) throws {
        try require(permits(id, caller: caller, boot: boot, now: now))
        var attempt = UUID(); let recovery = !blockers.isEmpty
        if recovery {
            guard let index = grants?.firstIndex(where: { eligibleGrant($0, caller: caller, boot: boot, now: now) && $0.entries.contains { !$0.consumed && $0.appStoreID == id } }),
                  let entry = grants?[index].entries.firstIndex(where: { !$0.consumed && $0.appStoreID == id }) else { throw Failure.refused }
            attempt = grants![index].entries[entry].attemptID
            grants![index].entries[entry].consumed = true
        }
        try begin("install", id: id, caller: caller, attemptID: attempt, recoveryAdmitted: recovery)
        operations[operations.count - 1].ownership = OperationOwnership(bootIdentity: boot)
        transition("launching", reason: "durable_admission_and_grant_consumption_before_spawn")
    }
    mutating func finishVerified(present: Bool, verification: String) throws {
        try require(verification == "verified_present")
        guard let operation = operations.last, operation.qualifiedLifetime else { throw Failure.refused }
        try require(operation.ownership?.launches.allSatisfy { $0.exitStatus == 0 } == true)
        transition("completed", reason: present ? "already_present" : "succeeded_verified")
        operations[operations.count - 1].outcome = present ? "already_present" : "succeeded_verified"
        operations[operations.count - 1].verification = "inventory_bundle_signature_receipt_verified"
        if let grant = grants?.first(where: { $0.scope == "retry" && $0.entries.contains { $0.attemptID == operation.id && $0.consumed } }) {
            var values = decisions ?? []
            values.append(AdmissionDecision(source: grant.source, attempt: operation.id, decision: "verified_retry_under_accepted_risk", at: Self.timestamp()))
            decisions = values
        }
    }
}
