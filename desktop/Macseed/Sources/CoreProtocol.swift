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
    case capturePrepare = "capture_prepare", captureExecute = "capture_execute", captureIdentityInspect = "capture_identity_inspect"
    case restorePrepare = "restore_prepare", restoreExecute = "restore_execute", secureRestoreCompare = "secure_restore_compare", secureRestoreInventory = "secure_restore_inventory"
    case sshRestoreReview = "ssh_restore_review"
    case environmentCompare = "environment_compare"
    case secureCheckInventory = "secure_check_inventory", secureCheckCompare = "secure_check_compare"
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

// Private operation/session data, deliberately absent from ordinary Core JSONL.
struct CoreRestoreDestinations: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    struct Item: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
        var description: String { "RestoreDestination(redacted)" }
        var debugDescription: String { description }
        var customMirror: Mirror { Mirror(self, children: [:]) }
        let identityID: String
        let directory: String?
        var selected: Bool? = nil
        enum CodingKeys: String, CodingKey { case identityID = "identity_id", directory, selected }
        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(identityID, forKey: .identityID)
            if let directory { try values.encode(directory, forKey: .directory) }
            else { try values.encodeNil(forKey: .directory) }
            if let selected { try values.encode(selected, forKey: .selected) }
        }
    }
    let version: Int
    let bundleID: String
    let items: [Item]
    enum CodingKeys: String, CodingKey { case version, bundleID = "bundle_id", items }
    var description: String { "RestoreDestinations(redacted)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: [:]) }
    func validate() throws {
        guard [1, 2].contains(version), Self.validID(bundleID), (1...32).contains(items.count),
              items.allSatisfy({ version == 1 ? $0.selected == nil : $0.selected != nil }),
              items.map(\.identityID) == Array(Set(items.map(\.identityID))).sorted(),
              items.allSatisfy({ Self.validID($0.identityID) && ($0.directory.map {
                  $0.hasPrefix("/") && $0.utf8.count <= 1024 && !$0.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
              } ?? true) }) else { throw CoreRuntimeError.invalidRequest }
    }
    static func validID(_ value: String) -> Bool { value.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil }
}

struct CoreRestoreIdentityInventory: Decodable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    struct Item: Decodable, Identifiable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
        let identityID: String
        let name: String
        let keyType: String
        let fingerprint: String
        var id: String { identityID }
        enum CodingKeys: String, CodingKey { case identityID = "identity_id", name, keyType = "key_type", fingerprint }
        var description: String { "RestoreIdentity(redacted)" }
        var debugDescription: String { description }
        var customMirror: Mirror { Mirror(self, children: [:]) }
    }
    let version: Int
    let operationID: String
    let bundleID: String
    let items: [Item]
    enum CodingKeys: String, CodingKey { case version, operationID = "operation_id", bundleID = "bundle_id", items }
    var description: String { "RestoreInventory(redacted)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: [:]) }
    func validate(operationID: String) throws {
        guard version == 1, self.operationID == operationID, CoreRestoreDestinations.validID(bundleID),
              (1...32).contains(items.count), Set(items.map(\.id)).count == items.count,
              Set(items.map { $0.name.lowercased() }).count == items.count, Set(items.map(\.fingerprint)).count == items.count,
              items.allSatisfy({ CoreRestoreDestinations.validID($0.id)
                  && $0.name.range(of: "^[A-Za-z0-9][A-Za-z0-9_.-]{0,79}$", options: .regularExpression) != nil
                  && !$0.name.lowercased().hasSuffix(".pub")
                  && ["ssh-ed25519", "ssh-rsa", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521"].contains($0.keyType)
                  && $0.fingerprint.range(of: "^SHA256:[A-Za-z0-9+/]{43}$", options: .regularExpression) != nil
              }) else { throw CoreRuntimeError.secureChannelInvalid }
    }
}

enum CoreCommand: Sendable {
    case capabilities
    case bundleInspect(path: String)
    case captureIdentityInspect
    case capturePrepare(selection: CoreCaptureSelection?)
    case captureExecute(selection: CoreCaptureSelection, destination: String, preparedID: String, replacementSHA256: String? = nil)
    case restorePrepare(path: String, disabledGroups: [String], includeSecure: Bool, selection: CoreRestoreSelection? = nil, installerPreparations: [String]? = nil)
    case restoreExecute(path: String, disabledGroups: [String], includeSecure: Bool, preparedID: String, selection: CoreRestoreSelection? = nil, secureComparison: CoreSecureComparison? = nil)
    case sshRestoreReview(path: String, selection: CoreRestoreSelection, includeSecure: Bool = false)
    case secureRestoreInventory(path: String)
    case secureRestoreCompare(path: String, preparedID: String, selection: CoreRestoreSelection)
    case environmentCompare(generatedDirectory: String, blueprintPath: String?)
    case environmentCompareBundle(path: String)
    case secureCheckInventory(path: String, bundleID: String)
    case secureCheckCompare(path: String, bundleID: String)

    var operation: CoreOperation {
        switch self {
        case .capabilities: .capabilities
        case .bundleInspect: .bundleInspect
        case .captureIdentityInspect: .captureIdentityInspect
        case .capturePrepare: .capturePrepare
        case .captureExecute: .captureExecute
        case .restorePrepare: .restorePrepare
        case .restoreExecute: .restoreExecute
        case .sshRestoreReview: .sshRestoreReview
        case .secureRestoreInventory: .secureRestoreInventory
        case .secureRestoreCompare: .secureRestoreCompare
        case .environmentCompare, .environmentCompareBundle: .environmentCompare
        case .secureCheckInventory: .secureCheckInventory
        case .secureCheckCompare: .secureCheckCompare
        }
    }
    var requiresSecretBridge: Bool {
        switch self {
        case .captureExecute(let selection, _, _, _): !selection.secureIdentities.isEmpty
        case .restoreExecute(_, _, let secure, _, _, _): secure
        case .secureRestoreCompare, .secureRestoreInventory, .secureCheckInventory, .secureCheckCompare: true
        case .sshRestoreReview(_, _, let secure): secure
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
        case .bundleInspect(let path), .secureRestoreInventory(let path): return .object(["path": .string(path)])
        case .sshRestoreReview(let path, let value, let secure):
            return .object(["path": .string(path), "include_secure": .bool(secure), "selection": try JSONDecoder().decode(CoreJSON.self, from: JSONEncoder().encode(value))])
        case .captureIdentityInspect: return .object([:])
        case .capturePrepare(let value): return .object(["selection": try selection(value)])
        case .captureExecute(let value, let destination, let id, let replacement):
            var parameters: [String: CoreJSON] = ["selection": try selection(value), "destination": .string(destination), "expected_prepared_capture_id": .string(id)]
            if let replacement { parameters["replacement_sha256"] = .string(replacement) }
            return .object(parameters)
        case .restorePrepare(let path, let groups, let secure, let selection, let installers):
            var values = restore(path, groups, secure)
            if let installers { values["installer_preparations"] = .array(installers.map(CoreJSON.string)) }
            if let selection { values["selection"] = try JSONDecoder().decode(CoreJSON.self, from: JSONEncoder().encode(selection)) }
            return .object(values)
        case .secureRestoreCompare(let path, let id, let selection):
            return .object(["path": .string(path), "disabled_groups": .array([]), "include_secure": .bool(true),
                "expected_prepared_plan_id": .string(id), "selection": try JSONDecoder().decode(CoreJSON.self, from: JSONEncoder().encode(selection))])
        case .restoreExecute(let path, let groups, let secure, let id, let selection, let comparison):
            var values = restore(path, groups, secure)
            values["expected_prepared_plan_id"] = .string(id)
            if let comparison { values["secure_comparison"] = try JSONDecoder().decode(CoreJSON.self, from: JSONEncoder().encode(comparison)) }
            if let selection { values["selection"] = try JSONDecoder().decode(CoreJSON.self, from: JSONEncoder().encode(selection)) }
            return .object(values)
        case .environmentCompareBundle(let path):
            return .object(["bundle_path": .string(path)])
        case .secureCheckInventory(let path, let id), .secureCheckCompare(let path, let id):
            guard path.hasPrefix("/"), !path.contains("\0"), CoreRestoreDestinations.validID(id) else { throw CoreRuntimeError.invalidRequest }
            return .object(["path": .string(path), "expected_bundle_id": .string(id)])
        case .environmentCompare(let directory, let blueprint):
            return .object(["generated_dir": .string(directory), "blueprint_path": blueprint.map(CoreJSON.string) ?? .null])
        }
    }
}

struct CoreRequest: Sendable {
    let command: CoreCommand
    let operationID: String
    // Capture-session references only. Never serialized into the ordinary request
    // or logs; the transport owns a private per-operation reference file.
    let externalIdentityPaths: [String]
    let restoreDestinations: CoreRestoreDestinations?
    let sshApprovals: CoreSSHApprovals?
    init(_ command: CoreCommand, operationID: String = UUID().uuidString, externalIdentityPaths: [String] = [], restoreDestinations: CoreRestoreDestinations? = nil, sshApprovals: CoreSSHApprovals? = nil) {
        self.command = command
        self.operationID = operationID
        self.externalIdentityPaths = externalIdentityPaths
        self.restoreDestinations = restoreDestinations
        self.sshApprovals = sshApprovals
    }
    func encoded() throws -> Data {
        guard operationID.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil else {
            throw CoreRuntimeError.invalidRequest
        }
        var fields: [String: CoreJSON] = ["protocol_version": .integer(1), "operation_id": .string(operationID),
                                          "operation": .string(command.operation.rawValue)]
        if let parameters = try command.parameters() { fields["parameters"] = parameters }
        if !externalIdentityPaths.isEmpty {
            guard [.capturePrepare, .captureExecute, .captureIdentityInspect].contains(command.operation),
                  externalIdentityPaths.count <= 32, Set(externalIdentityPaths).count == externalIdentityPaths.count,
                  externalIdentityPaths.allSatisfy({ $0.hasPrefix("/") && $0.utf8.count <= 1024 && !$0.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) }),
                  var parameters = fields["parameters"]?.object else { throw CoreRuntimeError.invalidRequest }
            parameters["external_identities"] = .bool(true)
            fields["parameters"] = .object(parameters)
        } else if command.operation == .captureIdentityInspect { throw CoreRuntimeError.invalidRequest }
        if let restoreDestinations {
            guard [.restorePrepare, .restoreExecute, .secureRestoreCompare, .sshRestoreReview, .secureCheckCompare].contains(command.operation),
                  var parameters = fields["parameters"]?.object,
                  command.operation == .secureCheckCompare || parameters["include_secure"]?.boolean == true else { throw CoreRuntimeError.invalidRequest }
            try restoreDestinations.validate()
            if command.operation == .secureCheckCompare {
                guard restoreDestinations.version == 2, restoreDestinations.items.contains(where: { $0.selected == true }),
                      parameters["expected_bundle_id"]?.string == restoreDestinations.bundleID else { throw CoreRuntimeError.invalidRequest }
            }
            parameters["custom_destinations"] = .bool(true)
            fields["parameters"] = .object(parameters)
        }
        if command.operation == .secureCheckCompare && restoreDestinations == nil { throw CoreRuntimeError.invalidRequest }
        if let sshApprovals {
            guard [.restorePrepare, .restoreExecute, .secureRestoreCompare, .sshRestoreReview].contains(command.operation),
                  var parameters = fields["parameters"]?.object else { throw CoreRuntimeError.invalidRequest }
            try sshApprovals.validate(review: command.operation == .sshRestoreReview)
            parameters["ssh_approvals"] = .bool(true)
            fields["parameters"] = .object(parameters)
        }
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
    case secureChannelInvalid, secureChannelTimeout, secureChannelDisconnected
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
    var supportsSSHResolution: Bool { operations.contains("ssh_restore_review") && features?["ssh_identity_resolution"]?.object?["version"]?.integer == 1 }
    var supportsSecureRestoreDestinations: Bool { operations.contains("secure_restore_inventory") && features?["secure_restore_destinations"]?.object?["version"]?.integer == 1 }
    var supportsSecureRestoreSelection: Bool { supportsSecureRestoreDestinations && features?["secure_restore_destinations"]?.object?["selection_version"]?.integer == 2 }
    var supportsBundleComparison: Bool { features?["bundle_comparison"]?.object?["version"]?.integer == 1 }
    var supportsSecureCheck: Bool {
        let feature = features?["secure_check"]?.object
        return operations.contains("secure_check_inventory") && operations.contains("secure_check_compare")
            && feature?["version"]?.integer == 1 && feature?["selection_version"]?.integer == 2 && feature?["read_only"]?.boolean == true
    }
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
    init(operationID: String) {
        self.operationID = operationID
    }
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
