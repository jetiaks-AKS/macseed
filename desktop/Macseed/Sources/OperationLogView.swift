import AppKit
import SwiftUI

private typealias LogViewState<Value> = SwiftUI.State<Value>
struct OperationLogRow: Identifiable {
    struct ID: Hashable {
        let operation: UUID
        let revision: UUID
        let ordinal: Int
    }
    let id: ID
    let record: OperationLogRecord
}
private struct OperationLogOpenKey: EnvironmentKey {
    static let defaultValue: ((UUID?) -> Void)? = nil
}
extension EnvironmentValues {
    var openOperationLog: ((UUID?) -> Void)? {
        get { self[OperationLogOpenKey.self] }
        set { self[OperationLogOpenKey.self] = newValue }
    }
}
// One standard native window shared by all entry points. Closing it cancels
// only its reader; CoreRuntime remains owned by the application.
@MainActor final class OperationLogWindowController: NSWindowController, NSWindowDelegate {
    static let shared = OperationLogWindowController()
    private var model: OperationLogViewerModel?
    private var runtime: CoreRuntime?
    var selectedOperationID: UUID? { model?.selectedID }
    init() { super.init(window: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    func open(runtime: CoreRuntime, target: UUID?) {
        if let window, window.isVisible, self.runtime === runtime, let target, let model {
            model.choose(target)
            model.requestHistory()
            window.makeKeyAndOrderFront(nil)
            return
        }
        model?.close()
        let reader = OperationLogViewerModel(store: runtime.operationLogStore, target: target)
        model = reader; self.runtime = runtime
        if window == nil {
            let native = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 620),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            native.title = "Operation Logs"
            native.isReleasedWhenClosed = false
            native.contentMinSize = NSSize(width: 680, height: 480)
            native.center()
            native.setFrameAutosaveName("MacseedOperationLogs")
            native.delegate = self
            window = native
        }
        window?.contentView = NSHostingView(rootView: OperationLogSheet(runtime: runtime, target: target, model: reader))
        window?.makeKeyAndOrderFront(nil)
    }
    func windowWillClose(_ notification: Notification) {
        model?.close()
        // Detach hosting content so SwiftUI cancels its polling task as well.
        window?.contentView = nil
    }
}

struct OperationLogPresenter: ViewModifier {
    @ObservedObject var runtime: CoreRuntime
    @Environment(\.openOperationLog) private var parentOpen
    func body(content: Content) -> some View {
        content.environment(\.openOperationLog, parentOpen ?? { OperationLogWindowController.shared.open(runtime: runtime, target: $0) })
    }
}

enum OperationLogVisibility {
    static func capture(_ state: CaptureFlowState, active: Bool, reference: OperationLogReference?, failure: CaptureFailure? = nil, terminal: Bool = false) -> Bool {
        // A local destination failure did not launch a new Core operation.
        if !terminal || failure == .invalidDestination { return false }
        return final([.result, .failed, .cancelled].contains(state), active: active, reference: reference,
              allowed: [.capturePrepare, .captureExecute])
    }
    static func status(_ state: EnvironmentStatusState, active: Bool, reference: OperationLogReference?, terminal: Bool = false) -> Bool {
        guard terminal else { return false }
        return visible(final: state == .result || state == .failed || state == .cancelled, active: active, reference: reference, operation: .environmentCompare)
    }
    static func restore(_ state: RestoreFlowState, active: Bool, reference: OperationLogReference?, terminal: Bool = false, failedOperation: Bool = false) -> Bool {
        guard terminal else { return false }
        if state == .result { return visible(final: true, active: active, reference: reference, operation: .restoreExecute) }
        let allowed: Set<CoreOperation> = [.review, .failed, .cancelled].contains(state)
            ? [.bundleInspect, .restorePrepare] : [.restorePrepare]
        let failure = [.failed, .cancelled].contains(state)
            || (failedOperation && [.review, .preview, .confirming].contains(state))
        return final(failure,
            active: active, reference: reference, allowed: allowed)
    }
    private static func final(_ terminal: Bool, active: Bool, reference: OperationLogReference?, allowed: Set<CoreOperation>) -> Bool {
        terminal && !active && reference.map { allowed.contains($0.operation) } == true
    }
    static func visible(final: Bool, active: Bool, reference: OperationLogReference?, operation: CoreOperation) -> Bool {
        final && !active && reference?.operation == operation
    }
}

struct OperationLogReport: Sendable {
    var loading = true
    var unavailable = false
    var damaged = false
    var incomplete = false
    var truncated = false
    var keys: [OperationLogRecord] = []
    var summaries: [OperationLogRecord] = []
    var issues: [String: Int] = [:]
    var overflow = 0
    var keyOverflow = 0
    var verificationIssues: [String: String] = [:]
    mutating func receive(_ record: OperationLogRecord) {
        guard OperationLogSanitizer.valid(record) else { damaged = true; return }
        incomplete = incomplete || record.omitted == true || record.incomplete == true
        truncated = truncated || record.client == .truncated
        if ["result", "completed", "failed", "cancelled"].contains(record.eventType ?? "") || record.kind == .finish {
            // Retain latest records by type/section, bounded independently of All.
            summaries.removeAll { $0.kind == record.kind && $0.eventType == record.eventType && $0.facts?.codes["section"] == record.facts?.codes["section"] }
            if summaries.count < 32 { summaries.append(record) }
        }
        for facts in [record.facts].compactMap({ $0 }) + (record.evidence ?? []) where facts.codes["section"] == "verification" {
            for (key, label) in ["mismatch_count": "item did not match", "unsupported_count": "unsupported requirement", "unresolved_count": "unresolved requirement", "unverified_count": "unverified requirement", "warning_count": "warning", "error_count": "error"] {
                if let count = facts.counts[key] {
                    verificationIssues[key] = count > 0 ? (key == "mismatch_count" ? "Verification: \(count) \(count == 1 ? "item" : "items") did not match" : "Verification: \(count) \(label)\(count == 1 ? "" : "s")") : nil
                }
            }
        }
        if let issue = OperationLogPresentation.issue(record) {
            if issues[issue] != nil || issues.count < 64 { issues[issue, default: 0] += 1 }
            else { overflow += 1 }
        }
        if record.kind == .header || record.kind == .finish ||
            ["phase_started", "phase_completed", "completed", "failed", "cancelled"].contains(record.eventType ?? "") {
            if keys.count >= 32 { keys.remove(at: keys.first?.kind == .header ? 1 : 0); keyOverflow += 1 }
            keys.append(record)
        }
    }
}
private struct OperationLogReportBatch: Sendable {
    var report: OperationLogReport
    var cursor: OperationLogCursor?
    var changed: Bool
}

private struct OperationLogSelection {
    var report = OperationLogReport()
    var selectedID: UUID?
    var generation = UUID()
    var rows: [OperationLogRow] = []
    var finish: OperationLogRecord?
    var unavailable = false
    var incomplete = true
    var truncated = false
    var hasMore = false
    var earlierEvents = false
    var following = true
}

@MainActor final class OperationLogViewerModel: ObservableObject {
    nonisolated static let visibleLimit = 512
    @Published private(set) var history: [OperationLogHistory] = []
    @Published private var selection = OperationLogSelection()
    @Published private(set) var clearing = false
    var report: OperationLogReport { selection.report }
    private var reportCursor: OperationLogCursor?
    private var reportTask: Task<Void, Never>?
    private var reportWorker: Task<OperationLogReportBatch, Error>?
    private(set) var selectedID: UUID? {
        get { selection.selectedID }
        set { selection.selectedID = newValue }
    }
    private(set) var generation: UUID {
        get { selection.generation }
        set { selection.generation = newValue }
    }
    private(set) var rows: [OperationLogRow] {
        get { selection.rows }
        set { selection.rows = newValue }
    }
    private(set) var finish: OperationLogRecord? {
        get { selection.finish }
        set { selection.finish = newValue }
    }
    private(set) var unavailable: Bool {
        get { selection.unavailable }
        set { selection.unavailable = newValue }
    }
    private(set) var incomplete: Bool {
        get { selection.incomplete }
        set { selection.incomplete = newValue }
    }
    private(set) var truncated: Bool {
        get { selection.truncated }
        set { selection.truncated = newValue }
    }
    private(set) var hasMore: Bool {
        get { selection.hasMore }
        set { selection.hasMore = newValue }
    }
    private(set) var earlierEvents: Bool {
        get { selection.earlierEvents }
        set { selection.earlierEvents = newValue }
    }
    private(set) var following: Bool {
        get { selection.following }
        set { selection.following = newValue }
    }
    private let store: OperationLogStore?
    private let readPage: (UUID, OperationLogCursor?, Bool) async throws -> OperationLogPage
    private var cursor: OperationLogCursor?
    private var readEpoch = UUID()
    private var loading: UUID?
    private var readerTask: Task<Void, Never>?
    private var historyTask: Task<Void, Never>?
    private var closed = false
    private var ordinal = 0
    private var tail = true
    private var damaged = false
    private var omissions = false
    init(store: OperationLogStore?, target: UUID?,
         readPage: ((UUID, OperationLogCursor?, Bool) async throws -> OperationLogPage)? = nil) {
        self.store = store
        self.readPage = readPage ?? { id, cursor, tail in
            guard let store else { throw OperationLogError.storageUnavailable }
            return try await store.page(id, after: cursor, tail: tail)
        }
        selectedID = target
    }

    func refreshHistory() async {
        guard !closed, !Task.isCancelled, !clearing else { return }
        guard let store else { unavailable = true; selection.report.loading = false; selection.report.unavailable = true; return }
        let token = readEpoch
        do {
            let saved = try await store.history()
            guard readEpoch == token, !Task.isCancelled else { return }
            history = OperationLogHistoryList.sorted(saved)
            if selectedID == nil, let first = history.first { select(first.id) }
            if let item = history.first(where: { $0.id == selectedID }), cursor?.finishSeen != true {
                finish = item.finish; incomplete = item.incomplete || damaged || omissions
            }
        } catch { if readEpoch == token && !closed && !Task.isCancelled { unavailable = true } }
    }
    func select(_ id: UUID, fromBeginning: Bool = false) {
        let sameReport = selectedID == id && !selection.report.unavailable && !selection.report.damaged
        let savedReport = sameReport ? selection.report : OperationLogReport()
        let savedReportCursor = sameReport ? reportCursor : nil
        readerTask?.cancel(); reportTask?.cancel(); reportWorker?.cancel(); reportTask = nil; reportCursor = savedReportCursor
        cursor = nil; ordinal = 0; damaged = false; omissions = false; tail = !fromBeginning
        // A single publication changes identity, summary and timeline together.
        var next = OperationLogSelection(selectedID: id, finish: history.first { $0.id == id }?.finish,
            earlierEvents: !fromBeginning, following: !fromBeginning)
        next.report = savedReport
        readEpoch = next.generation; selection = next
        requestReport()
    }
    func choose(_ id: UUID, fromBeginning: Bool = false) {
        select(id, fromBeginning: fromBeginning); requestLoad()
    }
    func requestLoad() {
        readerTask?.cancel()
        readerTask = Task { await load() }
    }
    func requestHistory() {
        historyTask?.cancel()
        historyTask = Task { await refreshHistory(); await poll() }
    }
    func open() { closed = false }
    func close() {
        closed = true; readEpoch = UUID()
        readerTask?.cancel(); historyTask?.cancel(); reportTask?.cancel(); reportWorker?.cancel()
    }
    func poll() async { if following { await load() }; requestReport() }
    func requestReport() {
        guard !closed, !selection.report.damaged, !selection.report.unavailable, reportTask == nil, let id = selectedID, let store else { return }
        let token = readEpoch, previous = selection.report, cursor = reportCursor
        let worker = Task.detached(priority: .utility) { () throws -> OperationLogReportBatch in
            var report = previous, cursor = cursor, changed = previous.loading
            while true {
                try Task.checkCancellation()
                let page = try await store.page(id, after: cursor)
                for record in page.records { report.receive(record) }
                changed = changed || !page.records.isEmpty || page.damaged
                cursor = page.cursor
                report.damaged = report.damaged || page.damaged
                if page.atEnd || page.damaged { break }
            }
            report.loading = false
            return OperationLogReportBatch(report: report, cursor: cursor, changed: changed)
        }
        reportWorker = worker
        reportTask = Task {
            defer { if readEpoch == token { reportTask = nil; reportWorker = nil } }
            do {
                let batch = try await worker.value
                guard !closed, !Task.isCancelled, readEpoch == token, selectedID == id else { return }
                reportCursor = batch.cursor
                if batch.changed { selection.report = batch.report }
            } catch {
                if !closed, !Task.isCancelled, readEpoch == token {
                    selection.report.loading = false; selection.report.unavailable = true
                }
            }
        }
    }
    func waitForReport() async { requestReport(); await reportTask?.value }
    func load() async {
        let token = readEpoch
        guard !closed, !Task.isCancelled, loading != token, !damaged, store != nil, let id = selectedID else { return }
        requestReport()
        loading = token; defer { if loading == token { loading = nil } }
        do {
            // Two bounded pages per tick; large files cannot monopolize MainActor.
            for _ in 0..<2 {
                let initial = cursor == nil
                let page = try await readPage(id, cursor, tail)
                guard !closed, !Task.isCancelled, readEpoch == token, selectedID == id else { return }
                if page.records.isEmpty && !page.damaged {
                    cursor = page.cursor
                    if unavailable { unavailable = false }
                    if hasMore != !page.atEnd { hasMore = !page.atEnd }
                    break // Idle polling must not invalidate disclosure layouts.
                }
                var next = selection
                if initial { next.earlierEvents = page.records.first?.kind != .header }
                cursor = page.cursor; next.unavailable = false; damaged = page.damaged; next.hasMore = !page.atEnd && !page.damaged
                for record in page.records {
                    let rowID = OperationLogRow.ID(operation: id, revision: next.generation, ordinal: ordinal)
                    next.rows.append(OperationLogRow(id: rowID, record: record)); ordinal += 1
                    if record.kind == .finish { next.finish = record }
                    if record.client == .truncated { next.truncated = true }
                    if record.omitted == true { omissions = true }
                }
                if next.rows.count > Self.visibleLimit { next.rows.removeFirst(next.rows.count - Self.visibleLimit); next.earlierEvents = true }
                next.incomplete = damaged || omissions || next.finish == nil || next.finish?.incomplete == true || next.finish?.terminalValid != true
                selection = next
                if page.atEnd || page.damaged { break }
            }
        } catch { if !closed && !Task.isCancelled && readEpoch == token { unavailable = true; incomplete = true } }
    }
    func clear() async {
        guard !clearing, let store else { return }
        clearing = true; defer { clearing = false }
        do {
            _ = try await store.clearInactive()
            readEpoch = UUID()
            reportTask?.cancel(); reportWorker?.cancel(); reportTask = nil
            let surviving = OperationLogHistoryList.sorted(try await store.history())
            history = surviving
            if !surviving.contains(where: { $0.id == selectedID }) {
                selectedID = nil; cursor = nil; rows = []; finish = nil; incomplete = true
                if let first = surviving.first { select(first.id) }
            }
            unavailable = false
        } catch { unavailable = true }
    }
}

struct OperationLogButton: View {
    @ObservedObject var runtime: CoreRuntime
    let reference: OperationLogReference?
    var historyOnly = false
    @Environment(\.openOperationLog) private var open
    var body: some View {
        Button { open?(reference?.id) } label: { Label(historyOnly ? "Operation Logs" : "View Log", systemImage: historyOnly ? "clock" : "doc.text") }
            .disabled(open == nil || runtime.operationLogStore == nil || (!historyOnly && reference == nil))
    }
}

struct OperationLogSheet: View {
    @ObservedObject var runtime: CoreRuntime
    @StateObject private var model: OperationLogViewerModel
    private let initiallyExpandedDetails: Bool
    private let initiallyAllEvents: Bool
    init(runtime: CoreRuntime, target: UUID?, model: OperationLogViewerModel? = nil, initiallyExpandedDetails: Bool = false, initiallyAllEvents: Bool = false) {
        self.initiallyAllEvents = initiallyAllEvents
        self.runtime = runtime
        self.initiallyExpandedDetails = initiallyExpandedDetails
        _model = StateObject(wrappedValue: model ?? OperationLogViewerModel(store: runtime.operationLogStore, target: target))
    }
    private var activeID: UUID? { runtime.isActive ? runtime.operationLogReference(matching: runtime.operationID)?.id : nil }
    var body: some View {
        OperationLogView(runtime: runtime, history: model.history, records: model.rows, selectedID: model.selectedID,
            activeID: activeID, finish: model.finish, incomplete: model.incomplete, truncated: model.truncated,
            unavailable: model.unavailable, hasMore: model.hasMore, earlierEvents: model.earlierEvents, clearing: model.clearing,
            following: model.following, report: model.report,
            select: { model.choose($0) }, loadMore: { model.requestLoad() },
            readBeginning: { if let id = model.selectedID { model.choose(id, fromBeginning: true) } },
            readLatest: { if let id = model.selectedID { model.choose(id) } },
            refreshHistory: { model.requestHistory() }, clearLogs: { Task { await model.clear() } },
            initiallyExpandedDetails: initiallyExpandedDetails, initiallyAllEvents: initiallyAllEvents)
        .task {
            model.open()
            await model.refreshHistory()
            await model.load()
            while !Task.isCancelled {
                await model.poll()
                do { try await Task.sleep(for: .milliseconds(500)) } catch { break }
            }
        }
        .onDisappear { model.close() }
        .onChange(of: runtime.operationLogStatus) { _, _ in
            if !runtime.isActive { model.requestHistory() }
        }
    }
}

enum OperationLogTimelineMode: Hashable { case important, all }
struct OperationLogTimelineGroup: Identifiable {
    var rows: [OperationLogRow]
    var id: OperationLogRow.ID { rows[0].id }
}

struct OperationLogCounterGroup: Identifiable {
    struct Counter: Identifiable { let id: String; let title: String; let value: Int }
    let id: String
    let title: String
    let counters: [Counter]
}

// Presentation consumes only validated persistent records, never CoreEvent payloads.
enum OperationLogPresentation {
    static func repetitive(_ record: OperationLogRecord) -> Bool {
        guard OperationLogSanitizer.valid(record), tone(record) == .neutral, record.omitted != true,
              ["verification_record", "coverage_record", "operation_record", "execution_event"].contains(record.eventType ?? "") else { return false }
        let facts = [record.facts].compactMap { $0 } + (record.evidence ?? [])
        return !facts.contains { facts in
            facts.codes["code"] != nil || facts.codes["reason"] != nil ||
            (facts.counts["warning_count"] ?? 0) > 0 || (facts.counts["error_count"] ?? 0) > 0 ||
            (facts.counts["unsupported_count"] ?? 0) > 0 || (facts.counts["mismatch_count"] ?? 0) > 0 ||
            facts.codes.values.contains { ["skipped", "unsupported", "unresolved", "mismatch", "failure", "failed", "blocked", "conflict", "warning"].contains($0) }
        }
    }
    static func issue(_ record: OperationLogRecord) -> String? {
        guard OperationLogSanitizer.valid(record) else { return nil }
        if let client = record.client, [.gracefulStopDelivered, .gracefulStopDeliveryFailed, .forceStopRequested].contains(client) { return title(record) }
        let facts = [record.facts].compactMap { $0 } + (record.evidence ?? [])
        let problems = facts.flatMap { facts in
            facts.codes.filter { ["severity", "state", "outcome", "conformity", "support", "disposition"].contains($0.key) &&
                ["warning", "error", "failed", "failure", "blocked", "conflict", "unsupported", "unresolved", "mismatch", "skipped"].contains($0.value) }.map(\.value)
        }
        guard !problems.isEmpty || record.eventType == "failed" else { return nil }
        let reason = record.facts?.codes["code"] ?? record.facts?.codes["reason"]
        let domain = record.facts?.codes["domain"]
        let source = record.kind == .finish ? "Process" : record.eventType == "verification_record" ? "Verification" :
            record.eventType == "coverage_record" ? "Scope" : record.eventType == "diagnostic_record" ? "Diagnostic" : "Execution"
        return ([source, domain, Array(Set(problems)).sorted().joined(separator: ", ").isEmpty ? "Failed" : Array(Set(problems)).sorted().joined(separator: ", "), reason].compactMap { $0 }).joined(separator: " · ")
    }
    static func timeline(_ rows: [OperationLogRow], mode: OperationLogTimelineMode) -> [OperationLogTimelineGroup] {
        var result: [OperationLogTimelineGroup] = []
        for row in rows.suffix(OperationLogViewerModel.visibleLimit) {
            if mode == .important {
                guard row.record.kind == .header || row.record.kind == .finish ||
                    ["phase_started", "phase_completed", "completed", "failed", "cancelled"].contains(row.record.eventType ?? "") else { continue }
            }
            if mode == .all, repetitive(row.record), let last = result.last,
               last.rows.last.map({ repetitive($0.record) }) == true,
               last.rows.last?.record.eventType == row.record.eventType,
               last.rows.last?.record.evidence?.map(\.codes) == row.record.evidence?.map(\.codes),
               last.rows.last?.record.evidence?.map(\.counts) == row.record.evidence?.map(\.counts),
               last.rows.last?.record.evidence?.map(\.flags) == row.record.evidence?.map(\.flags),
               last.rows.last?.record.facts?.codes == row.record.facts?.codes,
               last.rows.last?.record.facts?.counts == row.record.facts?.counts,
               last.rows.last?.record.facts?.flags == row.record.facts?.flags {
                result[result.count - 1].rows.append(row)
            } else { result.append(OperationLogTimelineGroup(rows: [row])) }
        }
        return result
    }
    static func counterLabel(_ key: String) -> String {
        ["selected_count": "Selected", "selected_domains": "Selected areas", "selected_items": "Selected items", "verified_count": "Verified",
         "mismatch_count": "Mismatches", "error_count": "Errors", "warning_count": "Warnings", "unverified_count": "Unverified",
         "unsupported_count": "Unsupported", "unresolved_count": "Unresolved"][key] ?? key.replacingOccurrences(of: "_", with: " ").capitalized
    }
    static func counterGroups(_ records: [OperationLogRecord]) -> [OperationLogCounterGroup] {
        let safe = records.filter { OperationLogSanitizer.valid($0) }
        // Counts belong to their persisted source sequence/section; never sum
        // overlapping evidence or reinterpret a failed process as no changes.
        var summaries: [String: (Int, OperationLogFacts)] = [:]
        for record in safe where ["result", "completed", "failed", "cancelled"].contains(record.eventType ?? "") {
            for facts in [record.facts].compactMap({ $0 }) + (record.evidence ?? []) where !facts.counts.isEmpty {
                let section = facts.codes["section"] ?? record.eventType ?? "result"
                guard ["result", "completed", "failed", "cancelled", "summary", "verification", "comparison", "verification_details", "records"].contains(section) else { continue }
                if let prior = summaries[section], prior.0 == record.sequence {
                    var combined = prior.1
                    combined.counts.merge(facts.counts) { _, latest in latest }
                    summaries[section] = (prior.0, combined)
                } else { summaries[section] = (record.sequence ?? 0, facts) }
            }
        }
        return summaries.keys.sorted().map { section in
            let facts = summaries[section]!.1
            let title = ["failed": "Execution", "completed": "Execution", "cancelled": "Execution", "result": "Operation", "summary": "Selection" ][section]
                ?? section.replacingOccurrences(of: "_", with: " ").capitalized
            return OperationLogCounterGroup(id: section, title: title, counters: facts.counts.keys.sorted().map {
                OperationLogCounterGroup.Counter(id: $0, title: counterLabel($0), value: facts.counts[$0]!)
            })
        }
    }
    static func summary(_ records: [OperationLogRecord]) -> [String] {
        let safe = records.filter { OperationLogSanitizer.valid($0) }
        var lines = counterGroups(records).map { group in
            group.title + ": " + group.counters.map { "\($0.title): \($0.value)" }.joined(separator: " · ")
        }
        if let failure = safe.last(where: { $0.eventType == "failed" }),
           let reason = failure.runtimeError ?? failure.facts?.codes["code"] ?? failure.facts?.codes["reason"] {
            lines.append("Reason: " + reason)
        }
        if let finish = safe.last(where: { $0.kind == .finish }), let reason = finish.runtimeError,
           !lines.contains("Reason: " + reason) { lines.append("Reason: " + reason) }
        return lines
    }
    static func importantIssues(_ report: OperationLogReport) -> [String] {
        let reasons = Set(summary(report.summaries).filter { $0.hasPrefix("Reason: ") }.map { String($0.dropFirst(8)) })
        let finish = report.summaries.last { $0.kind == .finish }
        let failed = outcome(finish) == "Failed" || report.summaries.contains { $0.kind == .event && $0.eventType == "failed" }
        var lines = Set<String>()
        // Counters remain in the summary. Keep specific Verification limitations
        // here, without repeating generic Errors/Warnings over those findings.
        for key in report.verificationIssues.keys.sorted() {
            if ["error_count", "warning_count"].contains(key), report.verificationIssues.keys.contains(where: {
                ["mismatch_count", "unsupported_count", "unresolved_count", "unverified_count"].contains($0)
            }) { continue }
            lines.insert(report.verificationIssues[key]!)
        }
        for issue in report.issues.keys.sorted() {
            let parts = issue.components(separatedBy: " · ")
            let source = parts.first ?? ""
            let domain = parts.first { OperationLogSanitizer.vocabularies["domain"]?.contains($0) == true }
            let code = parts.last.flatMap { OperationLogSanitizer.reasons.contains($0) ? $0 : nil }
            if domain == nil, ["Execution", "Process"].contains(source) {
                if let code, reasons.contains(code) { continue } // Already explained once in summary.
                if code == nil && failed && parts.dropFirst().flatMap({ $0.components(separatedBy: ", ") }).allSatisfy({ ["Failed", "failed", "failure", "error"].contains($0) }) { continue }
            }
            if source == "Verification", code == nil, domain == nil,
               parts.contains(where: { $0.contains("mismatch") }), report.verificationIssues["mismatch_count"] != nil { continue }
            // Keep domains and Verification/execution sources distinct. Exact
            // repeated records do not imply multiple independent user problems.
            if let code {
                // A reason is one finding per source/domain, even if several
                // records describe its warning/failure at different levels.
                lines.insert([source, domain, code].compactMap { $0 }.joined(separator: " · "))
            } else { lines.insert(issue) }
        }
        return lines.sorted()
    }
    static func diagnosticStatus(incomplete: Bool, truncated: Bool, unavailable: Bool, recording: Bool) -> String {
        unavailable ? "Log unavailable" : truncated ? "Log truncated · Incomplete" : recording ? "Log recording" : incomplete ? "Log incomplete" : "Log complete"
    }
    static func operation(_ value: CoreOperation?) -> String {
        switch value {
        case .capturePrepare: "Capture · Scan and Prepare"
        case .captureExecute: "Capture · Save Environment"
        case .bundleInspect: "Restore · Inspect Environment"
        case .restorePrepare: "Restore · Preview"
        case .restoreExecute: "Restore · Rebuild"
        case .environmentCompare: "Environment Status · Compare"
        default: "Operation"
        }
    }
    static func outcome(_ finish: OperationLogRecord?, active: Bool = false) -> String {
        guard let finish, OperationLogSanitizer.valid(finish), finish.kind == .finish else {
            return active ? "Running" : "Interrupted or Unknown"
        }
        guard finish.terminalValid == true else { return "Interrupted or Unknown" }
        switch finish.eventType {
        case "completed": return "Completed"
        case "cancelled": return "Stopped"
        case "failed": return ["cancelled", "secure_cancelled"].contains(finish.runtimeError ?? "") || finish.exitCode == 130 ? "Stopped" : "Failed"
        default: return "Unknown"
        }
    }
    static func verification(_ finish: OperationLogRecord?) -> String {
        guard let finish, OperationLogSanitizer.valid(finish) else { return "Verification not established" }
        switch finish.verificationStatus {
        case "complete": return finish.detailStatus == "complete" ? "Verification complete" : "Verification complete · Details incomplete"
        case "partial", "truncated", "invalid": return "Verification incomplete"
        case "not_run": return "Verification not run"
        default: return "Verification unavailable"
        }
    }
    static func verificationValue(_ finish: OperationLogRecord?) -> String {
        let full = verification(finish)
        let prefix = "Verification "
        guard full.hasPrefix(prefix) else { return full }
        let value = String(full.dropFirst(prefix.count))
        return value.prefix(1).uppercased() + value.dropFirst()
    }
    static func phase(_ code: String?) -> String? {
        guard let code, OperationLogSanitizer.vocabularies["phase"]?.contains(code) == true else { return nil }
        let names = ["bundle_creation": "Saving Environment", "bundle_validation": "Validating Environment", "bootstrap": "Rebuild",
                     "post_apply": "Checking Changes", "secure_import": "Secure Import", "secure_export": "Secure Export"]
        return names[code] ?? code.replacingOccurrences(of: "_", with: " ").capitalized
    }
    private static func finding(_ record: OperationLogRecord) -> String {
        let values = ([record.facts].compactMap { $0 } + (record.evidence ?? [])).flatMap { $0.codes.values }
        let findings = ["failed", "failure", "warning", "mismatch", "unsupported", "unresolved", "skipped"].filter { values.contains($0) }
        return findings.isEmpty ? "" : " · " + findings.map { $0.capitalized }.joined(separator: ", ")
    }
    static func title(_ record: OperationLogRecord) -> String {
        guard OperationLogSanitizer.valid(record) else { return "Unavailable Event" }
        if record.kind == .header { return "Operation Started" }
        if record.kind == .finish { return "Process Result · " + outcome(record) }
        if let client = record.client {
            switch client {
            case .gracefulStopDelivered: return "Graceful Stop Request Delivered"
            case .gracefulStopDeliveryFailed: return "Graceful Stop Request Unavailable"
            case .forceStopRequested: return "Force Stop Requested"
            case .eventSkipped: return "Some Diagnostic Evidence Was Omitted"
            case .truncated: return "Log Limit Reached"
            }
        }
        switch record.eventType {
        case "started": return "Core Operation Started"
        case "phase_started": return "Phase Started"
        case "phase_completed": return "Phase Finished"
        case "capture_category": return "Capture Category Checked"
        case "verification_record": return "Verification Evidence" + finding(record)
        case "coverage_record": return "Scope Coverage" + finding(record)
        case "diagnostic_record": return "Diagnostic Finding"
        case "operation_record": return "Operation Evidence" + finding(record)
        case "execution_event":
            switch record.facts?.codes["state"] {
            case "graceful_stop_accepted": return "Core Accepted Graceful Stop"
            case "graceful_stop_unavailable": return "Core Could Not Accept Graceful Stop"
            case "failed": return "Step Failed"
            case "warning": return "Step Needs Attention"
            case "changed": return "Step Changed State"
            case "already_satisfied": return "Step Already Matches"
            default: return "Execution Progress"
            }
        case "result": return "Core Result Evidence"
        case "completed": return "Core Reported Completion"
        case "cancelled": return "Core Reported Cancellation"
        case "failed": return record.facts?.codes["code"] == "cancelled" ? "Core Reported Cancellation" : "Core Reported Failure"
        case "secret_required": return "Secure Input Requested"
        case "secret_accepted": return "Secure Input Accepted"
        case "secure_packaging": return "Secure Packaging Status"
        case "secure_publication_started": return "Secure Publication Started"
        default: return "Structured Event"
        }
    }
    static func tone(_ record: OperationLogRecord) -> RestoreStatusTone {
        guard OperationLogSanitizer.valid(record) else { return .warning }
        let facts = [record.facts].compactMap { $0 } + (record.evidence ?? [])
        if facts.contains(where: { $0.codes["severity"] == "error" || $0.codes["outcome"] == "failure" || $0.codes["state"] == "failed" }) { return .error }
        if record.client == .gracefulStopDeliveryFailed ||
            facts.contains(where: { $0.codes["severity"] == "warning" || $0.codes["outcome"] == "warning" || $0.codes["conformity"] == "unverified" }) { return .warning }
        if record.kind == .finish && ["Stopped", "Completed"].contains(outcome(record)) { return .neutral }
        if record.eventType == "failed", !["cancelled", "secure_cancelled"].contains(record.facts?.codes["code"] ?? "") { return .error }
        return .neutral
    }
    static func details(_ record: OperationLogRecord) -> [String] {
        guard OperationLogSanitizer.valid(record) else { return ["Diagnostic evidence is unavailable."] }
        var details: [String] = []
        if record.kind == .event, let sequence = record.sequence { details.append("Core sequence: \(sequence)") }
        for facts in [record.facts].compactMap({ $0 }) + (record.evidence ?? []) {
            details += facts.codes.keys.sorted().compactMap { key in facts.codes[key].map { key + ": " + $0 } }
            details += facts.counts.keys.sorted().compactMap { key in facts.counts[key].map { key + ": " + String($0) } }
            details += facts.flags.keys.sorted().compactMap { key in facts.flags[key].map { key + ": " + String($0) } }
            details += facts.references.keys.sorted().compactMap { key in facts.references[key].map { key + ": " + $0 } }
        }
        if let code = record.runtimeError { details.append("Transport/Core reason: " + code) }
        if let exit = record.exitCode { details.append("Process exit: \(exit)") }
        if let signal = record.signalNumber { details.append("Process signal: \(signal)") }
        if let valid = record.terminalValid { details.append("Validated terminal: \(valid)") }
        if let count = record.droppedEvents, count > 0 { details.append("Omitted events: \(count)") }
        if record.omitted == true { details.append("Some fields or evidence were omitted.") }
        return details
    }
    static func hasDetails(_ record: OperationLogRecord) -> Bool {
        if !OperationLogSanitizer.valid(record) { return true }
        if record.kind == .event && record.sequence != nil { return true }
        let facts = [record.facts].compactMap { $0 } + (record.evidence ?? [])
        return facts.contains { !$0.codes.isEmpty || !$0.counts.isEmpty || !$0.flags.isEmpty || !$0.references.isEmpty } ||
            record.runtimeError != nil || record.exitCode != nil || record.signalNumber != nil || record.terminalValid != nil ||
            (record.droppedEvents ?? 0) > 0 || record.omitted == true
    }
}

struct OperationLogHistoryList: View {
    let entries: [OperationLogHistory]
    let activeID: UUID?
    let selectedID: UUID?
    let select: (UUID) -> Void
    static func sorted(_ entries: [OperationLogHistory]) -> [OperationLogHistory] {
        entries.sorted {
            if $0.header.time != $1.header.time { return $0.header.time > $1.header.time }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
    var body: some View {
        let sorted = Self.sorted(entries)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(sorted, id: \.id) { entry in
                Button { select(entry.id) } label: {
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(OperationLogPresentation.operation(entry.header.operation)).font(.callout.weight(.medium))
                            Text(entry.header.time, format: .dateTime.year().month().day().hour().minute().second())
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 4) {
                            Text(OperationLogPresentation.outcome(entry.finish, active: entry.id == activeID)).font(.callout)
                            Text(entry.id == activeID ? "Recording" : entry.incomplete ? "Incomplete log" : "Complete log")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if entry.id == selectedID { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor) }
                    }.padding(12).background(entry.id == selectedID ? Color.accentColor.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 8)).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier(entry.id.uuidString)
                if entry.id != sorted.last?.id { Divider() }
            }
        }
    }
}

// Summary-only formatting; the source projection and Important/All stay intact.
enum OperationLogSummaryPresentation {
    struct Row: Identifiable { let id: String; let title: String; let value: String }
    static func rows(finish: OperationLogRecord?, active: Bool, records: [OperationLogRecord]) -> [Row] {
        let process = OperationLogPresentation.outcome(finish, active: active)
        var rows = [Row(id: "process", title: "Process Result", value: process == "Stopped" ? "Cancelled" : process)]
        let verification = OperationLogPresentation.verificationValue(finish)
        let status: String
        switch verification {
        case "Not run": status = "Not Run"
        case "Not established", "Unavailable": status = "Unknown"
        default: status = verification
        }
        rows.append(Row(id: "verification", title: "Verification", value: status))
        let groups = OperationLogPresentation.counterGroups(records)
        func counters(_ group: OperationLogCounterGroup?, keys: [String]) -> [String] {
            keys.compactMap { key in
                group?.counters.first { $0.id == key }.map { "\($0.title): \($0.value.formatted())" }
            }
        }
        // Prefer the actual terminal/result source, never Verification totals for
        // execution counts and never add overlapping summary values together.
        let terminalType = records.last { OperationLogSanitizer.valid($0) && $0.kind == .event && ["completed", "failed", "cancelled"].contains($0.eventType ?? "") }?.eventType
        let execution = terminalType.flatMap { type in groups.first { $0.id == type } }
            ?? groups.first { $0.id == "result" }
            ?? groups.first { $0.id == "summary" }
        let executionCounts = counters(execution, keys: ["error_count", "warning_count"])
        if !executionCounts.isEmpty {
            rows.append(Row(id: "execution", title: "Execution", value: executionCounts.joined(separator: " · ")))
        }
        let verificationGroup = groups.first { $0.id == "verification" }
        var verificationCounts = counters(verificationGroup,
            keys: ["verified_count", "unverified_count", "mismatch_count", "unresolved_count", "warning_count", "selected_count"])
        if verificationGroup?.counters.contains(where: { $0.id == "selected_count" }) != true {
            // Selected items and areas are separate known quantities, not a
            // guessed total of verified requirements.
            let selection = groups.first { $0.id == "summary" } ?? execution
            verificationCounts += counters(selection, keys: ["selected_count", "selected_items", "selected_domains"])
        }
        if !verificationCounts.isEmpty {
            rows.append(Row(id: "counters", title: "Verification counters", value: verificationCounts.joined(separator: " · ")))
        }
        let reasons = OperationLogPresentation.summary(records).filter { $0.hasPrefix("Reason: ") }.map { String($0.dropFirst(8)) }
        if !reasons.isEmpty { rows.append(Row(id: "reason", title: "Reason", value: reasons.joined(separator: " · "))) }
        return rows
    }
}

struct OperationLogResultSummary: View {
    let finish: OperationLogRecord?
    let active: Bool
    let incomplete: Bool
    let truncated: Bool
    let unavailable: Bool
    var records: [OperationLogRecord] = []
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                ForEach(OperationLogSummaryPresentation.rows(finish: finish, active: active, records: records)) { row in
                    GridRow(alignment: .top) {
                        Text(row.title + ":").foregroundStyle(.secondary).fixedSize()
                        Text(row.value).monospacedDigit().fixedSize(horizontal: false, vertical: true)
                    }
                }
            }.font(.callout).frame(maxWidth: 560, alignment: .leading)
            let recording = active && finish?.kind == nil
            let limitation = unavailable || truncated || (incomplete && !recording)
            Text(OperationLogPresentation.diagnosticStatus(incomplete: incomplete, truncated: truncated,
                unavailable: unavailable, recording: recording) + (limitation ? " — Only saved diagnostics are available." : ""))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct OperationLogStopRequest {
    enum Mode { case graceful, force, cancel }
    let operationID: String
    let mode: Mode
    @MainActor func perform(on runtime: CoreRuntime) {
        guard runtime.isActive, runtime.operationID == operationID, !runtime.stopping else { return }
        if mode == .graceful {
            guard runtime.operation == .restoreExecute else { return }
            runtime.requestGracefulStop()
        } else { runtime.cancel() }
    }
}

// Native sheets block the parent's footer. These invoke the same Runtime control
// paths, with confirmation bound to the operation that was active when requested.
struct OperationLogStopControls: View {
    @ObservedObject var runtime: CoreRuntime
    @LogViewState private var pending: OperationLogStopRequest?
    var body: some View {
        HStack(spacing: 12) {
            if runtime.isActive, let id = runtime.operationID {
                if runtime.operation == .restoreExecute {
                    Button("Stop Rebuild") { pending = OperationLogStopRequest(operationID: id, mode: .graceful) }
                        .disabled(runtime.stopping || runtime.gracefulStopRequested)
                    Button("Force Stop", role: .destructive) { pending = OperationLogStopRequest(operationID: id, mode: .force) }
                        .tint(.red).foregroundStyle(.red).disabled(runtime.stopping)
                } else if runtime.operation != .capabilities {
                    Button("Cancel Operation", role: .cancel) { pending = OperationLogStopRequest(operationID: id, mode: .cancel) }
                        .disabled(runtime.stopping)
                }
                if runtime.stopping { ProgressView().controlSize(.small); Text("Stopping…").foregroundStyle(.secondary) }
                else if runtime.gracefulStopRequested { Text("Waiting for the current item…").foregroundStyle(.secondary) }
            }
        }.font(.callout)
        .sheet(isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            VStack(alignment: .leading, spacing: 16) {
                let force = pending?.mode == .force
                Text(force ? "Force Stop Rebuild?" : pending?.mode == .graceful ? "Stop rebuilding?" : "Cancel operation?")
                    .font(.title2).accessibilityAddTraits(.isHeader)
                Text(force ? "Force Stop will interrupt the current operation. This may leave some changes incomplete and require additional steps before rebuilding again." : pending?.mode == .graceful ? "Rebuild is still in progress. Stopping it may leave some changes already applied to this Mac. A fresh Restore Preview will be required before another Rebuild." : runtime.operation == .captureExecute ? "Once saving begins, stopping does not promise that a published file will be removed." : "Cancel the current inspection? You can start a fresh operation afterward.")
                HStack {
                    Button("Continue Operation") { pending = nil }.keyboardShortcut(.defaultAction)
                    Button(force ? "Force Stop" : pending?.mode == .graceful ? "Stop Rebuild" : "Cancel Operation", role: force ? .destructive : nil) {
                        let request = pending; pending = nil; request?.perform(on: runtime)
                    }.tint(force ? .red : .accentColor)
                }
            }.padding(24).frame(width: 420).interactiveDismissDisabled().onExitCommand { pending = nil }
        }
    }
}

// The caller supplies a bounded transient projection from the existing store.
// This view owns only disclosure/confirmation state; it does not own a history.
struct OperationLogView: View {
    @ObservedObject var runtime: CoreRuntime
    let history: [OperationLogHistory]
    let records: [OperationLogRow]
    let selectedID: UUID?
    let activeID: UUID?
    let finish: OperationLogRecord?
    let incomplete: Bool
    let truncated: Bool
    let unavailable: Bool
    let hasMore: Bool
    let earlierEvents: Bool
    let clearing: Bool
    let following: Bool
    var report = OperationLogReport()
    let select: (UUID) -> Void
    let loadMore: () -> Void
    let readBeginning: () -> Void
    let readLatest: () -> Void
    let refreshHistory: () -> Void
    let clearLogs: () -> Void
    var initiallyExpandedDetails = false
    var initiallyAllEvents = false
    @LogViewState private var mode = OperationLogTimelineMode.important
    @LogViewState private var expandedHistory = false
    @LogViewState private var clearConfirmation = false
    @LogViewState private var diagnosticRequest: DiagnosticReportRequest?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            OperationLogStopControls(runtime: runtime)
            if let message = runtime.gracefulStopMessage { Text(message).font(.callout).foregroundStyle(.secondary) }
            ScrollView {
                // The existing 512-event window bounds this stack. Avoid lazy
                // placement caches for rows whose disclosures change height.
                VStack(alignment: .leading, spacing: 16) {
                    DisclosureGroup("Previous Operations", isExpanded: $expandedHistory) {
                        if history.isEmpty { Text("No saved operation logs.").foregroundStyle(.secondary) }
                        else { OperationLogHistoryList(entries: history, activeID: activeID, selectedID: selectedID, select: select) }
                    }.disclosureGroupStyle(HeaderDisclosureStyle())
                    if selectedID != nil {
                        if let entry = history.first(where: { $0.id == selectedID }) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(OperationLogPresentation.operation(entry.header.operation)).font(.headline)
                                    .accessibilityIdentifier("operation-log-current-" + entry.id.uuidString)
                                Text(entry.header.time, format: .dateTime.year().month().day().hour().minute().second()).foregroundStyle(.secondary)
                            }
                        }
                        OperationLogResultSummary(finish: report.summaries.last(where: { $0.kind == .finish }) ?? finish, active: selectedID == activeID, incomplete: incomplete || report.incomplete || report.damaged, truncated: truncated || report.truncated, unavailable: unavailable || report.unavailable, records: report.summaries + (finish.map { [$0] } ?? []))
                        Picker("Events", selection: $mode) {
                            Text("Important").tag(OperationLogTimelineMode.important)
                            Text("All").tag(OperationLogTimelineMode.all)
                        }.pickerStyle(.segmented)
                        if mode == .important {
                            OperationLogImportantView(report: report)
                            Button("Show All Events") { mode = .all }
                        } else {
                            if earlierEvents {
                                Text("This is a bounded page. Earlier saved events remain accessible from the beginning.").font(.caption).foregroundStyle(.secondary)
                                Button("Read From Beginning", action: readBeginning)
                            }
                            if !following { Button("Show Latest Events", action: readLatest) }
                            ForEach(OperationLogPresentation.timeline(records, mode: .all)) { group in
                                OperationLogEventGroup(group: group, initiallyExpandedDetails: initiallyExpandedDetails)
                                Divider()
                            }
                            if hasMore { Button("Load More Events", action: loadMore) }
                        }
                    } else if unavailable { Text("Operation logs are unavailable.").foregroundStyle(.orange) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Button { refreshHistory() } label: { Label("Refresh History", systemImage: "arrow.clockwise") }.controlSize(.small)
                Button("Diagnostic Report") {
                    if let selectedID { diagnosticRequest = DiagnosticReportRequest(id: selectedID) }
                }.disabled(selectedID == nil)
                Spacer()
                Button("Clear Logs", role: .destructive) { clearConfirmation = true }.disabled(history.isEmpty || clearing)
            }
        }.padding(24).frame(minWidth: 680, minHeight: 480)
        .onAppear { if selectedID == nil { expandedHistory = true }; if initiallyAllEvents { mode = .all } }
        .sheet(item: $diagnosticRequest) { request in
            DiagnosticReportView(id: request.id, store: runtime.operationLogStore)
        }
        .alert("Clear Operation Logs?", isPresented: $clearConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Clear Logs", role: .destructive, action: clearLogs)
        } message: {
            Text("Delete saved inactive operation logs. Active logs will be kept.")
        }
    }
}

private struct DiagnosticReportRequest: Identifiable {
    let id: UUID
}

struct OperationLogImportantView: View {
    let report: OperationLogReport
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if report.loading { ProgressView("Reading important events across the saved log…") }
            if report.unavailable { Text("Important events unavailable. Their absence is not a successful result.").foregroundStyle(.orange) }
            let issues = OperationLogPresentation.importantIssues(report)
            if !issues.isEmpty || report.overflow > 0 {
                Text("Needs Attention / Issues").font(.headline)
                ForEach(issues, id: \.self) { issue in
                    Text(issue).font(.callout).foregroundStyle(.orange)
                }
                if report.overflow > 0 { Text("\(report.overflow) additional issue events. Inspect All for every saved detail.") }
            }
            // Key events are a bounded report, not hundreds of evidence rows.
            ForEach(Array(report.keys.enumerated()), id: \.offset) { _, record in
                HStack {
                    Text(record.time, format: .dateTime.hour().minute().second()).foregroundStyle(.secondary)
                    Text(OperationLogPresentation.title(record)).foregroundStyle(OperationLogPresentation.tone(record).color)
                    if let phase = OperationLogPresentation.phase(record.facts?.codes["phase"]) { Text(phase).foregroundStyle(.secondary) }
                }.font(.callout)
            }
            if report.keyOverflow > 0 { Text("Earlier phase events are available in All.").font(.caption) }

        }
    }
}
struct OperationLogEventGroup: View {
    let group: OperationLogTimelineGroup
    let initiallyExpandedDetails: Bool
    @LogViewState private var expanded: Bool
    init(group: OperationLogTimelineGroup, initiallyExpandedDetails: Bool = false) {
        self.group = group; self.initiallyExpandedDetails = initiallyExpandedDetails
        _expanded = LogViewState(initialValue: initiallyExpandedDetails)
    }
    var body: some View {
        if group.rows.count > 1 {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(group.rows) { row in OperationLogEventRow(record: row.record, initiallyExpanded: initiallyExpandedDetails) }
                }
            } label: {
                Text(OperationLogPresentation.title(group.rows[0].record) + " · \(group.rows.count) events · Core \(group.rows.first?.record.sequence ?? 0)–\(group.rows.last?.record.sequence ?? 0)")
            }.disclosureGroupStyle(HeaderDisclosureStyle())
        } else if let row = group.rows.first { OperationLogEventRow(record: row.record, initiallyExpanded: initiallyExpandedDetails) }
    }
}

struct OperationLogEventRow: View {
    let record: OperationLogRecord
    @LogViewState private var expanded: Bool
    init(record: OperationLogRecord, initiallyExpanded: Bool = false) {
        self.record = record
        _expanded = LogViewState(initialValue: initiallyExpanded)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(record.time, format: .dateTime.hour().minute().second()).monospacedDigit().foregroundStyle(.secondary)
                Text(OperationLogPresentation.title(record)).fontWeight(.medium)
                    .foregroundStyle(OperationLogPresentation.tone(record).color)
                Spacer(minLength: 0)
                if let phase = OperationLogPresentation.phase(record.facts?.codes["phase"]) {
                    Text(phase).foregroundStyle(.secondary)
                }
            }.font(.callout)
            if OperationLogPresentation.hasDetails(record) {
                DisclosureGroup("Technical Details", isExpanded: $expanded) {
                    if expanded { OperationLogDetailPage(details: OperationLogPresentation.details(record)) }
                }.disclosureGroupStyle(TaskDisclosureStyle(minimumHeight: 22)).font(.caption)
            }
        }.padding(.vertical, 10)
    }
}

// One expanded row must not create hundreds of selectable Text layouts inside
// the timeline. Pages replace their contents instead of accumulating.
struct OperationLogDetailPage: View {
    static let pageSize = 40
    static func height(_ lines: [String]) -> CGFloat {
        // Arithmetic only: no TextKit measurement/layout feedback into SwiftUI.
        let wrappedLines = lines.reduce(0) { $0 + max(1, ($1.count + 69) / 70) }
        return CGFloat(min(220, max(22, wrappedLines * (wrappedLines <= 8 ? 14 : 16) + 8)))
    }
    @MainActor static func copy(_ details: [String], to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(details.joined(separator: "\n"), forType: .string)
    }
    let details: [String]
    @LogViewState private var page = 0
    static func range(count: Int, page: Int) -> Range<Int> {
        let start = min(max(0, page), max(0, count - 1) / pageSize) * pageSize
        return start..<min(count, start + pageSize)
    }
    var body: some View {
        let range = Self.range(count: details.count, page: page)
        VStack(alignment: .leading, spacing: 4) {
            if details.count > Self.pageSize {
                HStack {
                    Text("Details \(range.lowerBound + 1)–\(range.upperBound) of \(details.count)").foregroundStyle(.secondary)
                    Spacer()
                    Button("Previous") { page = max(0, page - 1) }.disabled(range.lowerBound == 0)
                    Button("Next") { page += 1 }.disabled(range.upperBound == details.count)
                }.font(.caption)
            }
            Button("Copy Details") { Self.copy(details) }.font(.caption)
                .help("Copy all sanitized details of this event, including every page.")
            OperationLogDetailText(text: details[range].joined(separator: "\n"))
                .frame(height: Self.height(Array(details[range])))
        }
    }
}

// TextKit owns selection and internal scrolling. A bounded viewport keeps changes
// to text/pagination out of SwiftUI's row measurement graph.
private struct OperationLogDetailText: NSViewRepresentable {
    let text: String
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 220))
        view.isEditable = false; view.isSelectable = true; view.isRichText = false
        view.setAccessibilityLabel("Operation event details")
        view.drawsBackground = false; view.textColor = .labelColor
        view.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.minSize = .zero; view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: 700, height: CGFloat.greatestFiniteMagnitude)
        view.textContainerInset = NSSize(width: 4, height: 4)
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        if view.string != text {
            view.string = text
            view.setSelectedRange(NSRange(location: 0, length: 0))
            scroll.contentView.scroll(to: .zero)
        }
    }
}
