import Foundation

enum CoreLocationKind: Sendable { case development, bundledResource }

struct CoreLocation: Sendable {
    let kind: CoreLocationKind
    let root: URL
    let python: URL
    let home: URL
    let temporaryBase: URL
    let toolDirectories: [URL]
    var launcher: URL { root.appendingPathComponent("modules/core/application-interface/core.sh") }

    init(root: URL, python: URL, home: URL = URL(fileURLWithPath: NSHomeDirectory()),
         temporaryBase: URL = FileManager.default.temporaryDirectory, kind: CoreLocationKind = .development,
         toolDirectories: [URL] = [URL(fileURLWithPath: "/opt/homebrew/bin"), URL(fileURLWithPath: "/usr/local/bin")]) {
        self.toolDirectories = toolDirectories
        self.kind = kind
        self.root = root
        self.python = python
        self.home = home
        self.temporaryBase = temporaryBase
    }
    func validate(for command: CoreCommand) throws {
        let files = [launcher, root.appendingPathComponent("modules/core/application-interface/core.py"),
                     root.appendingPathComponent("config/toolkit.conf"), root.appendingPathComponent("bootstrap.sh")]
        guard files.allSatisfy({ FileManager.default.isReadableFile(atPath: $0.path) }) else {
            throw CoreRuntimeError.runtimeUnavailable
        }
        guard python.lastPathComponent == "python3", FileManager.default.isExecutableFile(atPath: python.path) else {
            throw CoreRuntimeError.pythonUnavailable
        }
        if command.requiresSecretBridge { throw CoreRuntimeError.secureBridgeUnavailable }
        // Current Core writes logs/config under its own root. Never try to write into
        // signed resources; workflow runtime placement must be qualified separately.
        if ![CoreOperation.capabilities, .bundleInspect].contains(command.operation),
           (kind == .bundledResource || !FileManager.default.isWritableFile(atPath: root.path)) {
            throw CoreRuntimeError.writableCoreRequired
        }
    }
    func environment(temporary: URL) -> [String: String] {
        // Never inherit arbitrary BLUEPRINT_*, credentials, PYTHONPATH or loader vars.
        let helpers = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers")
        let bundledMAS = FileManager.default.isExecutableFile(atPath: helpers.appendingPathComponent("mas").path)
        let path = ((bundledMAS ? [helpers.path] : []) + [python.deletingLastPathComponent().path] + toolDirectories.map(\.path) + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]).joined(separator: ":")
        var environment = ["HOME": home.path, "PATH": path,
         "TMPDIR": temporary.path, "LC_ALL": "en_US.UTF-8", "PYTHONDONTWRITEBYTECODE": "1"]
        if bundledMAS && FileManager.default.isExecutableFile(atPath: helpers.appendingPathComponent("MASClient").path) {
            environment["MACSEED_MAS_INVENTORY_COMMAND"] = helpers.appendingPathComponent("mas").path
            environment["MACSEED_MAS_ADAPTER"] = helpers.appendingPathComponent("MASClient").path
        }
        let parent = ProcessInfo.processInfo.environment
        if parent["MACSEED_PERFORMANCE_TRACE"] == "1" {
            environment["MACSEED_PERFORMANCE_TRACE"] = "1"
            if let directory = parent["MACSEED_PERFORMANCE_TRACE_DIR"], !directory.isEmpty {
                environment["MACSEED_PERFORMANCE_TRACE_DIR"] = directory
            }
        }
        return environment
    }
}

struct CoreLocationResolver {
    let resources: URL?
    init(resources: URL? = Bundle.main.resourceURL) { self.resources = resources }
    func resolve() throws -> CoreLocation {
        guard let resources,
              let bytes = try? Data(contentsOf: resources.appendingPathComponent("CoreRuntime.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: bytes, format: nil),
              let fields = plist as? [String: Any], fields["Version"] as? Int == 1,
              let mode = fields["Mode"] as? String else { throw CoreRuntimeError.runtimeUnavailable }
        let root: URL
        let python: URL
        if mode == "development" {
            guard let core = fields["CoreRoot"] as? String, core.hasPrefix("/"),
                  let runtime = fields["PythonExecutable"] as? String, runtime.hasPrefix("/"),
                  !core.contains("\0"), !runtime.contains("\0") else { throw CoreRuntimeError.invalidRuntimeConfiguration }
            root = URL(fileURLWithPath: core)
            python = URL(fileURLWithPath: runtime)
        } else if mode == "bundled" {
            func contained(_ key: String) throws -> URL {
                guard let path = fields[key] as? String, !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0") else {
                    throw CoreRuntimeError.invalidRuntimeConfiguration
                }
                let value = resources.appendingPathComponent(path).resolvingSymlinksInPath()
                guard value.path.hasPrefix(resources.resolvingSymlinksInPath().path + "/") else {
                    throw CoreRuntimeError.invalidRuntimeConfiguration
                }
                return value
            }
            root = try contained("CorePath")
            python = try contained("PythonPath")
        } else { throw CoreRuntimeError.invalidRuntimeConfiguration }
        return CoreLocation(root: root, python: python, kind: mode == "bundled" ? .bundledResource : .development)
    }
}
