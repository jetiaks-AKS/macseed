import Combine
import Foundation

enum RestoreFlowState { case choose, inspecting, preparing, review, preview, confirming, rebuilding, result, failed, cancelled }

struct RestorePreviewPresentation {
    let categories: [DisplayCategory]
    let summary: String
    let sections: [Section]
    struct Section: Identifiable {
        let id: String
        let rows: [DisplayCategory]
    }
    static func readyText(action: String) -> String {
        switch action {
        case "install", "reinstall": "Ready to Install"
        case "set_setting", "set_preference", "switch_branch": "Ready to Change"
        case "create_directory", "create": "Ready to Create"
        default: "Ready to Restore"
        }
    }
    static func state(_ row: DisplayCategory) -> String {
        if row.items.isEmpty || row.items.contains(where: { ![DisplayStatus.matching, .ready].contains($0.status) }) { return "Needs Attention" }
        return row.items.contains { $0.status == .ready } ? "Changes Planned" : "Already Matches"
    }
    static func summary(changes: Int, matches: Int, attention: Int) -> String {
        "\(changes) \(changes == 1 ? "change" : "changes") · \(matches) already \(matches == 1 ? "matches" : "match") · \(attention) \(attention == 1 ? "needs" : "need") attention"
    }
    init(_ prepared: CoreRestorePreparation, catalog: CoreRestoreInspection.Inventory) {
        var rows: [String: [DisplayItem]] = [:]
        var order: [String] = []
        for (index, row) in prepared.plan.enumerated() {
            if rows[row.domain] == nil { order.append(row.domain) }
            let status: DisplayStatus
            let message: String
            switch row.disposition {
            case "satisfied": status = .matching; message = "Already Matches"
            case "planned":
                status = .ready
                switch row.action {
                case "install": message = "Will install"
                case "clone": message = "Will clone repository"
                case "switch_branch": message = "Will switch branch"
                case "restart_process": message = "Will restart affected process"
                case "replace_with_backup": message = "Will replace with backup"
                case "create_directory", "create": message = "Will create"
                case "set_setting", "set_preference": message = "Will restore setting"
                case "reinstall": message = "Will reinstall"
                default: message = "Will Restore"
                }
            case "conflict": status = .attention; message = "Conflict: existing state differs from this requirement."
            case "blocked": status = .attention; message = "This requirement cannot currently be restored."
            case "warning": status = .attention; message = "This requirement needs attention."
            default: status = .unverified; message = "This requirement could not be inspected reliably."
            }
            let reasonMessage: String?
            switch row.reason {
            case "partial_source_coverage": reasonMessage = "The saved SSH configuration covers only part of the source configuration."
            case "source_absent": reasonMessage = "No SSH configuration was captured in this saved environment."
            case "source_excluded": reasonMessage = "The captured SSH configuration is not eligible for restoration."
            case "observation_failed": reasonMessage = "Current state could not be inspected reliably."
            case "target_conflict": reasonMessage = "Conflict: existing state differs from the saved environment and will be preserved."
            default: reasonMessage = nil
            }
            let inventoryLabel = row.selectionItemID.flatMap { id in catalog.inventory.first { $0.id == row.domain }?.items.first { $0.id == id }?.label }
            let title = inventoryLabel ?? row.displayName ?? (row.itemID.hasPrefix("opaque:") ? "Private item" : (row.itemID == "scope" ? "Selected area" : row.itemID))
            rows[row.domain, default: []].append(DisplayItem(id: "restore-\(index)", title: title, status: status, action: reasonMessage ?? message, reason: row.reason, restoreReadyText: status == .ready ? Self.readyText(action: row.action) : nil))
        }
        categories = order.map { domain in
            DisplayCategory(id: domain, title: catalog.inventory.first { $0.id == domain }?.label ?? "Other supported state", symbol: "slider.horizontal.3", items: rows[domain] ?? [])
        }
        let planned = prepared.plan.filter { $0.disposition == "planned" }.count
        let satisfied = prepared.plan.filter { $0.disposition == "satisfied" }.count
        let attention = prepared.plan.filter { !["planned", "satisfied"].contains($0.disposition) }.count
        summary = Self.summary(changes: planned, matches: satisfied, attention: attention)
        let domainRows = categories
        sections = RestorePresentationSection.project(catalog.groups).compactMap { section in
            var projected: [DisplayCategory] = []
            for group in section.groups {
                if group.id == "macOS Settings" {
                    let selected = domainRows.filter { group.domains.contains($0.id) }
                    if !selected.isEmpty {
                        projected.append(DisplayCategory(id: group.id, title: group.id, symbol: "slider.horizontal.3",
                            items: selected.flatMap { category in category.items.map { item in
                                DisplayItem(id: item.id, title: category.title + " · " + item.title, status: item.status, action: item.action, reason: item.reason, restoreReadyText: item.restoreReadyText)
                            } }))
                    }
                }
            }
            projected += section.areas(in: catalog.inventory).filter { area in
                !section.groups.contains { $0.id == "macOS Settings" && $0.domains.contains(area.id) }
            }.compactMap { area in domainRows.first { $0.id == area.id } }
            return projected.isEmpty ? nil : Section(id: section.id, rows: projected)
        }
    }
}

// Operation-local presentation scope. Only domain scope completion confirms a whole row.
struct RestoreProgressRow {
    let id: String
    let title: String
    let domains: Set<String>
    let hasAttention: Bool
    let itemNames: [String: [String: String]]

    static func freeze(preview: RestorePreviewPresentation, plan: CoreRestorePreparation) -> [Self] {
        preview.sections.flatMap(\.rows).compactMap { row in
            let itemIDs = Set(row.items.map(\.id))
            let rowDomains = Set(preview.categories.filter { category in
                category.items.contains { itemIDs.contains($0.id) }
            }.map(\.id))
            let relevant = plan.plan.filter { rowDomains.contains($0.domain) && $0.disposition != "satisfied" }
            guard !relevant.isEmpty else { return nil }
            var names: [String: [String: String]] = [:]
            for (index, entry) in plan.plan.enumerated() where rowDomains.contains(entry.domain) {
                guard entry.itemID != "scope", !entry.itemID.hasPrefix("opaque:"),
                      let item = preview.categories.flatMap(\.items).first(where: { $0.id == "restore-\(index)" }),
                      item.title != "Private item" else { continue }
                names[entry.domain, default: [:]][entry.itemID] = item.title
            }
            return Self(id: row.id, title: row.title, domains: Set(relevant.map(\.domain)),
                        hasAttention: relevant.contains { $0.disposition != "planned" }, itemNames: names)
        }
    }
    func project(events: [CoreEvent]) -> DisplayItem {
        var states: [String: DisplayStatus] = [:]
        var active: [String: (id: String, text: String)] = [:]
        for event in events where ["execution_event", "operation_record"].contains(event.type) {
            guard let domain = event.data?["domain"]?.string,
                  let state = event.data?["state"]?.string ?? event.data?["outcome"]?.string else { continue }
            // Workspace's production module owns both folders and repositories.
            let targets = domain == "workspace" ? domains.intersection(["workspace-folders", "git-repositories"]) : domains.intersection([domain])
            for target in targets {
                let itemID = event.data?["item_id"]?.string
                if event.type == "operation_record" {
                    if active[target]?.id == itemID { active[target] = nil }
                    if state == "failure" || (state == "skipped" && ["dependency_failed", "cask_execution_requirements_unsupported"].contains(event.data?["reason"]?.string ?? "")) { states[target] = .attention }
                    continue
                }
                if state == "applying" {
                    active[target] = nil
                    if let itemID, let name = itemNames[target]?[itemID],
                       let action = event.data?["action"]?.string {
                        let verb: String?
                        switch action {
                        case "install", "reinstall": verb = "Installing"
                        case "set_setting", "set_preference": verb = "Restoring"
                        case "create", "create_directory": verb = "Creating"
                        case "clone": verb = "Cloning"
                        default: verb = nil
                        }
                        if let verb { active[target] = (itemID, "\(verb) \(name)…") }
                    }
                } else if itemID == "scope" || active[target]?.id == itemID {
                    active[target] = nil
                }
                if ["warning", "failed", "conflict", "blocked", "cancelled", "interrupted"].contains(state) {
                    states[target] = .attention
                } else if states[target] != .attention {
                    if ["changed", "already_satisfied", "satisfied"].contains(state), event.data?["item_id"]?.string == "scope" {
                        states[target] = .complete
                    } else if ["started", "applying", "verifying", "changed", "already_satisfied", "satisfied"].contains(state), states[target] != .complete {
                        states[target] = .working
                    }
                }
            }
        }
        let status: DisplayStatus
        if hasAttention || states.values.contains(.attention) { status = .attention }
        else if domains.allSatisfy({ states[$0] == .complete }) { status = .complete }
        else if states.values.contains(.working) || states.values.contains(.complete) { status = .working }
        else { status = .waiting }
        let activity = domains.sorted().compactMap { active[$0]?.text }.joined(separator: "\n")
        return DisplayItem(id: id, title: title, status: status,
                           action: status == .complete ? "OK" : status == .working ? "Working…" : status == .attention ? "Needs Attention" : "Waiting",
                           restoreActivity: !activity.isEmpty ? activity : nil)
    }
    static func phase(events: [CoreEvent], mutationPossible: Bool) -> String {
        if events.contains(where: { $0.data?["domain"]?.string == "verification" || $0.phase == "verification" }) {
            return "Verifying restored environment…"
        }
        return mutationPossible ? "Applying your saved environment…" : "Preparing rebuild…"
    }
}

@MainActor final class RestoreModel: ObservableObject {
    static let shared = RestoreModel(runtime: .shared)
    @Published private(set) var state: RestoreFlowState = .choose
    @Published private(set) var source: URL?
    @Published private(set) var inspection: CoreRestoreInspection?
    @Published private(set) var selectedCategories: Set<String> = []
    @Published private(set) var selectedItems: [String: Set<String>] = [:]
    @Published private(set) var preparation: CoreRestorePreparation?
    @Published private(set) var preview: RestorePreviewPresentation?
    @Published private(set) var executionResult: RestoreExecutionPresentation?
    // Retained presentation inputs only; prepared-plan authorization still uses preparation.
    @Published private(set) var executionPreview: RestorePreviewPresentation?
    @Published private(set) var executionPlan: CoreRestorePreparation?
    @Published private(set) var executionStartedAt: Date?
    @Published private(set) var executionFinishedAt: Date?
    @Published var stopConfirmation = false
    @Published private(set) var failure: String?
    @Published private(set) var technicalReason: String?
    let runtime: CoreRuntime
    private let location: CoreLocation?
    private var work: Task<Void, Never>?
    private var cancelRequested = false
    var busy: Bool { state == .inspecting || state == .preparing || state == .confirming || state == .rebuilding }
    var areas: [CoreRestoreInspection.Area] { inspection?.restoreSelection?.inventory ?? [] }
    var groups: [CoreRestoreInspection.Group] { inspection?.restoreSelection?.groups ?? [] }
    var selection: CoreRestoreSelection {
        let whole = areas.filter { $0.selectionMode == "items" && selectionState($0) == .all }.map(\.id)
        return CoreRestoreSelection(categories: selectedCategories.union(whole).sorted(),
            items: selectedItems.filter { !$0.value.isEmpty && !whole.contains($0.key) }.mapValues { $0.sorted() })
    }
    var canonicalSelection: CoreRestoreSelection {
        CoreRestoreSelection(categories: selectedCategories.sorted(), items: selectedItems.filter { !$0.value.isEmpty }.mapValues { $0.sorted() })
    }
    var selectedAreaCount: Int { selectedCategories.count + selectedItems.filter { !$0.value.isEmpty }.count }
    var selectedItemCount: Int { selectedItems.values.reduce(0) { $0 + $1.count } }
    var selectionSummary: String {
        switch bulkState {
        case .all: "Everything selected"
        case .mixed: "Some items excluded"
        case .none: "Nothing selected"
        }
    }
    var bulkState: SelectionState {
        let available = areas.filter(\.selectable)
        if !available.isEmpty && available.allSatisfy({ selectionState($0) == .all }) { return .all }
        return selectedAreaCount == 0 ? .none : .mixed
    }
    var canPreview: Bool { !busy && !runtime.isActive && selectedAreaCount > 0 && source != nil && inspection != nil }
    var ready: Bool {
        guard state == .preview, let plan = preparation, plan.readiness.ready, plan.errorCount == 0 else { return false }
        return !plan.plan.contains { row in
            // A conflict with no proposed action is retained by the existing
            // consumer; environmental blockers are owned by Core readiness.
            if row.disposition == "conflict" && row.action == "none" { return false }
            return ["conflict", "blocked", "unknown", "pending_unlock"].contains(row.disposition) && !plan.isItemLocalSkip(row)
        }
    }
    init(runtime: CoreRuntime, location: CoreLocation? = nil) { self.runtime = runtime; self.location = location }
    var canRebuild: Bool {
        ready && !runtime.isActive && preparation?.hasExecutableChanges == true
            && preparation?.selection == canonicalSelection
    }
    var mutationPossible: Bool {
        runtime.mutationMayHaveStarted == true || runtime.events.contains { $0.phase == "bootstrap" || $0.type == "execution_event" }
    }
    private var progressScope: [RestoreProgressRow] = []
    var activity: String {
        RestoreProgressRow.phase(events: runtime.events, mutationPossible: mutationPossible)
    }
    var executionActivities: [DisplayItem] {
        progressScope.map { $0.project(events: runtime.events) }
    }
    func requestRebuild() {
        guard canRebuild else { return }
        state = .confirming
    }
    func cancelRebuildConfirmation() { if state == .confirming { state = .preview } }
    func confirmRebuild() {
        guard state == .confirming, !runtime.isActive, let source, let plan = preparation, let preview,
              plan.readiness.ready, plan.errorCount == 0, plan.hasExecutableChanges, plan.selection == canonicalSelection else { return }
        let request = CoreRequest(.restoreExecute(path: source.path, disabledGroups: [], includeSecure: false,
                                                preparedID: plan.preparedPlanID, selection: selection))
        progressScope = RestoreProgressRow.freeze(preview: preview, plan: plan)
        executionPreview = preview; executionPlan = plan
        executionStartedAt = Date(); executionFinishedAt = nil
        executionResult = nil; stopConfirmation = false; state = .rebuilding
        // Start synchronously so a second activation cannot launch another operation.
        runtime.start(request, location: location)
        work = Task {
            await runtime.waitForCompletion()
            executionFinishedAt = Date()
            let terminal = runtime.termination?.terminal
            let payload = runtime.latestResult?.data ?? terminal?.data
            let names = progressScope.reduce(into: [String: [String: String]]()) { result, row in
                result.merge(row.itemNames) { previous, _ in previous }
            }
            executionResult = RestoreExecutionPresentation(runtime: runtime, payload: payload, expectedID: plan.preparedPlanID, catalog: inspection?.restoreSelection, itemNames: names)
            invalidate(); state = .result
        }
    }
    func requestStop() {
        guard state == .rebuilding, runtime.isActive else { return }
        if mutationPossible { stopConfirmation = true } else { runtime.cancel() }
    }
    func confirmStop() {
        guard state == .rebuilding else { return }
        stopConfirmation = false; runtime.cancel()
    }
    func checkCurrentState() {
        guard state == .result, !runtime.isActive else { return }
        state = .review; executionResult = nil; refreshPreview()
    }
    func finish() {
        guard state == .result, !runtime.isActive else { return }
        invalidate(); progressScope = []; executionResult = nil; inspection = nil; source = nil
        executionPreview = nil; executionPlan = nil; executionStartedAt = nil; executionFinishedAt = nil
        selectedCategories = []; selectedItems = [:]; state = .choose
    }
    func selectionState(_ area: CoreRestoreInspection.Area) -> SelectionState {
        guard area.selectable else { return .none }
        return area.selectionMode == "category" ? (selectedCategories.contains(area.id) ? .all : .none)
            : SelectionState.summarize(selected: selectedItems[area.id] ?? [], children: area.items.map(\.id))
    }
    func groupState(_ group: CoreRestoreInspection.Group) -> SelectionState {
        let children = areas.filter { group.domains.contains($0.id) && $0.selectable }
        if !children.isEmpty && children.allSatisfy({ selectionState($0) == .all }) { return .all }
        return children.contains { selectionState($0) != .none } ? .mixed : .none
    }
    func choose(_ url: URL) {
        guard !busy, !runtime.isActive else { return }
        cancelRequested = false
        source = url; inspection = nil; selectedCategories = []; selectedItems = [:]
        invalidate(); failure = nil; technicalReason = nil
        guard url.isFileURL, url.pathExtension.lowercased() == "mbt" else {
            fail("Choose a Macseed saved environment (.mbt).", code: nil); return
        }
        state = .inspecting
        work = Task {
            guard await receive(CoreRequest(.capabilities)) else { return }
            guard runtime.capabilities?.supportsRestoreSelection == true else {
                fail("This Core runtime does not support fine Restore selection. Use a compatible development build.", code: nil); return
            }
            guard await receive(CoreRequest(.bundleInspect(path: url.path))) else { return }
            do {
                guard let result = runtime.latestResult else { throw CoreRuntimeError.malformedEvent }
                let data = try result.decodeData(CoreRestoreInspection.self)
                try data.validate(); inspection = data; state = .review
                for area in areas where area.selectable { selectArea(area.id, included: true) }
            } catch { fail("The saved environment could not be inspected reliably.", code: "invalid_result") }
        }
    }
    func selectArea(_ id: String, included: Bool) {
        guard !busy, !runtime.isActive, let area = areas.first(where: { $0.id == id }), area.selectable else { return }
        if area.selectionMode == "category" {
            if included { selectedCategories.insert(id) } else { selectedCategories.remove(id) }
        } else {
            selectedItems[id] = included ? Set(area.items.map(\.id)) : nil
        }
        invalidate(); state = .review
    }
    func selectItem(_ domain: String, item: String, included: Bool) {
        guard !busy, !runtime.isActive, let area = areas.first(where: { $0.id == domain }), area.selectable,
              area.selectionMode == "items", area.items.contains(where: { $0.id == item }) else { return }
        if included { selectedItems[domain, default: []].insert(item) }
        else { selectedItems[domain]?.remove(item); if selectedItems[domain]?.isEmpty == true { selectedItems[domain] = nil } }
        invalidate(); state = .review
    }
    func selectGroup(_ group: CoreRestoreInspection.Group, included: Bool) {
        for area in areas where group.domains.contains(area.id) { selectArea(area.id, included: included) }
    }
    func toggleAll() {
        guard !busy, !runtime.isActive else { return }
        let included = bulkState != .all
        for area in areas { selectArea(area.id, included: included) }
    }
    func refreshPreview() {
        guard canPreview, let source, let catalog = inspection?.restoreSelection else { return }
        cancelRequested = false
        let expected = canonicalSelection
        let request = CoreRequest(.restorePrepare(path: source.path, disabledGroups: [], includeSecure: false, selection: selection))
        invalidate(); failure = nil; technicalReason = nil; state = .preparing
        work = Task {
            guard await receive(request) else { return }
            do {
                guard let result = runtime.latestResult else { throw CoreRuntimeError.malformedEvent }
                let data = try result.decodeData(CoreRestorePreparation.self)
                try data.validate(expected: expected, catalog: catalog)
                preparation = data; preview = RestorePreviewPresentation(data, catalog: catalog); state = .preview
            } catch { fail("Restore Preview did not provide complete, consistent evidence. Refresh Preview before rebuilding.", code: "invalid_result") }
        }
    }
    func back() {
        guard !busy, !runtime.isActive else { return }
        invalidate(); state = inspection == nil ? .choose : .review
    }
    func cancel() { if busy { cancelRequested = true; invalidate(); runtime.cancel() } }
    private func invalidate() { preparation = nil; preview = nil }
    private func receive(_ request: CoreRequest) async -> Bool {
        if cancelRequested {
            invalidate(); failure = "Restore preparation cancelled. No target changes were made."; state = .cancelled; return false
        }
        runtime.start(request, location: location)
        await runtime.waitForCompletion()
        guard runtime.operationID == request.operationID else { fail("Restore inspection was interrupted. Try again.", code: "operation_mismatch"); return false }
        switch runtime.state {
        case .completed: return true
        case .cancelled:
            invalidate(); failure = "Restore preparation cancelled. No target changes were made. Refresh Preview or choose a saved environment again."
            state = .cancelled; return false
        default:
            let error = runtime.error
            let code: String?
            if case .coreFailure(let value) = error { code = value } else { code = nil }
            let message: String
            switch code {
            case "bundle_invalid": message = "The saved environment is invalid or damaged. Choose another saved environment."
            case "unsupported_bundle": message = "This saved environment uses an unsupported format. Choose a compatible saved environment."
            case "bundle_unavailable": message = "The saved environment is unavailable. Choose an accessible file."
            case "recovery_required": message = "An earlier Restore needs recovery through the CLI before another Preview."
            case "stale_plan": message = "The inputs changed. Refresh Preview to inspect the current state."
            default: message = error == .interrupted ? "Restore preparation was interrupted. No complete Preview is available. Try again." : "Restore preparation could not complete. Try again or choose another saved environment."
            }
            fail(message, code: code); return false
        }
    }
    private func fail(_ message: String, code: String?) { invalidate(); failure = message; technicalReason = code; state = .failed }
    func waitForCompletion() async { await work?.value }
}

struct RestoreExecutionPresentation {
    enum Outcome { case clean, partial, attention, stoppedBeforeMutation, stoppedAfterMutation, interrupted, failedBeforeMutation, failedAfterMutation }
    let outcome: Outcome
    let title: String
    let message: String
    let details: [DisplayItem]
    let findings: [DisplayItem]
    let successfulAreas: [String]
    let structuredEvidence: [String: CoreJSON]?
    @MainActor init(runtime: CoreRuntime, payload: [String: CoreJSON]?, expectedID: String, catalog: CoreRestoreInspection.Inventory? = nil, itemNames: [String: [String: String]] = [:]) {
        structuredEvidence = payload
        let terminal = runtime.termination?.terminal
        let validTerminal: Bool
        if case .coreFailure = runtime.error { validTerminal = true }
        else { validTerminal = runtime.error == nil }
        let mayMutate = payload?["target_mutation_may_have_started"]?.boolean ?? true
        let verification = payload?["verification"]?.object
        let verified = verification?["verdict"]?.string == "selected_requirements_verified"
            && verification?["status"]?.string == "complete"
            && ["mismatch_count", "unverified_count", "unresolved_count", "warning_count", "error_count"].allSatisfy { verification?[$0]?.integer == 0 }
        if !validTerminal || terminal == nil || payload?["target_mutation_may_have_started"]?.boolean == nil {
            outcome = .interrupted
        } else if terminal?.isCancellation == true {
            outcome = mayMutate ? .stoppedAfterMutation : .stoppedBeforeMutation
        } else if terminal?.type == "failed" {
            let records = verification?["details"]?.object?["operation_records"]
            let changed: Bool
            if case .array(let rows) = records, case .array(let observed) = verification?["details"]?.object?["verification_records"] {
                changed = rows.contains { value in
                    guard let operation = value.object, operation["outcome"]?.string == "success" else { return false }
                    return observed.contains { observation in
                        let row = observation.object
                        return row?["domain"] == operation["domain"] && row?["item_id"] == operation["item_id"]
                            && row?["conformity"]?.string == "verified"
                    }
                }
            } else { changed = false }
            let complete = verification?["status"]?.string == "complete" && verification?["details"]?.object?["status"]?.string == "complete"
            outcome = payload?["independent_work_completed"]?.boolean == true && complete && changed && payload?["prepared_plan_id"]?.string == expectedID
                ? .partial : mayMutate ? .failedAfterMutation : .failedBeforeMutation
        } else if runtime.state == .completed && payload?["execution_status"]?.string == "completed"
                    && payload?["prepared_plan_id"]?.string == expectedID {
            outcome = verified && payload?["warning_count"]?.integer == 0 && payload?["error_count"]?.integer == 0 ? .clean : .attention
        } else { outcome = .interrupted }
        switch outcome {
        case .clean: title = "All Done"; message = "Your environment is ready. Everything was restored successfully."
        case .partial: title = "Rebuild Completed with Issues"; message = "Some selected changes completed. Refresh Preview to inspect unresolved items before rebuilding again."
        case .attention: title = "Rebuild completed with attention needed"; message = "Review the observed results, then Refresh Preview to check current state."
        case .stoppedBeforeMutation: title = "Rebuild Cancelled"; message = "Core reports that no target mutation started. Refresh Preview before another Rebuild."
        case .stoppedAfterMutation: title = "Rebuild Stopped"; message = "Completed changes may remain. Refresh Preview to inspect current state before rebuilding again."
        case .interrupted: title = "Rebuild Interrupted"; message = "Final consequences are unknown. Changes may remain. Refresh Preview to inspect current state."
        case .failedBeforeMutation: title = "Rebuild Could Not Start"; message = "Core reports that no target mutation started. Refresh Preview to check prerequisites and current state."
        case .failedAfterMutation: title = "Rebuild Failed"; message = "Some selected changes could not be completed. Changes may remain. Refresh Preview to inspect the current state before rebuilding again."
        }
        let normalized = RestoreResultFindings(payload: payload, events: runtime.events, catalog: catalog, verified: verified, itemNames: itemNames)
        details = normalized.details.isEmpty && outcome != .clean
            ? [DisplayItem(id: "incomplete", title: "Rebuild result", status: .unverified,
                           action: "Complete final evidence is unavailable. Inspect current state with a fresh Preview.")]
            : normalized.details
        successfulAreas = outcome == .partial ? normalized.successfulAreas : []
        findings = outcome == .clean ? [] : normalized.findings
    }
}

// Separate actionable area summaries from technical evidence, keyed by Protocol identity.
struct RestoreResultFindings {
    private struct Key: Hashable {
        let kind: String
        let domain: String
        let item: String
        let action: String
        let reason: String
    }
    let findings: [DisplayItem]
    let details: [DisplayItem]
    let successfulAreas: [String]
    init(payload: [String: CoreJSON]?, events: [CoreEvent], catalog: CoreRestoreInspection.Inventory?, verified: Bool, itemNames: [String: [String: String]] = [:]) {
        var detailRows: [DisplayItem] = []
        var seen: Set<Key> = []
        var areaOrder: [String] = []
        var areaStates: [String: DisplayStatus] = [:]
        var failedAreas: Set<String> = []
        var itemFindings: [DisplayItem] = []
        var itemFindingIDs: Set<String> = []
        var itemFindingAreas: Set<String> = []
        var otherIssues: Set<String> = []
        var verifiedAreaOrder: [String] = []
        func area(_ domain: String) -> (String, String)? {
            if let group = catalog?.groups.first(where: { $0.id == "macOS Settings" && $0.domains.contains(domain) }) {
                return (group.id, group.id)
            }
            guard let entry = catalog?.inventory.first(where: { $0.id == domain }) else { return nil }
            return (domain, entry.label)
        }
        func append(kind: String, domain: String, item: String = "scope", action: String = "", reason: String,
                    title: String, status: DisplayStatus, message: String) {
            guard seen.insert(Key(kind: kind, domain: domain, item: item, action: action, reason: reason)).inserted else { return }
            detailRows.append(DisplayItem(id: "finding-\(detailRows.count)", title: title, status: status, action: message, reason: reason.isEmpty ? nil : reason))
        }
        func mark(_ domain: String, actionable: Bool, failed: Bool = false) {
            guard let (id, _) = area(domain) else { return }
            if areaStates[id] == nil { areaOrder.append(id) }
            if failed { failedAreas.insert(id) }
            if actionable || areaStates[id] == nil { areaStates[id] = actionable ? .attention : .unverified }
        }
        if let code = payload?["code"]?.string {
            append(kind: "rebuild", domain: "", reason: code, title: "Rebuild", status: .attention,
                   message: code == "stale_plan" ? "The Mac or saved environment changed. A fresh Preview is required." : "Rebuild could not complete.")
        }
        let verification = payload?["verification"]?.object
        if let verdict = verification?["verdict"]?.string {
            append(kind: "conformity", domain: "", reason: verdict, title: "Observed environment", status: verified ? .matching : .unverified,
                   message: verified ? "Selected requirements verified" : "Final conformity needs attention.")
        }
        let evidence = verification?["details"]?.object
        func records(_ key: String) -> [CoreJSON] {
            if case .array(let values) = evidence?[key] { return values }
            return []
        }
        let operations = records("operation_records")
        var operationDomains: Set<String> = []
        for value in operations {
            guard let row = value.object, let domain = row["domain"]?.string,
                  let outcome = row["outcome"]?.string, ["failure", "warning"].contains(outcome) || (outcome == "skipped" && ["dependency_failed", "dependency_observation_failed", "cask_execution_requirements_unsupported"].contains(row["reason"]?.string ?? "")) else { continue }
            let reason = row["reason"]?.string ?? outcome
            // A selected-work aggregate may repeat the terminal failure verbatim.
            if area(domain) == nil && reason == payload?["code"]?.string { continue }
            if domain == "orchestration" && row["item_id"]?.string == "bootstrap"
                && row["action"]?.string == "execute" && payload?["code"]?.string == "bootstrap_failed" { continue }
            operationDomains.insert(domain); mark(domain, actionable: true, failed: outcome == "failure")
            let identity = domain + ":" + (row["item_id"]?.string ?? "scope")
            if ["item_stalled_timeout", "cask_execution_requirements_unsupported"].contains(reason),
               let name = itemNames[domain]?[row["item_id"]?.string ?? ""] {
                if itemFindingIDs.insert(identity).inserted {
                    let message = reason == "item_stalled_timeout"
                        ? "Download stalled. Check your network or VPN and try again."
                        : "This application was skipped because its installation requirements are not supported."
                    itemFindings.append(DisplayItem(id: identity, title: name, status: .attention,
                        action: message, reason: reason))
                }
                if let (id, _) = area(domain) { itemFindingAreas.insert(id) }
            } else if let (id, _) = area(domain) { otherIssues.insert(id) }
            append(kind: "operation", domain: domain, item: row["item_id"]?.string ?? "scope", action: row["action"]?.string ?? "",
                   reason: reason, title: area(domain)?.1 ?? "Rebuild", status: .attention,
                   message: outcome == "failure" ? "Rebuild could not complete this selected work." : "This selected work needs attention.")
        }
        // Scope failures fill missing operation evidence, rather than repeating it.
        let lifecycle = records("module_outcomes").compactMap(\.object)
            + events.filter { $0.type == "execution_event" }.compactMap(\.data)
        for row in lifecycle {
            guard let domain = row["domain"]?.string, let state = row["state"]?.string,
                  ["failed", "warning", "conflict", "blocked"].contains(state) else { continue }
            if row["item_id"]?.string == "scope" && operationDomains.contains(domain) { continue }
            if operations.contains(where: { value in
                guard let operation = value.object else { return false }
                return operation["domain"] == row["domain"] && operation["item_id"] == row["item_id"]
                    && operation["reason"] == row["reason"]
                    && ["failure", "warning"].contains(operation["outcome"]?.string ?? "")
            }) { continue }
            mark(domain, actionable: true, failed: state == "failed")
            if let (id, _) = area(domain) { otherIssues.insert(id) }
            append(kind: "execution", domain: domain, item: row["item_id"]?.string ?? "scope",
                   reason: row["reason"]?.string ?? state, title: area(domain)?.1 ?? "Rebuild", status: .attention,
                   message: state == "failed" ? "Rebuild could not complete this area." : "This selected area needs attention.")
        }
        for value in records("verification_records") {
            guard let row = value.object, let domain = row["domain"]?.string,
                  let conformity = row["conformity"]?.string else { continue }
            if conformity == "verified" {
                if let (id, _) = area(domain), !verifiedAreaOrder.contains(id) { verifiedAreaOrder.append(id) }
                continue
            }
            if !itemFindingIDs.contains(domain + ":" + (row["item_id"]?.string ?? "scope")), let (id, _) = area(domain) { otherIssues.insert(id) }
            mark(domain, actionable: ["mismatch", "missing", "different"].contains(conformity))
            // Equal conformity/reason within a domain is one final-state finding.
            append(kind: "verification", domain: domain, action: conformity, reason: row["reason"]?.string ?? conformity,
                   title: area(domain)?.1 ?? "Selected environment requirement", status: .unverified,
                   message: "Final state: Unverified")
        }
        for value in records("coverage_records") {
            guard let row = value.object, row["disposition"]?.string == "unresolved", let domain = row["domain"]?.string else { continue }
            mark(domain, actionable: false)
        }
        successfulAreas = verifiedAreaOrder.filter { areaStates[$0] == nil }.map { area($0)?.1 ?? $0 }
        findings = itemFindings + areaOrder.filter { !itemFindingAreas.contains($0) || otherIssues.contains($0) }.map { id in
            let title = area(id)?.1 ?? id
            let status = areaStates[id] ?? .unverified
            return DisplayItem(id: id, title: title, status: status,
                               action: failedAreas.contains(id) ? "Rebuild could not complete this area." : status == .attention ? "This selected area needs attention." : "Final conformity could not be proven. Refresh Preview to inspect this area.")
        }
        details = detailRows
    }
}
