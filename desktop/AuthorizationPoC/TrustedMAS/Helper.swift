import Foundation
import Darwin
import Security
import SystemConfiguration
import CryptoKit

// All ancestors are opened separately without following links. The deployment
// directory and all children stay private to root; no caller-supplied paths.
enum StoreScope {
    case legacy, lifetimeQualification
    var directoryName: String { self == .legacy ? "MacseedTrustedMASPoC" : Contract.lifetimeDirectoryName }
}
final class Store {
    let fd: Int32
    let scope: StoreScope
    init(scope: StoreScope = .legacy, create: Bool = true) throws {
        self.scope = scope
        var current = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        try require(current >= 0)
        do {
            for component in ["Library", "Application Support", scope.directoryName] {
                if component == scope.directoryName && create {
                    if mkdirat(current, component, 0o700) != 0 { try require(errno == EEXIST) }
                }
                let next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                try require(next >= 0)
                close(current); current = next
                var info = stat(); try require(fstat(current, &info) == 0)
                try require(info.st_uid == 0 && info.st_mode & 0o022 == 0)
                // Mode bits do not describe extended ACL grants.
                try requireNoACL(current)
                if component == scope.directoryName { try require(info.st_mode & 0o077 == 0) }
            }
            fd = current
        } catch { close(current); throw error }
    }
    deinit { close(fd) }
    var journalFile: JournalFile { JournalFile(fd) }
    var currentOperation = "diagnostic"
    var currentCaller = Caller(uid: 0, gid: 0, auditSession: 0)
    func readState() throws -> String { try journalFile.load()?.state ?? "unknown" }
    func state(_ value: String) throws {
        guard var journal = try journalFile.load() else { throw Failure.refused }
        if value == "running" { try journal.begin(currentOperation, id: nil, caller: currentCaller) }
        else { journal.transition(value, reason: value == "unknown" ? "unconfirmed_operation_completion" : "diagnostic_finished") }
        try journalFile.save(journal)
    }
    func installed() throws -> String {
        try require(scope == .legacy)
        let input = openat(fd, "mas", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        try require(input >= 0)
        defer { close(input) }
        var info = stat(); try require(fstat(input, &info) == 0)
        try require(info.st_uid == 0 && info.st_mode & S_IFMT == S_IFREG && info.st_mode & 0o777 == 0o500 && info.st_nlink == 1)
        let path = Contract.directory + "/mas"
        try checkCode(path)
        return path
    }
    func deploy() throws {
        try require(scope == .legacy)
        // First checkpoint is no-clobber. Updates/rollback are deliberately
        // refused; they require a separately reviewed generation manifest.
        var existing = stat()
        if fstatat(fd, "mas", &existing, AT_SYMLINK_NOFOLLOW) == 0 { _ = try installed(); return }
        try require(errno == ENOENT)
        let input = open(Contract.source, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        try require(input >= 0)
        defer { close(input) }
        var info = stat(); try require(fstat(input, &info) == 0)
        try require(info.st_mode & S_IFMT == S_IFREG && info.st_size > 0 && info.st_size < 32 * 1024 * 1024)
        let name = ".staging-" + UUID().uuidString
        let output = openat(fd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o500)
        try require(output >= 0)
        defer { close(output); unlinkat(fd, name, 0) }
        let source = FileHandle(fileDescriptor: input, closeOnDealloc: false)
        let target = FileHandle(fileDescriptor: output, closeOnDealloc: false)
        var total = 0
        while let bytes = try source.read(upToCount: 65536), !bytes.isEmpty {
            total += bytes.count; try require(total <= 32 * 1024 * 1024)
            try target.write(contentsOf: bytes)
        }
        try require(fsync(output) == 0)
        try checkCode(Contract.directory + "/" + name)
        try require(renameatx_np(fd, name, fd, "mas", UInt32(RENAME_EXCL)) == 0 && fsync(fd) == 0)
        _ = try installed()
    }
}

final class Session {
    let lock = NSLock()
    var lost = false
    let uid: uid_t
    let gid: gid_t
    let asid: au_asid_t
    init(_ connection: NSXPCConnection) {
        uid = connection.effectiveUserIdentifier; gid = connection.effectiveGroupIdentifier
        asid = connection.auditSessionIdentifier
    }
    var caller: Caller { Caller(uid: uid, gid: gid, auditSession: UInt32(asid)) }
    func disconnect() { lock.lock(); lost = true; lock.unlock() }
    func valid() -> Bool {
        var console: uid_t = 0
        _ = SCDynamicStoreCopyConsoleUser(nil, &console, nil)
        var session = SecuritySessionId(asid)
        var attributes: SessionAttributeBits = []
        let graphic = SessionGetInfo(session, &session, &attributes) == errSecSuccess && attributes.contains(.sessionHasGraphicAccess)
        return Contract.admission("version", uid: uid, console: console, graphical: graphic)
    }
}

final class Coordinator {
    let operationLock = NSLock()
    func run(_ operation: String, session: Session) -> String {
        guard Contract.operations.contains(operation) else { return "invalid_operation" }
        guard session.valid() else { return "wrong_user_or_session" }
        session.lock.lock(); let disconnected = session.lost; session.lock.unlock()
        guard !disconnected else { return "connection_lost_no_start" }
        guard operationLock.try() else { return "operation_busy" }
        defer { operationLock.unlock() }
        do {
            let store = try Store()
            let lockFD = openat(store.fd, "operation.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
            try require(lockFD >= 0)
            defer { close(lockFD) }
            var lockInfo = stat(); try require(fstat(lockFD, &lockInfo) == 0)
            try require(lockInfo.st_uid == 0 && lockInfo.st_mode & S_IFMT == S_IFREG && lockInfo.st_mode & 0o077 == 0 && lockInfo.st_nlink == 1)
            guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { return "operation_busy" }
            store.currentOperation = operation
            store.currentCaller = session.caller
            let previous = try store.readState()
            if ["launching", "running"].contains(previous) { try store.state("unknown"); return "unknown_no_retry" }
            if operation == "state" { return previous }
            guard Contract.allowsStart(previous) else { return "unknown_no_retry" }
            try store.state("running")
            do {
                session.lock.lock(); let lostBeforeStart = session.lost; session.lock.unlock()
                guard !lostBeforeStart else { try store.state("unknown"); return "unknown_xpc_disconnect" }
                let result: String
                if operation == "deploy" { try store.deploy(); result = "deployed_verified" }
                else {
                    let path = try store.installed()
                    // SUDO_UID binds effective identity only. We do not claim
                    // that launchd's System bootstrap became the GUI bootstrap.
                    guard let record = getpwuid(session.uid) else { throw Failure.refused }
                    let process = Process(); process.executableURL = URL(fileURLWithPath: path)
                    process.arguments = operation == "version" ? ["version"] : ["list", "--json"]
                    process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": String(cString: record.pointee.pw_dir), "MAS_NO_AUTO_INDEX": "1", "SUDO_UID": String(session.uid), "SUDO_GID": String(session.gid)]
                    // Output is drained concurrently and bounded; vendor stderr
                    // never enters GUI, state or diagnostic files.
                    let output = Pipe(); process.standardOutput = output
                    process.standardError = FileHandle.nullDevice; process.standardInput = FileHandle.nullDevice
                    let dataLock = NSLock(); var bytes = Data(); var overflow = false
                    let drained = DispatchGroup(); drained.enter()
                    DispatchQueue.global().async {
                        defer { drained.leave() }
                        do {
                            while let chunk = try output.fileHandleForReading.read(upToCount: 65536), !chunk.isEmpty {
                                dataLock.lock()
                                if bytes.count + chunk.count <= 2 * 1024 * 1024 { bytes.append(chunk) } else { overflow = true }
                                dataLock.unlock()
                            }
                        } catch { dataLock.lock(); overflow = true; dataLock.unlock() }
                    }
                    do { try process.run() } catch { try? output.fileHandleForWriting.close(); throw error }
                    try output.fileHandleForWriting.close()
                    try store.recordChild(process.processIdentifier, role: operation)
                    let deadline = Date().addingTimeInterval(30)
                    while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
                    guard !process.isRunning else {
                        // No signal, no automatic retry. Persist unknown while
                        // the diagnostic child may still be running.
                        try store.state("unknown"); return "unknown_diagnostic_timeout"
                    }
                    process.waitUntilExit()
                    try store.recordExit(process.processIdentifier, status: process.terminationStatus, reason: process.terminationReason == .exit ? "exit" : "signal", role: operation)
                    guard drained.wait(timeout: .now() + 2) == .success else { try store.state("unknown"); return "unknown_output_incomplete" }
                    dataLock.lock(); let captured = bytes; let tooLarge = overflow; dataLock.unlock()
                    guard process.terminationStatus == 0 && !tooLarge else { throw Failure.refused }
                    if operation == "version" {
                        try require(String(data: captured, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == "7.0.0+")
                        result = "version=7.0.0+; caller_identity_bound; gui_bootstrap_unproven"
                    } else {
                        var ids = [String]()
                        for line in captured.split(separator: 10) where !line.isEmpty {
                            let object = try JSONSerialization.jsonObject(with: Data(line))
                            let rows = (object as? [[String: Any]]) ?? (object as? [String: Any]).map { [$0] } ?? []
                            try require(!rows.isEmpty)
                            for row in rows { guard let number = row["adamID"] as? NSNumber else { throw Failure.refused }; ids.append(number.stringValue) }
                        }
                        result = "inventory_ids=" + ids.sorted().joined(separator: ",") + "; caller_identity_bound; gui_bootstrap_unproven"
                    }
                }
                session.lock.lock(); defer { session.lock.unlock() }
                if session.lost { try store.state("unknown"); return "unknown_xpc_disconnect" }
                try store.state("completed")
                return result
            } catch { try store.state("unknown"); return "unknown_operation_failed_no_retry" }
        } catch { return "deployment_or_state_refused" }
    }
}

final class Service: NSObject, MASDiagnostics {
    let coordinator: Coordinator
    let session: Session
    init(_ coordinator: Coordinator, _ session: Session) { self.coordinator = coordinator; self.session = session }
    func qualifyLifetimeVersion(reply: @escaping (String) -> Void) {
        reply("version_qualification_closed_in_install_candidate")
    }
    func lifetimeQualificationStatus(reply: @escaping (String) -> Void) {
        DispatchQueue.global().async { reply(self.coordinator.qualificationStatus(self.session)) }
    }
    // Pure observation: deliberately never opens Store or journal files.
    func observeProcesses(reply: @escaping (String) -> Void) {
        DispatchQueue.global().async {
            guard self.session.valid() else { reply("wrong_user_or_session"); return }
            guard self.coordinator.operationLock.try() else { reply("operation_busy"); return }
            defer { self.coordinator.operationLock.unlock() }
            let result = ProcessObserver.native()
            self.session.lock.lock(); let connected = !self.session.lost; self.session.lock.unlock()
            guard self.session.valid() && connected else { reply("caller_disconnected_or_session_changed"); return }
            reply(result.json)
        }
    }
    func preflight(_ appStoreID: String, reply: @escaping (String) -> Void) {
        guard !Contract.lifetimeQualificationOnly else { reply("qualification_build_read_only_only"); return }
        DispatchQueue.global().async { reply(self.coordinator.controlled(appStoreID, session: self.session, preflightOnly: true)) }
    }
    func install(_ appStoreID: String, confirmed: Bool, reply: @escaping (String) -> Void) {
        guard !Contract.lifetimeQualificationOnly else { reply("qualification_build_read_only_only"); return }
        DispatchQueue.global().async { reply(self.coordinator.controlled(appStoreID, session: self.session, preflightOnly: false, confirmed: confirmed)) }
    }
    func reconcileLegacyDiagnostic(_ acknowledged: Bool, reply: @escaping (String) -> Void) {
        reply("legacy_reconciliation_disabled")
    }
    func perform(_ operation: String, reply: @escaping (String) -> Void) {
        reply("legacy_operations_disabled")
    }
}
final class Delegate: NSObject, NSXPCListenerDelegate {
    let coordinator = Coordinator()
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.setCodeSigningRequirement(Contract.requirement(Contract.app))
        let session = Session(connection)
        guard session.valid() else { return false }
        connection.exportedInterface = NSXPCInterface(with: MASDiagnostics.self)
        connection.exportedObject = Service(coordinator, session)
        connection.invalidationHandler = { session.disconnect() }
        connection.interruptionHandler = { session.disconnect() }
        connection.resume(); return true
    }
}
@main enum Main {
    static func main() {
        guard geteuid() == 0 else { exit(77) }
        let delegate = Delegate(); let listener = NSXPCListener(machServiceName: Contract.helper)
        listener.delegate = delegate; listener.resume()
        withExtendedLifetime((delegate, listener)) { dispatchMain() }
    }
}
