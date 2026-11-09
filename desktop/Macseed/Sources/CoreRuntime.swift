import Combine
import Foundation

enum GracefulStopState: String { case idle, requested, accepted, unavailable, deliveryFailed
    static func receiving(_ state: String, current: Self) -> Self {
        if state == "graceful_stop_accepted" { return .accepted }
        if state == "graceful_stop_unavailable" { return .unavailable }
        return current
    }
}
enum CoreRuntimeState: String { case idle, launching, running, completed, failed, cancelled }
struct OperationLogReference: Sendable {
    let id: UUID
    let operationID: String
    let operation: CoreOperation
    let time: Date
}

extension CoreSecureChallenge: Identifiable {
    var id: String { operationID + ":" + challengeID }
}

@MainActor final class CoreRuntime: ObservableObject {
    static let shared = CoreRuntime()
    @Published private(set) var state: CoreRuntimeState = .idle
    @Published private(set) var operationID: String?
    @Published private(set) var operation: CoreOperation?
    @Published private(set) var currentPhase: String?
    @Published private(set) var events: [CoreEvent] = []
    @Published private(set) var historyTruncated = false
    @Published private(set) var latestResult: CoreEvent?
    @Published private(set) var error: CoreRuntimeError?
    @Published private(set) var termination: CoreProcessOutcome?
    @Published private(set) var secureChallenge: CoreSecureChallenge?
    @Published private(set) var secureCancellationRequested = false
    private var secureReply: (@Sendable (CoreSecureResponse) -> Void)?
    private(set) var bundleComparisonSupported: Bool?
    private(set) var secureCheckSupported = false
    private(set) var homebrewGracefulSupported = false
    @Published private(set) var gracefulStopRequested = false
    @Published private(set) var gracefulStopState: GracefulStopState = .idle
    @Published private(set) var gracefulStopMessage: String?
    @Published private(set) var secureCheck: CoreSecureCheckResult?
    @Published private(set) var sshReview: CoreSSHReview?
    @Published private(set) var restoreIdentityInventory: CoreRestoreIdentityInventory?
    @Published private(set) var capabilities: CoreCapabilities?
    @Published private(set) var mutationMayHaveStarted: Bool?
    @Published private(set) var publicationOccurred: Bool?
    @Published private(set) var stopping = false
    @Published private(set) var operationLogStatus: OperationLogStatus = .inactive
    @Published private(set) var operationLogReferences: [CoreOperation: OperationLogReference] = [:]
    private let resolver: CoreLocationResolver
    private let operationLogs: OperationLogStore?
    private let secureClock: @Sendable () -> TimeInterval
    private var logSession: OperationLogSession?
    private var logGeneration = UUID()
    private var logFinished = false
    private var coreProductVersion: String?
    init(resolver: CoreLocationResolver = CoreLocationResolver(), operationLogs: OperationLogStore? = .shared,
         secureClock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.resolver = resolver; self.operationLogs = operationLogs; self.secureClock = secureClock
    }
    private var transport: CoreTransport?
    private var work: Task<Void, Never>?
    var isActive: Bool { state == .launching || state == .running }

    func takeRestoreIdentityInventory() -> CoreRestoreIdentityInventory? {
        guard state == .completed, [.secureRestoreInventory, .secureCheckInventory].contains(operation) else { return nil }
        defer { restoreIdentityInventory = nil; termination?.restoreIdentityInventory = nil }
        return restoreIdentityInventory
    }

    func takeSecureCheck() -> CoreSecureCheckResult? {
        guard state == .completed, operation == .secureCheckCompare else { return nil }
        defer { secureCheck = nil; termination?.secureCheck = nil }
        return secureCheck
    }

    func takeSSHReview() -> CoreSSHReview? {
        guard state == .completed, operation == .sshRestoreReview else { return nil }
        defer { sshReview = nil; termination?.sshReview = nil }
        return sshReview
    }

    func start(_ request: CoreRequest, location: CoreLocation? = nil) {
        guard !isActive else { return }
        if request.command.operation == .capabilities { bundleComparisonSupported = nil; secureCheckSupported = false }
        state = .launching
        operationID = request.operationID
        operation = request.command.operation
        currentPhase = nil
        events = []
        historyTruncated = false
        latestResult = nil
        error = nil
        termination = nil
        clearSecureChallenge()
        secureCancellationRequested = false
        capabilities = nil
        restoreIdentityInventory = nil
        sshReview = nil
        secureCheck = nil
        mutationMayHaveStarted = nil
        publicationOccurred = nil
        stopping = false
        gracefulStopRequested = false; gracefulStopState = .idle; gracefulStopMessage = nil
        let generation = UUID()
        logGeneration = generation
        logFinished = false
        operationLogStatus = .inactive
        let log: OperationLogSession?
        if request.command.operation != .capabilities, let operationLogs {
            operationLogStatus = .recording
            log = operationLogs.begin(request, coreVersion: coreProductVersion) { [weak self] status in
                Task { @MainActor in
                    guard let self, self.logGeneration == generation, !self.logFinished else { return }
                    self.operationLogStatus = status
                }
            }
        } else { log = nil }
        logSession = log
        if let log {
            operationLogReferences[request.command.operation] = OperationLogReference(id: log.id, operationID: request.operationID,
                operation: request.command.operation, time: Date())
        }
        let channel = AsyncStream<CoreEvent>.makeStream()
        let transport = CoreTransport(secureClock: secureClock)
        self.transport = transport
        work = Task {
            let resolved: CoreLocation
            do { resolved = try location ?? resolver.resolve() }
            catch {
                let failure = error as? CoreRuntimeError ?? .invalidRuntimeConfiguration
                self.error = failure
                state = .failed
                self.transport = nil
                if let log {
                    let status = await log.finish(nil, error: failure, processLaunched: false)
                    if logGeneration == generation { logFinished = true; operationLogStatus = status }
                }
                return
            }
            let producer = Task<CoreProcessOutcome, Never> {
                let secureExecution = request.command.requiresSecretBridge
                let handler: CoreSecureChallengeHandler?
                if secureExecution {
                    handler = { [weak self = self] challenge, reply in
                        Task<Void, Never> { @MainActor in
                            guard let self, self.transport === transport, self.operationID == challenge.operationID,
                                  self.isActive, !self.stopping, transport.secureState == .waiting(challenge) else { return }
                            if [.secureRestoreCompare, .secureRestoreInventory, .sshRestoreReview, .secureCheckInventory, .secureCheckCompare].contains(self.operation) && challenge.kind != .bundleUnlock {
                                reply(.cancel)
                                return
                            }
                            if self.operation == .restoreExecute && self.gracefulStopRequested {
                                self.secureCancellationRequested = true
                                reply(.cancel)
                                return
                            }
                            self.secureReply = reply
                            self.secureChallenge = challenge
                        }
                    }
                } else { handler = nil }
                let monitor: Task<Void, Never>? = secureExecution ? Task<Void, Never> { @MainActor [weak self = self] in
                    while !Task.isCancelled {
                        guard let self, self.transport === transport else { return }
                        if let challenge = self.secureChallenge, transport.secureState != .waiting(challenge) {
                            self.clearSecureChallenge()
                        }
                        try? await Task.sleep(for: .milliseconds(50))
                    }
                } : nil
                let result = await transport.run(request: request, location: resolved, secureChallenge: handler) { event in
                    log?.receive(event)
                    channel.continuation.yield(event)
                }
                monitor?.cancel()
                if self.transport === transport { clearSecureChallenge() }
                channel.continuation.finish()
                return result
            }
            for await event in channel.stream {
                state = .running
                gracefulStopState = GracefulStopState.receiving(event.data?["state"]?.string ?? "", current: gracefulStopState)
                if gracefulStopState == .accepted { gracefulStopMessage = nil }
                if event.data?["state"]?.string == "graceful_stop_unavailable" {
                    gracefulStopRequested = false
                    gracefulStopMessage = "Stop Unavailable. Force Stop remains available."
                }
                events.append(event)
                if events.count > 256 { events.removeFirst(); historyTruncated = true }
                if let phase = event.phase { currentPhase = phase }
                if event.type == "result" { latestResult = event }
                if let mutation = event.data?["target_mutation_may_have_started"]?.boolean {
                    mutationMayHaveStarted = mutationMayHaveStarted == true || mutation
                }
                if event.type == "secure_publication_started" { mutationMayHaveStarted = true }
                if let publication = event.data?["publication_occurred"]?.boolean {
                    publicationOccurred = publicationOccurred == true || publication
                }
            }
            let outcome = await producer.value
            termination = outcome
            restoreIdentityInventory = outcome.restoreIdentityInventory
            sshReview = outcome.sshReview
            secureCheck = outcome.secureCheck
            self.transport = nil
            stopping = false
            if let failure = outcome.error { error = failure; state = .failed }
            else if outcome.terminal?.isCancellation == true || (outcome.terminal == nil && outcome.cancellationRequested) {
                state = .cancelled
            } else if let terminal = outcome.terminal, terminal.type == "failed" {
                error = .coreFailure(terminal.code ?? "unknown_failure")
                state = .failed
            } else if request.command.operation == .capabilities {
                do {
                    guard let latestResult else { throw CoreRuntimeError.malformedEvent }
                    let value = try latestResult.decodeData(CoreCapabilities.self)
                    guard value.protocolVersion == 1 else { throw CoreRuntimeError.incompatibleProtocol(value.protocolVersion) }
                    guard !value.productVersion.isEmpty else { throw CoreRuntimeError.malformedEvent }
                    homebrewGracefulSupported = value.features?["homebrew_graceful_stop"]?.object?["version"]?.integer == 1
                    capabilities = value
                    coreProductVersion = value.productVersion // Header metadata is sanitized on the log queue.
                    bundleComparisonSupported = value.supportsBundleComparison
                    secureCheckSupported = value.supportsSecureCheck
                    state = .completed
                } catch { self.error = error as? CoreRuntimeError ?? .malformedEvent; state = .failed }
            } else { state = .completed } // Operation completion, never a conformity verdict.
            if let log {
                let terminalError: CoreRuntimeError? = outcome.terminal?.type == "failed" && outcome.terminal?.isCancellation == false
                    ? .coreFailure(outcome.terminal?.code ?? "unknown_failure") : nil
                let status = await log.finish(outcome, error: outcome.error ?? terminalError)
                if logGeneration == generation { logFinished = true; operationLogStatus = status }
            }
        }
    }
    @discardableResult func requestGracefulStop() -> Bool {
        guard isActive, operation == .restoreExecute, !gracefulStopRequested else { return false }
        guard homebrewGracefulSupported, transport?.requestGracefulStop() == true else {
            logSession?.client(.gracefulStopDeliveryFailed)
            gracefulStopState = .deliveryFailed
            gracefulStopMessage = "Graceful Stop could not be delivered. Force Stop remains available."
            return false
        }
        gracefulStopRequested = true; gracefulStopState = .requested; gracefulStopMessage = "Stop Requested"
        logSession?.client(.gracefulStopDelivered)
        if let challenge = secureChallenge { cancelSecureChallenge(challenge) }
        return true
    }
    func cancel() {
        guard isActive else { return }
        clearSecureChallenge()
        stopping = true
        gracefulStopMessage = nil
        logSession?.client(.forceStopRequested)
        transport?.cancel()
    }
    private func clearSecureChallenge() {
        secureReply = nil
        secureChallenge = nil
    }
    @discardableResult func respond(to challenge: CoreSecureChallenge, with response: CoreSecureResponse) -> Bool {
        guard isActive, !stopping, (operation == .captureExecute || operation == .restoreExecute || operation == .secureRestoreCompare || operation == .secureRestoreInventory || operation == .sshRestoreReview || operation == .secureCheckInventory || operation == .secureCheckCompare), operationID == challenge.operationID,
              secureChallenge == challenge, transport?.secureState == .waiting(challenge), let reply = secureReply else { return false }
        clearSecureChallenge()
        if case .cancel = response {
            if operation == .restoreExecute || operation == .secureRestoreCompare || operation == .secureRestoreInventory || operation == .sshRestoreReview || operation == .secureCheckInventory || operation == .secureCheckCompare { secureCancellationRequested = true }
            else { stopping = true }
        }
        reply(response)
        return true
    }
    func cancelSecureChallenge(_ challenge: CoreSecureChallenge) { _ = respond(to: challenge, with: .cancel) }
    func waitForCompletion() async { await work?.value }
    func operationLogHistory() async throws -> [OperationLogHistory] { try await operationLogs?.history() ?? [] }
    var operationLogStore: OperationLogStore? { operationLogs }
    func operationLogReference(matching id: String?) -> OperationLogReference? {
        operationLogReferences.values.first { $0.operationID == id }
    }
    func latestOperationLog(_ operations: Set<CoreOperation>) -> OperationLogReference? {
        operationLogReferences.values.filter { operations.contains($0.operation) }.max { $0.time < $1.time }
    }
    func checkCapabilities() { start(CoreRequest(.capabilities)) }
}
