import Foundation
import Darwin
import Security

// Fixed protected deployment. Never follows a user-supplied path.
func protectedApp() throws {
    var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    try require(descriptor >= 0); defer { close(descriptor) }
    for component in ["Library", "Application Support", "MacseedDesktop", "Macseed.app", "Contents", "Helpers"] {
        let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        try require(next >= 0); close(descriptor); descriptor = next
        var metadata = stat(); try require(fstat(descriptor, &metadata) == 0)
        try require(metadata.st_uid == 0 && metadata.st_mode & 0o022 == 0)
        try requireNoACL(descriptor)
    }
    var app: SecStaticCode?; var requirement: SecRequirement?
    try require(SecStaticCodeCreateWithPath(URL(fileURLWithPath: "/Library/Application Support/MacseedDesktop/Macseed.app") as CFURL, [], &app) == errSecSuccess)
    try require(SecRequirementCreateWithString(Contract.requirement(Contract.app) as CFString, [], &requirement) == errSecSuccess)
    try require(SecStaticCodeCheckValidity(app!, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures), requirement) == errSecSuccess)
}

final class Coordinator {
    let lock = NSLock()
    var retiring = false
    func status(_ session: Session, id: String? = nil) -> String {
        if let id, !Contract.validID(id) { return "invalid_id" }
        guard session.valid() else { return "session_refused" }
        guard lock.try() else { return "busy" }; defer { lock.unlock() }
        guard !retiring else { return "busy" }
        do {
            var metadata = stat()
            if lstat(Contract.directory, &metadata) != 0 {
                return errno == ENOENT ? "unavailable" : "unknown_no_retry"
            }
            let store = try Store(create: false)
            return try store.journalFile.withExclusiveLock(create: false) {
                guard let journal = try store.journalFile.load() else { return "unknown_no_retry" }
                let boot = try Child.bootIdentity()
                guard try recoveryObservationsReady(file: store.journalFile, journal: journal, boot: boot) else { return "unknown_no_retry" }
                return journal.permits(id, caller: session.caller, boot: boot) ? "ready" : "unknown_no_retry"
            }
        } catch { return "unknown_no_retry" }
    }
    func install(_ id: String, session: Session) -> String {
        guard Contract.validID(id) else { return "invalid_id" }
        guard session.valid() else { return "session_refused" }
        guard lock.try() else { return "busy" }; defer { lock.unlock() }
        guard !retiring else { return "busy" }
        do {
            try protectedApp()
            let store = try Store()
            return try store.journalFile.withExclusiveLock {
                if try OwnedExecution.recoverInterruptedOwner(file: store.journalFile) { return "unknown_no_retry" }
                guard let existing = try store.journalFile.load(),
                      try recoveryObservationsReady(file: store.journalFile, journal: existing, boot: Child.bootIdentity()) else { return "unknown_no_retry" }
                try store.journalFile.checkpointHistory()
                guard var journal = try store.journalFile.load() else { return "unknown_no_retry" }
                let boot = try Child.bootIdentity()
                guard try recoveryObservationsReady(file: store.journalFile, journal: journal, boot: boot), journal.permits(id, caller: session.caller, boot: boot) else { return "unknown_no_retry" }
                try store.deploy(); _ = try store.installed()
                guard session.valid(), let account = getpwuid(session.uid) else { return "session_refused" }
                let environment = ["PATH=/usr/bin:/bin:/usr/sbin:/sbin", "HOME=" + String(cString: account.pointee.pw_dir), "SUDO_UID=\(session.uid)", "SUDO_GID=\(session.gid)", "MAS_NO_AUTO_INDEX=1"]
                // Re-check the source barrier even for an existing unspent grant.
                for barrier in journal.blockers {
                    try require(recoveryOwnership(barrier, boot: boot) != "unproven")
                }
                try journal.admitInstall(id, caller: session.caller, boot: boot)
                try store.journalFile.save(journal)
                func invoke(_ command: OwnedCommand, mutation: Bool) throws -> Data {
                    let result = try OwnedExecution.run(file: store.journalFile, command: command, role: mutation ? "install" : "inventory", mutation: mutation, environment: environment, connected: {
                        session.lock.lock(); defer { session.lock.unlock() }; return !session.lost && session.valid()
                    }, resumeWhileAdmitted: { child in
                        session.lock.lock(); defer { session.lock.unlock() }
                        try require(!session.lost && session.valid()); try child.resume()
                    })
                    try require(result.0 == 0); return result.1
                }
                do {
                    let before = try invoke(.inventory, mutation: false)
                    let observation = try MASInventory.inspect(before, id: id, home: String(cString: account.pointee.pw_dir))
                    try require(["verified_present", "absent_in_observed_scope"].contains(observation.result))
                    try require(observation.appleServices != "possible_active_download")
                    let present = observation.result == "verified_present"
                    if !present {
                        _ = try invoke(.install(id), mutation: true)
                        let verified = try MASInventory.inspect(invoke(.inventory, mutation: false), id: id, home: String(cString: account.pointee.pw_dir))
                        try require(verified.result == "verified_present" && verified.appleServices != "possible_active_download")
                    }
                    journal = try store.journalFile.load()!
                    session.lock.lock(); defer { session.lock.unlock() }
                    try require(!session.lost && session.valid())
                    try journal.finishVerified(present: present, verification: "verified_present")
                    try store.journalFile.save(journal)
                    return present ? "already_present" : "succeeded_verified"
                } catch {
                    if var failed = try store.journalFile.load() {
                        if let last = failed.operations.last, !last.mutationMayHaveStarted, last.qualifiedLifetime {
                            failed.transition("failed", reason: "failed_before_mutation")
                            failed.operations[failed.operations.count - 1].outcome = "failed_before_mutation"
                            try store.journalFile.save(failed)
                            return "failed_before_mutation"
                        }
                        failed.transition("unknown", reason: "execution_verification_disconnect_or_timeout"); try store.journalFile.save(failed)
                    }
                    return "unknown_no_retry"
                }
            }
        } catch { return "trust_or_storage_refused" }
    }
}
final class Service: NSObject, MASServiceProtocol {
    let coordinator: Coordinator; let session: Session
    init(_ coordinator: Coordinator, _ session: Session) { self.coordinator = coordinator; self.session = session }
    func install(_ appStoreID: String, reply: @escaping (String) -> Void) {
        DispatchQueue.global().async { reply(self.coordinator.install(appStoreID, session: self.session)) }
    }
    func recovery(_ operationID: String, action: String, confirmed: Bool, reviewID: String, appStoreIDs: [String], downloadsClear: Bool, reply: @escaping (String) -> Void) {
        DispatchQueue.global().async { reply(self.coordinator.recovery(operationID, action: action, confirmed: confirmed, session: self.session, reviewID: reviewID, appStoreIDs: appStoreIDs, downloadsClear: downloadsClear).encoded()) }
    }
    func admission(_ appStoreID: String, reply: @escaping (String) -> Void) {
        DispatchQueue.global().async { reply(self.coordinator.status(self.session, id: appStoreID)) }
    }
    func readiness(reply: @escaping (String) -> Void) { DispatchQueue.global().async { reply("v2:" + self.coordinator.status(self.session)) } }
    func status(reply: @escaping (String) -> Void) { DispatchQueue.global().async { reply(self.coordinator.status(self.session)) } }
}
final class Delegate: NSObject, NSXPCListenerDelegate {
    let coordinator = Coordinator()
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // Only the signed fixed bridge (Core child) or the signed Desktop can call.
        let session = Session(connection); guard session.valid() else { return false }
        // Bind the dynamic classification to the connection's OS-enforced peer
        // requirement. A PID-classification race can only reject a connection;
        // it cannot grant Desktop-only recovery to MASClient or foreign code.
        connection.setCodeSigningRequirement(Contract.requirement(session.isDesktop ? Contract.app : Contract.app + ".mas-client"))
        connection.exportedInterface = NSXPCInterface(with: MASServiceProtocol.self)
        connection.exportedObject = Service(coordinator, session)
        connection.invalidationHandler = { session.disconnect() }; connection.interruptionHandler = { session.disconnect() }
        connection.resume(); return true
    }
}
@main enum Main {
    static func main() throws {
        try require(geteuid() == 0); try protectedApp()
        let delegate = Delegate(); let listener = NSXPCListener(machServiceName: Contract.helper)
        listener.delegate = delegate; listener.resume(); RunLoop.current.run()
    }
}
