import Foundation

@main struct RestoreTests {
    static func write(_ value: String, _ path: URL) throws { try value.write(to: path, atomically: false, encoding: .utf8) }
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
        let emptyProgress = operationTasks([])
        precondition(emptyProgress.domains.count == 2 && emptyProgress.domains.flatMap(\.items).count == 37)
        precondition(RestoreOperationSummary(domains: emptyProgress.domains).completed == 0)
        let unrelatedAction = try event("operation_record", domains[0], "firefox", "outcome", "success", action: "inspect")
        precondition(RestoreOperationSummary(domains: operationTasks([unrelatedAction]).domains).completed == 0)
        let projected = operationTasks([finished, activeEvent, failure])
        let counts = RestoreOperationSummary(domains: projected.domains)
        precondition(counts.completed == 1 && counts.working == 1 && counts.attention == 1)
        let skippedItem = TaskItemPresentation(id: "skip", item: DisplayItem(id: "skip", title: "Dependent item",
            status: .attention, action: "Skipped", reason: "dependency_failed"), state: .skipped)
        precondition(RestoreOperationSummary(domains: [.init(id: "skip", title: "Skipped", symbol: "app", items: [skippedItem])]).attention == 1)
        let checking = operationTasks([finished, activeEvent, verifiedOnly, phase])
        precondition(RestoreOperationSummary(domains: checking.domains).completed == 1)
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
        let warning = try event("operation_record", domains[0], "firefox", "outcome", "warning")
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
        precondition(view.contains("DisclosureGroup(\"Technical Details\")") && !view.contains("DisclosureGroup(\"View Details\")"))
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
        let automationRaw: [String: Any] = ["domain": "homebrew-casks", "code": "cask_authorization_required",
            "status": "external_action_required", "scope": "operation", "selected_item_index": 1,
            "diagnostic": ["primitive": "login_item", "condition": "authorization_denied"]]
        let automation = try JSONDecoder().decode(CoreRestorePreparation.Condition.self, from: JSONSerialization.data(withJSONObject: automationRaw))
        precondition(automation.diagnostic?.automationRequirement == true && !automation.isItemLocal)
        precondition(RestorePrerequisiteSummaryPresentation.status([automation]) == "Authorization Required")
        precondition(automation.diagnostic!.explanation.contains("Check Again"))
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
        let readyBranch = summarySource.components(separatedBy: "if summary.isTerminalReady {")[1].components(separatedBy: "} else {")[0]
        precondition(readyBranch.contains("Label(\"Ready\", systemImage: \"checkmark\")"))
        precondition(!readyBranch.contains("DisclosureGroup") && !readyBranch.contains("ForEach") && !readyBranch.contains("Button"))
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
            events.append(try event("operation_record", domains[0], item, "outcome", "success"))
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
        precondition(caskRow.executionStatus == .attention && !caskRow.executionMessages.isEmpty)
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
    @MainActor static func main() async throws {
        try taskPresentationChecks()
        try restoreEvidenceChecks()
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
            features={} if mode=='old_core' else {'restore_selection':{'version':1}}
            result=dict(protocol_version=1, product_version='3.4.0',operations=['bundle_inspect','restore_prepare'],features=features)
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
            if mode=='execute_missing_result': emit('completed'); sys.exit(0)
            if mode in ('execute_partial','execute_item_skip'):
                emit('phase_started',dict(phase='bootstrap'))
                item_reason='cask_execution_requirements_unsupported' if mode=='execute_item_skip' else 'item_stalled_timeout'
                item_outcome='skipped' if mode=='execute_item_skip' else 'failure'
                emit('operation_record',dict(domain='homebrew-casks',item_id='1',action='install',outcome=item_outcome,reason=item_reason))
                details=dict(status='complete',operation_records=[dict(domain='homebrew-casks',item_id='1',action='install',outcome=item_outcome,reason=item_reason),dict(domain='vscode-extensions',item_id='1',action='install',outcome='success',reason=None)],verification_records=[dict(domain='homebrew-casks',item_id='1',conformity='mismatch'),dict(domain='vscode-extensions',item_id='1',conformity='verified')])
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
            if mode=='execute_attention': verification['unverified_count']=1; verification['verdict']='incomplete'
            result=dict(prepared_plan_id=session_id if session else 'a'*64,execution_status='completed',target_mutation_may_have_started=True,publication_occurred=True,verification=verification,warning_count=0,error_count=0)
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
            ["domain": domain, "label": "Core label " + domain, "selection_mode": "items", "availability": "available", "reason": NSNull(),
             "items": (1...4).map { ["item_id": "stable-\(domain)-\($0)", "label": "Core item \($0)"] }]
        }
        inventory += macOS.map { ["domain": $0, "label": "Core label " + $0, "selection_mode": "category", "availability": "available", "reason": NSNull(), "items": []] }
        inventory += [["domain": "ssh-configuration", "label": "SSH Configuration", "selection_mode": "category", "availability": "available", "reason": NSNull(), "items": []],
                      ["domain": "unavailable-area", "label": "Unavailable area", "selection_mode": "category", "availability": "unavailable", "reason": "no_selectable_content", "items": []]]
        inventory.append(["domain": "empty-items", "label": "Empty items", "selection_mode": "items", "availability": "available", "reason": NSNull(), "items": []])
        let groups: [[String: Any]] = [["id": "Applications", "domains": applications], ["id": "Workspace", "domains": workspace],
                                      ["id": "macOS Settings", "domains": macOS], ["id": "SSH Configuration", "domains": ["ssh-configuration"]], ["id": "Other Core group", "domains": ["homebrew-packages", "unavailable-area", "empty-items"]]]
        let inspection: [String: Any] = ["format_version": 1, "selected_categories": macOS + ["ssh-configuration"], "selected_item_counts": [:], "secure_component": true,
                                        "restore_selection": ["groups": groups, "inventory": inventory]]
        try JSONSerialization.data(withJSONObject: inspection).write(to: core.appendingPathComponent("inspection.json"))
        let runtime = CoreRuntime()
        let model = RestoreModel(runtime: runtime, location: CoreLocation(root: core, python: python, home: root, temporaryBase: root, toolDirectories: []))
        let source = root.appendingPathComponent("sample.mbt")
        model.choose(source); await model.waitForCompletion()
        precondition(model.state == .review && model.areas.count == inventory.count && model.groups.count == 5 && model.bulkState == .all)
        precondition(model.selectionSummary == "Everything selected" && model.canPreview)
        precondition(model.inspection?.secureComponent == true && model.selectedAreaCount == 13)
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
        precondition(sections.map(\.id) == ["Applications & Tools", "Settings", "Shell", "Git", "SSH Configuration", "Workspace"])
        precondition(sections[0].areas(in: model.areas).map(\.id) == ["homebrew-casks", "app-store", "homebrew-packages", "vscode-extensions"])
        precondition(sections[1].groups.map(\.id) == ["macOS Settings"])
        precondition(sections[5].areas(in: model.areas).map(\.id) == workspace)
        precondition(RestorePresentationSection.project(presentationGroups.reversed()).map(\.id) == sections.map(\.id))
        for id in applications + workspace + ["homebrew-packages"] {
            let area = model.areas.first { $0.id == id }!
            model.selectItem(id, item: area.items[0].id, included: false)
            precondition(model.selectionState(area) == .mixed && model.selection.items[id]?.count == 3)
            model.selectArea(id, included: true)
        }
        let shellGroup = CoreRestoreInspection.Group(id: "Shell", domains: ["unavailable-area"])
        let visibleGroups = presentationGroups + [shellGroup]
        let inventoryBefore = model.areas.map(\.id)
        let selectionBefore = model.canonicalSelection
        let visible = RestorePresentationSection.visible(visibleGroups, inventory: model.areas)
        precondition(!visible.contains { $0.id == "Shell" })
        precondition(visible.contains { $0.id == "Settings" } && visible.contains { $0.id == "Applications & Tools" })
        let availableShell = CoreRestoreInspection.Group(id: "Shell", domains: ["ssh-configuration", "unavailable-area"])
        precondition(RestorePresentationSection.visible([availableShell], inventory: model.areas).map(\.id) == ["Shell"])
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
        precondition(taskPreview.counters.reduce(0) { $0 + $1.count } == taskPreview.domains.count)
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
        precondition(normalized.findings.count == 1 && normalized.findings[0].id == "homebrew-casks" && normalized.findings[0].status == .attention)
        precondition(normalized.details.filter { $0.reason == "mismatch" }.count == 1)
        precondition(normalized.details.filter { $0.reason == "bootstrap_failed" }.count == 1)
        precondition(normalized.details.contains { $0.title == "Rebuild" && $0.reason == "bootstrap_failed" })
        precondition(normalized.details.filter { $0.reason == "differences_detected" }.count == 1)
        let failedExtension: [String: Any] = ["domain": "vscode-extensions", "item_id": "extension", "action": "install", "outcome": "failure", "reason": "install_failed"]
        let secondSpecificEvent = try event("homebrew-casks", "blocked", item: "other-item")
        let specificFailures = try normalize([failedCask], [], lifecycle: [secondSpecificEvent])
        precondition(specificFailures.details.contains { $0.reason == "blocked" })
        let distinct = try normalize([failedCask, failedExtension], [mismatch])
        precondition(distinct.findings.map(\.id) == ["homebrew-casks", "vscode-extensions"])
        var anotherFailure = failedCask; anotherFailure["reason"] = "authorization_required"
        let sameArea = try normalize([failedCask, anotherFailure], [mismatch])
        precondition(sameArea.findings.count == 1 && sameArea.details.contains { $0.reason == "authorization_required" })
        let uncertain = try normalize([], [["domain": "homebrew-casks", "conformity": "unverified"]])
        precondition(uncertain.findings.count == 1 && uncertain.findings[0].status == .unverified)
        print("PASS: Structured active items, identity fallback, completion/replacement, concurrent domains and semantic result normalization")
        model.selectItem(packages.id, item: packages.items[0].id, included: true)
        precondition(model.preparation == nil && model.preview == nil && model.state == .review)
        try write("attention", core.appendingPathComponent("mode"))
        model.refreshPreview(); await model.waitForCompletion()
        precondition(model.state == .preview && !model.ready && model.preparation?.readiness.conditions.first?.status == "external_action_required")
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
        precondition(model.prerequisiteRetryMessage != nil && !model.canRebuild && model.preparation!.preparedPlanID == blockedAutomationID)
        let deniedRequests = try String(contentsOf: core.appendingPathComponent("requests.jsonl"), encoding: .utf8)
        precondition(deniedRequests == retryRequestsBefore)
        var permissionCalls = 0
        await model.checkPrerequisites(permission: {
            permissionCalls += 1
            try! write("clean", core.appendingPathComponent("mode"))
            return .available
        })
        await model.waitForCompletion()
        precondition(permissionCalls == 1 && model.canRebuild && model.prerequisiteRetryMessage == nil)
        let retryRequestsAfter = try String(contentsOf: core.appendingPathComponent("requests.jsonl"), encoding: .utf8)
        precondition(retryRequestsAfter.split(separator: "\n").count == retryRequestsBefore.split(separator: "\n").count + 1)
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
                model.requestStop()
                precondition(model.stopConfirmation && runtime.isActive && !runtime.stopping)
                model.requestStop(); precondition(model.stopConfirmation && !runtime.stopping)
                if mode == "execute_stop_after" {
                    precondition(model.mutationPossible)
                    model.dismissStopConfirmation(); precondition(runtime.isActive)
                    model.requestStop()
                }
                model.confirmStop(); model.confirmStop()
                precondition(!model.stopConfirmation)
            }
            if mode == "execute_clean" { model.requestStop() }
            await model.waitForCompletion()
            precondition(!model.stopConfirmation)
            model.confirmStop(); model.requestStop()
            precondition(!runtime.stopping && !model.stopConfirmation)
            precondition(model.state == .result && model.executionResult?.outcome == outcome)
            precondition(model.executionStartedAt != nil && model.executionFinishedAt != nil)
            precondition(model.executionFinishedAt! >= model.executionStartedAt!)
            let tasks = RestoreTaskPresentation(preview: model.executionPreview!, plan: model.executionPlan!,
                events: runtime.events, result: model.executionResult!)
            precondition(tasks.domains.map(\.id) == taskIDs)
            precondition(tasks.counters.reduce(0) { $0 + $1.count } == tasks.domains.count)
            if mode == "execute_clean" {
                precondition(tasks.domains.allSatisfy { $0.state == .completed })
                let compact = RestoreTaskPresentation(preview: model.executionPreview!, plan: model.executionPlan!, events: runtime.events, result: model.executionResult!, operationProgress: true)
                precondition(compact.domains.allSatisfy { [.completed, .matching].contains($0.executionStatus) })
                precondition(model.executionResult!.title == "All Done")
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
                    .object(["domain": .string(row.domain), "item_id": .string(row.itemID),
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
                precondition(model.executionResult!.title == "Rebuild Needs Attention")
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
        print("PASS: Stage 16G eligibility, confirmation, fine Execute request, ownership, zero-change, Safe Stop, failure/interruption and Verification outcomes; fixtures only")
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
