import Foundation
import AppKit
import SwiftUI

@main struct EnvironmentStatusTests {
    typealias Object = [String: Any]
    static func row(_ id: Int, _ kind: String, support: String = "supported", reason: String? = nil) -> Object {
        ["record_id": "v:\(id)", "domain": "homebrew-packages", "item_id": "item-\(id)",
         "comparison_kind": kind, "support": support, "reason": reason ?? NSNull(), "phase": NSNull()]
    }
    static func payload(_ rows: [Object], verdict: String, unresolved: Bool = false,
                        extras: Object = ["domains": [], "items": []], alsoIncomplete: Bool = false) -> Object {
        var counts = ["matching": 0, "missing": 0, "differing": 0, "unverified": 0, "unsupported": 0,
                      "unresolved": unresolved ? 1 : 0, "extra": (extras["items"] as! [Object]).count, "unknown_difference": 0]
        for row in rows {
            counts[row["comparison_kind"] as! String, default: 0] += 1
            if row["support"] as! String == "unsupported" { counts["unsupported", default: 0] += 1 }
            if row["reason"] as? String == "unknown_difference" { counts["unknown_difference", default: 0] += 1 }
        }
        let coverage: [Object] = unresolved ? [["record_id": "c:0", "domain": "homebrew-packages", "item_id": "unknown",
                                                "disposition": "unresolved", "source_status": "unknown"]] : []
        return ["read_only": true, "publication_occurred": false, "target_mutation_may_have_started": false,
                "comparison": ["status": "complete", "verdict": verdict, "also_incomplete": alsoIncomplete, "counts": counts],
                "comparison_records": rows, "verification": ["status": "complete"], "extra": extras,
                "records": ["status": "complete", "verification_records": [], "coverage_records": coverage,
                            "operation_records": [], "diagnostics": []]]
    }
    static func data(_ object: Object) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
    static func presentation(_ object: Object) throws -> EnvironmentStatusPresentation {
        try EnvironmentStatusPresentation(JSONDecoder().decode(CoreComparisonResult.self, from: data(object)))
    }
    static func rejected(_ object: Object) {
        do { _ = try presentation(object); preconditionFailure("Invalid comparison must fail closed") } catch {}
    }
    static func write(_ text: String, _ url: URL, executable: Bool = false) throws {
        try text.write(to: url, atomically: false, encoding: .utf8)
        if executable { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path) }
    }
    static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    @MainActor static func render<V: View>(_ view: V, name: String, width: Int) throws {
        _ = NSApplication.shared
        NSApp.appearance = NSAppearance(named: .aqua)
        let height = 800
        let root = HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Macseed").font(.title2.weight(.semibold))
                Label("All Tasks", systemImage: "square.grid.2x2")
                ForEach(ProductTask.allCases) { task in Label(task.rawValue, systemImage: task.symbol) }
                Spacer()
            }.padding(20).frame(width: 215).background(.regularMaterial)
            ScrollView { view.modifier(WorkspaceContentGeometry()) }
        }.frame(width: CGFloat(width), height: CGFloat(height)).background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .light)
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { preconditionFailure("Native render unavailable") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/Debug/\(name).png"))
        window.close()
    }

    @MainActor static func main() async throws {
        let renderRuntime = CoreRuntime()
        let renderModel = EnvironmentStatusModel(runtime: renderRuntime)
        for (label, width) in [("narrow", 1000), ("wide", 1600)] {
            try render(TaskHome(select: { _ in }), name: "AllTasksUIv2-" + label, width: width)
            try render(VStack(alignment: .leading, spacing: 20) {
                WorkspaceHeader(title: ProductTask.status.rawValue, subtitle: ProductTask.status.subtitle, symbol: ProductTask.status.symbol)
                EnvironmentStatusView(model: renderModel, runtime: renderRuntime)
            }, name: "EnvironmentStatusUIv2-initial-" + label, width: width)
        }
        let visualResult = try presentation(payload([row(0, "matching"), row(1, "differing"), row(2, "missing"), row(3, "unverified", reason: "observation_failed")], verdict: "differences_detected", alsoIncomplete: true))
        precondition(visualResult.counts["matching"] == 1 && visualResult.counts["missing"] == 1)
        precondition(visualResult.categories.map(\.id) == ["homebrew-packages"])
        print("PASS: native All Tasks/Status narrow/wide renders and real comparison taxonomy/counts")
        let bundleURL = FileManager.default.temporaryDirectory.appendingPathComponent("status-bundle-" + UUID().uuidString + ".mbt")
        try write("fixture", bundleURL)
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        renderModel.selectBundle(bundleURL)
        precondition(renderModel.reference?.bundle == bundleURL && renderModel.state == .choose && renderRuntime.state == .idle)
        let bundleRequest = CoreRequest(renderModel.reference!.command)
        let bundleObject = try JSONSerialization.jsonObject(with: bundleRequest.encoded()) as! Object
        precondition((bundleObject["parameters"] as! Object)["bundle_path"] as? String == bundleURL.path)
        precondition((bundleObject["parameters"] as! Object).count == 1)
        try renderModel.reference!.validateAvailability()

        let identities = ["opaque:" + String(repeating: "a", count: 64), "opaque:" + String(repeating: "b", count: 64)]
        var repositoryRows: [Object] = []
        var repositoryOwners: [Object] = []
        var repositoryDiagnostics: [Object] = []
        for (index, predicate) in ["worktree", "origin", "branch"].enumerated() {
            var fact = row(index, index == 0 ? "missing" : "unverified", reason: index == 0 ? "confirmed_mismatch" : "prerequisite_unmet")
            fact["domain"] = "git-repositories"; fact["item_id"] = identities[0]
            repositoryRows.append(fact)
            repositoryOwners.append(["record_id": "v:\(index)", "domain": "git-repositories", "item_id": identities[0], "predicate": predicate])
            repositoryDiagnostics.append(["record_id": "v:\(index)", "code": index == 0 ? "confirmed_mismatch" : "prerequisite_unmet", "severity": "warning", "phase": "observation"])
        }
        var matchingRepository = row(3, "matching")
        matchingRepository["domain"] = "git-repositories"; matchingRepository["item_id"] = identities[1]
        repositoryRows.append(matchingRepository)
        var repositoryPayload = payload(repositoryRows, verdict: "differences_detected", alsoIncomplete: true)
        var repositoryEvidence = repositoryPayload["records"] as! Object
        repositoryEvidence["verification_records"] = repositoryOwners
        repositoryEvidence["diagnostics"] = repositoryDiagnostics
        repositoryPayload["records"] = repositoryEvidence
        repositoryPayload["reference_presentation"] = ["groups": [], "app_store_names": [:], "repository_labels": [identities[0]: "bootstrap-test", identities[1]: "macseed"]] as Object
        let namedRepositories = try presentation(repositoryPayload)
        let namedItems = namedRepositories.categories[0].items
        precondition(!namedRepositories.needsAttention && namedRepositories.headline == "Differences Found")
        precondition(namedRepositories.counts["unverified"] == 2 && namedRepositories.counts["missing"] == 1)
        precondition(namedItems[0].status == .missing && namedRepositories.categories[0].comparisonStatus == .missing)
        let repositoryDetails = namedRepositories.technicalFacts[namedItems[0].id]!
        precondition(repositoryDetails.count == 3 && Set(repositoryDetails.compactMap(\.predicate)) == Set(["worktree", "origin", "branch"]))
        precondition(Set(repositoryDetails.flatMap(\.phases)) == Set(["observation"]))
        precondition(Set(repositoryDetails.flatMap(\.codes)) == Set(["confirmed_mismatch", "prerequisite_unmet"]))
        precondition(namedItems.count == 2 && namedItems[0].title == "bootstrap-test" && namedItems[1].title == "macseed")
        precondition(namedItems[0].action == "Repository not found on this Mac. Its remote and branch could not be verified.")
        precondition(namedItems[0].reason!.contains("confirmed_mismatch") && namedItems[0].reason!.contains("prerequisite_unmet"))
        for index in 0..<3 { precondition(namedItems[0].reason!.contains("v:\(index)")) }
        repositoryPayload["comparison_records"] = Array(repositoryRows.reversed())
        let reorderedRepositories = try presentation(repositoryPayload)
        precondition(Dictionary(uniqueKeysWithValues: reorderedRepositories.categories[0].items.map { ($0.id, $0.title) }) == Dictionary(uniqueKeysWithValues: namedItems.map { ($0.id, $0.title) }))
        precondition(reorderedRepositories.counts == namedRepositories.counts)
        repositoryPayload["reference_presentation"] = ["groups": [], "app_store_names": [:], "repository_labels": [identities[0]: "/Users/private/repo", identities[1]: "https://user:secret@example.invalid/repo"]] as Object
        let fallbackRepositories = try presentation(repositoryPayload)
        precondition(Set(fallbackRepositories.categories[0].items.map(\.title)) == Set(["Repository 1", "Repository 2"]))
        repositoryPayload.removeValue(forKey: "reference_presentation")
        let legacyRepositories = try presentation(repositoryPayload)
        precondition(legacyRepositories.categories[0].items.map(\.title) == fallbackRepositories.categories[0].items.map(\.title))
        repositoryEvidence["verification_records"] = [] // No predicates: do not guess the explanation.
        repositoryPayload["records"] = repositoryEvidence
        let ambiguousRepositories = try presentation(repositoryPayload)
        precondition(!ambiguousRepositories.categories[0].items[1].action.contains("Its remote and branch"))
        precondition(ambiguousRepositories.needsAttention)
        var unsupportedDependencyRows = repositoryRows
        unsupportedDependencyRows[1]["support"] = "unsupported"
        var unsupportedDependency = payload(unsupportedDependencyRows, verdict: "differences_detected", alsoIncomplete: true)
        var unsupportedEvidence = repositoryEvidence
        unsupportedEvidence["verification_records"] = repositoryOwners
        unsupportedDependency["records"] = unsupportedEvidence
        let unsupportedDependencyPresentation = try presentation(unsupportedDependency)
        precondition(unsupportedDependencyPresentation.needsAttention)

        print("PASS: Exact opaque repository label correlation, reordered facts, safe fallback and independent technical evidence")

        var firefox = row(10, "differing", reason: "confirmed_mismatch")
        firefox["domain"] = "homebrew-casks"; firefox["item_id"] = "firefox"
        var folder = row(11, "missing", reason: "confirmed_mismatch")
        folder["domain"] = "workspace-folders"; folder["item_id"] = "VSCode"
        var scoped = payload(repositoryRows + [firefox, folder], verdict: "differences_detected", alsoIncomplete: true)
        var scopedEvidence = scoped["records"] as! Object
        scopedEvidence["verification_records"] = repositoryOwners + [
            ["record_id": "v:10", "domain": "homebrew-casks", "item_id": "firefox", "predicate": "installed"],
            ["record_id": "v:11", "domain": "workspace-folders", "item_id": "VSCode", "predicate": "directory"]]
        scopedEvidence["diagnostics"] = repositoryDiagnostics + [
            ["record_id": "v:10", "code": "confirmed_mismatch", "severity": "warning", "phase": "observation"],
            ["record_id": "v:11", "code": "confirmed_mismatch", "severity": "warning", "phase": "observation"],
            ["record_id": "c:ssh", "code": "partial_source_coverage", "severity": "warning", "phase": "scope"]]
        scopedEvidence["coverage_records"] = [
            ["record_id": "c:ssh", "domain": "ssh-configuration", "item_id": "config", "disposition": "resolved", "source_status": "partial"],
            ["record_id": "c:zsh", "domain": "shell-zsh", "item_id": "scope", "disposition": "no_requirement", "source_status": "observed_absent"],
            ["record_id": "c:excluded", "domain": "workspace-folders", "item_id": "excluded", "disposition": "excluded", "source_status": "unknown"]]
        scoped["records"] = scopedEvidence
        scoped["reference_presentation"] = ["groups": [
            ["id": "Applications", "domains": ["homebrew-casks"]],
            ["id": "Workspace", "domains": ["git-repositories", "workspace-folders"]],
            ["id": "SSH Configuration", "domains": ["ssh-configuration"]],
            ["id": "Shell", "domains": ["shell-zsh"]]], "app_store_names": [:]] as Object
        let precise = try presentation(scoped)
        let firefoxItem = precise.categories.first { $0.id == "homebrew-casks" }!.items[0]
        precondition(firefoxItem.status == .different && firefoxItem.action == "Current state differs from the selected reference.")
        precondition(EnvironmentComparisonDomain.summaryStatus(precise.categories.first { $0.id == "homebrew-casks" }!) == .different)
        let mixedApplications = DisplayCategory(id: "homebrew-casks", title: "Homebrew Applications", symbol: "app",
            items: [firefoxItem, DisplayItem(id: "matching", title: "Matching app", status: .matching, action: "")])
        precondition(EnvironmentComparisonDomain.summaryStatus(mixedApplications) == .different)
        precondition(EnvironmentComparisonDomain.summaryStatus(precise.categories.first { $0.id == "git-repositories" }!) == .missing)

        precondition(precise.categories.first { $0.id == "workspace-folders" }!.items[0].status == .missing)
        precondition(precise.categories.first { $0.id == "ssh-configuration" }!.comparisonStatus == .attention)
        precondition(precise.needsAttention && precise.headline == "Needs Attention")
        for (outcome, expected) in [(ComparisonOutcome.match, 1), (.different, 1), (.missing, 2), (.notApplicable, 1)] {
            precondition(precise.sections.reduce(0) { $0 + $1.entries.reduce(0) { $0 + precise.categoryCount(outcome, category: $1.category, children: $1.children) } } == expected)
        }
        let workspaceGroup = precise.sections.first { $0.id == "Workspace" }!
        precondition(workspaceGroup.entries.map(\.id) == ["workspace-folders", "git-repositories"])
        precondition(precise.categoryCount(.match, category: workspaceGroup.entries[1].category) == 1 && precise.categoryCount(.missing, category: workspaceGroup.entries[1].category) == 1)
        let sshGroup = precise.sections.first { $0.id == "SSH Configuration" }!
        precondition(ComparisonOutcome.allCases.allSatisfy { precise.categoryCount($0, category: sshGroup.entries[0].category) == 0 })
        try render(EnvironmentComparisonView(result: precise), name: "EnvironmentStatus-final-groups", width: 1000)
        for width in [1000, 785] {
            let ids = Set(precise.sections.flatMap(\.entries).map(\.id))
            try render(EnvironmentComparisonView(result: precise), name: "StatusUnified-collapsed-\(width)", width: width)
            try render(EnvironmentComparisonView(result: precise, categoryExpansion: .constant(ids)), name: "StatusUnified-expanded-\(width)", width: width)
        }

        var variedPhases = repositoryPayload
        var variedEvidence = variedPhases["records"] as! Object
        var variedDiagnostics = repositoryDiagnostics
        variedDiagnostics[1]["phase"] = "scope"
        variedEvidence["verification_records"] = repositoryOwners
        variedEvidence["diagnostics"] = variedDiagnostics
        variedPhases["records"] = variedEvidence
        let variedDetails = try presentation(variedPhases).technicalFacts["git-repositories:" + identities[0]]!
        precondition(Set(variedDetails.flatMap(\.phases)) == Set(["scope", "observation"]))
        precondition(variedDetails.map(\.predicateTitle) == ["Worktree", "Origin", "Branch"])
        precondition(EnvironmentComparisonDomain.visibleOutcomes([.match: 2, .different: 1, .missing: 3, .notApplicable: 0]) == [.match, .different, .missing])
        precondition(EnvironmentComparisonDomain.visibleOutcomes([.match: 1]) == [.match])
        precondition(EnvironmentComparisonDomain.visibleOutcomes([.match: 1, .missing: 1]) == [.match, .missing])
        precondition(EnvironmentComparisonDomain.visibleOutcomes([.missing: 0]).isEmpty)
        print("PASS: Core-record category counts, precise mismatch/absence statuses, mixed Git category and independent SSH coverage")

        let clean = payload([row(0, "matching")], verdict: "no_differences_detected")
        let ready = try presentation(clean)
        precondition(EnvironmentComparisonView.summaryOutcomes(ready) == [.match, .different, .missing])

        precondition(ready.headline == "No differences detected" && !ready.needsAttention && ready.summary == "1 matching")
        precondition(ready.categories[0].items[0].status == .matching && !ready.categories[0].hasAttention)
        precondition(EnvironmentComparisonDomain.summaryStatus(ready.categories[0]).rawValue == "Already Matches")
        precondition(EnvironmentComparisonDomain.visibleOutcomes([.match: 1]) == [.match])

        for width in [1000, 1600] {
            try render(VStack(spacing: 0) {
                EnvironmentComparisonDomain(category: ready.categories[0], counts: [.match: 1])
                EnvironmentComparisonDomain(category: mixedApplications, counts: [.match: 12, .different: 3])
                EnvironmentComparisonDomain(category: mixedApplications, counts: [.match: 1, .different: 12, .missing: 123])
            }.modifier(WorkspaceCardSurface()), name: "EnvironmentStatus-wide-pills-\(width)", width: width)
        }

        for kind in ["missing", "differing"] {
            let value = try presentation(payload([row(0, kind)], verdict: "differences_detected"))
            precondition(!value.needsAttention && value.headline == "Differences Found" && !value.summary.contains("0 "))
            precondition(value.categories[0].items[0].status == (kind == "missing" ? .missing : .different))
        }
        let unsupported = try presentation(payload([row(0, "unverified", support: "unsupported", reason: "unsupported_predicate")], verdict: "incomplete"))
        precondition(unsupported.categories[0].items[0].status == .unsupported)
        precondition(unsupported.summary == "1 unverified · 1 unsupported (within unverified)")
        precondition(ComparisonOutcome.notApplicable.count(unsupported) == 0)
        var noRequirementPayload = payload([], verdict: "no_comparable_requirements")
        var noRequirementRecords = noRequirementPayload["records"] as! Object
        noRequirementRecords["coverage_records"] = [
            ["record_id": "c:0", "domain": "homebrew-packages", "item_id": "scope", "disposition": "no_requirement", "source_status": "unknown"],
            ["record_id": "c:1", "domain": "homebrew-casks", "item_id": "scope", "disposition": "excluded", "source_status": "unknown"]]
        noRequirementPayload["records"] = noRequirementRecords
        let notApplicable = try presentation(noRequirementPayload)
        precondition(ComparisonOutcome.notApplicable.count(notApplicable) == 1)
        precondition(EnvironmentComparisonView.summaryOutcomes(notApplicable) == [.match, .different, .missing, .notApplicable])

        precondition(!notApplicable.categories.flatMap(\.items).contains { $0.status == .excluded })
        precondition(ComparisonOutcome.allCases.map { $0.count(visualResult) } == [1, 1, 1, 0])
        let unknown = try presentation(payload([row(0, "unverified", reason: "unknown_difference")], verdict: "incomplete"))
        precondition(unknown.categories[0].items[0].status == .unverified && unknown.summary.contains("unknown difference"))
        let mixed = try presentation(payload([row(0, "matching"), row(1, "differing"), row(2, "unverified", reason: "observation_failed")],
                                             verdict: "differences_detected", unresolved: true, alsoIncomplete: true))
        precondition(mixed.summary == "1 matching · 1 different · 1 unverified · 1 unresolved")
        precondition(mixed.message.contains("could not be verified") && mixed.categories[0].hasAttention)
        precondition(mixed.categories[0].items.contains { $0.status == .unresolved })
        let observation = try presentation(payload([row(0, "unverified", reason: "observation_failed")], verdict: "incomplete"))
        precondition(observation.categories[0].items[0].action == "Core could not observe current state.")
        let empty = try presentation(payload([], verdict: "no_comparable_requirements"))
        precondition(empty.headline == "No comparable requirements" && empty.summary.isEmpty && !empty.needsAttention)
        print("PASS: Core verdicts/states, observation failure, mixed/unresolved and zero-count suppression")

        let unavailable: Object = ["domains": [["domain": "homebrew-casks", "status": "unavailable", "count": NSNull(),
                                               "reason": "reference_inventory_completeness_unknown"]], "items": []]
        let noExtras = try presentation(payload([row(0, "matching")], verdict: "no_differences_detected", extras: unavailable))
        precondition(!noExtras.needsAttention && !noExtras.summary.contains("extra"))
        precondition(!noExtras.categories.contains { $0.id == "homebrew-casks" })
        let available: Object = ["domains": [["domain": "homebrew-casks", "status": "available", "count": 1, "reason": NSNull()]],
                                 "items": [["domain": "homebrew-casks", "item_id": "extra-app"]]]
        let extras = try presentation(payload([], verdict: "differences_detected", extras: available))
        precondition(extras.summary == "1 extra" && extras.categories[0].items[0].status == .extra)
        precondition(extras.categories[0].items[0].action.contains("Nothing will be removed"))
        var forged = unavailable
        forged["items"] = available["items"]
        rejected(payload([], verdict: "differences_detected", extras: forged))
        let unsupportedDomain: Object = ["domains": [["domain": "homebrew-packages", "status": "available", "count": 1]],
                                        "items": [["domain": "homebrew-packages", "item_id": "formula"]]]
        rejected(payload([], verdict: "differences_detected", extras: unsupportedDomain))
        var invalid = clean
        invalid["read_only"] = false; rejected(invalid)
        invalid = clean; invalid["publication_occurred"] = true; rejected(invalid)
        invalid = clean; invalid["target_mutation_may_have_started"] = true; rejected(invalid)
        invalid = clean
        var records = invalid["records"] as! Object
        records["status"] = "truncated"; invalid["records"] = records; rejected(invalid)
        invalid = payload([row(0, "missing")], verdict: "no_differences_detected"); rejected(invalid)
        invalid = clean
        records = invalid["records"] as! Object
        records["diagnostics"] = [["record_id": "run", "code": "observation_failed", "severity": "warning", "phase": "observation"]]
        invalid["records"] = records
        let warning = try presentation(invalid)
        precondition(warning.needsAttention && warning.categories.last!.hasAttention)
        precondition(warning.categories[0].items[0].status == .matching)
        print("PASS: Extras provenance/status gating, read-only evidence, incomplete/contradictory result rejection and warnings")
        var refined = payload([row(0, "matching")], verdict: "no_differences_detected")
        var sshRow = row(0, "matching")
        sshRow["domain"] = "ssh-configuration"; sshRow["item_id"] = "config"
        refined["comparison_records"] = [sshRow]
        refined["reference_presentation"] = ["groups": [
            ["id": "SSH Configuration", "domains": ["ssh-configuration"]],
            ["id": "macOS Settings", "domains": CaptureMacOSSettingsGroup.domainIDs],
            ["id": "Applications", "domains": ["app-store"]]], "app_store_names": ["123": "Infuse"]]
        var evidence = refined["records"] as! Object
        evidence["coverage_records"] = [
            ["record_id": "c:ssh", "domain": "ssh-configuration", "item_id": "config", "disposition": "resolved", "source_status": "partial"],
            ["record_id": "c:excluded", "domain": "homebrew-packages", "item_id": "excluded", "disposition": "excluded", "source_status": "observed_present"]]
        evidence["diagnostics"] = [
            ["record_id": "c:ssh", "code": "partial_source_coverage", "severity": "warning", "phase": "scope"],
            ["record_id": "c:ssh", "code": "partial_source_coverage", "severity": "warning", "phase": "scope"]]
        refined["records"] = evidence
        let ssh = try presentation(refined)
        precondition(ssh.categories.count == 1 && ssh.categories[0].items.count == 1)
        precondition(ssh.categories[0].items[0].status == .attention)
        precondition(ssh.categories[0].items[0].action.contains("Matches") && ssh.categories[0].items[0].action.contains("only part"))
        precondition(ssh.categories[0].items[0].reason!.contains("partial_source_coverage"))
        precondition(ssh.message.contains("SSH Configuration") && ssh.message.contains("only part"))
        precondition(ssh.counts["matching"] == 1 && ComparisonOutcome.notApplicable.count(ssh) == 0)
        precondition(ssh.sections.map(\.id) == ["SSH Configuration"])
        precondition(ssh.categoryCount(.match, category: ssh.categories[0]) == 1)
        precondition(EnvironmentComparisonDomain.visibleOutcomes([.match: ssh.categoryCount(.match, category: ssh.categories[0])]) == [.match])

        var excludedOnly = payload([], verdict: "no_comparable_requirements")
        excludedOnly["records"] = ["status": "complete", "verification_records": [], "operation_records": [], "diagnostics": [],
            "coverage_records": [["record_id": "c:x", "domain": "app-store", "item_id": "123", "disposition": "excluded", "source_status": "observed_present"]]]
        let hiddenExcluded = try presentation(excludedOnly)
        precondition(hiddenExcluded.categories.isEmpty)
        var aggregate = payload([row(0, "matching"), row(1, "differing")], verdict: "differences_detected")
        var finder = row(0, "matching"); finder["domain"] = "macos-finder"
        var dock = row(1, "differing"); dock["domain"] = "macos-dock"
        aggregate["comparison_records"] = [finder, dock]
        aggregate["reference_presentation"] = refined["reference_presentation"]
        var labelsMetadata = aggregate["reference_presentation"] as! Object
        labelsMetadata["setting_labels"] = ["macos-dock": ["item-1": "Magnification"]]
        aggregate["reference_presentation"] = labelsMetadata
        let macOS = try presentation(aggregate)
        precondition(macOS.sections[0].id == "Settings")
        let macOSEntry = macOS.sections[0].entries[0]
        precondition(macOSEntry.category.title == "macOS Settings" && macOSEntry.children.map(\.id) == ["macos-finder", "macos-dock"])
        precondition(macOSEntry.category.comparisonStatusText == "Different")
        precondition(!macOS.needsAttention && macOS.headline == "Differences Found")
        let mixedSettings = DisplayCategory(id: "macos-dock", title: "Dock", symbol: "dock.rectangle", items: [
            DisplayItem(id: "a", title: "A", status: .different, action: ""), DisplayItem(id: "b", title: "B", status: .missing, action: "")])
        precondition(mixedSettings.comparisonStatusText == "Differences Found")
        let uncertainSettings = DisplayCategory(id: "macos-dock", title: "Dock", symbol: "dock.rectangle", items: [
            DisplayItem(id: "unknown", title: "Unknown", status: .unverified, action: "")])
        precondition(uncertainSettings.comparisonStatusText == "Needs Attention")
        for width in [1000, 1600] {
            try render(EnvironmentComparisonView(result: macOS), name: "EnvironmentStatus-three-metrics-\(width)", width: width)
            try render(EnvironmentComparisonView(result: notApplicable), name: "EnvironmentStatus-four-metrics-\(width)", width: width)
        }

        precondition(ComparisonOutcome.allCases.map { macOS.categoryCount($0, category: macOSEntry.category, children: macOSEntry.children) } == [1, 1, 0, 0])
        precondition(EnvironmentComparisonDomain.visibleOutcomes([.match: 1, .different: 1]) == [.match, .different])

        let mainIDs = Set(macOS.sections.flatMap(\.entries).map(\.id))
        let initiallyExpanded = Set<String>()
        let allExpanded = EnvironmentComparisonView.toggledCategories(initiallyExpanded, ids: mainIDs)
        precondition(allExpanded == mainIDs && !allExpanded.contains("macos-dock"))
        precondition(EnvironmentComparisonView.toggledCategories(allExpanded, ids: mainIDs).isEmpty)
        let mixedIDs: Set<String> = ["macos-settings", "ssh-configuration"]
        precondition(EnvironmentComparisonView.toggledCategories(["macos-settings"], ids: mixedIDs) == mixedIDs)

        precondition(macOSEntry.children[1].items[0].title == "Magnification")
        for width in [1000, 785] {
            try render(EnvironmentComparisonView(result: macOS, categoryExpansion: .constant(["macos-settings"]), settingsExpansion: .constant(true)),
                name: "StatusUnified-macOS-settings-\(width)", width: width)
        }

        let plainMatch = macOSEntry.children[0].items[0]
        precondition(plainMatch.isNormalComparisonMatch && plainMatch.comparisonExplanation == nil && plainMatch.comparisonTechnicalDetails == nil)
        let problem = macOSEntry.children[1].items[0]
        precondition(!problem.isNormalComparisonMatch && problem.comparisonExplanation != nil && problem.comparisonTechnicalDetails != nil)
        precondition(!ssh.categories[0].items[0].isNormalComparisonMatch && ssh.categories[0].items[0].comparisonTechnicalDetails!.contains("partial_source_coverage"))

        var named = payload([row(0, "matching")], verdict: "no_differences_detected")
        var app = row(0, "matching"); app["domain"] = "app-store"; app["item_id"] = "123"
        named["comparison_records"] = [app]; named["reference_presentation"] = refined["reference_presentation"]
        let namedApp = try presentation(named)
        precondition(namedApp.categories[0].items[0].title == "Infuse")
        named.removeValue(forKey: "reference_presentation")
        let unnamed = try presentation(named).categories[0].items[0]
        precondition(unnamed.title == "App Store Application" && unnamed.reason!.contains("123"))
        evidence["coverage_records"] = [["record_id": "c:only", "domain": "ssh-configuration", "item_id": "other", "disposition": "excluded", "source_status": "partial"]]
        evidence["diagnostics"] = [["record_id": "c:only", "code": "partial_source_coverage", "severity": "warning", "phase": "scope"]]
        excludedOnly["records"] = evidence
        let diagnosticOnly = try presentation(excludedOnly)
        precondition(diagnosticOnly.categories[0].items[0].status == .attention)
        let catalogGroups = [
            CoreRestoreInspection.Group(id: "Applications", domains: ["homebrew-casks", "app-store", "vscode-extensions"]),
            CoreRestoreInspection.Group(id: "Homebrew", domains: ["homebrew-packages"]),
            CoreRestoreInspection.Group(id: "macOS Settings", domains: CaptureMacOSSettingsGroup.domainIDs),
            CoreRestoreInspection.Group(id: "VS Code Settings", domains: ["vscode-settings"]),
            CoreRestoreInspection.Group(id: "Git", domains: ["git-configuration"]),
            CoreRestoreInspection.Group(id: "Workspace", domains: ["workspace-folders", "git-repositories"]),
            CoreRestoreInspection.Group(id: "Shell", domains: ["shell-zsh"]),
            CoreRestoreInspection.Group(id: "SSH Configuration", domains: ["ssh-configuration"])]
        let domainIDs = ["shell-zsh", "workspace-folders", "git-repositories", "ssh-configuration", "git-configuration", "vscode-settings", "macos-dock", "vscode-extensions", "homebrew-packages", "app-store", "homebrew-casks"]
        let ordered = EnvironmentStatusSection.project(domainIDs.map { DisplayCategory(id: $0, title: $0, symbol: "folder", items: []) }, groups: catalogGroups)
        precondition(ordered.map(\.id) == ["Applications & Tools", "Settings", "Git", "SSH Configuration", "Workspace", "Shell"])
        precondition(ordered[0].entries.map(\.id) == ["homebrew-casks", "app-store", "homebrew-packages", "vscode-extensions"])
        precondition(ordered[2].entries.map(\.id) == ["git-configuration"])
        precondition(ordered[4].entries.map(\.id) == ["workspace-folders", "git-repositories"])
        let presentedIDs = ordered.flatMap(\.entries).map(\.id)
        precondition(Set(presentedIDs).count == presentedIDs.count)
        let workspaceIDs = Set(ordered[4].entries.map(\.id))
        precondition(EnvironmentComparisonView.toggledCategories([], ids: workspaceIDs) == workspaceIDs)
        precondition(EnvironmentComparisonView.toggledCategories(workspaceIDs, ids: workspaceIDs).isEmpty)
        print("PASS: Excluded filtering, stable SSH correlation, independent diagnostics, macOS aggregation, semantic mixed statuses and trusted App Store labels")


        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("macseed-status-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let core = directory.appendingPathComponent("fake-core")
        try FileManager.default.createDirectory(at: core.appendingPathComponent("modules/core/application-interface"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: core.appendingPathComponent("config"), withIntermediateDirectories: true)
        for path in ["modules/core/application-interface/core.py", "config/toolkit.conf", "bootstrap.sh"] { try Data().write(to: core.appendingPathComponent(path)) }
        try write("#!/bin/bash\nexec python3 -B fixture.py\n", core.appendingPathComponent("modules/core/application-interface/core.sh"))
        let python = URL(fileURLWithPath: CommandLine.arguments[2])
        try write("""
        import json, sys, pathlib, signal, time, os
        request = json.loads(sys.stdin.buffer.read())
        assert request['operation'] in ('environment_compare', 'capabilities')
        with open('requests.jsonl', 'a') as stream: stream.write(json.dumps(request) + '\\n')
        mode = pathlib.Path('mode').read_text()
        sequence = 0
        def emit(kind, data=None):
            global sequence
            sequence += 1
            event = dict(protocol_version=1, operation_id=request['operation_id'], sequence=sequence, type=kind)
            if data is not None: event['data'] = data
            print(json.dumps(event), flush=True)
        def stop(signum, frame):
            if mode in ('cancel_source_failure', 'cancel_cleanup_failure'):
                emit('failed', dict(code='bundle_unavailable' if mode == 'cancel_source_failure' else 'comparison_unavailable', read_only=True))
                sys.exit(2)
            if mode == 'cancel_interrupt': os.kill(os.getpid(), signal.SIGKILL)
            emit('cancelled', dict(read_only=True, publication_occurred=False, target_mutation_may_have_started=False))
            sys.exit(130)
        signal.signal(signal.SIGTERM, stop)
        emit('started')
        if request['operation'] == 'capabilities':
            emit('result', dict(protocol_version=1, product_version='fixture', operations=['environment_compare'], features={'bundle_comparison': {'version': 1}}))
            emit('completed'); sys.exit(0)
        if mode in ('slow', 'slow_validation', 'slow_verification', 'cancel_source_failure', 'cancel_cleanup_failure', 'cancel_interrupt'):
            emit('execution_event', dict(phase='bundle_validation' if mode == 'slow_validation' else 'verification', read_only=True))
            while True: time.sleep(.05)
        if mode == 'terminal_before_cancel':
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            emit('result', json.loads(pathlib.Path('response.json').read_text()))
            emit('completed', dict(read_only=True))
            time.sleep(.3); sys.exit(0)
        if mode == 'interrupt': os.kill(os.getpid(), signal.SIGKILL)
        if mode == 'protocol': print('not JSON', flush=True); sys.exit(0)
        if mode == 'success' or mode == 'reference_invalid_after_result': emit('result', json.loads(pathlib.Path('response.json').read_text()))
        if mode == 'success': emit('completed', dict(read_only=True)); sys.exit(0)
        emit('failed', dict(code='reference_invalid' if mode == 'reference_invalid_after_result' else mode, read_only=True))
        sys.exit(2)
        """, core.appendingPathComponent("fixture.py"))
        try data(clean).write(to: core.appendingPathComponent("response.json"))
        try write("success", core.appendingPathComponent("mode"))
        let reference = directory.appendingPathComponent("generated")
        try FileManager.default.createDirectory(at: reference, withIntermediateDirectories: false)
        let blueprint = directory.appendingPathComponent("blueprint.conf")
        try write("fixture", blueprint)
        let location = CoreLocation(root: core, python: python, home: directory, temporaryBase: directory, toolDirectories: [])
        let runtime = CoreRuntime()
        let model = EnvironmentStatusModel(runtime: runtime, location: location)
        model.compare()
        precondition(model.failure == .noReference && runtime.state == .idle)
        model.selectReference(directory.appendingPathComponent("absent"))
        model.compare()
        precondition(model.failure == .referenceUnavailable && runtime.state == .idle)
        model.selectReference(blueprint) // A Bundle/file is not a Generated Configuration folder.
        model.compare()
        precondition(model.failure == .referenceUnavailable && runtime.state == .idle)
        model.selectReference(reference)
        model.selectBlueprint(directory.appendingPathComponent("absent.conf")); model.compare()
        precondition(model.failure == .referenceUnavailable)
        model.selectBlueprint(nil)
        model.compare(); await model.waitForCompletion()
        precondition(model.state == .result && model.presentation?.headline == "No differences detected")
        let firstID = model.operationID
        try data(payload([row(0, "matching"), row(1, "differing"), row(2, "missing"), row(3, "unverified", reason: "observation_failed")], verdict: "differences_detected", alsoIncomplete: true)).write(to: core.appendingPathComponent("response.json"))
        model.selectBlueprint(blueprint)
        model.compare(); await model.waitForCompletion()
        precondition(model.operationID != firstID && model.presentation?.headline == "Needs Attention")
        // Check Again changes neither reference nor Blueprint and always creates a new request.
        let secondID = model.operationID
        model.compare(); await model.waitForCompletion()
        precondition(model.operationID != secondID && model.reference?.blueprint == blueprint)
        for (label, width) in [("narrow", 1000), ("wide", 1600)] {
            try render(EnvironmentStatusView(model: model, runtime: runtime), name: "EnvironmentStatusUIv2-result-" + label, width: width)
        }
        let requests = try String(contentsOf: core.appendingPathComponent("requests.jsonl"), encoding: .utf8).split(separator: "\n")
        precondition(requests.count == 3)
        let sent = try requests.map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! Object }
        precondition(Set(sent.map { $0["operation_id"] as! String }).count == 3)
        precondition((sent[0]["parameters"] as! Object)["blueprint_path"] is NSNull)
        precondition((sent[2]["parameters"] as! Object)["blueprint_path"] as? String == blueprint.path)
        precondition(sent.allSatisfy { $0["operation"] as? String == "environment_compare" })
        print("PASS: Missing/unavailable reference, explicit Blueprint/null and fresh Check Again requests/results")
        let bundleRuntime = CoreRuntime()
        let bundleModel = EnvironmentStatusModel(runtime: bundleRuntime, location: location)
        bundleModel.selectBundle(bundleURL)
        precondition(bundleModel.state == .choose && bundleModel.presentation == nil && !bundleRuntime.isActive)
        bundleModel.compare()
        precondition(bundleModel.failure == .unsupportedCapability && !bundleRuntime.isActive)
        bundleRuntime.start(CoreRequest(.capabilities), location: location)
        await bundleRuntime.waitForCompletion()
        precondition(bundleRuntime.bundleComparisonSupported == true)
        bundleModel.compare(); await bundleModel.waitForCompletion()
        precondition(bundleModel.state == .result)
        for kind in ["matching", "differing", "missing"] {
            try data(payload([row(0, kind)], verdict: kind == "matching" ? "no_differences_detected" : "differences_detected")).write(to: core.appendingPathComponent("response.json"))
            bundleModel.compare()
            precondition(bundleModel.restoreReviewBundle == nil)
            await bundleModel.waitForCompletion()
            precondition(bundleModel.restoreReviewBundle == (kind == "matching" ? nil : bundleURL))
            if kind == "differing" {
                for width in [1000, 1600] {
                    try render(EnvironmentStatusActions(model: bundleModel, runtime: bundleRuntime, reviewInRestore: {}), name: "Status-Restore-footer-\(width)", width: width)
                }
            }

        }
        try data(refined).write(to: core.appendingPathComponent("response.json")) // SSH warning without differences.
        bundleModel.compare(); await bundleModel.waitForCompletion()
        precondition(bundleModel.restoreReviewBundle == nil)
        precondition(model.restoreReviewBundle == nil) // Development reference is never handed off.

        bundleModel.selectBundle(directory.appendingPathComponent("missing.mbt"))
        precondition(bundleModel.presentation == nil)
        bundleModel.compare()
        precondition(bundleModel.failure == .referenceUnavailable && bundleModel.presentation == nil)
        bundleModel.selectBundle(bundleURL)
        for mode in ["bundle_invalid", "unsupported_bundle", "bundle_unavailable", "reference_changed"] {
            try write(mode, core.appendingPathComponent("mode"))
            bundleModel.compare(); await bundleModel.waitForCompletion()
            precondition(bundleModel.state == .failed && bundleModel.presentation == nil)
            precondition(bundleModel.failure?.technicalReason == mode && bundleModel.restoreReviewBundle == nil)
        }


        for mode in ["reference_invalid", "reference_unavailable", "reference_changed", "comparison_reporting_incomplete", "reference_invalid_after_result", "protocol", "interrupt"] {
            try write(mode, core.appendingPathComponent("mode"))
            model.compare(); precondition(model.presentation == nil)
            await model.waitForCompletion()
            precondition(model.state == .failed && model.presentation == nil && model.failure != nil)
            if mode == "interrupt" { precondition(model.failure == .interrupted) }
            if mode == "reference_invalid_after_result" { precondition(model.failure == .runtime(.coreFailure("reference_invalid"))) }
        }
        try write("slow", core.appendingPathComponent("mode"))
        model.compare()
        for _ in 0..<100 where runtime.events.isEmpty { try await Task.sleep(nanoseconds: 20_000_000) }
        precondition(model.state == .running && runtime.state == .running)
        model.cancel(); await model.waitForCompletion()
        precondition(model.state == .choose && model.presentation == nil && model.failure == nil && model.restoreReviewBundle == nil)
        precondition(model.reference?.generatedDirectory == reference)
        try write("success", core.appendingPathComponent("mode"))
        model.compare(); await model.waitForCompletion()
        precondition(model.state == .result)
        for mode in ["slow", "slow_validation", "slow_verification", "cancel_source_failure", "cancel_cleanup_failure", "cancel_interrupt", "terminal_before_cancel"] {
            try write(mode, core.appendingPathComponent("mode"))
            bundleModel.compare()
            if mode != "slow" {
                for _ in 0..<100 {
                    if bundleRuntime.events.contains(where: { mode == "terminal_before_cancel" ? $0.type == "completed" : $0.type == "execution_event" }) { break }
                    try await Task.sleep(nanoseconds: 20_000_000)
                }
            }
            bundleModel.cancel(); await bundleModel.waitForCompletion()
            precondition(bundleModel.reference?.bundle == bundleURL)
            precondition(bundleModel.presentation == nil || mode == "terminal_before_cancel")
            switch mode {
            case "cancel_source_failure": precondition(bundleModel.state == .failed && bundleModel.failure == .runtime(.coreFailure("bundle_unavailable")))
            case "cancel_cleanup_failure": precondition(bundleModel.state == .failed && bundleModel.failure == .runtime(.coreFailure("comparison_unavailable")))
            case "cancel_interrupt": precondition(bundleModel.state == .failed && bundleModel.failure == .interrupted)
            case "terminal_before_cancel": precondition(bundleModel.state == .result)
            default: precondition(bundleModel.state == .choose && bundleModel.failure == nil)
            }
            try write("success", core.appendingPathComponent("mode"))
            bundleModel.compare(); await bundleModel.waitForCompletion()
            precondition(bundleModel.state == .result && bundleModel.reference?.bundle == bundleURL)
        }
        let missingRuntime = EnvironmentStatusModel(runtime: CoreRuntime(resolver: CoreLocationResolver(resources: directory.appendingPathComponent("no-runtime"))))
        missingRuntime.selectReference(reference); missingRuntime.compare(); await missingRuntime.waitForCompletion()
        precondition(missingRuntime.state == .failed && missingRuntime.failure == .runtime(.runtimeUnavailable) && missingRuntime.presentation == nil)
        #if DEBUG
        let sample = DemoSession()
        sample.load(.differences)
        let sampleCategories = sample.statusCategories
        sample.compare()
        precondition(sample.statusCategories == sampleCategories && missingRuntime.presentation == nil)
        #else
        precondition(!BuildFeatures.sampleExperience)
        #endif
        print("PASS: Failed/partial result cannot appear clean, protocol/interruption/cancel handling and sample isolation")

        try await realCoreTest(directory: directory, repository: URL(fileURLWithPath: CommandLine.arguments[1]), python: python)
    }

    static func snapshot(_ directory: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for case let url as URL in FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])! {
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true { result[url.path] = try Data(contentsOf: url) }
        }
        return result
    }
    @MainActor static func realCoreTest(directory: URL, repository: URL, python: URL) async throws {
        // Automated disposable fixture, never the user's reference/current-Mac manual gate.
        let core = directory.appendingPathComponent("real-core")
        try FileManager.default.createDirectory(at: core.appendingPathComponent("config"), withIntermediateDirectories: true)
        for name in ["modules", "bootstrap.sh", "config/toolkit.conf"] {
            try FileManager.default.copyItem(at: repository.appendingPathComponent(name), to: core.appendingPathComponent(name))
        }
        let generated = directory.appendingPathComponent("real-generated")
        let home = directory.appendingPathComponent("real-home")
        let bin = directory.appendingPathComponent("real-bin")
        for url in [generated, home, bin] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false) }
        let mode = bin.appendingPathComponent("mode")
        let marker = directory.appendingPathComponent("mutation-attempts")
        try write("matching", mode)
        try write("""
        #!/bin/bash
        if [[ "$*" != 'list --formula --full-name' ]]; then echo "$*" >> \(quote(marker.path)); exit 99; fi
        case "$(/bin/cat \(quote(mode.path)))" in
          matching) echo git;;
          missing) exit 0;;
          observation_error) exit 2;;
        esac
        """, bin.appendingPathComponent("brew"), executable: true)
        for name in ["sudo", "defaults", "killall", "mas", "code", "curl", "xcode-select"] {
            try write("#!/bin/bash\necho attempted >> " + quote(marker.path) + "\nexit 99\n", bin.appendingPathComponent(name), executable: true)
        }
        try write("git\n", generated.appendingPathComponent("brew-packages.conf"))
        let blueprint = directory.appendingPathComponent("real-blueprint.conf")
        let categories = ["git-configuration", "ssh-configuration", "vscode-settings", "shell-zsh", "macos-finder", "macos-dock", "macos-windows", "macos-keyboard", "macos-trackpad", "macos-screenshots"]
        try write("[categories]\n" + categories.map { $0 + "=\"false\"\n" }.joined()
                  + "[homebrew-packages]\ngit\n[homebrew-casks]\n[app-store]\n[vscode-extensions]\n[workspace-folders]\n[git-repositories]\n", blueprint)
        let beforeReference = try snapshot(generated), beforeHome = try snapshot(home), beforeBlueprint = try Data(contentsOf: blueprint)
        let runtime = CoreRuntime()
        let model = EnvironmentStatusModel(runtime: runtime, location: CoreLocation(root: core, python: python, home: home,
                                                                                  temporaryBase: directory, toolDirectories: [bin]))
        model.selectReference(generated); model.selectBlueprint(blueprint)
        for modeName in ["matching", "missing", "observation_error"] {
            try write(modeName, mode)
            model.compare(); await model.waitForCompletion()
            precondition(model.state == .result, "Actual Core projection rejected: \(String(describing: model.failure))")
            precondition(model.presentation?.headline == (modeName == "matching" ? "No differences detected" : (modeName == "missing" ? "Differences Found" : "Needs Attention")))
            precondition(runtime.latestResult?.data?["read_only"] == .bool(true))
            if modeName == "observation_error" { precondition(model.presentation?.categories.flatMap(\.items).contains { [.unverified, .attention].contains($0.status) && $0.reason?.contains("Comparison: unverified") == true } == true) }
        }
        try write("invalid!\n", blueprint)
        model.compare(); await model.waitForCompletion()
        precondition(model.state == .failed && model.failure == .runtime(.coreFailure("reference_invalid")) && model.presentation == nil)
        try beforeBlueprint.write(to: blueprint)
        let afterReference = try snapshot(generated), afterHome = try snapshot(home), afterBlueprint = try Data(contentsOf: blueprint)
        precondition(afterReference == beforeReference && afterHome == beforeHome && afterBlueprint == beforeBlueprint)
        precondition(!FileManager.default.fileExists(atPath: marker.path) && !FileManager.default.fileExists(atPath: core.appendingPathComponent("logs").path))
        print("PASS: Swift → production Core → disposable readers → Status (matching/difference/observation/invalid reference); no mutation")
    }
}
