import Foundation
import Darwin

struct CoreStderrDiagnostics: Equatable, Sendable {
    var byteCount = 0
    var readError: CoreRuntimeError?
    // Opaque tool output is drained, never stored, rendered, parsed or logged.
    var outputPresent: Bool { byteCount > 0 }
}

struct CoreProcessOutcome: Sendable {
    let terminal: CoreEvent?
    let exitCode: Int32?
    let signalled: Bool
    let error: CoreRuntimeError?
    let stderr: CoreStderrDiagnostics
    let cancellationRequested: Bool
    // Nil keeps older/injected outcomes unknown; absence of Core events alone
    // does not establish whether a process launched.
    var processLaunched: Bool? = nil
    var restoreIdentityInventory: CoreRestoreIdentityInventory? = nil
    var sshReview: CoreSSHReview? = nil
    var secureCheck: CoreSecureCheckResult? = nil
}

// One owned process group per operation. All blocking I/O runs off the MainActor.
final class CoreTransport: @unchecked Sendable {
    private let lock = NSLock()
    private var pid: pid_t?
    private var cancellationRequested = false
    private var reaped = false
    private var consumed = false
    private var controlWriter: FileHandle?
    private var secure: CoreSecureTransport?
    private let secureClock: @Sendable () -> TimeInterval

    init(secureClock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.secureClock = secureClock
    }
    var secureState: CoreSecureState {
        lock.lock(); let channel = secure; lock.unlock()
        return channel?.state ?? .idle
    }

    func requestGracefulStop() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let writer = controlWriter, pid != nil else { return false }
        var command: UInt8 = 83
        return Darwin.write(writer.fileDescriptor, &command, 1) == 1
    }
    func cancel() { stop(userRequested: true) }
    private func stop(userRequested: Bool) {
        lock.lock()
        if userRequested { cancellationRequested = true }
        // Lock order is transport -> secret channel; its callbacks run without its lock.
        secure?.cancel(userRequested: userRequested)
        if let pid { _ = kill(-pid, SIGTERM) }
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [self] in
            lock.lock()
            // PID is cleared atomically with waitpid, so an unrelated reused PID
            // cannot be killed by this delayed escalation.
            if let pid { _ = kill(-pid, SIGKILL) }
            lock.unlock()
        }
    }
    private func wasCancelled() -> Bool {
        lock.lock(); defer { lock.unlock() }; return cancellationRequested
    }
    private func hasReaped() -> Bool {
        lock.lock(); defer { lock.unlock() }; return reaped
    }

    func run(request: CoreRequest, location: CoreLocation,
             secureChallenge: CoreSecureChallengeHandler? = nil,
             receive: @escaping @Sendable (CoreEvent) -> Void) async -> CoreProcessOutcome {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                continuation.resume(returning: perform(request: request, location: location, secureChallenge: secureChallenge, receive: receive))
            }
        }
    }
    private func perform(request: CoreRequest, location: CoreLocation,
                         secureChallenge: CoreSecureChallengeHandler?,
                         receive: @escaping @Sendable (CoreEvent) -> Void) -> CoreProcessOutcome {
        func failure(_ error: CoreRuntimeError) -> CoreProcessOutcome {
            CoreProcessOutcome(terminal: nil, exitCode: nil, signalled: false, error: error,
                               stderr: CoreStderrDiagnostics(), cancellationRequested: wasCancelled(), processLaunched: false)
        }
        lock.lock()
        let reused = consumed
        consumed = true
        lock.unlock()
        if reused { return failure(.invalidLifecycle) }
        let requestBytes: Data
        do {
            guard secureChallenge == nil || request.command.requiresSecretBridge else { throw CoreRuntimeError.invalidRequest }
            requestBytes = try request.encoded()
            try location.validate(for: request.command, secureTransportAvailable: secureChallenge != nil)
        }
        catch { return failure(error as? CoreRuntimeError ?? .invalidRequest) }
        if wasCancelled() {
            return CoreProcessOutcome(terminal: nil, exitCode: nil, signalled: false, error: nil,
                                      stderr: CoreStderrDiagnostics(), cancellationRequested: true, processLaunched: false)
        }
        let temporary = location.temporaryBase.appendingPathComponent("macseed-operation-" + UUID().uuidString)
        do { try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false,
                                                     attributes: [.posixPermissions: 0o700]) }
        catch { return failure(.ioFailed(Int32(errno))) }
        defer { try? FileManager.default.removeItem(at: temporary) }
        if !request.externalIdentityPaths.isEmpty {
            do {
                let bytes = try JSONSerialization.data(withJSONObject: ["version": 1, "operation_id": request.operationID, "paths": request.externalIdentityPaths])
                guard bytes.count <= 65536,
                      FileManager.default.createFile(atPath: temporary.appendingPathComponent("external-ssh-sources.json").path,
                                                     contents: bytes, attributes: [.posixPermissions: 0o600]) else { return failure(.invalidRequest) }
            } catch { return failure(.invalidRequest) }
        }
        if let mapping = request.restoreDestinations {
            do {
                let value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(mapping))
                let bytes = try JSONSerialization.data(withJSONObject: ["operation_id": request.operationID, "mapping": value])
                guard bytes.count <= 65536,
                      FileManager.default.createFile(atPath: temporary.appendingPathComponent("secure-restore-destinations.json").path,
                          contents: bytes, attributes: [.posixPermissions: 0o600]) else { return failure(.invalidRequest) }
            } catch { return failure(.invalidRequest) }
        }
        if let approvals = request.sshApprovals {
            do {
                let value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(approvals))
                let bytes = try JSONSerialization.data(withJSONObject: ["operation_id": request.operationID, "approvals": value])
                guard bytes.count <= 65536,
                      FileManager.default.createFile(atPath: temporary.appendingPathComponent("ssh-restore-approvals.json").path,
                          contents: bytes, attributes: [.posixPermissions: 0o600]) else { return failure(.invalidRequest) }
            } catch { return failure(.invalidRequest) }
        }
        let input = Pipe(), output = Pipe(), diagnostics = Pipe()
        let control: Pipe? = request.command.operation == .restoreExecute ? Pipe() : nil
        let secureChannel: CoreSecureTransport?
        do {
            secureChannel = try secureChallenge.map { try CoreSecureTransport(request: request, handler: $0, clock: secureClock) }
        } catch { return failure(error as? CoreRuntimeError ?? .secureChannelInvalid) }
        lock.lock(); secure = secureChannel; let cancelledBeforeLaunch = cancellationRequested; lock.unlock()
        var secureWorkerStarted = false
        defer {
            if !secureWorkerStarted { secureChannel?.closeBeforeLaunch() }
            secureChannel?.closeChildEndpoint()
        }
        if cancelledBeforeLaunch, let secureChannel { secureChannel.cancel(userRequested: true); return failure(.interrupted) }
        defer {
            lock.lock(); controlWriter = nil; lock.unlock()
            try? control?.fileHandleForReading.close(); try? control?.fileHandleForWriting.close()
        }
        let actionsResult: Int32
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { return failure(.launchFailed(errno)) }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { return failure(.launchFailed(errno)) }
        defer { posix_spawnattr_destroy(&attributes) }
        var descriptors: [(Int32, Int32)] = [(input.fileHandleForReading.fileDescriptor, STDIN_FILENO),
                                           (output.fileHandleForWriting.fileDescriptor, STDOUT_FILENO),
                                           (diagnostics.fileHandleForWriting.fileDescriptor, STDERR_FILENO)]
        if let control { descriptors.append((control.fileHandleForReading.fileDescriptor, 3)) }
        if let secureChannel { descriptors.append((secureChannel.childFD, CoreSecureTransport.inheritedFD)) }
        var setupError: Int32 = 0
        for (source, target) in descriptors {
            let code = posix_spawn_file_actions_adddup2(&actions, source, target)
            if code != 0 { setupError = code }
        }
        if secureChannel != nil {
            // Darwin considers descriptors referenced by file actions explicitly
            // inherited. Close dup2 sources after all remapping, except target FDs.
            let targets = Set(descriptors.map { $0.1 })
            for source in Set(descriptors.map { $0.0 }).subtracting(targets) {
                let code = posix_spawn_file_actions_addclose(&actions, source)
                if code != 0 { setupError = code }
            }
        }
        // Only explicitly duplicated stdio/control and an opted-in secret endpoint inherit.
        let flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT)
        var mask = sigset_t(); sigemptyset(&mask)
        var defaults = sigset_t(); sigemptyset(&defaults); sigaddset(&defaults, SIGTERM); sigaddset(&defaults, SIGINT)
        for code in [posix_spawnattr_setflags(&attributes, flags), posix_spawnattr_setpgroup(&attributes, 0),
                     posix_spawnattr_setsigmask(&attributes, &mask), posix_spawnattr_setsigdefault(&attributes, &defaults)] {
            if code != 0 { setupError = code }
        }
        // The current deployment target supports this API; no global chdir.
        actionsResult = posix_spawn_file_actions_addchdir_np(&actions, location.root.path)
        if actionsResult != 0 { setupError = actionsResult }
        guard setupError == 0 else { return failure(.launchFailed(setupError)) }
        let argumentStrings: [String] = ["/bin/bash", location.launcher.path]
            + (secureChannel == nil ? [] : ["--secure-fd", String(CoreSecureTransport.inheritedFD)])
        let arguments = argumentStrings.map { $0.withCString { strdup($0) } }
        var childEnvironment = location.environment(temporary: temporary)
        if control != nil { childEnvironment["MACSEED_GRACEFUL_FD"] = "3" }
        let environment = childEnvironment.sorted { $0.key < $1.key }
            .map { strdup($0.key + "=" + $0.value) }
        defer { arguments.forEach { free($0) }; environment.forEach { free($0) } }
        var child: pid_t = 0
        let launch = (arguments + [nil]).withUnsafeBufferPointer { argv in
            (environment + [nil]).withUnsafeBufferPointer { env in
                posix_spawn(&child, "/bin/bash", &actions, &attributes,
                            UnsafeMutablePointer(mutating: argv.baseAddress!), UnsafeMutablePointer(mutating: env.baseAddress!))
            }
        }
        guard launch == 0 else { return failure(.launchFailed(launch)) }
        secureChannel?.closeChildEndpoint()
        lock.lock()
        pid = child
        if let control {
            _ = fcntl(control.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            controlWriter = control.fileHandleForWriting
        }
        let cancelAfterLaunch = cancellationRequested
        lock.unlock()
        if cancelAfterLaunch { stop(userRequested: true) }
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        try? diagnostics.fileHandleForWriting.close()

        let readers = DispatchGroup()
        let secretReader = DispatchGroup()
        if let secureChannel {
            secureWorkerStarted = true
            secretReader.enter()
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                defer { secretReader.leave() }
                secureChannel.run { stop(userRequested: false) }
            }
        }
        // Each variable below has a single writer and is read only after group.wait.
        var stream = CoreEventStream(operationID: request.operationID)
        var streamError: CoreRuntimeError?
        var stderr = CoreStderrDiagnostics()
        readers.enter()
        DispatchQueue.global().async { [self] in
            defer { readers.leave(); try? output.fileHandleForReading.close() }
            var secureFailureStopped = false
            drain(output.fileHandleForReading.fileDescriptor) { data in
                guard streamError == nil else { return }
                do {
                    try stream.append(data) { event in
                        secureChannel?.observe(event)
                        if !secureFailureStopped, secureChannel?.error != nil {
                            secureFailureStopped = true
                            stop(userRequested: false)
                        }
                        receive(event)
                    }
                }
                catch { streamError = error as? CoreRuntimeError ?? .malformedEvent; stop(userRequested: false) }
            } failed: { error in if streamError == nil { streamError = error } }
        }
        readers.enter()
        DispatchQueue.global().async { [self] in
            defer { readers.leave(); try? diagnostics.fileHandleForReading.close() }
            drain(diagnostics.fileHandleForReading.fileDescriptor) { data in stderr.byteCount += data.count }
                failed: { error in stderr.readError = error }
        }
        // Request is bounded to 4096 bytes; write without SIGPIPE on cancellation.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        var written = 0
        requestBytes.withUnsafeBytes { bytes in
            while written < bytes.count {
                let count = Darwin.write(input.fileHandleForWriting.fileDescriptor, bytes.baseAddress!.advanced(by: written), bytes.count - written)
                if count > 0 { written += count }
                else if errno != EINTR { break }
            }
        }
        try? input.fileHandleForWriting.close()
        var status: Int32 = 0
        var waitError: CoreRuntimeError?
        while true {
            lock.lock()
            let result = waitpid(child, &status, WNOHANG)
            if result == child || (result < 0 && errno != EINTR) { pid = nil; reaped = true }
            let done = reaped
            if result < 0 && errno != EINTR { waitError = .ioFailed(errno) }
            lock.unlock()
            if done { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        readers.wait()
        let signalled = (status & 0x7f) != 0
        let exitCode = signalled ? (status & 0x7f) : ((status >> 8) & 0xff)
        var terminal: CoreEvent?
        var finalError = secureChannel?.error ?? streamError ?? waitError
        if finalError == nil {
            do { terminal = try stream.finish(exitCode: exitCode, signalled: signalled) }
            catch let failure as CoreRuntimeError { finalError = failure }
            catch { finalError = .malformedEvent }
        }
        secureChannel?.finish(outcomeError: finalError)
        secretReader.wait()
        if let error = secureChannel?.error { finalError = error; terminal = nil }
        var inventory: CoreRestoreIdentityInventory?
        if [.secureRestoreInventory, .secureCheckInventory].contains(request.command.operation), finalError == nil, terminal?.type == "completed", !wasCancelled() {
            do {
                inventory = try Self.readRestoreInventory(temporary: temporary, operationID: request.operationID)
                if case .secureCheckInventory(_, let id) = request.command, inventory?.bundleID != id { throw CoreRuntimeError.secureChannelInvalid }
            }
            catch { finalError = .secureChannelInvalid; terminal = nil }
        }
        var secureCheck: CoreSecureCheckResult?
        if request.command.operation == .secureCheckCompare, finalError == nil, terminal?.type == "completed", !wasCancelled() {
            do {
                guard let mapping = request.restoreDestinations else { throw CoreRuntimeError.secureChannelInvalid }
                let data = try Self.readPrivateInventory(temporary: temporary, name: "secure-check-result.json")
                try CoreSecureCheckResult.validateFields(data)
                let value = try JSONDecoder().decode(CoreSecureCheckResult.self, from: data)
                try value.validate(operationID: request.operationID, mapping: mapping)
                try Self.validateFields(data, count: 16 + mapping.items.count * 3 + value.items.count * 6)
                secureCheck = value
            } catch { finalError = .secureChannelInvalid; terminal = nil }
        }
        var sshReview: CoreSSHReview?
        if request.command.operation == .sshRestoreReview, finalError == nil, terminal?.type == "completed", !wasCancelled() {
            do {
                let data = try Self.readPrivateInventory(temporary: temporary, name: "ssh-restore-references.json")
                let value = try JSONDecoder().decode(CoreSSHReview.self, from: data)
                try value.validate(operationID: request.operationID)
                // Current reviews include a reason; older responses omit it.
                // Count decoded optional fields without admitting unknown or duplicate keys.
                try Self.validateFields(data, count: 4 + value.items.count * 6
                    + value.items.filter { $0.reason != nil }.count
                    + value.items.filter { $0.proposal != nil }.count * 3)
                sshReview = value
            } catch { finalError = .malformedEvent; terminal = nil }
        }
        return CoreProcessOutcome(terminal: terminal, exitCode: exitCode, signalled: signalled,
                                  error: finalError, stderr: stderr,
                                  cancellationRequested: wasCancelled() || secureChannel?.cancellationRequested == true, processLaunched: true, restoreIdentityInventory: inventory, sshReview: sshReview, secureCheck: secureCheck)
    }

    private static func readRestoreInventory(temporary: URL, operationID: String) throws -> CoreRestoreIdentityInventory {
        let data = try readPrivateInventory(temporary: temporary, name: "secure-restore-inventory.json")
        let inventory = try JSONDecoder().decode(CoreRestoreIdentityInventory.self, from: data)
        try inventory.validate(operationID: operationID)
        try validateFields(data, count: 4 + inventory.items.count * 4)
        return inventory
    }

    private static func readPrivateInventory(temporary: URL, name: String) throws -> Data {
        let directory = open(temporary.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directory >= 0 else { throw CoreRuntimeError.secureChannelInvalid }
        defer { Darwin.close(directory) }
        var parent = stat(), parentNow = stat()
        guard fstat(directory, &parent) == 0, parent.st_uid == getuid(), parent.st_mode & 0o777 == 0o700 else { throw CoreRuntimeError.secureChannelInvalid }
        let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw CoreRuntimeError.secureChannelInvalid }
        defer { Darwin.close(fd) }
        func same(_ left: stat, _ right: stat) -> Bool {
            left.st_dev == right.st_dev && left.st_ino == right.st_ino && left.st_mode == right.st_mode
                && left.st_uid == right.st_uid && left.st_gid == right.st_gid && left.st_nlink == right.st_nlink
                && left.st_size == right.st_size && left.st_mtimespec.tv_sec == right.st_mtimespec.tv_sec
                && left.st_mtimespec.tv_nsec == right.st_mtimespec.tv_nsec && left.st_ctimespec.tv_sec == right.st_ctimespec.tv_sec
                && left.st_ctimespec.tv_nsec == right.st_ctimespec.tv_nsec
        }
        var before = stat(), after = stat(), visible = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_uid == getuid(),
              before.st_mode & 0o777 == 0o600, before.st_nlink == 1, (1...65536).contains(before.st_size) else { throw CoreRuntimeError.secureChannelInvalid }
        var bytes = [UInt8](repeating: 0, count: Int(before.st_size) + 1)
        let count = Darwin.read(fd, &bytes, bytes.count)
        guard count == before.st_size, fstat(fd, &after) == 0, fstatat(directory, name, &visible, AT_SYMLINK_NOFOLLOW) == 0,
              same(before, after), same(after, visible), lstat(temporary.path, &parentNow) == 0,
              parent.st_dev == parentNow.st_dev, parent.st_ino == parentNow.st_ino,
              parent.st_mode == parentNow.st_mode, parent.st_uid == parentNow.st_uid else { throw CoreRuntimeError.secureChannelInvalid }
        return Data(bytes.prefix(count))
    }

    private static func validateFields(_ data: Data, count: Int) throws {
        // Required fields account for every object key, including duplicates that
        // a JSON decoder would otherwise collapse. Callers include nested schema keys.
        var quoted = false, escaped = false, fields = 0
        for byte in data {
            if escaped { escaped = false }
            else if quoted && byte == 92 { escaped = true }
            else if byte == 34 { quoted.toggle() }
            else if !quoted && byte == 58 { fields += 1 }
        }
        guard fields == count else { throw CoreRuntimeError.secureChannelInvalid }
    }

    private func drain(_ fd: Int32, receive: (Data) -> Void, failed: (CoreRuntimeError) -> Void) {
        var bytes = [UInt8](repeating: 0, count: 16384)
        var quietAfterExit = 0
        while true {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP), revents: 0)
            let available = poll(&descriptor, 1, 100)
            if available < 0 {
                if errno == EINTR { continue }
                failed(.ioFailed(errno)); return
            }
            if available == 0 {
                if hasReaped() { quietAfterExit += 1 }
                if quietAfterExit >= 10 { failed(.incompleteStream); return }
                continue
            }
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count == 0 { return }
            if count < 0 {
                if errno == EINTR { continue }
                failed(.ioFailed(errno)); return
            }
            receive(Data(bytes.prefix(count)))
        }
    }
}
