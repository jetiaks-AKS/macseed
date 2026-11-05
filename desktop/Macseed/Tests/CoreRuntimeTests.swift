import Foundation
import Darwin

private final class SecureTestBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func read() -> Value { lock.lock(); defer { lock.unlock() }; return value }
    func update(_ action: (inout Value) -> Void) { lock.lock(); defer { lock.unlock() }; action(&value) }
}

private final class SecureTestClock: @unchecked Sendable {
    private let values = SecureTestBox((time: ProcessInfo.processInfo.systemUptime, tick: 0.0))
    func now() -> TimeInterval {
        var result = 0.0
        values.update { result = $0.time; $0.time += $0.tick }
        return result
    }
    func expire() { values.update { $0.time += 121 } }
    func ticking() { values.update { $0.tick = 31 } }
}

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
        if CommandLine.arguments.contains("--secure-transport-only") || CommandLine.arguments.contains("--secure-context-only") {
            precondition(CommandLine.arguments.count == 4, "Pass repository and Python runtime before --secure-transport-only")
            try await secureTransportTests(directory, repository: URL(fileURLWithPath: CommandLine.arguments[1]),
                                           python: URL(fileURLWithPath: CommandLine.arguments[2]))
            return
        }
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
        // Capture now supplies the native bridge; Restore remains unintegrated.
        let refused = await run(success, command: .restoreExecute(path: "/sample.mbt", disabledGroups: [], includeSecure: true,
                                                               preparedID: String(repeating: "a", count: 64)))
        precondition(refused.error == .secureBridgeUnavailable && refused.events.isEmpty)
        print("PASS: Resolver containment, controlled environment, missing runtime without sample fallback and secure boundary")

        if CommandLine.arguments.count == 3 {
            try await secureTransportTests(directory, repository: URL(fileURLWithPath: CommandLine.arguments[1]),
                                           python: URL(fileURLWithPath: CommandLine.arguments[2]))
            let live = await run(CoreLocation(root: URL(fileURLWithPath: CommandLine.arguments[1]),
                                             python: URL(fileURLWithPath: CommandLine.arguments[2]), temporaryBase: directory))
            precondition(live.state == .completed && live.capabilities?.protocolVersion == 1)
            precondition(live.capabilities?.operations.contains("environment_compare") == true)
            print("PASS: Production Core capabilities smoke test (no Discovery or Apply)")
        }
    }

    static func secureFixture(_ directory: URL, repository: URL, python: URL, scenario: String) throws -> CoreLocation {
        let base = try fixture(directory, body: "")
        let adapter = "modules/core/application-interface/"
        let launcher = try Data(contentsOf: repository.appendingPathComponent(adapter + "core.sh"))
        try launcher.write(to: base.launcher)
        try "TOOLKIT_VERSION=fixture\n".write(to: base.root.appendingPathComponent("config/toolkit.conf"), atomically: false, encoding: .utf8)
        for name in ["secret_input.py", "age_runtime.py"] {
            try Data(contentsOf: repository.appendingPathComponent("modules/migration/" + name))
                .write(to: base.root.appendingPathComponent(adapter + name))
        }
        // Production launcher + production Python framing/response validator. Only the
        // Core challenge producer is injected; no migration/key tools are invoked.
        try #"""
        import json,os,signal,socket,struct,subprocess,sys,time,traceback
        from pathlib import Path
        def safe_failure(kind,value,tb):
            Path('fixture-failure').write_text(kind.__name__+':'+','.join(str(frame.lineno) for frame in traceback.extract_tb(tb)))
        sys.excepthook=safe_failure
        signal.alarm(12)
        mode = "\#(scenario)"
        request=json.load(sys.stdin)
        sequence=0
        def event(kind,data=None):
            global sequence
            sequence+=1
            value=dict(protocol_version=1,operation_id=request['operation_id'],sequence=sequence,type=kind)
            if data is not None: value['data']=data
            print(json.dumps(value),flush=True)
        event('started')
        if mode=='ordinary':
            assert sys.argv[2:]==[]
            assert 'MACSEED_GRACEFUL_FD' not in os.environ
            event('result',{});event('completed');sys.exit(0)
        assert sys.argv[2:]==['--secure-fd','4']
        restore=request['operation']=='restore_execute'
        allowed={4}
        if restore:
            assert os.environ['MACSEED_GRACEFUL_FD']=='3';allowed.add(3)
        else: assert 'MACSEED_GRACEFUL_FD' not in os.environ
        for fd in range(3,128):
            try: os.fstat(fd)
            except OSError: continue
            if fd not in allowed:
                event('fixture_descriptor',{'fd':fd,'mode':os.fstat(fd).st_mode})
            assert fd in allowed, 'unexpected inherited descriptor'
        # uuid (also imported by Core) can open its own /dev/urandom descriptor.
        # Inspect inherited authority before importing that module.
        from secret_input import inherited_socket,metadata,receive,response,SecureError
        import uuid
        channel=inherited_socket(int(sys.argv[3]))
        assert channel.family==socket.AF_UNIX and channel.type==socket.SOCK_STREAM
        assert not channel.getsockname() and not channel.getpeername()
        subprocess.run([sys.executable,'-B','-c',
            'import os\nfor fd in (3,4):\n try: os.fstat(fd)\n except OSError: continue\n raise SystemExit(1)'],check=True)
        phase='secure_import' if restore else 'secure_packaging'
        event('phase_started',{'phase':phase})
        def challenge(kind=None,attempt=1):
            kind=kind or ('bundle_unlock' if restore else 'bundle_encrypt')
            value=dict(type='challenge',protocol_version=2 if kind=='ssh_key_unlock' else 1,operation_id=request['operation_id'],
                       challenge_id=uuid.uuid4().hex,kind=kind,attempt=attempt)
            if kind=='ssh_key_unlock': value['identity']=dict(name='fixture_identity',key_type='ssh-ed25519',fingerprint='SHA256:'+'A'*43,position=1,total=2)
            return value
        def exchange(value,fragment=False):
            if fragment:
                payload=json.dumps(value,separators=(',',':')).encode('ascii')
                raw=struct.pack('!I',len(payload))+payload
                for offset in range(0,len(raw),3):
                    channel.sendall(raw[offset:offset+3]);time.sleep(.001)
            else: metadata(channel,value)
            raw=receive(channel,time.monotonic()+10)
            try: secret=response(raw,value)
            except SecureError as error:
                assert error.code=='secure_cancelled'
                event('failed',{'code':'secure_cancelled'});channel.close();sys.exit(130)
            if value['kind']=='import_confirmation': assert secret==b''
            else:
                assert secret and len(secret)<=128
                assert secret.decode() not in str(sys.argv) and secret.decode() not in str(dict(os.environ))
            return value
        if mode in ('capture','restore','close_before_event','graceful_force','stale_reply','replayed_nonce','duplicate_reply','cancel','invalid_response','timeout','force_pending','late_after_completion','exit_mismatch','secret_confirmation','trailing_challenge'):
            if mode=='capture':
                for attempt in (1,2,3): exchange(challenge('ssh_key_unlock',attempt))
            first=exchange(challenge(),fragment=mode in ('capture','restore'))
            if mode=='replayed_nonce': exchange(first)
            if mode=='stale_reply': exchange(challenge('ssh_key_unlock'))
            if mode in ('restore','secret_confirmation'):
                exchange(challenge('ssh_key_unlock'));exchange(challenge('import_confirmation'))
            if mode=='graceful_force':
                assert os.read(3,1)==b'S'
                signal.signal(signal.SIGTERM,signal.SIG_IGN)
                event('execution_event',{'state':'graceful_received'})
                time.sleep(10)
            if mode=='close_before_event': channel.close();time.sleep(.05)
            event('phase_completed',{'phase':phase})
            if mode=='trailing_challenge': metadata(channel,challenge())
            if mode!='close_before_event': channel.close()
            time.sleep(.03) # Core's remaining ordinary work can outlive the secret endpoint.
            event('result',{});event('completed');sys.exit(2 if mode=='exit_mismatch' else 0)
        value=challenge('ssh_key_unlock') if mode.startswith('context_') else challenge()
        if mode=='context_retry_changed':
            exchange(value);value=challenge('ssh_key_unlock',2);value['identity']['name']='another_identity'
        if mode=='context_missing': del value['identity']
        if mode=='context_version': value['protocol_version']=1
        if mode=='context_name': value['identity']['name']='../invalid'
        if mode=='context_type': value['identity']['key_type']={}
        if mode=='context_fingerprint': value['identity']['fingerprint']='SHA256:invalid'
        if mode=='context_position': value['identity']['position']=3
        if mode=='context_boolean': value['identity']['position']=True
        if mode=='context_extra': value['identity']['unexpected']='redact'
        if mode=='context_bundle': value.update(kind='bundle_encrypt',protocol_version=1)
        if mode=='context_operation': value['operation_id']='forged-operation'
        if mode=='wrong_operation': value['operation_id']='another-operation'
        if mode=='wrong_nonce': value['challenge_id']='bad'
        if mode=='wrong_kind': value['kind']='bundle_unlock'
        if mode=='attempt_zero': value['attempt']=0
        if mode=='attempt_four': value['attempt']=4
        if mode=='attempt_bool': value['attempt']=True
        if mode=='attempt_float': value['attempt']=1.0
        if mode=='version_bool': value['protocol_version']=True
        if mode=='version_float': value['protocol_version']=1.0
        if mode=='extra_field': value['unexpected']='redact'
        if mode=='nested': value['kind']={'value':'bundle_encrypt'}
        payload=json.dumps(value,separators=(',',':')).encode('ascii')
        if mode=='context_duplicate': payload=payload.replace(b'"name":',b'"name":"duplicate","name":')
        if mode=='duplicate_field': payload=payload[:-1]+b',"attempt":1}'
        if mode=='invalid_json': payload=b'no-json'
        if mode=='length_zero': channel.sendall(struct.pack('!I',0))
        elif mode=='length_large': channel.sendall(struct.pack('!I',2049))
        elif mode in ('partial_header','partial_timeout'):
            channel.sendall(b'\x00')
            if mode=='partial_timeout': event('execution_event',{'state':'partial_sent'})
            else: channel.close();sys.exit(2)
        elif mode=='partial_payload':
            channel.sendall(struct.pack('!I',len(payload))+payload[:5]);channel.close();sys.exit(2)
        elif mode=='early_eof':
            channel.close();event('result',{});event('completed');sys.exit(0)
        elif mode=='false_completion':
            event('phase_completed',{'phase':phase});channel.close();event('result',{});event('completed');sys.exit(0)
        else: channel.sendall(struct.pack('!I',len(payload))+payload)
        time.sleep(10)
        """#.write(to: base.root.appendingPathComponent(adapter + "core.py"), atomically: false, encoding: .utf8)
        return CoreLocation(root: base.root, python: python, home: directory, temporaryBase: directory, toolDirectories: [])
    }

    static func secureTransportTests(_ directory: URL, repository: URL, python: URL) async throws {
        typealias Reply = @Sendable (CoreSecureResponse) -> Void
        let secret = Data(("disposable-" + UUID().uuidString).utf8)
        let capture = CoreCommand.captureExecute(selection: CoreCaptureSelection(categories: [], items: [:], secureIdentities: ["fixture"]),
            destination: directory.appendingPathComponent("unused.mbt").path, preparedID: String(repeating: "a", count: 64))
        let restore = CoreCommand.restoreExecute(path: directory.appendingPathComponent("unused.mbt").path,
            disabledGroups: [], includeSecure: true, preparedID: String(repeating: "a", count: 64))
        let logDirectory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("macseed-secure-logs-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: logDirectory) }
        let logStore = OperationLogStore(directory: logDirectory)
        var cases = 0
        func exercise(_ scenario: String, command: CoreCommand? = nil,
                      reply override: CoreSecureResponse? = nil) async throws -> CoreProcessOutcome {
            let location = try secureFixture(directory, repository: repository, python: python, scenario: scenario)
            let request = CoreRequest(command ?? capture)
            let clock = SecureTestClock()
            let transport = CoreTransport(secureClock: { clock.now() })
            let previous = SecureTestBox<Reply?>(nil)
            let observed = SecureTestBox<[CoreSecureChallenge]>([])
            let log = logStore.begin(request, coreVersion: "fixture")
            let events = SecureTestBox<[CoreEvent]>([])
            let result = await transport.run(request: request, location: location, secureChallenge: { challenge, respond in
                observed.update { $0.append(challenge) }
                if scenario == "timeout" { clock.expire(); return }
                if scenario == "force_pending" { transport.cancel(); respond(.secret(secret)); return }
                if scenario == "graceful_force" { precondition(transport.requestGracefulStop()) }
                if scenario == "stale_reply", let old = previous.read() { old(.secret(secret)); return }
                previous.update { $0 = respond }
                respond(override ?? (scenario == "cancel" ? .cancel : (challenge.kind == .importConfirmation && scenario != "secret_confirmation" ? .confirmImport : .secret(secret))))
                if scenario == "duplicate_reply" { respond(.secret(secret)) }
            }) { event in
                events.update { $0.append(event) }
                log.receive(event)
                if event.data?["state"]?.string == "partial_sent" { clock.ticking() }
                if event.data?["state"]?.string == "graceful_received" { transport.cancel() }
            }
            let logStatus = await log.finish(result, error: result.error)
            precondition(logStatus == .complete || logStatus == .incomplete, "Privacy check requires a persisted operation log")
            cases += 1
            if let diagnostic = try? String(contentsOf: location.root.appendingPathComponent("fixture-failure"), encoding: .utf8) {
                let descriptors = events.read().filter { $0.type == "fixture_descriptor" }.map { ($0.data?["fd"]?.integer ?? -1, $0.data?["mode"]?.integer ?? -1) }
                preconditionFailure("Fixture failed (type/lines and descriptor metadata only): \(diagnostic), \(descriptors)")
            }
            if ["capture", "restore", "close_before_event", "late_after_completion"].contains(scenario) {
                precondition(result.error == nil && result.exitCode == 0 && result.terminal?.type == "completed", "Secure success failed: \(scenario), \(String(describing: result.error))")
                precondition(transport.secureState == .completed)
                if scenario == "capture" { precondition(observed.read().map(\.attempt) == [1, 2, 3, 1]) }
                if scenario == "restore" { precondition(observed.read().map(\.kind) == [.bundleUnlock, .sshKeyUnlock, .importConfirmation]) }
                for value in observed.read() where value.kind == .sshKeyUnlock {
                    precondition(value.identity?.name == "fixture_identity" && value.identity?.typeLabel == "Ed25519" && value.identity?.position == 1 && value.identity?.total == 2)
                    precondition(!String(reflecting: value).contains("fixture_identity"))
                }
                if scenario == "late_after_completion" {
                    previous.read()?(.secret(secret))
                    precondition(transport.secureState == .completed)
                }
            } else if scenario == "cancel" {
                precondition(result.error == nil && result.exitCode == 130 && result.terminal?.isCancellation == true)
                precondition(result.cancellationRequested && transport.secureState == .cancelled)
                previous.read()?(.secret(secret))
                precondition(transport.secureState == .cancelled)
            } else if ["graceful_force", "force_pending"].contains(scenario) {
                precondition(result.signalled && result.cancellationRequested && result.error == .interrupted)
                if scenario == "graceful_force" { precondition(result.exitCode == SIGKILL) }
            } else {
                precondition(result.error != nil && result.terminal?.type != "completed", "Accepted invalid secure case: \(scenario)")
                if scenario == "exit_mismatch" {
                    precondition(result.error == .exitMismatch && transport.secureState == .failed(.exitMismatch))
                } else if scenario == "timeout" || scenario == "partial_timeout" { precondition(result.error == .secureChannelTimeout) }
                else if ["early_eof", "false_completion", "replayed_nonce", "duplicate_reply", "stale_reply", "trailing_challenge"].contains(scenario) {
                    precondition(result.error == .invalidLifecycle, "Wrong lifecycle failure: \(scenario)")
                } else { precondition(result.error == .secureChannelInvalid, "Wrong wire failure: \(scenario), \(String(describing: result.error))") }
            }
            precondition(!events.read().contains { event in
                (try? JSONEncoder().encode(CoreJSON.object(event.fields)).range(of: secret)) != nil
            })
            return result
        }
        if CommandLine.arguments.contains("--secure-context-only") {
            _ = try await exercise("capture")
            _ = try await exercise("restore", command: restore)
            for scenario in ["context_missing", "context_version", "context_name", "context_type", "context_fingerprint", "context_position", "context_boolean", "context_extra", "context_bundle", "context_operation", "context_duplicate", "context_retry_changed", "replayed_nonce", "stale_reply", "late_after_completion", "cancel", "timeout"] {
                _ = try await exercise(scenario)
            }
            for file in try FileManager.default.contentsOfDirectory(at: logDirectory, includingPropertiesForKeys: nil) where file.pathExtension == "jsonl" {
                let raw = try Data(contentsOf: file)
                for value in [secret, Data("fixture_identity".utf8), Data(("SHA256:" + String(repeating: "A", count: 43)).utf8)] { precondition(raw.range(of: value) == nil) }
            }
            print("PASS: \(cases) focused secure-context cases: strict v2 identity, retries, forged/invalid metadata, replay/late response, cancellation, timeout and log privacy")
            return
        }
        // Warm the queues/log store before checking descriptor lifetime across all paths.
        _ = try await exercise("capture")
        func descriptors() -> Set<Int32> { Set((0..<256).map(Int32.init).filter { fcntl($0, F_GETFD) != -1 }) }
        let baseline = descriptors()
        // A foreign descriptor must never be inherited, even if it lacks CLOEXEC.
        let foreign = Pipe()
        let expected = descriptors()
        _ = try await exercise("restore", command: restore)
        _ = try await exercise("close_before_event")
        _ = try await exercise("late_after_completion")
        for scenario in ["wrong_operation", "wrong_nonce", "wrong_kind", "attempt_zero", "attempt_four", "attempt_bool", "attempt_float",
                         "version_bool", "version_float", "extra_field", "nested", "duplicate_field", "invalid_json", "length_zero", "length_large",
                         "partial_header", "partial_payload", "early_eof", "false_completion", "replayed_nonce", "duplicate_reply", "stale_reply", "timeout", "partial_timeout"] {
            _ = try await exercise(scenario)
        }
        for reply in [CoreSecureResponse.secret(Data()), .secret(Data(repeating: 65, count: 129)),
                      .secret(Data([0xff])), .secret(Data("invalid\n".utf8)), .confirmImport] {
            _ = try await exercise("invalid_response", reply: reply)
        }
        _ = try await exercise("cancel")
        _ = try await exercise("exit_mismatch")
        _ = try await exercise("secret_confirmation", command: restore)
        _ = try await exercise("trailing_challenge")
        _ = try await exercise("force_pending")
        _ = try await exercise("graceful_force", command: restore)
        precondition(descriptors() == expected, "Secure transport leaked or closed an unrelated descriptor")
        try foreign.fileHandleForReading.close(); try foreign.fileHandleForWriting.close()
        precondition(descriptors() == baseline)

        let ordinary = try secureFixture(directory, repository: repository, python: python, scenario: "ordinary")
        let disabled = await CoreTransport().run(request: CoreRequest(capture), location: ordinary) { _ in preconditionFailure("Secure operation launched without handler") }
        precondition(disabled.error == .secureBridgeUnavailable)
        let unexpected = await CoreTransport().run(request: CoreRequest(.capabilities), location: ordinary,
            secureChallenge: { _, _ in preconditionFailure("Ordinary request delivered secure input") }) { _ in preconditionFailure("Unexpected secure handler launched") }
        precondition(unexpected.error == .invalidRequest)
        let regular = CoreTransport()
        let normal = await regular.run(request: CoreRequest(.capabilities), location: ordinary) { _ in }
        precondition(normal.error == nil && normal.exitCode == 0 && regular.secureState == .idle)
        let reused = await regular.run(request: CoreRequest(capture), location: ordinary, secureChallenge: { _, _ in }) { _ in }
        precondition(reused.error == .invalidLifecycle)
        let beforeLaunch = CoreTransport()
        beforeLaunch.cancel()
        let cancelled = await beforeLaunch.run(request: CoreRequest(capture), location: ordinary, secureChallenge: { _, _ in }) { _ in }
        precondition(cancelled.cancellationRequested && cancelled.terminal == nil)
        precondition(descriptors() == baseline)
        try assertNoPersistedSecret(directory, secret: secret)
        try assertNoPersistedSecret(logDirectory, secret: secret)
        print("PASS: \(cases + 5) focused secure transport scenarios through production spawn/launcher and Core framing")
        print("PASS: Fragmented framing, identity/kind/attempt checks, timeout, EOF, replay/stale input, cancellation and isolated Stop FDs")
        print("PASS: Default-off boundary, descriptor ownership/inheritance, ordinary requests and no secret in JSONL, argv, environment or persisted operation logs")
    }

    static func assertNoPersistedSecret(_ directory: URL, secret: Data) throws {
        for case let url as URL in FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])! {
            if (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true {
                let contents = try Data(contentsOf: url)
                precondition(contents.range(of: secret) == nil, "Secret reached persistent fixture/log data")
            }
        }
    }
}
