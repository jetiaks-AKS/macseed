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
                Label("Home", systemImage: "square.grid.2x2")
                ForEach(ProductTask.allCases) { task in Label(task.title, systemImage: task.symbol) }
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
            let matchingSettings = visual.sections.flatMap(\.entries).first { $0.id == "macos-settings" }!.children.map { category in
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

    @MainActor static func legacySSHCoverageChecks() throws {
        var config = row(0, "matching"); config["domain"] = "ssh-configuration"; config["item_id"] = "config"
        var raw = payload([config], verdict: "incomplete", alsoIncomplete: true)
        var records = raw["records"] as! Object
        records["verification_records"] = [["record_id": "v:0", "domain": "ssh-configuration", "item_id": "config", "predicate": "supported_config_match"]]
        let opaque = "opaque:" + String(repeating: "a", count: 64)
        records["coverage_records"] = [["record_id": "c:legacy", "domain": "ssh-configuration", "item_id": opaque, "disposition": "unresolved", "source_status": "partial"]]
        records["diagnostics"] = [["record_id": "c:legacy", "code": "partial_source_coverage", "severity": "warning", "phase": "scope"]]
        raw["records"] = records
        var summary = raw["comparison"] as! Object, counts = summary["counts"] as! [String: Int]
        counts["unresolved"] = 1; summary["counts"] = counts; raw["comparison"] = summary
        let legacy = try presentation(raw)
        let items = legacy.categories.first { $0.id == "ssh-configuration" }!.items
        precondition(items.count == 2 && items.first { $0.title == "config" }?.status == .matching)
        let coverage = items.first { $0.title == "SSH configuration coverage" }!
        precondition(coverage.status == .attention && coverage.action.contains("only part") && coverage.reason!.contains("partial_source_coverage"))
        precondition(legacy.needsAttention && legacy.counts["matching"] == 1 && legacy.counts["unresolved"] == 1)
        try secureRender(EnvironmentComparisonView(result: legacy, categoryExpansion: .constant(EnvironmentComparisonView.disclosureIDs(legacy))), name: "legacy-coverage")
        // The label is grounded in the owner, domain, source status and exact code.
        // An unrelated opaque warning must never become SSH coverage or key evidence.
        for variant in ["wrong-owner", "observation", "ready-source", "different-domain", "reference"] {
            var altered = records
            var coverageRows = altered["coverage_records"] as! [Object]
            var diagnostics = altered["diagnostics"] as! [Object]
            if variant == "wrong-owner" { diagnostics[0]["record_id"] = "unrelated" }
            if variant == "observation" { diagnostics[0]["code"] = "observation_failed" }
            if variant == "ready-source" { coverageRows[0]["source_status"] = "observed_present" }
            if variant == "different-domain" { coverageRows[0]["domain"] = "shell-zsh" }
            if variant == "reference" {
                coverageRows[0]["item_id"] = "identity-references"
                diagnostics[0]["code"] = "prerequisite_unmet"; diagnostics[0]["phase"] = "observation"
            }
            altered["coverage_records"] = coverageRows; altered["diagnostics"] = diagnostics; raw["records"] = altered
            let value = try presentation(raw)
            precondition(!value.categories.flatMap(\.items).contains { $0.title == "SSH configuration coverage" })
            precondition(value.needsAttention && value.counts == legacy.counts)
            if variant == "reference" { precondition(value.categories.flatMap(\.items).contains { $0.title == "SSH key references" }) }
        }
        print("PASS: legacy partial SSH coverage has a scoped private-safe label; modern references and unrelated evidence keep their predicates/counts")
    }

    static func topologyChecks() throws {
        let identities = ["opaque:" + String(repeating: "a", count: 64),
                          "opaque:" + String(repeating: "b", count: 64)]
        let workspaceID = "workspace-" + String(repeating: "c", count: 64)
        for kind in ["matching", "missing", "differing", "unverified"] {
            for unsupported in kind == "unverified" ? [false, true] : [false] {
                let reason = kind == "matching" ? nil : kind == "unverified"
                    ? (unsupported ? "unsupported_predicate" : "prerequisite_unmet") : "confirmed_mismatch"
                var rows: [Object] = [], owners: [Object] = [], diagnostics: [Object] = []
                for index in 0..<3 {
                    let domain = index == 2 ? "vscode-workspaces" : "git-repositories"
                    let identity = index == 2 ? workspaceID : identities[index]
                    var fact = row(index, kind, support: unsupported ? "unsupported" : "supported", reason: reason)
                    fact["domain"] = domain; fact["item_id"] = identity
                    rows.append(fact)
                    owners.append(["record_id": "v:\(index)", "domain": domain, "item_id": identity,
                                   "predicate": index == 2 ? "folder_relationships" : "topology"])
                    if let reason {
                        diagnostics.append(["record_id": "v:\(index)", "code": reason, "severity": "warning", "phase": "observation"])
                    }
                }
                let verdict = kind == "matching" ? "no_differences_detected" : kind == "unverified" ? "incomplete" : "differences_detected"
                var object = payload(rows, verdict: verdict)
                var records = object["records"] as! Object
                records["verification_records"] = Array(owners.reversed())
                records["diagnostics"] = diagnostics
                object["records"] = records
                object["reference_presentation"] = ["groups": [], "app_store_names": [:],
                    "repository_labels": [identities[0]: "demo", identities[1]: "demo"],
                    "workspace_labels": [workspaceID: "view.code-workspace"]] as Object
                let value = try presentation(object)
                let event = try CoreEvent(line: data(["protocol_version": 1, "operation_id": "topology-fixture",
                    "sequence": 1, "type": "result", "data": object]))
                var sanitizer = OperationLogSanitizer()
                let log = sanitizer.event(event, at: Date())
                let logText = String(decoding: try JSONEncoder().encode(log), as: UTF8.self)
                var report = DiagnosticReportBuilder(id: UUID(), environment: .init(version: "3.4.0", build: nil,
                    macOS: .init(majorVersion: 14, minorVersion: 0, patchVersion: 0), architecture: "arm64"))
                report.receive(log)
                for privateValue in ["view.code-workspace", "demo", workspaceID] + identities {
                    precondition(!logText.contains(privateValue) && !report.snapshot().text.contains(privateValue))
                }
                let repositories = value.categories.first { $0.id == "git-repositories" }!
                let descriptors = value.categories.first { $0.id == "vscode-workspaces" }!
                let expected: DisplayStatus = kind == "matching" ? .matching : kind == "missing" ? .missing
                    : kind == "differing" ? .different : unsupported ? .unsupported : .unverified
                precondition(repositories.items.count == 2 && repositories.items.allSatisfy { $0.status == expected && $0.title == "demo" })
                precondition(descriptors.items.count == 1 && descriptors.items[0].status == expected
                             && descriptors.items[0].title == "view.code-workspace")
                precondition(value.technicalFacts[descriptors.items[0].id]?.first?.predicateTitle == "Folder relationships")
                precondition(value.needsAttention == (kind == "unverified"))
                precondition(value.attentionCount == (kind == "unverified" ? 3 : 0))
                let outcome: ComparisonOutcome = kind == "matching" ? .match : kind == "missing" ? .missing
                    : kind == "differing" ? .different : .needsAttention
                precondition(value.categoryCount(outcome, category: repositories) == 2)
                precondition(value.categoryCount(outcome, category: descriptors) == 1)
                object["comparison_records"] = Array(rows.reversed())
                let reordered = try presentation(object)
                precondition(Set(reordered.categories.flatMap(\.items).map(\.id)) == Set(value.categories.flatMap(\.items).map(\.id)))
                object["reference_presentation"] = ["groups": [], "app_store_names": [:],
                    "workspace_labels": [workspaceID: "/Users/private/view.code-workspace"]] as Object
                let fallback = try presentation(object)
                precondition(fallback.categories.first { $0.id == "vscode-workspaces" }!.items[0].title == "VS Code Workspace")
                if kind == "matching" {
                    // Same record ID with the wrong item cannot prove relationships.
                    owners[2]["item_id"] = "another-workspace"
                    records["verification_records"] = owners
                    object["records"] = records
                    let incomplete = try presentation(object)
                    precondition(incomplete.needsAttention)
                    precondition(incomplete.categories.first { $0.id == "vscode-workspaces" }!.items[0].status == .unverified)
                }
            }
        }
        print("PASS: topology and folder_relationships Status, stable identity, labels, counts, diagnostics and failed correlation")
    }

    @MainActor static func groupedPresentationChecks() throws {
        var rows: [Object] = []
        var owners: [Object] = []
        func append(_ domain: String, _ item: String, _ kind: String = "matching", predicate: String = "installed", unsupported: Bool = false) {
            let id = rows.count
            var fact = row(id, kind, support: unsupported ? "unsupported" : "supported",
                reason: unsupported ? "unsupported_predicate" : kind == "unverified" ? "observation_failed" : kind == "matching" ? nil : "confirmed_mismatch")
            fact["domain"] = domain; fact["item_id"] = item; rows.append(fact)
            owners.append(["record_id": "v:\(id)", "domain": domain, "item_id": item, "predicate": predicate])
        }
        append("app-store", "425264550", "missing")
        append("homebrew-casks", "firefox")
        append("homebrew-casks", "iina", "differing")
        append("homebrew-packages", "git")
        append("homebrew-packages", "unavailable-package", "unverified")
        for domain in CaptureMacOSSettingsGroup.domainIDs {
            append(domain, "saved-preference", domain == "macos-dock" ? "differing" : "matching", predicate: "stored_preference")
        }
        append("vscode-extensions", "ms-python.python")
        append("vscode-extensions", "ms-azuretools.vscode-docker", "missing")
        append("vscode-settings", "settings.json", predicate: "file_content")
        append("git-configuration", "user.name", predicate: "direct_global_value")
        for predicate in ["worktree", "origin", "branch"] {
            append("git-repositories", "repository-1", predicate == "branch" ? "differing" : "matching", predicate: predicate)
        }
        append("workspace-folders", "Infrastructure", predicate: "directory")
        append("ssh-configuration", "config", "unverified", predicate: "file_content", unsupported: true)
        append("shell-zsh", ".zshrc", predicate: "file_content")
        append("vscode-workspaces", "workspace-1", predicate: "folder_relationships")
        var raw = payload(rows, verdict: "differences_detected", alsoIncomplete: true)
        var evidence = raw["records"] as! Object
        evidence["verification_records"] = owners
        raw["records"] = evidence
        raw["reference_presentation"] = ["groups": WorkspacePresentationTaxonomy.Group.allCases.map {
            ["id": $0.title, "domains": $0.domains] as Object
        }, "app_store_names": ["425264550": "Blackmagic Disk Speed Test"],
        "repository_labels": ["repository-1": "Infrastructure"], "workspace_labels": ["workspace-1": "Project workspace"],
        "setting_labels": Dictionary(uniqueKeysWithValues: CaptureMacOSSettingsGroup.domainIDs.map { ($0, ["saved-preference": "Saved preference"]) })] as Object
        let result = try presentation(raw)
        let grouped = EnvironmentComparisonView.visibleSections(result)
        precondition(grouped.map(\.id) == ["Standard Setup", "For Experienced Users"])
        precondition(grouped[0].entries.map(\.id) == ["app-store", "homebrew-casks", "homebrew-packages", "macos-settings", CaptureHierarchy.Group.vscode.id])
        precondition(grouped[0].entries[3].children.map(\.id) == CaptureMacOSSettingsGroup.domainIDs)
        precondition(grouped[0].entries[4].children.map(\.id) == ["vscode-extensions", "vscode-settings"])
        precondition(grouped[1].entries.map(\.id) == [DeveloperSelectionGroup.git.id, DeveloperSelectionGroup.workspace.id, DeveloperSelectionGroup.ssh.id, DeveloperSelectionGroup.shell.id])
        precondition(grouped[1].entries.map { $0.children.map(\.id) } == [["git-configuration", "git-repositories"], ["workspace-folders", "vscode-workspaces"], ["ssh-configuration"], ["shell-zsh"]])
        let projected = grouped.flatMap(\.entries).flatMap { $0.children.isEmpty ? $0.category.items : $0.children.flatMap(\.items) }
        let originals = result.categories.flatMap(\.items)
        precondition(projected.count == originals.count && Set(projected.map(\.id)) == Set(originals.map(\.id)))
        for item in originals {
            let copy = projected.first { $0.id == item.id }!
            precondition(copy.title == item.title && copy.status == item.status && copy.action == item.action && copy.reason == item.reason)
        }
        for outcome in ComparisonOutcome.allCases {
            precondition(grouped.flatMap(\.entries).reduce(0) { $0 + result.categoryCount(outcome, category: $1.category, children: $1.children) }
                == result.categories.reduce(0) { $0 + result.categoryCount(outcome, category: $1) }, "Grouping must not change category counts")
        }
        precondition(grouped[1].entries.first { $0.id == DeveloperSelectionGroup.ssh.id }!.category.comparisonStatus == .attention)
        precondition(grouped[0].entries[3].category.comparisonStatus == .different)
        precondition(projected.contains { $0.isNormalComparisonMatch } && projected.contains { $0.status == .unsupported })
        let warning = DisplayItem(id: "ssh-configuration:identity-references", title: "SSH key references", status: .attention, action: "Unverified prerequisite", reason: "prerequisite_unmet")
        let config = DisplayCategory(id: "ssh-configuration", title: "SSH Configuration", symbol: "key", items: [warning])
        let parent = DisplayCategory(id: DeveloperSelectionGroup.ssh.id, title: "SSH", symbol: "key", items: [warning])
        precondition(EnvironmentComparisonDomain.showsAggregateStatus(parent, children: [config], expanded: false))
        precondition(!EnvironmentComparisonDomain.showsAggregateStatus(parent, children: [config], expanded: true))
        precondition(!EnvironmentComparisonDomain.showsAggregateStatus(config, expanded: true), "The visible leaf retains the identical warning")
        let independent = DisplayItem(id: "ssh:independent", title: "Independent warning", status: .attention, action: "Different evidence", reason: nil)
        let additional = DisplayCategory(id: parent.id, title: parent.title, symbol: parent.symbol, items: [warning, independent])
        precondition(EnvironmentComparisonDomain.showsAggregateStatus(additional, children: [config], expanded: true), "Never hide additional independent evidence")
        let missing = DisplayCategory(id: "fixture", title: "Fixture", symbol: "folder", items: [DisplayItem(id: "missing", title: "Missing item", status: .missing, action: "", reason: nil)])
        precondition(EnvironmentComparisonDomain.showsAggregateStatus(missing, expanded: true), "Specific leaf and aggregate labels remain distinct")
        precondition(config.comparisonStatusText == "Needs Attention" && missing.comparisonStatusText == "Differences Found")
        precondition(EnvironmentComparisonDomain.badgeCounts([.match: 2, .missing: 1, .needsAttention: 1]).map { $0.0 } == ["Match", "Differences Found", "Needs Attention"])
        let ids = EnvironmentComparisonView.disclosureIDs(result)
        let parents = Set(["macos-settings", CaptureHierarchy.Group.vscode.id] + DeveloperSelectionGroup.allCases.map(\.id))
        precondition(ids == Set(result.categories.map(\.id)).union(parents))
        precondition(!ids.contains("Standard Setup") && !ids.contains("For Experienced Users"), "Section headers never disclose")
        precondition(Set(CaptureMacOSSettingsGroup.domainIDs).isSubset(of: ids))
        precondition(EnvironmentComparisonView.toggledCategories([], ids: ids) == ids)
        precondition(EnvironmentComparisonView.toggledCategories(ids, ids: ids).isEmpty)
        var sparse = payload([row(0, "matching")], verdict: "no_differences_detected")
        let ordinary = try presentation(sparse)
        precondition(EnvironmentComparisonView.visibleSections(ordinary).map(\.id) == ["Standard Setup"])
        var sparseEvidence = sparse["records"] as! Object
        sparseEvidence["coverage_records"] = [["record_id": "c:none", "domain": "shell-zsh", "item_id": "scope", "disposition": "no_requirement", "source_status": "observed_absent"]]
        sparse["records"] = sparseEvidence
        let absent = try presentation(sparse)
        precondition(EnvironmentComparisonView.visibleSections(absent).map(\.id) == ["Standard Setup"], "Absent Advanced scope must stay hidden")
        precondition(ComparisonSummaryOutcome.notApplicable.count(absent) == 1, "Authoritative coverage summary remains unchanged")
        var future = row(0, "unverified"); future["domain"] = "future-domain"
        let unknown = try presentation(payload([future], verdict: "incomplete", alsoIncomplete: true))
        precondition(EnvironmentComparisonView.visibleSections(unknown).map(\.id) == ["Standard Setup"])
        let sameNames = projected.filter { $0.title == "Infrastructure" }
        precondition(sameNames.count == 2 && Set(sameNames.map(\.id)).count == 2, "Git and folder requirements never merge by display name")
        precondition(grouped[1].entries.flatMap(\.children).contains { $0.title == "Git Repositories / Worktrees" })
        precondition(grouped[1].entries.flatMap(\.children).contains { $0.title == "Workspace Folders" })
        precondition(EnvironmentStatusSection.project([DisplayCategory(id: "ssh-configuration", title: "SSH Configuration", symbol: "key", items: [])]).isEmpty)
        try secureRender(EnvironmentComparisonView(result: result, categoryExpansion: .constant([])), name: "all-collapsed", height: 1300)
        try secureRender(EnvironmentComparisonView(result: result, categoryExpansion: .constant(["macos-settings", CaptureHierarchy.Group.vscode.id])), name: "standard-expanded", height: 1800)
        try secureRender(EnvironmentComparisonView(result: result, categoryExpansion: .constant(Set(DeveloperSelectionGroup.allCases.map(\.id)))), name: "developer-expanded", height: 1800)
        try secureRender(EnvironmentComparisonView(result: result, categoryExpansion: .constant(Set(DeveloperSelectionGroup.allCases.map(\.id) + ["git-repositories", "workspace-folders", "ssh-configuration"]))), name: "developer-details", height: 2100)
        let output = URL(fileURLWithPath: "build/Debug/StatusFinalGrouping", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try data(raw).write(to: output.appendingPathComponent("comparison-fixture.json"))
        print("PASS: Static Status sections preserve every included matching/differing/unsupported item and diagnostic, counts once, hides absent groups, retains unknown evidence and nested disclosures")
    }

    @MainActor static func secureRender<V: View>(_ view: V, name: String, sheet: Bool = false, height: CGFloat = 1000) throws {
        let directory = URL(fileURLWithPath: "/private/tmp/macseed-check-legacy-visuals")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for dark in [false, true] {
            _ = NSApplication.shared
            NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let root = VStack(alignment: .leading, spacing: 16) {
                if !sheet { WorkspaceHeader(title: "Check", subtitle: "Compare a saved environment with this Mac.", symbol: "checkmark.circle") }
                view
                if !sheet { Spacer(minLength: 0) }
            }.padding(sheet ? 0 : 24).frame(width: sheet ? 620 : 960, height: sheet ? 460 : height, alignment: .topLeading)
                .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, dark ? .dark : .light)
            let host = NSHostingView(rootView: root)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: sheet ? 620 : 960, height: sheet ? 460 : height), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host
            host.frame = window.contentView!.bounds; host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { preconditionFailure("Secure Check render unavailable") }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name + (dark ? "-dark.png" : "-light.png")))
            window.close()
        }
    }

    @MainActor static func secureCheckTests() async throws {
        let bundleID = String(repeating: "b", count: 64), identityID = String(repeating: "a", count: 64)
        var ordinary = payload([row(0, "matching")], verdict: "no_differences_detected")
        var rows = ordinary["comparison_records"] as! [Object]
        rows[0]["domain"] = "ssh-configuration"; rows[0]["item_id"] = "config"
        ordinary["comparison_records"] = rows
        let unchanged = try presentation(ordinary)
        precondition(unchanged.secureCoverage == nil && unchanged.headline == "No differences detected")
        try secureRender(EnvironmentComparisonView(result: unchanged, categoryExpansion: .constant(EnvironmentComparisonView.disclosureIDs(unchanged))), name: "ordinary")
        ordinary["secure_check"] = ["version": 1, "bundle_id": bundleID, "status": "available"]
        let unchecked = try presentation(ordinary)
        precondition(unchecked.counts["matching"] == 1 && unchecked.headline == "Check Incomplete" && unchecked.needsAttention)
        precondition(unchecked.categories.first { $0.id == "secure-ssh-identities" }?.comparisonStatusText == "Not checked")
        let ssh = EnvironmentComparisonView.visibleSections(unchecked).first { $0.id == "For Experienced Users" }!.entries.first { $0.id == CaptureHierarchy.sshID }!
        precondition(ssh.children.map(\.id) == ["ssh-configuration", "secure-ssh-identities"])
        precondition(ssh.category.comparisonStatusText == "Partially checked")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("macseed-check-ui-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let core = directory.appendingPathComponent("core")
        try FileManager.default.createDirectory(at: core.appendingPathComponent("modules/core/application-interface"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: core.appendingPathComponent("config"), withIntermediateDirectories: true)
        for path in ["modules/core/application-interface/core.py", "config/toolkit.conf", "bootstrap.sh"] { try Data().write(to: core.appendingPathComponent(path)) }
        try write("#!/bin/bash\nexec python3 -B fixture.py \"$@\"\n", core.appendingPathComponent("modules/core/application-interface/core.sh"))
        for helper in ["secret_input.py", "age_runtime.py"] {
            try FileManager.default.copyItem(at: URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("modules/migration/" + helper), to: core.appendingPathComponent(helper))
        }
        try data(ordinary).write(to: core.appendingPathComponent("ordinary.json"))
        try write("matching", core.appendingPathComponent("mode"))
        try write(#"""
        import json, os, sys, time, uuid
        from pathlib import Path
        from secret_input import inherited_socket, metadata, receive, response, SecureError
        request = json.load(sys.stdin); seq = 0
        def emit(kind, data=None):
            global seq
            seq += 1
            print(json.dumps(dict(protocol_version=1, operation_id=request['operation_id'], sequence=seq, type=kind, data=data or {})), flush=True)
        safety = dict(read_only=True, publication_occurred=False, target_mutation_may_have_started=False)
        op = request['operation']; mode = Path('mode').read_text(); emit('started')
        with Path('operations').open('a') as stream: stream.write(op+'\n')
        if op == 'capabilities':
            features = dict(bundle_comparison=dict(version=1))
            if mode != 'unsupported': features['secure_check'] = dict(version=1, selection_version=2, read_only=True)
            emit('result', dict(protocol_version=1, product_version='fixture', operations=['environment_compare','secure_check_inventory','secure_check_compare'], features=features))
            emit('completed'); sys.exit(0)
        if op == 'environment_compare':
            assert '--secure-fd' not in sys.argv
            emit('result', json.loads(Path('ordinary.json').read_text())); emit('completed', safety); sys.exit(0)
        assert op in ('secure_check_inventory', 'secure_check_compare')
        channel = inherited_socket(int(sys.argv[-1]))
        emit('phase_started', dict(phase='secure_compare'))
        for attempt in range(1,4):
            challenge = dict(type='challenge', protocol_version=1, operation_id=request['operation_id'], challenge_id=uuid.uuid4().hex, kind='import_confirmation' if mode == 'forbidden_import' else 'ssh_key_unlock' if mode == 'forbidden_key_unlock' else 'bundle_unlock', attempt=attempt)
            if mode == 'forbidden_key_unlock': challenge['identity'] = dict(name='id_fixture', key_type='ssh-ed25519', fingerprint='SHA256:'+'A'*43)
            metadata(channel, challenge)
            try: secret = response(receive(channel, time.monotonic()+10), challenge)
            except (SecureError, OSError):
                emit('cancelled', dict(code='secure_cancelled', **safety)); sys.exit(130)
            if secret == b'fixture secret': break
        else:
            emit('failed', dict(code='secure_unlock_rejected', **safety)); sys.exit(2)
        channel.close()
        if mode in ('unavailable','reference_changed','timeout'):
            emit('failed', dict(code=dict(unavailable='secure_payload_invalid',reference_changed='reference_changed',timeout='secure_channel_timeout')[mode], **safety)); sys.exit(2)
        root = Path(os.environ['TMPDIR'])
        value = dict(version=1, operation_id=request['operation_id'], bundle_id='b'*64)
        if op == 'secure_check_inventory':
            value['items'] = [dict(identity_id=key*64, name=name, key_type='ssh-ed25519', fingerprint='SHA256:'+key.upper()*43) for key,name in [('a','id_fixture_work'),('c','id_fixture_personal')]]
            filename = 'secure-restore-inventory.json'
        else:
            mapping = json.loads((root/'secure-restore-destinations.json').read_text())['mapping']
            Path('last-mapping.json').write_text(json.dumps(mapping))
            kind = mode if mode in ('matching','missing','differing','unverified') else 'matching'
            def observation(item, index):
                kind = ('matching' if index == 0 else 'missing') if mode == 'mixed' else mode if mode in ('matching','missing','differing','unverified') else 'matching'
                return dict(identity_id=item['identity_id'], comparison_kind=kind,
                reason=dict(matching='pair_identical',missing='pair_absent',differing='private_bytes_differ',unverified='unsafe_target')[kind],
                target_state=None if kind=='unverified' else 'd'*64, private_bytes_match=kind=='matching' if kind in ('matching','differing') else None,
                public_bytes_match=True if kind in ('matching','differing') else None)
            value['items'] = [observation(item, index) for index, item in enumerate(mapping['items']) if item['selected']]
            value['context'] = dict(mapping=mapping, target_state='d'*64, source_validation='saved_files',
                ssh_reference_coverage='resolved' if kind=='matching' else 'unresolved', observed_at='2026-11-09T10:00:00.000001+00:00', **safety)
            filename = 'secure-check-result.json'
            if mode == 'wrong_assurance': value['context']['source_validation'] = 'cryptographic_pair'
            if mode == 'wrong_operation': value['operation_id'] = 'wrong'
            if mode == 'wrong_mapping': value['context']['mapping']['items'][0]['directory'] = '/wrong'
            if mode == 'extra_field': value['context']['unexpected'] = True
            if mode == 'compensated_field':
                value['context']['mapping']['items'][1].pop('directory'); value['context']['mapping']['items'][1]['unexpected'] = None
            if mode == 'duplicate_field':
                raw = json.dumps(value).replace('"version": 1', '"version": 1, "version": 1', 1)
            else: raw = json.dumps(value)
        if op == 'secure_check_inventory': raw = json.dumps(value)
        fd = os.open(root/filename, os.O_CREAT|os.O_EXCL|os.O_WRONLY, 0o600)
        with os.fdopen(fd,'w') as stream: stream.write(raw)
        if mode == 'unsafe_file': (root/filename).chmod(0o644)
        emit('phase_completed', dict(phase='secure_compare')); emit('result', dict(status='checked', **safety)); emit('completed', safety)
        """#, core.appendingPathComponent("fixture.py"))
        let python = URL(fileURLWithPath: CommandLine.arguments[2])
        let location = CoreLocation(root: core, python: python, home: directory, temporaryBase: directory, toolDirectories: [])
        let runtime = CoreRuntime(operationLogs: nil)
        runtime.start(CoreRequest(.capabilities), location: location); await runtime.waitForCompletion()
        precondition(runtime.secureCheckSupported, "Capability fixture failed: \(String(describing: runtime.error))")
        let model = EnvironmentStatusModel(runtime: runtime, location: location)
        let bundle = directory.appendingPathComponent("Fixture.mbt"); try write("fixture", bundle)
        func operations() throws -> [String] { try String(contentsOf: core.appendingPathComponent("operations")).split(separator: "\n").map(String.init) }
        func evidence() -> [String] {
            guard let value = model.presentation else { return [] }
            return [value.headline, value.summary, String(describing: value.counts.sorted { $0.key < $1.key }), model.secureMessage ?? ""]
                + value.categories.flatMap(\.items).map { [$0.id, $0.title, $0.status.rawValue, $0.action, $0.reason ?? ""].joined(separator: "|") }
        }
        func cancelledDraft(_ name: String) async throws {
            let before = evidence(), operationsBefore = try operations()
            let selection = model.selectedSecureIDs, directories = model.secureDirectories
            model.customizeSSHKeys(); await model.waitForCompletion()
            precondition(model.showsSecureSelection && evidence() == before)
            model.setSecureDirectory(directory.appendingPathComponent("Discarded Keys").path, for: identityID)
            model.selectSecureIdentity(String(repeating: "c", count: 64), included: !selection.contains(String(repeating: "c", count: 64)))
            precondition(model.selectedSecureIDs == selection && model.secureDirectories == directories && evidence() == before)
            precondition(model.draftSecureDirectories != directories)
            for id in model.draftSecureIDs { model.selectSecureIdentity(id, included: false) }
            model.compareSSHKeys()
            precondition(model.showsSecureSelection && evidence() == before, "Empty scope never starts a comparison or commits edits")
            model.cancelSecureSelection()
            precondition(!model.showsSecureSelection && model.draftSecureIDs.isEmpty && model.draftSecureDirectories.isEmpty)
            precondition(model.selectedSecureIDs == selection && model.secureDirectories == directories && evidence() == before)
            precondition(try! operations() == operationsBefore, "Opening/editing/cancelling with authenticated inventory never runs Core")
            model.customizeSSHKeys(); await model.waitForCompletion()
            precondition(model.draftSecureIDs == selection && model.draftSecureDirectories == directories, "Cancelled mappings must not return")
            model.cancelSecureSelection()
            if name == "differing" { try show("location-cancelled-different") }
            print("PASS: Change Location Cancel preserves " + name + " evidence, counts, scope and committed mapping without Core operations")
        }
        func show(_ name: String) throws {
            let result = model.presentation!
            try secureRender(VStack(alignment: .leading, spacing: 16) {
                Text(result.headline).font(.title2.weight(.semibold))
                EnvironmentComparisonView(result: result, secureActions: model.showsSecureRecovery ? AnyView(EnvironmentSecureCheckStatus(
                    message: model.secureCoverageMessage ?? "", available: model.canRetrySSHKeys,
                    customizable: model.canRetrySSHKeys, customize: model.customizeSSHKeys, check: model.checkSSHKeys)) : nil,
                    categoryExpansion: .constant(EnvironmentComparisonView.disclosureIDs(result)))
                EnvironmentStatusActions(model: model, runtime: runtime)
            }, name: name)
        }
        func prompt() async throws -> CoreSecureChallenge {
            for _ in 0..<500 {
                if let challenge = model.secureChallenge { return challenge }
                try await Task.sleep(for: .milliseconds(10))
            }
            preconditionFailure("Expected bounded Check authentication prompt")
        }
        @discardableResult func finish(cancel: Bool = false, wrongFirst: Bool = false, wrongAll: Bool = false) async throws -> Int {
            var prompts = 0
            for _ in 0..<1000 {
                try await Task.sleep(for: .milliseconds(10))
                if let challenge = model.secureChallenge {
                    precondition(challenge.kind == .bundleUnlock, "Check must never request Import consent")
                    prompts += 1
                    model.respondToSecureCheck(challenge, cancel ? .cancel : .secret(Data((wrongAll || (wrongFirst && prompts == 1) ? "wrong fixture" : "fixture secret").utf8)))
                }
                if !runtime.isActive && !model.secureBusy && model.state != .running { break }
            }
            precondition(!runtime.isActive && !model.secureBusy && model.state != .running, "Protected Check did not finish")
            await model.waitForCompletion()
            return prompts
        }
        // A Bundle without keys remains a single ordinary operation and no prompt.
        var noKeys = ordinary; noKeys.removeValue(forKey: "secure_check")
        try data(noKeys).write(to: core.appendingPathComponent("ordinary.json"))
        model.selectBundle(bundle); model.compare(); await model.waitForCompletion()
        precondition(model.state == .result && model.secureChallenge == nil && !model.secureCheckAvailable)
        precondition(try! operations().filter { $0 == "environment_compare" }.count == 1)
        try show("ordinary")
        try data(ordinary).write(to: core.appendingPathComponent("ordinary.json"))
        model.selectBundle(bundle); model.compare()
        let initial = try await prompt()
        precondition(model.state == .running && model.secureBusy && runtime.operation == .secureCheckInventory)
        try secureRender(CaptureSecureInputView(runtime: CoreRuntime(operationLogs: nil), challenge: initial, checking: true), name: "initial-prompt", sheet: true)
        let promptCount = try await finish()
        precondition(promptCount == 1, "One Bundle prompt continues inventory to comparison, scoped to this Check only; observed \(promptCount)")
        precondition(!model.showsSecureSelection && model.selectedSecureIDs.count == 2)
        precondition(model.presentation?.counts["matching"] == 3 && model.presentation?.headline == "No differences detected")
        precondition(!model.canRetrySSHKeys && !model.showsSecureRecovery)
        precondition(try! operations().suffix(3) == ["environment_compare","secure_check_inventory","secure_check_compare"])
        try show("matching")
        try await cancelledDraft("Matches")
        let ordinaryCount = try operations().filter { $0 == "environment_compare" }.count
        // Recovery offers optional locations/subsets only when there is a difference.
        try write("missing", core.appendingPathComponent("mode"))
        model.checkSSHKeys(); try await finish()
        precondition(model.canRetrySSHKeys && model.showsSecureRecovery)
        try await cancelledDraft("Missing")
        try write("matching", core.appendingPathComponent("mode"))
        // No identity outside the selected subset is falsely matched.
        model.customizeSSHKeys(); await model.waitForCompletion()
        precondition(model.showsSecureSelection)
        let previousEvidence = evidence(), previousOperations = try operations().count
        try secureRender(EnvironmentSecureSelectionView(model: model), name: "selection-default", sheet: true)
        model.setSecureDirectory(directory.appendingPathComponent("Custom Keys").path, for: identityID)
        model.selectSecureIdentity(String(repeating: "c", count: 64), included: false)
        try secureRender(EnvironmentSecureSelectionView(model: model), name: "selection-custom", sheet: true)
        precondition(evidence() == previousEvidence && model.selectedSecureIDs.count == 2 && model.secureDirectories.isEmpty)
        model.compareSSHKeys(); let laterPrompts = try await finish()
        precondition(try! operations().count == previousOperations + 1)
        let sent = try JSONDecoder().decode(CoreRestoreDestinations.self, from: Data(contentsOf: core.appendingPathComponent("last-mapping.json")))
        precondition(sent.items.filter { $0.selected == true }.map(\.identityID) == [identityID])
        precondition(sent.items.first { $0.identityID == identityID }?.directory == directory.appendingPathComponent("Custom Keys").path)
        precondition(model.selectedSecureIDs == [identityID] && model.secureDirectories[identityID] != nil && model.draftSecureIDs.isEmpty)
        precondition(laterPrompts == 1, "No retained passphrase after completed Check")
        precondition(model.presentation?.counts["matching"] == 2 && model.presentation?.counts["unverified"] == 1)
        precondition(model.presentation?.headline == "Check Incomplete" && model.presentation?.attentionCount == 1 && model.canRetrySSHKeys)
        precondition(model.presentation?.categories.first { $0.id == "secure-ssh-identities" }?.items.count == 2)
        try show("partial")
        try await cancelledDraft("partial selected subset/custom destination")
        try write("mixed", core.appendingPathComponent("mode"))
        model.checkSSHKeys(); try await finish()
        precondition(model.presentation?.counts["matching"] == 2 && model.presentation?.counts["missing"] == 1)
        precondition(model.presentation?.counts["unverified"] == 0 && model.presentation?.headline == "Differences Found")
        precondition(model.canRetrySSHKeys && model.showsSecureRecovery)
        try show("mixed")
        for kind in ["missing", "differing", "unverified"] {
            try write(kind, core.appendingPathComponent("mode"))
            model.checkSSHKeys(); try await finish()
            precondition(model.state == .result && model.presentation?.counts[kind] == 2)
            precondition(model.selectedSecureIDs.count == 2 && model.secureDirectories[identityID] != nil)
            precondition(model.canRetrySSHKeys && model.showsSecureRecovery)
            precondition(model.presentation?.headline == (kind == "unverified" ? "Needs Attention" : "Differences Found"))
            try show(kind)
            try await cancelledDraft(kind)
        }
        try write("matching", core.appendingPathComponent("mode"))
        model.checkSSHKeys(); try await finish(cancel: true)
        precondition(model.state == .result && model.presentation?.counts["matching"] == 1 && model.secureMessage?.contains("cancelled") == true)
        precondition(model.canRetrySSHKeys && model.presentation?.headline == "Check Incomplete")
        try show("cancelled")
        model.checkSSHKeys(); let retryPrompts = try await finish(wrongFirst: true)
        precondition(retryPrompts == 2)
        precondition(model.presentation?.counts["matching"] == 3 && !model.canRetrySSHKeys && !model.showsSecureRecovery)
        model.checkSSHKeys(); let exhaustedPrompts = try await finish(wrongAll: true)
        precondition(exhaustedPrompts == 3 && model.canRetrySSHKeys && model.showsSecureRecovery)
        precondition(model.presentation?.counts["matching"] == 1 && model.presentation?.headline == "Check Incomplete")
        precondition(try! operations().filter { $0 == "environment_compare" }.count == ordinaryCount, "Scoped retries cannot rerun ordinary domains")
        for mode in ["unavailable", "timeout", "wrong_operation", "wrong_mapping", "extra_field", "compensated_field", "duplicate_field", "unsafe_file", "forbidden_import", "forbidden_key_unlock", "wrong_assurance", "reference_changed"] {
            try write(mode, core.appendingPathComponent("mode"))
            model.checkSSHKeys(); try await finish()
            precondition(model.state == .result && model.presentation?.counts["matching"] == 1 && model.secureMessage != nil, "Reject invalid private result: \(mode)")
            if mode == "unavailable" { try show("unavailable") }
            if model.requiresFullCheck {
                precondition(!model.canRetrySSHKeys)
                let before = try operations().count
                model.checkSSHKeys(); await model.waitForCompletion()
                precondition(try! operations().count == before, "Invalid context requires full Check")
                try write("matching", core.appendingPathComponent("mode"))
                model.compare(); try await finish()
            }
        }
        let priorID = model.operationID
        try write("matching", core.appendingPathComponent("mode"))
        model.compare(); try await finish()
        precondition(model.operationID != priorID && model.presentation?.counts["matching"] == 3)
        model.customizeSSHKeys(); await model.waitForCompletion()
        let staleOperationCount = try operations().count
        model.setSecureDirectory(directory.appendingPathComponent("Stale Keys").path, for: identityID)
        model.selectBundle(bundle)
        model.compareSSHKeys()
        precondition(try! operations().count == staleOperationCount)
        precondition(model.state == .choose && model.secureDirectories.isEmpty && model.draftSecureDirectories.isEmpty)
        model.compare(); try await finish()
        // A failed initial unlock has no inventory. Authenticating the optional
        // dialog may load it, but still must not commit scope or change evidence.
        model.selectBundle(bundle)
        try write("unavailable", core.appendingPathComponent("mode"))
        model.compare(); try await finish()
        let beforeInventoryDraft = evidence()
        precondition(model.secureInventory == nil && model.selectedSecureIDs.isEmpty)
        try write("matching", core.appendingPathComponent("mode"))
        model.customizeSSHKeys(); try await finish()
        precondition(model.showsSecureSelection && model.draftSecureIDs.count == 2 && model.selectedSecureIDs.isEmpty)
        precondition(evidence() == beforeInventoryDraft)
        let afterInventory = try operations().count
        model.cancelSecureSelection()
        precondition(evidence() == beforeInventoryDraft && model.selectedSecureIDs.isEmpty && model.secureDirectories.isEmpty)
        precondition(try! operations().count == afterInventory)
        model.customizeSSHKeys(); await model.waitForCompletion()
        precondition(model.draftSecureIDs.count == 2 && model.selectedSecureIDs.isEmpty && evidence() == beforeInventoryDraft)
        model.cancelSecureSelection()
        model.compare(); try await finish()
        try write("unsupported", core.appendingPathComponent("mode"))
        runtime.start(CoreRequest(.capabilities), location: location); await runtime.waitForCompletion()
        model.compare(); await model.waitForCompletion()
        precondition(!model.canCheckSSHKeys && model.presentation?.headline == "Check Incomplete")
        model.selectBundle(bundle)
        precondition(model.secureInventory == nil && model.selectedSecureIDs.isEmpty && model.secureDirectories.isEmpty)
        model.compareSSHKeys(); model.setSecureDirectory("/unconfirmed", for: identityID)
        precondition(!model.showsSecureSelection && model.draftSecureIDs.isEmpty && model.secureDirectories.isEmpty)
        var unresolved = ordinary
        var records = unresolved["records"] as! Object
        records["coverage_records"] = [["record_id": "c:1", "domain": "ssh-configuration", "item_id": "identity-references", "disposition": "unresolved", "source_status": "unobserved"]]
        records["diagnostics"] = [["record_id": "c:1", "code": "prerequisite_unmet", "severity": "warning", "phase": "observation"]]
        unresolved["records"] = records
        var summary = unresolved["comparison"] as! Object, counts = summary["counts"] as! [String:Int]
        counts["unresolved"] = 1; summary["counts"] = counts; summary["verdict"] = "incomplete"; summary["also_incomplete"] = true; unresolved["comparison"] = summary
        let diagnostic = try presentation(unresolved)
        precondition(diagnostic.categories.flatMap(\.items).contains { $0.title == "SSH key references" && $0.action.contains("not establish") })
        let mapping: Object = ["version": 2, "bundle_id": bundleID, "items": [["identity_id": identityID, "directory": NSNull(), "selected": true]]]
        var context: Object = ["mapping": mapping, "target_state": String(repeating: "d", count: 64), "source_validation": "saved_files",
            "ssh_reference_coverage": "resolved", "observed_at": "2026-11-09T10:00:00.000001+00:00", "read_only": true,
            "publication_occurred": false, "target_mutation_may_have_started": false]
        var secure: Object = ["version": 1, "operation_id": "fixture-check", "bundle_id": bundleID, "context": context,
            "items": [["identity_id": identityID, "comparison_kind": "matching", "reason": "pair_identical", "target_state": String(repeating: "d", count: 64), "private_bytes_match": true, "public_bytes_match": true]]]
        func reconcile(_ raw: Object) throws -> EnvironmentStatusPresentation {
            try EnvironmentStatusPresentation(JSONDecoder().decode(CoreComparisonResult.self, from: data(raw)),
                secureCheck: JSONDecoder().decode(CoreSecureCheckResult.self, from: data(secure)))
        }
        let proven = try reconcile(unresolved)
        precondition(proven.counts["unresolved"] == 0 && proven.counts["matching"] == 2 && !proven.needsAttention)
        precondition(!proven.categories.flatMap(\.items).contains { $0.title == "SSH key references" })
        context["ssh_reference_coverage"] = "unresolved"; secure["context"] = context
        let unproven = try reconcile(unresolved)
        precondition(unproven.needsAttention && !unproven.secureRequiresRetry)
        precondition(unproven.counts["unresolved"] == 1 && unproven.counts["matching"] == 2)
        let reference = unproven.categories.first { $0.id == "ssh-configuration" }!.items.first { $0.title == "SSH key references" }!
        precondition(reference.action.contains("Saved SSH key files match") && reference.action.contains("does not prove"))
        precondition(!reference.action.contains("A required inspection prerequisite"), "Do not append the same generic warning")
        precondition(reference.reason?.contains("prerequisite_unmet") == true, "Diagnostic evidence remains available")
        precondition(unproven.categories.first { $0.id == "ssh-configuration" }!.items.filter { $0.status == .matching }.map(\.title) == ["config"], "Aggregate verification never manufactures per-Host Matches")
        // Mirrors the reported shape: one configuration predicate, one unresolved
        // dependency, three matching saved-file pairs. No claim of private-key usability.
        let priorSecure = secure
        let threeIDs = [identityID, String(repeating: "c", count: 64), String(repeating: "e", count: 64)]
        var threeContext = context
        threeContext["mapping"] = ["version": 2, "bundle_id": bundleID, "items": threeIDs.map { ["identity_id": $0, "directory": NSNull(), "selected": true] as Object }]
        secure["context"] = threeContext
        let item = (secure["items"] as! [Object])[0]
        secure["items"] = threeIDs.map { id -> Object in var row = item; row["identity_id"] = id; return row }
        let threeMatching = try reconcile(unresolved)
        precondition(threeMatching.counts["matching"] == 4 && threeMatching.counts["unresolved"] == 1 && threeMatching.needsAttention && !threeMatching.secureRequiresRetry)
        try secureRender(EnvironmentComparisonView(result: threeMatching, categoryExpansion: .constant([])), name: "ssh-independent-collapsed")
        try secureRender(EnvironmentComparisonView(result: threeMatching, categoryExpansion: .constant(EnvironmentComparisonView.disclosureIDs(threeMatching))), name: "ssh-independent-expanded", height: 1200)
        threeContext["ssh_reference_coverage"] = "resolved"; secure["context"] = threeContext
        let threeProven = try reconcile(unresolved)
        precondition(threeProven.counts["matching"] == 4 && threeProven.counts["unresolved"] == 0 && !threeProven.needsAttention)
        precondition(threeProven.categories.first { $0.id == "ssh-configuration" }!.items.map(\.title) == ["config"], "Resolved reference coverage adds no matching records or Host rows")
        var legacy = unresolved, legacyRecords = records
        legacyRecords["coverage_records"] = (records["coverage_records"] as! [Object]) + [
            ["record_id": "c:legacy", "domain": "ssh-configuration", "item_id": "scope", "disposition": "unresolved", "source_status": "partial"]]
        legacyRecords["diagnostics"] = (records["diagnostics"] as! [Object]) + [
            ["record_id": "c:legacy", "code": "partial_source_coverage", "severity": "warning", "phase": "scope"]]
        legacy["records"] = legacyRecords
        var legacySummary = summary, legacyCounts = counts
        legacyCounts["unresolved"] = 2; legacySummary["counts"] = legacyCounts; legacy["comparison"] = legacySummary
        let legacyProven = try reconcile(legacy)
        precondition(legacyProven.counts["matching"] == 4 && legacyProven.counts["unresolved"] == 1 && legacyProven.needsAttention)
        precondition(legacyProven.categories.flatMap(\.items).contains { $0.title == "SSH configuration coverage" && $0.status == .attention })
        secure = priorSecure
        context["ssh_reference_coverage"] = "resolved"; secure["context"] = context
        records["diagnostics"] = (records["diagnostics"] as! [Object]) + [["record_id": "c:1", "code": "partial_source_coverage", "severity": "warning", "phase": "input"]]
        unresolved["records"] = records
        let partial = try reconcile(unresolved)
        precondition(partial.needsAttention, "Correlation must preserve unrelated diagnostic evidence")
        // Fresh ordinary/protected results must replace, never accumulate Host counts.
        func hostFixture(_ states: [String]) -> Object {
            let kind = states.contains("differing") ? "differing" : states.contains("missing") ? "missing" : "matching"
            var value = ordinary, records = ordinary["records"] as! Object
            var fact = rows[0]; fact["comparison_kind"] = kind
            value["comparison_records"] = [fact]
            records["verification_records"] = [["record_id": "v:0", "domain": "ssh-configuration", "item_id": "config", "predicate": "supported_config_match"]]
            value["records"] = records
            var summary = ordinary["comparison"] as! Object, counts = summary["counts"] as! [String: Int]
            counts["matching"] = 0; counts[kind] = 1; summary["counts"] = counts
            summary["verdict"] = kind == "matching" ? "no_differences_detected" : "differences_detected"; value["comparison"] = summary
            value["reference_presentation"] = ["groups": [], "app_store_names": [:], "ssh_hosts": [
                "version": 1, "snapshot_id": bundleID, "observation_id": bundleID, "comparison_record_id": "v:0",
                "hosts": states.enumerated().map { index, state in ["item_id": CoreSSHHosts.identity("host-\(index)"), "label": "host-\(index)",
                    "state": state, "reason": state == "differing" ? "target_conflict" : NSNull()] as Object }]]
            return value
        }
        func hostCounts(match: Int, missing: Int = 0, different: Int = 0) {
            let result = model.presentation!
            let ssh = result.sections.flatMap(\.entries).first { $0.id == CaptureHierarchy.sshID }!
            precondition(result.counts["matching"] == match && result.counts["missing"] == missing && result.counts["differing"] == different)
            precondition(result.categoryCount(.match, category: ssh.category, children: ssh.children) == match)
            precondition(result.categoryCount(.missing, category: ssh.category, children: ssh.children) == missing)
            precondition(result.categoryCount(.different, category: ssh.category, children: ssh.children) == different)
        }
        try write("matching", core.appendingPathComponent("mode"))
        runtime.start(CoreRequest(.capabilities), location: location); await runtime.waitForCompletion()
        try data(hostFixture(["matching", "matching", "matching"])).write(to: core.appendingPathComponent("ordinary.json"))
        model.selectBundle(bundle); model.compare(); try await finish()
        hostCounts(match: 5) // Three Hosts plus two independently checked keys.
        try write("mixed", core.appendingPathComponent("mode"))
        model.checkSSHKeys(); try await finish()
        hostCounts(match: 4, missing: 1)
        let previousCheckID = model.operationID
        try data(hostFixture(["matching", "missing", "differing"])).write(to: core.appendingPathComponent("ordinary.json"))
        try write("matching", core.appendingPathComponent("mode"))
        model.compare(); precondition(model.presentation == nil); try await finish()
        precondition(model.operationID != previousCheckID)
        hostCounts(match: 3, missing: 1, different: 1)
        let otherBundle = directory.appendingPathComponent("Other.mbt"); try write("other fixture", otherBundle)
        try data(ordinary).write(to: core.appendingPathComponent("ordinary.json"))
        model.selectBundle(otherBundle)
        precondition(model.presentation == nil && model.secureInventory == nil && model.selectedSecureIDs.isEmpty)
        model.compare(); try await finish()
        hostCounts(match: 3) // Legacy config plus two keys; no previous Host evidence.
        precondition(model.presentation!.categories.first { $0.id == "ssh-configuration" }!.items.map(\.title) == ["config"])
        print("PASS: Host counts refresh after protected Check, scoped retry, Check Again and Saved Environment changes without accumulation")
        print("PASS: unified Check, one-use authentication, automatic all-key scope, scoped retry, truthful partial coverage, private decoding and light/dark production Views")
    }

    @MainActor static func main() async throws {
        try legacySSHCoverageChecks()
        try await secureCheckTests()
        if CommandLine.arguments.contains("--secure-check-only") { return }
        try groupedPresentationChecks()
        if CommandLine.arguments.contains("--status-grouping-only") { _ = try finalConsistencyChecks(); return }
        try topologyChecks()
        if CommandLine.arguments.contains("--concise-messages-only") { try conciseMessageChecks(); return }
        let finalVisual = try finalConsistencyChecks()
        let renderRuntime = CoreRuntime()
        let renderModel = EnvironmentStatusModel(runtime: renderRuntime)
        for (label, width) in [("narrow", 1000), ("wide", 1600)] {
            try render(TaskHome(select: { _ in }), name: "AllTasksUIv2-" + label, width: width)
            try render(VStack(alignment: .leading, spacing: 20) {
                WorkspaceHeader(title: ProductTask.status.title, subtitle: ProductTask.status.subtitle, symbol: ProductTask.status.symbol)
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
        let developer = precise.sections.first { $0.id == "For Experienced Users" }!
        let workspaceGroup = developer.entries.first { $0.id == DeveloperSelectionGroup.workspace.id }!
        precondition(workspaceGroup.children.map(\.id) == ["workspace-folders"])
        let repositories = developer.entries.first { $0.id == DeveloperSelectionGroup.git.id }!.children.first { $0.id == "git-repositories" }!
        precondition(precise.categoryCount(.match, category: repositories) == 1 && precise.categoryCount(.missing, category: repositories) == 1)
        let sshGroup = developer.entries.first { $0.id == DeveloperSelectionGroup.ssh.id }!
        precondition(precise.categoryCount(.needsAttention, category: sshGroup.category, children: sshGroup.children) == 1)
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
        precondition(ssh.sections.map(\.id) == ["For Experienced Users"])
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
        precondition(macOS.sections[0].id == "Standard Setup")
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

        let mainIDs = EnvironmentComparisonView.disclosureIDs(macOS)
        let initiallyExpanded = Set<String>()
        let allExpanded = EnvironmentComparisonView.toggledCategories(initiallyExpanded, ids: mainIDs)
        precondition(allExpanded == mainIDs && allExpanded.contains("macos-dock") && allExpanded.contains("macos-finder"))
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
        let domainIDs = ["shell-zsh", "workspace-folders", "git-repositories", "ssh-configuration", "git-configuration", "vscode-settings", "macos-dock", "vscode-extensions", "homebrew-packages", "app-store", "homebrew-casks"]
        let ordered = EnvironmentStatusSection.project(domainIDs.map { DisplayCategory(id: $0, title: $0, symbol: "folder", items: [DisplayItem(id: $0 + ":fixture", title: "Fixture", status: .matching, action: "", reason: nil)]) })
        precondition(ordered.map(\.id) == ["Standard Setup", "For Experienced Users"])
        precondition(ordered[0].entries.map(\.id) == ["app-store", "homebrew-casks", "homebrew-packages", "macos-settings", CaptureHierarchy.Group.vscode.id])
        precondition(ordered[1].entries[0].children.map(\.id) == ["git-configuration", "git-repositories"])
        precondition(ordered[1].entries[1].children.map(\.id) == ["workspace-folders"])
        let presentedIDs = ordered.flatMap(\.entries).flatMap { [$0.id] + $0.children.map(\.id) }
        precondition(Set(presentedIDs).count == presentedIDs.count)
        let workspaceIDs = Set(ordered[1].entries[1].children.map(\.id) + [DeveloperSelectionGroup.workspace.id])
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
