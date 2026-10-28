import Combine
import Foundation

struct EnvironmentReference: Equatable {
    var bundle: URL? = nil
    let generatedDirectory: URL
    let blueprint: URL?
    var command: CoreCommand {
        if let bundle { return .environmentCompareBundle(path: bundle.path) }
        return .environmentCompare(generatedDirectory: generatedDirectory.path, blueprintPath: blueprint?.path)
    }
    func validateAvailability() throws {
        if let bundle {
            let values = try? bundle.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard bundle.isFileURL, values?.isRegularFile == true, values?.isSymbolicLink != true,
                  FileManager.default.isReadableFile(atPath: bundle.path) else { throw StatusFailure.referenceUnavailable }
            return
        }
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
    case noReference, referenceUnavailable, unsupportedCapability, invalidResult, cancelled, interrupted
    case runtime(CoreRuntimeError)
    var message: String {
        switch self {
        case .noReference: "Choose a Saved Environment (.mbt) to compare with this Mac."
        case .unsupportedCapability: "Comparison is unavailable in this build. Check the app setup or update Macseed."
        case .referenceUnavailable: "The selected Saved Environment is unavailable. Choose an accessible file or restore access."
        case .invalidResult: "Comparison results are incomplete. Compare again to check the current state."
        case .cancelled: "Comparison cancelled. Check again to inspect current state."
        case .interrupted: "Comparison was interrupted. Compare again to check the current state."
        case .runtime(.coreFailure(let code)):
            switch code {
            case "bundle_unavailable": "The selected Saved Environment is unavailable. Choose an accessible file."
            case "bundle_invalid": "The selected Saved Environment is invalid or corrupted. Choose a valid Bundle."
            case "unsupported_bundle": "This Saved Environment uses an unsupported Bundle format."
            case "reference_unavailable": "The selected reference is unavailable. Choose an accessible saved configuration or Blueprint."
            case "reference_invalid": "The selected configuration or Blueprint is invalid. Choose a valid reference."
            case "reference_changed": "The reference changed during comparison. Check again to compare its current contents."
            case "comparison_reporting_incomplete": "Comparison results are incomplete. Compare again to check the current state."
            case "comparison_unavailable": "Comparison could not finish. Compare again to check the current state."
            case "comparison_failed": "Comparison failed. Check the saved environment and try again."
            default: "Couldn’t compare this Mac with the selected saved environment."
            }
        case .runtime(.runtimeUnavailable), .runtime(.pythonUnavailable), .runtime(.invalidRuntimeConfiguration), .runtime(.writableCoreRequired), .runtime(.incompatibleProtocol):
            "Comparison is unavailable in this build. Check the app setup or update Macseed."
        case .runtime: "Comparison was interrupted. Compare again to check the current state."
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
    let sections: [EnvironmentStatusSection]
    let needsAttention: Bool
    let counts: [String: Int]
    let attentionCount: Int?
    let technicalFacts: [String: [ComparisonTechnicalFact]]

    func categoryCount(_ outcome: ComparisonOutcome, category: DisplayCategory, children: [DisplayCategory] = []) -> Int {
        // Category badges count the logical rows shown below them, not Core predicates.
        let items = children.isEmpty ? category.items : children.flatMap(\.items)
        return items.filter { item in
            switch outcome {
            case .match: item.status == .matching
            case .different: item.status == .different
            case .missing: item.status == .missing
            case .notApplicable: item.status == .noRequirement
            case .needsAttention: [.attention, .unverified, .unsupported, .unresolved].contains(item.status)
            }
        }.count
    }

    init(_ result: CoreComparisonResult) throws {
        try result.validate()
        counts = result.comparison.counts
        technicalFacts = Dictionary(grouping: result.comparisonRecords.filter { $0.domain == "git-repositories" }, by: { $0.domain + ":" + $0.itemID }).mapValues { rows in
            rows.map { row in
                ComparisonTechnicalFact(recordID: row.recordID,
                    predicate: result.records.verificationRecords.first(where: { $0.recordID == row.recordID })?.predicate,
                    result: row.comparisonKind, reason: row.reason, phase: row.phase, support: row.support,
                    diagnostics: result.records.diagnostics.filter { $0.recordID == row.recordID })
            }.sorted {
                let order = ["worktree", "origin", "branch"]
                return (order.firstIndex(of: $0.predicate ?? "") ?? 3, $0.recordID)
                    < (order.firstIndex(of: $1.predicate ?? "") ?? 3, $1.recordID)
            }
        }
        var grouped: [String: [DisplayItem]] = [:]
        var order: [String] = []
        func add(_ domain: String, _ item: DisplayItem) {
            if grouped[domain] == nil { order.append(domain) }
            if let index = grouped[domain]?.firstIndex(where: { $0.id == item.id }) {
                let previous = grouped[domain]![index]
                let action = [previous.action, item.action].reduce(into: [String]()) { if !$1.isEmpty && !$0.contains($1) { $0.append($1) } }.joined(separator: " ")
                let reasons = [previous.reason, item.reason].compactMap { $0 }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                let precedence: [DisplayStatus] = [.noRequirement, .information, .matching, .extra, .different, .missing, .unsupported, .unverified, .unresolved, .attention]
                let status = (precedence.firstIndex(of: item.status) ?? 0) > (precedence.firstIndex(of: previous.status) ?? 0) ? item.status : previous.status
                grouped[domain]![index] = DisplayItem(id: previous.id, title: previous.title, status: status,
                                                     action: action, reason: reasons.isEmpty ? nil : reasons.joined(separator: "\n"))
            } else { grouped[domain, default: []].append(item) }
        }
        func logicalID(_ domain: String, _ identity: String) -> String { domain + ":" + identity }
        func diagnosticMessage(_ code: String) -> String {
            switch code {
            case "partial_source_coverage": "The saved configuration covers only part of this category."
            case "unsupported_predicate": "Some requirements are not supported for verification."
            case "observation_failed": "Current state could not be observed completely."
            case "selected_input_unresolved": "A selected requirement could not be resolved."
            case "input_invalid": "The saved configuration could not be validated."
            case "confirmed_mismatch": "A requirement differs from the saved environment."
            case "prerequisite_unmet": "A required inspection prerequisite is unavailable."
            default: "An inspection issue needs review in this category."
            }
        }
        let repositoryIDs = Set(result.comparisonRecords.filter { $0.domain == "git-repositories" }.map(\.itemID)
            + result.records.coverageRecords.filter { $0.domain == "git-repositories" && $0.disposition != "excluded" }.map(\.itemID)
            + result.records.verificationRecords.filter { $0.domain == "git-repositories" }.map(\.itemID)).sorted()
        func title(_ identity: String, domain: String) -> String {
            if domain == "git-repositories", identity != "scope" {
                if let label = result.referencePresentation?.repositoryLabels?[identity],
                   label != "Private item", label.range(of: "^[A-Za-z0-9][A-Za-z0-9_. -]{0,79}$", options: .regularExpression) != nil {
                    return label
                }
                if let index = repositoryIDs.firstIndex(of: identity) { return "Repository \(index + 1)" }
                return "Repository"
            }
            if let label = result.referencePresentation?.settingLabels?[domain]?[identity] { return label }
            if domain == "app-store" {
                if let name = result.referencePresentation?.appStoreNames[identity], !name.isEmpty, name != "Private item" { return name }
                return "App Store Application"
            }
            return identity.hasPrefix("opaque:") ? "Private item" : (identity == "scope" ? "Category scope" : identity)
        }
        func technical(_ reason: String?, _ phase: String?) -> String? {
            let parts = [reason, phase.map { "Phase: " + $0 }].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: "\n")
        }
        for row in result.comparisonRecords {
            let owner = result.records.verificationRecords.first {
                $0.recordID == row.recordID && $0.domain == row.domain && $0.itemID == row.itemID
            }
            let status: DisplayStatus
            let action: String
            switch row.comparisonKind {
            case "matching": status = .matching; action = "Matches the selected reference."
            case "missing":
                status = .missing
                if row.domain.hasPrefix("macos-"), owner?.predicate == "stored_preference", row.reason == "confirmed_mismatch" {
                    action = "Saved preference is not explicitly set on this Mac."
                } else {
                    action = row.domain == "app-store"
                        ? "The App Store requirement was not found. A Homebrew installation does not confirm the App Store version."
                        : "Reference requirement was not found on this Mac."
                }
            case "differing": status = .different; action = "Current state differs from the selected reference."
            default:
                status = row.support == "unsupported" ? .unsupported : .unverified
                switch row.reason {
                case "unknown_difference": action = "Couldn’t determine how this requirement differs."
                case "observation_failed": action = "Couldn’t read the current state."
                default: action = row.support == "unsupported" ? "This requirement cannot be checked in this version." : "Couldn’t verify this requirement."
                }
            }
            add(row.domain, DisplayItem(id: logicalID(row.domain, row.itemID), title: title(row.itemID, domain: row.domain), status: status,
                                        action: action, reason: [technical(row.reason, row.phase), "Comparison: " + row.comparisonKind + " · " + row.recordID,
                                                                row.domain == "app-store" ? "App Store ID: " + row.itemID : nil,
                                                                row.domain == "git-repositories" || row.domain.hasPrefix("macos-") ? owner?.predicate.map { "Predicate: " + $0 } : nil].compactMap { $0 }.joined(separator: "\n")))
        }
        for row in result.records.coverageRecords where !["resolved", "excluded"].contains(row.disposition) {
            let status: DisplayStatus = row.disposition == "unresolved" ? .unresolved : (row.disposition == "excluded" ? .excluded : .noRequirement)
            let action = row.disposition == "unresolved" ? "The selected reference requirement could not be resolved."
                : (row.disposition == "excluded" ? "Excluded from the selected comparison scope." : "No requirement in the selected scope.")
            add(row.domain, DisplayItem(id: logicalID(row.domain, row.itemID), title: title(row.itemID, domain: row.domain), status: status,
                                       action: action, reason: row.disposition == "unresolved" || row.sourceStatus != "unknown"
                                        ? "Source status: " + row.sourceStatus : nil))
        }
        let owners = result.records.verificationRecords + result.records.operationRecords
        for (index, diagnostic) in result.records.diagnostics.enumerated() {
            let owner = owners.first { $0.recordID == diagnostic.recordID }
            let coverage = result.records.coverageRecords.first { $0.recordID == diagnostic.recordID }
            let domain = owner?.domain ?? coverage?.domain ?? "comparison"
            let identity = owner?.itemID ?? coverage?.itemID ?? "scope"
            // Correlate by the owner identity; retain matching facts and every diagnostic in the same row.
            let attention = ["warning", "error"].contains(diagnostic.severity)
            let fact = result.comparisonRecords.first { $0.recordID == diagnostic.recordID }
            let expectedDiagnostic = fact.map { row in
                (diagnostic.code == "confirmed_mismatch" && ["missing", "differing"].contains(row.comparisonKind))
                    || (["observation_failed", "prerequisite_unmet", "unsupported_predicate"].contains(diagnostic.code) && row.comparisonKind == "unverified")
            } ?? false
            // Expected predicate diagnostics explain the typed result; independent warnings retain attention.
            add(domain, DisplayItem(id: owner != nil || coverage != nil ? logicalID(domain, identity) : "diagnostic:\(index)", title: title(identity, domain: domain), status: attention && !expectedDiagnostic ? .attention : .information,
                                    action: expectedDiagnostic ? "" : (attention ? diagnosticMessage(diagnostic.code) : "Additional comparison information is available."),
                                    reason: diagnostic.severity + ": " + diagnostic.code + "\nPhase: " + diagnostic.phase + "\nRecord: " + diagnostic.recordID
                                    + (coverage.map { "\nSource status: " + $0.sourceStatus } ?? "")))
        }
        var dependentRepositoryRecords = Set<String>()
        var collapsedRepositoryIDs = Set<String>()
        // Summarize only the proven absent-worktree + blocked origin/branch combination.
        for identity in repositoryIDs {
            let rows = result.comparisonRecords.filter { $0.domain == "git-repositories" && $0.itemID == identity }
            let predicates = result.records.verificationRecords.filter { $0.domain == "git-repositories" && $0.itemID == identity }
            let facts = Dictionary(grouping: predicates, by: { $0.predicate ?? "" })
            guard rows.count == 3, predicates.count == 3,
                  Set(facts.keys) == Set(["worktree", "origin", "branch"]), facts.values.allSatisfy({ $0.count == 1 }) else { continue }
            func absentOrDependent(_ owner: CoreComparisonResult.Owner) -> Bool {
                guard let row = rows.first(where: { $0.recordID == owner.recordID }), row.support == "supported" else { return false }
                let codes = result.records.diagnostics.filter { $0.recordID == owner.recordID }.map(\.code)
                return owner.predicate == "worktree"
                    ? row.comparisonKind == "missing" && row.reason == "confirmed_mismatch" && Set(codes) == Set(["confirmed_mismatch"])
                    : row.comparisonKind == "unverified" && (row.reason == nil || row.reason == "prerequisite_unmet") && Set(codes) == Set(["prerequisite_unmet"])
            }
            let valid = predicates.allSatisfy(absentOrDependent)
            if let worktree = facts["worktree"]?.first, absentOrDependent(worktree) {
                // Even in a mixed failure, blocked dependent checks are not independent issues.
                dependentRepositoryRecords.formUnion(predicates.filter {
                    $0.predicate != "worktree" && absentOrDependent($0)
                }.map(\.recordID))
            }
            let ownerIDs = Set(predicates.map(\.recordID))
            let related = result.records.coverageRecords.filter { $0.domain == "git-repositories" && $0.itemID == identity }
            guard valid, related.allSatisfy({ $0.disposition == "resolved" || $0.disposition == "excluded" }),
                  !result.records.operationRecords.contains(where: { $0.domain == "git-repositories" && $0.itemID == identity }),
                  !result.records.diagnostics.contains(where: { diagnostic in
                      related.contains(where: { $0.recordID == diagnostic.recordID }) && !ownerIDs.contains(diagnostic.recordID)
                  }), let index = grouped["git-repositories"]?.firstIndex(where: { $0.id == logicalID("git-repositories", identity) }) else { continue }
            collapsedRepositoryIDs.insert(identity)
            let previous = grouped["git-repositories"]![index]
            grouped["git-repositories"]![index] = DisplayItem(id: previous.id, title: previous.title, status: .missing,
                action: "Repository not found on this Mac. Its remote and branch could not be verified.", reason: previous.reason)
        }
        // Finalize one repository explanation after all facts and independent diagnostics.
        // Missing is reserved for an explicitly absent worktree; a missing origin is Different.
        var incompleteRepositoryEvidence = false
        for identity in repositoryIDs {
            guard let index = grouped["git-repositories"]?.firstIndex(where: { $0.id == logicalID("git-repositories", identity) }) else { continue }
            let previous = grouped["git-repositories"]![index]
            let facts = technicalFacts[previous.id] ?? []
            if collapsedRepositoryIDs.contains(identity) { continue }
            let complete = facts.count == 3 && Set(facts.compactMap(\.predicate)) == Set(["worktree", "origin", "branch"])
            let status: DisplayStatus
            let explanation: String
            if previous.status == .noRequirement && facts.isEmpty { continue }
            if !complete || facts.contains(where: { $0.result == "unverified" || $0.support == "unsupported" })
                || [.attention, .unresolved].contains(previous.status) {
                status = facts.contains(where: { $0.support == "unsupported" }) ? .unsupported : .unverified
                explanation = "Couldn’t fully check this repository. View Log for the failed checks."
                if !complete { incompleteRepositoryEvidence = true }
            } else if facts.contains(where: { $0.predicate == "worktree" && $0.result == "missing" && $0.reason == "confirmed_mismatch" }) {
                status = .missing
                explanation = "Repository worktree was not found on this Mac."
            } else if facts.contains(where: { ["missing", "differing"].contains($0.result) }) {
                status = .different
                explanation = "Repository checks differ from the selected reference."
            } else {
                status = .matching
                explanation = "Matches the selected reference."
            }
            grouped["git-repositories"]![index] = DisplayItem(id: previous.id, title: previous.title,
                status: status, action: explanation, reason: previous.reason)
        }
        for (index, item) in result.extra.items.enumerated() {
            add(item.domain, DisplayItem(id: "extra:\(index)", title: title(item.itemID, domain: item.domain), status: .extra,
                                        action: "Present on this Mac outside the complete source inventory. Nothing will be removed.",
                                        reason: (["Domain: " + item.domain, "Item: " + item.itemID]
                                            + result.extra.domains.filter { $0.domain == item.domain }.map {
                                                "Extra evidence: " + $0.status + " · Count: " + String($0.count ?? 0)
                                                    + ($0.reason.map { " · " + $0 } ?? "")
                                            }).joined(separator: "\n")))
        }
        for domain in result.extra.domains where domain.status == "unavailable" && grouped[domain.domain] != nil {
            add(domain.domain, DisplayItem(id: "extra-availability:" + domain.domain, title: "Extra-item evidence", status: .information,
                                          action: "Unavailable. Extra items cannot be determined for this category.", reason: domain.reason))
        }
        let names: [String: (String, String)] = [
            "homebrew-packages": ("Homebrew Packages", "shippingbox"), "homebrew-casks": ("Homebrew Applications", "app"),
            "app-store": ("App Store Applications", "app"), "vscode-extensions": ("VS Code Extensions", "puzzlepiece.extension"),
            "vscode-settings": ("VS Code Settings", "slider.horizontal.3"), "git-configuration": ("Git Configuration", "gearshape"),
            "git-repositories": ("Git Repositories", "folder"), "vscode-workspaces": ("VS Code Workspaces", "folder"), "workspace-folders": ("Workspace Folders", "folder"),
            "ssh-configuration": ("SSH Configuration", "key"), "shell-zsh": ("Shell Configuration", "terminal"),
            "macos-finder": ("Finder", "finder"), "macos-dock": ("Dock", "dock.rectangle"),
            "macos-windows": ("Windows", "macwindow"), "macos-keyboard": ("Keyboard", "keyboard"),
            "macos-trackpad": ("Trackpad", "hand.draw"), "macos-screenshots": ("Screenshots", "camera"),
            "comparison": ("Comparison", "checkmark.circle"), "blueprint": ("Blueprint", "doc.text")]
        categories = order.map { domain in
            DisplayCategory(id: domain, title: names[domain]?.0 ?? domain, symbol: names[domain]?.1 ?? "folder", items: grouped[domain]!)
        }
        sections = EnvironmentStatusSection.project(categories, groups: result.referencePresentation?.groups ?? [])
        let independentUnverified = result.comparisonRecords.contains { $0.comparisonKind == "unverified" && !dependentRepositoryRecords.contains($0.recordID) }
        let independentDiagnostics = result.records.diagnostics.filter { diagnostic in
            guard ["warning", "error"].contains(diagnostic.severity) else { return false }
            if dependentRepositoryRecords.contains(diagnostic.recordID) && diagnostic.code == "prerequisite_unmet" { return false }
            if diagnostic.code == "confirmed_mismatch", let fact = result.comparisonRecords.first(where: { $0.recordID == diagnostic.recordID }),
               ["missing", "differing"].contains(fact.comparisonKind) { return false }
            return true
        }
        needsAttention = incompleteRepositoryEvidence || result.comparison.verdict == "incomplete" || independentUnverified
            || result.records.coverageRecords.contains { $0.disposition == "unresolved" }
            || !independentDiagnostics.isEmpty
            || (result.comparison.alsoIncomplete && result.comparison.counts["unverified"] == 0 && result.comparison.counts["unresolved"] == 0)
        let attentionIDs = Set(result.comparisonRecords.filter {
            $0.comparisonKind == "unverified" && !dependentRepositoryRecords.contains($0.recordID)
        }.map(\.recordID) + result.records.coverageRecords.filter { $0.disposition == "unresolved" }.map(\.recordID))
        // Unsupported is already inside Unverified. Independent diagnostics without a
        // counted owner, or incomplete predicate sets, have no trustworthy numeric total.
        attentionCount = !needsAttention ? 0 : (!incompleteRepositoryEvidence && !attentionIDs.isEmpty
            && independentDiagnostics.allSatisfy { attentionIDs.contains($0.recordID) } ? attentionIDs.count : nil)
        if needsAttention {
            headline = "Needs Attention"
            message = "Some requirements could not be verified. Review the affected categories."
        } else if result.comparison.verdict == "differences_detected" {
            headline = "Differences Found"
            message = "Differences were found in the selected scope."
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

struct ComparisonTechnicalFact: Identifiable {
    let recordID: String
    let predicate: String?
    let result: String
    let reason: String?
    let phase: String?
    let support: String
    let diagnostics: [CoreComparisonResult.Diagnostic]
    var id: String { recordID }
    var predicateTitle: String { predicate.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "Requirement" }
    var resultTitle: String {
        switch result { case "matching": "Matching"; case "differing": "Different"; case "missing": "Missing"; default: support == "unsupported" ? "Unsupported" : "Unverified" }
    }
    var phases: [String] { Array(Set(([phase].compactMap { $0 } + diagnostics.map(\.phase)).filter { !$0.isEmpty })).sorted() }
    var codes: [String] { Array(Set([reason].compactMap { $0 } + diagnostics.map(\.code))).sorted() }
}

struct EnvironmentStatusSection: Identifiable {
    struct Entry: Identifiable {
        let category: DisplayCategory
        let children: [DisplayCategory]
        var id: String { category.id }
    }
    let id: String
    let entries: [Entry]
    static func project(_ categories: [DisplayCategory], groups: [CoreRestoreInspection.Group]) -> [Self] {
        let order = ["Applications & Tools", "Settings", "Git", "SSH Configuration", "Workspace", "Shell"]
        var used = Set<String>()
        let projected = RestorePresentationSection.project(groups)
        var sections: [Self] = []
        for title in order {
            var domains = projected.first { $0.id == title }?.groups.flatMap(\.domains) ?? []
            if title == "Workspace" {
                domains = ["workspace-folders", "git-repositories", "vscode-workspaces"].filter(domains.contains)
            }
            if title == "Applications & Tools" {
                domains = ["homebrew-casks", "app-store", "homebrew-packages", "vscode-extensions"].filter(domains.contains)
            }
            var entries: [Entry] = []
            if title == "Settings" {
                let children = CaptureMacOSSettingsGroup.domainIDs.compactMap { id in categories.first { $0.id == id } }
                if !children.isEmpty {
                    let aggregate = DisplayCategory(id: "macos-settings", title: "macOS Settings", symbol: "slider.horizontal.3", items: children.flatMap(\.items))
                    entries.append(Entry(category: aggregate, children: children))
                    used.formUnion(children.map(\.id))
                }
            }
            for domain in domains where !used.contains(domain) {
                if let category = categories.first(where: { $0.id == domain }) {
                    entries.append(Entry(category: category, children: [])); used.insert(domain)
                }
            }
            if !entries.isEmpty { sections.append(Self(id: title, entries: entries)) }
        }
        let other = categories.filter { !used.contains($0.id) }.map { Entry(category: $0, children: []) }
        if !other.isEmpty { sections.append(Self(id: "Other Findings", entries: other)) }
        return sections
    }
}

extension DisplayItem {
    var isNormalComparisonMatch: Bool { status == .matching }
    var comparisonExplanation: String? { isNormalComparisonMatch || action.isEmpty ? nil : action }
    var comparisonTechnicalDetails: String? {
        guard !isNormalComparisonMatch, let reason, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return reason
    }
}

extension DisplayCategory {
    var comparisonStatus: DisplayStatus {
        let statuses = Set(items.map(\.status))
        if statuses.contains(.attention) || statuses.contains(.unresolved) { return .attention }
        if statuses.contains(.unverified) || statuses.contains(.unsupported) { return .attention }
        if statuses.contains(.missing) || statuses.contains(.different) { return .different }
        if statuses.contains(.matching) { return .matching }
        if statuses.contains(.extra) { return .extra }
        return .noRequirement
    }
    var comparisonStatusText: String {
        comparisonStatus == .different ? "Differences Found" : comparisonStatus.rawValue
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

    var restoreReviewBundle: URL? {
        guard state == .result, let bundle = reference?.bundle, let presentation,
              presentation.counts["differing", default: 0] > 0 || presentation.counts["missing", default: 0] > 0 else { return nil }
        return bundle
    }

    func selectBundle(_ bundle: URL) {
        guard !runtime.isActive, state != .running else { return }
        reference = EnvironmentReference(bundle: bundle, generatedDirectory: bundle, blueprint: nil)
        reset()
    }
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
            if reference.bundle != nil, runtime.bundleComparisonSupported != true { throw StatusFailure.unsupportedCapability }
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
                case .cancelled: reset() // Keep the selected reference; confirmed cancellation has no result screen.
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
