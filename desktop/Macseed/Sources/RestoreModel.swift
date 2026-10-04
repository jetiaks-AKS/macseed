import Combine
import Foundation

enum RestoreFlowState { case choose, inspecting, preparing, review, preview, failed, cancelled }

struct RestorePreviewPresentation {
    let categories: [DisplayCategory]
    let summary: String
    let sections: [Section]
    struct Section: Identifiable {
        let id: String
        let rows: [DisplayCategory]
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
            rows[row.domain, default: []].append(DisplayItem(id: "restore-\(index)", title: title, status: status, action: reasonMessage ?? message, reason: row.reason))
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
                                DisplayItem(id: item.id, title: category.title + " · " + item.title, status: item.status, action: item.action, reason: item.reason)
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

@MainActor final class RestoreModel: ObservableObject {
    @Published private(set) var state: RestoreFlowState = .choose
    @Published private(set) var source: URL?
    @Published private(set) var inspection: CoreRestoreInspection?
    @Published private(set) var selectedCategories: Set<String> = []
    @Published private(set) var selectedItems: [String: Set<String>] = [:]
    @Published private(set) var preparation: CoreRestorePreparation?
    @Published private(set) var preview: RestorePreviewPresentation?
    @Published private(set) var failure: String?
    @Published private(set) var technicalReason: String?
    let runtime: CoreRuntime
    private let location: CoreLocation?
    private var work: Task<Void, Never>?
    private var cancelRequested = false
    var busy: Bool { state == .inspecting || state == .preparing }
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
        state == .preview && preparation?.readiness.ready == true && preparation?.errorCount == 0
            && preparation?.plan.contains(where: { ["conflict", "blocked", "unknown", "pending_unlock"].contains($0.disposition) }) == false
    }
    init(runtime: CoreRuntime, location: CoreLocation? = nil) { self.runtime = runtime; self.location = location }
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
