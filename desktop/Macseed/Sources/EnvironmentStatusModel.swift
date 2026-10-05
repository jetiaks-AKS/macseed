import Combine
import Foundation

struct EnvironmentReference: Equatable {
    let generatedDirectory: URL
    let blueprint: URL?
    var command: CoreCommand {
        .environmentCompare(generatedDirectory: generatedDirectory.path, blueprintPath: blueprint?.path)
    }
    func validateAvailability() throws {
        var directory: ObjCBool = false
        guard generatedDirectory.isFileURL,
              FileManager.default.fileExists(atPath: generatedDirectory.path, isDirectory: &directory), directory.boolValue,
              FileManager.default.isReadableFile(atPath: generatedDirectory.path) else { throw StatusFailure.referenceUnavailable }
        if let blueprint {
            guard blueprint.isFileURL,
                  FileManager.default.fileExists(atPath: blueprint.path, isDirectory: &directory), !directory.boolValue,
                  FileManager.default.isReadableFile(atPath: blueprint.path) else { throw StatusFailure.referenceUnavailable }
        }
    }
}

enum StatusFailure: Error, Equatable {
    case noReference, referenceUnavailable, invalidResult, cancelled, interrupted
    case runtime(CoreRuntimeError)
    var message: String {
        switch self {
        case .noReference: "Choose a saved Generated Configuration folder to compare with this Mac."
        case .referenceUnavailable: "The selected reference is unavailable. Choose an accessible saved configuration and Blueprint, or check again after restoring access."
        case .invalidResult: "Core returned incomplete or invalid comparison evidence. No status conclusion is available."
        case .cancelled: "Comparison cancelled. Check again to inspect current state."
        case .interrupted: "Comparison interrupted. No complete status conclusion is available. Check again to inspect current state."
        case .runtime(.coreFailure(let code)):
            switch code {
            case "reference_unavailable": "The selected reference is unavailable. Choose an accessible saved configuration or Blueprint."
            case "reference_invalid": "The selected configuration or Blueprint is invalid. Choose a valid reference."
            case "reference_changed": "The reference changed during comparison. Check again to compare its current contents."
            case "comparison_reporting_incomplete": "Core could not provide complete comparison evidence. No status conclusion is available."
            case "comparison_failed": "Core could not complete the comparison. Check the reference and try again."
            default: "Core could not compare this Mac with the selected reference."
            }
        case .runtime(let error): error.message
        }
    }
    var technicalReason: String? {
        if case .runtime(.coreFailure(let code)) = self,
           code.range(of: "^[a-z][a-z0-9_-]{0,63}$", options: .regularExpression) != nil { return code }
        return nil
    }
}

struct EnvironmentStatusPresentation {
    let headline: String
    let message: String
    let summary: String
    let categories: [DisplayCategory]
    let needsAttention: Bool
    let counts: [String: Int]

    init(_ result: CoreComparisonResult) throws {
        try result.validate()
        counts = result.comparison.counts
        var grouped: [String: [DisplayItem]] = [:]
        var order: [String] = []
        func add(_ domain: String, _ item: DisplayItem) {
            if grouped[domain] == nil { order.append(domain) }
            grouped[domain, default: []].append(item)
        }
        func title(_ identity: String) -> String {
            identity.hasPrefix("opaque:") ? "Private item" : (identity == "scope" ? "Category scope" : identity)
        }
        func technical(_ reason: String?, _ phase: String?) -> String? {
            let parts = [reason, phase.map { "Phase: " + $0 }].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: "\n")
        }
        for row in result.comparisonRecords {
            let status: DisplayStatus
            let action: String
            switch row.comparisonKind {
            case "matching": status = .matching; action = "Matches the selected reference."
            case "missing": status = .missing; action = "Reference requirement was not found on this Mac."
            case "differing": status = .different; action = "Current state differs from the selected reference."
            default:
                status = row.support == "unsupported" ? .unsupported : .unverified
                switch row.reason {
                case "unknown_difference": action = "Core could not determine the kind of difference."
                case "observation_failed": action = "Core could not observe current state."
                default: action = row.support == "unsupported" ? "This requirement is unverified because its predicate is not supported." : "Core could not verify this requirement."
                }
            }
            add(row.domain, DisplayItem(id: row.recordID, title: title(row.itemID), status: status,
                                        action: action, reason: technical(row.reason, row.phase)))
        }
        for row in result.records.coverageRecords where row.disposition != "resolved" {
            let status: DisplayStatus = row.disposition == "unresolved" ? .unresolved : (row.disposition == "excluded" ? .excluded : .noRequirement)
            let action = row.disposition == "unresolved" ? "The selected reference requirement could not be resolved."
                : (row.disposition == "excluded" ? "Excluded from the selected comparison scope." : "No requirement in the selected scope.")
            add(row.domain, DisplayItem(id: row.recordID, title: title(row.itemID), status: status,
                                       action: action, reason: row.disposition == "unresolved" || row.sourceStatus != "unknown"
                                        ? "Source status: " + row.sourceStatus : nil))
        }
        let owners = result.records.verificationRecords + result.records.operationRecords
        for (index, diagnostic) in result.records.diagnostics.enumerated() {
            let owner = owners.first { $0.recordID == diagnostic.recordID }
            let coverage = result.records.coverageRecords.first { $0.recordID == diagnostic.recordID }
            let domain = owner?.domain ?? coverage?.domain ?? "comparison"
            let identity = owner?.itemID ?? coverage?.itemID ?? "scope"
            // Keep diagnostics separate: a warning must not replace a matching fact.
            let attention = ["warning", "error"].contains(diagnostic.severity)
            add(domain, DisplayItem(id: "diagnostic:\(index)", title: title(identity), status: attention ? .attention : .information,
                                    action: attention ? "Core reported a comparison issue." : "Core reported additional comparison information.",
                                    reason: diagnostic.severity + ": " + diagnostic.code + "\nPhase: " + diagnostic.phase))
        }
        for (index, item) in result.extra.items.enumerated() {
            add(item.domain, DisplayItem(id: "extra:\(index)", title: title(item.itemID), status: .extra,
                                        action: "Present on this Mac outside the complete source inventory. Nothing will be removed."))
        }
        for domain in result.extra.domains where domain.status == "unavailable" {
            add(domain.domain, DisplayItem(id: "extra-availability:" + domain.domain, title: "Extra-item evidence", status: .information,
                                          action: "Unavailable. Extra items cannot be determined for this category.", reason: domain.reason))
        }
        let names: [String: (String, String)] = [
            "homebrew-packages": ("Homebrew Packages", "shippingbox"), "homebrew-casks": ("Homebrew Applications", "app"),
            "app-store": ("App Store Applications", "app"), "vscode-extensions": ("VS Code Extensions", "puzzlepiece.extension"),
            "vscode-settings": ("VS Code Settings", "slider.horizontal.3"), "git-configuration": ("Git Configuration", "gearshape"),
            "git-repositories": ("Git Repositories", "folder"), "workspace-folders": ("Workspace Folders", "folder"),
            "ssh-configuration": ("SSH Configuration", "key"), "shell-zsh": ("Shell Configuration", "terminal"),
            "macos-finder": ("Finder", "finder"), "macos-dock": ("Dock", "dock.rectangle"),
            "macos-windows": ("Windows", "macwindow"), "macos-keyboard": ("Keyboard", "keyboard"),
            "macos-trackpad": ("Trackpad", "hand.draw"), "macos-screenshots": ("Screenshots", "camera"),
            "comparison": ("Comparison", "checkmark.circle"), "blueprint": ("Blueprint", "doc.text")]
        categories = order.map { domain in
            DisplayCategory(id: domain, title: names[domain]?.0 ?? domain, symbol: names[domain]?.1 ?? "folder", items: grouped[domain]!)
        }
        needsAttention = result.comparison.verdict == "incomplete" || result.comparison.verdict == "differences_detected"
            || result.comparison.alsoIncomplete || categories.contains(where: \.hasAttention)
        if needsAttention {
            headline = "Needs Attention"
            message = result.comparison.verdict == "incomplete" ? "Comparison is incomplete. Some requirements could not be verified."
                : (result.comparison.alsoIncomplete ? "Differences were found, and some requirements could not be verified."
                    : (result.comparison.verdict == "differences_detected" ? "Differences were found in the selected scope." : "Core reported issues in the selected scope."))
        } else {
            headline = result.comparison.verdict == "no_comparable_requirements" ? "No comparable requirements" : "No differences detected"
            message = result.comparison.verdict == "no_comparable_requirements" ? "The selected scope contains no comparable requirements."
                : "The compared requirements match the selected reference."
        }
        let labels = [("matching", "matching"), ("missing", "missing"), ("differing", "different"), ("unverified", "unverified"),
                      ("unsupported", "unsupported (within unverified)"), ("unresolved", "unresolved"), ("extra", "extra"),
                      ("unknown_difference", "unknown difference (within unverified)")]
        summary = labels.compactMap { key, label in
            let count = result.comparison.counts[key] ?? 0
            return count > 0 ? "\(count) \(label)" : nil
        }.joined(separator: " · ")
    }
}

enum EnvironmentStatusState { case choose, running, result, failed, cancelled }

@MainActor final class EnvironmentStatusModel: ObservableObject {
    @Published private(set) var reference: EnvironmentReference?
    @Published private(set) var state: EnvironmentStatusState = .choose
    @Published private(set) var presentation: EnvironmentStatusPresentation?
    @Published private(set) var failure: StatusFailure?
    @Published private(set) var operationID: String?
    let runtime: CoreRuntime
    private let location: CoreLocation?
    private var work: Task<Void, Never>?
    init(runtime: CoreRuntime, location: CoreLocation? = nil) { self.runtime = runtime; self.location = location }

    func selectReference(_ directory: URL) {
        guard !runtime.isActive, state != .running else { return }
        reference = EnvironmentReference(generatedDirectory: directory, blueprint: nil)
        reset()
    }
    func selectBlueprint(_ blueprint: URL?) {
        guard !runtime.isActive, state != .running, let reference else { return }
        self.reference = EnvironmentReference(generatedDirectory: reference.generatedDirectory, blueprint: blueprint)
        reset()
    }
    private func reset() { state = .choose; presentation = nil; failure = nil; operationID = nil }

    func compare() {
        guard !runtime.isActive, state != .running else { return }
        presentation = nil // Never retain an old success under a fresh failure/progress state.
        failure = nil
        do {
            guard let reference else { throw StatusFailure.noReference }
            try reference.validateAvailability()
            let request = CoreRequest(reference.command)
            operationID = request.operationID
            state = .running
            runtime.start(request, location: location)
            work = Task {
                await runtime.waitForCompletion()
                guard runtime.operationID == request.operationID else { fail(.invalidResult); return }
                switch runtime.state {
                case .completed:
                    do {
                        guard let event = runtime.latestResult else { throw StatusFailure.invalidResult }
                        presentation = try EnvironmentStatusPresentation(event.decodeData(CoreComparisonResult.self))
                        state = .result
                    } catch { fail(.invalidResult) }
                case .cancelled: failure = .cancelled; state = .cancelled
                case .failed:
                    let error = runtime.error ?? .malformedEvent
                    fail(error == .interrupted ? .interrupted : .runtime(error))
                default: fail(.invalidResult)
                }
            }
        } catch { operationID = nil; fail(error as? StatusFailure ?? .invalidResult) }
    }
    private func fail(_ error: StatusFailure) { presentation = nil; failure = error; state = .failed }
    func cancel() { if state == .running { runtime.cancel() } }
    func waitForCompletion() async { await work?.value }
}
