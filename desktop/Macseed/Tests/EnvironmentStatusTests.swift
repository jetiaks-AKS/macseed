import Foundation
import AppKit
import SwiftUI

private struct StatusAnchorFrames: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

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

    @MainActor static func nativeStatusAnchorChecks(width: Int) throws {
        var frames: [Int: CGRect] = [:]
        precondition(EnvironmentComparisonRowLayout.leadingInset(306, depth: 2, item: true) == 50)
        precondition(EnvironmentComparisonRowLayout.leadingInset(1102, depth: 2, item: true) == 82)
        let root = VStack(spacing: 0) {
            ForEach(0..<3) { depth in
                EnvironmentComparisonRowLayout(depth: depth) {
                    Text("A long nested preference name")
                    Label("Already Matches", systemImage: "checkmark.circle.fill").font(.callout)
                        .background(GeometryReader { geometry in
                            Color.clear.preference(key: StatusAnchorFrames.self,
                                value: [depth: geometry.frame(in: .named("status-anchors"))])
                        })
                }.padding(.trailing, 26)
            }
        }.padding(.horizontal, 36).coordinateSpace(name: "status-anchors")
            .onPreferenceChange(StatusAnchorFrames.self) { frames = $0 }
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.close() }
        host.frame = NSRect(x: 0, y: 0, width: width, height: 300)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
        host.layoutSubtreeIfNeeded()
        precondition(frames.count == 3)
        let xs = frames.values.map(\.minX)
        precondition(xs.max()! - xs.min()! < 0.5, "All depths share one native status anchor")
        precondition(frames.values.allSatisfy { $0.height < 20 }, "Category match text must fit on one line")
        let old = TaskTextStatusLayout.widths(CGFloat(width) - 98)
        precondition(xs[0] < CGFloat(width) - 62 - old.status - 20, "Status anchor moves left")
    }

    static func categorySemanticsCases() throws -> [(String, EnvironmentStatusPresentation)] {
        let cases: [(String, [DisplayStatus], String)] = [
            ("only-different", [.different], "Differences Found"),
            ("only-missing", [.missing], "Differences Found"),
            ("different-and-missing", [.different, .missing], "Differences Found"),
            ("different-and-unsupported", [.different, .unsupported], "Needs Attention"),
            ("all-match", [.matching], "Already Matches"),
            ("no-requirements", [], "No Requirement")]
        let domains = ["macos-finder", "macos-dock", "macos-screenshots", "homebrew-casks"]
        return try cases.map { name, statuses, expected in
            var rows: [Object] = [], owners: [Object] = [], coverage: [Object] = []
            for domain in domains {
                if statuses.isEmpty {
                    coverage.append(["record_id": "c:" + domain, "domain": domain, "item_id": "scope",
                        "disposition": "no_requirement", "source_status": "observed_absent"])
                }
                for (index, status) in statuses.enumerated() {
                    let id = rows.count
                    let kind = status == .different ? "differing" : (status == .missing ? "missing" : (status == .matching ? "matching" : "unverified"))
                    var fact = row(id, kind, support: status == .unsupported ? "unsupported" : "supported",
                        reason: status == .unsupported ? "unsupported_predicate" : (status == .matching ? nil : "confirmed_mismatch"))
                    fact["domain"] = domain; fact["item_id"] = "preference-\(index + 1)"
                    rows.append(fact)
                    owners.append(["record_id": "v:\(id)", "domain": domain, "item_id": "preference-\(index + 1)",
                        "predicate": domain.hasPrefix("macos-") ? "stored_preference" : "installed"])
                }
            }
            let uncertain = statuses.contains(.unsupported)
            let verdict = statuses.isEmpty ? "no_comparable_requirements" : (statuses == [.matching] ? "no_differences_detected" : "differences_detected")
            var object = payload(rows, verdict: verdict, alsoIncomplete: uncertain)
            var records = object["records"] as! Object
            records["verification_records"] = owners; records["coverage_records"] = coverage
            object["records"] = records
            object["reference_presentation"] = ["groups": [
                ["id": "Applications", "domains": ["homebrew-casks"]],
                ["id": "macOS Settings", "domains": Array(domains.prefix(3))]], "app_store_names": [:]] as Object
            let result = try presentation(object)
            for entry in result.sections.flatMap(\.entries) {
                for category in [entry.category] + entry.children {
                    precondition(category.comparisonStatusText == expected, "One category policy across all domains")
                }
            }
            for category in result.categories {
                precondition(result.categoryCount(.different, category: category) == statuses.filter { $0 == .different }.count)
                precondition(result.categoryCount(.missing, category: category) == statuses.filter { $0 == .missing }.count)
                precondition(result.categoryCount(.needsAttention, category: category) == statuses.filter { $0 == .unsupported }.count)
                precondition(category.items.map(\.status) == (statuses.isEmpty ? [.noRequirement] : statuses))
            }
            for independent in [DisplayStatus.unverified, .unresolved, .attention] {
                let category = DisplayCategory(id: "case", title: "Case", symbol: "folder", items: [
                    DisplayItem(id: "difference", title: "Difference", status: .different, action: ""),
                    DisplayItem(id: "gap", title: "Gap", status: independent, action: "")])
                precondition(category.comparisonStatusText == "Needs Attention")
            }
            return (name, result)
        }
    }

    @MainActor static func finalConsistencyChecks() throws -> EnvironmentStatusPresentation {
        let semanticCases = try categorySemanticsCases()
        var rows: [Object] = []
        var owners: [Object] = []
        let names = ["Infrastructure", "macseed", "bootstrap-branch-test"]
        for repo in 0..<3 {
            for (offset, predicate) in ["worktree", "origin", "branch"].enumerated() {
                let id = repo * 3 + offset
                var fact = row(id, id == 5 ? "differing" : "matching", reason: id == 5 ? "confirmed_mismatch" : nil)
                fact["domain"] = "git-repositories"; fact["item_id"] = names[repo]
                rows.append(fact)
                owners.append(["record_id": "v:\(id)", "domain": "git-repositories", "item_id": names[repo], "predicate": predicate])
            }
        }
        func repositories(_ facts: [Object], diagnostics: [Object] = []) throws -> EnvironmentStatusPresentation {
            var value = payload(facts, verdict: "differences_detected", alsoIncomplete: facts.contains { $0["comparison_kind"] as? String == "unverified" })
            var evidence = value["records"] as! Object
            evidence["verification_records"] = owners.filter { owner in facts.contains { $0["record_id"] as? String == owner["record_id"] as? String } }
            evidence["diagnostics"] = diagnostics
            value["records"] = evidence
            return try presentation(value)
        }
        let result = try repositories(rows)
        precondition(result.counts["matching"] == 8 && result.counts["differing"] == 1)
        precondition(result.categoryCount(.match, category: result.categories[0]) == 2)
        precondition(result.categoryCount(.different, category: result.categories[0]) == 1)
        precondition(result.categories[0].items.map(\.status) == [.matching, .different, .matching])
        precondition(result.categories[0].items[1].action == "Repository checks differ from the selected reference.")
        precondition(result.technicalFacts["git-repositories:macseed"]!.count == 3)
        for offset in rows.indices {
            let reordered = try repositories(Array(rows[offset...] + rows[..<offset]).reversed())
            precondition(reordered.counts == result.counts)
            precondition(Dictionary(uniqueKeysWithValues: reordered.categories[0].items.map { ($0.id, $0.status) })
                == Dictionary(uniqueKeysWithValues: result.categories[0].items.map { ($0.id, $0.status) }))
            precondition(reordered.categoryCount(.match, category: reordered.categories[0]) == 2)
        }
        var partial = rows
        partial.remove(at: 0)
        let incomplete = try repositories(partial)
        precondition(incomplete.categories[0].items[0].status == .unverified && incomplete.attentionCount == nil)
        var repositoryScenarios: [(String, EnvironmentStatusPresentation)] = [("Incomplete predicates", incomplete)]
        for reason in ["unknown_difference", "unsupported_predicate", "observation_failed"] {
            var uncertain = rows
            uncertain[0]["comparison_kind"] = "unverified"; uncertain[0]["reason"] = reason
            uncertain[0]["support"] = reason == "unsupported_predicate" ? "unsupported" : "supported"
            let value = try repositories(uncertain)
            precondition(value.needsAttention && value.attentionCount == 1)
            precondition(value.categoryCount(.match, category: value.categories[0]) == 1)
            precondition(value.categoryCount(.needsAttention, category: value.categories[0]) == 1)
            repositoryScenarios.append((reason, value))
        }
        var absentRows = rows
        for index in 0..<3 {
            absentRows[index]["comparison_kind"] = index == 0 ? "missing" : "unverified"
            absentRows[index]["reason"] = index == 0 ? "confirmed_mismatch" : "prerequisite_unmet"
        }
        let absentWorktree = try repositories(absentRows, diagnostics: (0..<3).map {
            ["record_id": "v:\($0)", "severity": "warning", "code": $0 == 0 ? "confirmed_mismatch" : "prerequisite_unmet", "phase": "observation"]
        })
        precondition(absentWorktree.categories[0].items[0].status == .missing && !absentWorktree.needsAttention)
        repositoryScenarios.append(("Absent worktree", absentWorktree))
        var missingOrigin = rows
        missingOrigin[1]["comparison_kind"] = "missing"; missingOrigin[1]["reason"] = "confirmed_mismatch"
        let absentOrigin = try repositories(missingOrigin)
        precondition(absentOrigin.categories[0].items[0].status == .different)
        let warning = try repositories(rows, diagnostics: [["record_id": "v:0", "severity": "warning", "code": "independent_issue", "phase": "observation"]])
        precondition(warning.attentionCount == nil && warning.categories[0].items[0].status == .unverified)

        var visualRows = rows
        var visualOwners = owners
        var labels: [String: [String: String]] = [:]
        for domain in CaptureMacOSSettingsGroup.domainIDs {
            let identities = domain == "macos-finder"
                ? ["NSGlobalDomain/AppleShowAllExtensions", "com.apple.finder/FXEnableExtensionChangeWarning"]
                : ["preference-1", "preference-2"]
            let titles = domain == "macos-finder"
                ? ["Show extensions", "Extension change warning"] : ["Supported preference", "Window and item display preferences"]
            for index in 0..<2 {
                let id = visualRows.count
                let kind = domain == "macos-finder" ? (index == 0 ? "missing" : "differing")
                    : (domain == "macos-dock" ? "differing" : "matching")
                var fact = row(id, kind, reason: kind == "matching" ? nil : "confirmed_mismatch")
                fact["domain"] = domain; fact["item_id"] = identities[index]
                visualRows.append(fact); labels[domain, default: [:]][identities[index]] = titles[index]
                visualOwners.append(["record_id": "v:\(id)", "domain": domain, "item_id": identities[index], "predicate": "stored_preference"])
            }
        }
        for (domain, identity, kind) in [("homebrew-casks", "telegram", "matching"), ("app-store", "747648890", "missing"),
            ("homebrew-packages", "git", "matching"), ("vscode-extensions", "extension", "matching"),
            ("vscode-settings", "settings.json", "matching"), ("git-configuration", "user.name", "matching"),
            ("ssh-configuration", "config", "matching"), ("workspace-folders", "Projects", "matching"),
            ("homebrew-packages", "unknown", "unverified"), ("homebrew-casks", "different-app", "differing"),
            ("homebrew-casks", "unsupported-one", "unverified"), ("homebrew-casks", "unsupported-two", "unverified"),
            ("homebrew-casks", "unsupported-three", "unverified")] {
            let unsupported = identity.hasPrefix("unsupported-")
            var fact = row(visualRows.count, kind, support: unsupported ? "unsupported" : "supported",
                reason: unsupported ? "unsupported_predicate" : (kind == "unverified" ? "observation_failed" : nil))
            fact["domain"] = domain; fact["item_id"] = identity; visualRows.append(fact)
        }
        let extras: Object = ["domains": ["app-store", "homebrew-casks", "vscode-extensions"].map {
            ["domain": $0, "status": "available", "count": 1, "reason": NSNull()] as Object
        }, "items": ["app-store", "homebrew-casks", "vscode-extensions"].map {
            ["domain": $0, "item_id": $0 == "app-store" ? "123" : "extra-application"]
        }]
        var visualPayload = payload(visualRows, verdict: "differences_detected", extras: extras, alsoIncomplete: true)
        var evidence = visualPayload["records"] as! Object
        evidence["verification_records"] = visualOwners
        evidence["coverage_records"] = [["record_id": "c:empty", "domain": "shell-zsh", "item_id": "scope", "disposition": "no_requirement", "source_status": "observed_absent"]]
        visualPayload["records"] = evidence
        visualPayload["reference_presentation"] = ["groups": [
            ["id": "Applications", "domains": ["homebrew-casks", "app-store", "vscode-extensions"]],
            ["id": "Homebrew", "domains": ["homebrew-packages"]],
            ["id": "macOS Settings", "domains": CaptureMacOSSettingsGroup.domainIDs],
            ["id": "VS Code Settings", "domains": ["vscode-settings"]],
            ["id": "Git", "domains": ["git-configuration"]],
            ["id": "Workspace", "domains": ["workspace-folders", "git-repositories"]],
            ["id": "SSH Configuration", "domains": ["ssh-configuration"]],
            ["id": "Shell", "domains": ["shell-zsh"]]],
            "app_store_names": ["747648890": "Telegram", "123": "Additional App"], "setting_labels": labels,
            "repository_labels": Dictionary(uniqueKeysWithValues: names.map { ($0, $0) })]
        let visual = try presentation(visualPayload)
        precondition(EnvironmentComparisonView.summaryOutcomes(visual).count == 4 && visual.attentionCount == 4)
        precondition(ComparisonOutcome.needsAttention.explanation == "Unsupported or incomplete checks")
        precondition(ComparisonOutcome.different.tint != ComparisonOutcome.needsAttention.tint)
        precondition(ComparisonOutcome.different.tint == EnvironmentComparisonPalette.color(for: .different))
        for status in [DisplayStatus.unsupported, .unverified, .unresolved, .attention] {
            precondition(EnvironmentComparisonPalette.color(for: status) == ComparisonOutcome.needsAttention.tint)
        }
        precondition(ComparisonOutcome.missing.tint == .red && ComparisonOutcome.needsAttention.tint == .orange)
        let casks = visual.categories.first { $0.id == "homebrew-casks" }!
        let caskCounts = Dictionary(uniqueKeysWithValues: ComparisonOutcome.allCases.map { ($0, visual.categoryCount($0, category: casks)) })
        let caskBadges = EnvironmentComparisonDomain.visibleOutcomes(caskCounts)
        precondition(caskBadges == [.match, .different, .needsAttention])
        precondition(caskBadges[2].title == "Needs Attention" && caskCounts[caskBadges[2]] == 3)
        precondition(caskBadges[2].tint == .orange && caskCounts[.missing] == 0)
        precondition(visual.counts["unsupported"] == 3 && visual.counts["unverified"] == 4 && visual.attentionCount == 4)
        let appStore = visual.categories.first { $0.id == "app-store" }!
        precondition(appStore.items[0].status == .missing && appStore.items[0].action.contains("App Store version"))
        precondition(appStore.items.last!.reason!.contains("Extra evidence: available · Count: 1"))
        precondition(visual.categoryCount(.missing, category: appStore) == 1 && visual.categoryCount(.needsAttention, category: appStore) == 0)
        let visible = EnvironmentComparisonView.visibleSections(visual)
        precondition(visible.flatMap(\.entries).flatMap { $0.category.items }.allSatisfy { $0.status != .extra })
        precondition(visual.counts["extra"] == 3 && visual.categories.flatMap(\.items).filter { $0.status == .extra }.count == 3)
        let event = try CoreEvent(line: data(["protocol_version": 1, "operation_id": "extra-fixture", "sequence": 1,
            "type": "result", "data": visualPayload]))
        var sanitizer = OperationLogSanitizer()
        let logRecord = sanitizer.event(event, at: Date())
        precondition(logRecord.evidence?.contains { $0.counts["extra"] == 3 } == true)
        var report = DiagnosticReportBuilder(id: UUID(), environment: .init(version: "3.4.0", build: nil,
            macOS: .init(majorVersion: 14, minorVersion: 0, patchVersion: 0), architecture: "arm64"))
        report.receive(logRecord)
        precondition(report.snapshot().text.contains("extra=3"))
        let extrasOnly = try presentation(payload([], verdict: "differences_detected", extras: extras))
        precondition(EnvironmentComparisonView.visibleSections(extrasOnly).isEmpty)
        precondition(ComparisonOutcome.allCases.allSatisfy { $0.count(extrasOnly) == 0 })
        let extraAvailability = DisplayCategory(id: "homebrew-casks", title: "Homebrew Applications", symbol: "app", items: [
            DisplayItem(id: "extra-availability:homebrew-casks", title: "Extra-item evidence", status: .information, action: "Unavailable")])
        precondition(EnvironmentComparisonView.visibleCategory(extraAvailability).items.isEmpty)
        precondition(extraAvailability.items.count == 1)
        for count in 1...5 {
            for width in [420.0, 785, 985, 1200] {
                precondition(EnvironmentComparisonMetricsLayout.columns(width, count: count) <= count)
            }
        }
        _ = NSApplication.shared
        NSApp.appearance = NSAppearance(named: .aqua)
        func snapshot<V: View>(_ view: V, _ name: String, _ width: Int, scheme: ColorScheme = .light) throws {
            NSApp.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            let content = view.padding(20).frame(width: CGFloat(width))
                .frame(maxHeight: .infinity, alignment: .top)
                .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, scheme)
            let host = NSHostingView(rootView: content)
            let height = ceil(host.fittingSize.height) + 1
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: CGFloat(width), height: height),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host
            defer { window.close() }
            host.frame = NSRect(x: 0, y: 0, width: CGFloat(width), height: height)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                preconditionFailure("Native Status composition did not render")
            }
            precondition(host.bounds.width == CGFloat(width))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!
                .write(to: URL(fileURLWithPath: "build/Debug/Status-colors-\(name)-\(width).png"))
        }
        precondition(EnvironmentComparisonMetricsLayout.columns(.infinity, count: 5) == 5)
        precondition(EnvironmentComparisonMetricsLayout.columns(0, count: 5) == 1)
        let expanded = Set(visual.sections.flatMap(\.entries).map(\.id))
        let childCounts = Dictionary(uniqueKeysWithValues: visual.categories.map { category in
            (category.id, Dictionary(uniqueKeysWithValues: ComparisonOutcome.allCases.map { ($0, visual.categoryCount($0, category: category)) }))
        })
        for width in [420, 785, 985, 1200] {
            try nativeStatusAnchorChecks(width: width)
            for (name, scenario) in semanticCases {
                let ids = Set(scenario.sections.flatMap(\.entries).map(\.id))
                try snapshot(EnvironmentComparisonView(result: scenario, categoryExpansion: .constant(ids),
                    settingsExpansion: .constant(true)), "category-" + name, width)
            }
            try snapshot(EnvironmentComparisonMetricsLayout {
                ForEach(ComparisonSummaryOutcome.allCases) {
                    ComparisonMetricCard(outcome: $0, count: $0.count(visual), explanation: $0.explanation(visual))
                }
            }, "metrics-dark", width, scheme: .dark)
            for (name, scenario) in repositoryScenarios {
                let category = scenario.categories[0]
                try snapshot(EnvironmentComparisonDomain(category: category, technicalFacts: scenario.technicalFacts,
                    counts: Dictionary(uniqueKeysWithValues: ComparisonOutcome.allCases.map { ($0, scenario.categoryCount($0, category: category)) }),
                    expansion: .constant(true), technicalExpansion: .constant(true)).modifier(WorkspaceCardSurface()),
                    "repositories-" + name.replacingOccurrences(of: " ", with: "-"), width)
            }
            let matchingSettings = visual.sections.first { $0.id == "Settings" }!.entries[0].children.map { category in
                DisplayCategory(id: category.id, title: category.title, symbol: category.symbol,
                    items: category.items.map { DisplayItem(id: $0.id, title: $0.title, status: .matching, action: "") })
            }
            try snapshot(EnvironmentComparisonDomain(category: DisplayCategory(id: "macos-settings", title: "macOS Settings",
                symbol: "slider.horizontal.3", items: matchingSettings.flatMap(\.items)), children: matchingSettings,
                counts: [.match: matchingSettings.flatMap(\.items).count], expansion: .constant(true), childExpansion: .constant(true),
                categoryCounts: Dictionary(uniqueKeysWithValues: matchingSettings.map { ($0.id, [.match: $0.items.count]) }))
                .modifier(WorkspaceCardSurface()), "settings-all-matching", width)
            for count in 1...ComparisonSummaryOutcome.allCases.count {
                try snapshot(EnvironmentComparisonMetricsLayout {
                    ForEach(Array(ComparisonSummaryOutcome.allCases.prefix(count))) { outcome in
                        ComparisonMetricCard(outcome: outcome, count: outcome == .needsAttention ? nil : outcome.count(visual),
                            explanation: outcome.explanation(visual))
                    }
                }, "metrics-\(count)", width)
            }
            try snapshot(EnvironmentComparisonView(result: visual), "collapsed", width)
            try snapshot(EnvironmentComparisonView(result: visual, categoryExpansion: .constant(expanded), settingsExpansion: .constant(true)), "expanded", width)
            for section in visual.sections {
                try snapshot(VStack(alignment: .leading, spacing: 12) {
                    WorkspaceSectionHeader(title: section.id)
                    VStack(spacing: 0) {
                        ForEach(section.entries) { entry in
                            EnvironmentComparisonDomain(category: entry.category, children: entry.children, technicalFacts: visual.technicalFacts,
                                counts: Dictionary(uniqueKeysWithValues: ComparisonOutcome.allCases.map { ($0, visual.categoryCount($0, category: entry.category, children: entry.children)) }),
                                expansion: .constant(true), childExpansion: .constant(true), categoryCounts: childCounts, technicalExpansion: .constant(true))
                        }
                    }.modifier(WorkspaceCardSurface())
                }, section.id.replacingOccurrences(of: " ", with: "-"), width)
            }
        }
        print("PASS: 8/1 predicates → 2/1 repository items, order independence, incomplete/unsupported/independent errors, provider-specific scope, Extra evidence; actual SwiftUI at 420/785/985/1200pt with expanded/collapsed details")
        return visual
    }

    @MainActor static func renderResultViewport(_ visual: EnvironmentStatusPresentation, model: EnvironmentStatusModel, runtime: CoreRuntime, width: Int) throws {
        let expanded = Set(visual.sections.flatMap(\.entries).map(\.id))
        // Exercise the production scroll/content/footer composition with real actions.
        let root = VStack(spacing: 0) {
            ScrollView { EnvironmentComparisonView(result: visual, categoryExpansion: .constant(expanded), settingsExpansion: .constant(true)).modifier(WorkspaceContentGeometry()) }
            Divider()
            EnvironmentStatusActions(model: model, runtime: runtime, reviewInRestore: {}).modifier(WorkspaceFooterPadding())
        }.frame(width: CGFloat(width), height: 800).background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        host.frame = window.contentView!.bounds
        host.layoutSubtreeIfNeeded()
        func scrollView(_ view: NSView) -> NSScrollView? {
            (view as? NSScrollView) ?? view.subviews.lazy.compactMap { scrollView($0) }.first
        }
        guard let scroll = scrollView(host), let document = scroll.documentView else { preconditionFailure("Missing native scroll") }
        let scrollFrame = scroll.convert(scroll.bounds, to: host)
        precondition(scrollFrame.height < 800 && document.bounds.height > scroll.bounds.height)
        for position in ["top", "bottom"] {
            if position == "bottom" {
                scroll.contentView.scroll(to: NSPoint(x: 0, y: document.bounds.height - scroll.contentView.bounds.height))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            precondition(scroll.convert(scroll.bounds, to: host) == scrollFrame)
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/Debug/Status-colors-viewport-\(position)-\(width).png"))
        }
        window.close()
    }

    @MainActor static func conciseMessageChecks() throws {
        var object = payload([row(0, "unverified", reason: "observation_failed"), row(1, "matching")],
            verdict: "incomplete")
        var records = object["records"] as! Object
        records["coverage_records"] = [["record_id": "c:ssh", "domain": "ssh-configuration", "item_id": "config",
            "disposition": "resolved", "source_status": "partial"]]
        records["diagnostics"] = [["record_id": "c:ssh", "code": "partial_source_coverage", "severity": "warning", "phase": "scope"]]
        object["records"] = records
        let result = try presentation(object)
        precondition(result.counts["matching"] == 1 && result.counts["unverified"] == 1)
        precondition(result.message == "Some requirements could not be verified. Review the affected categories.")
        precondition(result.categories.first { $0.id == "ssh-configuration" }?.items.first?.action.contains("only part") == true)
        precondition(result.categories.first { $0.id == "homebrew-packages" }?.items.first?.action == "Couldn’t read the current state.")
        precondition(StatusFailure.runtime(.pythonUnavailable).message.contains("Check the app setup"))
        precondition(!StatusFailure.runtime(.malformedEvent).message.contains("Core"))
        precondition(StatusFailure.runtime(.coreFailure("comparison_reporting_incomplete")).message == StatusFailure.invalidResult.message)
        print("PASS: concise Status failures and summary, retained independent SSH warning and item counts")
    }

    @MainActor static func main() async throws {
        if CommandLine.arguments.contains("--concise-messages-only") { try conciseMessageChecks(); return }
        let finalVisual = try finalConsistencyChecks()
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
        for (index, predicate) in ["worktree", "origin", "branch"].enumerated() {
            var fact = row(index + 3, "matching")
            fact["domain"] = "git-repositories"; fact["item_id"] = identities[1]
            repositoryRows.append(fact)
            repositoryOwners.append(["record_id": "v:\(index + 3)", "domain": "git-repositories", "item_id": identities[1], "predicate": predicate])
        }
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
        precondition(namedItems[0].status == .missing && namedRepositories.categories[0].comparisonStatus == .different)
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

        var mixedFailureRows = repositoryRows
        mixedFailureRows[2]["reason"] = "observation_failed"
        var mixedFailure = payload(mixedFailureRows, verdict: "differences_detected", alsoIncomplete: true)
        var mixedFailureEvidence = repositoryEvidence
        mixedFailureEvidence["verification_records"] = repositoryOwners
        var mixedFailureDiagnostics = repositoryDiagnostics
        mixedFailureDiagnostics[2]["code"] = "observation_failed"
        mixedFailureEvidence["diagnostics"] = mixedFailureDiagnostics
        mixedFailure["records"] = mixedFailureEvidence
        let mixedRepositoryFailure = try presentation(mixedFailure)
        precondition(mixedRepositoryFailure.categories[0].items[0].status == .unverified)
        precondition(mixedRepositoryFailure.counts["unverified"] == 2 && mixedRepositoryFailure.attentionCount == 1)
        precondition(mixedRepositoryFailure.categories[0].items[0].reason!.contains("prerequisite_unmet"))
        precondition(mixedRepositoryFailure.categories[0].items[0].reason!.contains("observation_failed"))

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
        precondition(EnvironmentComparisonDomain.summaryStatus(precise.categories.first { $0.id == "git-repositories" }!) == .different)

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
        precondition(precise.categoryCount(.needsAttention, category: sshGroup.entries[0].category) == 1)
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
        precondition(EnvironmentComparisonView.summaryOutcomes(ready) == [.match])

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
        precondition(EnvironmentComparisonView.summaryOutcomes(notApplicable) == [.notApplicable])

        precondition(!notApplicable.categories.flatMap(\.items).contains { $0.status == .excluded })
        precondition(ComparisonOutcome.allCases.map { $0.count(visualResult) } == [1, 1, 1, 0, 1])
        let unknown = try presentation(payload([row(0, "unverified", reason: "unknown_difference")], verdict: "incomplete"))
        precondition(unknown.categories[0].items[0].status == .unverified && unknown.summary.contains("unknown difference"))
        let mixed = try presentation(payload([row(0, "matching"), row(1, "differing"), row(2, "unverified", reason: "observation_failed")],
                                             verdict: "differences_detected", unresolved: true, alsoIncomplete: true))
        precondition(mixed.summary == "1 matching · 1 different · 1 unverified · 1 unresolved")
        precondition(mixed.message.contains("could not be verified") && mixed.categories[0].hasAttention)
        precondition(mixed.categories[0].items.contains { $0.status == .unresolved })
        let observation = try presentation(payload([row(0, "unverified", reason: "observation_failed")], verdict: "incomplete"))
        precondition(observation.categories[0].items[0].action == "Couldn’t read the current state.")
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
        precondition(ssh.message.contains("Review the affected categories") && ssh.categories[0].title == "SSH Configuration")
        precondition(ssh.counts["matching"] == 1 && ComparisonOutcome.notApplicable.count(ssh) == 0)
        precondition(ssh.sections.map(\.id) == ["SSH Configuration"])
        precondition(ssh.categoryCount(.match, category: ssh.categories[0]) == 0)
        precondition(ssh.categoryCount(.needsAttention, category: ssh.categories[0]) == 1)

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
        precondition(macOSEntry.category.comparisonStatusText == "Differences Found")
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

        precondition(ComparisonOutcome.allCases.map { macOS.categoryCount($0, category: macOSEntry.category, children: macOSEntry.children) } == [1, 1, 0, 0, 0])
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
                for width in [420, 785, 985, 1200] {
                    try renderResultViewport(finalVisual, model: bundleModel, runtime: bundleRuntime, width: width)
                }
                print("PASS: Real result actions, scroll and fixed footer at 420/785/985/1200pt")
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

        // Exercise the actual preference observer and Comparison projector, never live defaults.
        let macOS = generated.appendingPathComponent("macos")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: false)
        try write("NSGlobalDomain|AppleShowAllExtensions|bool|true\ncom.apple.finder|FXEnableExtensionChangeWarning|bool|true\n", macOS.appendingPathComponent("finder.conf"))
        let finderBlueprint = String(decoding: beforeBlueprint, as: UTF8.self)
            .replacingOccurrences(of: "macos-finder=\"false\"", with: "macos-finder=\"true\"")
            .replacingOccurrences(of: "[homebrew-packages]\ngit\n", with: "[homebrew-packages]\n")
        try write(finderBlueprint, blueprint)
        try write("""
        #!/bin/bash
        case "$1:$2:$3" in
          read-type:NSGlobalDomain:AppleShowAllExtensions) echo "The domain/default pair of ($2, $3) does not exist" >&2; exit 1;;
          read-type:com.apple.finder:FXEnableExtensionChangeWarning) echo 'Type is boolean';;
          read:com.apple.finder:FXEnableExtensionChangeWarning) echo 0;;
          *) echo attempted >> \(quote(marker.path)); exit 99;;
        esac
        """, bin.appendingPathComponent("defaults"), executable: true)
        let beforeFinderReference = try snapshot(generated), beforeFinderHome = try snapshot(home)
        model.compare(); await model.waitForCompletion()
        precondition(model.state == .result)
        let event = runtime.latestResult!
        let comparison = try event.decodeData(CoreComparisonResult.self)
        precondition(comparison.comparisonRecords.count == 2 && comparison.comparison.counts["missing"] == 1 && comparison.comparison.counts["differing"] == 1)
        let expected = ["NSGlobalDomain/AppleShowAllExtensions": "missing", "com.apple.finder/FXEnableExtensionChangeWarning": "differing"]
        for fact in comparison.comparisonRecords {
            precondition(fact.comparisonKind == expected[fact.itemID] && fact.reason == "confirmed_mismatch" && fact.support == "supported")
            precondition(comparison.records.verificationRecords.contains { $0.recordID == fact.recordID && $0.itemID == fact.itemID && $0.predicate == "stored_preference" })
            precondition(comparison.records.diagnostics.contains { $0.recordID == fact.recordID && $0.code == "confirmed_mismatch" && $0.phase == "observation" })
            let item = model.presentation!.categories.flatMap(\.items).first { $0.id == "macos-finder:" + fact.itemID }!
            precondition(item.status == (fact.comparisonKind == "missing" ? .missing : .different))
            precondition(item.reason!.contains(fact.recordID) && item.reason!.contains("Predicate: stored_preference"))
            if fact.comparisonKind == "missing" { precondition(item.action == "Saved preference is not explicitly set on this Mac.") }
        }
        precondition(model.presentation!.categories.first { $0.id == "macos-finder" }!.comparisonStatusText == "Differences Found")
        let afterFinderReference = try snapshot(generated), afterFinderHome = try snapshot(home)
        let afterFinderBlueprint = try String(contentsOf: blueprint)
        precondition(afterFinderReference == beforeFinderReference && afterFinderHome == beforeFinderHome)
        precondition(afterFinderBlueprint == finderBlueprint)
        precondition(!FileManager.default.fileExists(atPath: marker.path))
        let raw = event.data!, records = raw["records"]!.object!
        let proof: [String: CoreJSON] = ["comparison": raw["comparison"]!, "comparison_records": raw["comparison_records"]!,
            "verification_records": records["verification_records"]!, "diagnostics": records["diagnostics"]!]
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(proof).write(to: URL(fileURLWithPath: "build/Debug/Status-colors-Finder-core-records.json"))
        print("PASS: Production Finder records: Show extensions = Missing (absent explicit key), Extension change warning = Different (stored false vs saved true); exact predicates/IDs/diagnostics retained, fixtures unchanged")
    }
}
