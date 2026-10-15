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
    private(set) var bundleComparisonSupported: Bool?
    private(set) var homebrewGracefulSupported = false
    @Published private(set) var gracefulStopRequested = false
    @Published private(set) var gracefulStopState: GracefulStopState = .idle
    @Published private(set) var gracefulStopMessage: String?
    @Published private(set) var capabilities: CoreCapabilities?
    @Published private(set) var mutationMayHaveStarted: Bool?
    @Published private(set) var publicationOccurred: Bool?
    @Published private(set) var stopping = false
    @Published private(set) var operationLogStatus: OperationLogStatus = .inactive
    @Published private(set) var operationLogReferences: [CoreOperation: OperationLogReference] = [:]
    private let resolver: CoreLocationResolver
    private let operationLogs: OperationLogStore?
    private var logSession: OperationLogSession?
    private var logGeneration = UUID()
    private var logFinished = false
    private var coreProductVersion: String?
    init(resolver: CoreLocationResolver = CoreLocationResolver(), operationLogs: OperationLogStore? = .shared) {
        self.resolver = resolver; self.operationLogs = operationLogs
    }
    private var transport: CoreTransport?
    private var work: Task<Void, Never>?
    var isActive: Bool { state == .launching || state == .running }

    func start(_ request: CoreRequest, location: CoreLocation? = nil) {
        guard !isActive else { return }
        if request.command.operation == .capabilities { bundleComparisonSupported = nil }
        state = .launching
        operationID = request.operationID
        operation = request.command.operation
        currentPhase = nil
        events = []
        historyTruncated = false
        latestResult = nil
        error = nil
        termination = nil
        capabilities = nil
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
        let transport = CoreTransport()
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
                    let status = await log.finish(nil, error: failure)
                    if logGeneration == generation { logFinished = true; operationLogStatus = status }
                }
                return
            }
            let producer = Task {
                let result = await transport.run(request: request, location: resolved) { event in
                    log?.receive(event)
                    channel.continuation.yield(event)
                }
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
                if let publication = event.data?["publication_occurred"]?.boolean {
                    publicationOccurred = publicationOccurred == true || publication
                }
            }
            let outcome = await producer.value
            termination = outcome
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
        return true
    }
    func cancel() {
        guard isActive else { return }
        stopping = true
        gracefulStopMessage = nil
        logSession?.client(.forceStopRequested)
        transport?.cancel()
    }
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
