import Foundation
import Darwin

@main struct OperationLogTests {
    static func check(_ condition: Bool, file: StaticString = #file, line: UInt = #line) {
        precondition(condition, file: file, line: line)
    }
    static func event(_ sequence: Int, _ type: String, _ data: [String: CoreJSON] = [:], id: String = "fixture") throws -> CoreEvent {
        try CoreEvent(line: JSONEncoder().encode(CoreJSON.object(["protocol_version": .integer(1), "operation_id": .string(id),
            "sequence": .integer(sequence), "type": .string(type), "data": .object(data)])))
    }
    static func outcome(_ terminal: CoreEvent? = nil, exit: Int32? = 0, error: CoreRuntimeError? = nil) -> CoreProcessOutcome {
        CoreProcessOutcome(terminal: terminal, exitCode: exit, signalled: false, error: error, stderr: CoreStderrDiagnostics(), cancellationRequested: false)
    }
    static func terminal() throws -> CoreEvent { try event(3, "completed") }
    static func logPath(_ directory: URL, _ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".jsonl") }
    static func newStore(_ root: URL, _ name: String, limits: OperationLogLimits = OperationLogLimits()) -> OperationLogStore {
        OperationLogStore(directory: root.appendingPathComponent(name), limits: limits)
    }
    static func request(_ operation: CoreCommand = .capturePrepare(selection: nil)) -> CoreRequest { CoreRequest(operation, operationID: "fixture") }
    static func raw(_ record: OperationLogRecord) throws -> Data {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        var data = try encoder.encode(record); data.append(10); return data
    }
    static func append(_ data: Data, to url: URL) throws {
        let file = try FileHandle(forWritingTo: url); defer { try? file.close() }
        try file.seekToEnd(); try file.write(contentsOf: data)
    }
    static func expectFailure(_ work: () async throws -> Void) async {
        do { try await work(); preconditionFailure("Unsafe storage accepted") } catch { }
    }

    static func sanitizerTests() throws {
        var sanitizer = OperationLogSanitizer()
        for reason in ["provider_conflict", "manual_installation_required", "launcher_destination_conflict", "launcher_inspection_failed", "launcher_install_failed", "launcher_verification_failed"] {
            let record = sanitizer.event(try event(1, "operation_record", ["domain": .string("launcher"), "reason": .string(reason)]), at: Date())
            check(record.facts?.codes["reason"] == reason)
        }
        let secret = "fixture-secret-token-user-repository"
        let data: [String: CoreJSON] = ["phase": .string("verification"), "domain": .string("git-repositories"),
            "item_id": .string("/Users/" + secret), "record_id": .string(secret), "code": .string("observation_failed"),
            "reason": .string(secret), "outcome": .string("failure"), "username": .string(secret),
            "stdout": .string(secret), "environment": .object(["TOKEN": .string(secret)]), "unknown": .object(["nested": .string(secret)]),
            "verification": .object(["status": .string("partial"), "verdict": .string("incomplete"), "verified_count": .integer(4),
                "unverified_count": .integer(2), "warning_count": .integer(-1), "details": .object(["status": .string("truncated"),
                    "verification_records": .array([.object(["item_id": .string(secret), "conformity": .string("unverified"),
                        "support": .string("unsupported"), "predicate": .string("identity_pair_matches_package"), "secret": .string(secret)])])])])]
        let projected = sanitizer.event(try event(1, "result", data), at: Date())
        let bytes = try raw(projected)
        let text = String(decoding: bytes, as: UTF8.self)
        check(!text.contains(secret) && !text.contains("/Users/") && !text.contains("TOKEN"))
        check(projected.facts?.codes["code"] == "observation_failed" && projected.facts?.codes["reason"] == nil)
        check(projected.evidence?.contains { $0.counts["verified_count"] == 4 && $0.counts["unverified_count"] == 2 } == true)
        check(projected.omitted == true && sanitizer.verificationStatus == "partial" && sanitizer.detailStatus == "truncated")
        let again = sanitizer.event(try event(2, "result", data), at: Date())
        var other = OperationLogSanitizer()
        let separate = other.event(try event(1, "result", data), at: Date())
        check(projected.facts?.references == again.facts?.references && projected.facts?.references != separate.facts?.references)
        check(sanitizer.event(try event(3, secret, data), at: Date()).client == .eventSkipped)
        let malformed = sanitizer.event(try event(4, "diagnostic_record", ["code": .array([.string(secret)]), "error_count": .string(secret), "ready": .integer(1)]), at: Date())
        check(malformed.omitted == true && malformed.facts?.codes.isEmpty == true && malformed.facts?.counts.isEmpty == true)
        let oversized = sanitizer.event(try event(5, "execution_event", ["item_id": .string(String(repeating: "x", count: 2048))]), at: Date())
        check(oversized.facts?.references.isEmpty == true && oversized.omitted == true)
        let many = sanitizer.event(try event(6, "result", ["verification_records": .array((0..<100).map { _ in .object(["code": .string("operation_failed")]) })]), at: Date())
        check(many.evidence?.count == 20 && many.omitted == true)
        var comparison = OperationLogSanitizer()
        _ = comparison.event(try event(7, "result", ["verification": .object(["status": .string("complete")]), "records": .object(["status": .string("partial")])]), at: Date())
        check(comparison.verificationStatus == "complete" && comparison.detailStatus == "partial")
        print("PASS: closed sanitizer, nested secrets, private aliases, invalid types/values, counts/reasons and bounded evidence")
    }

    static func storageTests(_ root: URL) async throws {
        let store = newStore(root, "private")
        let session = store.begin(request(), coreVersion: "3.4.0")
        session.receive(try event(1, "started"))
        session.receive(try event(2, "result", ["verification": .object(["status": .string("complete"), "details": .object(["status": .string("complete")])])]))
        session.receive(try terminal())
        let status = await session.finish(outcome(try terminal()), error: nil)
        check(status == .complete)
        let value = try await store.read(session.id)
        check(value.records.count == 5 && !value.incomplete)
        check(value.records.last?.terminalValid == true && value.records.last?.verificationStatus == "complete")
        let directoryPermissions = try FileManager.default.attributesOfItem(atPath: store.directory.path)[.posixPermissions] as! NSNumber
        let filePermissions = try FileManager.default.attributesOfItem(atPath: logPath(store.directory, session.id).path)[.posixPermissions] as! NSNumber
        check(directoryPermissions.intValue == 0o700 && filePermissions.intValue == 0o600)
        let bytes = try Data(contentsOf: logPath(store.directory, session.id))
        check(bytes.split(separator: 10).allSatisfy { $0.count + 1 <= 16 * 1024 })
        check(!String(decoding: bytes, as: UTF8.self).contains("fixture")) // Arbitrary request IDs are not persisted.

        let invalid = UUID()
        try FileManager.default.createSymbolicLink(at: logPath(store.directory, invalid), withDestinationURL: logPath(store.directory, session.id))
        await expectFailure { _ = try await store.read(invalid) }
        try FileManager.default.removeItem(at: logPath(store.directory, invalid))
        let hardlink = UUID()
        check(link(logPath(store.directory, session.id).path, logPath(store.directory, hardlink).path) == 0)
        await expectFailure { _ = try await store.read(hardlink) }
        try FileManager.default.removeItem(at: logPath(store.directory, hardlink))
        check(chmod(logPath(store.directory, session.id).path, 0o644) == 0)
        await expectFailure { _ = try await store.read(session.id) }
        check(chmod(logPath(store.directory, session.id).path, 0o600) == 0)
        check(chmod(store.directory.path, 0o755) == 0)
        await expectFailure { _ = try await store.read(session.id) }
        check(chmod(store.directory.path, 0o700) == 0)

        let linkedDirectory = root.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: linkedDirectory, withDestinationURL: store.directory)
        let unsafe = OperationLogStore(directory: linkedDirectory).begin(request(), coreVersion: nil)
        check(await unsafe.finish(outcome(try terminal()), error: nil) == .unavailable)
        let publicDirectory = root.appendingPathComponent("public")
        try FileManager.default.createDirectory(at: publicDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        let publicSession = OperationLogStore(directory: publicDirectory).begin(request(), coreVersion: nil)
        check(await publicSession.finish(outcome(try terminal()), error: nil) == .unavailable)
        let device = open("/dev/null", O_RDONLY); defer { Darwin.close(device) }
        do { try store.checkFile(device); preconditionFailure("Device accepted") } catch { }
        let rootOwned = open("/etc/hosts", O_RDONLY); defer { Darwin.close(rootOwned) }
        do { try store.checkFile(rootOwned); preconditionFailure("Foreign owner accepted") } catch { }
        print("PASS: 0700/0600, symlink/hardlink, foreign owner, non-regular file and public-directory protection")

        let interrupted = store.begin(request(), coreVersion: nil)
        interrupted.receive(try event(1, "started"))
        check(await interrupted.finish(outcome(nil, exit: 9, error: .interrupted), error: .interrupted) == .incomplete)
        let failed = try await store.read(interrupted.id)
        check(failed.records.last?.terminalValid == false && failed.records.last?.runtimeError == "interrupted")
        let writeFailure = store.begin(request(), coreVersion: nil)
        writeFailure.receive(try event(1, "started"))
        _ = try await store.read(writeFailure.id)
        check(chmod(logPath(store.directory, writeFailure.id).path, 0o400) == 0)
        check(await writeFailure.finish(outcome(try terminal()), error: nil) == .unavailable)
        check(chmod(logPath(store.directory, writeFailure.id).path, 0o600) == 0)
        check(try await store.read(writeFailure.id).incomplete)
        print("PASS: missing terminal/transport failure never produces a complete log")
    }

    static func capTests(_ root: URL) async throws {
        var limits = OperationLogLimits(); limits.fileBytes = 8192; limits.recordBytes = 1024; limits.totalBytes = 24 * 1024
        let store = newStore(root, "caps", limits: limits)
        let log = store.begin(request(), coreVersion: nil)
        // Waiting for each read tests disk caps independently of queue overflow.
        for sequence in 1...100 {
            log.receive(try event(sequence, "execution_event", ["state": .string("started"), "domain": .string("homebrew-casks")]))
            _ = try await store.read(log.id)
        }
        check(await log.finish(outcome(try terminal()), error: nil) == .incomplete)
        let value = try await store.read(log.id)
        check(value.records.contains { $0.client == .truncated } && value.records.last?.kind == .finish)
        check(try Data(contentsOf: logPath(store.directory, log.id)).count <= limits.fileBytes)
        check(value.records.allSatisfy { (try! raw($0)).count <= limits.recordBytes })

        var queueLimits = limits; queueLimits.pendingRecords = 0
        let queued = newStore(root, "queue", limits: queueLimits)
        let overflow = queued.begin(request(), coreVersion: nil)
        overflow.receive(try event(1, "started"))
        check(await overflow.finish(outcome(try terminal()), error: nil) == .incomplete)
        let lost = try await queued.read(overflow.id)
        check(lost.records.contains { $0.client == .eventSkipped } && lost.records.last?.droppedEvents == 1)
        print("PASS: file/record caps, explicit truncation, reserved finish and bounded ingress loss")

        var retentionLimits = limits; retentionLimits.operations = 2
        let retention = newStore(root, "retention", limits: retentionLimits)
        let active = retention.begin(request(), coreVersion: nil)
        _ = try await retention.read(active.id)
        let secondStore = OperationLogStore(directory: retention.directory, limits: retentionLimits)
        let activeElsewhere = secondStore.begin(request(), coreVersion: nil)
        _ = try await secondStore.read(activeElsewhere.id)
        let refused = retention.begin(request(), coreVersion: nil)
        check(await refused.finish(outcome(try terminal()), error: nil) == .unavailable)
        check(FileManager.default.fileExists(atPath: logPath(retention.directory, active.id).path))
        _ = await active.finish(outcome(try terminal()), error: nil)
        _ = await activeElsewhere.finish(outcome(try terminal()), error: nil)
        let newest = retention.begin(request(), coreVersion: nil)
        _ = await newest.finish(outcome(try terminal()), error: nil)
        check(try await retention.history().count == 2)

        let expiredStore = OperationLogStore(directory: retention.directory, limits: retentionLimits, now: { Date().addingTimeInterval(31 * 24 * 60 * 60) })
        let foreign = retention.directory.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: foreign)
        check(try await expiredStore.history().isEmpty)
        check(FileManager.default.fileExists(atPath: foreign.path))

        var totalLimits = limits; totalLimits.totalBytes = 5000
        let total = newStore(root, "total", limits: totalLimits)
        for _ in 0..<10 {
            let next = total.begin(request(), coreVersion: nil)
            for sequence in 1...5 { next.receive(try event(sequence, "started")); _ = try await total.read(next.id) }
            _ = await next.finish(outcome(try terminal()), error: nil)
        }
        let histories = try await total.history()
        let totalBytes = try histories.reduce(0) { try $0 + Data(contentsOf: logPath(total.directory, $1.id)).count }
        check(totalBytes <= totalLimits.totalBytes && histories.count < 10)
        print("PASS: retention, count/total caps, foreign-file preservation and cross-instance active protection")
    }

    static func crashTests(_ root: URL) async throws {
        let store = newStore(root, "crash")
        var session: OperationLogSession? = store.begin(request(), coreVersion: nil)
        let id = session!.id
        session!.receive(try event(1, "started"))
        let partial = try await store.read(id)
        check(partial.records.count == 2 && partial.incomplete)
        session = nil // No implicit finish on teardown/crash.
        try append(Data("{\"kind\":\"event\"".utf8), to: logPath(store.directory, id))
        let reopened = OperationLogStore(directory: store.directory)
        let value = try await reopened.read(id)
        check(value.damaged && value.incomplete && value.records.count == 2)
        let history = try await reopened.history()
        check(history.count == 1 && history[0].finish == nil && history[0].incomplete)
        let malformedSession = reopened.begin(request(), coreVersion: nil)
        _ = await malformedSession.finish(outcome(try terminal()), error: nil)
        try append(Data("{\"secret\":\"fixture-secret\"}\n".utf8), to: logPath(store.directory, malformedSession.id))
        let malformed = try await reopened.read(malformedSession.id)
        check(malformed.damaged && malformed.incomplete && malformed.records.last?.kind == .finish)
        print("PASS: progressive append, abandoned operation, crash-tail, malformed trailing records and restart history")
    }

    static func fixture(_ root: URL, body: String) throws -> CoreLocation {
        let core = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: core.appendingPathComponent("modules/core/application-interface"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: core.appendingPathComponent("config"), withIntermediateDirectories: true)
        for name in ["modules/core/application-interface/core.py", "config/toolkit.conf", "bootstrap.sh"] { try Data().write(to: core.appendingPathComponent(name)) }
        try body.write(to: core.appendingPathComponent("modules/core/application-interface/core.sh"), atomically: false, encoding: .utf8)
        let python = core.appendingPathComponent("python3")
        try "#!/bin/sh\nexit 0\n".write(to: python, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: python.path)
        return CoreLocation(root: core, python: python, home: root, temporaryBase: root)
    }
    @MainActor static func runtimeTests(_ root: URL) async throws {
        let store = newStore(root, "runtime")
        let commands: [CoreCommand] = [.capturePrepare(selection: nil),
            .captureExecute(selection: CoreCaptureSelection(categories: [], items: [:], secureIdentities: []), destination: "/private/destination", preparedID: "fixture"),
            .bundleInspect(path: "/private/input"), .restorePrepare(path: "/private/input", disabledGroups: [], includeSecure: false),
            .restoreExecute(path: "/private/input", disabledGroups: [], includeSecure: false, preparedID: "fixture"),
            .environmentCompareBundle(path: "/private/input")]
        for command in commands {
            let request = CoreRequest(command)
            var lines = [try event(1, "started", id: request.operationID)]
            for sequence in 2...301 { lines.append(try event(sequence, "execution_event", ["state": .string("started")], id: request.operationID)) }
            lines.append(try event(302, "result", ["publication_occurred": .bool(true), "verification": .object(["status": .string("partial")])], id: request.operationID))
            lines.append(try event(303, "completed", id: request.operationID))
            let text = lines.map { String(data: try! JSONEncoder().encode(CoreJSON.object($0.fields)), encoding: .utf8)! }.joined(separator: "\n")
            let location = try fixture(root, body: "#!/bin/bash\n/bin/cat >/dev/null\nprintf 'fixture-secret-stderr' >&2\n/bin/cat <<'EVENTS'\n" + text + "\nEVENTS\n")
            let runtime = CoreRuntime(operationLogs: store)
            runtime.start(request, location: location); await runtime.waitForCompletion()
            check(runtime.state == .completed && runtime.events.count == 256 && runtime.historyTruncated)
            check(runtime.latestResult?.sequence == 302 && runtime.publicationOccurred == true)
            let history = try await runtime.operationLogHistory()
            let saved = try await store.read(history.first { $0.header.operationID?.uuidString == request.operationID }!.id)
            // A burst may hit bounded ingress. Either all events precede ring eviction,
            // or their loss is explicitly recorded; the Core result is unaffected.
            let count = saved.records.filter { $0.kind == .event }.count
            check(count > 0 && (count == 303 || saved.incomplete))
            check(saved.records.contains { $0.kind == .event && $0.sequence == 1 })
            check(!String(decoding: try Data(contentsOf: logPath(store.directory, saved.records[0].storageID!)), as: UTF8.self).contains("fixture-secret"))
            let disabled = CoreRuntime(operationLogs: nil)
            disabled.start(request, location: location); await disabled.waitForCompletion()
            check(disabled.state == runtime.state && disabled.latestResult == runtime.latestResult && disabled.termination?.exitCode == runtime.termination?.exitCode)
        }
        let next = CoreRuntime(operationLogs: OperationLogStore(directory: store.directory))
        check(try await next.operationLogHistory().count == 6 && next.state == .idle && next.events.isEmpty)

        let brokenPath = root.appendingPathComponent("not-a-directory")
        try Data().write(to: brokenPath)
        let brokenStore = OperationLogStore(directory: brokenPath)
        let id = UUID().uuidString
        let lines = [try event(1, "started", id: id), try event(2, "result", id: id), try event(3, "completed", id: id)]
        let text = lines.map { String(data: try! JSONEncoder().encode(CoreJSON.object($0.fields)), encoding: .utf8)! }.joined(separator: "\n")
        let location = try fixture(root, body: "#!/bin/bash\n/bin/cat >/dev/null\n/bin/cat <<'EVENTS'\n" + text + "\nEVENTS\n")
        let failedStoreRuntime = CoreRuntime(operationLogs: brokenStore)
        failedStoreRuntime.start(CoreRequest(.capturePrepare(selection: nil), operationID: id), location: location)
        await failedStoreRuntime.waitForCompletion()
        check(failedStoreRuntime.state == .completed && failedStoreRuntime.operationLogStatus == .unavailable)

        let malformed = CoreRuntime(operationLogs: store)
        malformed.start(CoreRequest(.capturePrepare(selection: nil)), location: try fixture(root, body: "#!/bin/sh\nprintf 'fixture-secret-invalid-output\\n'\n"))
        await malformed.waitForCompletion()
        check(malformed.error == .malformedEvent && malformed.state == .failed && malformed.operationLogStatus == .incomplete)
        let malformedLog = try await store.read((try await store.history())[0].id)
        check(malformedLog.records.last?.runtimeError == "malformed_event" && malformedLog.records.last?.terminalValid == false)
        let missing = CoreRuntime(resolver: CoreLocationResolver(resources: nil), operationLogs: store)
        missing.start(CoreRequest(.restorePrepare(path: "/private/input", disabledGroups: [], includeSecure: false)))
        await missing.waitForCompletion()
        check(missing.error == .runtimeUnavailable && missing.operationLogStatus == .incomplete)
        try await cancellationTests(root, store: store)
        print("PASS: all requested Runtime operations, ring eviction, restart without retry, process-output exclusion and persistence failure independence")
    }
    @MainActor static func cancellationTests(_ root: URL, store: OperationLogStore) async throws {
        let runtime = CoreRuntime(operationLogs: store)
        let capsID = UUID().uuidString
        let caps = [try event(1, "started", id: capsID), try event(2, "result", ["protocol_version": .integer(1), "product_version": .string("3.4.0"),
            "operations": .array([.string("restore_execute")]), "features": .object(["homebrew_graceful_stop": .object(["version": .integer(1)])])], id: capsID), try event(3, "completed", id: capsID)]
        func encoded(_ value: CoreEvent) -> String { String(data: try! JSONEncoder().encode(CoreJSON.object(value.fields)), encoding: .utf8)! }
        let capsBody = "#!/bin/bash\n/bin/cat >/dev/null\n/bin/cat <<'EVENTS'\n" + caps.map(encoded).joined(separator: "\n") + "\nEVENTS\n"
        runtime.start(CoreRequest(.capabilities, operationID: capsID), location: try fixture(root, body: capsBody))
        await runtime.waitForCompletion()
        check(runtime.homebrewGracefulSupported && runtime.operationLogStatus == .inactive)
        let id = UUID().uuidString
        let started = encoded(try event(1, "started", id: id))
        let accepted = encoded(try event(2, "execution_event", ["state": .string("graceful_stop_accepted"), "domain": .string("orchestration")], id: id))
        let stopped = encoded(try event(3, "failed", ["code": .string("cancelled"), "unknown_consequences": .bool(false)], id: id))
        let body = "#!/bin/bash\n/bin/cat >/dev/null\nprintf '%s\\n' '" + started + "'\nIFS= read -r -n 1 control <&3\n[[ $control == S ]] || exit 2\nprintf '%s\\n' '" + accepted + "' '" + stopped + "'\nexit 130\n"
        runtime.start(CoreRequest(.restoreExecute(path: "/private/input", disabledGroups: [], includeSecure: false, preparedID: "fixture"), operationID: id), location: try fixture(root, body: body))
        let deadline = Date().addingTimeInterval(5)
        while runtime.events.isEmpty && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        check(runtime.state == .running)
        runtime.requestGracefulStop(); await runtime.waitForCompletion()
        check(runtime.state == .cancelled && runtime.termination?.exitCode == 130)
        let gracefulHistory = try await store.history()
        let graceful = try await store.read(gracefulHistory.first { $0.header.operationID?.uuidString == id }!.id)
        check(graceful.records[0].coreVersion == "3.4.0")
        check(graceful.records.contains { $0.client == .gracefulStopDelivered && $0.sequence == nil })
        check(graceful.records.contains { $0.facts?.codes["state"] == "graceful_stop_accepted" })
        check(graceful.records.last?.terminalValid == true && graceful.records.last?.runtimeError == nil)

        let forceID = UUID().uuidString
        let forceStarted = encoded(try event(1, "started", id: forceID))
        let forceBody = "#!/bin/bash\n/bin/cat >/dev/null\ntrap '' TERM\nprintf '%s\\n' '" + forceStarted + "'\nwhile true; do /bin/sleep 0.05; done\n"
        runtime.start(CoreRequest(.capturePrepare(selection: nil), operationID: forceID), location: try fixture(root, body: forceBody))
        while runtime.events.isEmpty && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        check(runtime.state == .running)
        runtime.cancel(); await runtime.waitForCompletion()
        check(runtime.error == .interrupted && runtime.termination?.signalled == true)
        let forceHistory = try await store.history()
        let force = try await store.read(forceHistory.first { $0.header.operationID?.uuidString == forceID }!.id)
        check(force.records.contains { $0.client == .forceStopRequested && $0.sequence == nil })
        check(force.records.last?.terminalValid == false && force.records.last?.signalNumber == SIGKILL && force.incomplete)
        print("PASS: capability/Core version, confirmed Graceful delivery/acceptance and Force Stop interruption without fabricated sequences")
    }
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("macseed-operation-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        try sanitizerTests()
        try await storageTests(root)
        try await capTests(root)
        try await crashTests(root)
        try await runtimeTests(root)
    }
}
