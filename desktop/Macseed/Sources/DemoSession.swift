#if DEBUG
import Combine
import Foundation

enum CaptureState: Equatable { case idle, scanning, review, result, cancelled }
enum RestoreState: Equatable { case choose, review, rebuilding, result, stopped }
enum StatusState: Equatable { case choose, result }

enum DemoPreset: String, CaseIterable, Identifiable {
    case home = "Home"
    case scanning = "Capture scanning"
    case captureReview = "Capture review"
    case securePrompt = "Capture secure prompt"
    case captureSuccess = "Capture success"
    case prerequisite = "Prerequisite required"
    case restoreReady = "Restore ready"
    case rebuilding = "Rebuild progress"
    case stopped = "Stopped rebuild"
    case success = "Successful result"
    case attention = "Result needing attention"
    case differences = "Environment Status differences"
    var id: String { rawValue }
}

// In-memory UI demonstration only. No process, file, network or secret access.
@MainActor final class DemoSession: ObservableObject {
    @Published var task: ProductTask?
    @Published private(set) var captureState: CaptureState = .idle
    @Published private(set) var captureItemSelection = Set(SampleProvider.capture.flatMap(\.items).map(\.id))
    @Published private(set) var identitySelection: Set<String> = []
    @Published var secureSheet = false
    @Published private(set) var restoreState: RestoreState = .choose
    @Published private(set) var bundle: String?
    @Published private(set) var restoreSelection: Set<String> = []
    @Published private(set) var homebrewAvailable = false
    @Published private(set) var revision = 0
    @Published private(set) var confirmedRevision: Int?
    @Published private(set) var previousStoppedBundle: String?
    @Published private(set) var progressIndex = 0
    @Published private(set) var result: DisplayResult?
    @Published private(set) var statusState: StatusState = .choose

    var captureCategories: [DisplayCategory] { SampleProvider.capture }
    var secureIdentityNames: [String] { SampleProvider.identities }
    var prerequisite: DisplayPrerequisite { SampleProvider.prerequisite }
    var statusCategories: [DisplayCategory] { SampleProvider.status }

    var busy: Bool { captureState == .scanning || restoreState == .rebuilding || secureSheet }
    var captureSelection: Set<String> {
        Set(captureCategories.filter { $0.items.contains { captureItemSelection.contains($0.id) } }.map(\.id))
    }
    var selectedCaptureItemCount: Int { captureItemSelection.count }
    func captureSelectionState(_ category: DisplayCategory) -> SelectionState {
        SelectionState.summarize(selected: captureItemSelection, children: category.items.map(\.id))
    }
    var captureBulkState: SelectionState {
        SelectionState.summarize(selected: captureItemSelection, children: captureCategories.flatMap(\.items).map(\.id))
    }
    var secureBulkState: SelectionState {
        SelectionState.summarize(selected: identitySelection, children: secureIdentityNames)
    }
    var restoreBulkState: SelectionState {
        SelectionState.summarize(selected: restoreSelection, children: restoreCategories.map(\.id))
    }
    func toggleAllCapture() {
        guard captureState == .review, !secureSheet else { return }
        captureItemSelection = captureBulkState == .all ? [] : Set(captureCategories.flatMap(\.items).map(\.id))
    }
    func toggleAllIdentities() {
        guard captureState == .review, !secureSheet else { return }
        identitySelection = secureBulkState == .all ? [] : Set(secureIdentityNames)
    }
    func toggleAllRestore() {
        guard restoreState == .review else { return }
        restoreSelection = restoreBulkState == .all ? [] : Set(restoreCategories.map(\.id))
        revision += 1
        confirmedRevision = nil
    }
    var canCreate: Bool { !captureItemSelection.isEmpty || !identitySelection.isEmpty }
    var canGoBack: Bool { task != nil && !busy }
    func goBack() {
        guard canGoBack, let task else { return }
        switch task {
        case .capture:
            switch captureState {
            case .result: captureState = .review
            case .review: captureState = .idle
            default: self.task = nil
            }
        case .restore:
            switch restoreState {
            case .result, .stopped:
                // Never return to an old confirmation or progress cursor.
                chooseBundle(bundle ?? "A")
            case .review: cancelRestore()
            default: self.task = nil
            }
        case .status:
            if statusState == .result { statusState = .choose } else { self.task = nil }
        }
    }
    var needsHomebrew: Bool { restoreSelection.contains("Homebrew") && !homebrewAvailable }
    var canRebuild: Bool { restoreState == .review && !restoreSelection.isEmpty && !needsHomebrew }
    var restoreCategories: [DisplayCategory] {
        SampleProvider.restore(bundle ?? "A").map { category in
            guard category.id == "Homebrew", needsHomebrew else { return category }
            return DisplayCategory(id: category.id, title: category.title, symbol: category.symbol,
                                   items: category.items.map { item in
                DisplayItem(id: item.id, title: item.title, status: .attention,
                            action: "Waiting for Homebrew", reason: SampleProvider.prerequisite.reason)
            })
        }
    }
    var progress: DisplayProgress {
        let fixture = SampleProvider.progress[progressIndex]
        let groupIDs = ["apps": "Applications", "brew": "Homebrew", "settings": "macOS Settings"]
        let rows = fixture.categories.filter { restoreSelection.contains(groupIDs[$0.id] ?? "") }
        let subject = progressIndex == 1 && !restoreSelection.contains("Homebrew")
            ? "Processing selected settings…" : fixture.subject
        return DisplayProgress(phase: fixture.phase, subject: subject,
                               processed: rows.filter { $0.status == .complete }.count, categories: rows)
    }

    func navigate(_ destination: ProductTask?) {
        guard !busy else { return }
        task = destination
    }
    func scan() { captureState = .scanning }
    func finishScan() { guard captureState == .scanning else { return }; captureState = .review }
    func cancelCapture() { secureSheet = false; captureState = .cancelled }
    func selectCapture(_ id: String, included: Bool) {
        guard captureState == .review, let category = captureCategories.first(where: { $0.id == id }) else { return }
        let children = Set(category.items.map(\.id))
        if included { captureItemSelection.formUnion(children) }
        else { captureItemSelection.subtract(children) }
    }
    func selectCaptureItem(_ id: String, included: Bool) {
        guard captureState == .review, captureCategories.flatMap(\.items).contains(where: { $0.id == id }) else { return }
        if included { captureItemSelection.insert(id) } else { captureItemSelection.remove(id) }
    }
    func selectIdentity(_ id: String, included: Bool) {
        guard captureState == .review, SampleProvider.identities.contains(id) else { return }
        if included { identitySelection.insert(id) } else { identitySelection.remove(id) }
    }
    func createCapture() {
        guard captureState == .review, canCreate else { return }
        if identitySelection.isEmpty { captureState = .result } else { secureSheet = true }
    }
    // Receives no passphrase. The sheet clears its local demonstration input.
    func completeSecureDemo() {
        guard secureSheet, captureState == .review else { return }
        secureSheet = false
        captureState = .result
    }
    func chooseBundle(_ name: String) {
        guard restoreState != .rebuilding, ["A", "B"].contains(name) else { return }
        bundle = name
        restoreSelection = Set(SampleProvider.restore(name).map(\.id))
        homebrewAvailable = false
        revision += 1
        confirmedRevision = nil
        result = nil
        progressIndex = 0
        restoreState = .review
    }
    func selectRestore(_ id: String, included: Bool) {
        guard restoreState == .review, restoreCategories.contains(where: { $0.id == id }) else { return }
        if included { restoreSelection.insert(id) } else { restoreSelection.remove(id) }
        revision += 1
        confirmedRevision = nil
    }
    func checkAgain() {
        guard restoreState == .review else { return }
        homebrewAvailable = true
        revision += 1
        confirmedRevision = nil
    }
    func cancelRestore() {
        guard restoreState != .rebuilding else { return }
        confirmedRevision = nil
        restoreState = .choose
        bundle = nil
        result = nil
    }
    func rebuild() {
        guard canRebuild else { return }
        confirmedRevision = revision
        progressIndex = 0
        restoreState = .rebuilding
    }
    func nextEvent() {
        guard restoreState == .rebuilding else { return }
        if progressIndex < SampleProvider.progress.count - 1 { progressIndex += 1 }
        else {
            result = SampleProvider.completion(selection: restoreSelection)
            restoreState = .result
        }
    }
    func stop() {
        guard restoreState == .rebuilding else { return }
        previousStoppedBundle = bundle
        confirmedRevision = nil
        result = DisplayResult(title: "Rebuild stopped.", message: "Completed changes may remain. Inspect current state and review a fresh plan before rebuilding again.",
                               readyCount: nil, attentionCount: nil, details: [
                                DisplayItem(id: "processed", title: "\(progress.processed) sample actions processed", status: .complete, action: "Completed actions remain"),
                                DisplayItem(id: "remaining", title: "Remaining results not confirmed", status: .attention,
                                            action: "Refresh Preview", reason: "cancelled")]
                                + restoreCategories.filter { restoreSelection.contains($0.id) }
                                    .flatMap(\.items).filter { $0.status == .matching })
        restoreState = .stopped
    }
    func compare() { statusState = .result }

    func load(_ preset: DemoPreset) {
        // Explicit reset for visual inspection, not a resumable operation.
        secureSheet = false
        task = nil
        captureState = .idle
        captureItemSelection = Set(SampleProvider.capture.flatMap(\.items).map(\.id))
        identitySelection = []
        restoreState = .choose
        bundle = nil
        restoreSelection = []
        homebrewAvailable = false
        revision = 0
        confirmedRevision = nil
        previousStoppedBundle = nil
        progressIndex = 0
        result = nil
        statusState = .choose
        switch preset {
        case .home: break
        case .scanning: task = .capture; scan()
        case .captureReview: task = .capture; scan(); finishScan()
        case .securePrompt:
            task = .capture; scan(); finishScan()
            selectIdentity(SampleProvider.identities[0], included: true); createCapture()
        case .captureSuccess: task = .capture; scan(); finishScan(); createCapture()
        case .prerequisite: task = .restore; chooseBundle("A")
        case .restoreReady: task = .restore; chooseBundle("A"); checkAgain()
        case .rebuilding, .stopped:
            task = .restore; chooseBundle("A"); checkAgain(); rebuild(); nextEvent()
            if preset == .stopped { stop() }
        case .success, .attention:
            task = .restore; chooseBundle("A"); checkAgain()
            if preset == .success { selectRestore("Workspace", included: false) }
            rebuild(); nextEvent(); nextEvent(); nextEvent()
        case .differences: task = .status; compare()
        }
    }
}
#endif
