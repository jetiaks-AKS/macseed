import Foundation
import Darwin

// The existing Core secret channel, never part of CoreEvent or an operation log.
struct CoreSecureChallenge: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    enum Kind: String, Sendable {
        case bundleEncrypt = "bundle_encrypt", bundleUnlock = "bundle_unlock"
        case sshKeyUnlock = "ssh_key_unlock", importConfirmation = "import_confirmation"
    }
    struct Identity: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
        let name: String
        let keyType: String
        let fingerprint: String
        var position: Int? = nil
        var total: Int? = nil
        var typeLabel: String { keyType == "ssh-ed25519" ? "Ed25519" : keyType == "ssh-rsa" ? "RSA" : "ECDSA" }
        var description: String { "SecureIdentity(redacted)" }
        var debugDescription: String { description }
        var customMirror: Mirror { Mirror(self, children: [:]) }
    }
    var description: String { "CoreSecureChallenge(redacted)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: [:]) }
    var identity: Identity? = nil
    let operationID: String
    let challengeID: String
    let kind: Kind
    let attempt: Int
}

enum CoreSecureResponse: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    case secret(Data), confirmImport, cancel
    var description: String { "CoreSecureResponse(redacted)" }
    var debugDescription: String { description }
}

enum CoreSecureState: Equatable, Sendable {
    case idle, active, waiting(CoreSecureChallenge), awaitingResult, cancelled, completed
    case failed(CoreRuntimeError)
}

// A responder belongs to exactly one challenge. It must not be retained with secret data.
// Delivery runs off MainActor; a future UI may dispatch to MainActor without blocking I/O.
typealias CoreSecureChallengeHandler = @Sendable (CoreSecureChallenge, @escaping @Sendable (CoreSecureResponse) -> Void) -> Void

final class CoreSecureTransport: @unchecked Sendable {
    // Keep these aligned with modules/migration/secret_input.py, not UI policy.
    static let maximumFrame = 2048
    static let maximumSecret = 128
    static let waitSeconds: TimeInterval = 120
    static let maximumChallenges = 32 * 3 + 3 + 1 // Core package limit, key/bundle attempts, import confirmation.
    static let inheritedFD: Int32 = 4 // Graceful Stop owns FD 3.

    private let lock = NSLock()
    private var stateValue: CoreSecureState = .active
    private var errorValue: CoreRuntimeError?
    private var stopped = false
    private var processFinished = false
    private var cancelled = false
    private var response: Data?
    private var seen = Set<String>()
    private var lastChallenge: CoreSecureChallenge?
    private var deadline: TimeInterval?
    private var phaseCompleted = false
    private var phaseStarted = false
    private var terminalReceived = false
    private var terminalFailed = false
    private var peerClosed = false
    private var disconnectedWhileWaiting = false
    private var respondedToPrimary = false
    private var respondingKind: CoreSecureChallenge.Kind?
    private var parentFD: Int32
    private(set) var childFD: Int32
    private let operationID: String
    private let phase: String
    private let kinds: Set<CoreSecureChallenge.Kind>
    private var handler: CoreSecureChallengeHandler?
    private let clock: @Sendable () -> TimeInterval

    var state: CoreSecureState { lock.lock(); defer { lock.unlock() }; return stateValue }
    var error: CoreRuntimeError? { lock.lock(); defer { lock.unlock() }; return errorValue }
    var cancellationRequested: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    init(request: CoreRequest, handler: @escaping CoreSecureChallengeHandler,
         clock: @escaping @Sendable () -> TimeInterval) throws {
        guard request.command.requiresSecretBridge else { throw CoreRuntimeError.invalidRequest }
        operationID = request.operationID
        let capture = request.command.operation == .captureExecute
        let comparing = [.secureRestoreCompare, .secureRestoreInventory].contains(request.command.operation)
        phase = capture ? "secure_packaging" : comparing ? "secure_compare" : "secure_import"
        kinds = capture ? [.bundleEncrypt, .sshKeyUnlock] : comparing ? [.bundleUnlock] : [.bundleUnlock, .sshKeyUnlock, .importConfirmation]
        self.handler = handler
        self.clock = clock
        var pair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw CoreRuntimeError.ioFailed(errno) }
        parentFD = pair[0]
        // Keep the spawn source above both reserved descriptors, even with closed stdio.
        childFD = fcntl(pair[1], F_DUPFD_CLOEXEC, 5)
        let duplicateError = errno
        Darwin.close(pair[1])
        guard childFD >= 5 else {
            Darwin.close(parentFD); parentFD = -1
            throw CoreRuntimeError.ioFailed(duplicateError)
        }
        var noSignal: Int32 = 1
        guard fcntl(parentFD, F_SETFD, FD_CLOEXEC) == 0,
              fcntl(parentFD, F_SETFL, O_NONBLOCK) == 0,
              setsockopt(parentFD, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            let code = errno
            Darwin.close(parentFD); Darwin.close(childFD); parentFD = -1; childFD = -1
            throw CoreRuntimeError.ioFailed(code)
        }
    }

    deinit {
        if parentFD >= 0 { Darwin.close(parentFD) }
        if childFD >= 0 { Darwin.close(childFD) }
    }

    // Called by the spawning thread only; parent I/O has a separate single owner.
    func closeChildEndpoint() {
        if childFD >= 0 { Darwin.close(childFD); childFD = -1 }
    }
    func closeBeforeLaunch() {
        lock.lock(); handler = nil; lock.unlock()
        closeChildEndpoint()
        if parentFD >= 0 { Darwin.close(parentFD); parentFD = -1 }
    }

    private func clearResponse() {
        let count = response?.count ?? 0
        response?.resetBytes(in: 0..<count)
        response = nil
    }
    private func fail(_ error: CoreRuntimeError) {
        if errorValue == nil { errorValue = error }
        lastChallenge = nil
        stateValue = .failed(errorValue!)
        clearResponse()
    }
    func cancel(userRequested: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard !processFinished else { return }
        cancelled = cancelled || userRequested; stopped = true
        clearResponse()
        handler = nil; lastChallenge = nil
        if errorValue == nil { stateValue = cancelled ? .cancelled : .awaitingResult }
    }

    // JSONL contains lifecycle evidence only. Core closes the socket after the secure
    // phase, before the remaining Bootstrap work; EOF alone is never success evidence.
    func observe(_ event: CoreEvent) {
        lock.lock(); defer { lock.unlock() }
        guard !stopped, errorValue == nil else { return }
        if event.type == "phase_started", event.phase == phase {
            guard !phaseStarted, !terminalReceived else { fail(.invalidLifecycle); return }
            phaseStarted = true
            deadline = min(deadline ?? .infinity, clock() + Self.waitSeconds)
        }
        if event.type == "phase_completed", event.phase == phase {
            if case .waiting = stateValue { fail(.invalidLifecycle); return }
            guard phaseStarted, !phaseCompleted, !cancelled, respondedToPrimary else { fail(.invalidLifecycle); return }
            phaseCompleted = true; deadline = nil
        }
        if event.isTerminal {
            terminalReceived = true
            terminalFailed = event.type != "completed"
            if !terminalFailed && (!phaseCompleted || disconnectedWhileWaiting || cancelled) {
                fail(.invalidLifecycle)
            }
            clearResponse()
            if errorValue == nil {
                stateValue = event.isCancellation ? .cancelled : (terminalFailed ? .failed(.coreFailure(event.code ?? "unknown_failure")) : .awaitingResult)
            }
        }
    }

    // Called after JSONL is drained and the owned process has been reaped.
    func finish(outcomeError: CoreRuntimeError?) {
        lock.lock(); defer { lock.unlock() }
        processFinished = true
        lastChallenge = nil
        clearResponse()
        handler = nil
        if errorValue == nil {
            if let outcomeError { stateValue = .failed(outcomeError) }
            else if cancelled { stateValue = .cancelled }
            else if terminalReceived && !terminalFailed && phaseCompleted { stateValue = .completed }
        }
    }

    private func challenge(_ data: Data) throws -> CoreSecureChallenge {
        // Count all object fields before decoding: duplicate/unknown fields at
        // either level must not disappear through JSONSerialization.
        var quoted = false, escaped = false, fields = 0
        for byte in data {
            if escaped { escaped = false }
            else if quoted && byte == 92 { escaped = true }
            else if byte == 34 { quoted.toggle() }
            else if !quoted && byte == 58 { fields += 1 }
        }
        func integer(_ value: Any?) -> Int? {
            guard let number = value as? NSNumber, !["c", "f", "d"].contains(String(cString: number.objCType)) else { return nil }
            return number.stringValue == String(number.intValue) ? number.intValue : nil
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "challenge", object["operation_id"] as? String == operationID,
              let id = object["challenge_id"] as? String, id.utf8.count == 32, id.range(of: "^[0-9a-fA-F]{32}$", options: .regularExpression) != nil,
              let rawKind = object["kind"] as? String, let kind = CoreSecureChallenge.Kind(rawValue: rawKind), kinds.contains(kind),
              let attempt = integer(object["attempt"]), (1...3).contains(attempt) else { throw CoreRuntimeError.secureChannelInvalid }
        let base: Set<String> = ["type", "protocol_version", "operation_id", "challenge_id", "kind", "attempt"]
        var identity: CoreSecureChallenge.Identity?
        if kind == .sshKeyUnlock {
            guard integer(object["protocol_version"]) == 2, Set(object.keys) == base.union(["identity"]),
                  let context = object["identity"] as? [String: Any],
                  Set(context.keys) == ["name", "key_type", "fingerprint"] || Set(context.keys) == ["name", "key_type", "fingerprint", "position", "total"],
                  fields == 7 + context.count,
                  let name = context["name"] as? String, name.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0) }), name.range(of: "^[A-Za-z0-9][A-Za-z0-9_.-]{0,79}$", options: .regularExpression) != nil, !name.hasSuffix(".pub"),
                  let keyType = context["key_type"] as? String, ["ssh-ed25519", "ssh-rsa", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521"].contains(keyType),
                  let fingerprint = context["fingerprint"] as? String, fingerprint.range(of: "^SHA256:[A-Za-z0-9+/]{43}$", options: .regularExpression) != nil,
                  let digest = Data(base64Encoded: String(fingerprint.dropFirst(7)) + "="), digest.count == 32,
                  digest.base64EncodedString() == String(fingerprint.dropFirst(7)) + "=" else { throw CoreRuntimeError.secureChannelInvalid }
            var value = CoreSecureChallenge.Identity(name: name, keyType: keyType, fingerprint: fingerprint)
            if context["position"] != nil || context["total"] != nil {
                guard let position = integer(context["position"]), let total = integer(context["total"]), (1...32).contains(total), (1...total).contains(position) else { throw CoreRuntimeError.secureChannelInvalid }
                value.position = position; value.total = total
            }
            identity = value
        } else {
            guard integer(object["protocol_version"]) == 1, fields == 6, Set(object.keys) == base else { throw CoreRuntimeError.secureChannelInvalid }
        }
        return CoreSecureChallenge(identity: identity, operationID: operationID, challengeID: id.lowercased(), kind: kind, attempt: attempt)
    }

    private func accept(_ data: Data) throws {
        let value = try challenge(data)
        lock.lock()
        guard !stopped, !terminalReceived, !phaseCompleted, !cancelled,
              stateValue == .active, seen.count < Self.maximumChallenges, seen.insert(value.challengeID).inserted else {
            lock.unlock(); throw CoreRuntimeError.invalidLifecycle
        }
        if value.attempt > 1 {
            guard let previous = lastChallenge, previous.kind == value.kind, previous.identity == value.identity, previous.attempt + 1 == value.attempt else {
                lock.unlock(); throw CoreRuntimeError.secureChannelInvalid
            }
        }
        lastChallenge = value
        stateValue = .waiting(value)
        deadline = clock() + Self.waitSeconds
        lock.unlock()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let deliver = self.stateValue == .waiting(value) ? self.handler : nil
            self.lock.unlock()
            deliver?(value) { [weak self] reply in self?.submit(reply, for: value) }
        }
    }

    private func submit(_ reply: CoreSecureResponse, for challenge: CoreSecureChallenge) {
        lock.lock(); defer { lock.unlock() }
        // Late UI callbacks cannot revive a finished/cancelled operation.
        guard !stopped, !terminalReceived, errorValue == nil else { return }
        guard !peerClosed, stateValue == .waiting(challenge), response == nil else { fail(.invalidLifecycle); return }
        guard let deadline, clock() < deadline else { fail(.secureChannelTimeout); return }
        var body = Data()
        let hex = Array(challenge.challengeID.utf8)
        for index in stride(from: 0, to: hex.count, by: 2) {
            body.append(UInt8(String(bytes: hex[index...index + 1], encoding: .utf8)!, radix: 16)!)
        }
        switch reply {
        case .cancel:
            body.append(67); cancelled = true
        case .confirmImport:
            guard challenge.kind == .importConfirmation else { fail(.secureChannelInvalid); return }
            body.append(89)
        case .secret(let secret):
            guard challenge.kind != .importConfirmation, (1...Self.maximumSecret).contains(secret.count),
                  let text = String(data: secret, encoding: .utf8),
                  !text.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
                fail(.secureChannelInvalid); return
            }
            body.append(83); body.append(secret)
        }
        respondingKind = challenge.kind
        response = body
    }

    private func sendResponse(_ body: inout Data) throws {
        var frame = Data([UInt8(body.count >> 24), UInt8((body.count >> 16) & 255), UInt8((body.count >> 8) & 255), UInt8(body.count & 255)])
        frame.append(body)
        defer { frame.resetBytes(in: 0..<frame.count); body.resetBytes(in: 0..<body.count) }
        var offset = 0
        let until = clock() + Self.waitSeconds
        while offset < frame.count {
            lock.lock()
            guard !stopped, !terminalReceived, errorValue == nil else { lock.unlock(); return }
            let count = frame.withUnsafeBytes { Darwin.write(parentFD, $0.baseAddress!.advanced(by: offset), $0.count - offset) }
            let code = errno
            if count > 0 && offset + count == frame.count && !cancelled,
               respondingKind == .bundleEncrypt || respondingKind == .bundleUnlock {
                respondedToPrimary = true
            }
            lock.unlock()
            if count > 0 { offset += count; continue }
            if count < 0 && code == EINTR { continue }
            guard count < 0 && (code == EAGAIN || code == EWOULDBLOCK) else { throw CoreRuntimeError.secureChannelDisconnected }
            guard clock() < until else { throw CoreRuntimeError.secureChannelTimeout }
            var descriptor = pollfd(fd: parentFD, events: Int16(POLLOUT), revents: 0)
            _ = poll(&descriptor, 1, 20)
        }
    }

    // The worker alone reads/writes/closes the parent endpoint. Cancellation only
    // changes locked state, so no concurrent close can redirect I/O to a reused FD.
    func run(failed: () -> Void) {
        defer { Darwin.close(parentFD); parentFD = -1 }
        var buffer = Data()
        var frameDeadline: TimeInterval?
        do {
            while true {
                lock.lock()
                if stopped { lock.unlock(); return }
                if let errorValue { lock.unlock(); throw errorValue }
                var outgoing = response
                response = nil
                if outgoing != nil {
                    stateValue = cancelled ? .cancelled : .active
                    deadline = clock() + Self.waitSeconds
                }
                let expired = !terminalReceived && ((deadline.map { clock() >= $0 } ?? false) || (frameDeadline.map { clock() >= $0 } ?? false))
                let closed = peerClosed
                let settled = phaseCompleted || terminalFailed
                let finished = processFinished
                lock.unlock()
                if expired { throw CoreRuntimeError.secureChannelTimeout }
                if outgoing != nil { try sendResponse(&outgoing!); outgoing = nil }
                if closed {
                    if settled || finished { return }
                    Thread.sleep(forTimeInterval: 0.02)
                    continue
                }
                var descriptor = pollfd(fd: parentFD, events: Int16(POLLIN | POLLHUP), revents: 0)
                let ready = poll(&descriptor, 1, 20)
                if ready < 0 { if errno == EINTR { continue }; throw CoreRuntimeError.secureChannelDisconnected }
                if ready == 0 {
                    if finished {
                        guard buffer.isEmpty else { throw CoreRuntimeError.secureChannelInvalid }
                        return
                    }
                    continue
                }
                var bytes = [UInt8](repeating: 0, count: Self.maximumFrame + 4 - buffer.count)
                let count = Darwin.read(parentFD, &bytes, bytes.count)
                if count < 0 {
                    if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                    throw CoreRuntimeError.secureChannelDisconnected
                }
                if count == 0 {
                    guard buffer.isEmpty else { throw CoreRuntimeError.secureChannelInvalid }
                    lock.lock()
                    peerClosed = true
                    if case .waiting = stateValue { disconnectedWhileWaiting = true }
                    clearResponse()
                    if !cancelled { stateValue = .awaitingResult }
                    if deadline == nil && !phaseCompleted { deadline = clock() + Self.waitSeconds }
                    lock.unlock()
                    continue
                }
                if buffer.isEmpty { frameDeadline = clock() + Self.waitSeconds }
                buffer.append(contentsOf: bytes.prefix(count))
                while buffer.count >= 4 {
                    let size = buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
                    guard (1...Self.maximumFrame).contains(size) else { throw CoreRuntimeError.secureChannelInvalid }
                    guard buffer.count >= size + 4 else { break }
                    let data = Data(buffer.dropFirst(4).prefix(size))
                    buffer.removeFirst(size + 4)
                    try accept(data)
                    frameDeadline = buffer.isEmpty ? nil : clock() + Self.waitSeconds
                }
            }
        } catch {
            lock.lock()
            if !stopped { fail(error as? CoreRuntimeError ?? .secureChannelInvalid) }
            let notify = !stopped
            lock.unlock()
            if notify { failed() }
        }
    }
}
