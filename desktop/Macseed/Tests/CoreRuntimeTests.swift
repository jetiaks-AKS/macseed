import Foundation

@main struct CoreRuntimeTests {
    static func performanceTraceEnvironment(_ location: CoreLocation, temporary: URL) {
        let names = ["MACSEED_PERFORMANCE_TRACE", "MACSEED_PERFORMANCE_TRACE_DIR", "MACSEED_PERFORMANCE_SCOPE", "PYTHONPATH"]
        let original = ProcessInfo.processInfo.environment
        defer {
            for name in names {
                if let value = original[name] { setenv(name, value, 1) }
                else { unsetenv(name) }
            }
        }
        for name in names { unsetenv(name) }
        let baseline = location.environment(temporary: temporary)
        precondition(baseline["MACSEED_PERFORMANCE_TRACE"] == nil && baseline["MACSEED_PERFORMANCE_TRACE_DIR"] == nil)
        setenv("MACSEED_PERFORMANCE_TRACE_DIR", temporary.appendingPathComponent("not-created").path, 1)
        setenv("MACSEED_PERFORMANCE_SCOPE", "bootstrap", 1)
        setenv("PYTHONPATH", "/untrusted", 1)
        for flag in [nil, "0", "true"] as [String?] {
            if let flag { setenv("MACSEED_PERFORMANCE_TRACE", flag, 1) }
            else { unsetenv("MACSEED_PERFORMANCE_TRACE") }
            precondition(location.environment(temporary: temporary) == baseline)
        }
        setenv("MACSEED_PERFORMANCE_TRACE", "1", 1)
        var expected = baseline
        expected["MACSEED_PERFORMANCE_TRACE"] = "1"
        expected["MACSEED_PERFORMANCE_TRACE_DIR"] = temporary.appendingPathComponent("not-created").path
        precondition(location.environment(temporary: temporary) == expected)
        precondition(!FileManager.default.fileExists(atPath: expected["MACSEED_PERFORMANCE_TRACE_DIR"]!))
        expected.removeValue(forKey: "MACSEED_PERFORMANCE_TRACE_DIR")
        setenv("MACSEED_PERFORMANCE_TRACE_DIR", "", 1)
        precondition(location.environment(temporary: temporary) == expected)
        unsetenv("MACSEED_PERFORMANCE_TRACE_DIR")
        precondition(location.environment(temporary: temporary) == expected)
        print("PASS: Performance trace environment is opt-in, bounded and does not create its directory")
    }
    static func encodedEvent(_ sequence: Int, _ type: String, data: CoreJSON? = nil,
                             id: String = "test", version: Int = 1) -> String {
        var fields: [String: CoreJSON] = ["protocol_version": .integer(version), "operation_id": .string(id),
                                         "sequence": .integer(sequence), "type": .string(type)]
        if let data { fields["data"] = data }
        return String(data: try! JSONEncoder().encode(CoreJSON.object(fields)), encoding: .utf8)!
    }
    static let caps: CoreJSON = .object(["protocol_version": .integer(1), "product_version": .string("fixture"),
                                        "operations": .array([.string("capabilities")])])
    static func stream(_ events: [String]) -> String { events.joined(separator: "\n") + "\n" }
    static func script(_ events: [String], exit: Int = 0, before: String = "") -> String {
        "#!/bin/bash\n/bin/cat >/dev/null\n" + before + "\n/bin/cat <<'EVENTS'\n" + stream(events) + "EVENTS\nexit \(exit)\n"
    }
    static func fixture(_ root: URL, body: String) throws -> CoreLocation {
        let core = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: core.appendingPathComponent("modules/core/application-interface"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: core.appendingPathComponent("config"), withIntermediateDirectories: true)
        for name in ["modules/core/application-interface/core.py", "config/toolkit.conf", "bootstrap.sh"] {
            try Data().write(to: core.appendingPathComponent(name))
        }
        try body.write(to: core.appendingPathComponent("modules/core/application-interface/core.sh"), atomically: false, encoding: .utf8)
        let python = core.appendingPathComponent("python3")
        try "#!/bin/sh\nexit 0\n".write(to: python, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: python.path)
        return CoreLocation(root: core, python: python, home: root, temporaryBase: root)
    }
    @MainActor static func run(_ location: CoreLocation, command: CoreCommand = .capabilities) async -> CoreRuntime {
        let runtime = CoreRuntime(operationLogs: nil)
        runtime.start(CoreRequest(command, operationID: "test"), location: location)
        await runtime.waitForCompletion()
        return runtime
    }
    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("macseed-runtime-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        if CommandLine.arguments.contains("--graceful-control-only") {
            let location = try fixture(directory, body: "#!/bin/sh\nexec /Library/Developer/CommandLineTools/usr/bin/python3 -B control.py\n")
            try """
            import json,os,sys
            from pathlib import Path
            request=json.load(sys.stdin)
            def emit(sequence,kind,data=None):
                event=dict(protocol_version=1,operation_id=request['operation_id'],sequence=sequence,type=kind)
                if data is not None: event['data']=data
                print(json.dumps(event),flush=True)
            emit(1,'started')
            if request['operation']=='capabilities':
                emit(2,'result',dict(protocol_version=1,product_version='mock',operations=['restore_execute'],features={'homebrew_graceful_stop':{'version':1}}))
                emit(3,'completed');sys.exit(0)
            assert os.read(int(os.environ['MACSEED_GRACEFUL_FD']),1)==b'S'
            rejected=Path('reject-stop').exists()
            emit(2,'execution_event',dict(domain='orchestration',item_id='stop',state='graceful_stop_unavailable' if rejected else 'graceful_stop_accepted'))
            emit(3,'failed',dict(code='bootstrap_failed' if rejected else 'cancelled',target_mutation_may_have_started=not rejected,unknown_consequences=False))
            sys.exit(2 if rejected else 130)
            """.write(to: location.root.appendingPathComponent("control.py"), atomically: false, encoding: .utf8)
            let runtime = CoreRuntime(operationLogs: nil)
            runtime.start(CoreRequest(.capabilities), location: location); await runtime.waitForCompletion()
            precondition(runtime.homebrewGracefulSupported)
            runtime.start(CoreRequest(.restoreExecute(path: directory.appendingPathComponent("sample.mbt").path,
                disabledGroups: [], includeSecure: false, preparedID: String(repeating: "a", count: 64))), location: location)
            let deadline = Date().addingTimeInterval(8)
            while runtime.state == .launching && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
            guard runtime.state == .running else {
                runtime.cancel(); await runtime.waitForCompletion(); preconditionFailure("mock launch failed")
            }
            precondition(runtime.requestGracefulStop())
            precondition(runtime.gracefulStopState == .requested && runtime.gracefulStopRequested)
            precondition(!runtime.requestGracefulStop())
            await runtime.waitForCompletion()
            precondition(runtime.state == .cancelled && runtime.termination?.exitCode == 130 && runtime.termination?.signalled == false)
            precondition(runtime.events.contains { $0.data?["state"]?.string == "graceful_stop_accepted" })
            precondition(!runtime.stopping && runtime.error == nil && runtime.gracefulStopState == .accepted)
            let acceptedID = runtime.operationID
            try Data().write(to: location.root.appendingPathComponent("reject-stop"))
            runtime.start(CoreRequest(.restoreExecute(path: directory.appendingPathComponent("sample.mbt").path,
                disabledGroups: [], includeSecure: false, preparedID: String(repeating: "a", count: 64))), location: location)
            precondition(runtime.operationID != acceptedID && runtime.gracefulStopState == .idle)
            let rejectionDeadline = Date().addingTimeInterval(8)
            while runtime.state == .launching && Date() < rejectionDeadline { try await Task.sleep(for: .milliseconds(10)) }
            precondition(runtime.requestGracefulStop())
            await runtime.waitForCompletion()
            precondition(runtime.gracefulStopState == .unavailable && !runtime.gracefulStopRequested)
            precondition(runtime.state == .failed && runtime.termination?.exitCode == 2)
            precondition(runtime.gracefulStopMessage?.contains("Stop Unavailable") == true)
            runtime.start(CoreRequest(.capabilities), location: location); await runtime.waitForCompletion()
            precondition(runtime.gracefulStopState == .idle && runtime.gracefulStopMessage == nil)
            print("PASS: Requested/Accepted/Unavailable transitions, ordinary failure after refusal and operation isolation")
            print("PASS: Swift private control FD, capability binding, repeated Graceful Stop, continued events and real cancellation terminal without TERM/KILL")
            return
        }
        let valid = [encodedEvent(1, "started"), encodedEvent(2, "result", data: caps), encodedEvent(3, "completed")]
        let success = try fixture(directory, body: script(valid, before: "printf 'not JSON and secrets must not be rendered\\n' >&2"))
        let runtime = await run(success)
        precondition(runtime.state == .completed && runtime.capabilities?.productVersion == "fixture")
        precondition(runtime.events.map(\.sequence) == [1, 2, 3])
        precondition(runtime.termination?.exitCode == 0 && runtime.termination?.stderr.outputPresent == true)
        print("PASS: Real child JSONL, completion, EOF stdin and isolated stderr")

        let scenarios: [([String], Int, CoreRuntimeError)] = [
            (["not-json"], 0, .malformedEvent),
            ([encodedEvent(1, "started", version: 2)], 0, .incompatibleProtocol(2)),
            ([encodedEvent(1, "started"), encodedEvent(1, "result", data: caps)], 0, .sequenceOrder),
            ([encodedEvent(1, "started", id: "other")], 0, .operationMismatch),
            ([encodedEvent(1, "started")], 0, .missingTerminal),
            (valid, 2, .exitMismatch),
            (valid + [encodedEvent(4, "completed")], 0, .invalidLifecycle),
            ([encodedEvent(1, "completed")], 0, .invalidLifecycle),
            ([encodedEvent(1, "failed")], 2, .malformedEvent)
        ]
        for (events, exit, expected) in scenarios {
            let value = await run(try fixture(directory, body: script(events, exit: exit)))
            precondition(value.state == .failed && value.error == expected, "Expected \(expected), got \(String(describing: value.error))")
        }
        let failed = await run(try fixture(directory, body: script([encodedEvent(1, "failed", data: .object(["code": .string("bundle_invalid")]))], exit: 2)))
        precondition(failed.state == .failed && failed.error == .coreFailure("bundle_invalid"))
        for terminal in [encodedEvent(2, "cancelled"), encodedEvent(2, "failed", data: .object(["code": .string("secure_cancelled")]))] {
            let stopped = await run(try fixture(directory, body: script([encodedEvent(1, "started"), terminal], exit: 130)))
            precondition(stopped.state == .cancelled)
        }
        print("PASS: Typed failures, incompatible version, sequence/identity/lifecycle and terminal exit checks")

        let started = encodedEvent(1, "started")
        let cancelled = encodedEvent(2, "failed", data: .object(["code": .string("cancelled"), "target_mutation_may_have_started": .bool(true)]))
        let cancellationBody = "#!/bin/bash\n/bin/cat >/dev/null\ntrap '/bin/cat <<\"EVENT\"\n\(cancelled)\nEVENT\nexit 130' TERM\nprintf '%s\\n' '\(started)'\nwhile true; do /bin/sleep 0.05; done\n"
        let active = CoreRuntime(operationLogs: nil)
        active.start(CoreRequest(.capabilities, operationID: "test"), location: try fixture(directory, body: cancellationBody))
        for _ in 0..<100 where active.events.isEmpty { try await Task.sleep(nanoseconds: 20_000_000) }
        precondition(active.state == .running)
        active.cancel()
        await active.waitForCompletion()
        precondition(active.state == .cancelled && active.mutationMayHaveStarted == true)
        precondition(active.termination?.exitCode == 130)
        print("PASS: Owned process-group cancellation retains possible mutation evidence")

        let interrupted = CoreRuntime(operationLogs: nil)
        let ignoresStop = "#!/bin/bash\n/bin/cat >/dev/null\ntrap '' TERM\nprintf '%s\\n' '\(started)'\nwhile true; do /bin/sleep 0.05; done\n"
        interrupted.start(CoreRequest(.capabilities, operationID: "test"), location: try fixture(directory, body: ignoresStop))
        for _ in 0..<100 where interrupted.events.isEmpty { try await Task.sleep(nanoseconds: 20_000_000) }
        precondition(interrupted.state == .running)
        interrupted.cancel()
        await interrupted.waitForCompletion()
        precondition(interrupted.state == .failed && interrupted.error == .interrupted)
        precondition(interrupted.termination?.signalled == true && interrupted.mutationMayHaveStarted == nil)
        print("PASS: Forced group termination is interruption, never inferred rollback/handled cancellation")

        var decoder = CoreEventStream(operationID: "test")
        var received: [CoreEvent] = []
        let extended = encodedEvent(4, "future_progress", data: .object(["phase": .string("discovery"), "new_field": .array([.integer(1)])]))
        let bytes = Data(stream([started, extended, encodedEvent(7, "result", data: caps), encodedEvent(8, "completed")]).utf8)
        for byte in bytes { try decoder.append(Data([byte])) { received.append($0) } }
        _ = try decoder.finish(exitCode: 0, signalled: false)
        precondition(received[1].type == "future_progress" && received[1].phase == "discovery")
        precondition(received[1].data?["new_field"] == .array([.integer(1)]))
        var partial = CoreEventStream(operationID: "test")
        try partial.append(Data(started.utf8)) { _ in }
        do { _ = try partial.finish(exitCode: 0, signalled: false); preconditionFailure("Incomplete framing") }
        catch { precondition(error as? CoreRuntimeError == .incompleteStream) }
        print("PASS: Chunk framing, increasing non-contiguous sequence and unknown additive metadata")

        let selection = CoreCaptureSelection(categories: ["macos-finder"], items: ["homebrew-packages": ["git"]], secureIdentities: [])
        let commands: [CoreCommand] = [.capabilities, .bundleInspect(path: "/sample.mbt"), .capturePrepare(selection: nil),
            .capturePrepare(selection: selection), .captureExecute(selection: selection, destination: "/sample.mbt", preparedID: String(repeating: "a", count: 64)),
            .restorePrepare(path: "/sample.mbt", disabledGroups: ["Homebrew"], includeSecure: false),
            .restoreExecute(path: "/sample.mbt", disabledGroups: [], includeSecure: false, preparedID: String(repeating: "b", count: 64)),
            .environmentCompare(generatedDirectory: "/reference", blueprintPath: nil)]
        for command in commands {
            let value = try JSONDecoder().decode(CoreJSON.self, from: CoreRequest(command).encoded()).object!
            precondition(value["protocol_version"] == .integer(1))
            precondition((value["parameters"] != nil) == (command.operation != .capabilities))
        }
        do { _ = try CoreRequest(.capabilities, operationID: "bad id").encoded(); preconditionFailure("Invalid operation ID") }
        catch { precondition(error as? CoreRuntimeError == .invalidRequest) }
        do { _ = try CoreRequest(.bundleInspect(path: String(repeating: "x", count: 5000))).encoded(); preconditionFailure("Request limit") }
        catch { precondition(error as? CoreRuntimeError == .requestTooLarge) }
        let captureRequest = try JSONDecoder().decode(CoreJSON.self, from: CoreRequest(.capturePrepare(selection: nil)).encoded())
        precondition(captureRequest.object?["parameters"]?.object?["selection"] == .null)
        let compareRequest = try JSONDecoder().decode(CoreJSON.self, from: CoreRequest(.environmentCompare(generatedDirectory: "/reference", blueprintPath: nil)).encoded())
        precondition(compareRequest.object?["parameters"]?.object?["blueprint_path"] == .null)
        let inventory = Data("{\"domain\":\"macos-finder\",\"status\":\"present\",\"selection_mode\":\"category\",\"reason\":null,\"items\":[]}".utf8)
        let row = try JSONDecoder().decode(CoreCaptureInventoryRow.self, from: inventory)
        precondition(row.selectionMode == "category")
        print("PASS: All request shapes, explicit nulls and Core selection_mode metadata")

        let resources = directory.appendingPathComponent("resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: false)
        let unresolved = CoreRuntime(resolver: CoreLocationResolver(resources: resources))
        // No resource descriptor exists for this test executable; Release must fail honestly.
        unresolved.start(CoreRequest(.capabilities))
        await unresolved.waitForCompletion()
        precondition(unresolved.state == .failed && unresolved.capabilities == nil)
        precondition(unresolved.events.isEmpty && unresolved.error == .runtimeUnavailable)
        let plist: [String: Any] = ["Version": 1, "Mode": "bundled", "CorePath": "../escape", "PythonPath": "python3"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: resources.appendingPathComponent("CoreRuntime.plist"))
        do { _ = try CoreLocationResolver(resources: resources).resolve(); preconditionFailure("Path escape") }
        catch { precondition(error as? CoreRuntimeError == .invalidRuntimeConfiguration) }
        let bundledPlist: [String: Any] = ["Version": 1, "Mode": "bundled", "CorePath": "core", "PythonPath": "python3"]
        try PropertyListSerialization.data(fromPropertyList: bundledPlist, format: .xml, options: 0).write(to: resources.appendingPathComponent("CoreRuntime.plist"))
        let bundled = try CoreLocationResolver(resources: resources).resolve()
        precondition(bundled.kind == .bundledResource && bundled.root.path == resources.appendingPathComponent("core").path)
        let bundledFixture = CoreLocation(root: success.root, python: success.python, temporaryBase: directory, kind: .bundledResource)
        do { try bundledFixture.validate(for: .capturePrepare(selection: nil)); preconditionFailure("Signed resources cannot be a writable workflow root") }
        catch { precondition(error as? CoreRuntimeError == .writableCoreRequired) }
        let environment = success.environment(temporary: directory)
        precondition(environment["HOME"] == directory.path && environment["BLUEPRINT_FILE"] == nil && environment["PYTHONPATH"] == nil)
        performanceTraceEnvironment(success, temporary: directory)
        let secure = CoreCaptureSelection(categories: [], items: [:], secureIdentities: ["fixture"])
        let refused = await run(success, command: .captureExecute(selection: secure, destination: "/sample.mbt", preparedID: String(repeating: "a", count: 64)))
        precondition(refused.error == .secureBridgeUnavailable && refused.events.isEmpty)
        print("PASS: Resolver containment, controlled environment, missing runtime without sample fallback and secure boundary")

        if CommandLine.arguments.count == 3 {
            let live = await run(CoreLocation(root: URL(fileURLWithPath: CommandLine.arguments[1]),
                                             python: URL(fileURLWithPath: CommandLine.arguments[2]), temporaryBase: directory))
            precondition(live.state == .completed && live.capabilities?.protocolVersion == 1)
            precondition(live.capabilities?.operations.contains("environment_compare") == true)
            print("PASS: Production Core capabilities smoke test (no Discovery or Apply)")
        }
    }
}
