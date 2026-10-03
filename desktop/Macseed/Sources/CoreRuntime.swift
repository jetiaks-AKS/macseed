import Combine
import Foundation

enum CoreRuntimeState: String { case idle, launching, running, completed, failed, cancelled }

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
    @Published private(set) var capabilities: CoreCapabilities?
    @Published private(set) var mutationMayHaveStarted: Bool?
    @Published private(set) var publicationOccurred: Bool?
    @Published private(set) var stopping = false
    private let resolver: CoreLocationResolver
    init(resolver: CoreLocationResolver = CoreLocationResolver()) { self.resolver = resolver }
    private var transport: CoreTransport?
    private var work: Task<Void, Never>?
    var isActive: Bool { state == .launching || state == .running }

    func start(_ request: CoreRequest, location: CoreLocation? = nil) {
        guard !isActive else { return }
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
        let channel = AsyncStream<CoreEvent>.makeStream()
        let transport = CoreTransport()
        self.transport = transport
        work = Task {
            let resolved: CoreLocation
            do { resolved = try location ?? resolver.resolve() }
            catch {
                self.error = error as? CoreRuntimeError ?? .invalidRuntimeConfiguration
                state = .failed
                self.transport = nil
                return
            }
            let producer = Task {
                let result = await transport.run(request: request, location: resolved) { event in
                    channel.continuation.yield(event)
                }
                channel.continuation.finish()
                return result
            }
            for await event in channel.stream {
                state = .running
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
                    capabilities = value
                    state = .completed
                } catch { self.error = error as? CoreRuntimeError ?? .malformedEvent; state = .failed }
            } else { state = .completed } // Operation completion, never a conformity verdict.
        }
    }
    func cancel() {
        guard isActive else { return }
        stopping = true
        transport?.cancel()
    }
    func waitForCompletion() async { await work?.value }
    func checkCapabilities() { start(CoreRequest(.capabilities)) }
}
