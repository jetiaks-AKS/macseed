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
        case "install": "Ready to Install"
        case "reinstall": "Ready to Repair"
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
                case "reinstall": message = "Will Repair"
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
            case "privileged_lifecycle_unknown": reasonMessage = "Privileged Homebrew work may still be running. Inspect it before another Rebuild."
            default: reasonMessage = nil
            }
            let inventoryLabel = row.selectionItemID.flatMap { id in catalog.inventory.first { $0.id == row.domain }?.items.first { $0.id == id }?.label }
            let title = inventoryLabel ?? row.displayName ?? (row.itemID.hasPrefix("opaque:") ? "Private item" : (row.itemID == "scope" ? "Selected area" : row.itemID))
            let action = row.diagnostic?.explanation ?? reasonMessage ?? (row.authorizationRequired == true ? message + " · Administrator authorization required" : message)
            rows[row.domain, default: []].append(DisplayItem(id: "restore-\(index)", title: title, status: status, action: action, reason: row.reason, restoreReadyText: status == .ready ? Self.readyText(action: row.action) : nil))
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
            for (index, entry) in plan.plan.enumerated() where rowDomains.contains(entry.domain) && entry.disposition != "satisfied" {
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
                        case "install": verb = "Installing"
                        case "reinstall": verb = "Repairing"
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
    static func activity(events: [CoreEvent], rows: [Self], mutationPossible: Bool) -> String {
        var current: CoreEvent?
        for event in events {
            if event.isTerminal || ["phase_started", "phase_completed"].contains(event.type) {
                current = nil
            } else if event.type == "execution_event" {
                let state = event.data?["state"]?.string ?? ""
                if ["started", "applying", "verifying"].contains(state) {
                    // Core executes sequentially; activity is reported, never inferred from the plan.
                    current = event
                } else if current?.data?["domain"] == event.data?["domain"] &&
                            (current?.data?["item_id"] == event.data?["item_id"] || event.data?["item_id"]?.string == "scope") {
                    current = nil
                }
            } else if ["operation_record", "verification_record"].contains(event.type),
                      current?.data?["domain"] == event.data?["domain"],
                      current?.data?["item_id"] == event.data?["item_id"] || event.data?["item_id"]?.string == "scope" {
                current = nil
            }
        }
        let fallback = phase(events: events, mutationPossible: mutationPossible)
        guard !fallback.hasPrefix("Verifying"), let current,
              let domain = current.data?["domain"]?.string,
              let row = rows.first(where: { $0.domains.contains(domain) ||
                  (domain == "workspace" && !$0.domains.isDisjoint(with: ["workspace-folders", "git-repositories"])) }) else { return fallback }
        if let text = row.project(events: [current]).restoreActivity {
            return domain == "vscode-extensions" && current.data?["action"]?.string == "install"
                ? text.replacingOccurrences(of: "Installing ", with: "Installing VS Code extension: ") : text
        }
        return row.title + "…"
    }
    static func phase(events: [CoreEvent], mutationPossible: Bool) -> String {
        if events.contains(where: { $0.data?["domain"]?.string == "verification" || $0.phase == "verification" }) {
            return "Verifying restored environment…"
        }
        return mutationPossible ? "Restoring environment…" : "Preparing rebuild…"
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
    @Published private(set) var stopConfirmation = false
    private var stopOperationID: String?
    @Published private(set) var failure: String?
    @Published private(set) var technicalReason: String?
    @Published private(set) var retryingPrerequisites = false
    @Published private(set) var prerequisiteRetryMessage: String?
    let runtime: CoreRuntime
    private let location: CoreLocation?
    private var work: Task<Void, Never>?
    private var cancelRequested = false
    @Published private(set) var categoryEvidenceEvents: [CoreEvent] = []
    private var categoryEvidence: [String: CoreEvent] = [:]
    private var evidenceSubscription: AnyCancellable?
    private var evidenceSequence = 0
    var categoryPresentationEvents: [CoreEvent] {
        (categoryEvidenceEvents + runtime.events.filter { !["verification_record", "coverage_record", "operation_record"].contains($0.type) })
            .sorted { $0.sequence < $1.sequence }
    }

    var busy: Bool { retryingPrerequisites || state == .inspecting || state == .preparing || state == .confirming || state == .rebuilding }
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
    var selectionCategoryCounts: (fully: Int, partially: Int, notSelected: Int) {
        areas.filter(\.selectable).reduce(into: (fully: 0, partially: 0, notSelected: 0)) { counts, area in
            switch selectionState(area) {
            case .all: counts.fully += 1
            case .mixed: counts.partially += 1
            case .none: counts.notSelected += 1
            }
        }
    }
    var categorySelectionSummary: String {
        let counts = selectionCategoryCounts
        return [(counts.fully, "fully selected"), (counts.partially, "partially selected"),
                (counts.notSelected, "not selected")].filter { $0.0 > 0 }
            .map { "\($0.0) \($0.0 == 1 ? "category" : "categories") \($0.1)" }.joined(separator: " · ")
    }
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
    var previewNeedsRefresh: Bool {
        preparation.map { $0.selection != canonicalSelection } ?? false
    }
    var ready: Bool {
        guard !previewNeedsRefresh, state == .preview, let plan = preparation, plan.readiness.ready, plan.errorCount == 0 else { return false }
        return !plan.plan.contains { row in
            // A conflict with no proposed action is retained by the existing
            // consumer; environmental blockers are owned by Core readiness.
            if row.disposition == "conflict" && row.action == "none" { return false }
            return ["conflict", "blocked", "unknown", "pending_unlock"].contains(row.disposition) && !plan.isItemLocalSkip(row)
        }
    }
    init(runtime: CoreRuntime, location: CoreLocation? = nil) {
        self.runtime = runtime; self.location = location
        evidenceSubscription = runtime.$events.sink { [weak self] events in
            guard let self, self.state == .rebuilding else { return }
            var changed = false
            for event in events where event.sequence > self.evidenceSequence {
                self.evidenceSequence = event.sequence
                guard ["verification_record", "coverage_record", "operation_record"].contains(event.type),
                      let domain = event.data?["domain"]?.string, let item = event.data?["item_id"]?.string else { continue }
                let key = [event.type, domain, item, event.data?["predicate"]?.string ?? "", event.data?["action"]?.string ?? ""].joined(separator: "|")
                self.categoryEvidence[key] = event
                changed = true
            }
            if changed { self.categoryEvidenceEvents = self.categoryEvidence.values.sorted { $0.sequence < $1.sequence } }
        }
    }
    var canRebuild: Bool {
        ready && !runtime.isActive && preparation?.hasExecutableChanges == true
            && preparation?.selection == canonicalSelection
    }
    var mutationPossible: Bool {
        runtime.mutationMayHaveStarted == true || runtime.events.contains { $0.phase == "bootstrap" || $0.type == "execution_event" }
    }
    private var progressScope: [RestoreProgressRow] = []
    var activity: String {
        RestoreProgressRow.activity(events: runtime.events, rows: progressScope, mutationPossible: mutationPossible)
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
        categoryEvidence = [:]; categoryEvidenceEvents = []; evidenceSequence = 0
        executionResult = nil; dismissStopConfirmation(); state = .rebuilding
        // Start synchronously so a second activation cannot launch another operation.
        runtime.start(request, location: location)
        work = Task {
            await runtime.waitForCompletion()
            dismissStopConfirmation()
            executionFinishedAt = Date()
            let terminal = runtime.termination?.terminal
            let payload = runtime.latestResult?.data ?? terminal?.data
            let names = progressScope.reduce(into: [String: [String: String]]()) { result, row in
                result.merge(row.itemNames) { previous, _ in previous }
            }
            executionResult = RestoreExecutionPresentation(runtime: runtime, payload: payload, expectedID: plan.preparedPlanID, catalog: inspection?.restoreSelection, itemNames: names, expectedDiagnostics: plan.planDiagnostics)
            invalidate(); state = .result
        }
    }
    func requestStop() {
        guard state == .rebuilding, runtime.isActive, runtime.operation == .restoreExecute,
              !runtime.stopping, !stopConfirmation, let id = runtime.operationID else { return }
        stopOperationID = id
        stopConfirmation = true
    }
    func dismissStopConfirmation() {
        stopConfirmation = false
        stopOperationID = nil
    }
    func confirmStop() {
        let id = stopOperationID
        let pending = stopConfirmation
        dismissStopConfirmation()
        guard pending, let id, state == .rebuilding, runtime.isActive,
              runtime.operation == .restoreExecute, runtime.operationID == id, !runtime.stopping else { return }
        runtime.cancel()
    }
    func checkCurrentState() {
        guard state == .result, !runtime.isActive else { return }
        state = .review; executionResult = nil; refreshPreview()
    }
    func finish() {
        guard state == .result, !runtime.isActive else { return }
        invalidate(); progressScope = []; executionResult = nil; inspection = nil; source = nil
        executionPreview = nil; executionPlan = nil; executionStartedAt = nil; executionFinishedAt = nil
        categoryEvidence = [:]; categoryEvidenceEvents = []; evidenceSequence = 0
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
        updateDraftArea(area, included: included)
        invalidate(); state = .review
    }
    private func updateDraftArea(_ area: CoreRestoreInspection.Area, included: Bool) {
        let id = area.id
        if area.selectionMode == "category" {
            if included { selectedCategories.insert(id) } else { selectedCategories.remove(id) }
        } else {
            selectedItems[id] = included ? Set(area.items.map(\.id)) : nil
        }
    }
    func selectPreviewDomain(_ id: String, included: Bool) {
        guard state == .preview, !runtime.isActive else { return }
        let scope = areas.first(where: { $0.id == id }).map { [$0] }
            ?? groups.first(where: { $0.id == id }).map { group in areas.filter { group.domains.contains($0.id) } }
            ?? []
        for area in scope where area.selectable { updateDraftArea(area, included: included) }
        // Keep the immutable accepted Preview. Only explicit Refresh invokes Core.
    }
    func previewSelectionState(_ id: String) -> SelectionState {
        if let area = areas.first(where: { $0.id == id }) { return selectionState(area) }
        if let group = groups.first(where: { $0.id == id }) { return groupState(group) }
        return .none
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
    func checkPrerequisites(permission: () async -> RestoreAutomationPermission.Outcome = RestoreAutomationPermission.requestAccess) async {
        guard state == .preview, !busy, !runtime.isActive, !previewNeedsRefresh, let plan = preparation else { return }
        prerequisiteRetryMessage = nil
        if plan.readiness.conditions.contains(where: { $0.diagnostic?.automationRequirement == true }) {
            retryingPrerequisites = true
            let outcome = await permission()
            retryingPrerequisites = false
            guard preparation?.preparedPlanID == plan.preparedPlanID, !previewNeedsRefresh else { return }
            if outcome != .available { prerequisiteRetryMessage = outcome.message; return }
        }
        refreshPreview()
    }
    func refreshPreview() {
        guard canPreview, let source, let catalog = inspection?.restoreSelection else { return }
        cancelRequested = false
        prerequisiteRetryMessage = nil
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
    let diagnosticEvents: [CoreEvent]
    private let expectedPlanID: String
    private let expectedDiagnostics: [String: String]?
    @MainActor init(runtime: CoreRuntime, payload: [String: CoreJSON]?, expectedID: String, catalog: CoreRestoreInspection.Inventory? = nil, itemNames: [String: [String: String]] = [:], expectedDiagnostics: [String: String]? = nil) {
        self.expectedPlanID = expectedID
        self.expectedDiagnostics = expectedDiagnostics
        structuredEvidence = payload
        diagnosticEvents = runtime.events
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
            outcome = Self.hasPartialEvidence(payload: payload, expectedID: expectedID)
                ? .partial : mayMutate ? .failedAfterMutation : .failedBeforeMutation
        } else if runtime.state == .completed && payload?["execution_status"]?.string == "completed"
                    && payload?["prepared_plan_id"]?.string == expectedID {
            outcome = verified && payload?["warning_count"]?.integer == 0 && payload?["error_count"]?.integer == 0 ? .clean : .attention
        } else { outcome = .interrupted }
        switch outcome {
        case .clean: title = "All Done"; message = "Your selected environment has been restored and verified."
        case .partial: title = "Rebuild Needs Attention"; message = "Some selected changes completed. Refresh Preview to inspect unresolved items before rebuilding again."
        case .attention: title = "Rebuild Completed with Issues"; message = "Review the observed results, then Refresh Preview to check current state."
        case .stoppedBeforeMutation: title = "Rebuild Cancelled"; message = "Core reports that no target mutation started. Refresh Preview before another Rebuild."
        case .stoppedAfterMutation: title = "Rebuild Stopped"; message = "Completed changes may remain. Refresh Preview to inspect current state before rebuilding again."
        case .interrupted: title = "Rebuild Interrupted"; message = "Final consequences are unknown. Changes may remain. Refresh Preview to inspect current state."
        case .failedBeforeMutation:
            if payload?["code"]?.string == "stale_plan" || terminal?.code == "stale_plan" {
                title = "Restore Plan Is Outdated"
                message = "The restore plan is no longer valid. Refresh Preview to generate an updated plan before rebuilding."
                    + (payload?["target_mutation_may_have_started"]?.boolean == false
                       ? " No changes were made by this Restore attempt." : "")
            } else {
                title = "Rebuild Could Not Start"
                message = "Core reports that no target mutation started. Refresh Preview to check prerequisites and current state."
            }
        case .failedAfterMutation: title = "Rebuild Failed"; message = "Some selected changes could not be completed. Changes may remain. Refresh Preview to inspect the current state before rebuilding again."
        }
        let normalized = RestoreResultFindings(payload: payload, events: runtime.events, catalog: catalog, verified: verified, itemNames: itemNames, completedWithIssues: [.partial, .attention].contains(outcome))
        details = normalized.details.isEmpty && outcome != .clean
            ? [DisplayItem(id: "incomplete", title: "Rebuild result", status: .unverified,
                           action: "Complete final evidence is unavailable. Inspect current state with a fresh Preview.")]
            : normalized.details
        successfulAreas = outcome == .partial ? normalized.successfulAreas : []
        findings = outcome == .clean ? [] : normalized.findings
    }
    static func hasPartialEvidence(payload: [String: CoreJSON]?, expectedID: String) -> Bool {
        let verification = payload?["verification"]?.object
        let records = verification?["details"]?.object?["operation_records"]
        let changed: Bool
        if case .array(let rows) = records, case .array(let observed) = verification?["details"]?.object?["verification_records"] {
            changed = rows.contains { value in
                guard let operation = value.object, operation["outcome"]?.string == "success" else { return false }
                let matching = observed.compactMap(\.object).filter {
                    $0["domain"] == operation["domain"] && $0["item_id"] == operation["item_id"]
                }
                return !matching.isEmpty && matching.allSatisfy { $0["conformity"]?.string == "verified" }
            }
        } else { changed = false }
        let concreteFailure: Bool
        let knownItemSkip: Bool
        if case .array(let rows) = records {
            knownItemSkip = rows.contains { value in
                let row = value.object
                return row?["outcome"]?.string == "skipped" && row?["reason"]?.string == "cask_execution_requirements_unsupported"
            }
            concreteFailure = rows.contains { value in
                guard let row = value.object else { return true }
                if ["success", "noop"].contains(row["outcome"]?.string ?? "") { return false }
                if row["outcome"]?.string == "skipped", row["reason"]?.string == "cask_execution_requirements_unsupported" { return false }
                // Only the known Bootstrap aggregate can accompany an item-local skip.
                return !(row["outcome"]?.string == "failure" && row["domain"]?.string == "orchestration"
                    && row["item_id"]?.string == "bootstrap" && row["action"]?.string == "execute"
                    && (row["reason"]?.string == nil || row["reason"]?.string == "bootstrap_failed"))
            }
        } else { concreteFailure = true; knownItemSkip = false }
        let complete = verification?["status"]?.string == "complete" && verification?["details"]?.object?["status"]?.string == "complete"
        let dangerousScope = verification?["details"]?.object?["module_outcomes"]
        let scopeFailure: Bool
        if case .array(let rows) = dangerousScope {
            scopeFailure = rows.compactMap(\.object).contains { row in
                guard ["failed", "blocked", "conflict", "interrupted"].contains(row["state"]?.string ?? "") else { return false }
                return !(row["domain"]?.string == "homebrew-casks" && row["item_id"]?.string == "scope" && row["reason"]?.string == "module_failed" && knownItemSkip)
            }
        } else { scopeFailure = false }
        let details = verification?["details"]?.object
        let operationRows: [[String: CoreJSON]]
        let observationRows: [[String: CoreJSON]]
        if case .array(let values) = records { operationRows = values.compactMap(\.object) } else { operationRows = [] }
        if case .array(let values) = details?["verification_records"] { observationRows = values.compactMap(\.object) } else { observationRows = [] }
        let skipRows = operationRows.filter { $0["outcome"]?.string == "skipped" && $0["reason"]?.string == "cask_execution_requirements_unsupported" }
        func isSkippedItem(_ row: [String: CoreJSON]) -> Bool {
            skipRows.contains { $0["domain"] == row["domain"] && $0["item_id"] == row["item_id"] }
        }
        let unexplainedObservation = observationRows.contains { $0["conformity"]?.string != "verified" && !isSkippedItem($0) }
        let unexplainedDiagnostic: Bool
        if case .array(let values) = details?["diagnostics"] {
            unexplainedDiagnostic = values.compactMap(\.object).contains { row in
                guard row["severity"]?.string == "error" else { return false }
                let owner = row["record_id"]?.string
                if row["code"]?.string == "confirmed_mismatch" {
                    return !observationRows.contains { $0["record_id"]?.string == owner && owner != nil && isSkippedItem($0) }
                }
                if row["code"]?.string == "operation_failed" {
                    return !operationRows.contains { $0["record_id"]?.string == owner && owner != nil && $0["domain"]?.string == "orchestration" && $0["item_id"]?.string == "bootstrap" && $0["action"]?.string == "execute" && $0["outcome"]?.string == "failure" }
                }
                return true
            }
        } else { unexplainedDiagnostic = false }
        let unexplainedTopFailure: Bool
        if case .array(let values) = payload?["operation_failures"] {
            unexplainedTopFailure = values.contains { value in
                guard let row = value.object else { return true }
                return !operationRows.contains { $0["domain"] == row["domain"] && $0["item_id"] == row["item_id"] && $0["action"] == row["action"] && $0["outcome"] == row["outcome"] && $0["reason"] == row["reason"] }
            }
        } else { unexplainedTopFailure = false }
        return knownItemSkip && !concreteFailure && !scopeFailure && !unexplainedObservation && !unexplainedDiagnostic && !unexplainedTopFailure && payload?["unknown_consequences"]?.boolean != true
            && payload?["code"]?.string == "bootstrap_failed" && payload?["independent_work_completed"]?.boolean == true
            && complete && changed && payload?["prepared_plan_id"]?.string == expectedID
    }
    // Short problem-only projection. The full allowlisted report remains separate.
    var compactTechnicalDetails: [String] {
        var seen = Set<String>()
        return technicalDetails.filter { line in
            let problem = ["outcome: failure", "outcome: warning", "outcome: skipped", "conformity: mismatch",
                "conformity: unverified", "conformity: unsupported", "conformity: unresolved",
                "disposition: unresolved", "severity: error", "severity: warning",
                "state: failed", "state: blocked", "state: conflict", "state: interrupted"].contains { line.contains($0) }
            return problem
        }.compactMap { line in
            let fields = line.components(separatedBy: " · ").filter { field in
                ["domain:", "item_id:", "outcome:", "conformity:", "reason:", "code:", "disposition:", "state:"].contains { field.hasPrefix($0) }
            }
            let text = fields.joined(separator: " · ")
            return !text.isEmpty && seen.insert(text).inserted ? text : nil
        }
    }
    var diagnosticReport: String {
        (["Restore diagnostic report (allowlisted Protocol fields; raw payloads and process output excluded)."] + technicalDetails + planValidationDetails).joined(separator: "\n")
    }

    private var planValidationDetails: [String] {
        guard structuredEvidence?["code"]?.string == "stale_plan",
              let validation = structuredEvidence?["plan_validation"]?.object else { return [] }
        func hash(_ value: String?) -> String? {
            guard let value, value.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { return nil }
            return value
        }
        var lines = ["Plan validation (fingerprints only; target-state change is not established by a fingerprint mismatch)."]
        if let id = hash(expectedPlanID) { lines.append("Desktop prepared ID: " + id) }
        if let id = hash(validation["expected_id"]?.string) { lines.append("Execute requested ID: " + id) }
        if let id = hash(validation["recomputed_id"]?.string) { lines.append("Core recomputed ID: " + id) }
        if let check = validation["check"]?.string, ["prepared_plan_id", "input_recheck"].contains(check) {
            lines.append("Validation check: " + check)
        }
        for key in ["bundle", "stage", "selection", "parameters", "plan", "readiness", "modules"] {
            let before = hash(expectedDiagnostics?[key])
            let after = hash(validation["components"]?.object?[key]?.string)
            lines.append(key + " changed: " + (before != nil && after != nil ? String(before != after) : "unknown"))
            if let before { lines.append(key + " prepared fingerprint: " + before) }
            if let after { lines.append(key + " recomputed fingerprint: " + after) }
        }
        for key in ["bundle_changed_after_prepare", "stage_changed_after_prepare"] {
            if let changed = validation[key]?.boolean { lines.append(key + ": " + String(changed)) }
        }
        return lines
    }

    var technicalDetails: [String] {
        // Only Protocol diagnostic fields; never dump arbitrary payloads, process output or future fields.
        let keys = ["record_id", "domain", "item_id", "action", "state", "outcome", "reason", "predicate", "conformity", "support", "observed_at", "disposition", "source_status", "code", "severity", "phase", "status", "execution_status", "bootstrap_status", "prepared_plan_id", "verdict", "warning_count", "error_count", "verified_count", "mismatch_count", "unverified_count", "unresolved_count", "target_mutation_may_have_started", "unknown_consequences", "independent_work_completed"]
        var output: [String] = []
        var seen = Set<String>()
        func append(_ kind: String, _ row: [String: CoreJSON]) {
            let fields = keys.compactMap { key -> String? in
                guard let value = row[key], value != .null else { return nil }
                let text: String
                switch value {
                case .string(let string): text = string
                case .integer(let number): text = String(number)
                case .bool(let boolean): text = String(boolean)
                default: return nil
                }
                return key + ": " + text
            }
            let text = ([kind] + fields).joined(separator: " · ")
            if seen.insert(text).inserted { output.append(text) }
        }
        for event in diagnosticEvents where event.isTerminal || ["execution_event", "operation_record", "verification_record", "coverage_record", "diagnostic_record"].contains(event.type) {
            append(event.type, event.data ?? [:])
        }
        if let payload = structuredEvidence {
            append("Restore result", payload)
            if case .array(let records) = payload["operation_failures"] {
                for record in records { if let row = record.object { append("operation_failures", row) } }
            }
            if let verification = payload["verification"]?.object {
                append("Verification", verification)
                if let details = verification["details"]?.object {
                    append("Evidence", details)
                    for key in ["operation_records", "verification_records", "coverage_records", "diagnostics", "module_outcomes"] {
                        if case .array(let records) = details[key] {
                            for record in records { if let row = record.object { append(key, row) } }
                        }
                    }
                }
            }
        }
        return output
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
    init(payload: [String: CoreJSON]?, events: [CoreEvent], catalog: CoreRestoreInspection.Inventory?, verified: Bool, itemNames: [String: [String: String]] = [:], completedWithIssues: Bool = false) {
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
        if let code = payload?["code"]?.string, !(completedWithIssues && code == "bootstrap_failed") {
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
                        : "Skipped — this application’s installation requirements are not safely supported."
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
            if completedWithIssues && row["reason"]?.string == "bootstrap_failed"
                && ["orchestration", "bootstrap"].contains(domain) { continue }
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
        // User issues are keyed by Protocol identity and cause, never by their rendered text.
        var issues: [DisplayItem] = []
        var issueKeys = Set<String>()
        var affectedItems = Set<String>()
        var problemDomains = Set<String>()
        func issue(_ domain: String, _ item: String, _ cause: String, _ message: String, status: DisplayStatus = .attention, action: String = "") {
            let identity = domain + ":" + item
            guard issueKeys.insert(identity + ":" + action + ":" + cause).inserted else { return }
            let name = itemNames[domain]?[item]
            issues.append(DisplayItem(id: identity + ":" + action + ":" + cause,
                title: name ?? area(domain)?.1 ?? "Selected work", status: status, action: message, reason: cause))
            affectedItems.insert(identity)
            problemDomains.insert(domain)
        }
        let userOperations = operations.compactMap(\.object) + events.filter { $0.type == "operation_record" }.compactMap(\.data)
        for row in userOperations {
            guard let domain = row["domain"]?.string, let item = row["item_id"]?.string,
                  let outcome = row["outcome"]?.string else { continue }
            let reason = row["reason"]?.string ?? outcome
            if ["cancelled", "secure_cancelled"].contains(reason) { continue }
            guard ["failure", "warning"].contains(outcome) || (outcome == "skipped" && !["not_applicable", "not_selected", "already_satisfied", "no_requirement", "cancelled"].contains(reason)) else { continue }
            if domain == "orchestration" && item == "bootstrap" && row["action"]?.string == "execute" && outcome == "failure" && payload?["code"]?.string == "bootstrap_failed" { continue }
            let message: String
            switch reason {
            case "cask_execution_requirements_unsupported": message = "This application's installation requirements are not supported."
            case "item_stalled_timeout": message = "Download stalled. Check your network or VPN and try again."
            case "dependency_failed", "dependency_observation_failed": message = "A required dependency could not be completed or inspected."
            case "privileged_lifecycle_unknown": message = "Privileged work may continue. Inspect Homebrew before another Rebuild."
            default: message = outcome == "failure" ? "This selected work could not be completed." : "This selected work needs attention."
            }
            issue(domain, item, reason, message, action: row["action"]?.string ?? "")
        }
        for row in lifecycle {
            guard let domain = row["domain"]?.string, let item = row["item_id"]?.string,
                  ["failed", "warning", "conflict", "blocked"].contains(row["state"]?.string ?? "") else { continue }
            let reason = row["reason"]?.string ?? row["state"]?.string ?? ""
            if affectedItems.contains(domain + ":" + item) && userOperations.contains(where: { $0["domain"]?.string == domain && $0["item_id"]?.string == item && $0["reason"]?.string == reason }) { continue }
            if item == "scope" && problemDomains.contains(domain) && ["module_failed", "module_warning"].contains(reason) { continue }
            if completedWithIssues && ["bootstrap", "orchestration"].contains(domain) && reason == "bootstrap_failed" { continue }
            issue(domain, item, reason, "This selected area could not be completed without issues.")
        }
        for row in records("verification_records").compactMap(\.object) {
            guard let domain = row["domain"]?.string, let item = row["item_id"]?.string,
                  let conformity = row["conformity"]?.string, conformity != "verified" else { continue }
            if affectedItems.contains(domain + ":" + item) { continue } // Same item's final consequence remains in Technical Details.
            issue(domain, item, conformity, conformity == "mismatch" ? "The final state does not match the saved environment." : "The final state could not be confirmed.", status: conformity == "mismatch" ? .attention : .unverified)
        }
        for row in records("coverage_records").compactMap(\.object) where row["disposition"]?.string == "unresolved" {
            guard let domain = row["domain"]?.string, let item = row["item_id"]?.string else { continue }
            issue(domain, item, "unresolved", "Some selected requirements could not be resolved.", status: .unresolved)
        }
        for row in records("diagnostics").compactMap(\.object) {
            guard ["error", "warning"].contains(row["severity"]?.string ?? ""), let code = row["code"]?.string else { continue }
            let owner = row["record_id"]?.string
            let ownerRows = userOperations + records("verification_records").compactMap(\.object) + records("coverage_records").compactMap(\.object)
            if let linked = ownerRows.first(where: { owner != nil && $0["record_id"]?.string == owner }) {
                let domain = linked["domain"]?.string ?? ""
                let item = linked["item_id"]?.string ?? "scope"
                if ["confirmed_mismatch", "operation_failed", "selected_input_unresolved", "observation_failed"].contains(code) && (affectedItems.contains(domain + ":" + item) || (domain == "orchestration" && item == "bootstrap" && payload?["code"]?.string == "bootstrap_failed" && !issues.isEmpty)) { continue }
                issue(domain, item, code, "Core reported a problem while inspecting or restoring this selected work.")
            } else {
                issue("diagnostic", owner ?? "run", code, "Core reported a problem while inspecting or restoring the selected environment.")
            }
        }
        if issues.isEmpty && (!verified || (payload?["warning_count"]?.integer ?? 0) > 0 || (payload?["error_count"]?.integer ?? 0) > 0) && payload?["code"]?.string != "cancelled" && payload?["code"]?.string != "secure_cancelled" {
            issues.append(DisplayItem(id: "result-incomplete", title: "Rebuild result", status: .unverified,
                action: "Complete final conformity could not be confirmed. Refresh Preview to inspect current state."))
        }
        findings = issues
        details = detailRows
    }
}
