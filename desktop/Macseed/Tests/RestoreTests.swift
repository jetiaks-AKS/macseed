import Foundation
import AppKit
import SwiftUI

@main struct RestoreTests {
    static var finalUXFixtures: Bool {
        CommandLine.arguments.contains("--final-restore-ux-only") || CommandLine.arguments.contains("--selection-preview-only") || CommandLine.arguments.contains("--preview-appstore-layout-only")
    }
    static func write(_ value: String, _ path: URL) throws { try value.write(to: path, atomically: false, encoding: .utf8) }
    @MainActor static func render(_ model: RestoreModel, _ runtime: CoreRuntime, state: String, expanded: Bool = false, settingsOnly: Bool = false) throws {
        guard !CommandLine.arguments.contains("--no-renders") else { return }
        _ = NSApplication.shared
        NSApp.appearance = NSAppearance(named: .aqua)
        for width in (Self.finalUXFixtures ? [420, 785, 985] : [785, 985]) {
            let selection = model.selection
            let preparedID = model.preparation?.preparedPlanID
            let workspace = VStack(alignment: .leading, spacing: 20) {
                WorkspaceHeader(title: ProductTask.restore.rawValue, subtitle: ProductTask.restore.subtitle, symbol: ProductTask.restore.symbol)
                if settingsOnly, let group = model.groups.first(where: { $0.id == "macOS Settings" }) {
                    RestoreMacOSSelectionView(model: model, group: group, expansion: .constant(true), childExpansion: .constant(true))
                        .modifier(WorkspaceCardSurface())
                } else {
                    RestoreView(model: model, runtime: runtime, categoryExpansion: expanded ? .constant(true) : nil,
                        showsPreviewActions: false, showsSelectionActions: false, showsResultActions: false)
                }
            }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
            let footer = Group {
                if model.showingAppStore {
                    AppStoreRestoreActions(model: model).modifier(WorkspaceFooterPadding())
                } else if model.state == .result, let result = model.executionResult {
                    RestoreResultActions(result: result, refresh: {}, done: {}, logRuntime: runtime)
                        .modifier(WorkspaceFooterPadding())
                } else if model.state == .review {
                    RestoreSelectionActions(status: model.selectionSummary, canPreview: model.canPreview, preview: {})
                        .modifier(WorkspaceFooterPadding())
                } else {
                    RestorePreviewActions(back: {}, refresh: {}, rebuild: {}, canRebuild: model.canRebuild, showsRebuild: model.hasAutomaticSelection)
                        .modifier(WorkspaceFooterPadding())
                }
            }
            let content = VStack(spacing: 0) {
                ScrollView { workspace }
                Divider()
                footer
            }.frame(width: CGFloat(width), height: 850).background(Color(nsColor: .windowBackgroundColor))
            if state.hasPrefix("layout-") || state == "final-selection" {
                let fullContent = VStack(spacing: 0) { workspace; Divider(); footer }
                    .frame(width: CGFloat(width)).background(Color(nsColor: .windowBackgroundColor))
                let fullHost = NSHostingView(rootView: fullContent)
                let fullHeight = fullHost.fittingSize.height
                let fullWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: CGFloat(width), height: fullHeight),
                    styleMask: [.borderless], backing: .buffered, defer: false)
                fullWindow.isReleasedWhenClosed = false; fullWindow.contentView = fullHost
                fullHost.frame = fullWindow.contentView!.bounds
                fullHost.layoutSubtreeIfNeeded(); fullHost.displayIfNeeded()
                let bitmap = fullHost.bitmapImageRepForCachingDisplay(in: fullHost.bounds)!
                fullHost.cacheDisplay(in: fullHost.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/Debug/RestoreUnified-\(state)-full-\(width).png"))
                fullWindow.close()
            }
            let host = NSHostingView(rootView: content)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 850), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host
            host.frame = window.contentView!.bounds
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            precondition(bitmap.pixelsWide == Int(CGFloat(width) * window.backingScaleFactor))
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/Debug/RestoreUnified-\(state)\(expanded ? "-expanded" : "")-\(width).png"))
            precondition(model.selection == selection && model.preparation?.preparedPlanID == preparedID)
            if CommandLine.arguments.contains("--preview-appstore-layout-only"), state.hasPrefix("layout-") {
                func findScroll(_ view: NSView) -> NSScrollView? {
                    if let scroll = view as? NSScrollView { return scroll }
                    return view.subviews.lazy.compactMap { findScroll($0) }.first
                }
                guard let scroll = findScroll(host), let document = scroll.documentView else {
                    preconditionFailure("Expected the production ScrollView")
                }
                precondition(document.bounds.height > scroll.documentVisibleRect.height, "Fixture must exercise scrolling")
                let original = scroll.documentVisibleRect.minY
                scroll.contentView.scroll(to: NSPoint(x: 0, y: document.bounds.maxY - scroll.documentVisibleRect.height))
                scroll.reflectScrolledClipView(scroll.contentView)
                host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
                precondition(scroll.documentVisibleRect.minY > original, "Inventory must scroll independently of the footer")
                let bottom = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                host.cacheDisplay(in: host.bounds, to: bottom)
                try bottom.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/Debug/RestoreUnified-\(state)-bottom-\(width).png"))
            }
            window.close()
        }
    }
    @MainActor static func taskPresentationChecks() throws {
        let casks = ["firefox", "iina", "keka"] + (4...16).map { "cask-\($0)" }
        let packages = ["firefox"] + (2...21).map { "formula-\($0)" }
        let domains = ["homebrew-casks", "homebrew-packages"]
        let titles = ["Homebrew Applications", "Homebrew Packages"]
        let names = [casks, packages]
        let catalog = CoreRestoreInspection.Inventory(
            groups: [.init(id: "Homebrew", domains: domains)],
            inventory: domains.enumerated().map { index, domain in
                .init(domain: domain, label: titles[index], selectionMode: "items", availability: "available", reason: nil,
                      items: names[index].map { .init(itemID: $0, label: $0) })
            })
        var rows: [[String: Any]] = domains.enumerated().flatMap { index, domain in
            names[index].map { ["domain": domain, "item_id": $0, "display_name": $0,
                               "action": "install", "disposition": "planned"] }
        }
        rows[0]["action"] = "reinstall"
        rows[1]["authorization_required"] = true
        let raw: [String: Any] = ["prepared_plan_id": String(repeating: "a", count: 64),
            "selection": ["categories": [], "items": Dictionary(uniqueKeysWithValues: zip(domains, names))],
            "selected_groups": ["Homebrew"], "selected_categories": [],
            "selected_item_counts": [domains[0]: 16, domains[1]: 21],
            "include_secure": false, "secure_restore_status": "not_selected", "plan": rows,
            "readiness": ["ready": true, "ready_scope": "environment", "conditions": [], "reentry": "restore_prepare"],
            "has_planned_changes": true, "warning_count": 0, "error_count": 0]
        let plan = try JSONDecoder().decode(CoreRestorePreparation.self, from: JSONSerialization.data(withJSONObject: raw))
        let preview = RestorePreviewPresentation(plan, catalog: catalog)
        precondition(plan.plan[1].authorizationRequired == true)
        precondition(preview.categories[0].items[1].action.contains("Administrator authorization required"))
        func event(_ type: String, _ domain: String, _ item: String, _ key: String, _ value: String, action: String = "install") throws -> CoreEvent {
            try CoreEvent(line: JSONSerialization.data(withJSONObject: ["protocol_version": 1, "operation_id": "presentation",
                "sequence": 1, "type": type, "data": ["domain": domain, "item_id": item, "action": action, key: value]]))
        }
        // Operation progress never infers execution from conformity or a phase change.
        let finished = try event("operation_record", domains[0], "firefox", "outcome", "success", action: "reinstall")
        let activeEvent = try event("execution_event", domains[1], "firefox", "state", "applying")
        let verifiedOnly = try event("verification_record", domains[0], "iina", "conformity", "verified")
        let phase = try event("execution_event", "verification", "scope", "state", "started")
        let failure = try event("operation_record", domains[0], "keka", "outcome", "failure")
        func operationTasks(_ events: [CoreEvent]) -> RestoreTaskPresentation {
            RestoreTaskPresentation(preview: preview, plan: plan, events: events, executing: true, operationProgress: true)
        }
        var multiActionRaw = raw
        var secondAction = rows[0]
        secondAction["action"] = "install"
        multiActionRaw["plan"] = [rows[0], secondAction]
        let multiPlan = try JSONDecoder().decode(CoreRestorePreparation.self, from: JSONSerialization.data(withJSONObject: multiActionRaw))
        let multiPreview = RestorePreviewPresentation(multiPlan, catalog: catalog)
        let multiTasks = RestoreTaskPresentation(preview: multiPreview, plan: multiPlan, events: [finished], executing: true, operationProgress: true)
        let multiItems = multiTasks.domains.flatMap(\.items)
        precondition(multiItems[0].resultLabels.contains("Applied") && !multiItems[1].resultLabels.contains("Applied"))
        let verifiedRepair = try event("verification_record", domains[0], "firefox", "conformity", "verified")
        let verifiedTasks = operationTasks([finished, verifiedRepair])
        let verifiedRow = verifiedTasks.domains.flatMap(\.items).first { $0.id == "restore-0" }!
        precondition(verifiedRow.resultLabels == ["Applied", "Verified"] && verifiedRow.resultTitle == "Verified")
        precondition(verifiedRow.resultBreakdown == "verified")
        precondition(operationTasks([finished]).domains.flatMap(\.items).first { $0.id == "restore-0" }!.resultBreakdown == "applied, not verified")
        let multiVerified = RestoreTaskPresentation(preview: multiPreview, plan: multiPlan, events: [finished, verifiedRepair], executing: true, operationProgress: true)
        precondition(multiVerified.domains.flatMap(\.items).allSatisfy { $0.resultLabels.contains("Verified") })
        precondition(!multiVerified.domains.flatMap(\.items)[1].resultLabels.contains("Applied"))
        precondition(RestoreResultSummary(domains: multiVerified.domains).cards.first?.count == 2)
        let emptyProgress = operationTasks([])
        precondition(emptyProgress.domains.count == 2 && emptyProgress.domains.flatMap(\.items).count == 37)
        precondition(RestoreOperationSummary(domains: emptyProgress.domains).completed == 0)
        let unrelatedAction = try event("operation_record", domains[0], "firefox", "outcome", "success", action: "inspect")
        precondition(RestoreOperationSummary(domains: operationTasks([unrelatedAction]).domains).completed == 0)
        let projected = operationTasks([finished, activeEvent, failure])
        let counts = RestoreOperationSummary(domains: projected.domains)
        precondition(counts.completed == 1 && counts.working == 1 && counts.attention == 1)
        for problem in ["failed", "blocked", "conflict"] {
            let changed = try event("execution_event", domains[0], "firefox", "state", "changed", action: "reinstall")
            let trouble = try event("execution_event", domains[0], "firefox", "state", problem, action: "reinstall")
            let tasks = operationTasks([changed, trouble])
            let item = tasks.domains.flatMap(\.items).first { $0.id == "restore-0" }!
            precondition(item.resultLabels.contains("Applied"))
            precondition(RestoreFinalDomain.group(item) == "Needs Attention")
            precondition(RestoreFinalDomain.finalStatus(tasks.domains[0]) == .attention)
            precondition(RestoreFinalDomain.showsItemDetails(item))
            precondition(item.resultTechnicalDetails!.contains("state: " + problem))
            precondition(RestoreFinalDomain.visibleLabels(item) == [problem == "failed" ? "Failed" : "Needs Attention"])
        }
        let skippedItem = TaskItemPresentation(id: "skip", item: DisplayItem(id: "skip", title: "Dependent item",
            status: .attention, action: "Skipped", reason: "dependency_failed"), state: .skipped)
        precondition(RestoreOperationSummary(domains: [.init(id: "skip", title: "Skipped", symbol: "app", items: [skippedItem])]).attention == 1)
        let checking = operationTasks([finished, activeEvent, verifiedOnly, phase])
        precondition(RestoreOperationSummary(domains: checking.domains).completed == 1)
        let itemResults = checking.domains.flatMap(\.items)
        precondition(itemResults.first { $0.id == "restore-0" }!.resultLabels == ["Applied"])
        precondition(itemResults.first { $0.id == "restore-1" }!.resultLabels == ["Verified"])
        precondition(emptyProgress.domains.flatMap(\.items).allSatisfy { $0.resultLabels == ["Unverified"] })
        precondition(operationTasks([unrelatedAction]).domains.flatMap(\.items).allSatisfy { !$0.resultLabels.contains("Applied") })
        precondition(checking.domains.flatMap(\.items).first { $0.id == "restore-1" }!.state == .unverified)
        precondition(RestoreOperationSummary(domains: checking.domains).working == 0)
        var twoRaw = raw
        twoRaw["plan"] = [rows[0], rows[16]]
        let twoPlan = try JSONDecoder().decode(CoreRestorePreparation.self, from: JSONSerialization.data(withJSONObject: twoRaw))
        let twoPreview = RestorePreviewPresentation(twoPlan, catalog: catalog)
        var matchingRaw = twoRaw
        var matchingRows = [rows[0], rows[16]]
        matchingRows[1]["disposition"] = "satisfied"
        matchingRaw["plan"] = matchingRows
        let matchingPlan = try JSONDecoder().decode(CoreRestorePreparation.self, from: JSONSerialization.data(withJSONObject: matchingRaw))
        let matchingPreview = RestorePreviewPresentation(matchingPlan, catalog: catalog)
        func live(_ events: [CoreEvent]) -> RestoreTaskPresentation {
            RestoreTaskPresentation(preview: matchingPreview, plan: matchingPlan, events: events, executing: true, operationProgress: true)
        }
        let starting = live([])
        precondition(starting.domains.allSatisfy { ![.completed, .matching].contains($0.executionStatus) })
        precondition(starting.domains[0].executionStatus == .waiting && starting.domains[1].executionStatus == .awaitingVerification)
        precondition(live([finished]).domains[0].executionStatus == .awaitingVerification)
        let verifiedCask = try event("verification_record", domains[0], "firefox", "conformity", "verified")
        let verifiedPackage = try event("verification_record", domains[1], "firefox", "conformity", "verified")
        precondition(live([finished, verifiedCask]).domains[0].executionStatus == .completed)
        precondition(live([finished, verifiedCask]).domains[1].executionStatus == .awaitingVerification)
        precondition(live([finished, verifiedCask, phase]).domains[0].executionStatus == .completed)
        precondition(live([finished, verifiedCask, verifiedPackage, phase]).domains[1].executionStatus == .matching)
        let mismatch = try event("verification_record", domains[0], "firefox", "conformity", "mismatch")
        let withMismatch = live([finished, verifiedCask, verifiedPackage, phase, mismatch])
        precondition(withMismatch.domains[0].executionStatus == .attention && withMismatch.domains[1].executionStatus == .matching)
        precondition(live([mismatch, activeEvent]).domains[0].executionStatus == .attention)

        let two = RestoreTaskPresentation(preview: twoPreview, plan: twoPlan, executing: true, operationProgress: true)
        precondition(two.domains.count == 2 && two.domains.flatMap(\.items).count == 2)
        var manyRaw = raw
        manyRaw["plan"] = (0..<120).map { index in
            ["domain": domains[index % 2], "item_id": "item-\(index)", "display_name": "Item \(index)",
             "action": "install", "disposition": "planned"]
        }
        let manyPlan = try JSONDecoder().decode(CoreRestorePreparation.self, from: JSONSerialization.data(withJSONObject: manyRaw))
        let manyPreview = RestorePreviewPresentation(manyPlan, catalog: catalog)
        let many = RestoreTaskPresentation(preview: manyPreview, plan: manyPlan, executing: true, operationProgress: true)
        precondition(many.domains.count == 2 && many.domains.flatMap(\.items).count == 120)
        precondition(RestoreOperationSummary(domains: many.domains).completed == 0)
        let macDomains = ["macos-dock", "macos-screenshots"]
        let macCatalog = CoreRestoreInspection.Inventory(groups: [.init(id: "macOS Settings", domains: macDomains)],
            inventory: macDomains.map { .init(domain: $0, label: $0, selectionMode: "category", availability: "available", reason: nil, items: []) })
        var macRaw = raw
        macRaw["plan"] = [
            ["domain": macDomains[0], "item_id": "com.apple.dock/tilesize", "action": "set_preference", "disposition": "planned"],
            ["domain": macDomains[1], "item_id": "com.apple.screencapture/location", "action": "set_preference", "disposition": "planned"],
            ["domain": macDomains[1], "item_id": "SystemUIServer", "action": "restart_process", "disposition": "planned"]]
        let macPlan = try JSONDecoder().decode(CoreRestorePreparation.self, from: JSONSerialization.data(withJSONObject: macRaw))
        let macPreview = RestorePreviewPresentation(macPlan, catalog: macCatalog)
        let preferenceEvidence: [[String: CoreJSON]] = macPlan.plan.filter { $0.action != "restart_process" }.map {
            ["domain": .string($0.domain), "item_id": .string($0.itemID), "predicate": .string("stored_preference"), "conformity": .string("verified")]
        }
        precondition(RestoreTaskPresentation.hasVerifiedRequirements(entries: macPlan.plan, observations: preferenceEvidence, operations: []))
        precondition(!RestoreTaskPresentation.hasVerifiedRequirements(entries: macPlan.plan, observations: Array(preferenceEvidence.prefix(1)), operations: []))
        var wrongPredicate = preferenceEvidence
        wrongPredicate[1]["predicate"] = .string("other")
        precondition(!RestoreTaskPresentation.hasVerifiedRequirements(entries: macPlan.plan, observations: wrongPredicate, operations: []))

        func macTasks(_ evidence: [CoreEvent]) -> RestoreTaskPresentation {
            RestoreTaskPresentation(preview: macPreview, plan: macPlan, events: evidence, executing: true, operationProgress: true)
        }
        let macVerified = try event("verification_record", macDomains[1], "com.apple.screencapture/location", "conformity", "verified", action: "set_preference")
        let missing = macTasks([macVerified, phase])
        precondition(missing.domains.flatMap(\.items).count == 3)
        let restart = missing.domains.flatMap(\.items).first { $0.id == "restore-2" }!
        precondition(restart.auxiliaryCompletionUnreported)
        precondition(RestoreFinalDomain.group(restart) == nil)
        precondition(RestoreFinalDomain.visibleLabels(restart) == ["Completion Not Reported"])
        precondition(!RestoreFinalDomain.showsItemDetails(restart))
        precondition(!restart.resultLabels.contains("Applied") && !restart.resultLabels.contains("Verified"))

        precondition(missing.domains.allSatisfy { $0.state == .unverified })
        precondition(RestoreOperationSummary(domains: missing.domains).completed == 0)
        precondition(RestoreOperationSummary(domains: missing.domains).attention == 0)
        let macReceipt = try event("operation_record", macDomains[0], "com.apple.dock/tilesize", "outcome", "success", action: "set_preference")
        precondition(RestoreOperationSummary(domains: macTasks([macReceipt]).domains).completed == 1)
        let macWrongAction = try event("operation_record", macDomains[0], "com.apple.dock/tilesize", "outcome", "success", action: "verify")
        precondition(RestoreOperationSummary(domains: macTasks([macWrongAction]).domains).completed == 0)
        precondition(emptyProgress.domains.allSatisfy { $0.executionStatus == .waiting })
        precondition(missing.domains.allSatisfy { $0.executionStatus == .awaitingVerification && $0.executionMessages.isEmpty })
        precondition(projected.domains[0].executionStatus == .attention)
        precondition(projected.domains[1].executionStatus == .working)
        let warning = try event("operation_record", domains[0], "firefox", "outcome", "warning", action: "reinstall")
        precondition(operationTasks([warning]).domains[0].executionStatus == .attention)
        precondition(operationTasks([warning, warning]).domains[0].executionMessages.count == 1)
        let matchingDomain = TaskDomainPresentation(id: "matching", title: "Matching", symbol: "app", items: [
            .init(id: "match", item: preview.categories[0].items[0], state: .matching)])
        precondition(matchingDomain.executionStatus == .awaitingVerification)
        let neutralSkip = TaskDomainPresentation(id: "skip", title: "Skip", symbol: "app", items: [
            .init(id: "skip", item: DisplayItem(id: "skip", title: "Skip", status: .waiting, action: "", reason: "not_applicable"), state: .skipped)])
        precondition(neutralSkip.executionStatus == .waiting && neutralSkip.executionMessages.isEmpty)
        let cancelled = try event("execution_event", domains[0], "firefox", "state", "cancelled")
        precondition(operationTasks([cancelled]).domains[0].executionStatus == .waiting)
        precondition(operationTasks([cancelled]).domains[0].executionMessages.isEmpty)
        let summary = RestoreVerificationSummary(payload: ["verification": .object([
            "status": .string("complete"), "verified_count": .integer(127), "mismatch_count": .integer(0),
            "unverified_count": .integer(0), "unresolved_count": .integer(0)])])
        precondition(summary.verified == 127 && summary.mismatch == 0 && counts.completed == 1)
        precondition(RestoreVerificationSummary(payload: nil).verified == nil)
        precondition(summary.complete && summary.title == "Verification Complete")
        precondition(RestoreVerificationSummary(payload: nil).title == "Verification Not Reported")
        for status in ["not_run", "incomplete", "failed", "complete"] {
            let incomplete = RestoreVerificationSummary(payload: ["verification": .object(["status": .string(status), "verified_count": .integer(3)])])
            precondition(!incomplete.complete && incomplete.mismatch == nil && incomplete.unverified == nil && incomplete.unresolved == nil)
        }
        let activeRows = RestoreProgressRow.freeze(preview: preview, plan: plan)
        func activity(_ events: [CoreEvent]) -> String {
            RestoreProgressRow.activity(events: events, rows: activeRows, mutationPossible: true)
        }
        let firstActivity = try event("execution_event", domains[0], "firefox", "state", "applying", action: "reinstall")
        let nextActivity = try event("execution_event", domains[1], "firefox", "state", "applying")
        precondition(activity([]) == "Restoring environment…")
        precondition(activity([firstActivity]) == "Repairing firefox…")
        precondition(activity([firstActivity, nextActivity]) == "Installing firefox…")
        precondition(activity([firstActivity, finished]) == "Restoring environment…")
        precondition(activity([firstActivity, failure]) == "Repairing firefox…") // unrelated receipt
        precondition(activity([firstActivity, phase]) == "Verifying restored environment…")
        precondition(activity([firstActivity, cancelled]) == "Restoring environment…")
        let unknownActivity = try event("execution_event", domains[0], "opaque:unknown", "state", "applying")
        precondition(activity([firstActivity, unknownActivity]) == "Homebrew Applications…")
        let startedCategory = try event("execution_event", domains[1], "scope", "state", "started")
        precondition(activity([firstActivity, startedCategory]) == "Homebrew Packages…")
        for type in ["phase_started", "phase_completed", "completed", "failed", "cancelled"] {
            let boundary = try CoreEvent(line: JSONSerialization.data(withJSONObject: ["protocol_version": 1, "operation_id": "presentation", "sequence": 2,
                "type": type, "data": ["phase": "bootstrap"]]))
            precondition(activity([firstActivity, boundary]) == "Restoring environment…")
        }
        func resultSummary(_ counts: [String: CoreJSON]) -> RestoreVerificationSummary {
            RestoreVerificationSummary(payload: ["verification": .object(counts)])
        }
        let cleanCounts: [String: CoreJSON] = ["status": .string("complete"), "verified_count": .integer(129),
            "mismatch_count": .integer(0), "unverified_count": .integer(0), "unresolved_count": .integer(0)]
        let cleanSummary = resultSummary(cleanCounts)
        precondition(cleanSummary.overallResult(outcome: .clean) == "OK" && cleanSummary.verified == 129)
        for (outcome, expected) in [(RestoreExecutionPresentation.Outcome.failedBeforeMutation, "Failed"), (.failedAfterMutation, "Failed"),
            (.stoppedBeforeMutation, "Stopped"), (.stoppedAfterMutation, "Stopped"), (.interrupted, "Interrupted"), (.partial, "Needs Attention"), (.attention, "Needs Attention")] {
            precondition(cleanSummary.overallResult(outcome: outcome) == expected)
            if ["Failed", "Stopped", "Interrupted"].contains(expected) {
                precondition(resultSummary([:]).overallResult(outcome: outcome) == expected)
            }
        }
        precondition(resultSummary([:]).overallResult(outcome: .clean) == "Incomplete")
        for key in ["mismatch_count", "unverified_count", "unresolved_count"] {
            var counts = cleanCounts; counts[key] = .integer(1)
            precondition(resultSummary(counts).overallResult(outcome: .clean) == "Needs Attention")
            counts.removeValue(forKey: key)
            precondition(resultSummary(counts).overallResult(outcome: .attention) == "Incomplete")
        }
        var events: [CoreEvent] = []
        func project() -> RestoreTaskPresentation {
            RestoreTaskPresentation(preview: preview, plan: plan, events: events, executing: true)
        }
        func stable(_ tasks: RestoreTaskPresentation) {
            precondition(tasks.domains.map(\.id) == domains)
            precondition(tasks.domains.map(\.title) == titles)
            precondition(tasks.domains.map { $0.items.count } == [16, 21])
            precondition(tasks.counters.reduce(0) { $0 + $1.count } == 2)
        }
        func state(_ item: String, domain: String = "homebrew-casks") -> TaskRowState {
            project().domains.first { $0.id == domain }!.items.first { $0.item.title == item }!.state
        }
        stable(RestoreTaskPresentation(preview: preview, plan: plan))
        let repairItem = preview.categories.first { $0.id == domains[0] }!.items[0]
        precondition(repairItem.action == "Will Repair" && repairItem.restoreReadyText == "Ready to Repair")
        let repairProgress = RestoreProgressRow.freeze(preview: preview, plan: plan).first { $0.id == domains[0] }!
        let repairEvent = try event("execution_event", domains[0], "firefox", "state", "applying", action: "reinstall")
        precondition(repairProgress.project(events: [repairEvent]).restoreActivity == "Repairing firefox…")
        let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
        let view = try String(contentsOf: sourceRoot.appendingPathComponent("RestoreView.swift"), encoding: .utf8)
        precondition(!view.contains("DisclosureGroup(\"Technical Details\")") && !view.contains("DisclosureGroup(\"View Details\")"))
        precondition(view.contains("Macseed will apply the changes shown in this Preview. Items that already match will not be changed."))
        precondition(view.contains("Some changes may require administrator authorization."))
        precondition(!view.contains("Some Homebrew casks require administrator authorization") && !view.contains("A separate password prompt will appear."))
        // These are the actual production Preview, Rebuild and Result consumers.
        precondition(view.contains("RestoreTaskPresentation(preview: preview, plan: prepared)"))
        precondition(view.contains("RestoreTaskPresentation(preview: preview, plan: plan, events: model.categoryPresentationEvents, executing: true, operationProgress: true)"))
        precondition(view.contains("RestoreResultContent(result: result"))
        precondition(view.contains("RestoreRebuildProgressContent(tasks: tasks"))
        precondition(TaskDomainPresentation(id: "mixed", title: "Mixed", symbol: "app", items: [
            .init(id: "1", item: preview.categories[0].items[0], state: .matching),
            .init(id: "2", item: preview.categories[0].items[1], state: .attention)
        ], previewOnly: true).state == .attention)
        for state in [TaskRowState.planned, .matching, .attention, .unverified] {
            precondition(TaskDomainPresentation(id: "one", title: "One", symbol: "app", items: [
                .init(id: "1", item: preview.categories[0].items[0], state: state)
            ], previewOnly: true).state == state)
        }
        var scopedRaw = raw
        var scopedRows = rows
        scopedRows[2]["disposition"] = "satisfied"
        scopedRaw["plan"] = scopedRows
        let scopedPlan = try JSONDecoder().decode(CoreRestorePreparation.self, from: JSONSerialization.data(withJSONObject: scopedRaw))
        let scopedPreview = RestorePreviewPresentation(scopedPlan, catalog: catalog)
        let scoped = RestoreTaskPresentation(preview: scopedPreview, plan: scopedPlan, executing: true)
        precondition(scoped.domains.flatMap(\.items).count == rows.count - 1)
        precondition(!scoped.domains.flatMap(\.items).contains { $0.id == "restore-2" })
        let scopedCounts = RestorePreviewMetrics.counts(RestoreTaskPresentation(preview: scopedPreview, plan: scopedPlan).domains)
        precondition(scopedCounts.changes == rows.count - 1 && scopedCounts.matching == 1)
        var semanticRaw = scopedRaw
        var semanticRows = scopedRows
        semanticRows[3]["disposition"] = "blocked"
        semanticRows[3]["reason"] = "cask_target_conflict"
        semanticRows[3]["diagnostic"] = ["primitive": "launchctl", "condition": "foreign_target"]
        semanticRows[4]["disposition"] = "unknown"
        semanticRaw["plan"] = semanticRows
        let semanticPlan = try JSONDecoder().decode(CoreRestorePreparation.self, from: JSONSerialization.data(withJSONObject: semanticRaw))
        let semanticPreview = RestorePreviewPresentation(semanticPlan, catalog: catalog)
        let semanticTasks = RestoreTaskPresentation(preview: semanticPreview, plan: semanticPlan)
        let metrics = RestorePreviewMetrics.counts(semanticTasks.domains)
        precondition(metrics.changes == rows.count - 3 && metrics.attention == 2 && metrics.matching == 1)
        precondition(!semanticTasks.domains.contains { $0.state == .partial })
        let diagnosticItem = semanticTasks.domains.flatMap(\.items).first { $0.id == "restore-3" }!
        precondition(diagnosticItem.item.reason == "cask_target_conflict")
        precondition(diagnosticItem.item.action.contains("launch service"))
        precondition(diagnosticItem.diagnostic?.technicalDescription == "primitive: launchctl\ncondition: foreign_target")
        var rosettaRaw = semanticRaw
        var rosettaRows = semanticRows
        rosettaRows[3]["action"] = "reinstall"
        rosettaRows[3]["reason"] = "cask_rosetta_required"
        rosettaRows[3]["diagnostic"] = ["primitive": "rosetta", "condition": "installation_required"]
        rosettaRaw["plan"] = rosettaRows
        let rosettaPlan = try JSONDecoder().decode(CoreRestorePreparation.self, from: JSONSerialization.data(withJSONObject: rosettaRaw))
        let rosettaTasks = RestoreTaskPresentation(preview: RestorePreviewPresentation(rosettaPlan, catalog: catalog), plan: rosettaPlan)
        let rosettaItem = rosettaTasks.domains.flatMap(\.items).first { $0.id == "restore-3" }!
        precondition(rosettaItem.item.action.contains("softwareupdate --install-rosetta"))
        precondition(rosettaItem.item.action.contains("Refresh Preview"))
        precondition(rosettaItem.diagnostic?.technicalDescription == "primitive: rosetta\ncondition: installation_required")
        rosettaRows[3]["reason"] = "cask_metadata_unavailable"
        rosettaRows[3]["diagnostic"] = ["primitive": "rosetta", "condition": "observation_failed"]
        rosettaRaw["plan"] = rosettaRows
        let unknownRosetta = try JSONDecoder().decode(CoreRestorePreparation.self, from: JSONSerialization.data(withJSONObject: rosettaRaw))
        let unknownTasks = RestoreTaskPresentation(preview: RestorePreviewPresentation(unknownRosetta, catalog: catalog), plan: unknownRosetta)
        let unknownItem = unknownTasks.domains.flatMap(\.items).first { $0.id == "restore-3" }!
        precondition(unknownItem.item.action.contains("could not reliably inspect"))
        precondition(!unknownItem.item.action.contains("install-rosetta"))
        if CommandLine.arguments.contains("--rosetta-only") { return }
        let automationRaw: [String: Any] = ["domain": "homebrew-casks", "code": "cask_authorization_required",
            "status": "external_action_required", "scope": "operation", "selected_item_index": 1,
            "diagnostic": ["primitive": "login_item", "condition": "authorization_denied"]]
        let automation = try JSONDecoder().decode(CoreRestorePreparation.Condition.self, from: JSONSerialization.data(withJSONObject: automationRaw))
        precondition(automation.diagnostic?.automationRequirement == true && !automation.isItemLocal)
        precondition(RestorePrerequisiteSummaryPresentation.status([automation]) == "Authorization Required")
        precondition(automation.diagnostic!.explanation.contains("Refresh Preview"))
        precondition(RestorePrerequisiteSummaryPresentation(conditions: [automation], ready: false).blockers.count == 1)
        var launchRaw = automationRaw
        launchRaw["code"] = "cask_launchctl_observation_failed"
        launchRaw["diagnostic"] = ["primitive": "launchctl", "condition": "observation_failed"]
        let launch = try JSONDecoder().decode(CoreRestorePreparation.Condition.self, from: JSONSerialization.data(withJSONObject: launchRaw))
        var unavailableRaw = automationRaw
        unavailableRaw["code"] = "cask_metadata_unavailable"
        unavailableRaw["diagnostic"] = ["primitive": "login_item", "condition": "application_unavailable"]
        let unavailable = try JSONDecoder().decode(CoreRestorePreparation.Condition.self, from: JSONSerialization.data(withJSONObject: unavailableRaw))
        let scopedPrerequisites = RestorePrerequisiteSummaryPresentation(conditions: [launch, unavailable], ready: false)
        precondition(scopedPrerequisites.blockers.count == 2)
        precondition(scopedPrerequisites.blockers.contains { $0.diagnostic?.automationRequirement == true })
        precondition(launch.diagnostic?.automationRequirement == false)
        let aggregateRaw: [String: Any] = ["domain": "homebrew-casks", "code": "preview_observation_failed", "status": "external_action_required"]
        let aggregate = try JSONDecoder().decode(CoreRestorePreparation.Condition.self, from: JSONSerialization.data(withJSONObject: aggregateRaw))
        let deduplicated = RestorePrerequisiteSummaryPresentation(conditions: [aggregate, unavailable, unavailable], ready: false)
        precondition(deduplicated.conditions.count == 3 && deduplicated.conditions.first?.code == "preview_observation_failed")
        precondition(deduplicated.blockers.count == 1 && deduplicated.blockers[0].diagnostic == unavailable.diagnostic)
        precondition(RestorePrerequisiteSummaryPresentation(conditions: [aggregate], ready: false).blockers.count == 1)
        var foreignRaw = launchRaw
        foreignRaw["code"] = "cask_target_conflict"
        foreignRaw["diagnostic"] = ["primitive": "launchctl", "condition": "foreign_target"]
        let foreign = try JSONDecoder().decode(CoreRestorePreparation.Condition.self, from: JSONSerialization.data(withJSONObject: foreignRaw))
        precondition(RestorePrerequisiteSummaryPresentation(conditions: [aggregate, foreign], ready: false).blockers.count == 2)
        let compact = RestorePrerequisiteSummaryPresentation(conditions: [], ready: true)
        precondition(compact.title == "Ready" && compact.blockers.isEmpty && !compact.detailsInitiallyExpanded)
        var successfulRaw = aggregateRaw
        successfulRaw["code"] = "ready"
        successfulRaw["status"] = "ready"
        let successful = try JSONDecoder().decode(CoreRestorePreparation.Condition.self, from: JSONSerialization.data(withJSONObject: successfulRaw))
        let allReady = RestorePrerequisiteSummaryPresentation(conditions: [successful], ready: true)
        precondition(allReady.isTerminalReady && allReady.conditions.count == 1 && allReady.blockers.isEmpty)
        precondition(!scopedPrerequisites.isTerminalReady && !deduplicated.isTerminalReady)
        precondition(!RestorePrerequisiteSummaryPresentation(conditions: [successful], ready: false).isTerminalReady)
        let summarySource = try String(contentsOf: sourceRoot.appendingPathComponent("RestoreSummary.swift"), encoding: .utf8)
        let prerequisiteView = summarySource.components(separatedBy: "struct RestorePrerequisiteSummaryView: View {")[1]
            .components(separatedBy: "private struct RestoreBlockingPrerequisiteAreaView: View {")[0]
        precondition(prerequisiteView.contains("if !summary.manualConditions.isEmpty {"))
        precondition(prerequisiteView.contains("ForEach(summary.manualDomains") && prerequisiteView.contains("summary.manualConditions.filter"))
        precondition(!prerequisiteView.contains("Label(\"Ready\"") && !prerequisiteView.contains("Button("))
        precondition(summarySource.contains("RestoreBlockingPrerequisiteAreaView(") && summarySource.contains("private var expanded = true"))
        let forged = CoreRestorePreparation.Diagnostic(primitive: "/private/path", condition: "foreign_target")
        precondition(!forged.valid)
        let verificationPhase = try event("execution_event", "verification", "scope", "state", "started")
        precondition(RestoreProgressRow.phase(events: [verificationPhase], mutationPossible: true) == "Verifying restored environment…")
        for item in casks.prefix(3) {
            events.append(try event("execution_event", domains[0], item, "state", "applying", action: item == "firefox" ? "reinstall" : "install"))
            stable(project())
            precondition(project().domains.flatMap(\.items).filter { $0.state == .working }.map { $0.item.title } == [item])
            precondition(project().domains[0].summary.contains("1 working"))
            precondition(project().counters.first { $0.state == .working }?.count == 1)
            events.append(try event("operation_record", domains[0], item, "outcome", "success", action: item == "firefox" ? "reinstall" : "install"))
            precondition(state(item) == .awaitingVerification, "Operation success awaits authoritative conformity")
            precondition(state(item).tone == .neutral && state(item).symbol == "clock")
            precondition(!project().domains.flatMap(\.items).contains { $0.state == .working })
            precondition(!project().counters.contains { $0.state == .working })
        }
        // Even missing terminal evidence must not retain stale activity or imply success.
        events.append(try event("execution_event", domains[0], "cask-4", "state", "applying"))
        events.append(try event("execution_event", domains[1], "firefox", "state", "applying"))
        precondition(state("cask-4") == .unverified)
        precondition(state("firefox") == .awaitingVerification && state("firefox", domain: domains[1]) == .working)
        precondition(project().domains[0].state != .working && project().domains[1].state == .working)
        events.append(try event("operation_record", domains[1], "firefox", "outcome", "failure"))
        precondition(state("firefox", domain: domains[1]) == .failed)
        events.append(try event("operation_record", domains[0], "cask-5", "outcome", "skipped"))
        precondition(state("cask-5") == .skipped)
        events.append(try event("execution_event", domains[0], "cask-6", "state", "applying"))
        events.append(try event("execution_event", domains[0], "cask-6", "state", "changed"))
        precondition(state("cask-6") == .unverified)
        events.append(try event("execution_event", domains[0], "keka", "state", "verifying"))
        precondition(state("keka") == .working)
        events.append(try event("verification_record", domains[0], "keka", "conformity", "verified"))
        precondition(state("keka") == .completed)
        precondition(!project().counters.contains { $0.state == .working })
        events.append(try event("execution_event", "verification", "scope", "state", "started"))
        stable(project())
        precondition(!project().domains.flatMap(\.items).contains { $0.state == .working })
        let verified: [[String: Any]] = rows.map { ["domain": $0["domain"]!, "item_id": $0["item_id"]!, "conformity": "verified"] }
        // Final evidence overrides any earlier live observation.
        events.append(try event("verification_record", domains[0], "firefox", "conformity", "mismatch"))
        precondition(state("firefox") == .unverified && state("firefox").tone == .warning)
        let payloadRaw: [String: Any] = ["verification": ["details": ["verification_records": verified, "operation_records": []]]]
        let payload = try JSONDecoder().decode(CoreJSON.self, from: JSONSerialization.data(withJSONObject: payloadRaw)).object!
        let result = RestoreExecutionPresentation(runtime: CoreRuntime(), payload: payload, expectedID: plan.preparedPlanID)
        let final = RestoreTaskPresentation(preview: preview, plan: plan, events: events.filter { $0.type != "operation_record" }, result: result)
        stable(final)
        precondition(final.domains.allSatisfy { $0.state == .completed })
        precondition(final.domains.flatMap(\.items).allSatisfy { $0.state == .completed })
        let unfinished = RestoreTaskPresentation(preview: preview, plan: plan, events: [],
            result: RestoreExecutionPresentation(runtime: CoreRuntime(), payload: nil, expectedID: plan.preparedPlanID))
        stable(unfinished)
        precondition(unfinished.domains.flatMap(\.items).allSatisfy { $0.state == .unverified })
        print("PASS: Homebrew Applications (16) and Packages (21) stay separate through Preview/Rebuild/Verification/Result")
        print("PASS: Sequential items clear Working without inferred success; counters and final Verification stay authoritative")
        print("PASS: Production Restore projection distinguishes Will Repair / Ready to Repair / Repairing")
    }
    @MainActor static func restoreEvidenceChecks() throws {
        func json(_ value: [String: Any]) throws -> [String: CoreJSON] {
            try JSONDecoder().decode(CoreJSON.self, from: JSONSerialization.data(withJSONObject: value)).object!
        }
        let launcherFailure = try CoreEvent(line: JSONSerialization.data(withJSONObject: ["protocol_version": 1,
            "operation_id": "checks", "sequence": 1, "type": "execution_event",
            "data": ["domain": "launcher", "item_id": "scope", "state": "failed", "reason": "module_failed"]]))
        precondition(RestoreExecutionPresentation.launcherFailureMessages(events: [launcherFailure]).count == 1)
        precondition(RestoreExecutionPresentation.launcherFailureMessages(events: []).isEmpty)
        let launcherRecord: [String: Any] = ["domain": "launcher", "item_id": "scope", "action": "restore", "outcome": "failure", "reason": "launcher_destination_conflict"]
        let launcherPayload = try json(["verification": ["details": ["operation_records": [launcherRecord]]]])
        precondition(RestoreExecutionPresentation.launcherFailureMessages(events: [], payload: launcherPayload).first!.contains("It was preserved"))
        precondition(!RestoreExecutionPresentation.launcherFailureMessages(events: [launcherFailure]).first!.contains("points elsewhere"))
        let provider = CoreRestorePreparation.Diagnostic(primitive: "payload", condition: "provider_conflict")
        precondition(provider.explanation.contains("uncertain") && provider.repairExplanation == provider.explanation)
        precondition(AssistedAppStoreItem(appID: "747648890", status: .missing).statusTitle == "Not in App Store")
        precondition(AssistedAppStoreItem(appID: "747648890", status: .missing).message == "Install in App Store, then Refresh Status.")
        let preparation = try JSONDecoder().decode(CoreRestorePreparation.Diagnostic.self,
            from: JSONSerialization.data(withJSONObject: ["primitive": "pkgutil", "condition": "preparation_required"]))
        let requirement = TaskItemPresentation(id: "pkg", item: DisplayItem(id: "pkg", title: "Fixture", status: .attention,
            action: "Unsupported", reason: "cask_execution_requirements_unsupported"), state: .attention, diagnostic: preparation,
            resultLabels: ["Unsupported"])
        precondition(requirement.resultExplanation!.contains("Refresh Preview and choose Fix Issues…"))
        precondition(requirement.resultExplanation!.contains("does not guarantee installation"))
        var unsupported = requirement; unsupported.diagnostic = nil
        precondition(!unsupported.resultExplanation!.contains("Fix Issues"))
        let id = String(repeating: "a", count: 64)
        let skip: [String: Any] = ["record_id": "o:0", "domain": "homebrew-casks", "item_id": "tailscale-app", "action": "install", "outcome": "skipped", "reason": "cask_execution_requirements_unsupported"]
        let success: [String: Any] = ["record_id": "o:1", "domain": "homebrew-packages", "item_id": "bat", "action": "install", "outcome": "success"]
        let noop: [String: Any] = ["domain": "homebrew-packages", "item_id": "htop", "action": "install", "outcome": "noop"]
        let aggregate: [String: Any] = ["domain": "orchestration", "item_id": "bootstrap", "action": "execute", "outcome": "failure"]
        let observations: [[String: Any]] = [["domain": "homebrew-casks", "item_id": "tailscale-app", "conformity": "mismatch"], ["domain": "homebrew-packages", "item_id": "bat", "conformity": "verified"]]
        func payload(_ operations: [[String: Any]], observations: [[String: Any]] = observations) throws -> [String: CoreJSON] {
            try json(["code": "bootstrap_failed", "prepared_plan_id": id, "independent_work_completed": true,
                "target_mutation_may_have_started": true, "verification": ["status": "complete", "details": ["status": "complete", "operation_records": operations, "verification_records": observations]]])
        }
        let partial = try payload([skip, success, noop, aggregate])
        precondition(RestoreExecutionPresentation.hasPartialEvidence(payload: partial, expectedID: id))
        let manual: [String: Any] = ["domain": "app-store", "item_id": "747648890", "action": "inspect", "outcome": "skipped", "reason": "manual_installation_required"]
        let manualObservation: [String: Any] = ["domain": "app-store", "item_id": "747648890", "predicate": "installed", "conformity": "mismatch"]
        let mixedPartial = try payload([skip, success, aggregate, manual], observations: observations + [manualObservation])
        precondition(RestoreExecutionPresentation.hasPartialEvidence(payload: mixedPartial, expectedID: id))
        let launcherFailed = try payload([skip, success, aggregate, manual, launcherRecord], observations: observations + [manualObservation])
        precondition(!RestoreExecutionPresentation.hasPartialEvidence(payload: launcherFailed, expectedID: id))
        precondition(!RestoreExecutionPresentation.hasPartialEvidence(payload: partial, expectedID: "wrong"))
        var wrongAggregate = aggregate; wrongAggregate["action"] = "install"
        let wrongAggregatePayload = try payload([skip, success, wrongAggregate])
        precondition(!RestoreExecutionPresentation.hasPartialEvidence(payload: wrongAggregatePayload, expectedID: id))
        var failedItem = success; failedItem["outcome"] = "failure"; failedItem["reason"] = "install_failed"
        let failedPayload = try payload([skip, success, failedItem, aggregate])
        precondition(!RestoreExecutionPresentation.hasPartialEvidence(payload: failedPayload, expectedID: id))
        let noopPayload = try payload([skip, noop, aggregate])
        precondition(!RestoreExecutionPresentation.hasPartialEvidence(payload: noopPayload, expectedID: id))
        var incompletePartial = partial
        incompletePartial["independent_work_completed"] = .bool(false)
        precondition(!RestoreExecutionPresentation.hasPartialEvidence(payload: incompletePartial, expectedID: id))
        var diagnosticPayload = partial
        var verificationObject = diagnosticPayload["verification"]!.object!
        var diagnosticDetails = verificationObject["details"]!.object!
        diagnosticDetails["diagnostics"] = .array([.object(["record_id": .string("run"), "code": .string("observation_failed"), "severity": .string("error")])])
        verificationObject["details"] = .object(diagnosticDetails); diagnosticPayload["verification"] = .object(verificationObject)
        precondition(!RestoreExecutionPresentation.hasPartialEvidence(payload: diagnosticPayload, expectedID: id))
        let catalog = CoreRestoreInspection.Inventory(groups: [.init(id: "macOS Settings", domains: ["macos-dock"]), .init(id: "Homebrew", domains: ["homebrew-casks"])], inventory: [
            .init(domain: "macos-dock", label: "Dock", selectionMode: "category", availability: "available", reason: nil, items: []),
            .init(domain: "homebrew-casks", label: "Homebrew Applications", selectionMode: "items", availability: "available", reason: nil, items: [])])
        let planRaw: [String: Any] = ["prepared_plan_id": id, "selection": ["categories": ["macos-dock"], "items": ["homebrew-casks": ["tailscale-app", "iina"]]], "selected_groups": ["macOS Settings"], "selected_categories": ["macos-dock"], "selected_item_counts": ["homebrew-casks": 2], "include_secure": false, "secure_restore_status": "not_selected", "plan": [
            ["domain": "macos-dock", "item_id": "com.apple.dock/tilesize", "action": "set_preference", "disposition": "planned"],
            ["domain": "macos-dock", "item_id": "com.apple.dock/autohide", "action": "set_preference", "disposition": "planned"],
            ["domain": "homebrew-casks", "item_id": "tailscale-app", "action": "install", "disposition": "blocked", "reason": "cask_execution_requirements_unsupported"],
            ["domain": "homebrew-casks", "item_id": "iina", "action": "install", "disposition": "planned"]],
            "readiness": ["ready": true, "ready_scope": "environment", "conditions": [], "reentry": "restore_prepare"], "has_planned_changes": true, "warning_count": 1, "error_count": 0]
        let plan = try JSONDecoder().decode(CoreRestorePreparation.self, from: JSONSerialization.data(withJSONObject: planRaw))
        let preview = RestorePreviewPresentation(plan, catalog: catalog)
        func event(_ domain: String, _ item: String, _ state: String) throws -> CoreEvent {
            try CoreEvent(line: JSONSerialization.data(withJSONObject: ["protocol_version": 1, "operation_id": "checks", "sequence": 1, "type": "execution_event", "data": ["domain": domain, "item_id": item, "state": state, "action": "set_preference"]]))
        }
        let caskActive = try event("homebrew-casks", "iina", "applying")
        let working = RestoreTaskPresentation(preview: preview, plan: plan, events: [caskActive], executing: true, operationProgress: true)
        let caskRow = working.domains.first { $0.id == "homebrew-casks" }!
        precondition(caskRow.executionStatus == .working && caskRow.executionStatusTitle == "Working · Needs Attention" && !caskRow.executionMessages.isEmpty)
        let changed = try event("macos-dock", "com.apple.dock/tilesize", "changed")
        let verifying = try event("verification", "scope", "started")
        let localVerifying = try event("macos-dock", "com.apple.dock/tilesize", "verifying")
        for events in [[changed], [changed, localVerifying, verifying]] {
            let rows = RestoreTaskPresentation(preview: preview, plan: plan, events: events, executing: true, operationProgress: true)
            precondition(rows.domains.first { $0.id == "macOS Settings" }!.executionStatus == .awaitingVerification)
        }
        let dockRecords: [[String: Any]] = ["tilesize", "autohide"].map {
            ["domain": "macos-dock", "item_id": "com.apple.dock/" + $0, "predicate": "stored_preference", "conformity": "verified"]
        }
        let dockEvidence = try dockRecords.map { try json($0) }
        let dockEntries = plan.plan.filter { $0.domain == "macos-dock" }
        precondition(RestoreTaskPresentation.hasVerifiedRequirements(entries: dockEntries, observations: dockEvidence, operations: []))
        precondition(!RestoreTaskPresentation.hasVerifiedRequirements(entries: dockEntries, observations: Array(dockEvidence.prefix(1)), operations: []))
        var mismatchEvidence = dockEvidence; mismatchEvidence[1]["conformity"] = .string("mismatch")
        precondition(!RestoreTaskPresentation.hasVerifiedRequirements(entries: dockEntries, observations: mismatchEvidence, operations: []))
        // A runtime without a terminal receipt cannot certify a final outcome.
        let runtime = CoreRuntime()
        func finalRows(_ observations: [[String: Any]]) throws -> RestoreTaskPresentation {
            let data = try payload([skip, success, aggregate], observations: observations + observationsForPackage)
            let result = RestoreExecutionPresentation(runtime: runtime, payload: data, expectedID: id, catalog: catalog)
            return RestoreTaskPresentation(preview: preview, plan: plan, result: result, executing: true, operationProgress: true)
        }
        let observationsForPackage: [[String: Any]] = [["domain": "homebrew-packages", "item_id": "bat", "conformity": "verified"]]
        // The incomplete runtime intentionally cannot certify a terminal outcome.
        let uncertified = try finalRows(dockRecords)
        precondition(uncertified.domains.first { $0.id == "macOS Settings" }!.executionStatus == .unverified)
        let names = ["homebrew-casks": ["tailscale-app": "Tailscale", "iina": "IINA"]]
        let normalized = RestoreResultFindings(payload: partial, events: [], catalog: catalog, verified: false, itemNames: names, completedWithIssues: true)
        precondition(normalized.findings.count == 1 && normalized.findings[0].title == "Tailscale")
        var second = skip; second["item_id"] = "iina"
        let two = RestoreResultFindings(payload: try payload([skip, second, success, aggregate]), events: [], catalog: catalog, verified: false, itemNames: names, completedWithIssues: true)
        precondition(two.findings.count == 2 && Set(two.findings.map(\.title)) == ["Tailscale", "IINA"])
        let technical = RestoreExecutionPresentation(runtime: runtime, payload: partial, expectedID: id).technicalDetails.joined(separator: "\n")
        precondition(technical.contains("bootstrap_failed") && technical.contains("cask_execution_requirements_unsupported") && technical.contains("tailscale-app") && technical.contains("mismatch"))
        var privatePayload = partial; privatePayload["access_token"] = .string("DO_NOT_RENDER")
        privatePayload["stderr"] = .string("DO_NOT_RENDER")
        precondition(!RestoreExecutionPresentation(runtime: runtime, payload: privatePayload, expectedID: id).technicalDetails.joined().contains("DO_NOT_RENDER"))
        let privateResult = RestoreExecutionPresentation(runtime: runtime, payload: privatePayload, expectedID: id)
        precondition(!privateResult.diagnosticReport.contains("DO_NOT_RENDER"))
        precondition(privateResult.diagnosticReport.contains("homebrew-packages") && privateResult.diagnosticReport.contains("verified"))
        precondition(!privateResult.compactTechnicalDetails.joined().contains("item_id: bat"))
        precondition(privateResult.compactTechnicalDetails.count < privateResult.technicalDetails.count)
        let safeHash = String(repeating: "d", count: 64)
        var stalePayload: [String: CoreJSON] = ["code": .string("stale_plan"),
            "target_mutation_may_have_started": .bool(false),
            "plan_validation": .object(["check": .string("prepared_plan_id"), "expected_id": .string(id),
                "recomputed_id": .string(safeHash), "components": .object(["plan": .string(safeHash), "bundle": .string(id), "secret": .string("DO_NOT_COPY")]),
                "private_path": .string("/Users/DO_NOT_COPY")])]
        let diagnostic = RestoreExecutionPresentation(runtime: runtime, payload: stalePayload, expectedID: id,
            expectedDiagnostics: ["plan": id, "bundle": id]).diagnosticReport
        precondition(diagnostic.contains("Desktop prepared ID: " + id) && diagnostic.contains("Execute requested ID: " + id))
        precondition(diagnostic.contains("Core recomputed ID: " + safeHash) && diagnostic.contains("plan changed: true"))
        precondition(diagnostic.contains("bundle changed: false") && diagnostic.contains("selection changed: unknown"))
        precondition(!diagnostic.contains("DO_NOT_COPY") && !diagnostic.contains("/Users/"))
        stalePayload["plan_validation"] = .object(["check": .string("DO_NOT_COPY"), "expected_id": .string("DO_NOT_COPY"),
            "components": .object(["plan": .string("DO_NOT_COPY")])])
        precondition(!RestoreExecutionPresentation(runtime: runtime, payload: stalePayload, expectedID: id,
            expectedDiagnostics: ["plan": "DO_NOT_COPY"]).diagnosticReport.contains("DO_NOT_COPY"))
        print("PASS: Working retains Preview warnings; execution awaits Verification; Partial requires typed independent success; item diagnostics preserve independent problems")
    }
    @MainActor static func applicationPrecedenceChecks() throws {
        let catalog = CoreRestoreInspection.Inventory(
            groups: [.init(id: "Applications", domains: ["homebrew-casks", "app-store"])],
            inventory: [
                .init(domain: "homebrew-casks", label: "Homebrew Applications", selectionMode: "items",
                      availability: "available", reason: nil, items: [.init(itemID: "cask", label: "Telegram")]),
                .init(domain: "app-store", label: "App Store Applications", selectionMode: "items",
                      availability: "available", reason: nil, items: [.init(itemID: "duplicate", label: "Telegram"),
                          .init(itemID: "other", label: "Other application")])])
        let requested = CoreRestoreSelection(categories: [], items: ["homebrew-casks": ["cask"], "app-store": ["duplicate", "other"]])
        var raw: [String: Any] = [
            "prepared_plan_id": String(repeating: "d", count: 64),
            "selection": ["categories": [], "items": requested.items],
            "effective_selection": ["categories": [], "items": ["homebrew-casks": ["cask"], "app-store": ["other"]]],
            "application_duplicates": [["app_store_item_id": "duplicate", "cask_item_id": "cask"]],
            "selected_groups": ["Applications"], "selected_categories": [],
            "selected_item_counts": ["homebrew-casks": 1, "app-store": 1],
            "include_secure": false, "secure_restore_status": "not_selected",
            "plan": [
                ["domain": "homebrew-casks", "item_id": "telegram", "selection_item_id": "cask", "action": "install", "disposition": "planned"],
                ["domain": "app-store", "item_id": "425264550", "selection_item_id": "other", "action": "inspect", "disposition": "warning", "reason": "manual_installation_required"]],
            "readiness": ["ready": true, "ready_scope": "environment", "conditions": [], "reentry": "restore_prepare"],
            "has_planned_changes": true, "has_executable_changes": true, "warning_count": 1, "error_count": 0]
        func decode(_ value: [String: Any]) throws -> CoreRestorePreparation {
            try JSONDecoder().decode(CoreRestorePreparation.self, from: JSONSerialization.data(withJSONObject: value))
        }
        let plan = try decode(raw)
        try plan.validate(expected: requested, catalog: catalog)
        let preview = RestorePreviewPresentation(plan, catalog: catalog)
        let tasks = RestoreTaskPresentation(preview: preview, plan: plan)
        precondition(preview.categories.flatMap(\.items).filter { $0.title == "Telegram" }.count == 1)
        precondition(plan.selection == requested && requested.items["app-store"]?.count == 2)
        precondition(plan.selectedItemCounts["app-store"] == 1 && plan.effectiveSelection?.items["app-store"]?.count == 1)
        precondition(tasks.appStore.items.count == 1)
        precondition(tasks.appStore.items[0].item.title == "Other application")
        var onlyDuplicate = raw
        let onlyRequested = CoreRestoreSelection(categories: [], items: ["homebrew-casks": ["cask"], "app-store": ["duplicate"]])
        onlyDuplicate["selection"] = ["categories": [], "items": onlyRequested.items]
        onlyDuplicate["effective_selection"] = ["categories": [], "items": ["homebrew-casks": ["cask"]]]
        onlyDuplicate["selected_item_counts"] = ["homebrew-casks": 1, "app-store": 0]
        onlyDuplicate["plan"] = [(raw["plan"] as! [[String: String]])[0]]
        let onlyPlan = try decode(onlyDuplicate)
        try onlyPlan.validate(expected: onlyRequested, catalog: catalog)
        let onlyPreview = RestorePreviewPresentation(onlyPlan, catalog: catalog)
        precondition(onlyPreview.categories.count == 1)
        precondition(RestoreTaskPresentation(preview: onlyPreview, plan: onlyPlan).appStore.items.isEmpty)
        // A Core reduction must name exactly the removed MAS IDs and selected Casks.
        for key in ["effective_selection", "application_duplicates"] {
            var invalid = raw; invalid.removeValue(forKey: key)
            do { try decode(invalid).validate(expected: requested, catalog: catalog); preconditionFailure("Unbound scope reduction") }
            catch {}
        }
        var invalid = raw
        invalid["application_duplicates"] = [["app_store_item_id": "duplicate", "cask_item_id": "unselected"]]
        do { try decode(invalid).validate(expected: requested, catalog: catalog); preconditionFailure("Unselected provider") }
        catch {}
        invalid = raw
        invalid["selected_item_counts"] = ["homebrew-casks": 1, "app-store": 2]
        do { try decode(invalid).validate(expected: requested, catalog: catalog); preconditionFailure("Duplicate counts") }
        catch {}
        // A failed retained Cask stays failed; no manual duplicate is resurrected.
        var rows = raw["plan"] as! [[String: String]]
        rows[0]["disposition"] = "unknown"; rows[0]["reason"] = "observation_failed"
        raw["plan"] = rows; raw["has_planned_changes"] = false; raw["has_executable_changes"] = false
        let failed = try decode(raw)
        try failed.validate(expected: requested, catalog: catalog)
        let failedPreview = RestorePreviewPresentation(failed, catalog: catalog)
        precondition(failedPreview.categories.first?.items.first?.status == .unverified)
        precondition(RestoreTaskPresentation(preview: failedPreview, plan: failed).appStore.items.count == 1)
    }

    @MainActor static func assistedAppStoreChecks() throws {
        try applicationPrecedenceChecks()
        let id = "425264550"
        let url = AssistedAppStoreItem.productURL(id)!
        precondition(url.absoluteString == "macappstore://apps.apple.com/app/id425264550")
        for invalid in ["", "0", "000", "-1", "425264550?x=1", "425264550/other", "App Name", " 425264550", "４２５", "1\n", String(repeating: "1", count: 21)] {
            precondition(AssistedAppStoreItem.productURL(invalid) == nil, invalid)
            for status in [AssistedAppStoreItem.Status.missing, .unverified] {
                precondition(AssistedAppStoreItem(appID: invalid, status: status).productURL == nil)
            }
        }
        var opened: [URL] = []
        precondition(AppStoreProductButton.open(url, using: { opened.append($0); return true }))
        precondition(opened == [url])
        precondition(!AppStoreProductButton.open(URL(string: "https://example.test/app/id425264550")!, using: { opened.append($0); return true }))
        precondition(opened == [url])
        precondition(!AppStoreProductButton.open(url, using: { _ in false }))
        let catalog = CoreRestoreInspection.Inventory(groups: [.init(id: "Applications", domains: ["app-store"])],
            inventory: [.init(domain: "app-store", label: "App Store Applications", selectionMode: "items", availability: "available", reason: nil,
                items: [.init(itemID: "selected-app", label: "Blackmagic Disk Speed Test")])])
        var appRows: [TaskItemPresentation] = []
        for (disposition, reason, expected) in [("satisfied", "", AssistedAppStoreItem.Status.installed),
                                                ("warning", "manual_installation_required", .missing),
                                                ("unknown", "observation_failed", .unverified)] {
            var row: [String: Any] = ["domain": "app-store", "item_id": id, "selection_item_id": "selected-app", "action": "inspect", "disposition": disposition]
            if !reason.isEmpty {
                row["reason"] = reason
                row["diagnostic"] = ["primitive": "inventory", "condition": "observation_failed"]
            }
            let raw: [String: Any] = ["prepared_plan_id": String(repeating: "a", count: 64),
                "selection": ["categories": [], "items": ["app-store": ["selected-app"]]],
                "selected_groups": ["Applications"], "selected_categories": [], "selected_item_counts": ["app-store": 1],
                "include_secure": false, "secure_restore_status": "not_selected", "plan": [row],
                "readiness": ["ready": true, "ready_scope": "environment", "conditions": [], "reentry": "restore_prepare"],
                "has_planned_changes": false, "has_executable_changes": false, "warning_count": 0, "error_count": 0]
            let plan = try JSONDecoder().decode(CoreRestorePreparation.self, from: JSONSerialization.data(withJSONObject: raw))
            try plan.validate(expected: plan.selection, catalog: catalog)
            let preview = RestorePreviewPresentation(plan, catalog: catalog)
            let before = RestoreTaskPresentation(preview: preview, plan: plan).domains.flatMap(\.items)[0]
            appRows.append(before)
            let partition = RestoreTaskPresentation(preview: preview, plan: plan)
            precondition(partition.automaticDomains.isEmpty && partition.appStore.items.count == 1)
            precondition(partition.counters.isEmpty)
            precondition(partition.appStore.allInstalled == (expected == .installed))
            precondition(RestorePreviewMetrics.counts(partition.automaticDomains).attention == 0)
            precondition(RestoreResultSummary(domains: partition.automaticDomains).cards.isEmpty)
            precondition(before.item.title == "Blackmagic Disk Speed Test" && before.assistedAppStore?.status == expected)
            precondition((before.assistedAppStore?.productURL != nil) == (expected != .installed))
            precondition(before.assistedAppStore != nil)
            precondition(before.item.reason == (reason.isEmpty ? nil : reason))
            precondition(before.diagnostic?.condition == (reason.isEmpty ? nil : "observation_failed"))
            // No final Verification means Unverified, even with a matching Preview.
            let unknown = RestoreTaskPresentation(preview: preview, plan: plan, executing: true, operationProgress: true).domains.flatMap(\.items)[0]
            precondition(unknown.assistedAppStore?.status == .unverified)
            for (conformity, status) in [("verified", AssistedAppStoreItem.Status.installed), ("mismatch", .missing), ("unverified", .unverified)] {
                let event = try CoreEvent(line: JSONSerialization.data(withJSONObject: ["protocol_version": 1,
                    "operation_id": "assisted", "sequence": 1, "type": "verification_record",
                    "data": ["domain": "app-store", "item_id": id, "predicate": "installed", "conformity": conformity]]))
                let item = RestoreTaskPresentation(preview: preview, plan: plan, events: [event], executing: true, operationProgress: true).domains.flatMap(\.items)[0]
                precondition(item.assistedAppStore?.status == status)
                precondition(item.resultTitle == status.rawValue)
                precondition(item.resultGroup == (status == .installed ? "Success" : "Needs Attention"))
                precondition(item.assistedAppStore != nil)
                precondition(item.resultTechnicalDetails != nil)
                precondition((item.assistedAppStore?.productURL != nil) == (status != .installed))
                if let productURL = item.assistedAppStore?.productURL {
                    let evidence = event.data, labels = item.resultLabels
                    for opened in [true, false] {
                        precondition(AppStoreProductButton.open(productURL, using: { _ in opened }) == opened)
                        precondition(item.assistedAppStore?.status == status && item.resultLabels == labels && event.data == evidence)
                    }
                }
            }
        }
        let summary = AppStoreRestorePresentation(domains: [.init(id: "app-store", title: "App Store", symbol: "app", items: appRows)])
        precondition(summary.items.count == 3 && summary.installed.count == 1 && summary.pending.count == 2)
        precondition(summary.missingCount == 1 && summary.unverifiedCount == 1 && !summary.allInstalled)
        precondition(summary.pending.map { AppStoreRestorePresentation.status($0) } == [.missing, .unverified])
        precondition(summary.summary == "1 installed · 1 manual action required · 1 unverified")
        precondition(!AppStoreRestorePresentation(domains: []).allInstalled)
        for domain in ["homebrew-casks", "homebrew-packages", "workspace-folders", "macos-finder", "vscode-extensions"] {
            let item = TaskItemPresentation(id: domain, item: DisplayItem(id: domain, title: domain, status: .attention,
                action: "Needs inspection", reason: "observation_failed"), state: .attention,
                resultLabels: ["Unverified"], resultTechnicalDetails: "Retained diagnostics", resultEvidenceAvailable: true)
            precondition(item.item.reason == "observation_failed")
            precondition(item.resultTechnicalDetails == "Retained diagnostics")
            let working = TaskItemPresentation(id: item.id, item: item.item, state: .working)
            precondition(working.item.reason == "observation_failed")
        }
        print("PASS: Assisted Missing/Unverified actions preserve evidence, Installed has no action, and all workflow rows retain diagnostics in their models")
    }
    @MainActor static func main() async throws {
        try assistedAppStoreChecks()
        if CommandLine.arguments.contains("--rosetta-only") {
            try taskPresentationChecks()
            print("PASS: Rosetta prerequisite and observation failure in Restore Preview and retained diagnostic evidence")
            return
        }
        if !CommandLine.arguments.contains("--preview-appstore-layout-only") && !CommandLine.arguments.contains("--selection-preview-only") && !CommandLine.arguments.contains("--independent-ownership-only") && !CommandLine.arguments.contains("--review-cancel-only") && !CommandLine.arguments.contains("--restore-macos-only") && !CommandLine.arguments.contains("--pkg-preparation-only") && !CommandLine.arguments.contains("--fix-issues-only") {
            for id in WorkspaceCategoryStyle.groups.flatMap({ $0.1 }) {
                let problem = TaskItemPresentation(id: "problem", item: DisplayItem(id: "problem", title: "Problem", status: .attention, action: "Needs inspection"), state: .failed, resultLabels: ["Failed", "Mismatch"])
                var category = TaskDomainPresentation(id: id, title: id, symbol: "folder", items: [problem], activityState: .working)
                precondition(category.executionStatusTitle == "Working · Needs Attention")
                category.activityState = nil
                precondition(category.executionStatusTitle == "Needs Attention")
                let counts = Dictionary(uniqueKeysWithValues: RestoreFinalDomain.counts(category))
                precondition(counts == ["Needs Attention": 1])
                precondition(counts["Applied"] == nil && counts["Verified"] == nil)
            }
            func resultItem(_ labels: [String], state: TaskRowState = .completed, reason: String? = nil) -> TaskItemPresentation {
                TaskItemPresentation(id: labels.joined(separator: ":"), item: DisplayItem(id: "fixture", title: "Fixture", status: .information, action: "", reason: reason), state: state, resultLabels: labels)
            }
            let success = resultItem(["Applied", "Verified"])
            let matching = resultItem(["Already Matches", "Verified"])
            let unsupported = resultItem(["Skipped", "Unsupported"], state: .skipped, reason: "cask_execution_requirements_unsupported")
            let skipped = resultItem(["Skipped", "Verified"], state: .skipped, reason: "not_applicable")
            let unverified = resultItem(["Applied", "Unverified"])
            let waiting = resultItem(["Unverified"], state: .waiting)
            let category = TaskDomainPresentation(id: "fixture", title: "Fixture", symbol: "folder", items: [success, matching, unsupported, skipped, unverified, waiting])
            precondition(Dictionary(uniqueKeysWithValues: RestoreFinalDomain.counts(category)) == ["Success": 3, "Needs Attention": 1, "Skipped": 1])
            precondition(RestoreFinalDomain.visibleLabels(success) == ["Verified"])
            precondition(!RestoreFinalDomain.showsItemDetails(success))
            precondition(!RestoreFinalDomain.showsItemDetails(matching))
            precondition(RestoreFinalDomain.group(unverified) == "Success")
            let ids = Set(WorkspaceCategoryStyle.groups.flatMap { $0.1 })
            precondition(RestoreExecutionCategories.toggledCategories([], ids: ids) == ids)
            precondition(RestoreExecutionCategories.toggledCategories(ids, ids: ids).isEmpty)
            precondition(RestoreExecutionCategories.toggledCategories(["homebrew-casks"], ids: ids) == ids)

            precondition(RestoreFinalDomain.visibleLabels(matching) == ["Already Matches"])
            precondition(RestoreFinalDomain.visibleLabels(unverified) == ["Applied, not verified"] && RestoreFinalDomain.showsItemDetails(unverified))
            precondition(RestoreFinalDomain.visibleLabels(unsupported) == ["Needs Attention"] && unsupported.resultLabels.contains("Unsupported"))
            precondition(RestoreFinalDomain.visibleLabels(success, notRun: true) == ["Verified"])
            precondition(RestoreFinalDomain.group(resultItem(["Skipped", "Unverified"], state: .skipped)) == "Needs Attention")
            precondition(RestoreFinalDomain.group(resultItem(["Verified"])) == "Success")
            precondition(RestoreFinalDomain.counts(TaskDomainPresentation(id: "not-run", title: "Not Run", symbol: "folder", items: [waiting], confirmedFinalState: .notRun)).isEmpty)
            try taskPresentationChecks()
            try restoreEvidenceChecks()
        }
        if CommandLine.arguments.contains("--presentation-only") { return }
        for (status, expected, prompts) in [(Int32(0), RestoreAutomationPermission.Outcome.available, 0),
                                            (-1744, .available, 1), (-1743, .denied, 0), (-10004, .unavailable, 0)] {
            var promptCount = 0
            var starts = 0
            let outcome = await RestoreAutomationPermission.resolve(check: { status }, prompt: { promptCount += 1; return 0 }, start: { starts += 1 })
            precondition(outcome == expected && promptCount == prompts && starts == 0)
        }
        var checks = 0
        let unavailableThenUndetermined = await RestoreAutomationPermission.resolve(check: { checks += 1; return checks == 1 ? -600 : -1744 }, prompt: { 0 }, start: {})
        precondition(unavailableThenUndetermined == .available && checks == 2)
        let deniedPrompt = await RestoreAutomationPermission.resolve(check: { -1744 }, prompt: { -1743 }, start: {})
        precondition(deniedPrompt == .denied && deniedPrompt.message != nil)
        let repo = URL(fileURLWithPath: CommandLine.arguments[1])
        let python = URL(fileURLWithPath: CommandLine.arguments[2])
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("macseed-desktop-restore-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let core = root.appendingPathComponent("fake")
        try FileManager.default.createDirectory(at: core.appendingPathComponent("modules/core/application-interface"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: core.appendingPathComponent("config"), withIntermediateDirectories: true)
        for path in ["bootstrap.sh", "config/toolkit.conf", "modules/core/application-interface/core.py"] { try Data().write(to: core.appendingPathComponent(path)) }
        try write("#!/bin/bash\nexec python3 -B fixture.py\n", core.appendingPathComponent("modules/core/application-interface/core.sh"))
        try write("""
        import json, sys, time, os, signal
        from pathlib import Path
        request=json.load(sys.stdin)
        with open('requests.jsonl','a') as out: out.write(json.dumps(request)+'\\n')
        mode=Path('mode').read_text() if Path('mode').exists() else 'clean'
        session=mode.startswith('session')
        session_id=__import__('hashlib').sha256(Path('session-count').read_bytes()).hexdigest() if Path('session-count').exists() else 'a'*64
        sequence=0
        def emit(kind,data=None):
            global sequence
            sequence+=1
            row=dict(protocol_version=1,operation_id=request['operation_id'],sequence=sequence,type=kind)
            if data is not None: row['data']=data
            print(json.dumps(row),flush=True)
        def cancelled(signum, frame):
            emit('cancelled',{'code':'cancelled'}); sys.exit(130)
        signal.signal(signal.SIGTERM,cancelled)
        emit('started')
        operation=request['operation']
        if operation=='capabilities':
            features={} if mode=='old_core' else {'restore_selection':{'version':1},'bundle_comparison':{'version':1}}
            result=dict(protocol_version=1, product_version='3.4.0',operations=['bundle_inspect','restore_prepare','environment_compare'],features=features)
        elif operation=='environment_compare':
            result=json.loads(Path('comparison.json').read_text())
        elif operation=='bundle_inspect':
            if mode in ('bundle_invalid','unsupported_bundle'):
                emit('failed',{'code':mode}); sys.exit(2)
            result=json.loads(Path('inspection.json').read_text())
        elif operation=='restore_prepare':
            if mode in ('slow','interrupted'):
                emit('phase_started',{'phase':'preparation'})
                if mode=='interrupted': os.kill(os.getpid(),signal.SIGKILL)
                time.sleep(20)
            if mode=='prepare_failure': emit('failed',{'code':'preview_failed'}); sys.exit(2)
            assert request['parameters']['include_secure'] is False
            assert request['parameters']['disabled_groups']==[]
            requested=request['parameters']['selection']
            catalog=json.loads(Path('inspection.json').read_text())['restore_selection']
            selected_categories=[]; selected_items={}; plan=[]
            for area in catalog['inventory']:
                domain=area['domain']
                if domain in requested['categories']:
                    if area['selection_mode']=='category': selected_categories.append(domain)
                    else: selected_items[domain]=[x['item_id'] for x in area['items']]
                elif domain in requested['items']: selected_items[domain]=requested['items'][domain]
                if domain in selected_categories:
                    plan.append(dict(domain=domain,item_id='scope',action='set_setting',disposition='planned',reason=None))
                for index,item in enumerate(selected_items.get(domain,[])):
                    disposition=['satisfied','planned','warning','conflict'][index%4] if mode=='attention' else 'planned'
                    plan.append(dict(domain=domain,item_id=str(index+1),selection_item_id=item,action='install',disposition=disposition,reason='target_conflict' if disposition=='conflict' else None))
            selected=set(selected_categories)|set(selected_items)
            groups=[group['id'] for group in catalog['groups'] if selected.intersection(group['domains'])]
            conditions=[] if mode!='attention' else [dict(domain='homebrew-packages',code='homebrew_installation_requires_interaction',status='external_action_required')]
            if mode=='automation': conditions=[dict(domain='homebrew-casks',code='cask_metadata_unavailable',status='external_action_required',scope='operation',selected_item_index=1,diagnostic=dict(primitive='login_item',condition='application_unavailable'))]
            if mode=='safe': conditions=[dict(domain='homebrew-packages',code='homebrew_path_activation',status='safely_satisfiable')]
            if mode=='satisfied': conditions=[dict(domain='homebrew-packages',code='ready',status='satisfied')]
            if mode=='unsupported_condition': conditions=[dict(domain='homebrew-packages',code='unsupported_interactive_operation',status='unsupported')]
            result=dict(prepared_plan_id=('b' if mode=='safe' else 'a')*64,
                selection=dict(categories=sorted(selected_categories),items={k:sorted(v) for k,v in selected_items.items()}),
                selected_groups=groups, selected_categories=selected_categories,selected_item_counts={k:len(v) for k,v in selected_items.items()},
                include_secure=False,secure_restore_status='not_selected',plan=plan,readiness=dict(ready=not conditions or mode in ('safe','satisfied'),ready_scope='environment',conditions=conditions,reentry='restore_prepare'),
                has_planned_changes=mode not in ('no_changes','no_changes_attention'),warning_count=1 if mode=='attention' else 0,error_count=0)
            if mode.startswith('assisted_'):
                result['warning_count']=0 if mode=='assisted_installed' else 1
                for index,row in enumerate(result['plan']):
                    if row['domain']=='app-store':
                        row['item_id']=str(425264550+index)
                        row['action']='inspect'
                        row['disposition']={'assisted_missing':'warning','assisted_installed':'satisfied','assisted_unverified':'unknown','assisted_launcher_failure':'warning','assisted_deduplicated':'warning'}[mode]
                        row['reason']={'assisted_missing':'manual_installation_required','assisted_installed':None,'assisted_unverified':'observation_failed','assisted_launcher_failure':'manual_installation_required','assisted_deduplicated':'manual_installation_required'}[mode]
                        if mode=='assisted_deduplicated':
                            row['item_id']=str(425264550+int(row['selection_item_id'].split('-')[-1])-1)
                if mode=='assisted_deduplicated' and selected_items.get('homebrew-casks') and selected_items.get('app-store'):
                    duplicate=selected_items['app-store'][0]
                    result['effective_selection']=json.loads(json.dumps(result['selection']))
                    result['effective_selection']['items']['app-store'].remove(duplicate)
                    result['application_duplicates']=[dict(app_store_item_id=duplicate,cask_item_id=selected_items['homebrew-casks'][0])]
                    result['selected_item_counts']['app-store']-=1
                    result['plan']=[row for row in result['plan'] if row.get('selection_item_id')!=duplicate]
                result['has_executable_changes']=any(row['disposition']=='planned' for row in result['plan'])
                result['has_planned_changes']=result['has_executable_changes']
            if mode=='ux':
                ux=json.loads(Path('ux.json').read_text())
                store=[row for row in result['plan'] if row['domain']=='app-store']
                for index,row in enumerate(store):
                    missing=index<ux.get('manual',0)
                    unverified=not missing and index<ux.get('manual',0)+ux.get('unverified',0)
                    row.update(item_id=str(425264550+index),action='inspect',disposition='warning' if missing else 'unknown' if unverified else 'satisfied',reason='manual_installation_required' if missing else 'observation_failed' if unverified else None)
                if ux.get('layout_preview'):
                    casks=[row for row in result['plan'] if row['domain']=='homebrew-casks']
                    for index,row in enumerate(casks):
                        row.update(disposition='warning' if index==0 else 'planned' if index==1 else 'satisfied',reason='observation_failed' if index==0 else None)
                    for row in result['plan']:
                        if row['domain'] in ['homebrew-packages','vscode-extensions']: row.update(disposition='satisfied',reason=None)
                if ux.get('partial'):
                    cask=next(row for row in result['plan'] if row['domain']=='homebrew-casks')
                    cask.update(disposition='blocked',reason='cask_execution_requirements_unsupported')
                    result['readiness']['conditions']=[dict(domain='homebrew-casks',code='cask_execution_requirements_unsupported',status='unsupported',scope='item',selected_item_index=1)]
                result['has_executable_changes']=any(row['disposition']=='planned' for row in result['plan'])
                result['has_planned_changes']=result['has_executable_changes']
            if mode=='mixed_progress':
                for row in result['plan']:
                    if row['domain'] in ('app-store','ssh-configuration'): row['disposition']='satisfied'
            if mode in ('no_changes','no_changes_attention'):
                for row in result['plan']: row['disposition']='satisfied'
                if mode=='no_changes_attention': result['plan'][0]['disposition']='warning'
            if mode in ('item_local','only_item_local','forged_item_local','scoped_ssh') and (mode!='scoped_ssh' or 'homebrew-casks' in selected_items):
                casks=[row for row in result['plan'] if row['domain']=='homebrew-casks']
                casks[1]['disposition']='blocked'
                casks[1]['reason']='cask_execution_requirements_unsupported'
                if mode=='only_item_local':
                    for row in result['plan']:
                        if row is not casks[1]: row['disposition']='satisfied'
                result['readiness']['conditions']=[dict(domain='homebrew-casks',code='homebrew_unavailable' if mode=='forged_item_local' else 'cask_execution_requirements_unsupported',status='unsupported',scope='item',selected_item_index=2)]
                if mode=='item_local':
                    # Existing no-action conflict semantics are preserved;
                    # they must not block unrelated executable work in the UI.
                    preserved=next(row for row in result['plan'] if row['domain']=='git-repositories')
                    preserved.update(action='none',disposition='conflict',reason='target_conflict')
                result['readiness']['ready']=True
                result['has_executable_changes']=any(row['disposition']=='planned' for row in result['plan'])
            if mode=='ownership_conflict':
                casks=[row for row in result['plan'] if row['domain']=='homebrew-casks']
                blocked=casks[1]
                ready=[row for row in result['plan'] if row is not blocked][:4]
                for row in result['plan']: row['disposition']='planned' if row in ready else 'satisfied'
                blocked.update(action='reinstall',disposition='blocked',reason='cask_target_conflict',diagnostic=dict(primitive='lifecycle',condition='ownership_unproven'))
                result['readiness'].update(ready=True,conditions=[dict(domain='homebrew-casks',code='cask_target_conflict',status='unsupported',scope='item',selected_item_index=2,diagnostic=blocked['diagnostic'])])
                result['has_executable_changes']=True
            if mode in ('pkg-preparation','pkg-and-automation'):
                approved=request['parameters'].get('installer_preparations')
                assert approved is None or approved==['c'*64]
                cask=next(row for row in result['plan'] if row['domain']=='homebrew-casks')
                if approved is None:
                    cask.update(disposition='blocked',reason='cask_execution_requirements_unsupported',installer_preparation_id='c'*64,diagnostic=dict(primitive='pkgutil',condition='preparation_required'))
                    result['readiness']['conditions']=[dict(domain='homebrew-casks',code='cask_execution_requirements_unsupported',status='unsupported',scope='item',selected_item_index=1)]
                result['readiness']['ready']=True
                result['prepared_plan_id']=('d' if approved else 'a')*64
                if mode=='pkg-and-automation' and not Path('automation-fixed').exists():
                    second=next(row for row in result['plan'] if row['domain']=='homebrew-casks' and row is not cask)
                    second.update(disposition='blocked',reason='cask_metadata_unavailable',diagnostic=dict(primitive='login_item',condition='application_unavailable'))
                    result['readiness']['conditions'].append(dict(domain='homebrew-casks',code='cask_metadata_unavailable',status='external_action_required',scope='operation',selected_item_index=2,diagnostic=dict(primitive='login_item',condition='application_unavailable')))
                    result['readiness']['ready']=False
                    result['prepared_plan_id']='e'*64
            if mode=='scoped_ssh':
                if 'ssh-configuration' in selected_categories:
                    result['readiness']['conditions'].append(dict(domain='ssh-configuration',code='ssh_configuration_not_ready',status='external_action_required',scope='operation'))
                    result['readiness']['ready']=False
                result['prepared_plan_id']=__import__('hashlib').sha256(json.dumps(result['selection'],sort_keys=True).encode()).hexdigest()
            if mode in ('session-automation','session-skip'):
                casks=[row for row in result['plan'] if row['domain']=='homebrew-casks']
                casks[1].update(disposition='blocked',reason='cask_execution_requirements_unsupported')
                result['readiness']['conditions']=[dict(domain='homebrew-casks',code='cask_execution_requirements_unsupported',status='unsupported',scope='item',selected_item_index=2)]
                result['readiness']['ready']=mode=='session-skip'
                if mode=='session-automation':
                    casks[0].update(disposition='blocked',reason='cask_metadata_unavailable',diagnostic=dict(primitive='login_item',condition='application_unavailable'))
                    result['readiness']['conditions'].append(dict(domain='homebrew-casks',code='cask_metadata_unavailable',status='external_action_required',scope='operation',selected_item_index=1,diagnostic=dict(primitive='login_item',condition='application_unavailable')))
            if session:
                count=int(Path('session-count').read_text())+1 if Path('session-count').exists() else 1
                Path('session-count').write_text(str(count))
                result['prepared_plan_id']=__import__('hashlib').sha256(str(count).encode()).hexdigest()
                result['plan_diagnostics']={key:result['prepared_plan_id'] for key in ('bundle','stage','selection','parameters','plan','readiness','modules')}
                if mode=='session-delay': time.sleep(0.15)
            if mode=='wrong_selection': result['selection']['categories']=['not-chosen']
        elif operation=='restore_execute':
            assert request['parameters']['include_secure'] is False
            assert request['parameters']['selection'] is not None
            requests=[json.loads(line) for line in Path('requests.jsonl').read_text().splitlines()]
            last_prepare=next(r for r in reversed(requests) if r['operation']=='restore_prepare')
            assert request['parameters']['selection']==last_prepare['parameters']['selection']
            assert request['parameters']['expected_prepared_plan_id']==(session_id if session else 'a'*64)
            if mode=='ux':
                ux=json.loads(Path('ux.json').read_text())
                if ux.get('interrupted'): os._exit(9)
                before=ux.get('before',False)
                records=[]; operations=[]
                if not before:
                    for index in range(104):
                        operations.append(dict(record_id='o:'+str(index),domain='workspace-folders',item_id=str(index+1),action='install',outcome='success'))
                        records.append(dict(record_id='v:'+str(index),domain='workspace-folders',item_id=str(index+1),predicate='exists',conformity='verified'))
                    if ux.get('layout'):
                        for domain in ['homebrew-casks','homebrew-packages','vscode-extensions']:
                            for index in range(4):
                                operations.append(dict(record_id=domain+':o:'+str(index),domain=domain,item_id=str(index+1),action='install',outcome='success'))
                                records.append(dict(record_id=domain+':v:'+str(index),domain=domain,item_id=str(index+1),predicate='installed',conformity='verified'))
                    for index in range(15):
                        records.append(dict(record_id='mas:'+str(index),domain='app-store',item_id=str(425264550+index),predicate='installed',conformity='mismatch' if index<ux.get('manual',0) else 'verified'))
                if ux.get('partial'):
                    operations.append(dict(domain='homebrew-casks',item_id='1',action='install',outcome='skipped',reason='cask_execution_requirements_unsupported'))
                    records.append(dict(domain='homebrew-casks',item_id='1',predicate='payload',conformity='mismatch'))
                launcher=dict(record_id='launcher:0',domain='launcher',item_id='scope',action='restore',outcome='failure',reason='launcher_destination_conflict')
                if ux.get('launcher'):
                    operations.append(launcher)
                    emit('operation_record',launcher)
                    emit('execution_event',dict(domain='launcher',item_id='scope',state='failed',reason='module_failed'))
                details=dict(status='incomplete' if ux.get('unknown') else 'complete',operation_records=operations,verification_records=records,module_outcomes=[],diagnostics=[])
                if ux.get('launcher'):
                    details['module_outcomes']=[dict(domain='launcher',item_id='scope',state='failed',reason='module_failed')]
                    details['diagnostics']=[dict(record_id='launcher:0',code='operation_failed',severity='error')]
                mismatch=ux.get('manual',0)+(1 if ux.get('partial') else 0)
                verification=dict(status='not_run' if before else 'complete',verdict='incomplete' if before else 'differences_detected' if mismatch else 'selected_requirements_verified',verified_count=0 if before else 119-ux.get('manual',0)+(12 if ux.get('layout') else 0),mismatch_count=mismatch,unverified_count=0,unresolved_count=0,warning_count=0,error_count=0,details=details)
                failed=before or ux.get('launcher') or ux.get('partial') or ux.get('stopped')
                result=dict(prepared_plan_id='a'*64,execution_status='failed' if failed else 'completed',target_mutation_may_have_started=not before,verification=verification,warning_count=1 if ux.get('unknown') else 0,error_count=1 if failed else 0,independent_work_completed=bool(ux.get('partial')))
                if failed:
                    result['code']='cancelled' if ux.get('stopped') else 'bootstrap_failed'
                    emit('failed',result);sys.exit(130 if ux.get('stopped') else 2)
                emit('result',result);emit('completed');sys.exit(0)
            if mode=='execute_missing_result': emit('completed'); sys.exit(0)
            if mode in ('execute_partial','execute_item_skip','execute_ownership_skip'):
                emit('phase_started',dict(phase='bootstrap'))
                item_reason='cask_execution_requirements_unsupported' if mode in ('execute_item_skip','execute_ownership_skip') else 'item_stalled_timeout'
                item_outcome='skipped' if mode in ('execute_item_skip','execute_ownership_skip') else 'failure'
                emit('operation_record',dict(domain='homebrew-casks',item_id=('2' if mode=='execute_ownership_skip' else '1'),action='install',outcome=item_outcome,reason=item_reason))
                details=dict(status='complete',operation_records=[dict(domain='homebrew-casks',item_id=('2' if mode=='execute_ownership_skip' else '1'),action='install',outcome=item_outcome,reason=item_reason),dict(domain='vscode-extensions',item_id=('2' if mode=='execute_ownership_skip' else '1'),action='install',outcome='success',reason=None)],verification_records=[dict(domain='homebrew-casks',item_id=('2' if mode=='execute_ownership_skip' else '1'),conformity='mismatch'),dict(domain='vscode-extensions',item_id=('2' if mode=='execute_ownership_skip' else '1'),conformity='verified')])
                verification=dict(status='complete',verdict='differences_detected',mismatch_count=1,unverified_count=0,unresolved_count=0,warning_count=0,error_count=1,details=details)
                emit('failed',dict(code='bootstrap_failed',prepared_plan_id='a'*64,target_mutation_may_have_started=True,independent_work_completed=True,verification=verification)); sys.exit(2)
            if mode=='execute_interrupted':
                emit('phase_started',dict(phase='bootstrap')); os._exit(9)
            if mode in ('execute_stop_before','execute_stop_after'):
                mutation=mode=='execute_stop_after'
                def stop(signum,frame):
                    emit('failed',dict(code='cancelled',target_mutation_may_have_started=mutation)); sys.exit(130)
                signal.signal(signal.SIGTERM,stop)
                emit('phase_started',dict(phase='bootstrap' if mutation else 'preparation'))
                time.sleep(10)
            if mode in ('execute_fail_before','execute_fail_after','execute_stale'):
                failed=dict(code='stale_plan' if mode=='execute_stale' else 'bootstrap_failed',target_mutation_may_have_started=mode=='execute_fail_after')
                if mode=='execute_stale': failed['plan_validation']=dict(check='prepared_plan_id',expected_id=request['parameters']['expected_prepared_plan_id'],recomputed_id='d'*64,components={'plan':'d'*64})
                if mode=='execute_stale': failed.update(execution_status='failed_before_mutation',bootstrap_status='not_started',verification=dict(status='not_run'))
                emit('failed',failed); sys.exit(2)
            emit('phase_started',dict(phase='bootstrap'))
            if mode=='session-evidence-window':
                emit('verification_record',dict(domain='homebrew-packages',item_id='1',predicate='installed',conformity='verified'))
                for index in range(300): emit('execution_event',dict(domain='verification',item_id='scope',state='started'))
            emit('execution_event',dict(domain='homebrew-packages',item_id='first',state='changed',action='install'))
            verification=dict(status='complete',verdict='selected_requirements_verified',mismatch_count=0,unverified_count=0,unresolved_count=0,warning_count=0,error_count=0,details={})
            if mode in ('assisted_missing','assisted_launcher_failure'):
                manual_selection=last_prepare['parameters']['selection']
                manual_count=4 if 'app-store' in manual_selection['categories'] else len(manual_selection['items'].get('app-store',[]))
                records=[dict(domain='app-store',item_id=str(425264550+i),predicate='installed',conformity='mismatch') for i in range(manual_count)]
                records += [dict(domain='workspace-folders',item_id=str(i+1),predicate='exists',conformity='verified') for i in range(4)]
                verification.update(verdict='differences_detected',verified_count=4,mismatch_count=manual_count,details=dict(verification_records=records))
            if mode=='assisted_deduplicated':
                records=[dict(domain='app-store',item_id=str(425264550+i),predicate='installed',conformity='mismatch') for i in range(1,4)]
                records += [dict(domain=domain,item_id=str(i+1),predicate='installed',conformity='verified') for domain in ['homebrew-casks','workspace-folders'] for i in range(4)]
                verification.update(verdict='differences_detected',verified_count=8,mismatch_count=3,details=dict(verification_records=records))
            if mode=='execute_attention': verification['unverified_count']=1; verification['verdict']='incomplete'
            result=dict(prepared_plan_id=session_id if session else 'a'*64,execution_status='completed',target_mutation_may_have_started=True,publication_occurred=True,verification=verification,warning_count=0,error_count=0)
            if mode=='assisted_launcher_failure':
                verification['details']['operation_records']=[dict(domain='launcher',item_id='scope',action='restore',outcome='failure',reason='launcher_destination_conflict')]
                result.update(code='bootstrap_failed',execution_status='failed',error_count=1)
                emit('failed',result); sys.exit(2)
        else:
            Path('MUTATION_ATTEMPT').write_text(operation)
            emit('failed',dict(code='forbidden_operation')); sys.exit(2)
        emit('result',result); emit('completed')
        """, core.appendingPathComponent("fixture.py"))
        let macOS = ["finder", "dock", "windows", "keyboard", "trackpad", "screenshots"].map { "macos-" + $0 }
        let applications = ["homebrew-casks", "app-store", "vscode-extensions"]
        let workspace = ["workspace-folders", "git-repositories"]
        let itemDomains = ["homebrew-packages"] + applications + workspace
        var inventory: [[String: Any]] = itemDomains.map { domain in
            ["domain": domain, "label": Self.finalUXFixtures ? CaptureCategory.title(for: domain) : "Core label " + domain, "selection_mode": "items", "availability": "available", "reason": NSNull(),
             "items": (1...(Self.finalUXFixtures ? (CommandLine.arguments.contains("--preview-appstore-layout-only") ? (["homebrew-casks": 16, "homebrew-packages": 21, "vscode-extensions": 24, "app-store": 15][domain] ?? 4) : (domain == "workspace-folders" ? 104 : domain == "app-store" ? 15 : 4)) : 4)).map { ["item_id": "stable-\(domain)-\($0)", "label": "Core item \($0)"] }]
        }
        inventory += macOS.map { ["domain": $0, "label": "Core label " + $0, "selection_mode": "category", "availability": "available", "reason": NSNull(), "items": []] }
        inventory += [["domain": "ssh-configuration", "label": "SSH Configuration", "selection_mode": "category", "availability": "available", "reason": NSNull(), "items": []],
                      ["domain": "unavailable-area", "label": "Unavailable area", "selection_mode": "category", "availability": "unavailable", "reason": "no_selectable_content", "items": []]]
        inventory.append(["domain": "empty-items", "label": "Empty items", "selection_mode": "items", "availability": "available", "reason": NSNull(), "items": []])
        let groups: [[String: Any]] = [["id": "Applications", "domains": applications], ["id": "Workspace", "domains": workspace],
                                      ["id": "macOS Settings", "domains": macOS], ["id": "SSH Configuration", "domains": ["ssh-configuration"]], ["id": "Other Core group", "domains": ["homebrew-packages", "unavailable-area", "empty-items"]]]
        if CommandLine.arguments.contains("--restore-macos-only") {
            for index in inventory.indices where macOS.contains(inventory[index]["domain"] as? String ?? "") {
                inventory[index]["label"] = CaptureCategory.title(for: inventory[index]["domain"] as! String)
            }
        }
        let inspection: [String: Any] = ["format_version": 1, "selected_categories": macOS + ["ssh-configuration"], "selected_item_counts": [:], "secure_component": !Self.finalUXFixtures,
                                        "restore_selection": ["groups": groups, "inventory": inventory]]
        try JSONSerialization.data(withJSONObject: inspection).write(to: core.appendingPathComponent("inspection.json"))
        let runtime = CoreRuntime()
        let model = RestoreModel(runtime: runtime, location: CoreLocation(root: core, python: python, home: root, temporaryBase: root, toolDirectories: []))
        let source = root.appendingPathComponent("sample.mbt")
        model.choose(source); await model.waitForCompletion()
        precondition(model.state == .review && model.areas.count == inventory.count && model.groups.count == 5 && model.bulkState == .all)
        precondition(model.selectionSummary == "Everything selected" && model.canPreview)
        precondition(model.inspection?.secureComponent == !Self.finalUXFixtures && model.selectedAreaCount == 13)
        if Self.finalUXFixtures {
            model.toggleAll()
            model.selectArea("workspace-folders", included: true)
            model.selectArea("app-store", included: true)
            let chosen = model.selection
            let included = RestorePresentationSection.includedAreas(model.areas)
            let sections = RestorePresentationSection.visible(model.groups, inventory: included)
            let displayed = sections.flatMap { $0.areas(in: included) }
            precondition(sections.first?.areas(in: included).map(\.id) == ["app-store", "homebrew-casks", "homebrew-packages", "vscode-extensions"])
            precondition(displayed.filter { $0.id == "app-store" }.count == 1)
            precondition(Set(displayed.map(\.id)) == Set(included.map(\.id)))
            let store = model.areas.first { $0.id == "app-store" }!
            model.selectItem("app-store", item: store.items[0].id, included: false)
            precondition(model.selectionState(store) == .mixed && model.selectedItems["app-store"]?.count == store.items.count - 1)
            model.selectItem("app-store", item: store.items[0].id, included: true)
            precondition(model.selectionState(store) == .all && model.selection == chosen)
            try render(model, runtime, state: "final-selection")
            if CommandLine.arguments.contains("--preview-appstore-layout-only") {
                model.selectArea("workspace-folders", included: false)
                for id in ["homebrew-casks", "homebrew-packages", "vscode-extensions"] { model.selectArea(id, included: true) }
                let selected = model.selection
                for (name, fixture) in [("installed", ["manual": 0]), ("missing", ["manual": 1]), ("unverified", ["unverified": 1])] {
                    var values = fixture; values["layout_preview"] = 1
                    try JSONSerialization.data(withJSONObject: values).write(to: core.appendingPathComponent("ux.json"))
                    try write("ux", core.appendingPathComponent("mode"))
                    model.refreshPreview(); await model.waitForCompletion()
                    precondition(model.state == .preview && model.canRebuild && model.selection == selected)
                    let tasks = RestoreTaskPresentation(preview: model.preview!, plan: model.preparation!)
                    let casks = tasks.automaticDomains.first { $0.id == "homebrew-casks" }!
                    precondition(casks.items.filter { $0.state == .attention }.count == 1)
                    precondition(casks.items.filter { $0.state == .planned }.count == 1)
                    precondition(casks.items.filter { $0.state == .matching }.count == 14)
                    if name == "installed" { try render(model, runtime, state: "layout-expanded-preview", expanded: true) }
                    model.reviewAppStore()
                    precondition(model.showingAppStore && model.appStorePresentation.items.count == 15)
                    precondition(model.appStorePresentation.pending.count == (name == "installed" ? 0 : 1))
                    try render(model, runtime, state: "layout-store-" + name)
                    if name == "unverified" {
                        model.refreshAppStore(); await model.waitForCompletion()
                        precondition(model.showingAppStore && model.state == .preview && model.selection == selected)
                    }
                    model.closeAppStore()
                    precondition(model.selection == selected && model.state == .preview)
                }
                print("PASS: expanded Preview 1 attention/1 planned/14 matching plus 21 packages and 24 extensions; immediate installed/missing/unverified App Store lists; navigation/selection preserved")
                return
            }
            if CommandLine.arguments.contains("--selection-preview-only") {
                for id in ["homebrew-casks", "homebrew-packages", "vscode-extensions"] { model.selectArea(id, included: true) }
                let selected = model.selection
                try JSONSerialization.data(withJSONObject: ["manual": 1, "layout": true]).write(to: core.appendingPathComponent("ux.json"))
                try write("ux", core.appendingPathComponent("mode"))
                model.refreshPreview(); await model.waitForCompletion()
                precondition(model.state == .preview && model.canRebuild)
                try render(model, runtime, state: "layout-preview")
                model.reviewAppStore(); model.closeAppStore()
                precondition(model.selection == selected)
                model.back()
                precondition(model.state == .review && model.selection == selected)
                print("PASS: App Store first in Selection group; item selection and navigation preserved; Preview hierarchy rendered at 420/785/985 pt")
                return
            }
            let scenarios: [(String, [String: Any], RestoreExecutionPresentation.Outcome)] = [
                ("successful", [:], .clean),
                ("launcher-failed", ["launcher": true], .failedAfterMutation),
                ("launcher-plus-manual", ["launcher": true, "manual": 1], .failedAfterMutation),
                ("manual-only-outstanding", ["manual": 1], .attention),
                ("all-appstore-installed", [:], .clean),
                ("failed-before-mutation", ["before": true], .failedBeforeMutation),
                ("interrupted", ["interrupted": true], .interrupted),
                ("incomplete-evidence", ["unknown": true], .attention),
                ("partial", ["partial": true], .partial),
                ("stopped", ["stopped": true], .stoppedAfterMutation)]
            for (name, fixture, expected) in scenarios {
                if model.state == .result { model.checkCurrentState(); await model.waitForCompletion() }
                model.selectArea("homebrew-casks", included: false)
                if fixture["partial"] as? Bool == true { model.selectItem("homebrew-casks", item: "stable-homebrew-casks-1", included: true) }
                try JSONSerialization.data(withJSONObject: fixture).write(to: core.appendingPathComponent("ux.json"))
                try write("ux", core.appendingPathComponent("mode"))
                model.refreshPreview(); await model.waitForCompletion()
                precondition(model.state == .preview && model.canRebuild)
                if name == "launcher-plus-manual" { try render(model, runtime, state: "final-preview") }
                model.requestRebuild(); model.confirmRebuild(); await model.waitForCompletion()
                precondition(model.state == .result && model.executionResult?.outcome == expected, name)
                let result = model.executionResult!
                let tasks = RestoreTaskPresentation(preview: model.executionPreview!, plan: model.executionPlan!, events: model.categoryPresentationEvents,
                    result: result, executing: true, operationProgress: true)
                let summary = RestoreResultSummary(domains: tasks.automaticDomains, result: result, appStore: tasks.appStore)
                precondition(summary.successfulCount == (["failed-before-mutation", "interrupted"].contains(name) ? 0 : 104), name)
                if name == "launcher-plus-manual" {
                    precondition(summary.attentionCount == 2 && summary.automaticAttentionCount == 1 && summary.manualAttentionCount == 1)
                    precondition(summary.issues.map(\.id) == ["launcher:scope", "app-store"])
                    precondition(summary.attentionCaption == "1 restore issue · 1 app to install")
                    precondition(RestoreResultContent.message(result: result, summary: summary) == "Macseed Launcher could not be configured.")
                    var independent = summary
                    independent.independentIssueTitles = ["Secure preparation"]
                    precondition(RestoreResultContent.message(result: result, summary: independent)
                        == "Macseed Launcher could not be configured; Secure preparation needs review.")
                }
                if name == "launcher-failed" {
                    precondition(summary.attentionCount == 1)
                    precondition(RestoreVerificationSummary(payload: result.structuredEvidence).requirementsTitle == "Verified",
                        "Execution failure is independent from selected requirement conformity")
                }
                if name == "manual-only-outstanding" {
                    precondition(summary.attentionCount == 1 && summary.automaticAttentionCount == 0)
                    precondition(summary.issues.count == 1 && summary.issues[0].appStore)
                    precondition(RestoreResultContent.heading(outcome: result.outcome, original: result.title, pendingManualWork: true, automaticProblems: false) == "Rebuild Completed")
                }
                if expected == .clean { precondition(summary.issues.isEmpty && summary.attentionCount == 0) }
                if ["failed-before-mutation", "interrupted", "incomplete-evidence"].contains(name) { precondition(summary.attentionCount == nil) }
                if name == "failed-before-mutation" {
                    precondition(RestoreVerificationSummary(payload: result.structuredEvidence).requirementsTitle == "Not confirmed")
                }
                if name == "stopped" { precondition(summary.issues.isEmpty, "Stopping is not an invented failed requirement") }
                if name == "partial" { precondition(summary.issues.filter { $0.id.hasPrefix("homebrew-casks:") }.count == 1) }
                let snapshot = model.selection
                try render(model, runtime, state: "final-" + name)
                precondition(model.selection == snapshot)
                print("PASS: consolidated Result \(name)")
            }
            model.checkCurrentState(); await model.waitForCompletion()
            for id in ["homebrew-casks", "homebrew-packages", "vscode-extensions"] { model.selectArea(id, included: true) }
            try JSONSerialization.data(withJSONObject: ["manual": 1, "launcher": true, "layout": true]).write(to: core.appendingPathComponent("ux.json"))
            model.refreshPreview(); await model.waitForCompletion()
            try render(model, runtime, state: "layout-preview")
            model.requestRebuild(); model.confirmRebuild(); await model.waitForCompletion()
            precondition(model.state == .result && model.executionResult?.outcome == .failedAfterMutation)
            try render(model, runtime, state: "layout-result")
            for id in ["homebrew-casks", "homebrew-packages", "vscode-extensions"] { model.selectArea(id, included: false) }
            model.selectArea("workspace-folders", included: false)
            try JSONSerialization.data(withJSONObject: ["manual": 1]).write(to: core.appendingPathComponent("ux.json"))
            model.refreshPreview(); await model.waitForCompletion()
            precondition(model.state == .preview && !model.canRebuild && !model.hasAutomaticSelection)
            let before = model.selection
            model.reviewAppStore(); model.closeAppStore()
            precondition(model.selection == before && model.source == source)
            try render(model, runtime, state: "final-appstore-only")
            precondition(chosen.items.isEmpty)
            print("PASS: App Store-only selection, navigation, original scope and fixed footer")
            return
        }
        if CommandLine.arguments.contains("--assisted-appstore-only") {
            model.toggleAll()
            model.selectArea("app-store", included: true)
            for (mode, expected) in [("assisted_missing", AssistedAppStoreItem.Status.missing),
                                     ("assisted_installed", .installed), ("assisted_unverified", .unverified)] {
                try write(mode, core.appendingPathComponent("mode"))
                model.refreshPreview(); await model.waitForCompletion()
                precondition(model.state == .preview && model.ready && !model.canRebuild && !model.hasAutomaticSelection)
                let plan = model.preparation!, selection = model.selection
                let source = model.source, inspection = model.inspection
                let requestBytes = try Data(contentsOf: core.appendingPathComponent("requests.jsonl"))
                model.reviewAppStore()
                precondition(model.showingAppStore && model.appStoreSelected)
                precondition(model.appStorePresentation.items.count == 4)
                try render(model, runtime, state: "screen-" + mode)
                model.closeAppStore()
                precondition(!model.showingAppStore && model.preparation?.preparedPlanID == plan.preparedPlanID)
                precondition(model.selection == selection && model.source == source && model.inspection?.restoreSelection?.inventory.count == inspection?.restoreSelection?.inventory.count)
                precondition(try! Data(contentsOf: core.appendingPathComponent("requests.jsonl")) == requestBytes)
                model.reviewAppStore(); model.refreshAppStore(); await model.waitForCompletion()
                precondition(model.showingAppStore && model.selection == selection && model.source == source)
                precondition(model.appStorePresentation.items.allSatisfy { $0.assistedAppStore?.status == expected })
                model.closeAppStore()
                let items = RestoreTaskPresentation(preview: model.preview!, plan: plan).domains.flatMap(\.items)
                precondition(items.allSatisfy { $0.assistedAppStore?.status == expected })
                precondition(items.allSatisfy { ($0.assistedAppStore?.productURL != nil) == (expected != .installed) })
                if let url = items.first?.assistedAppStore?.productURL {
                    let requests = try Data(contentsOf: core.appendingPathComponent("requests.jsonl"))
                    let evidence = runtime.events.map(\.data)
                    let rows = plan.plan.map { [$0.itemID, $0.action, $0.disposition, $0.reason ?? ""] }
                    for opened in [true, false] {
                        precondition(AppStoreProductButton.open(url, using: { _ in opened }) == opened)
                        precondition(model.preparation?.preparedPlanID == plan.preparedPlanID && model.selection == selection)
                        precondition(model.preparation?.plan.map { [$0.itemID, $0.action, $0.disposition, $0.reason ?? ""] } == rows)
                        precondition(runtime.events.map(\.data) == evidence)
                        precondition(try! Data(contentsOf: core.appendingPathComponent("requests.jsonl")) == requests)
                        let after = RestoreTaskPresentation(preview: model.preview!, plan: model.preparation!).domains.flatMap(\.items)
                        precondition(after.allSatisfy { $0.assistedAppStore?.status == expected })
                    }
                }
                try render(model, runtime, state: mode, expanded: true)
                model.selectArea("workspace-folders", included: true)
                model.refreshPreview(); await model.waitForCompletion()
                precondition(model.ready && model.canRebuild)
                precondition(model.hasAutomaticSelection)
                let mixed = RestoreTaskPresentation(preview: model.preview!, plan: model.preparation!)
                precondition(mixed.automaticDomains.map(\.id) == ["workspace-folders"])
                precondition(mixed.counters.count == 1 && mixed.counters[0].state == .planned && mixed.counters[0].count == 1)
                precondition(mixed.automaticDomains.flatMap(\.items).count == 4 && mixed.appStore.items.count == 4)
                precondition(RestorePreviewMetrics.counts(mixed.automaticDomains).changes == 4)
                precondition(RestorePreviewMetrics.counts(mixed.automaticDomains).attention == 0)
                precondition(mixed.automaticAttentionCount == 0)
                precondition(model.confirmationMessages.count == (expected == .installed ? 0 : 1))
                precondition(model.confirmationMessages.allSatisfy { $0.contains("App Store") && !$0.contains("automatic requirements need attention") })
                var scopePlan = model.preparation!
                scopePlan.scopeWarnings = ["homebrew-packages"]
                precondition(mixed.confirmationMessages(scopePlan).contains { $0.contains("category-level warning") })
                model.selectArea("workspace-folders", included: false)
            }
            let requests = try String(contentsOf: core.appendingPathComponent("requests.jsonl"))
            precondition(!requests.contains("restore_execute"))
            // Simulated execution only: automatic outcomes and final manual evidence stay independent.
            try write("assisted_missing", core.appendingPathComponent("mode"))
            model.selectArea("workspace-folders", included: true)
            model.refreshPreview(); await model.waitForCompletion()
            model.requestRebuild(); model.confirmRebuild(); await model.waitForCompletion()
            precondition(model.state == .result && model.executionResult?.outcome == .attention)
            let result = model.executionResult!, selection = model.selection, source = model.source
            let finalTasks = RestoreTaskPresentation(preview: model.executionPreview!, plan: model.executionPlan!,
                events: model.categoryPresentationEvents, result: result, executing: true, operationProgress: true)
            precondition(finalTasks.appStore.missingCount == 4)
            precondition(finalTasks.automaticDomains.map(\.id) == ["workspace-folders"])
            precondition(RestoreResultSummary(domains: finalTasks.automaticDomains).cards.first { $0.id == "Success" }?.count == 4)
            precondition(RestoreVerificationSummary(payload: result.structuredEvidence).overallResult(outcome: result.outcome) == "Needs Attention")
            model.reviewAppStore()
            precondition(model.appStorePresentation.missingCount == 4)
            model.closeAppStore()
            precondition(model.state == .result && model.executionResult?.operationID == result.operationID)
            try render(model, runtime, state: "assisted-result")
            model.reviewAppStore()
            try write("assisted_installed", core.appendingPathComponent("mode"))
            model.refreshAppStore(); await model.waitForCompletion()
            precondition(model.state == .preview && model.showingAppStore && model.appStorePresentation.allInstalled)
            precondition(model.selection == selection && model.source == source)
            precondition(model.executionResult == nil)
            model.closeAppStore()
            model.selectItem("app-store", item: "stable-app-store-4", included: false)
            let partialSelection = model.selection
            model.refreshPreview(); await model.waitForCompletion()
            model.reviewAppStore(); model.refreshAppStore(); await model.waitForCompletion()
            precondition(model.selection == partialSelection && model.appStorePresentation.items.count == 3)
            precondition(model.appStorePresentation.allInstalled)
            // Failed refresh must not continue displaying confirmed installation from the prior Preview.
            try write("prepare_failure", core.appendingPathComponent("mode"))
            model.refreshAppStore(); await model.waitForCompletion()
            precondition(model.state == .failed && model.appStorePresentation.items.isEmpty && !model.appStorePresentation.allInstalled)
            precondition(model.selection == partialSelection && model.source == source)
            model.closeAppStore()
            precondition(!model.showingAppStore)
            try write("assisted_launcher_failure", core.appendingPathComponent("mode"))
            model.refreshPreview(); await model.waitForCompletion()
            model.requestRebuild(); model.confirmRebuild(); await model.waitForCompletion()
            precondition(model.state == .result && model.executionResult?.outcome == .failedAfterMutation)
            let failed = model.executionResult!
            precondition(failed.globalProblemMessages(knownDomains: ["app-store", "workspace-folders"]).contains { $0.contains("Macseed Launcher could not be restored") && $0.contains("preserved") })
            precondition(model.appStorePresentation.missingCount == 3)
            try render(model, runtime, state: "launcher-failed-manual-pending")
            // Fresh Prepare after Result must keep requested IDs while displaying
            // only Core's effective scope. The mock supplies the same confirmed
            // decision; Core integration tests exercise real offline cache reuse.
            model.checkCurrentState(); await model.waitForCompletion()
            model.selectArea("homebrew-casks", included: true)
            model.selectArea("app-store", included: true)
            try write("assisted_deduplicated", core.appendingPathComponent("mode"))
            model.refreshPreview(); await model.waitForCompletion()
            let requested = model.canonicalSelection
            precondition(model.preparation?.selection == requested && model.appStorePresentation.items.count == 3)
            precondition(model.selectedItems["app-store"]?.count == 4)
            let effective = model.preparation?.effectiveSelection
            model.requestRebuild(); model.confirmRebuild(); await model.waitForCompletion()
            precondition(model.state == .result && model.executionPlan?.effectiveSelection == effective)
            precondition(model.appStorePresentation.items.count == 3 && model.canonicalSelection == requested)
            model.reviewAppStore(); model.refreshAppStore(); await model.waitForCompletion()
            precondition(model.state == .preview && model.showingAppStore)
            precondition(model.preparation?.effectiveSelection == effective && model.canonicalSelection == requested)
            precondition(model.appStorePresentation.items.count == 3)
            model.closeAppStore()
            model.selectArea("homebrew-casks", included: false)
            model.refreshPreview(); await model.waitForCompletion()
            precondition(model.preparation?.effectiveSelection == nil && model.appStorePresentation.items.count == 4)
            print("PASS: Result Refresh preserves requested IDs and effective App Store scope; App Store-only restores the full scope")
            print("PASS: Dedicated App Store navigation, refresh, independent automatic outcomes, truthful verification and failed recheck")
            return
        }
        if CommandLine.arguments.contains("--independent-ownership-only") {
            try write("ownership_conflict", core.appendingPathComponent("mode"))
            model.refreshPreview(); await model.waitForCompletion()
            precondition(model.state == .preview && model.canRebuild && model.ready)
            let plan = model.preparation!
            precondition(plan.plan.filter { $0.disposition == "planned" }.count == 4)
            let blocked = plan.plan.first { $0.reason == "cask_target_conflict" }!
            precondition(plan.isItemLocalSkip(blocked))
            let item = model.preview!.categories.flatMap(\.items).first { $0.reason == "cask_target_conflict" }!
            precondition(item.action.contains("ownership") && !item.action.contains("System Events"))
            let tasks = RestoreTaskPresentation(preview: model.preview!, plan: plan, events: [])
            let task = tasks.domains.flatMap(\.items).first { $0.item.reason == "cask_target_conflict" }!
            precondition(task.item.action == item.action && task.diagnostic?.technicalDescription.contains("ownership_unproven") == true)
            model.requestRebuild(); precondition(model.state == .confirming)
            try write("execute_ownership_skip", core.appendingPathComponent("mode"))
            model.confirmRebuild(); await model.waitForCompletion()
            precondition(model.executionResult?.outcome == .partial)
            model.choose(source); await model.waitForCompletion()
            try write("attention", core.appendingPathComponent("mode"))
            model.refreshPreview(); await model.waitForCompletion()
            precondition(!model.canRebuild)
            print("PASS: four ready operations plus ownership skip, primary diagnostic, partial Result and global blocker")
            return
        }
        if CommandLine.arguments.contains("--pkg-preparation-only") || CommandLine.arguments.contains("--fix-issues-only") {
            try write("pkg-preparation", core.appendingPathComponent("mode"))
            model.refreshPreview(); await model.waitForCompletion()
            precondition(model.state == .preview && model.installerPreparationRows.count == 1)
            let plan = model.preparation!.preparedPlanID
            let requests = core.appendingPathComponent("requests.jsonl")
            let before = try Data(contentsOf: requests)
            await model.checkPrerequisites()
            precondition(model.installerConsent && model.preparation!.preparedPlanID == plan)
            let unchanged = try Data(contentsOf: requests); precondition(unchanged == before)
            model.cancelInstallerPreparation()
            precondition(!model.installerConsent && model.preparation!.preparedPlanID == plan)
            let refused = try Data(contentsOf: requests); precondition(refused == before)
            await model.checkPrerequisites()
            model.confirmInstallerPreparation(); await model.waitForCompletion()
            precondition(model.state == .preview && model.preparation!.preparedPlanID == String(repeating: "d", count: 64))
            precondition(model.installerPreparationRows.isEmpty && !model.installerConsent)
            let sent = try String(contentsOf: requests).split(separator: "\n").map {
                try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
            }
            precondition(sent.allSatisfy { $0["operation"] as? String != "restore_execute" })
            precondition((sent.last!["parameters"] as! [String: Any])["installer_preparations"] as? [String] == [String(repeating: "c", count: 64)])
            model.refreshPreview(); await model.waitForCompletion()
            await model.checkPrerequisites()
            let recorded = try Data(contentsOf: requests)
            model.selectItem("homebrew-casks", item: "stable-homebrew-casks-1", included: false)
            model.confirmInstallerPreparation()
            let stale = try Data(contentsOf: requests); precondition(stale == recorded && !model.installerConsent)
            // One Fix Issues action processes Automation first, then a separate
            // explicit PKG decision. Neither choice grants the other permission.
            for outcome in [RestoreAutomationPermission.Outcome.available, .denied, .unavailable] {
                for approve in [false, true] {
                    try? FileManager.default.removeItem(at: core.appendingPathComponent("automation-fixed"))
                    model.choose(source); await model.waitForCompletion()
                    try write("pkg-and-automation", core.appendingPathComponent("mode"))
                    model.refreshPreview(); await model.waitForCompletion()
                    let retainedID = model.preparation!.preparedPlanID
                    let beforeFix = try Data(contentsOf: requests)
                    var permissionCalls = 0
                    await model.checkPrerequisites(permission: {
                        permissionCalls += 1
                        if outcome == .available { try! write("yes", core.appendingPathComponent("automation-fixed")) }
                        return outcome
                    })
                    precondition(permissionCalls == 1 && model.installerConsent && model.preparation!.preparedPlanID == retainedID)
                    let pending = try Data(contentsOf: requests); precondition(pending == beforeFix)
                    if approve { model.confirmInstallerPreparation() } else { model.cancelInstallerPreparation() }
                    await model.waitForCompletion()
                    precondition(model.state == .preview && !model.installerConsent)
                    precondition(model.installerPreparationRows.isEmpty == approve)
                    precondition(model.preparation!.readiness.conditions.contains { $0.diagnostic?.automationRequirement == true } == (outcome != .available))
                    precondition((model.prerequisiteRetryMessage != nil) == (outcome != .available))
                    let last = try String(contentsOf: requests).split(separator: "\n").last!
                    let request = try JSONSerialization.jsonObject(with: Data(last.utf8)) as! [String: Any]
                    let ids = (request["parameters"] as! [String: Any])["installer_preparations"] as? [String]
                    precondition(ids == (approve ? [String(repeating: "c", count: 64)] : nil))
                }
            }
            model.choose(source); await model.waitForCompletion()
            try write("automation", core.appendingPathComponent("mode"))
            model.refreshPreview(); await model.waitForCompletion()
            precondition(model.installerPreparationRows.isEmpty)
            await model.checkPrerequisites(permission: {
                try! write("clean", core.appendingPathComponent("mode")); return .available
            })
            await model.waitForCompletion()
            precondition(model.state == .preview && model.preparation!.readiness.ready && !model.installerConsent)
            let allRequests = try String(contentsOf: requests).split(separator: "\n")
            precondition(allRequests.allSatisfy { !$0.contains("restore_execute") })
            print("PASS: Unified fixes: Automation, PKG consent/refusal, both outcomes, errors, stale selection and no Execute")
            return
        }
        if CommandLine.arguments.contains("--restore-macos-only") {
            let group = model.groups.first { $0.id == "macOS Settings" }!
            let otherSelection = Set(model.selection.categories).subtracting(macOS)
            for id in macOS {
                precondition(model.areas.first { $0.id == id }!.selectionMode == "category")
                model.selectArea(id, included: false)
                precondition(model.groupState(group) == .mixed && !model.selection.categories.contains(id))
                precondition(Set(model.selection.categories).intersection(macOS) == Set(macOS).subtracting([id]))
                model.selectArea(id, included: true)
                precondition(model.groupState(group) == .all)
            }
            model.selectGroup(group, included: false)
            precondition(model.groupState(group) == .none && Set(model.selection.categories) == otherSelection)
            model.selectGroup(group, included: true)
            model.refreshPreview(); await model.waitForCompletion()
            precondition(model.state == .preview && model.preparation != nil)
            model.selectArea("macos-finder", included: false)
            precondition(model.state == .review && model.preparation == nil && model.preview == nil)
            model.refreshPreview(); await model.waitForCompletion()
            precondition(model.state == .preview && !model.selection.categories.contains("macos-finder"))
            let lines = try String(contentsOf: core.appendingPathComponent("requests.jsonl")).split(separator: "\n")
            let requests = try lines.map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
            let prepare = requests.last { $0["operation"] as? String == "restore_prepare" }!
            let parameters = prepare["parameters"] as! [String: Any]
            let selected = parameters["selection"] as! [String: Any]
            precondition(Set(selected["categories"] as! [String]) == Set(model.selection.categories))
            model.requestRebuild(); model.confirmRebuild(); await model.waitForCompletion()
            precondition(model.state == .result)
            model.finish(); model.choose(source); await model.waitForCompletion()
            model.selectArea("macos-finder", included: false)
            _ = NSApplication.shared; NSApp.appearance = NSAppearance(named: .aqua)
            let content = RestoreMacOSSelectionView(model: model, group: group, expansion: .constant(true))
                .modifier(WorkspaceCardSurface()).padding(28).frame(width: 785).background(Color(nsColor: .windowBackgroundColor))
            // AppKit checkbox bridges require NSHostingView rather than ImageRenderer.
            let host = NSHostingView(rootView: content)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 785, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host
            host.frame = window.contentView!.bounds
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/Debug/Restore-macOS-Selection.png"))
            window.close()
            print("PASS: Six category selections, parent all/mixed/none, independent exclusion, Preview invalidation; native Selection render")
            return
        }
        if CommandLine.arguments.contains("--review-cancel-only") {
            let originalBytes = Data("disposable saved environment bytes".utf8)
            try originalBytes.write(to: source)
            let counts = ["matching": 1, "missing": 0, "differing": 0, "unverified": 0, "unsupported": 0,
                "unresolved": 0, "extra": 0, "unknown_difference": 0]
            let comparison: [String: Any] = ["read_only": true, "publication_occurred": false, "target_mutation_may_have_started": false,
                "comparison": ["status": "complete", "verdict": "no_differences_detected", "also_incomplete": false, "counts": counts],
                "comparison_records": [["record_id": "v:0", "domain": "homebrew-packages", "item_id": "bat", "comparison_kind": "matching", "support": "supported"]],
                "verification": ["status": "complete"], "extra": ["domains": [], "items": []],
                "records": ["status": "complete", "verification_records": [], "coverage_records": [], "operation_records": [], "diagnostics": []]]
            try JSONSerialization.data(withJSONObject: comparison).write(to: core.appendingPathComponent("comparison.json"))
            let status = EnvironmentStatusModel(runtime: runtime, location: CoreLocation(root: core, python: python, home: root, temporaryBase: root, toolDirectories: []))
            status.selectBundle(source); status.compare(); await status.waitForCompletion()
            precondition(status.state == .result && status.presentation?.counts["matching"] == 1)
            let reference = status.reference, statusCounts = status.presentation!.counts, statusID = status.operationID
            let log = core.appendingPathComponent("requests.jsonl")
            func requestBytes() -> Data { try! Data(contentsOf: log) }
            func unchangedStatusAndFile() {
                precondition(status.state == .result && status.reference == reference && status.operationID == statusID && status.presentation?.counts == statusCounts)
                precondition(try! Data(contentsOf: source) == originalBytes)
            }
            let originalRequests = requestBytes()
            precondition(model.canCancelReview && !model.reviewCancellationNeedsConfirmation)
            model.requestReviewCancellation()
            precondition(model.state == .choose && model.source == nil && model.inspection == nil)
            precondition(model.selectedCategories.isEmpty && model.selectedItems.isEmpty && model.preparation == nil && model.preview == nil)
            precondition(model.executionPlan == nil && model.executionPreview == nil && model.failure == nil && model.technicalReason == nil && model.prerequisiteRetryMessage == nil)
            precondition(!model.reviewCancelConfirmation && requestBytes() == originalRequests)
            unchangedStatusAndFile()
            model.choose(source)
            precondition(model.state == .inspecting && !model.canCancelReview)
            model.requestReviewCancellation(); model.confirmReviewCancellation()
            precondition(model.state == .inspecting && model.source == source)
            await model.waitForCompletion()
            precondition(model.state == .review && model.bulkState == .all && requestBytes() != originalRequests)
            let area = model.areas.first(where: \.selectable)!
            model.selectArea(area.id, included: false)
            let dirtySelection = model.selection, dirtyRequests = requestBytes()
            model.requestReviewCancellation()
            precondition(model.reviewCancelConfirmation && model.state == .review && model.selection == dirtySelection)
            model.keepReviewSelection()
            precondition(!model.reviewCancelConfirmation && model.selection == dirtySelection && model.source == source)
            model.confirmReviewCancellation()
            precondition(model.state == .review)
            model.requestReviewCancellation(); model.confirmReviewCancellation()
            precondition(model.state == .choose && model.source == nil && model.inspection == nil && requestBytes() == dirtyRequests)
            unchangedStatusAndFile()
            model.choose(source); await model.waitForCompletion()
            model.selectArea(area.id, included: false); model.requestReviewCancellation()
            precondition(model.reviewCancelConfirmation)
            model.choose(source); await model.waitForCompletion()
            precondition(!model.reviewCancelConfirmation && model.bulkState == .all)
            model.confirmReviewCancellation(); precondition(model.state == .review && model.source == source)
            // Shared-runtime activity also blocks Review cancellation, even when owned by Status.
            status.compare()
            precondition(runtime.isActive && !model.canCancelReview)
            model.requestReviewCancellation(); model.confirmReviewCancellation()
            precondition(model.state == .review && model.source == source)
            await status.waitForCompletion()
            let refreshedStatusID = status.operationID
            precondition(status.state == .result && status.reference == reference && status.presentation?.counts == statusCounts)
            model.refreshPreview()
            precondition(model.state == .preparing && !model.canCancelReview)
            model.requestReviewCancellation(); model.confirmReviewCancellation()
            await model.waitForCompletion()
            precondition(model.state == .preview && model.preparation != nil && model.reviewCancellationNeedsConfirmation)
            let preparedID = model.preparation!.preparedPlanID, previewRequests = requestBytes()
            model.requestReviewCancellation(); model.confirmReviewCancellation()
            precondition(model.state == .preview && model.preparation?.preparedPlanID == preparedID && requestBytes() == previewRequests)
            model.requestRebuild()
            precondition(model.state == .confirming && !model.canCancelReview)
            model.requestReviewCancellation(); model.confirmReviewCancellation()
            precondition(model.state == .confirming && model.preparation?.preparedPlanID == preparedID)
            model.cancelRebuildConfirmation()
            try write("execute_stop_before", core.appendingPathComponent("mode"))
            model.requestRebuild(); model.confirmRebuild()
            precondition(model.state == .rebuilding && !model.canCancelReview)
            model.requestReviewCancellation(); model.confirmReviewCancellation()
            precondition(model.state == .rebuilding && model.source == source)
            model.requestStop(); model.confirmStop(); await model.waitForCompletion()
            precondition(model.state == .result)
            let result = model.executionResult
            model.requestReviewCancellation(); model.confirmReviewCancellation()
            precondition(model.state == .result && model.executionResult?.title == result?.title)
            model.finish()
            try write("clean", core.appendingPathComponent("mode"))
            model.choose(source); await model.waitForCompletion()
            precondition(model.state == .review && model.bulkState == .all && model.preparation == nil && model.preview == nil)
            precondition(status.reference == reference && status.operationID == refreshedStatusID && status.state == .result && status.presentation?.counts == statusCounts)
            precondition(try! Data(contentsOf: source) == originalBytes)
            // Third and final control render: real Review view and fixed footer.
            _ = NSApplication.shared
            let content = VStack(spacing: 0) {
                ScrollView { RestoreView(model: model, runtime: runtime, showsSelectionActions: false).padding(28) }
                Divider()
                RestoreSelectionActions(status: model.selectionSummary, canPreview: model.canPreview, preview: {}, reviewModel: model)
                    .modifier(WorkspaceFooterPadding())
            }.frame(width: 785, height: 850).background(Color(nsColor: .windowBackgroundColor))
            let host = NSHostingView(rootView: content)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 785, height: 850), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; host.frame = window.contentView!.bounds
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/Debug/FinalCorrections-Restore-Selection.png"))
            window.close()
            print("PASS: Review Cancel/reset, discard/keep confirmation, session ownership, active/inspect/prepare/preview/confirm/rebuild/result guards, Bundle/Status preservation and fresh reinspection; one native render")
            return
        }
        if CommandLine.arguments.contains("--status-handoff-only") {
            let navigation = ProductionNavigation()
            navigation.task = .status
            let log = core.appendingPathComponent("requests.jsonl")
            func requests() -> [[String: Any]] {
                try! String(contentsOf: log).split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
            }
            let originalSelection = model.selection
            let originalRequests = requests().count
            navigation.reviewInRestore(source, restore: model)
            precondition(navigation.task == .restore && model.state == .review)
            precondition(requests().count == originalRequests)
            precondition(model.selection.categories == originalSelection.categories && model.selection.items == originalSelection.items)
            navigation.task = .status
            let replacement = root.appendingPathComponent("different.mbt")
            navigation.reviewInRestore(replacement, restore: model)
            precondition(navigation.pendingRestoreBundle == replacement && navigation.task == .status && model.source == source)
            navigation.cancelRestoreReplacement()
            precondition(model.source == source && model.state == .review && navigation.task == .status)
            navigation.reviewInRestore(replacement, restore: model)
            navigation.confirmRestoreReplacement(replacement, restore: model)
            precondition(navigation.task == .restore && model.source == replacement && model.state == .inspecting)
            let blockedSource = model.source
            navigation.task = .status
            navigation.reviewInRestore(source, restore: model)
            precondition(navigation.task == .status && model.source == blockedSource && navigation.pendingRestoreBundle == nil)
            await model.waitForCompletion()
            precondition(model.state == .review)
            let replacementRequests = requests().dropFirst(originalRequests)
            precondition(replacementRequests.map { $0["operation"] as! String } == ["capabilities", "bundle_inspect"])
            precondition((replacementRequests.last!["parameters"] as! [String: Any])["path"] as? String == replacement.path)
            try write("safe", core.appendingPathComponent("mode"))
            model.refreshPreview(); await model.waitForCompletion()
            precondition(model.state == .preview)
            let planID = model.preparation!.preparedPlanID
            let previewSelection = model.selection
            let previewRequests = requests().count
            navigation.reviewInRestore(replacement, restore: model)
            precondition(model.state == .preview && model.preparation?.preparedPlanID == planID)
            precondition(model.selection.categories == previewSelection.categories && model.selection.items == previewSelection.items)
            precondition(requests().count == previewRequests)
            model.requestRebuild()
            precondition(model.state == .confirming)
            navigation.task = .status
            navigation.reviewInRestore(source, restore: model)
            precondition(navigation.task == .status && navigation.pendingRestoreBundle == nil && model.preparation?.preparedPlanID == planID)
            model.cancelRebuildConfirmation()
            let fresh = RestoreModel(runtime: runtime, location: CoreLocation(root: core, python: python, home: root, temporaryBase: root, toolDirectories: []))
            navigation.reviewInRestore(source, restore: fresh)
            await fresh.waitForCompletion()
            precondition(fresh.source == source && fresh.state == .review && fresh.preparation == nil)
            try write("bundle_invalid", core.appendingPathComponent("mode"))
            navigation.task = .status
            navigation.reviewInRestore(replacement, restore: fresh)
            navigation.confirmRestoreReplacement(replacement, restore: fresh)
            await fresh.waitForCompletion()
            precondition(fresh.state == .failed && fresh.preview == nil && fresh.preparation == nil)
            precondition(requests().allSatisfy { $0["operation"] as? String != "restore_execute" && $0["operation"] as? String != "environment_compare" })
            print("PASS: Status handoff preserves Review/Preview, confirms replacement, blocks active/confirming Restore and only starts independent inspection")
            return
        }
        if CommandLine.arguments.contains("--plan-session-only") {
            func prepare(_ mode: String = "session") async throws {
                try write(mode, core.appendingPathComponent("mode"))
                model.refreshPreview()
                precondition(!model.canRebuild && model.preparation == nil)
                await model.waitForCompletion()
                precondition(model.canRebuild)
            }
            func execute() async throws {
                let id = model.preparation!.preparedPlanID
                try write("session", core.appendingPathComponent("mode"))
                model.requestRebuild(); model.confirmRebuild(); await model.waitForCompletion()
                precondition(model.executionPlan?.preparedPlanID == id && model.executionResult?.outcome == .clean)
                model.checkCurrentState(); await model.waitForCompletion()
            }
            try await prepare(); try await execute()
            try await prepare()
            try write("session-evidence-window", core.appendingPathComponent("mode"))
            model.requestRebuild(); model.confirmRebuild(); await model.waitForCompletion()
            precondition(runtime.historyTruncated)
            precondition(!runtime.events.contains { $0.type == "verification_record" })
            precondition(model.categoryPresentationEvents.contains { $0.type == "verification_record" })
            model.checkCurrentState(); await model.waitForCompletion()
            try await prepare(); let first = model.preparation!.preparedPlanID
            try await prepare(); precondition(model.preparation!.preparedPlanID != first)
            try await execute()
            try write("automation", core.appendingPathComponent("mode"))
            model.refreshPreview(); await model.waitForCompletion()
            await model.checkPrerequisites(permission: {
                try! write("session", core.appendingPathComponent("mode")); return .available
            })
            await model.waitForCompletion()
            precondition(model.prerequisiteRetryMessage == nil && model.canRebuild)
            try await prepare(); try await execute()
            try await prepare("session-delay")
            let latest = model.preparation!.preparedPlanID
            try write("session-delay", core.appendingPathComponent("mode"))
            model.refreshPreview()
            let pending = model.waitForCompletion
            model.refreshPreview(); model.requestRebuild()
            precondition(model.state == .preparing && !model.canRebuild)
            await pending()
            precondition(model.preparation!.preparedPlanID != latest)
            let finalID = model.preparation!.preparedPlanID
            try await Task.sleep(nanoseconds: 200_000_000)
            precondition(model.preparation!.preparedPlanID == finalID)
            try await execute()
            try write("session-automation", core.appendingPathComponent("mode"))
            model.refreshPreview(); await model.waitForCompletion()
            precondition(!model.canRebuild && model.preparation!.readiness.conditions.contains { $0.diagnostic?.automationRequirement == true })
            await model.checkPrerequisites(permission: { .denied })
            await model.waitForCompletion()
            precondition(model.prerequisiteRetryMessage!.contains("Privacy & Security → Automation"))
            await model.checkPrerequisites(permission: {
                try! write("session-skip", core.appendingPathComponent("mode")); return .available
            })
            await model.waitForCompletion()
            precondition(model.prerequisiteRetryMessage == nil && model.canRebuild)
            precondition(!model.preparation!.readiness.conditions.contains { $0.diagnostic?.automationRequirement == true })
            precondition(model.preparation!.plan.contains { $0.reason == "cask_execution_requirements_unsupported" })
            try write("clean", core.appendingPathComponent("mode")); model.refreshPreview(); await model.waitForCompletion()
            try write("execute_stale", core.appendingPathComponent("mode"))
            model.requestRebuild(); model.confirmRebuild(); await model.waitForCompletion()
            precondition(model.executionResult?.outcome == .failedBeforeMutation)
            precondition(model.executionResult?.title == "Restore Plan Is Outdated")
            let notRun = RestoreTaskPresentation(preview: model.executionPreview!, plan: model.executionPlan!,
                events: runtime.events, result: model.executionResult!, operationProgress: true)
            precondition(notRun.domains.allSatisfy { $0.executionStatus == .notRun && $0.executionStatus.tone == .neutral })
            let summary = RestoreVerificationSummary(payload: model.executionResult!.structuredEvidence)
            precondition(summary.title == "Verification Not Run" && summary.mismatch == nil && summary.unverified == nil && summary.unresolved == nil)
            // Each required pre-mutation fact is necessary; a failure alone is not Not Run.
            for key in ["code", "execution_status", "target_mutation_may_have_started", "verification"] {
                var changed = model.executionResult!.structuredEvidence!
                changed.removeValue(forKey: key)
                let changedResult = RestoreExecutionPresentation(runtime: runtime, payload: changed, expectedID: model.executionPlan!.preparedPlanID)
                let changedTasks = RestoreTaskPresentation(preview: model.executionPreview!, plan: model.executionPlan!,
                    result: changedResult, operationProgress: true)
                precondition(changedTasks.domains.allSatisfy { $0.executionStatus != .notRun })
            }
            let performed = try CoreEvent(line: JSONSerialization.data(withJSONObject: ["protocol_version": 1,
                "operation_id": "performed", "sequence": 1, "type": "operation_record",
                "data": ["domain": "homebrew-casks", "item_id": "1", "action": "install", "outcome": "success"]]))
            let mixed = RestoreTaskPresentation(preview: model.executionPreview!, plan: model.executionPlan!,
                events: [performed], result: model.executionResult!, operationProgress: true)
            precondition(mixed.domains.first { $0.id == "homebrew-casks" }!.executionStatus == .unverified)

            precondition(model.executionResult!.message.contains("No changes were made by this Restore attempt."))
            precondition(model.executionResult!.diagnosticReport.contains("stale_plan"))
            precondition(model.executionResult!.diagnosticReport.contains("Core recomputed ID:"))
            precondition(model.executionResult!.diagnosticReport.contains("Execute requested ID:"))

            print("PASS: Same-session Prepare/Refresh/Check Again/Execute use latest IDs; overlapping Refresh is blocked; stale-plan UX and independent warnings remain")
            return
        }
        try render(model, runtime, state: "selection")
        try render(model, runtime, state: "selection", expanded: true)
        try render(model, runtime, state: "macOS-settings", settingsOnly: true)
        let initialSelection = model.selection
        precondition(model.selectionCategoryCounts.fully == model.areas.filter(\.selectable).count)
        precondition(model.selectionCategoryCounts.partially == 0 && model.selectionCategoryCounts.notSelected == 0)
        let itemArea = model.areas.first { $0.selectable && $0.items.count > 1 }!
        model.selectItem(itemArea.id, item: itemArea.items[0].id, included: false)
        precondition(model.selectionCategoryCounts.partially == 1)
        model.selectArea(itemArea.id, included: false)
        precondition(model.selectionCategoryCounts.notSelected == 1 && model.selectionCategoryCounts.partially == 0)
        model.selectArea(itemArea.id, included: true)
        precondition(model.selection == initialSelection)
        let summaryMacOSGroup = model.groups.first { $0.id == "macOS Settings" }!
        model.selectArea(summaryMacOSGroup.domains[0], included: false)
        precondition(model.groupState(summaryMacOSGroup) == .mixed && model.selectionCategoryCounts.notSelected == 1)
        model.selectGroup(summaryMacOSGroup, included: true)
        precondition(model.selection == initialSelection)

        for id in applications + workspace {
            model.selectArea(id, included: false)
            precondition(!model.selection.categories.contains(id))
            model.selectArea(id, included: true)
        }
        let presentationGroups = model.groups + [CoreRestoreInspection.Group(id: "Homebrew", domains: ["homebrew-packages"])]
        let sections = RestorePresentationSection.project(presentationGroups)
        precondition(sections.map(\.id) == ["Applications & Tools", "Settings", "Git", "SSH Configuration", "Workspace", "Shell", "Other Findings"])
        precondition(sections[0].areas(in: model.areas).map(\.id) == ["app-store", "homebrew-casks", "homebrew-packages", "vscode-extensions"])
        precondition(sections[1].groups.map(\.id) == ["macOS Settings"])
        precondition(sections[4].areas(in: model.areas).map(\.id) == workspace)
        let projectedIDs = sections.flatMap { $0.areas(in: model.areas).map(\.id) }
        precondition(Set(projectedIDs) == Set(model.areas.map(\.id)))
        precondition(projectedIDs.count == Set(projectedIDs).count)
        precondition(sections.last!.areas(in: model.areas).contains { $0.id == "unavailable-area" })

        precondition(RestorePresentationSection.project(presentationGroups.reversed()).map(\.id) == sections.map(\.id))
        for id in applications + workspace + ["homebrew-packages"] {
            let area = model.areas.first { $0.id == id }!
            model.selectItem(id, item: area.items[0].id, included: false)
            precondition(model.selectionState(area) == .mixed && model.selection.items[id]?.count == 3)
            model.selectArea(id, included: true)
        }
        let shellGroup = CoreRestoreInspection.Group(id: "Shell", domains: ["unavailable-area"])
        let visibleGroups = presentationGroups + [shellGroup]
        var absent = model.areas.first { $0.id == "unavailable-area" }!
        absent.sourcePresent = false
        var presentEmpty = absent
        presentEmpty.sourcePresent = true
        precondition(RestorePresentationSection.includedAreas([absent]).isEmpty)
        precondition(RestorePresentationSection.includedAreas([presentEmpty]).count == 1)
        var presentUnsupported = presentEmpty
        presentUnsupported = CoreRestoreInspection.Area(domain: "unsupported-test", label: "Unsupported", selectionMode: "category", availability: "unsupported", sourcePresent: true, reason: "unsupported", items: [])
        precondition(RestorePresentationSection.includedAreas([presentUnsupported]).count == 1)
        var inventoryOnly = presentEmpty
        inventoryOnly.captureSelected = false
        precondition(RestorePresentationSection.includedAreas([inventoryOnly]).isEmpty)
        var wholeSelected = presentEmpty
        wholeSelected.captureSelected = true
        precondition(RestorePresentationSection.includedAreas([wholeSelected]).count == 1)
        presentUnsupported.captureSelected = true
        precondition(RestorePresentationSection.includedAreas([presentUnsupported]).count == 1)
        let selectedError = CoreRestoreInspection.Area(domain: "error-test", label: "Error", selectionMode: "items", availability: "unavailable", sourcePresent: true, captureSelected: true, reason: "observation_error", items: [])
        precondition(RestorePresentationSection.includedAreas([selectedError]).first?.reason == "observation_error")
        let selectedItemsArea = model.areas.first { $0.selectionMode == "items" && !$0.items.isEmpty }!
        precondition(RestorePresentationSection.includedAreas([selectedItemsArea]).count == 1)
        let inventoryBefore = model.areas.map(\.id)
        let selectionBefore = model.canonicalSelection
        let visible = RestorePresentationSection.visible(visibleGroups, inventory: model.areas)
        precondition(visible.contains { $0.id == "Shell" }, "Unknown presence must not hide unavailable state")
        precondition(visible.contains { $0.id == "Settings" } && visible.contains { $0.id == "Applications & Tools" })
        let availableShell = CoreRestoreInspection.Group(id: "Shell", domains: ["ssh-configuration", "unavailable-area"])
        precondition(RestorePresentationSection.visible([availableShell], inventory: model.areas).map(\.id) == ["SSH Configuration", "Shell"])
        precondition(model.areas.map(\.id) == inventoryBefore && model.canonicalSelection == selectionBefore)
        precondition(model.areas.first { $0.id == "unavailable-area" }?.reason == "no_selectable_content")
        let macOSGroup = model.groups.first { $0.id == "macOS Settings" }!
        model.selectArea("macos-dock", included: false)
        precondition(model.groupState(macOSGroup) == .mixed && model.selectedAreaCount == 12)
        model.selectGroup(macOSGroup, included: false); precondition(model.groupState(macOSGroup) == .none && model.selectionSummary == "Some items excluded")
        model.selectGroup(macOSGroup, included: true); precondition(model.groupState(macOSGroup) == .all && model.selectionSummary == "Everything selected")
        model.selectItem("macos-dock", item: "invented", included: false)
        precondition(model.selectedCategories.contains("macos-dock"))
        let packages = model.areas.first { $0.id == "homebrew-packages" }!
        model.selectItem(packages.id, item: packages.items[0].id, included: false)
        precondition(model.selectionSummary == "Some items excluded")
        precondition(model.selectionState(packages) == .mixed && model.selection.items[packages.id]?.count == 3)
        model.selectArea("unavailable-area", included: true); precondition(!model.selection.categories.contains("unavailable-area"))
        model.refreshPreview(); await model.waitForCompletion()
        precondition(model.state == .preview && model.ready && model.preparation?.preparedPlanID == String(repeating: "a", count: 64))
        try render(model, runtime, state: "preview")
        try render(model, runtime, state: "preview", expanded: true)

        precondition(model.preview?.categories.first { $0.id == packages.id }?.items.first?.title == "Core item 2")
        let productPreview = model.preview!
        precondition(productPreview.sections.map(\.id) == ["Applications & Tools", "Settings", "SSH Configuration", "Workspace"])
        let settingsRows = productPreview.sections.first { $0.id == "Settings" }!.rows
        precondition(settingsRows.count == 1 && settingsRows[0].id == "macOS Settings")
        precondition(settingsRows[0].items.count == macOS.count)
        precondition(RestorePreviewPresentation.state(settingsRows[0]) == "Changes Planned")
        precondition(RestorePreviewPresentation.summary(changes: 0, matches: 122, attention: 1) == "0 changes · 122 already match · 1 needs attention")
        precondition(RestorePreviewPresentation.summary(changes: 1, matches: 1, attention: 2) == "1 change · 1 already matches · 2 need attention")
        let matching = DisplayCategory(id: "matches", title: "Matches", symbol: "checkmark.circle", items: [DisplayItem(id: "match", title: "Item", status: .matching, action: "Already Matches")])
        precondition(RestorePreviewPresentation.state(matching) == "Already Matches")
        for status in [DisplayStatus.unverified, .unsupported, .attention, .unresolved] {
            let aggregate = DisplayCategory(id: "macOS Settings", title: "macOS Settings", symbol: "slider.horizontal.3", items: settingsRows[0].items + [DisplayItem(id: "attention", title: "Detail", status: status, action: "Needs Attention")])
            precondition(RestorePreviewPresentation.state(aggregate) == "Needs Attention")
        }
        precondition(RestorePreviewPresentation.readyText(action: "install") == "Ready to Install")
        precondition(RestorePreviewPresentation.readyText(action: "set_preference") == "Ready to Change")
        precondition(RestorePreviewPresentation.readyText(action: "create_directory") == "Ready to Create")
        precondition(RestorePreviewPresentation.readyText(action: "unknown") == "Ready to Restore")
        precondition(settingsRows[0].items.allSatisfy { $0.restoreReadyText == "Ready to Change" })
        func event(_ domain: String, _ state: String, item: String = "scope", action: String = "restore") throws -> CoreEvent {
            try CoreEvent(line: JSONSerialization.data(withJSONObject: ["protocol_version": 1, "operation_id": "test", "sequence": 1,
                "type": "execution_event", "data": ["domain": domain, "state": state, "item_id": item, "action": action]]))
        }
        let frozen = RestoreProgressRow.freeze(preview: productPreview, plan: model.preparation!)
        let taskPreview = RestoreTaskPresentation(preview: productPreview, plan: model.preparation!)
        let taskIDs = taskPreview.domains.map(\.id)
        precondition(Set(taskIDs).count == taskIDs.count)
        // This fixture places packages in an unknown group, outside projected sections.
        // The dedicated Homebrew presentation fixture above covers both real domains.
        precondition(taskIDs.contains("homebrew-casks"))
        precondition(!taskIDs.contains("homebrew"))
        precondition(taskPreview.counters.reduce(0) { $0 + $1.count } == taskPreview.automaticDomains.count)
        let taskWorking = RestoreTaskPresentation(preview: productPreview, plan: model.preparation!,
            events: [try event("homebrew-casks", "started")], executing: true)
        precondition(taskWorking.domains.map(\.id) == taskIDs)
        precondition(taskWorking.domains.first { $0.id == "homebrew-casks" }?.state == .working)
        precondition(frozen.map(\.id) == productPreview.sections.flatMap(\.rows).map(\.id))
        precondition(frozen.allSatisfy { $0.project(events: []).status == .waiting })
        let casks = frozen.first { $0.id == "homebrew-casks" }!
        let packageRow = frozen.first { $0.id == "vscode-extensions" }!
        var events = [try event(packageRow.id, "started"), try event(casks.id, "started")]
        precondition(casks.project(events: events).status == .working && packageRow.project(events: events).status == .working)
        precondition(frozen.map { $0.project(events: events).id } == frozen.map(\.id))
        events.append(try event(casks.id, "changed", item: "one-item"))
        precondition(casks.project(events: events).status == .working)
        events.append(try event(casks.id, "changed"))
        precondition(casks.project(events: events).action == "OK")
        events.append(try event("verification", "started"))
        precondition(RestoreProgressRow.phase(events: events, mutationPossible: true) == "Verifying restored environment…")
        precondition(casks.project(events: events).action == "OK" && frozen.count == productPreview.sections.flatMap(\.rows).count)
        precondition(packageRow.project(events: events).status == .working)
        events.append(try event(packageRow.id, "failed"))
        events.append(try event(packageRow.id, "changed"))
        precondition(packageRow.project(events: events).status == .attention)
        precondition(RestoreProgressRow.phase(events: [], mutationPossible: false) == "Preparing rebuild…")
        precondition(RestoreProgressRow.phase(events: [], mutationPossible: true) == "Restoring environment…")
        let settingsProgress = frozen.first { $0.id == "macOS Settings" }!
        let oneSettingEvent = try event(macOS[0], "changed")
        let allSettingsEvents = try macOS.map { try event($0, "changed") }
        precondition(settingsProgress.project(events: [oneSettingEvent]).status != .complete)
        precondition(settingsProgress.project(events: allSettingsEvents).action == "OK")
        for (domain, item, name) in [("homebrew-casks", "appcleaner", "AppCleaner"),
                                     ("homebrew-packages", "tree", "tree"),
                                     ("vscode-extensions", "anthropic.claude-code", "anthropic.claude-code")] {
            let row = RestoreProgressRow(id: domain, title: domain, domains: [domain], hasAttention: false,
                                         itemNames: [domain: [item: name, "next": "Next Item"]])
            var activityEvents = [try event(domain, "applying", item: item, action: "install")]
            precondition(row.project(events: activityEvents).restoreActivity == "Installing \(name)…")
            activityEvents.append(try event("another-domain", "applying", item: "other", action: "install"))
            precondition(row.project(events: activityEvents).restoreActivity == "Installing \(name)…")
            activityEvents.append(try event(domain, "changed", item: item))
            precondition(row.project(events: activityEvents).restoreActivity == nil)
            activityEvents.append(try event(domain, "applying", item: "next", action: "install"))
            precondition(row.project(events: activityEvents).restoreActivity == "Installing Next Item…")
            activityEvents.append(try event(domain, "applying", item: "opaque:unknown", action: "install"))
            precondition(row.project(events: activityEvents).restoreActivity == nil)
            activityEvents.append(try event(domain, "applying", item: item, action: "unknown"))
            precondition(row.project(events: activityEvents).restoreActivity == nil)
        }
        let knownActivity = try event(casks.id, "applying", item: "1", action: "install")
        precondition(casks.project(events: [knownActivity]).restoreActivity == "Installing Core item 1…")
        let completedItem = try CoreEvent(line: JSONSerialization.data(withJSONObject: ["protocol_version": 1, "operation_id": "test", "sequence": 2,
            "type": "operation_record", "data": ["domain": casks.id, "item_id": "1", "outcome": "success"]]))
        precondition(casks.project(events: [knownActivity, completedItem]).restoreActivity == nil)
        func normalize(_ operations: [[String: Any]], _ verificationRecords: [[String: Any]], lifecycle: [CoreEvent] = []) throws -> RestoreResultFindings {
            let raw: [String: Any] = ["code": "bootstrap_failed", "verification": ["verdict": "differences_detected", "details": [
                "operation_records": operations, "verification_records": verificationRecords]]]
            let payload = try JSONDecoder().decode(CoreJSON.self, from: JSONSerialization.data(withJSONObject: raw)).object
            return RestoreResultFindings(payload: payload, events: lifecycle, catalog: model.inspection!.restoreSelection, verified: false)
        }
        let failedCask: [String: Any] = ["domain": "homebrew-casks", "item_id": "appcleaner", "action": "install", "outcome": "failure", "reason": "install_failed"]
        let aggregateFailure: [String: Any] = ["domain": "bootstrap", "item_id": "scope", "action": "restore", "outcome": "failure", "reason": "bootstrap_failed"]
        let mismatch: [String: Any] = ["domain": "homebrew-casks", "item_id": "appcleaner", "conformity": "mismatch"]
        let normalized = try normalize([failedCask, failedCask, aggregateFailure], [mismatch, mismatch], lifecycle: [try event("homebrew-casks", "failed")])
        let expectedFindingReasons = [
            "homebrew-casks:appcleaner:install:install_failed": "install_failed",
            "bootstrap:scope:restore:bootstrap_failed": "bootstrap_failed",
            "homebrew-casks:scope::failed": "failed",
        ]
        precondition(normalized.findings.count == expectedFindingReasons.count)
        precondition(Set(normalized.findings.map(\.id)) == Set(expectedFindingReasons.keys))
        precondition(normalized.findings.allSatisfy {
            $0.status == .attention && $0.reason == expectedFindingReasons[$0.id]
        })
        precondition(normalized.details.filter { $0.reason == "install_failed" }.count == 1)
        precondition(normalized.details.filter { $0.reason == "mismatch" }.count == 1)
        precondition(normalized.details.filter { $0.reason == "bootstrap_failed" }.count == 1)
        precondition(normalized.details.contains { $0.title == "Rebuild" && $0.reason == "bootstrap_failed" })
        precondition(normalized.details.filter { $0.reason == "differences_detected" }.count == 1)
        let failedExtension: [String: Any] = ["domain": "vscode-extensions", "item_id": "extension", "action": "install", "outcome": "failure", "reason": "install_failed"]
        let secondSpecificEvent = try event("homebrew-casks", "blocked", item: "other-item")
        let specificFailures = try normalize([failedCask], [], lifecycle: [secondSpecificEvent])
        precondition(specificFailures.details.contains { $0.reason == "blocked" })
        let distinct = try normalize([failedCask, failedExtension], [mismatch])
        precondition(distinct.findings.count == 2 && Set(distinct.findings.map(\.id)) == [
            "homebrew-casks:appcleaner:install:install_failed",
            "vscode-extensions:extension:install:install_failed",
        ])
        precondition(distinct.findings.allSatisfy { $0.status == .attention && $0.reason == "install_failed" })
        var anotherFailure = failedCask; anotherFailure["reason"] = "authorization_required"
        let sameArea = try normalize([failedCask, anotherFailure], [mismatch])
        precondition(sameArea.findings.count == 2 && Set(sameArea.findings.map(\.id)) == [
            "homebrew-casks:appcleaner:install:install_failed",
            "homebrew-casks:appcleaner:install:authorization_required",
        ])
        precondition(sameArea.findings.allSatisfy { $0.status == .attention })
        precondition(Set(sameArea.findings.compactMap(\.reason)) == ["install_failed", "authorization_required"])
        precondition(sameArea.details.filter { $0.reason == "authorization_required" }.count == 1)
        let uncertain = try normalize([], [["domain": "homebrew-casks", "conformity": "unverified"]])
        precondition(uncertain.findings.count == 1 && uncertain.findings[0].status == .unverified)
        print("PASS: Structured active items, identity fallback, completion/replacement, concurrent domains and semantic result normalization")
        model.selectItem(packages.id, item: packages.items[0].id, included: true)
        precondition(model.preparation == nil && model.preview == nil && model.state == .review)
        try write("attention", core.appendingPathComponent("mode"))
        model.refreshPreview(); await model.waitForCompletion()
        precondition(model.state == .preview && !model.ready && model.preparation?.readiness.conditions.first?.status == "external_action_required")
        try render(model, runtime, state: "needs-attention")

        let projected = model.preview!.categories.first { $0.id == packages.id }!.items
        precondition(projected.map(\.action).contains("Already Matches") && projected.map(\.action).contains("Will install"))
        precondition(projected.contains { $0.action.hasPrefix("Conflict:") } && projected.contains { $0.requiresAttention })
        let attentionScope = RestoreProgressRow.freeze(preview: model.preview!, plan: model.preparation!)
        precondition(attentionScope.first { $0.id == "homebrew-casks" }?.project(events: []).status == .attention)
        let oldOperation = runtime.operationID
        try write("safe", core.appendingPathComponent("mode")); model.refreshPreview(); await model.waitForCompletion()
        precondition(runtime.operationID != oldOperation && model.ready && model.preparation?.preparedPlanID == String(repeating: "b", count: 64))
        precondition(model.preparation?.readiness.conditions.first?.status == "safely_satisfiable")
        for mode in ["satisfied", "unsupported_condition"] {
            try write(mode, core.appendingPathComponent("mode")); model.refreshPreview(); await model.waitForCompletion()
            precondition(model.state == .preview && model.ready == (mode == "satisfied"))
        }
        model.back(); precondition(model.state == .review && model.preparation == nil && model.bulkState == .all)
        model.toggleAll(); precondition(model.selectedAreaCount == 0 && !model.canPreview && model.selectionSummary == "Nothing selected")
        model.toggleAll(); precondition(model.bulkState == .all && model.selectionSummary == "Everything selected")
        for mode in ["prepare_failure", "wrong_selection", "interrupted"] {
            try write(mode, core.appendingPathComponent("mode")); model.refreshPreview(); await model.waitForCompletion()
            precondition(model.state == .failed && model.preparation == nil && model.preview == nil)
        }
        try write("slow", core.appendingPathComponent("mode")); model.refreshPreview()
        for _ in 0..<100 { if runtime.isActive && runtime.currentPhase == "preparation" { break }; try await Task.sleep(nanoseconds: 20_000_000) }
        model.cancel(); await model.waitForCompletion()
        precondition(model.state == .cancelled && model.preparation == nil && model.preview == nil)
        model.refreshPreview(); model.cancel(); await model.waitForCompletion()
        precondition(model.state == .cancelled && model.preparation == nil)
        for mode in ["old_core", "bundle_invalid", "unsupported_bundle"] {
            try write(mode, core.appendingPathComponent("mode")); model.choose(root.appendingPathComponent("another.mbt")); await model.waitForCompletion()
            precondition(model.state == .failed && model.inspection == nil && model.preparation == nil)
        }
        try write("clean", core.appendingPathComponent("mode")); model.choose(source); await model.waitForCompletion()
        model.refreshPreview(); await model.waitForCompletion()
        model.choose(root.appendingPathComponent("changed.mbt"))
        precondition(model.preparation == nil && model.preview == nil)
        await model.waitForCompletion()
        let requests = try String(contentsOf: core.appendingPathComponent("requests.jsonl"), encoding: .utf8).split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        precondition(requests.allSatisfy { ["capabilities", "bundle_inspect", "restore_prepare"].contains($0["operation"] as! String) })
        precondition(!FileManager.default.fileExists(atPath: core.appendingPathComponent("MUTATION_ATTEMPT").path))
        print("PASS: Capability/inventory, independent areas/groups/items, stable selection IDs, whole/subset requests, Preview correlation/readiness, invalidation, cancellation/interruption and no Execute")
        try write("automation", core.appendingPathComponent("mode"))
        model.refreshPreview(); await model.waitForCompletion()
        precondition(!model.canRebuild && model.prerequisiteRetryMessage == nil)
        let blockedAutomationID = model.preparation!.preparedPlanID
        let retryRequestsBefore = try String(contentsOf: core.appendingPathComponent("requests.jsonl"), encoding: .utf8)
        await model.checkPrerequisites(permission: { .denied })
        await model.waitForCompletion()
        precondition(model.prerequisiteRetryMessage != nil && !model.canRebuild && model.preparation!.preparedPlanID == blockedAutomationID)
        let deniedRequests = try String(contentsOf: core.appendingPathComponent("requests.jsonl"), encoding: .utf8)
        precondition(deniedRequests.split(separator: "\n").count == retryRequestsBefore.split(separator: "\n").count + 1)
        var permissionCalls = 0
        await model.checkPrerequisites(permission: {
            permissionCalls += 1
            try! write("clean", core.appendingPathComponent("mode"))
            return .available
        })
        await model.waitForCompletion()
        precondition(permissionCalls == 1 && model.canRebuild && model.prerequisiteRetryMessage == nil)
        let retryRequestsAfter = try String(contentsOf: core.appendingPathComponent("requests.jsonl"), encoding: .utf8)
        precondition(retryRequestsAfter.split(separator: "\n").count == retryRequestsBefore.split(separator: "\n").count + 2)
        print("PASS: Actionable Automation denial preserves fail-closed Preview; user retry performs one Prepare after access")
        try write("scoped_ssh", core.appendingPathComponent("mode"))
        model.refreshPreview(); await model.waitForCompletion()
        precondition(!model.canRebuild && model.preparation!.readiness.conditions.contains { $0.code == "ssh_configuration_not_ready" })
        func prepareRequests() throws -> [[String: Any]] {
            try String(contentsOf: core.appendingPathComponent("requests.jsonl"), encoding: .utf8)
                .split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
                .filter { $0["operation"] as? String == "restore_prepare" }
        }
        let prepareCount = try prepareRequests().count
        let sshPlanID = model.preparation!.preparedPlanID
        let selectedMetrics = RestorePreviewMetrics.counts(RestoreTaskPresentation(preview: model.preview!, plan: model.preparation!).domains)
        model.selectPreviewDomain("ssh-configuration", included: false)
        precondition(model.previewNeedsRefresh && !model.canRebuild && model.state == .preview)
        precondition(model.preparation!.preparedPlanID == sshPlanID && model.preview != nil)
        model.selectPreviewDomain("homebrew-casks", included: false)
        model.selectPreviewDomain("homebrew-casks", included: true)
        await Task.yield()
        let countAfterEdits = try prepareRequests().count
        precondition(countAfterEdits == prepareCount)
        model.requestRebuild(); precondition(model.state == .preview)
        let finalDraft = model.canonicalSelection
        model.refreshPreview(); await model.waitForCompletion()
        precondition((try? prepareRequests().count) == prepareCount + 1)
        precondition(model.preparation!.selection == finalDraft && !model.previewNeedsRefresh)
        precondition(model.canRebuild && !model.preparation!.selection.categories.contains("ssh-configuration"))
        precondition(model.preparation!.preparedPlanID != sshPlanID)
        precondition(!model.preparation!.readiness.conditions.contains { $0.domain == "ssh-configuration" })
        let unselectedMetrics = RestorePreviewMetrics.counts(RestoreTaskPresentation(preview: model.preview!, plan: model.preparation!).domains)
        precondition(unselectedMetrics.changes + unselectedMetrics.attention + unselectedMetrics.matching == selectedMetrics.changes + selectedMetrics.attention + selectedMetrics.matching - 1)
        precondition(model.preparation!.plan.filter { $0.domain == "homebrew-casks" && $0.disposition == "planned" }.count == 3)
        precondition(model.preparation!.readiness.conditions.contains { $0.isItemLocal })
        model.selectPreviewDomain("ssh-configuration", included: true)
        precondition(model.previewNeedsRefresh && !model.canRebuild)
        model.selectPreviewDomain("ssh-configuration", included: false)
        precondition(!model.previewNeedsRefresh && model.canRebuild)
        precondition((try? prepareRequests().count) == prepareCount + 1)
        model.selectPreviewDomain("ssh-configuration", included: true)
        model.refreshPreview(); await model.waitForCompletion()
        precondition(!model.canRebuild && model.preparation!.readiness.conditions.contains { $0.code == "ssh_configuration_not_ready" })
        model.selectPreviewDomain("ssh-configuration", included: false)
        try write("no_changes", core.appendingPathComponent("mode")); model.refreshPreview(); await model.waitForCompletion()
        precondition(!model.canRebuild && !model.preparation!.hasExecutableChanges)
        precondition(model.preparation!.plan.allSatisfy { $0.disposition == "satisfied" })
        model.back()
        if model.bulkState != .all { model.toggleAll() }
        model.toggleAll(); model.selectArea("ssh-configuration", included: true)
        try write("scoped_ssh", core.appendingPathComponent("mode")); model.refreshPreview(); await model.waitForCompletion()
        model.selectPreviewDomain("ssh-configuration", included: false)
        precondition(model.state == .preview && model.selectedAreaCount == 0 && !model.canRebuild)
        precondition(model.previewNeedsRefresh && model.preparation != nil && model.preview != nil && !model.canPreview)
        model.back(); model.toggleAll(); try write("clean", core.appendingPathComponent("mode")); model.refreshPreview(); await model.waitForCompletion()
        print("PASS: Draft checkbox edits make zero Prepare calls; one explicit refresh binds final selection; SSH re-entry, item skips, selected metrics and no-op eligibility")
        for mode in ["item_local", "only_item_local"] {
            try write(mode, core.appendingPathComponent("mode")); model.refreshPreview(); await model.waitForCompletion()
            precondition(model.state == .preview && model.ready)
            precondition(model.canRebuild == (mode == "item_local"))
            precondition(model.preview!.categories.first { $0.id == "homebrew-casks" }!.items.contains {
                $0.status == .attention && $0.reason == "cask_execution_requirements_unsupported"
            })
            precondition(model.preparation!.readiness.conditions.first!.isItemLocal)
        }
        try write("forged_item_local", core.appendingPathComponent("mode")); model.refreshPreview(); await model.waitForCompletion()
        precondition(model.state == .failed && !model.canRebuild)
        for mode in ["no_changes", "attention"] {
            try write(mode, core.appendingPathComponent("mode")); model.refreshPreview(); await model.waitForCompletion()
            precondition(!model.canRebuild)
            if mode == "no_changes" {
                precondition(RestoreProgressRow.freeze(preview: model.preview!, plan: model.preparation!).isEmpty)
            }
            model.requestRebuild(); precondition(model.state == .preview)
        }
        try write("mixed_progress", core.appendingPathComponent("mode")); model.refreshPreview(); await model.waitForCompletion()
        let mixedScope = RestoreProgressRow.freeze(preview: model.preview!, plan: model.preparation!)
        precondition(!mixedScope.contains { $0.id == "app-store" || $0.id == "ssh-configuration" })
        let matchingEvents = [try event("app-store", "started"), try event("app-store", "already_satisfied")]
        precondition(mixedScope.map { $0.project(events: matchingEvents).id } == mixedScope.map(\.id))
        precondition(mixedScope.allSatisfy { $0.project(events: matchingEvents).status == .waiting })
        let outcomes: [(String, RestoreExecutionPresentation.Outcome)] = [
            ("execute_clean", .clean), ("execute_partial", .failedAfterMutation), ("execute_item_skip", .partial), ("execute_attention", .attention),
            ("execute_fail_before", .failedBeforeMutation), ("execute_fail_after", .failedAfterMutation),
            ("execute_stale", .failedBeforeMutation), ("execute_interrupted", .interrupted), ("execute_missing_result", .interrupted),
            ("execute_stop_before", .stoppedBeforeMutation), ("execute_stop_after", .stoppedAfterMutation)]
        for (mode, outcome) in outcomes {
            try write("clean", core.appendingPathComponent("mode")); model.refreshPreview(); await model.waitForCompletion()
            precondition(model.canRebuild)
            let id = model.preparation!.preparedPlanID
            let progressIDs = RestoreProgressRow.freeze(preview: model.preview!, plan: model.preparation!).map(\.id)
            model.requestRebuild(); precondition(model.state == .confirming && !runtime.isActive)
            model.cancelRebuildConfirmation(); precondition(model.canRebuild && model.preparation?.preparedPlanID == id)
            model.requestRebuild()
            try write(mode, core.appendingPathComponent("mode")); model.confirmRebuild()
            precondition(model.executionActivities.map(\.id) == progressIDs && model.executionActivities.allSatisfy { $0.status == .waiting })
            let operation = runtime.operationID
            model.confirmRebuild(); model.choose(source); model.back()
            precondition(runtime.operationID == operation && model.state == .rebuilding)
            if mode.hasPrefix("execute_stop") {
                for _ in 0..<100 { if runtime.currentPhase != nil { break }; try await Task.sleep(nanoseconds: 20_000_000) }
                // This fixture has a TERM handler, not a graceful control channel.
                // Exercise the explicit Force Stop confirmation for that boundary.
                precondition(!runtime.homebrewGracefulSupported)
                model.requestForceStop()
                precondition(model.stopConfirmation && model.forceStopConfirmation && runtime.isActive && !runtime.stopping)
                model.requestForceStop(); precondition(model.stopConfirmation && !runtime.stopping)
                if mode == "execute_stop_after" {
                    precondition(model.mutationPossible)
                    model.dismissStopConfirmation(); precondition(runtime.isActive)
                    model.requestForceStop()
                }
                model.confirmStop(); model.confirmStop()
                precondition(!model.stopConfirmation)
            }
            if mode == "execute_clean" { model.requestStop() }
            await model.waitForCompletion()
            precondition(!model.stopConfirmation)
            model.confirmStop(); model.requestStop()
            precondition(!runtime.stopping && !model.stopConfirmation)
            precondition(model.state == .result && model.executionResult?.outcome == outcome,
                "\(mode): state=\(model.state), outcome=\(String(describing: model.executionResult?.outcome)), failure=\(model.failure ?? "none")")
            precondition(model.executionStartedAt != nil && model.executionFinishedAt != nil)
            precondition(model.executionFinishedAt! >= model.executionStartedAt!)
            let tasks = RestoreTaskPresentation(preview: model.executionPreview!, plan: model.executionPlan!,
                events: runtime.events, result: model.executionResult!)
            precondition(tasks.domains.map(\.id) == taskIDs)
            precondition(tasks.counters.reduce(0) { $0 + $1.count } == tasks.automaticDomains.count)
            if mode == "execute_clean" {
                precondition(tasks.domains.allSatisfy { $0.state == .completed })
                let compact = RestoreTaskPresentation(preview: model.executionPreview!, plan: model.executionPlan!, events: runtime.events, result: model.executionResult!, operationProgress: true)
                precondition(compact.domains.allSatisfy { [.completed, .matching].contains($0.executionStatus) })
                precondition(model.executionResult!.title == "Rebuild Completed")
                precondition(model.executionResult!.message.hasPrefix("Your selected environment has been restored and verified."))
                precondition(model.executionResult!.findings.isEmpty)
            }
            if mode == "execute_partial" {
                precondition(tasks.domains.first { $0.id == "homebrew-casks" }?.state == .failed)
                precondition(tasks.domains.first { $0.id == "homebrew-casks" }?.items.contains { $0.item.reason == "item_stalled_timeout" } == true)
            }
            if mode == "execute_item_skip" {
                precondition(tasks.domains.first { $0.id == "homebrew-casks" }?.items.contains { $0.state == .skipped } == true)
                precondition(tasks.domains.first { $0.id == "homebrew-casks" }?.items.contains { $0.item.reason == "cask_execution_requirements_unsupported" } == true)
                var payload = model.executionResult!.structuredEvidence!
                var verification = payload["verification"]!.object!
                var evidence = verification["details"]!.object!
                let casks = model.executionPlan!.plan.filter { $0.domain == "homebrew-casks" }
                evidence["operation_records"] = .array(casks.map { row in
                    .object(["domain": .string(row.domain), "item_id": .string(row.itemID), "action": .string(row.action),
                        "outcome": .string(row.itemID == "1" ? "skipped" : "success"),
                        "reason": row.itemID == "1" ? .string("cask_execution_requirements_unsupported") : .null])
                })
                evidence["verification_records"] = .array(casks.map { row in
                    .object(["domain": .string(row.domain), "item_id": .string(row.itemID),
                        "conformity": .string(row.itemID == "1" ? "unverified" : "verified")])
                })
                verification["details"] = .object(evidence); payload["verification"] = .object(verification)
                let mixed = RestoreExecutionPresentation(runtime: runtime, payload: payload, expectedID: id,
                    catalog: model.inspection?.restoreSelection)
                let mixedTasks = RestoreTaskPresentation(preview: model.executionPreview!, plan: model.executionPlan!, result: mixed)
                let homebrew = mixedTasks.domains.first { $0.id == "homebrew-casks" }!
                precondition(homebrew.state == .partial)
                precondition(homebrew.items.first { $0.item.reason == "cask_execution_requirements_unsupported" }?.state == .skipped)
                precondition(homebrew.items.contains { $0.state == .completed })
                precondition(mixedTasks.domains.map(\.id) == taskIDs)
            }
            if mode == "execute_interrupted" || mode == "execute_missing_result" {
                precondition(!tasks.domains.contains { $0.state == .completed })
            }
            precondition(model.executionActivities.map(\.id) == progressIDs)
            precondition(!model.executionActivities.contains { $0.status == .complete })
            if mode == "execute_partial" {
                let result = model.executionResult!
                precondition(result.title == "Rebuild Failed")
                precondition(result.findings.count == 1 && result.findings[0].title == "Core item 1")
                precondition(result.findings[0].action == "Download stalled. Check your network or VPN and try again.")
                precondition(result.details.contains { $0.action == "Rebuild could not complete." })
                precondition(result.details.contains { $0.reason == "item_stalled_timeout" })
            }
            if mode == "execute_item_skip" {
                precondition(model.executionResult!.title == "Partial Restore")
                precondition(!model.executionResult!.details.contains { $0.action == "Rebuild could not complete." })
                precondition(model.executionResult!.details.contains { $0.reason == "differences_detected" })
                precondition(model.executionResult!.details.contains { $0.reason == "cask_execution_requirements_unsupported" })
                precondition(model.executionResult!.findings.contains {
                    $0.title == "Core item 1" && $0.status == .attention && $0.reason == "cask_execution_requirements_unsupported"
                })
            }
            precondition(model.preparation == nil && !model.canRebuild)
            try write("clean", core.appendingPathComponent("mode")); model.checkCurrentState(); await model.waitForCompletion()
            precondition(model.state == .preview && model.canRebuild)
        }
        print("PASS: Stage 16G eligibility, confirmation, fine Execute request, ownership, zero-change, explicit Force Stop with handled fixture cancellation, failure/interruption and Verification outcomes; fixtures only")
        if !CommandLine.arguments.contains("--fixtures-only") { try await realPrepare(repo: repo, python: python, root: root) }
    }

    @MainActor static func realPrepare(repo: URL, python: URL, root: URL) async throws {
        let setup = root.appendingPathComponent("setup.py")
        try write("""
        import sys, shutil
        from pathlib import Path
        repo=Path(sys.argv[1]); root=Path(sys.argv[2]); core=root/'real-core'; core.mkdir()
        shutil.copytree(repo/'modules',core/'modules'); shutil.copy2(repo/'bootstrap.sh',core/'bootstrap.sh')
        (core/'config').mkdir(); shutil.copy2(repo/'config/toolkit.conf',core/'config/toolkit.conf')
        home=root/'real-home'; home.mkdir(); tools=root/'tools'; tools.mkdir()
        for name,body in [('curl','exit 0'),('xcode-select','exit 0'),('sw_vers','echo 99'),('sudo','exit 99'),('age','exit 99')]:
            p=tools/name; p.write_text('#!/bin/bash\\n'+body+'\\n'); p.chmod(0o700)
        sys.path.insert(0,str(repo/'modules/bundle')); import bundle
        stage=root/'source'; stage.mkdir()
        flags={name:False for name in bundle.CATEGORY_FLAGS}
        raw='[categories]\\n'+''.join(name+'="false"\\n' for name in flags)
        raw+=''.join('\\n['+name+']\\n'+('Projects\\nOther\\n' if name=='workspace-folders' else '') for name in bundle.ITEMS)
        bundle.write_file(stage/'blueprint.conf',raw.encode())
        bundle.write_file(stage/'generated/workspace/folders.conf',b'Projects|workspace\\nOther|workspace\\n')
        bundle.pack(stage,root/'real.mbt','/Users/fixture-source')
        """, setup)
        let process = Process(); process.executableURL = python; process.arguments = ["-B", setup.path, repo.path, root.path]
        try process.run(); process.waitUntilExit(); precondition(process.terminationStatus == 0)
        let home = root.appendingPathComponent("real-home")
        let core = root.appendingPathComponent("real-core")
        let original = try Data(contentsOf: root.appendingPathComponent("real.mbt"))
        let runtime = CoreRuntime()
        let model = RestoreModel(runtime: runtime, location: CoreLocation(root: core, python: python, home: home, temporaryBase: root, toolDirectories: [root.appendingPathComponent("tools")]))
        model.choose(root.appendingPathComponent("real.mbt")); await model.waitForCompletion()
        precondition(model.state == .review, "Real inspection failed: \(model.failure ?? "")")
        model.toggleAll()
        let area = model.areas.first { $0.id == "workspace-folders" }!
        model.selectItem(area.id, item: area.items[1].id, included: true)
        model.refreshPreview(); await model.waitForCompletion()
        precondition(model.state == .preview && model.ready, "Real Prepare failed: \(model.failure ?? "")")
        precondition(model.preparation?.plan.count == 1 && model.preparation?.plan.first?.selectionItemID == area.items[1].id)
        precondition(model.preview?.categories.first?.items.first?.title == area.items[1].label)
        precondition(!FileManager.default.fileExists(atPath: home.appendingPathComponent("Other").path))
        precondition(!FileManager.default.fileExists(atPath: home.appendingPathComponent("Projects").path))
        precondition(!FileManager.default.fileExists(atPath: core.appendingPathComponent("config/generated").path))
        precondition(!FileManager.default.fileExists(atPath: core.appendingPathComponent("config/blueprint.conf").path))
        let after = try Data(contentsOf: root.appendingPathComponent("real.mbt"))
        precondition(after == original)
        precondition(runtime.operation == .restorePrepare)
        print("PASS: Swift → real bundle_inspect → stable subset → production Restore Preview, no target/config/Bundle mutation")
    }
}
