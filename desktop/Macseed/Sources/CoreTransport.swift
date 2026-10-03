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
}

// One owned process group per operation. All blocking I/O runs off the MainActor.
final class CoreTransport: @unchecked Sendable {
    private let lock = NSLock()
    private var pid: pid_t?
    private var cancellationRequested = false
    private var reaped = false
    private var consumed = false

    func cancel() { stop(userRequested: true) }
    private func stop(userRequested: Bool) {
        lock.lock()
        if userRequested { cancellationRequested = true }
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
             receive: @escaping @Sendable (CoreEvent) -> Void) async -> CoreProcessOutcome {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                continuation.resume(returning: perform(request: request, location: location, receive: receive))
            }
        }
    }
    private func perform(request: CoreRequest, location: CoreLocation,
                         receive: @escaping @Sendable (CoreEvent) -> Void) -> CoreProcessOutcome {
        func failure(_ error: CoreRuntimeError) -> CoreProcessOutcome {
            CoreProcessOutcome(terminal: nil, exitCode: nil, signalled: false, error: error,
                               stderr: CoreStderrDiagnostics(), cancellationRequested: wasCancelled())
        }
        lock.lock()
        let reused = consumed
        consumed = true
        lock.unlock()
        if reused { return failure(.invalidLifecycle) }
        let requestBytes: Data
        do { requestBytes = try request.encoded(); try location.validate(for: request.command) }
        catch { return failure(error as? CoreRuntimeError ?? .invalidRequest) }
        if wasCancelled() {
            return CoreProcessOutcome(terminal: nil, exitCode: nil, signalled: false, error: nil,
                                      stderr: CoreStderrDiagnostics(), cancellationRequested: true)
        }
        let temporary = location.temporaryBase.appendingPathComponent("macseed-operation-" + UUID().uuidString)
        do { try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false,
                                                     attributes: [.posixPermissions: 0o700]) }
        catch { return failure(.ioFailed(Int32(errno))) }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let input = Pipe(), output = Pipe(), diagnostics = Pipe()
        let actionsResult: Int32
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { return failure(.launchFailed(errno)) }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { return failure(.launchFailed(errno)) }
        defer { posix_spawnattr_destroy(&attributes) }
        let descriptors: [(Int32, Int32)] = [(input.fileHandleForReading.fileDescriptor, STDIN_FILENO),
                                           (output.fileHandleForWriting.fileDescriptor, STDOUT_FILENO),
                                           (diagnostics.fileHandleForWriting.fileDescriptor, STDERR_FILENO)]
        var setupError: Int32 = 0
        for (source, target) in descriptors {
            let code = posix_spawn_file_actions_adddup2(&actions, source, target)
            if code != 0 { setupError = code }
        }
        // Only explicitly duplicated stdio is inherited. No app/credential/secret FDs.
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
        let arguments = ["/bin/bash", location.launcher.path].map { strdup($0) }
        let environment = location.environment(temporary: temporary).sorted { $0.key < $1.key }
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
        lock.lock()
        pid = child
        let cancelAfterLaunch = cancellationRequested
        lock.unlock()
        if cancelAfterLaunch { stop(userRequested: true) }
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        try? diagnostics.fileHandleForWriting.close()

        let readers = DispatchGroup()
        // Each variable below has a single writer and is read only after group.wait.
        var stream = CoreEventStream(operationID: request.operationID)
        var streamError: CoreRuntimeError?
        var stderr = CoreStderrDiagnostics()
        readers.enter()
        DispatchQueue.global().async { [self] in
            defer { readers.leave(); try? output.fileHandleForReading.close() }
            drain(output.fileHandleForReading.fileDescriptor) { data in
                guard streamError == nil else { return }
                do { try stream.append(data, receive: receive) }
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
        var finalError = streamError ?? waitError
        if finalError == nil {
            do { terminal = try stream.finish(exitCode: exitCode, signalled: signalled) }
            catch let failure as CoreRuntimeError { finalError = failure }
            catch { finalError = .malformedEvent }
        }
        return CoreProcessOutcome(terminal: terminal, exitCode: exitCode, signalled: signalled,
                                  error: finalError, stderr: stderr, cancellationRequested: wasCancelled())
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
