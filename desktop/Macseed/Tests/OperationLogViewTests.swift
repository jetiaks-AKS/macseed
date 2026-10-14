import Foundation
import AppKit
import SwiftUI

private actor DelayedLogPage {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var waiting = false
    private var released = false
    func pause() async {
        guard !released else { return }
        waiting = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}

@main struct OperationLogViewTests {
    static func check(_ value: Bool, file: StaticString = #file, line: UInt = #line) { precondition(value, file: file, line: line) }
    static func event(_ sequence: Int, _ type: String, id: String, data: [String: CoreJSON] = [:]) throws -> CoreEvent {
        try CoreEvent(line: JSONEncoder().encode(CoreJSON.object(["protocol_version": .integer(1), "operation_id": .string(id),
            "sequence": .integer(sequence), "type": .string(type), "data": .object(data)])))
    }
    static func outcome(_ terminal: CoreEvent) -> CoreProcessOutcome {
        CoreProcessOutcome(terminal: terminal, exitCode: 0, signalled: false, error: nil, stderr: CoreStderrDiagnostics(), cancellationRequested: false)
    }
    @MainActor static func storeChecks() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/macseed-log-view-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let store = OperationLogStore(directory: root.appendingPathComponent("logs"))
        let request = CoreRequest(.capturePrepare(selection: nil))
        let session = store.begin(request, coreVersion: "3.4.0")
        session.receive(try event(1, "started", id: request.operationID))
        let model = OperationLogViewerModel(store: store, target: session.id)
        await model.refreshHistory(); await model.load()
        check(model.rows.contains { $0.record.sequence == 1 })
        let first = try await store.page(session.id)
        let unchanged = try await store.page(session.id, after: first.cursor)
        check(unchanged.bytesRead == 0 && unchanged.records.isEmpty && unchanged.cursor.offset == first.cursor.offset)
        session.receive(try event(2, "diagnostic_record", id: request.operationID,
            data: ["code": .string("observation_failed"), "severity": .string("warning"), "item_id": .string("private-user-folder")]))
        await model.load()
        check(model.rows.filter { $0.record.sequence == 2 }.count == 1)
        let incremental = try await store.page(session.id, after: first.cursor)
        check(incremental.records.count == 1 && incremental.records[0].sequence == 2 && incremental.bytesRead <= 64 * 1024)
        for batch in 0..<6 {
            for index in 0..<150 {
                let sequence = 3 + batch * 150 + index
                session.receive(try event(sequence, "execution_event", id: request.operationID, data: ["state": .string("started")]))
            }
            await model.load()
        }
        check(model.rows.count <= 512 && model.earlierEvents)
        let terminal = try event(904, "completed", id: request.operationID)
        session.receive(try event(903, "result", id: request.operationID, data: ["verification": .object(["status": .string("partial")])]))
        session.receive(terminal)
        _ = await session.finish(outcome(terminal), error: nil)
        await model.refreshHistory(); await model.load()
        check(model.finish?.terminalValid == true && model.rows.last?.record.kind == .finish)
        check(OperationLogPresentation.verification(model.finish) == "Verification incomplete")
        check(!model.rows.flatMap { OperationLogPresentation.details($0.record) }.joined().contains("private-user-folder"))
        model.select(session.id, fromBeginning: true); await model.load()
        check(model.rows.first?.record.kind == .header && model.hasMore)
        let paused = model.rows.count
        await model.poll(); check(model.rows.count == paused)
        print("PASS: byte-cursor live updates without duplicate/full rereads, bounded pages/window, final events and manual earlier-page browsing")

        // Model an application restart: finish/cancel the old reader before a
        // new Store takes the directory lock. Production shares one Store.
        model.close(); await model.waitForReport()
        let fresh = CoreRuntime(operationLogs: OperationLogStore(directory: store.directory))
        let reopened = OperationLogViewerModel(store: fresh.operationLogStore, target: nil)
        await reopened.refreshHistory(); await reopened.load()
        check(reopened.history.contains { $0.id == session.id } && fresh.state == .idle)
        reopened.close(); await reopened.waitForReport()
        let resumedStore = fresh.operationLogStore!
        let activeRequest = CoreRequest(.environmentCompareBundle(path: "/private/fixture"))
        let active = resumedStore.begin(activeRequest, coreVersion: nil)
        active.receive(try event(1, "started", id: activeRequest.operationID))
        _ = try await resumedStore.page(active.id)
        let foreign = store.directory.appendingPathComponent("foreign.txt")
        try Data("keep".utf8).write(to: foreign)
        await reopened.clear()
        check(reopened.history.map(\.id) == [active.id])
        check(FileManager.default.fileExists(atPath: foreign.path))
        check(try await resumedStore.page(active.id).active)
        let stop = try event(2, "completed", id: activeRequest.operationID)
        active.receive(stop); _ = await active.finish(outcome(stop), error: nil)
        print("PASS: history after a new Runtime, confirmed-store clearing, active lock protection and preservation of foreign files")

        var limits = OperationLogLimits(); limits.fileBytes = 8192; limits.recordBytes = 1024
        let capped = OperationLogStore(directory: root.appendingPathComponent("capped"), limits: limits)
        let cappedRequest = CoreRequest(.restorePrepare(path: "/private/input", disabledGroups: [], includeSecure: false))
        let cappedSession = capped.begin(cappedRequest, coreVersion: nil)
        for sequence in 1...100 { cappedSession.receive(try event(sequence, "execution_event", id: cappedRequest.operationID, data: ["state": .string("started")])) }
        _ = await cappedSession.finish(outcome(try event(101, "completed", id: cappedRequest.operationID)), error: nil)
        let truncated = OperationLogViewerModel(store: capped, target: cappedSession.id)
        await truncated.refreshHistory(); await truncated.load(); await truncated.waitForReport()
        check(truncated.truncated && truncated.incomplete && truncated.report.truncated)
        check(OperationLogPresentation.timeline(truncated.rows, mode: .all).flatMap(\.rows).count == truncated.rows.count)
        check(truncated.rows.filter { $0.record.kind == .event }.count < 100)
        truncated.close()
        let unavailable = OperationLogViewerModel(store: nil, target: UUID())
        await unavailable.refreshHistory(); check(unavailable.unavailable && unavailable.report.unavailable && !unavailable.report.loading)
        let abandonedRequest = CoreRequest(.capturePrepare(selection: nil))
        var abandoned: OperationLogSession? = store.begin(abandonedRequest, coreVersion: nil)
        let abandonedID = abandoned!.id
        abandoned!.receive(try event(1, "started", id: abandonedRequest.operationID)); _ = try await store.page(abandonedID)
        abandoned = nil
        let file = try FileHandle(forWritingTo: store.directory.appendingPathComponent(abandonedID.uuidString + ".jsonl"))
        try file.seekToEnd(); try file.write(contentsOf: Data("{unfinished".utf8)); try file.close()
        let damaged = try await store.page(abandonedID)
        check(damaged.damaged)
        let crashViewer = OperationLogViewerModel(store: store, target: abandonedID)
        await crashViewer.refreshHistory(); await crashViewer.load(); await crashViewer.waitForReport()
        check(crashViewer.report.damaged && crashViewer.finish == nil)
        crashViewer.close()
        print("PASS: truncated/incomplete/unavailable states and inactive crash-tail detection")
        try await runtimeChecks(root, store: store)
    }
    @MainActor static func runtimeChecks(_ root: URL, store: OperationLogStore) async throws {
        let core = root.appendingPathComponent("core")
        try FileManager.default.createDirectory(at: core.appendingPathComponent("modules/core/application-interface"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: core.appendingPathComponent("config"), withIntermediateDirectories: true)
        for name in ["bootstrap.sh", "config/toolkit.conf", "modules/core/application-interface/core.py"] { try Data().write(to: core.appendingPathComponent(name)) }
        let python = core.appendingPathComponent("python3"); try Data("#!/bin/sh\nexit 0\n".utf8).write(to: python)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: python.path)
        let runtime = CoreRuntime(operationLogs: store)
        let location = CoreLocation(root: core, python: python, home: root, temporaryBase: root)
        func encoded(_ value: CoreEvent) -> String { String(data: try! JSONEncoder().encode(CoreJSON.object(value.fields)), encoding: .utf8)! }
        let commands: [CoreCommand] = [.capturePrepare(selection: nil),
            .restoreExecute(path: "/private/input", disabledGroups: [], includeSecure: false, preparedID: String(repeating: "a", count: 64)),
            .environmentCompareBundle(path: "/private/input")]
        for command in commands {
            let request = CoreRequest(command)
            let events = [try event(1, "started", id: request.operationID),
                try event(2, "result", id: request.operationID, data: ["read_only": .bool(true)]), try event(3, "completed", id: request.operationID)]
            let release = root.appendingPathComponent("release-" + request.operationID)
            let body = "#!/bin/bash\n/bin/cat >/dev/null\nfor attempt in {1..500}; do [[ -f '" + release.path + "' ]] && break; /bin/sleep 0.01; done\n[[ -f '" + release.path + "' ]] || exit 2\n/bin/cat <<'EVENTS'\n" + events.map(encoded).joined(separator: "\n") + "\nEVENTS\n"
            try body.write(to: core.appendingPathComponent("modules/core/application-interface/core.sh"), atomically: false, encoding: .utf8)
            runtime.start(request, location: location)
            let viewer = OperationLogViewerModel(store: runtime.operationLogStore, target: runtime.operationLogReference(matching: request.operationID)!.id)
            await viewer.refreshHistory(); await viewer.load()
            check(runtime.isActive)
            viewer.close()
            try Data().write(to: release)
            await runtime.waitForCompletion()
            check(runtime.state == .completed)
            if command.operation == .restoreExecute {
                let result = RestoreExecutionPresentation(runtime: runtime, payload: nil, expectedID: String(repeating: "a", count: 64))
                check(result.operationID == request.operationID)
            }
            let baseline = CoreRuntime(operationLogs: nil)
            baseline.start(request, location: location); await baseline.waitForCompletion()
            check(runtime.state == baseline.state && runtime.latestResult == baseline.latestResult && runtime.termination?.exitCode == baseline.termination?.exitCode)
        }
        // Failure before the first Protocol event still has a persistent request reference.
        try "#!/bin/bash\n/bin/cat >/dev/null\nexit 2\n".write(
            to: core.appendingPathComponent("modules/core/application-interface/core.sh"), atomically: false, encoding: .utf8)
        let earlyFailure = CoreRequest(commands[1])
        runtime.start(earlyFailure, location: location)
        await runtime.waitForCompletion()
        let failedResult = RestoreExecutionPresentation(runtime: runtime, payload: nil, expectedID: String(repeating: "a", count: 64))
        check(failedResult.diagnosticEvents.isEmpty && failedResult.operationID == earlyFailure.operationID)
        let failedReference = runtime.operationLogReference(matching: failedResult.operationID)
        check(OperationLogVisibility.restore(.result, active: runtime.isActive, reference: failedReference, terminal: runtime.termination != nil))
        let caps = CoreRequest(.capabilities)
        let capEvents = [try event(1, "started", id: caps.operationID), try event(2, "result", id: caps.operationID,
            data: ["protocol_version": .integer(1), "product_version": .string("3.4.0"), "operations": .array([.string("restore_execute")]),
                   "features": .object(["homebrew_graceful_stop": .object(["version": .integer(1)])])]), try event(3, "completed", id: caps.operationID)]
        try ("#!/bin/bash\n/bin/cat >/dev/null\n/bin/cat <<'EVENTS'\n" + capEvents.map(encoded).joined(separator: "\n") + "\nEVENTS\n")
            .write(to: core.appendingPathComponent("modules/core/application-interface/core.sh"), atomically: false, encoding: .utf8)
        runtime.start(caps, location: location); await runtime.waitForCompletion()
        let graceful = CoreRequest(commands[1])
        let gracefulEvents = [try event(1, "started", id: graceful.operationID),
            try event(2, "execution_event", id: graceful.operationID, data: ["state": .string("graceful_stop_accepted")]),
            try event(3, "failed", id: graceful.operationID, data: ["code": .string("cancelled")])]
        let gracefulBody = "#!/bin/bash\n/bin/cat >/dev/null\nprintf '%s\\n' '" + encoded(gracefulEvents[0]) +
            "'\nIFS= read -r -n 1 control <&3\n[[ $control == S ]] || exit 2\nprintf '%s\\n' '" + encoded(gracefulEvents[1]) + "' '" + encoded(gracefulEvents[2]) + "'\nexit 130\n"
        try gracefulBody.write(to: core.appendingPathComponent("modules/core/application-interface/core.sh"), atomically: false, encoding: .utf8)
        runtime.start(graceful, location: location)
        while runtime.events.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let gracefulViewer = OperationLogViewerModel(store: store, target: runtime.operationLogReference(matching: graceful.operationID)!.id)
        await gracefulViewer.refreshHistory(); await gracefulViewer.load()
        OperationLogStopRequest(operationID: graceful.operationID, mode: .graceful).perform(on: runtime)
        await runtime.waitForCompletion(); await gracefulViewer.load()
        check(runtime.state == .cancelled && runtime.termination?.exitCode == 130 && gracefulViewer.finish?.terminalValid == true)
        check(OperationLogVisibility.restore(.result, active: runtime.isActive,
            reference: runtime.operationLogReference(matching: graceful.operationID), terminal: runtime.termination != nil))
        print("PASS: Capture/Restore/Status outcomes unchanged and viewer Graceful Stop uses the existing control channel")
        let request = CoreRequest(.capturePrepare(selection: nil))
        let start = try event(1, "started", id: request.operationID)
        let text = String(data: try JSONEncoder().encode(CoreJSON.object(start.fields)), encoding: .utf8)!
        let body = "#!/bin/bash\n/bin/cat >/dev/null\ntrap '' TERM\nprintf '%s\\n' '" + text + "'\nwhile true; do /bin/sleep 0.05; done\n"
        try body.write(to: core.appendingPathComponent("modules/core/application-interface/core.sh"), atomically: false, encoding: .utf8)
        runtime.start(request, location: location)
        let deadline = Date().addingTimeInterval(5)
        while runtime.events.isEmpty && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        check(runtime.state == .running)
        let reference = runtime.operationLogReference(matching: request.operationID)!
        let coordinator = OperationLogWindowController(); coordinator.open(runtime: runtime, target: reference.id)
        let nativeWindow = coordinator.window!
        check(nativeWindow.sheetParent == nil && nativeWindow.styleMask.contains(.resizable))
        check(nativeWindow.styleMask.contains(.closable) && nativeWindow.styleMask.contains(.miniaturizable))
        check(nativeWindow.contentMinSize == NSSize(width: 680, height: 480))
        nativeWindow.setContentSize(NSSize(width: 940, height: 720))
        check(nativeWindow.contentLayoutRect.width >= 940)
        coordinator.open(runtime: runtime, target: UUID())
        check(coordinator.window === nativeWindow)
        coordinator.open(runtime: runtime, target: nil)
        check(coordinator.window === nativeWindow)
        coordinator.open(runtime: runtime, target: reference.id)
        check(coordinator.window === nativeWindow && coordinator.selectedOperationID == reference.id)
        coordinator.close()
        let viewer = OperationLogViewerModel(store: runtime.operationLogStore, target: reference.id)
        await viewer.refreshHistory(); await viewer.load()
        OperationLogStopRequest(operationID: "stale", mode: .force).perform(on: runtime)
        check(!runtime.stopping)
        await viewer.clear(); check(runtime.isActive && !runtime.stopping)
        OperationLogStopRequest(operationID: request.operationID, mode: .force).perform(on: runtime)
        await runtime.waitForCompletion(); await viewer.load()
        check(runtime.error == .interrupted && runtime.termination?.signalled == true)
        check(OperationLogVisibility.capture(.failed, active: runtime.isActive,
            reference: runtime.operationLogReference(matching: request.operationID), terminal: runtime.termination != nil))
        check(coordinator.selectedOperationID == reference.id)
        check(viewer.finish?.terminalValid == false && viewer.incomplete)
        print("PASS: View Log reads/clear leave active Core unchanged; stale Stop rejected and owned Force escalation retained")
    }
    @MainActor static func main() {
        setbuf(stdout, nil)
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        Task { @MainActor in
            do { try await runChecks(); exit(0) }
            catch { print("FAIL: OperationLogViewTests: \(error)"); exit(1) }
        }
        // Exercise SwiftUI within AppKit's actual event loop. dispatchMain from
        // async main is not an equivalent host for native table transactions.
        application.run()
    }
    static func diagnosticReportIntegrationChecks() {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
        let viewer = try! String(contentsOf: sources.appendingPathComponent("OperationLogView.swift"))
        let action = viewer.components(separatedBy: "Button(\"Diagnostic Report\")")[1].components(separatedBy: "Spacer()")[0]
        check(action.contains("DiagnosticReportRequest(id: selectedID)") && action.contains("disabled(selectedID == nil)"))
        check(!action.contains("activeID") && !action.contains("latestOperationLog"))
        check(viewer.contains("DiagnosticReportView(id: request.id, store: runtime.operationLogStore)"))
        let report = try! String(contentsOf: sources.appendingPathComponent("DiagnosticReport.swift"))
        check(report.contains("DiagnosticReportText(utf8: snapshot.utf8)"))
        check(!report.contains("CoreRuntime.shared") && !report.contains("operationLogStore.history"))
        print("PASS: selected operation captured for Diagnostic Report, shared store, immutable UTF-8 preview and no reader/runtime substitution")
    }
    @MainActor static func runChecks() async throws {
        if CommandLine.arguments.contains("--diagnostic-report-only") {
            diagnosticReportIntegrationChecks(); presentationUXChecks(); closeUXChecks()
            try await fullHistoryReportChecks(); try await storeChecks()
            return
        }
        diagnosticReportIntegrationChecks()
        if CommandLine.arguments.contains("--summary-only") { summaryPolishChecks(); return }
        if CommandLine.arguments.contains("--ux-close-only") {
            presentationUXChecks(); closeUXChecks()
            try await fullHistoryReportChecks()
            try await storeChecks()
            return
        }
        if CommandLine.arguments.contains("--switching-only") { try await switchingChecks(); return }
        if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--saved-log-copies" {
            let directory = URL(fileURLWithPath: CommandLine.arguments[2])
            let checkedDirectory = directory.resolvingSymlinksInPath().standardizedFileURL
            let temporaryRoot = URL(fileURLWithPath: "/private/tmp").resolvingSymlinksInPath().standardizedFileURL
            precondition(checkedDirectory.path.hasPrefix(temporaryRoot.path + "/"), "Only disposable private copies may be passed to this test")
            let store = OperationLogStore(directory: directory)
            let history = try await store.history()
            check(!history.isEmpty)
            for entry in history {
                let saved = try await store.read(entry.id)
                let revision = UUID()
                let rows = saved.records.enumerated().map { OperationLogRow(id: .init(operation: entry.id, revision: revision, ordinal: $0.offset), record: $0.element) }
                let visible = Array(rows.suffix(OperationLogViewerModel.visibleLimit))
                for mode in [OperationLogTimelineMode.all] {
                    check(OperationLogPresentation.timeline(rows, mode: mode).flatMap(\.rows).map(\.id) == visible.map(\.id))
                }
                let viewer = OperationLogViewerModel(store: store, target: entry.id)
                await viewer.refreshHistory(); viewer.select(entry.id, fromBeginning: true); await viewer.load(); await viewer.waitForReport()
                check(!viewer.report.loading && !viewer.report.unavailable)
                let summary = OperationLogPresentation.summary(viewer.report.summaries)
                if let finish = entry.finish { check(viewer.report.summaries.contains { $0.kind == .finish && $0.eventType == finish.eventType }) }
                viewer.close()
                if entry.header.operation == .restoreExecute && entry.finish?.runtimeError == "bootstrap_failed" {
                    check(summary.contains("Reason: bootstrap_failed"))
                    check(summary.contains { $0.contains("Verified:") })
                    check(OperationLogPresentation.outcome(entry.finish) == "Failed")
                    check(OperationLogPresentation.verification(entry.finish).hasPrefix("Verification complete"))
                    print("PASS: saved failed Restore keeps bootstrap_failed and completed Verification independent; summary uses persisted counts only")
                }
            }
            try await nativeViewerChecks(store: store, ids: history.map(\.id))
            print("PASS: native viewer on private read-only copies of saved logs")
            return
        }
        try await fullHistoryReportChecks()
        presentationUXChecks(); closeUXChecks(); summaryPolishChecks()
        try await switchingChecks()
        try await largeDetailsChecks()
        var complete = OperationLogRecord(.finish)
        complete.eventType = "completed"; complete.exitCode = 0; complete.terminalValid = true; complete.incomplete = false
        complete.verificationStatus = "partial"; complete.detailStatus = "partial"
        precondition(OperationLogPresentation.outcome(complete) == "Completed")
        precondition(OperationLogPresentation.verification(complete) == "Verification incomplete")
        complete.terminalValid = false; complete.incomplete = true
        precondition(OperationLogPresentation.outcome(complete) == "Interrupted or Unknown")
        precondition(OperationLogPresentation.outcome(nil, active: false) == "Interrupted or Unknown")
        precondition(OperationLogPresentation.outcome(nil, active: true) == "Running")
        complete.terminalValid = true; complete.eventType = "failed"; complete.exitCode = 130; complete.incomplete = false
        precondition(OperationLogPresentation.outcome(complete) == "Stopped")
        complete.exitCode = 2; complete.runtimeError = "privileged_lifecycle_unknown"; complete.verificationStatus = "complete"; complete.detailStatus = "complete"
        precondition(OperationLogPresentation.outcome(complete) == "Failed" && OperationLogPresentation.verification(complete) == "Verification complete")
        print("PASS: independent terminal result and Verification completeness, incomplete/unknown and handled cancellation")

        let secret = "fixture-private-repository-secret"
        var invalid = OperationLogRecord(.event)
        invalid.sequence = 1; invalid.eventType = "diagnostic_record"
        invalid.facts = OperationLogFacts(codes: ["reason": secret])
        precondition(!OperationLogPresentation.details(invalid).joined().contains(secret))
        precondition(OperationLogPresentation.title(invalid) == "Unavailable Event")
        var warning = OperationLogRecord(.event)
        warning.sequence = 2; warning.eventType = "diagnostic_record"
        warning.facts = OperationLogFacts(codes: ["code": "observation_failed", "severity": "warning", "phase": "observation"])
        precondition(OperationLogPresentation.details(warning).contains("code: observation_failed"))
        precondition(OperationLogPresentation.phase("observation") == "Observation")
        var omitted = OperationLogRecord(.client); omitted.client = .truncated; omitted.omitted = true
        precondition(OperationLogPresentation.title(omitted) == "Log Limit Reached")
        precondition(OperationLogPresentation.details(omitted).contains("Some fields or evidence were omitted."))
        print("PASS: validated-only presentation, readable phase/diagnostic codes and explicit truncation")

        let older = UUID(), newer = UUID()
        var oldHeader = OperationLogRecord(.header, time: Date(timeIntervalSince1970: 1))
        oldHeader.storageID = older; oldHeader.operation = .capturePrepare
        var newHeader = OperationLogRecord(.header, time: Date(timeIntervalSince1970: 2))
        newHeader.storageID = newer; newHeader.operation = .restoreExecute
        let history = [OperationLogHistory(id: older, header: oldHeader, finish: nil, incomplete: true),
                       OperationLogHistory(id: newer, header: newHeader, finish: complete, incomplete: false)]
        precondition(OperationLogHistoryList.sorted(history).map(\.id) == [newer, older])
        precondition(OperationLogPresentation.operation(.environmentCompare) == "Environment Status · Compare")
        print("PASS: compact operation labels and newest-first history")
        try await storeChecks()
    }

    @MainActor static func fullHistoryReportChecks() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/macseed-report-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = OperationLogStore(directory: root)
        let request = CoreRequest(.environmentCompareBundle(path: "/private/fixture"))
        let session = store.begin(request, coreVersion: nil)
        for sequence in 1...1600 {
            let type = sequence == 1 ? "started" : sequence == 700 ? "diagnostic_record" : "verification_record"
            session.receive(try event(sequence, type, id: request.operationID, data: sequence == 700 ?
                ["severity": .string("warning"), "code": .string("observation_failed")] : ["conformity": .string("verified")]))
            if sequence % 50 == 0 { _ = try await store.page(session.id) }
        }
        let terminal = try event(1601, "failed", id: request.operationID, data: ["code": .string("bootstrap_failed"),
            "verification": .object(["status": .string("complete"), "verified_count": .integer(127), "mismatch_count": .integer(1), "details": .object(["status": .string("complete")])])])
        session.receive(terminal)
        _ = await session.finish(CoreProcessOutcome(terminal: terminal, exitCode: 2, signalled: false, error: nil,
            stderr: CoreStderrDiagnostics(), cancellationRequested: false), error: .coreFailure("bootstrap_failed"))
        let model = OperationLogViewerModel(store: store, target: session.id)
        await model.refreshHistory(); model.select(session.id, fromBeginning: true); await model.load(); await model.waitForReport()
        check(!model.report.loading && !model.report.unavailable)
        check(!model.rows.contains { $0.record.sequence == 1601 })
        check(model.report.keys.contains { $0.eventType == "failed" })
        check(model.report.keys.contains { $0.kind == .finish })
        check(model.report.issues.keys.contains { $0.contains("observation_failed") })
        check(OperationLogPresentation.summary(model.report.summaries).contains { $0.contains("Verified: 127") && $0.contains("Mismatches: 1") })
        check(model.report.verificationIssues.values.contains("Verification: 1 item did not match"))
        var seen: [Int] = []
        repeat {
            let all = OperationLogPresentation.timeline(model.rows, mode: .all).flatMap(\.rows)
            for sequence in all.compactMap({ $0.record.sequence }) where !seen.contains(sequence) { seen.append(sequence) }
            check(model.rows.count <= OperationLogViewerModel.visibleLimit)
            if !model.hasMore { break }
            await model.load()
        } while true
        check(seen == Array(1...1601))
        model.select(session.id, fromBeginning: true)
        check(!model.report.loading && model.report.keys.contains { $0.eventType == "failed" })
        check(model.report.issues.keys.contains { $0.contains("observation_failed") })
        await model.load()
        check(model.rows.first?.record.kind == .header && model.rows.contains { $0.record.sequence == 1 })
        model.close()
        print("PASS: All reaches every sequence across 1600+ records and reopens earliest events; Important finds middle warning and terminal failure/Verification independently of the All cursor")
    }

    @MainActor static func presentationUXChecks() {
        let id = UUID(), revision = UUID()
        func row(_ sequence: Int, _ type: String, _ codes: [String: String] = [:]) -> OperationLogRow {
            var record = OperationLogRecord(.event)
            record.sequence = sequence; record.eventType = type
            record.facts = OperationLogFacts(codes: codes)
            return OperationLogRow(id: .init(operation: id, revision: revision, ordinal: sequence), record: record)
        }
        let rows = [row(1, "started"), row(2, "verification_record", ["conformity": "verified"]),
            row(3, "verification_record", ["conformity": "verified"]),
            row(4, "verification_record", ["conformity": "unsupported"]),
            row(5, "diagnostic_record", ["severity": "warning", "code": "observation_failed"]),
            row(6, "operation_record", ["outcome": "noop"]), row(7, "operation_record", ["outcome": "success"]),
            row(8, "failed", ["code": "bootstrap_failed"])]
        let important = OperationLogPresentation.timeline(rows, mode: .important)
        check(important.flatMap(\.rows).map { $0.record.sequence } == [8])
        let all = OperationLogPresentation.timeline(rows, mode: .all)
        check(all.flatMap(\.rows).map(\.id) == rows.map(\.id))
        check(all.contains { $0.rows.count == 2 && $0.rows.first?.record.sequence == 2 })
        check(all.contains { $0.rows.count == 1 && $0.rows[0].record.sequence == 4 })
        check(all.contains { $0.rows.count == 1 && $0.rows[0].record.sequence == 5 })
        var report = OperationLogReport()
        rows.forEach { report.receive($0.record) }
        check(report.issues.values.reduce(0, +) >= 3)
        var result = row(9, "result").record
        result.evidence = [OperationLogFacts(codes: ["section": "verification"], counts: ["verified_count": 4, "unsupported_count": 1])]
        var failed = row(10, "failed", ["code": "bootstrap_failed"]).record
        failed.evidence = [OperationLogFacts(codes: ["section": "verification"], counts: ["verified_count": 127, "mismatch_count": 1])]
        let failedSummary = OperationLogPresentation.summary([failed])
        check(failedSummary.contains("Reason: bootstrap_failed"))
        check(failedSummary.contains { $0.contains("Verified: 127") && $0.contains("Mismatches: 1") })
        let summary = OperationLogPresentation.summary(rows.map(\.record) + [result])
        check(summary.contains("Reason: bootstrap_failed"))
        check(summary.contains { $0.contains("Verified: 4") && $0.contains("Unsupported: 1") })
        check(!summary.joined().contains("Changed") && !summary.joined().contains("Tailscale"))
        check(OperationLogPresentation.summary([]).isEmpty)
        let details = (0..<123).map { "safe detail \($0)" }
        let pasteboard = NSPasteboard.withUniqueName()
        OperationLogDetailPage.copy(details, to: pasteboard)
        check(pasteboard.string(forType: .string) == details.joined(separator: "\n"))
        pasteboard.releaseGlobally()
        check(OperationLogDetailPage.height(["short"]) < 60)
        check(OperationLogDetailPage.height(details) == 220)
        check(OperationLogDetailPage.height([String(repeating: "x", count: 1000)]) == 220)
        print("PASS: Important is a short issues/key-event report; All groups ordinary evidence and exposes every event; safe source counts/reasons, compact bounded details and complete event copy")
    }

    @MainActor static func closeUXChecks() {
        var failed = OperationLogRecord(.event)
        failed.sequence = 1; failed.eventType = "failed"
        failed.facts = OperationLogFacts(codes: ["code": "bootstrap_failed"])
        failed.evidence = [OperationLogFacts(codes: ["section": "verification"], counts: ["verified_count": 127, "mismatch_count": 1, "error_count": 1, "warning_count": 1])]
        var finish = OperationLogRecord(.finish)
        finish.eventType = "failed"; finish.exitCode = 2; finish.terminalValid = true; finish.incomplete = false
        finish.runtimeError = "bootstrap_failed"; finish.verificationStatus = "complete"; finish.detailStatus = "complete"
        var report = OperationLogReport(); report.receive(failed); report.receive(finish)
        report.issues["Execution · homebrew-casks · error, failure · cask_execution_requirements_unsupported"] = 2
        report.issues["Execution · homebrew-casks · warning · cask_execution_requirements_unsupported"] = 1
        report.issues["Verification · homebrew-casks · unsupported · cask_execution_requirements_unsupported"] = 1
        report.issues["Diagnostic · workspace · warning · observation_failed"] = 1
        let original = report.issues
        let issues = OperationLogPresentation.importantIssues(report)
        check(issues.contains("Verification: 1 item did not match"))
        check(!issues.contains { $0.contains("bootstrap_failed") || $0 == "Process · Failed" })
        check(issues.filter { $0.hasPrefix("Execution · homebrew-casks") }.count == 1)
        check(issues.contains { $0.hasPrefix("Verification · homebrew-casks") })
        check(issues.contains { $0.contains("observation_failed") })
        check(report.issues == original) // All/source projection has not been modified.
        let counters = OperationLogPresentation.counterGroups([failed, finish])
        check(counters.first { $0.id == "verification" }?.counters.first { $0.id == "verified_count" }?.value == 127)
        check(!counters.flatMap(\.counters).contains { $0.id == "selected_count" })
        check(OperationLogPresentation.outcome(finish) == "Failed")
        check(OperationLogPresentation.verification(finish) == "Verification complete")
        check(OperationLogPresentation.verificationValue(finish) == "Complete")
        check(OperationLogPresentation.verificationValue(nil) == "Not established")
        finish.eventType = "completed"; finish.exitCode = 0; finish.runtimeError = nil; finish.incomplete = true
        check(OperationLogPresentation.outcome(finish) == "Completed" && OperationLogPresentation.tone(finish) == .neutral)
        check(OperationLogPresentation.diagnosticStatus(incomplete: true, truncated: false, unavailable: false, recording: false) == "Log incomplete")
        var truncated = OperationLogRecord(.client); truncated.client = .truncated; truncated.omitted = true
        check(OperationLogPresentation.tone(truncated) == .neutral)
        var warning = OperationLogRecord(.event); warning.eventType = "diagnostic_record"; warning.sequence = 2
        warning.facts = OperationLogFacts(codes: ["severity": "warning", "code": "observation_failed"])
        check(OperationLogPresentation.tone(warning) == .warning)
        check(OperationLogDetailPage.height(["short"]) == 22)
        check(OperationLogDetailPage.height(["one", "two"]) == 36)
        check(OperationLogDetailPage.height(Array(repeating: "long", count: 40)) == 220)
        let source = try! String(contentsOfFile: "Sources/OperationLogView.swift", encoding: .utf8)
        let resultStart = source.range(of: "struct OperationLogResultSummary")!.lowerBound
        let resultEnd = source.range(of: "struct OperationLogStopRequest")!.lowerBound
        let resultSource = source[resultStart..<resultEnd]
        check(resultSource.contains("OperationLogSummaryPresentation.rows("))
        check(resultSource.contains("Grid(") && resultSource.contains("diagnosticStatus(") && !resultSource.contains("Color.orange"))
        check(source.contains("view.isEditable = false; view.isSelectable = true") && !source.contains("LazyVStack"))
        print("PASS: Important deduplicates causes without merging domains/sources; compact source-scoped counters; successful incomplete logs stay neutral; short Details height 22/36 with bounded TextKit and complete copy")
    }

    @MainActor static func summaryPolishChecks() {
        var failure = OperationLogRecord(.event)
        failure.sequence = 1; failure.eventType = "failed"
        failure.facts = OperationLogFacts(codes: ["code": "bootstrap_failed"], counts: ["error_count": 1, "warning_count": 0])
        failure.evidence = [OperationLogFacts(codes: ["section": "verification"],
            counts: ["verified_count": 127, "unverified_count": 0, "mismatch_count": 1, "unresolved_count": 0, "warning_count": 1, "selected_count": 128, "error_count": 9])]
        var finish = OperationLogRecord(.finish)
        finish.eventType = "failed"; finish.terminalValid = true; finish.incomplete = false; finish.exitCode = 2
        finish.runtimeError = "bootstrap_failed"; finish.verificationStatus = "complete"; finish.detailStatus = "complete"
        let rows = OperationLogSummaryPresentation.rows(finish: finish, active: false, records: [failure, finish])
        check(rows.map(\.id) == ["process", "verification", "execution", "counters", "reason"])
        check(rows[0].value == "Failed" && rows[1].value == "Complete")
        check(rows[2].value == "Errors: 1 · Warnings: 0") // Never substitutes Verification Errors: 9.
        check(rows[3].value == "Verified: 127 · Unverified: 0 · Mismatches: 1 · Unresolved: 0 · Warnings: 1 · Selected: 128")
        check(rows[4].value == "bootstrap_failed")
        finish.eventType = "completed"; finish.exitCode = 0; finish.runtimeError = nil; finish.incomplete = true
        let success = OperationLogSummaryPresentation.rows(finish: finish, active: false, records: [])
        check(success.map(\.id) == ["process", "verification"] && success[0].value == "Completed")
        check(OperationLogPresentation.diagnosticStatus(incomplete: true, truncated: false, unavailable: false, recording: false) == "Log incomplete")
        finish.verificationStatus = "not_run"
        let preview = OperationLogSummaryPresentation.rows(finish: finish, active: false, records: [])
        check(preview.count == 2 && preview[1].value == "Not Run")
        let host = NSHostingView(rootView: OperationLogResultSummary(finish: finish, active: false,
            incomplete: false, truncated: false, unavailable: false, records: []))
        let size = host.fittingSize
        check(size.width > 0 && size.width <= 560 && size.height > 0 && size.height < 100)
        let running = OperationLogSummaryPresentation.rows(finish: nil, active: true, records: [])
        check(running.count == 2 && running[0].value == "Running" && running[1].value == "Unknown")
        finish.verificationStatus = "partial"; finish.detailStatus = "partial"
        check(OperationLogSummaryPresentation.rows(finish: finish, active: false, records: [])[1].value == "Incomplete")
        finish.eventType = "cancelled"; finish.exitCode = 130
        check(OperationLogSummaryPresentation.rows(finish: finish, active: false, records: [])[0].value == "Cancelled")
        check(OperationLogPresentation.outcome(finish) == "Stopped") // Global presentation contract is unchanged.
        finish.terminalValid = false
        check(OperationLogSummaryPresentation.rows(finish: finish, active: false, records: [])[0].value == "Interrupted or Unknown")
        let source = try! String(contentsOfFile: "Sources/OperationLogView.swift", encoding: .utf8)
        let start = source.range(of: "struct OperationLogResultSummary")!.lowerBound
        let end = source.range(of: "struct OperationLogStopRequest")!.lowerBound
        let summary = source[start..<end]
        check(summary.contains("maxWidth: 560") && !summary.contains("maxWidth: .infinity"))
        check(!summary.contains("WorkspaceCardSurface") && !summary.contains("Color.orange") && !summary.contains("padding(12)"))
        print("PASS: compact aligned Summary; Failed Restore with Complete Verification; source-separated known counters, success, Not Run, Unknown/Running, confirmed Cancelled and empty-counter Inspect/Preview")
    }

    @MainActor static func largeDetailsChecks() async throws {
        var sanitizer = OperationLogSanitizer()
        let rows = (0..<1100).map { index in CoreJSON.object([
            "domain": .string("git-configuration"), "status": .string("complete"),
            "item_id": .string("private-repository-\(index)"), "matching": .integer(1)]) }
        let raw = try event(2, "result", id: UUID().uuidString, data: ["comparison_records": .array(rows)])
        let safe = sanitizer.event(raw, at: Date())
        check(safe.omitted == true && safe.evidence?.count == 20)
        check(OperationLogPresentation.tone(safe) == .neutral)
        check(!OperationLogPresentation.details(safe).joined().contains("private-repository"))
        let root = URL(fileURLWithPath: "/private/tmp/macseed-comparison-details-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let store = OperationLogStore(directory: root.appendingPathComponent("logs"))
        let request = CoreRequest(.environmentCompareBundle(path: "/private/fixture"))
        let session = store.begin(request, coreVersion: nil)
        session.receive(try event(1, "started", id: request.operationID))
        session.receive(try event(2, "result", id: request.operationID, data: ["comparison_records": .array(rows)]))
        let terminal = try event(3, "completed", id: request.operationID)
        session.receive(terminal)
        check(await session.finish(outcome(terminal), error: nil) == .incomplete)
        let history = try await store.history()
        check(history.first?.finish?.terminalValid == true && history.first?.incomplete == true)
        check(OperationLogPresentation.outcome(history.first?.finish) == "Completed")
        let saved = try await store.read(session.id)
        check(saved.records.first { $0.sequence == 2 }?.evidence?.count == 20)
        var dense = safe
        // Exercise the largest permitted typed evidence, not unvalidated JSON.
        dense.evidence = (0..<20).map { _ in OperationLogFacts(
            codes: ["section": "comparison_records", "status": "complete"],
            counts: Dictionary(uniqueKeysWithValues: OperationLogSanitizer.countKeys.map { ($0, 1) })) }
        let details = OperationLogPresentation.details(dense)
        check(details.count > 400 && OperationLogSanitizer.valid(dense))
        var covered: [Int] = []
        for page in 0...details.count / OperationLogDetailPage.pageSize {
            let range = OperationLogDetailPage.range(count: details.count, page: page)
            check(range.count <= 40)
            if covered.last != range.last { covered += range }
        }
        check(covered == Array(details.indices))
        check(OperationLogDetailPage.range(count: 0, page: 0).isEmpty)

        func content(_ count: Int) -> some View {
            ScrollView {
                VStack(alignment: .leading) {
                    ForEach(0..<count, id: \.self) { _ in OperationLogEventRow(record: dense, initiallyExpanded: true) }
                }
            }.frame(width: 760, height: 480)
        }
        let host = NSHostingView(rootView: content(24))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 480),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        func scrollView(_ view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.compactMap { scrollView($0) }.first
        }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        guard let scroll = scrollView(host) else { preconditionFailure("Native scroll fixture is missing") }
        var distance: CGFloat = 0
        for tick in 0..<1200 {
            // Keep Details open while event arrivals invalidate the outer list.
            if tick % 30 == 0 { host.rootView = content(24 + tick / 30) }
            let height = max(0, (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height)
            let fraction = CGFloat(tick % 60) / 59
            let previous = scroll.contentView.bounds.origin.y
            scroll.contentView.scroll(to: NSPoint(x: 0, y: height * fraction))
            distance += abs(scroll.contentView.bounds.origin.y - previous)
            scroll.reflectScrolledClipView(scroll.contentView)
            host.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(25))
        }
        check(distance > 10_000)
        print("PASS: 1100 comparison records, truthful incomplete/completed log, bounded 40-line pages, open native Details with 1200 scroll/update frames over at least 30 seconds")
    }

    @MainActor static func switchingChecks() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/macseed-log-switch-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let store = OperationLogStore(directory: root.appendingPathComponent("logs"))
        var ids: [UUID] = []
        for count in [300, 1, 20] {
            let request = CoreRequest(.environmentCompareBundle(path: "/private/fixture"))
            let session = store.begin(request, coreVersion: nil); ids.append(session.id)
            session.receive(try event(1, "started", id: request.operationID))
            for index in 0..<count {
                session.receive(try event(index + 2, "diagnostic_record", id: request.operationID,
                    data: ["code": .string("observation_failed"), "severity": .string(count == 1 ? "error" : "warning")]))
                if index % 50 == 0 { _ = try await store.page(session.id) }
            }
            let terminal = try event(count + 2, count == 1 ? "failed" : "completed", id: request.operationID,
                                     data: count == 1 ? ["code": .string("observation_failed")] : [:])
            session.receive(terminal)
            _ = await session.finish(CoreProcessOutcome(terminal: terminal, exitCode: count == 1 ? 2 : 0,
                signalled: false, error: nil, stderr: CoreStderrDiagnostics(), cancellationRequested: false), error: nil)
        }
        let gate = DelayedLogPage()
        let model = OperationLogViewerModel(store: store, target: ids[0], readPage: { id, cursor, tail in
            let page = try await store.page(id, after: cursor, tail: tail)
            if id == ids[0] { await gate.pause() }
            return page
        })
        await model.refreshHistory()
        let stale = Task { await model.load() }
        while !(await gate.waiting) { await Task.yield() }
        var publications = 0
        let observer = model.objectWillChange.sink { publications += 1 }
        model.select(ids[1], fromBeginning: true)
        check(publications == 1)
        check(model.rows.isEmpty && model.selectedID == ids[1] && model.finish?.exitCode == 2)
        await model.load()
        check(model.rows.first?.record.storageID == ids[1] && model.finish?.exitCode == 2)
        check(model.rows.allSatisfy { $0.id.operation == ids[1] && $0.id.revision == model.generation })
        await model.waitForReport()
        publications = 0; await model.load(); await model.waitForReport(); check(publications == 0)
        observer.cancel()
        await gate.release(); await stale.value
        check(model.rows.first?.record.storageID == ids[1])
        for index in 0..<150 { model.choose(ids[index % ids.count], fromBeginning: true); await Task.yield() }
        model.select(ids[2], fromBeginning: true); await model.load()
        check(model.selectedID == ids[2] && model.rows.first?.record.storageID == ids[2] && model.finish?.exitCode == 0)

        let closeGate = DelayedLogPage()
        let closing = OperationLogViewerModel(store: store, target: ids[0], readPage: { id, cursor, tail in
            let page = try await store.page(id, after: cursor, tail: tail); await closeGate.pause(); return page
        })
        let inflight = Task { await closing.load() }
        while !(await closeGate.waiting) { await Task.yield() }
        closing.close(); await closeGate.release(); await inflight.value
        check(closing.rows.isEmpty)
        try await nativeViewerChecks(store: store, ids: ids)
        print("PASS: latest selection wins over delayed loads, 150 rapid switches, different outcomes/lengths and close during load")
    }

    @MainActor static func nativeViewerChecks(store: OperationLogStore, ids: [UUID]) async throws {
        let runtime = CoreRuntime(operationLogs: store)
        var model = OperationLogViewerModel(store: store, target: ids[0])
        await model.refreshHistory(); model.select(ids[0], fromBeginning: true); await model.load()
        func content(_ expanded: Bool) -> some View {
            OperationLogSheet(runtime: runtime, target: ids[0], model: model, initiallyExpandedDetails: expanded, initiallyAllEvents: true)
                .id(expanded)
        }
        let host = NSHostingView(rootView: content(true))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 620),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { model.close(); window.close() }
        var expanded = true
        var textChecks = 0
        func scrollView(_ view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.compactMap { scrollView($0) }.first
        }
        func textViews(_ view: NSView) -> [NSTextView] {
            (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap { textViews($0) }
        }
        for tick in 0..<300 {
            if tick % 25 == 0 {
                let id = ids[(tick / 25) % ids.count]
                model.choose(id, fromBeginning: true)
                for _ in 0..<100 {
                    if model.rows.first?.record.storageID == id { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                check(model.selectedID == id && model.rows.first?.record.storageID == id)
                check(model.rows.allSatisfy { $0.id.operation == id && $0.id.revision == model.generation })
                check(model.finish?.eventType == model.history.first { $0.id == id }?.finish?.eventType)
            }
            // Recreate the full sheet in expanded/collapsed state; exercise its
            // actual lifecycle and selected store data, not a row-only preview.
            if tick % 50 == 0 && expanded != (tick % 100 == 0) {
                let id = model.selectedID!
                model.close()
                model = OperationLogViewerModel(store: store, target: id)
                await model.refreshHistory(); model.select(id, fromBeginning: true); await model.load()
                expanded = tick % 100 == 0
                host.rootView = content(expanded)
            }
            try await Task.sleep(for: .milliseconds(15))
            guard let scroll = scrollView(host) else { preconditionFailure("Full viewer native scroll view missing") }
            let height = max(0, (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: height * CGFloat(tick % 20) / 19))
            scroll.reflectScrolledClipView(scroll.contentView)
            for text in textViews(host) where text.accessibilityLabel() == "Operation event details" {
                check(!text.isEditable && text.isSelectable && !text.isRichText)
                check(text.string.split(separator: "\n").count <= 40)
                text.setSelectedRange(NSRange(location: 0, length: min(20, (text.string as NSString).length)))
                text.scrollRangeToVisible(NSRange(location: max(0, (text.string as NSString).length - 1), length: 0))
                textChecks += 1
            }
            host.displayIfNeeded(); try await Task.sleep(for: .milliseconds(25))
        }
        check(textChecks > 0)
        print("PASS: full native sheet, exact selected IDs and timeline/summary, 12 history-model selections, expanded/collapsed Details and scrolling (no manual mouse test)")
    }
}
