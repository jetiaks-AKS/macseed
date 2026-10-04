import Foundation

// Lossless JSON values: future fields stay available without a parallel domain model.
indirect enum CoreJSON: Codable, Equatable, Sendable {
    case object([String: CoreJSON]), array([CoreJSON]), string(String), integer(Int), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let bool = try? value.decode(Bool.self) { self = .bool(bool) }
        else if let int = try? value.decode(Int.self) { self = .integer(int) }
        else if let number = try? value.decode(Double.self) { self = .number(number) }
        else if let string = try? value.decode(String.self) { self = .string(string) }
        else if let array = try? value.decode([CoreJSON].self) { self = .array(array) }
        else { self = .object(try value.decode([String: CoreJSON].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .object(let x): try value.encode(x)
        case .array(let x): try value.encode(x)
        case .string(let x): try value.encode(x)
        case .integer(let x): try value.encode(x)
        case .number(let x): try value.encode(x)
        case .bool(let x): try value.encode(x)
        case .null: try value.encodeNil()
        }
    }
    var object: [String: CoreJSON]? { if case .object(let x) = self { return x }; return nil }
    var string: String? { if case .string(let x) = self { return x }; return nil }
    var integer: Int? { if case .integer(let x) = self { return x }; return nil }
    var boolean: Bool? { if case .bool(let x) = self { return x }; return nil }
}

enum CoreOperation: String, Codable, CaseIterable, Sendable {
    case capabilities, bundleInspect = "bundle_inspect"
    case capturePrepare = "capture_prepare", captureExecute = "capture_execute"
    case restorePrepare = "restore_prepare", restoreExecute = "restore_execute"
    case environmentCompare = "environment_compare"
}

struct CoreCaptureSelection: Codable, Equatable, Sendable {
    let categories: [String]
    let items: [String: [String]]
    let secureIdentities: [String]
    enum CodingKeys: String, CodingKey { case categories, items, secureIdentities = "secure_identities" }
}

struct CoreRestoreSelection: Codable, Equatable, Sendable {
    let categories: [String]
    let items: [String: [String]]
}

// The discriminator comes from Core inventory, never inferred from a sample category.
struct CoreCaptureInventoryRow: Decodable, Sendable {
    let domain: String
    let status: String
    let reason: String?
    let selectionMode: String // "items" / "category"; unknown modes must not enable selection.
    let items: [Item]
    let includedSettings: [IncludedSetting]?
    struct IncludedSetting: Decodable, Sendable {
        let id: String
        let label: String
    }
    struct Item: Decodable, Sendable {
        let itemID: String
        let label: String
        enum CodingKeys: String, CodingKey { case itemID = "item_id", label }
    }
    enum CodingKeys: String, CodingKey { case domain, status, reason, items, selectionMode = "selection_mode", includedSettings = "included_settings" }
}

enum CoreCommand: Sendable {
    case capabilities
    case bundleInspect(path: String)
    case capturePrepare(selection: CoreCaptureSelection?)
    case captureExecute(selection: CoreCaptureSelection, destination: String, preparedID: String)
    case restorePrepare(path: String, disabledGroups: [String], includeSecure: Bool, selection: CoreRestoreSelection? = nil)
    case restoreExecute(path: String, disabledGroups: [String], includeSecure: Bool, preparedID: String, selection: CoreRestoreSelection? = nil)
    case environmentCompare(generatedDirectory: String, blueprintPath: String?)

    var operation: CoreOperation {
        switch self {
        case .capabilities: .capabilities
        case .bundleInspect: .bundleInspect
        case .capturePrepare: .capturePrepare
        case .captureExecute: .captureExecute
        case .restorePrepare: .restorePrepare
        case .restoreExecute: .restoreExecute
        case .environmentCompare: .environmentCompare
        }
    }
    var requiresSecretBridge: Bool {
        switch self {
        case .captureExecute(let selection, _, _): !selection.secureIdentities.isEmpty
        case .restoreExecute(_, _, let secure, _, _): secure
        default: false
        }
    }
    func parameters() throws -> CoreJSON? {
        func selection(_ value: CoreCaptureSelection?) throws -> CoreJSON {
            guard let value else { return .null }
            return try JSONDecoder().decode(CoreJSON.self, from: JSONEncoder().encode(value))
        }
        func restore(_ path: String, _ groups: [String], _ secure: Bool) -> [String: CoreJSON] {
            ["path": .string(path), "disabled_groups": .array(groups.map(CoreJSON.string)), "include_secure": .bool(secure)]
        }
        switch self {
        case .capabilities: return nil
        case .bundleInspect(let path): return .object(["path": .string(path)])
        case .capturePrepare(let value): return .object(["selection": try selection(value)])
        case .captureExecute(let value, let destination, let id):
            return .object(["selection": try selection(value), "destination": .string(destination), "expected_prepared_capture_id": .string(id)])
        case .restorePrepare(let path, let groups, let secure, let selection):
            var values = restore(path, groups, secure)
            if let selection { values["selection"] = try JSONDecoder().decode(CoreJSON.self, from: JSONEncoder().encode(selection)) }
            return .object(values)
        case .restoreExecute(let path, let groups, let secure, let id, let selection):
            var values = restore(path, groups, secure)
            values["expected_prepared_plan_id"] = .string(id)
            if let selection { values["selection"] = try JSONDecoder().decode(CoreJSON.self, from: JSONEncoder().encode(selection)) }
            return .object(values)
        case .environmentCompare(let directory, let blueprint):
            return .object(["generated_dir": .string(directory), "blueprint_path": blueprint.map(CoreJSON.string) ?? .null])
        }
    }
}

struct CoreRequest: Sendable {
    let command: CoreCommand
    let operationID: String
    init(_ command: CoreCommand, operationID: String = UUID().uuidString) {
        self.command = command
        self.operationID = operationID
    }
    func encoded() throws -> Data {
        guard operationID.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil else {
            throw CoreRuntimeError.invalidRequest
        }
        var fields: [String: CoreJSON] = ["protocol_version": .integer(1), "operation_id": .string(operationID),
                                          "operation": .string(command.operation.rawValue)]
        if let parameters = try command.parameters() { fields["parameters"] = parameters }
        let data = try JSONEncoder().encode(CoreJSON.object(fields))
        guard data.count <= 4096 else { throw CoreRuntimeError.requestTooLarge }
        return data
    }
}

enum CoreRuntimeError: Error, Equatable, Sendable {
    case runtimeUnavailable, invalidRuntimeConfiguration, pythonUnavailable, writableCoreRequired
    case invalidRequest, requestTooLarge, secureBridgeUnavailable, launchFailed(Int32), ioFailed(Int32)
    case malformedEvent, incompatibleProtocol(Int), operationMismatch, sequenceOrder, invalidLifecycle
    case eventTooLarge, incompleteStream, missingTerminal, exitMismatch, interrupted, coreFailure(String)
    var message: String {
        switch self {
        case .runtimeUnavailable: "Macseed Core runtime is unavailable."
        case .invalidRuntimeConfiguration: "Macseed Core runtime configuration is invalid."
        case .pythonUnavailable: "The configured Macseed Python runtime is unavailable."
        case .writableCoreRequired: "This operation needs a writable Core workspace."
        case .secureBridgeUnavailable: "Secure transfer integration is not available yet."
        case .incompatibleProtocol: "Macseed Core uses an incompatible protocol version."
        case .interrupted: "The operation was interrupted. Changes may remain. Inspect again before rebuilding."
        case .coreFailure: "Macseed Core could not complete this operation."
        default: "Macseed Core communication failed."
        }
    }
}

struct CoreEvent: Sendable, Equatable {
    let protocolVersion: Int
    let operationID: String
    let sequence: Int
    let type: String // Open vocabulary, including future additive event types.
    let fields: [String: CoreJSON]
    var data: [String: CoreJSON]? { fields["data"]?.object }
    var phase: String? { data?["phase"]?.string ?? fields["phase"]?.string }
    var code: String? { data?["code"]?.string }
    var isCancellation: Bool { type == "cancelled" || (type == "failed" && ["cancelled", "secure_cancelled"].contains(code ?? "")) }
    var isTerminal: Bool { ["completed", "failed", "cancelled"].contains(type) }
    init(line: Data) throws {
        guard let root = try? JSONDecoder().decode(CoreJSON.self, from: line), let fields = root.object,
              let version = fields["protocol_version"]?.integer else { throw CoreRuntimeError.malformedEvent }
        guard version == 1 else { throw CoreRuntimeError.incompatibleProtocol(version) }
        guard let id = fields["operation_id"]?.string, let sequence = fields["sequence"]?.integer,
              sequence > 0, let type = fields["type"]?.string, !type.isEmpty,
              fields["data"] == nil || fields["data"]?.object != nil else { throw CoreRuntimeError.malformedEvent }
        self.protocolVersion = version
        self.operationID = id
        self.sequence = sequence
        self.type = type
        self.fields = fields
    }
    func decodeData<T: Decodable>(_ type: T.Type) throws -> T {
        guard let data = fields["data"] else { throw CoreRuntimeError.malformedEvent }
        return try JSONDecoder().decode(type, from: JSONEncoder().encode(data))
    }
}

struct CoreCapabilities: Decodable, Sendable {
    let protocolVersion: Int
    let productVersion: String
    let operations: [String]
    let features: [String: CoreJSON]?
    var supportsRestoreSelection: Bool { features?["restore_selection"]?.object?["version"]?.integer == 1 }
    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version", productVersion = "product_version", operations, features
    }
}

// Framing and lifecycle validation apply to every operation, not domain logic.
struct CoreEventStream {
    static let maximumLineBytes = 64 * 1024 * 1024 // Aggregate result events can be much larger than individual Core records.
    let operationID: String
    private var receivedBytes = 0
    private(set) var lastSequence = 0
    private(set) var terminal: CoreEvent?
    private(set) var receivedResult = false
    private var started = false
    private var buffer = Data()
    mutating func append(_ bytes: Data, receive: (CoreEvent) throws -> Void) throws {
        receivedBytes += bytes.count
        guard receivedBytes <= 256 * 1024 * 1024 else { throw CoreRuntimeError.eventTooLarge }
        buffer.append(bytes)
        while let end = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<end])
            buffer.removeSubrange(...end)
            guard !line.isEmpty else { throw CoreRuntimeError.malformedEvent }
            guard line.count <= Self.maximumLineBytes else { throw CoreRuntimeError.eventTooLarge }
            let event = try CoreEvent(line: line)
            guard event.operationID == operationID else { throw CoreRuntimeError.operationMismatch }
            guard event.sequence > lastSequence else { throw CoreRuntimeError.sequenceOrder }
            guard terminal == nil else { throw CoreRuntimeError.invalidLifecycle }
            if !started {
                guard event.type == "started" || event.type == "failed" else { throw CoreRuntimeError.invalidLifecycle }
                started = event.type == "started"
            } else if event.type == "started" { throw CoreRuntimeError.invalidLifecycle }
            if event.type == "failed", event.code == nil { throw CoreRuntimeError.malformedEvent }
            if event.type == "result" { receivedResult = true }
            if event.type == "completed", !receivedResult { throw CoreRuntimeError.invalidLifecycle }
            lastSequence = event.sequence
            if event.isTerminal { terminal = event }
            try receive(event)
        }
        guard buffer.count <= Self.maximumLineBytes else { throw CoreRuntimeError.eventTooLarge }
    }
    func finish(exitCode: Int32, signalled: Bool) throws -> CoreEvent {
        guard buffer.isEmpty else { throw CoreRuntimeError.incompleteStream }
        guard let terminal else { throw signalled ? CoreRuntimeError.interrupted : CoreRuntimeError.missingTerminal }
        let expected: Int32 = terminal.isCancellation ? 130 : (terminal.type == "completed" ? 0 : 2)
        guard !signalled, exitCode == expected else { throw CoreRuntimeError.exitMismatch }
        return terminal
    }
}
