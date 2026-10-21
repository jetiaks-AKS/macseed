import Foundation
import AppKit
import SwiftUI

private actor ReportReadGate {
    var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    func pause() async { started = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

@main struct DiagnosticReportTests {
    static func check(_ value: Bool, file: StaticString = #file, line: UInt = #line) { precondition(value, file: file, line: line) }
    static func checkBackground() { check(!Thread.isMainThread) }
    static let environment = DiagnosticReportEnvironment(version: "3.4.0", build: "16", macOS: OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 1), architecture: "arm64")
    static let time = Date(timeIntervalSince1970: 1_700_000_000)
    static func header(_ id: UUID, operation: CoreOperation = .restoreExecute) -> OperationLogRecord {
        var record = OperationLogRecord(.header, time: time)
        record.storageID = id; record.operationID = UUID(); record.operation = operation
        record.desktopVersion = "3.4.0"; record.desktopBuild = "16"; record.coreVersion = "3.4.0"
        return record
    }
    static func event(_ sequence: Int, _ type: String = "execution_event", _ facts: OperationLogFacts = OperationLogFacts()) -> OperationLogRecord {
        var record = OperationLogRecord(.event, time: time.addingTimeInterval(Double(sequence)))
        record.sequence = sequence; record.eventType = type; record.facts = facts; return record
    }
    static func finish(_ type: String = "completed", verification: String? = "complete", details: String? = "complete") -> OperationLogRecord {
        var record = OperationLogRecord(.finish, time: time.addingTimeInterval(5000))
        record.eventType = type; record.terminalValid = true; record.incomplete = false
        record.exitCode = type == "failed" ? 2 : 0; record.signalled = false
        record.verificationStatus = verification; record.detailStatus = details; return record
    }
    static func makeReport(_ records: [OperationLogRecord], id: UUID, active: Bool = false) -> DiagnosticReportSnapshot {
        var builder = DiagnosticReportBuilder(id: id, environment: environment, date: time)
        builder.active = active; records.forEach { builder.receive($0) }; return builder.snapshot()
    }
    static func contractChecks() {
        let id = UUID()
        let verification = event(2, "result", OperationLogFacts(codes: ["section": "verification", "status": "complete", "verdict": "selected_requirements_not_verified"], counts: ["verified_count": 4, "mismatch_count": 1, "warning_count": 0]))
        var failure = finish("failed"); failure.runtimeError = "bootstrap_failed"; failure.incomplete = true
        let publication = event(1, "operation_record", OperationLogFacts(codes: ["state": "failed", "reason": "privileged_lifecycle_unknown"], flags: ["publication_occurred": true, "target_mutation_may_have_started": true, "unknown_consequences": true]))
        let failed = makeReport([header(id), publication, verification, failure], id: id).text
        check(failed.contains("Operation: Restore / Execute") && failed.contains("Process Result: Failed"))
        check(failed.contains("Exit code: 2") && failed.contains("Reason: bootstrap_failed"))
        check(failed.contains("Verification status: complete") && failed.contains("Log completeness: Incomplete"))
        check(failed.contains("Verification verdict: selected_requirements_not_verified") && failed.contains("Verification mismatch_count: 1"))
        check(failed.contains("unknown_consequences: true") && failed.contains("publication_occurred: true"))
        let success = makeReport([header(id, operation: .captureExecute), finish()], id: id).text
        check(success.contains("Process Result: Completed") && success.contains("Log completeness: Complete"))
        let notRun = makeReport([header(id, operation: .bundleInspect), finish(verification: "not_run", details: nil)], id: id).text
        check(notRun.contains("Verification status: not_run") && notRun.contains("Verification details completeness: Unknown"))
        check(!notRun.contains("verified_count:") && !notRun.contains("Execution error_count:"))
        var marker = OperationLogRecord(.client, time: time); marker.client = .truncated
        let partial = makeReport([header(id), marker, finish(verification: "partial", details: "truncated")], id: id).text
        check(partial.contains("Process Result: Completed") && partial.contains("Verification status: partial"))
        check(partial.contains("Log truncation: Truncated") && partial.contains("Log completeness: Incomplete"))
        let missing = makeReport([header(id)], id: id).text
        check(missing.contains("Process Result: Unknown") && missing.contains("No finish record"))
        check(makeReport([header(id)], id: id, active: true).text.contains("Process Result: Running"))
        for client in [OperationLogClient.gracefulStopDelivered, .gracefulStopDeliveryFailed, .forceStopRequested] {
            var record = OperationLogRecord(.client, time: time); record.client = client
            let report = makeReport([header(id), record], id: id).text
            check(report.contains("client " + client.rawValue) && !report.contains("Core #"))
        }
        var invalid = finish(); invalid.terminalValid = false
        check(makeReport([header(id), invalid], id: id).text.contains("Process Result: Unknown"))
        invalid.runtimeError = "incomplete_stream"
        let transport = makeReport([header(id), invalid], id: id).text
        check(transport.contains("Reason: incomplete_stream") && transport.contains("Verification status: complete") && transport.contains("Log completeness: Incomplete"))
        var terminal = event(3, "failed", OperationLogFacts(codes: ["reason": "bootstrap_failed"]))
        terminal.evidence = [OperationLogFacts(codes: ["section": "verification", "reason": "confirmed_mismatch"])]
        let processReason = makeReport([header(id), terminal, finish("failed")], id: id).text
        check(processReason.contains("Reason: bootstrap_failed") && !processReason.contains("Reason: confirmed_mismatch"))
        print("PASS: success / Failed Restore, independent process / Verification / log state, absent counters, partial/truncated, stop evidence and invalid terminal")
    }
    static func privacyChecks() {
        for reason in ["provider_conflict", "manual_installation_required", "launcher_destination_conflict", "launcher_inspection_failed", "launcher_install_failed", "launcher_verification_failed"] {
            let id = UUID()
            let report = makeReport([header(id), event(1, "operation_record", OperationLogFacts(codes: ["reason": reason])), finish()], id: id)
            check(report.text.contains(reason))
        }
        let id = UUID(), secret = "PRIVATE_TOKEN_abc123", path = "/Users/private-person/private-repo/key.pem"
        var h = header(id); h.desktopVersion = secret; h.desktopBuild = path; h.coreVersion = "version " + secret
        var record = event(1, "diagnostic_record", OperationLogFacts(codes: ["severity": "warning", "code": "observation_failed", "phase": path, "stdout": secret, "user": "private-person", "reason": "token_shaped_private_value"], counts: ["verified_count": 2, "error_count": -1, "warning_count": 1_000_000_001, "secret": 1337], flags: ["publication_occurred": true, "environment": true], references: ["item_id": "anon-012345678901234567890123", "token": secret]))
        record.evidence = [OperationLogFacts(codes: ["section": "verification", "verdict": secret, "message": path, "support": "unsupported"], counts: ["unsupported_count": 3], references: ["record_id": secret])]
        var f = finish(); f.runtimeError = secret; f.verificationStatus = path; f.detailStatus = secret
        let hostile = DiagnosticReportEnvironment(version: secret, build: path, macOS: environment.macOS, architecture: secret)
        var builder = DiagnosticReportBuilder(id: id, environment: hostile, date: time)
        [h, record, event(2, secret), f].forEach { builder.receive($0) }
        let text = builder.snapshot().text
        for privateValue in [secret, path, "private-person", "private-repo", "token_shaped_private_value", "anon-012345678901234567890123", "1337"] { check(!text.contains(privateValue)) }
        check(text.contains("code=observation_failed") && text.contains("support=unsupported") && text.contains("unsupported_count=3"))
        check(!text.contains("error_count=-1") && !text.contains("warning_count=1000000001"))
        check(text.contains("Privacy projection:") && text.contains("App version (report host): Unknown"))
        print("PASS: independent allowlist rejects private top-level/nested fields, aliases, arbitrary codes, secrets, paths, invalid counts and versions")
    }
    static func write(_ records: [OperationLogRecord], to url: URL) throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        var bytes = Data()
        for record in records { bytes.append(try encoder.encode(record)); bytes.append(10) }
        try bytes.write(to: url); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    @MainActor static func storeAndSnapshotChecks() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/macseed-report-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID(), url = root.appendingPathComponent(id.uuidString + ".jsonl")
        try write([header(id, operation: .environmentCompare), event(1, "started")], to: url)
        let store = OperationLogStore(directory: root)
        let model = DiagnosticReportModel(id: id, store: store, environment: environment)
        await model.refresh()
        let original = model.snapshot!
        check(original.operationID == id && original.text.contains("Log completeness: Incomplete"))
        let pasteboard = NSPasteboard.withUniqueName(); defer { pasteboard.releaseGlobally() }
        check(model.copy(to: pasteboard) && pasteboard.data(forType: .string) == original.utf8)
        check(Data(original.text.utf8) == original.utf8)
        let exported = root.appendingPathComponent("report.txt")
        await model.save(to: exported)
        check(try Data(contentsOf: exported) == original.utf8 && !model.saveFailed)
        await model.save(to: nil)
        check(try Data(contentsOf: exported) == original.utf8)
        await model.save(to: root.appendingPathComponent("missing-parent/report.txt"))
        check(model.saveFailed && model.snapshot!.utf8 == original.utf8)
        try write([header(id, operation: .environmentCompare), event(1, "started"), event(2, "completed"), finish()], to: url)
        try await Task.sleep(for: .milliseconds(50))
        check(model.snapshot!.utf8 == original.utf8)
        await model.refresh()
        check(model.snapshot!.utf8 != original.utf8 && model.snapshot!.text.contains("Process Result: Completed"))
        check(model.snapshot!.operationID == id)
        await model.save(to: exported); check(try Data(contentsOf: exported) == model.snapshot!.utf8)
        // Valid prefix + torn final record, no accidental successful finish.
        try write([header(id), event(1, "started")], to: url)
        let handle = try FileHandle(forWritingTo: url); try handle.seekToEnd(); try handle.write(contentsOf: Data("{broken".utf8)); try handle.close()
        await model.refresh()
        check(model.snapshot!.text.contains("Log damage: Detected") && model.snapshot!.text.contains("Process Result: Unknown"))
        let unavailable = DiagnosticReportModel(id: UUID(), store: store, environment: environment)
        await unavailable.refresh()
        check(unavailable.snapshot!.text.contains("Log availability: Unavailable"))
        let absentStore = DiagnosticReportModel(id: UUID(), store: nil, environment: environment)
        await absentStore.refresh(); check(absentStore.snapshot!.text.contains("Log availability: Unavailable"))
        model.close(); unavailable.close(); absentStore.close()
        print("PASS: existing paged store, immutable snapshot until explicit refresh, exact preview/copy/save bytes, cancelled save, write failure, crash tail and unavailable store")
    }
    @MainActor static func performanceAndLifecycleChecks() async throws {
        let id = UUID(), gate = ReportReadGate()
        var cursor = OperationLogCursor(); cursor.offset = 100
        let page = OperationLogPage(header: nil, records: [header(id), finish()], cursor: cursor, atEnd: true, damaged: false, active: false, bytesRead: 100)
        let delayed = DiagnosticReportModel(id: id, store: nil, environment: environment, read: { _, _ in
            checkBackground()
            await gate.pause(); return page
        })
        let open = Task { await delayed.refresh() }
        while !(await gate.started) { await Task.yield() }
        check(delayed.loading && delayed.snapshot == nil)
        delayed.close(); await gate.release(); await open.value
        check(delayed.snapshot == nil && !delayed.loading)
        // Bounded full-log streaming, even after the exported chronology fills.
        let count = 6000
        let model = DiagnosticReportModel(id: id, store: nil, environment: environment, read: { _, previous in
            checkBackground()
            let start = Int(previous?.offset ?? 0), end = min(count, start + 128)
            var records: [OperationLogRecord] = start == 0 ? [header(id)] : []
            for sequence in (start + 1)...end {
                records.append(event(sequence, "operation_record", OperationLogFacts(codes: ["phase": "comparison", "state": "completed"], counts: ["selected_count": 1])))
            }
            if end == count { records.append(finish()) }
            var next = OperationLogCursor(); next.offset = Int64(end)
            return OperationLogPage(header: nil, records: records, cursor: next, atEnd: end == count, damaged: false, active: false, bytesRead: 64 * 1024)
        })
        var heartbeats = 0
        let loading = Task { await model.refresh() }
        while model.snapshot == nil { heartbeats += 1; try await Task.sleep(for: .milliseconds(1)) }
        await loading.value
        check(heartbeats > 1 && model.snapshot!.utf8.count <= DiagnosticReportBuilder.maximumBytes)
        check(model.snapshot!.text.contains("Report chronology capped:") && model.snapshot!.text.contains("Process Result: Completed"))
        // Render actual TextKit preview with the capped large report.
        let host = NSHostingView(rootView: DiagnosticReportText(utf8: model.snapshot!.utf8))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.close(); model.close() }
        for _ in 0..<10 { host.layoutSubtreeIfNeeded(); host.displayIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
        func findText(_ view: NSView) -> NSTextView? { (view as? NSTextView) ?? view.subviews.compactMap { findText($0) }.first }
        let text = findText(host)!
        check(Data(text.string.utf8) == model.snapshot!.utf8 && !text.isEditable && text.isSelectable)
        text.scrollRangeToVisible(NSRange(location: (text.string as NSString).length - 1, length: 0))
        check(text.font?.fontName.contains("Mono") == true || text.font?.isFixedPitch == true)
        print("PASS: off-MainActor paged generation, responsive MainActor heartbeats, bounded 6000-record report, terminal summary retained, native TextKit preview and close-during-load cancellation")
    }
    @MainActor static func main() {
        setbuf(stdout, nil)
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        Task { @MainActor in
            do {
                contractChecks(); privacyChecks(); try await storeAndSnapshotChecks(); try await performanceAndLifecycleChecks()
                print("PASS: DiagnosticReportTests"); exit(0)
            } catch { print("FAIL: DiagnosticReportTests: \(type(of: error))"); exit(1) }
        }
        app.run()
    }
}
