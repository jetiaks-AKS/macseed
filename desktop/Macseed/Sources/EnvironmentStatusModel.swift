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
        case .noReference: "Choose a Saved Environment (.mbt) to check against this Mac."
        case .unsupportedCapability: "Check is unavailable in this build. Check the app setup or update Macseed."
        case .referenceUnavailable: "The selected Saved Environment is unavailable. Choose an accessible file or restore access."
        case .invalidResult: "Check results are incomplete. Check again to inspect the current state."
        case .cancelled: "Check cancelled. Check again to inspect current state."
        case .interrupted: "Check was interrupted. Check again to inspect the current state."
        case .runtime(.coreFailure(let code)):
            switch code {
            case "bundle_unavailable": "The selected Saved Environment is unavailable. Choose an accessible file."
            case "bundle_invalid": "The selected Saved Environment is invalid or corrupted. Choose a valid Bundle."
            case "unsupported_bundle": "This Saved Environment uses an unsupported Bundle format."
            case "reference_unavailable": "The selected reference is unavailable. Choose an accessible saved configuration or Blueprint."
            case "reference_invalid": "The selected configuration or Blueprint is invalid. Choose a valid reference."
            case "reference_changed": "The reference changed during the check. Check again against its current contents."
            case "comparison_reporting_incomplete": "Check results are incomplete. Check again to inspect the current state."
            case "comparison_unavailable": "Check could not finish. Check again to inspect the current state."
            case "comparison_failed": "Check failed. Review the saved environment and try again."
            default: "Couldn’t check this Mac against the selected saved environment."
            }
        case .runtime(.runtimeUnavailable), .runtime(.pythonUnavailable), .runtime(.invalidRuntimeConfiguration), .runtime(.writableCoreRequired), .runtime(.incompatibleProtocol):
            "Check is unavailable in this build. Check the app setup or update Macseed."
        case .runtime: "Check was interrupted. Check again to inspect the current state."
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
    private(set) var counts: [String: Int]
    let secureCoverage: String?
    let secureRequiresRetry: Bool
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

    init(_ result: CoreComparisonResult, secureCheck: CoreSecureCheckResult? = nil, inventory: CoreRestoreIdentityInventory? = nil) throws {
        try result.validate()
        if let secureCheck {
            guard result.secureCheck?.status == "available", result.secureCheck?.bundleID == secureCheck.bundleID else { throw StatusFailure.invalidResult }
            try secureCheck.validate(operationID: secureCheck.operationID, mapping: secureCheck.context.mapping)
        }
        let reconciled = Set(result.records.coverageRecords.filter {
            secureCheck?.context.sshReferenceCoverage == "resolved" && $0.domain == "ssh-configuration"
                && $0.itemID == "identity-references" && $0.disposition == "unresolved"
        }.map(\.recordID))
        let coverageRecords = result.records.coverageRecords.filter { !reconciled.contains($0.recordID) }
        let diagnostics = result.records.diagnostics.filter {
            !(reconciled.contains($0.recordID) && $0.code == "prerequisite_unmet")
        }
        let protectedScope = result.secureCheck?.status == "available"
        let savedIDs = secureCheck?.context.mapping.items.map(\.identityID)
            ?? (inventory?.bundleID == result.secureCheck?.bundleID ? inventory?.items.map(\.id) : nil)
        let observedIDs = Set(secureCheck?.items.map(\.identityID) ?? [])
        let uncheckedIDs = savedIDs?.filter { !observedIDs.contains($0) } ?? []
        let uncheckedScope = protectedScope && (savedIDs == nil || !uncheckedIDs.isEmpty)
        secureRequiresRetry = uncheckedScope || secureCheck?.items.contains { $0.comparisonKind != "matching" } == true
        counts = result.comparison.counts
        counts["unverified", default: 0] += uncheckedIDs.count
        counts["unresolved", default: 0] -= reconciled.count
        for item in secureCheck?.items ?? [] { counts[item.comparisonKind, default: 0] += 1 }
        if result.secureCheck?.status == "available" {
            secureCoverage = secureCheck.map { "\($0.items.count) of \($0.context.mapping.items.count) SSH keys checked. Remote SSH authentication was not tested." }
                ?? "SSH keys have not been checked. Retry inside SSH Keys."
        } else { secureCoverage = nil }
        technicalFacts = Dictionary(grouping: result.comparisonRecords.filter { ["git-repositories", "vscode-workspaces"].contains($0.domain) }, by: { $0.domain + ":" + $0.itemID }).mapValues { rows in
            rows.map { row in
                let owners = result.records.verificationRecords.filter { $0.recordID == row.recordID }
                let owner = owners.count == 1 && owners[0].domain == row.domain && owners[0].itemID == row.itemID ? owners[0] : nil
                return ComparisonTechnicalFact(recordID: row.recordID,
                    predicate: owner?.predicate,
                    result: row.comparisonKind, reason: row.reason, phase: row.phase, support: row.support,
                    diagnostics: diagnostics.filter { $0.recordID == row.recordID })
            }.sorted {
                let order = ["topology", "folder_relationships", "worktree", "origin", "branch"]
                return (order.firstIndex(of: $0.predicate ?? "") ?? order.count, $0.recordID)
                    < (order.firstIndex(of: $1.predicate ?? "") ?? order.count, $1.recordID)
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
            + coverageRecords.filter { $0.domain == "git-repositories" && $0.disposition != "excluded" }.map(\.itemID)
            + result.records.verificationRecords.filter { $0.domain == "git-repositories" }.map(\.itemID)).sorted()
        let partialSSHCoverage = Set(coverageRecords.filter { coverage in
            coverage.domain == "ssh-configuration" && coverage.disposition == "unresolved"
                && coverage.sourceStatus == "partial" && coverage.itemID != "identity-references"
                && diagnostics.contains { $0.recordID == coverage.recordID && $0.code == "partial_source_coverage" && $0.phase == "scope" }
        }.map(\.itemID))
        func title(_ identity: String, domain: String) -> String {
            if domain == "ssh-configuration", partialSSHCoverage.contains(identity) { return "SSH configuration coverage" }
            if domain == "ssh-configuration", identity == "identity-references" { return "SSH key references" }
            if domain == "vscode-workspaces", identity != "scope" {
                if let label = result.referencePresentation?.workspaceLabels?[identity],
                   label.range(of: "^[\\w .()+-]{1,160}$", options: .regularExpression) != nil {
                    return label
                }
                return "VS Code Workspace"
            }
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
                                                                ["git-repositories", "vscode-workspaces"].contains(row.domain) || row.domain.hasPrefix("macos-") ? owner?.predicate.map { "Predicate: " + $0 } : nil].compactMap { $0 }.joined(separator: "\n")))
        }
        for row in coverageRecords where !["resolved", "excluded"].contains(row.disposition) {
            let status: DisplayStatus = row.disposition == "unresolved" ? .unresolved : (row.disposition == "excluded" ? .excluded : .noRequirement)
            let action = row.domain == "ssh-configuration" && row.itemID == "identity-references"
                ? (secureCheck?.items.allSatisfy { $0.comparisonKind == "matching" } == true
                    ? "Saved SSH key files match, but not every IdentityFile dependency is qualified. File equality alone does not prove that each configured reference identifies a usable key."
                    : "Not every configured IdentityFile path and key pair could be qualified. This does not establish that a key is missing or invalid.")
                : row.domain == "ssh-configuration" && partialSSHCoverage.contains(row.itemID) ? diagnosticMessage("partial_source_coverage")
                : row.disposition == "unresolved" ? "The selected reference requirement could not be resolved."
                : (row.disposition == "excluded" ? "Excluded from the selected comparison scope." : "No requirement in the selected scope.")
            add(row.domain, DisplayItem(id: logicalID(row.domain, row.itemID), title: title(row.itemID, domain: row.domain), status: status,
                                       action: action, reason: row.disposition == "unresolved" || row.sourceStatus != "unknown"
                                        ? "Source status: " + row.sourceStatus : nil))
        }
        let owners = result.records.verificationRecords + result.records.operationRecords
        for (index, diagnostic) in diagnostics.enumerated() {
            let owner = owners.first { $0.recordID == diagnostic.recordID }
            let coverage = coverageRecords.first { $0.recordID == diagnostic.recordID }
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
                                    action: expectedDiagnostic || (domain == "ssh-configuration" && identity == "identity-references" && diagnostic.code == "prerequisite_unmet") ? "" : (attention ? diagnosticMessage(diagnostic.code) : "Additional diagnostic information is available."),
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
                let codes = diagnostics.filter { $0.recordID == owner.recordID }.map(\.code)
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
            let related = coverageRecords.filter { $0.domain == "git-repositories" && $0.itemID == identity }
            guard valid, related.allSatisfy({ $0.disposition == "resolved" || $0.disposition == "excluded" }),
                  !result.records.operationRecords.contains(where: { $0.domain == "git-repositories" && $0.itemID == identity }),
                  !diagnostics.contains(where: { diagnostic in
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
            let topology = facts.count == 1 && facts[0].predicate == "topology"
            let complete = topology || (facts.count == 3 && Set(facts.compactMap(\.predicate)) == Set(["worktree", "origin", "branch"]))
            let status: DisplayStatus
            let explanation: String
            if previous.status == .noRequirement && facts.isEmpty { continue }
            if !complete || facts.contains(where: { $0.result == "unverified" || $0.support == "unsupported" })
                || [.attention, .unresolved].contains(previous.status) {
                status = facts.contains(where: { $0.support == "unsupported" }) ? .unsupported : .unverified
                explanation = "Couldn’t fully check this repository. View Log for the failed checks."
                if !complete { incompleteRepositoryEvidence = true }
            } else if facts.contains(where: { ["worktree", "topology"].contains($0.predicate ?? "") && $0.result == "missing" && $0.reason == "confirmed_mismatch" }) {
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
        // File presence alone cannot establish a descriptor's relationships.
        for (index, item) in (grouped["vscode-workspaces"] ?? []).enumerated() where item.status != .noRequirement {
            let facts = technicalFacts[item.id] ?? []
            if facts.count != 1 || facts[0].predicate != "folder_relationships" {
                incompleteRepositoryEvidence = true
                grouped["vscode-workspaces"]![index] = DisplayItem(id: item.id, title: item.title,
                    status: .unverified, action: "Couldn’t fully check this workspace’s folder relationships.", reason: item.reason)
            }
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
        if result.secureCheck?.status == "available" {
            if let secureCheck {
                for item in secureCheck.items {
                    let index = savedIDs?.firstIndex(of: item.identityID) ?? 0
                    let status: DisplayStatus = item.comparisonKind == "matching" ? .matching
                        : item.comparisonKind == "missing" ? .missing : item.comparisonKind == "differing" ? .different : .unverified
                    let explanation: String
                    switch item.reason {
                    case "pair_identical": explanation = "Private and public files match the saved bytes."
                    case "pair_absent": explanation = "Both files are absent at the checked destination."
                    case "private_bytes_differ": explanation = "Private-key bytes differ from the saved pair."
                    case "public_bytes_differ": explanation = "Public-key bytes differ from the saved pair."
                    case "pair_bytes_differ": explanation = "Private and public bytes differ from the saved pair."
                    case "partial_pair": explanation = "Only part of the key pair is present. The pair could not be verified."
                    case "target_changed": explanation = "The target changed during inspection. Check again."
                    case "unsafe_target": explanation = "The destination or key permissions could not be safely qualified."
                    default: explanation = "The destination could not be observed safely."
                    }
                    add("secure-ssh-identities", DisplayItem(id: "secure-check:" + item.identityID, title: "SSH key \(index + 1)",
                        status: status, action: explanation, reason: nil))
                }
            }
            for id in uncheckedIDs {
                add("secure-ssh-identities", DisplayItem(id: "secure-check:unchecked:" + id,
                    title: "SSH key \((savedIDs?.firstIndex(of: id) ?? 0) + 1)", status: .unverified,
                    action: "Not checked. Check Again verifies saved SSH keys at their configured locations.", reason: nil))
            }
            if savedIDs == nil {
                add("secure-ssh-identities", DisplayItem(id: "secure-check:unchecked", title: "Protected SSH keys",
                    status: .information, action: "Not checked. Ordinary settings were checked separately.", reason: nil))
            }
        }
        let names: [String: (String, String)] = [
            "secure-ssh-identities": ("SSH Keys", "key"),
            "homebrew-packages": ("Homebrew Packages", "shippingbox"), "homebrew-casks": ("Homebrew Applications", "app"),
            "app-store": ("App Store Applications", "app"), "vscode-extensions": ("VS Code Extensions", "puzzlepiece.extension"),
            "vscode-settings": ("VS Code Settings", "slider.horizontal.3"), "git-configuration": ("Git Configuration", "gearshape"),
            "git-repositories": ("Git Repositories", "folder"), "vscode-workspaces": ("VS Code Workspaces", "folder"), "workspace-folders": ("Workspace Folders", "folder"),
            "ssh-configuration": ("SSH Configuration", "key"), "shell-zsh": ("Shell Configuration", "terminal"),
            "macos-finder": ("Finder", "finder"), "macos-dock": ("Dock", "dock.rectangle"),
            "macos-windows": ("Windows", "macwindow"), "macos-keyboard": ("Keyboard", "keyboard"),
            "macos-trackpad": ("Trackpad", "hand.draw"), "macos-screenshots": ("Screenshots", "camera"),
            "comparison": ("Check", "checkmark.circle"), "blueprint": ("Blueprint", "doc.text")]
        categories = order.map { domain in
            DisplayCategory(id: domain, title: DeveloperSelectionGroup.label(domain, fallback: names[domain]?.0 ?? domain), symbol: names[domain]?.1 ?? "folder", items: grouped[domain]!)
        }
        sections = EnvironmentStatusSection.project(categories)
        let independentUnverified = result.comparisonRecords.contains { $0.comparisonKind == "unverified" && !dependentRepositoryRecords.contains($0.recordID) }
        let independentDiagnostics = diagnostics.filter { diagnostic in
            guard ["warning", "error"].contains(diagnostic.severity) else { return false }
            if dependentRepositoryRecords.contains(diagnostic.recordID) && diagnostic.code == "prerequisite_unmet" { return false }
            if diagnostic.code == "confirmed_mismatch", let fact = result.comparisonRecords.first(where: { $0.recordID == diagnostic.recordID }),
               ["missing", "differing"].contains(fact.comparisonKind) { return false }
            return true
        }
        needsAttention = uncheckedScope || incompleteRepositoryEvidence || (result.comparison.verdict == "incomplete" && reconciled.isEmpty) || independentUnverified
            || secureCheck?.items.contains(where: { $0.comparisonKind == "unverified" }) == true
            || coverageRecords.contains { $0.disposition == "unresolved" }
            || !independentDiagnostics.isEmpty
            || (result.comparison.alsoIncomplete && reconciled.isEmpty && result.comparison.counts["unverified"] == 0 && result.comparison.counts["unresolved"] == 0)
        let attentionIDs = Set(result.comparisonRecords.filter {
            $0.comparisonKind == "unverified" && !dependentRepositoryRecords.contains($0.recordID)
        }.map(\.recordID) + coverageRecords.filter { $0.disposition == "unresolved" }.map(\.recordID))
        // Unsupported is already inside Unverified. Independent diagnostics without a
        // counted owner, or incomplete predicate sets, have no trustworthy numeric total.
        let secureAttention = (secureCheck?.items.filter { $0.comparisonKind == "unverified" }.count ?? 0) + uncheckedIDs.count
        attentionCount = !needsAttention ? 0 : (!incompleteRepositoryEvidence && !(protectedScope && savedIDs == nil) && attentionIDs.count + secureAttention > 0
            && independentDiagnostics.allSatisfy { attentionIDs.contains($0.recordID) } ? attentionIDs.count + secureAttention : nil)
        if needsAttention {
            headline = uncheckedScope ? "Check Incomplete" : "Needs Attention"
            message = uncheckedScope ? "Saved SSH keys remain unchecked. Ordinary results and verified matches are retained."
                : "Some requirements could not be verified. Review the affected categories."
        } else if counts["missing", default: 0] + counts["differing", default: 0] > 0 {
            headline = "Differences Found"
            message = "Differences were found in the selected scope."
        } else {
            let empty = result.comparison.verdict == "no_comparable_requirements" && counts["matching", default: 0] == 0
            headline = empty ? "No comparable requirements" : "No differences detected"
            message = empty ? "The selected scope contains no comparable requirements."
                : "The compared requirements match the selected reference."
        }
        let labels = [("matching", "matching"), ("missing", "missing"), ("differing", "different"), ("unverified", "unverified"),
                      ("unsupported", "unsupported (within unverified)"), ("unresolved", "unresolved"), ("extra", "extra"),
                      ("unknown_difference", "unknown difference (within unverified)")]
        let summaryCounts = counts
        summary = labels.compactMap { key, label in
            let count = summaryCounts[key] ?? 0
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
    var predicateTitle: String {
        if predicate == "folder_relationships" { return "Folder relationships" }
        return predicate.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "Requirement"
    }
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
    // Check projects existing domain evidence only; no Selection state or Core taxonomy.
    static func project(_ categories: [DisplayCategory]) -> [Self] {
        var used = Set<String>()
        func category(_ id: String) -> DisplayCategory? {
            categories.first { $0.id == id && !$0.items.isEmpty }
        }
        func group(_ id: String, _ title: String, _ symbol: String, _ domains: [String]) -> Entry? {
            let children = domains.compactMap(category)
            guard !children.isEmpty else { return nil }
            used.formUnion(children.map(\.id))
            return Entry(category: DisplayCategory(id: id, title: title, symbol: symbol,
                items: children.flatMap(\.items)), children: children)
        }
        var standard = ["app-store", "homebrew-casks", "homebrew-packages"].compactMap { id -> Entry? in
            guard let value = category(id) else { return nil }
            used.insert(id)
            return Entry(category: value, children: [])
        }
        if let settings = group("macos-settings", "macOS Settings", "slider.horizontal.3", CaptureMacOSSettingsGroup.domainIDs) {
            standard.append(settings)
        }
        if let extras = group(CaptureHierarchy.Group.vscode.id, "Application Extras", "puzzlepiece.extension", ["vscode-extensions", "vscode-settings"]) {
            standard.append(extras)
        }
        let developer: [Entry] = [DeveloperSelectionGroup.git, .workspace, .ssh, .shell].compactMap { value in
            group(value.id, value.title, value.symbol, value.domains.map {
                $0 == CaptureHierarchy.secureTransferID ? CoreRestorePreparation.secureDomain : $0
            })
        }
        // Unknown future domains retain their own names/evidence in Standard Setup.
        // Never drop a diagnostic simply because it has no presentation group yet.
        standard += categories.filter { !used.contains($0.id) && !$0.items.isEmpty }.map { Entry(category: $0, children: []) }
        return [Self(id: "Standard Setup", entries: standard), Self(id: "For Experienced Users", entries: developer)]
            .filter { !$0.entries.isEmpty }
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
        if id == "secure-ssh-identities", items.allSatisfy({ $0.id.hasPrefix("secure-check:unchecked") }) { return .information }
        if statuses.contains(.attention) || statuses.contains(.unresolved) { return .attention }
        if statuses.contains(.unverified) || statuses.contains(.unsupported) { return .attention }
        if statuses.contains(.missing) || statuses.contains(.different) { return .different }
        if id == CaptureHierarchy.sshID && items.contains(where: { $0.id.hasPrefix("secure-check:unchecked") }) { return .information }
        if statuses.contains(.matching) { return .matching }
        if statuses.contains(.extra) { return .extra }
        if id == "secure-ssh-identities", statuses.contains(.information) { return .information }
        return .noRequirement
    }
    var comparisonStatusText: String {
        if id == "secure-ssh-identities", comparisonStatus == .information { return "Not checked" }
        if id == CaptureHierarchy.sshID, comparisonStatus == .information { return "Partially checked" }
        return comparisonStatus == .different ? "Differences Found" : comparisonStatus.rawValue
    }
}

enum EnvironmentStatusState { case choose, running, result, failed, cancelled }

@MainActor final class EnvironmentStatusModel: ObservableObject {
    @Published private(set) var reference: EnvironmentReference?
    @Published private(set) var state: EnvironmentStatusState = .choose
    @Published private(set) var presentation: EnvironmentStatusPresentation?
    @Published private(set) var failure: StatusFailure?
    @Published private(set) var operationID: String?
    @Published private(set) var secureBusy = false
    @Published private(set) var secureMessage: String?
    @Published private(set) var secureInventory: CoreRestoreIdentityInventory?
    @Published private(set) var selectedSecureIDs: Set<String> = []
    @Published private(set) var secureDirectories: [String: String] = [:]
    @Published private(set) var showsSecureSelection = false
    private struct SecureSelectionDraft {
        let bundle: URL
        let bundleID: String
        let checkID: String?
        let inventoryIDs: Set<String>
        let originalSelection: Set<String>
        let originalDirectories: [String: String]
        var selection: Set<String>
        var directories: [String: String]
    }
    @Published private var secureDraft: SecureSelectionDraft?
    var draftSecureIDs: Set<String> { secureDraft?.selection ?? [] }
    var draftSecureDirectories: [String: String] { secureDraft?.directories ?? [:] }
    private var ordinaryResult: CoreComparisonResult?
    private var checkedKeys: CoreSecureCheckResult?
    @Published private(set) var secureChallenge: CoreSecureChallenge?
    @Published private(set) var requiresFullCheck = false
    private var secureOperationID: String?
    private var challengeObservation: AnyCancellable?
    // A one-use, 120-second handoff inside the same read-only Check. Never a
    // credential cache, Restore authorization or a response to an unrelated op.
    private var unlockHandoff: (bundleID: String, secret: Data)?
    private var unlockExpiry: Task<Void, Never>?
    let runtime: CoreRuntime
    private let location: CoreLocation?
    private var work: Task<Void, Never>?
    init(runtime: CoreRuntime, location: CoreLocation? = nil) {
        self.runtime = runtime; self.location = location
        challengeObservation = runtime.$secureChallenge.sink { [weak self] challenge in
            Task { @MainActor [weak self] in self?.receiveSecureChallenge(challenge) }
        }
    }
    private func clearUnlockHandoff() {
        unlockExpiry?.cancel(); unlockExpiry = nil
        let count = unlockHandoff?.secret.count ?? 0
        unlockHandoff?.secret.resetBytes(in: 0..<count); unlockHandoff = nil
    }
    private func receiveSecureChallenge(_ challenge: CoreSecureChallenge?) {
        guard runtime.secureChallenge == challenge else { return }
        guard let challenge else { secureChallenge = nil; return }
        guard secureBusy, challenge.operationID == secureOperationID, runtime.secureChallenge == challenge else { return }
        if runtime.operation == .secureCheckCompare, challenge.kind == .bundleUnlock, challenge.attempt == 1,
           let handoff = unlockHandoff, handoff.bundleID == ordinaryResult?.secureCheck?.bundleID {
            clearUnlockHandoff()
            runtime.respond(to: challenge, with: .secret(handoff.secret))
            return
        }
        if challenge.attempt > 1 { clearUnlockHandoff() }
        secureChallenge = challenge
    }
    func respondToSecureCheck(_ challenge: CoreSecureChallenge, _ response: CoreSecureResponse) {
        guard secureBusy, challenge == secureChallenge, challenge.operationID == secureOperationID else { return }
        if runtime.operation == .secureCheckInventory, challenge.kind == .bundleUnlock,
           case .secret(let bytes) = response, let id = ordinaryResult?.secureCheck?.bundleID {
            clearUnlockHandoff(); unlockHandoff = (id, bytes)
            unlockExpiry = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(120)) } catch { return }
                self?.clearUnlockHandoff()
            }
        }
        if !runtime.respond(to: challenge, with: response) { clearUnlockHandoff() }
        secureChallenge = nil
    }

    var restoreReviewBundle: URL? {
        guard state == .result, let bundle = reference?.bundle, let presentation,
              presentation.counts["differing", default: 0] > 0 || presentation.counts["missing", default: 0] > 0 else { return nil }
        return bundle
    }

    func selectBundle(_ bundle: URL) {
        guard !runtime.isActive, !secureBusy, state != .running else { return }
        reference = EnvironmentReference(bundle: bundle, generatedDirectory: bundle, blueprint: nil)
        reset()
    }
    func selectReference(_ directory: URL) {
        guard !runtime.isActive, !secureBusy, state != .running else { return }
        reference = EnvironmentReference(generatedDirectory: directory, blueprint: nil)
        reset()
    }
    func selectBlueprint(_ blueprint: URL?) {
        guard !runtime.isActive, !secureBusy, state != .running, let reference else { return }
        self.reference = EnvironmentReference(generatedDirectory: reference.generatedDirectory, blueprint: blueprint)
        reset()
    }
    private func reset() {
        clearUnlockHandoff(); secureChallenge = nil; requiresFullCheck = false
        state = .choose; presentation = nil; failure = nil; operationID = nil
        ordinaryResult = nil; checkedKeys = nil; secureInventory = nil
        selectedSecureIDs = []; secureDirectories = [:]; secureMessage = nil; discardSecureDraft()
    }
    var secureCheckAvailable: Bool { ordinaryResult?.secureCheck?.status == "available" }
    var canCheckSSHKeys: Bool { state == .result && secureCheckAvailable && runtime.secureCheckSupported && !runtime.isActive && !secureBusy && !requiresFullCheck }
    var canRetrySSHKeys: Bool { canCheckSSHKeys && presentation?.secureRequiresRetry == true }
    var showsSecureRecovery: Bool { secureCheckAvailable && (secureBusy || presentation?.secureRequiresRetry == true) }
    var secureCoverageMessage: String? {
        guard secureCheckAvailable else { return nil }
        if secureBusy { return "Checking SSH keys… Nothing will be changed." }
        if let secureMessage { return secureMessage }
        if !runtime.secureCheckSupported { return "SSH key checking is unavailable in this Core version. Protected keys were not checked." }
        return presentation?.secureCoverage
    }
    private func beginSecureDraft(selectAll: Bool = false) {
        guard let bundle = reference?.bundle, let inventory = secureInventory,
              inventory.bundleID == ordinaryResult?.secureCheck?.bundleID else { return }
        secureDraft = SecureSelectionDraft(bundle: bundle, bundleID: inventory.bundleID, checkID: operationID,
            inventoryIDs: Set(inventory.items.map(\.id)), originalSelection: selectedSecureIDs,
            originalDirectories: secureDirectories, selection: selectAll ? Set(inventory.items.map(\.id)) : selectedSecureIDs, directories: secureDirectories)
        showsSecureSelection = true
    }
    private func discardSecureDraft() { secureDraft = nil; showsSecureSelection = false }
    private var secureDraftIsCurrent: Bool {
        guard let draft = secureDraft, let inventory = secureInventory else { return false }
        return reference?.bundle == draft.bundle && ordinaryResult?.secureCheck?.bundleID == draft.bundleID
            && inventory.bundleID == draft.bundleID && operationID == draft.checkID
            && Set(inventory.items.map(\.id)) == draft.inventoryIDs
            && selectedSecureIDs == draft.originalSelection && secureDirectories == draft.originalDirectories
    }
    func selectSecureIdentity(_ id: String, included: Bool) {
        guard !secureBusy, showsSecureSelection, secureDraftIsCurrent, secureDraft?.inventoryIDs.contains(id) == true else { return }
        if included { secureDraft?.selection.insert(id) } else { secureDraft?.selection.remove(id) }
    }
    func setSecureDirectory(_ directory: String?, for id: String) {
        guard !secureBusy, showsSecureSelection, secureDraftIsCurrent, secureDraft?.inventoryIDs.contains(id) == true else { return }
        secureDraft?.directories[id] = directory
    }
    private func clearSecureEvidence() {
        checkedKeys = nil
        if let ordinaryResult { presentation = try? EnvironmentStatusPresentation(ordinaryResult, inventory: secureInventory) }
    }
    func cancelSecureSelection() {
        discardSecureDraft()
    }
    func checkSSHKeys() {
        guard canCheckSSHKeys, !showsSecureSelection else { return }
        secureBusy = true
        work = Task { await runSecureCheck() }
    }
    func customizeSSHKeys() {
        guard canCheckSSHKeys, !showsSecureSelection else { return }
        if secureInventory?.bundleID == ordinaryResult?.secureCheck?.bundleID {
            beginSecureDraft(selectAll: selectedSecureIDs.isEmpty); return
        }
        secureBusy = true
        work = Task { await runSecureCheck(customizing: true) }
    }
    func compareSSHKeys() {
        guard canCheckSSHKeys, showsSecureSelection, let draft = secureDraft else { return }
        guard secureDraftIsCurrent else {
            discardSecureDraft(); requiresFullCheck = true
            secureMessage = "The comparison context changed. Run the full Check Again."; return
        }
        guard !draft.selection.isEmpty, draft.selection.isSubset(of: draft.inventoryIDs) else { return }
        selectedSecureIDs = draft.selection; secureDirectories = draft.directories
        discardSecureDraft(); secureBusy = true
        work = Task { await runSecureCheck(useSelection: true) }
    }
    private func runSecureCheck(customizing: Bool = false, useSelection: Bool = false) async {
        guard let bundle = reference?.bundle, let id = ordinaryResult?.secureCheck?.bundleID,
              runtime.secureCheckSupported else { secureBusy = false; return }
        if !customizing { clearSecureEvidence(); secureMessage = nil }
        secureBusy = true
        defer { clearUnlockHandoff(); secureBusy = false; secureChallenge = nil; secureOperationID = nil }
        func run(_ request: CoreRequest) async -> Bool {
            secureOperationID = request.operationID
            runtime.start(request, location: location)
            await runtime.waitForCompletion()
            guard runtime.operationID == request.operationID, reference?.bundle == bundle,
                  ordinaryResult?.secureCheck?.bundleID == id else {
                requiresFullCheck = true; secureMessage = "The comparison context changed. Run the full Check Again."; return false
            }
            guard runtime.state == .completed else {
                secureMessage = runtime.state == .cancelled
                    ? "Authentication cancelled. SSH keys were not checked; ordinary results are retained."
                    : Self.secureFailure(runtime.error)
                if runtime.error == .coreFailure("reference_changed") || runtime.error == .coreFailure("secure_target_changed") || runtime.error == .secureChannelInvalid {
                    requiresFullCheck = true; secureInventory = nil; selectedSecureIDs = []; secureDirectories = [:]
                    secureMessage = "The saved environment or protected comparison context changed. Run the full Check Again."
                }
                return false
            }
            return true
        }
        var loadedInventory = false
        if secureInventory?.bundleID != id {
            guard await run(CoreRequest(.secureCheckInventory(path: bundle.path, bundleID: id))),
                  let value = runtime.takeRestoreIdentityInventory(), value.bundleID == id else { return }
            secureInventory = value; loadedInventory = true
            if !customizing {
                selectedSecureIDs = Set(value.items.map(\.id)); secureDirectories = [:]
                clearSecureEvidence()
            }
        }
        if customizing { beginSecureDraft(selectAll: loadedInventory); return }
        guard let inventory = secureInventory else { return }
        if !useSelection { selectedSecureIDs = Set(inventory.items.map(\.id)) }
        let mapping = CoreRestoreDestinations(version: 2, bundleID: id, items: inventory.items.map {
            CoreRestoreDestinations.Item(identityID: $0.id, directory: secureDirectories[$0.id], selected: selectedSecureIDs.contains($0.id))
        }.sorted { $0.identityID < $1.identityID })
        guard await run(CoreRequest(.secureCheckCompare(path: bundle.path, bundleID: id), restoreDestinations: mapping)) else { return }
        guard let value = runtime.takeSecureCheck(), let ordinaryResult else {
            secureMessage = "SSH key results are incomplete. Check Again inside SSH Keys."; return
        }
        do { presentation = try EnvironmentStatusPresentation(ordinaryResult, secureCheck: value); checkedKeys = value }
        catch { requiresFullCheck = true; secureMessage = "The comparison context changed. Run the full Check Again." }
    }
    static func secureFailure(_ error: CoreRuntimeError?) -> String {
        switch error {
        case .coreFailure("reference_changed"): "The Saved Environment changed. Run Check Again before checking SSH keys."
        case .coreFailure("secure_component_unavailable"): "This Saved Environment has no protected SSH keys to check."
        case .coreFailure("secure_decrypt_failed"), .coreFailure("secure_unlock_rejected"): "The Bundle passphrase was not accepted, or the encrypted package could not be decrypted. SSH keys were not checked."
        case .coreFailure("secure_target_changed"): "The identity selection no longer matches this package. Unlock it again."
        case .coreFailure("secure_payload_invalid"): "The encrypted identity package could not be validated. SSH keys were not checked."
        default: "SSH keys could not be checked. Ordinary Check results are retained; retry the protected check."
        }
    }

    func compare() {
        guard !runtime.isActive, !secureBusy, state != .running else { return }
        clearUnlockHandoff(); requiresFullCheck = false
        checkedKeys = nil; secureMessage = nil; discardSecureDraft()
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
                        let value = try event.decodeData(CoreComparisonResult.self)
                        presentation = try EnvironmentStatusPresentation(value)
                        if secureInventory?.bundleID != value.secureCheck?.bundleID {
                            secureInventory = nil; selectedSecureIDs = []; secureDirectories = [:]
                        }
                        ordinaryResult = value
                        if secureCheckAvailable { await runSecureCheck() }
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
    func cancel() { clearUnlockHandoff(); if state == .running || secureBusy { runtime.cancel() } }
    func waitForCompletion() async { await work?.value }
}
