import Foundation
import AppKit
import SwiftUI

@main struct CaptureTests {
    typealias Object = [String: Any]
    static func write(_ text: String, _ url: URL, executable: Bool = false) throws {
        try text.write(to: url, atomically: false, encoding: .utf8)
        if executable { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path) }
    }
    static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func snapshot(_ directory: URL) throws -> [String: Data] {
        var files: [String: Data] = [:]
        for case let url as URL in FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])! {
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true { files[url.path] = try Data(contentsOf: url) }
        }
        return files
    }
    static func row(_ domain: String, mode: String, status: String = "present", items: [String] = [], reason: String? = nil) -> Object {
        ["domain": domain, "selection_mode": mode, "status": status, "reason": reason ?? NSNull(),
         "items": items.map { ["item_id": $0, "label": $0] }]
    }
    @MainActor static func render(_ model: CaptureModel, _ runtime: CoreRuntime, state: String, expanded: Bool = false, settingsOnly: Bool = false) throws {
        guard !CommandLine.arguments.contains("--no-renders") else { return }
        _ = NSApplication.shared
        for (width, viewportHeight) in [(785, 660), (985, 760), (1385, 1010)] {
            let height = settingsOnly ? 1120 : viewportHeight
            let content = VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        WorkspaceHeader(title: "Capture this Mac", subtitle: ProductTask.capture.subtitle, symbol: ProductTask.capture.symbol)
                        if settingsOnly {
                            CaptureMacOSSettingsView(model: model, expansion: .constant(true), childExpansion: .constant(true))
                                .modifier(WorkspaceCardSurface())
                        } else {
                            CaptureView(model: model, runtime: runtime, showsActions: false, categoryExpansion: expanded ? .constant(true) : nil)
                        }
                    }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                CaptureActionsView(model: model, runtime: runtime).modifier(WorkspaceFooterPadding())
            }.frame(width: CGFloat(width), height: CGFloat(height)).background(Color(nsColor: .windowBackgroundColor))
            let host = NSHostingView(rootView: content)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.frame = NSRect(x: 0, y: 0, width: width, height: height)
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { preconditionFailure("Native Capture render unavailable") }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/Debug/CaptureUIv2-\(state)\(expanded ? "-expanded" : "")-\(width).png"))
            window.close()
        }
    }
    @MainActor static func main() async throws {
        // Foundation resolves /private/var to /var, while Core requires Python's
        // canonical parent spelling. Use an explicit canonical fixture root.
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("macseed-desktop-capture-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let python = URL(fileURLWithPath: CommandLine.arguments[2])
        let core = root.appendingPathComponent("fake-core")
        try FileManager.default.createDirectory(at: core.appendingPathComponent("modules/core/application-interface"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: core.appendingPathComponent("config"), withIntermediateDirectories: true)
        for path in ["modules/core/application-interface/core.py", "config/toolkit.conf", "bootstrap.sh"] { try Data().write(to: core.appendingPathComponent(path)) }
        try write("#!/bin/bash\nexec python3 -B fixture.py\n", core.appendingPathComponent("modules/core/application-interface/core.sh"))
        let inventory = [row("homebrew-packages", mode: "items", items: ["one", "two"], reason: "source_partial"),
                         row("macos-finder", mode: "category"), row("vscode-settings", mode: "category", status: "observation_error", reason: "observation_failed"),
                         row("shell-zsh", mode: "category", status: "unsupported", reason: "source_excluded"),
                         row("app-store", mode: "items", status: "unavailable", reason: "tool_unavailable"),
                         row("future-domain", mode: "future_mode")]
        try JSONSerialization.data(withJSONObject: inventory).write(to: core.appendingPathComponent("inventory.json"))
        try write("success", core.appendingPathComponent("mode"))
        try write("""
        import json, pathlib, signal, sys, time, os
        request = json.loads(sys.stdin.buffer.read())
        assert request['operation'] in ('capture_prepare', 'capture_execute')
        with open('requests.jsonl', 'a') as stream: stream.write(json.dumps(request) + '\\n')
        params = request['parameters']; selection = params['selection']; mode = pathlib.Path('mode').read_text()
        assert selection is None or selection['secure_identities'] == []
        sequence = 0; published = False
        def emit(kind, data=None):
            global sequence
            sequence += 1
            event = dict(protocol_version=1, operation_id=request['operation_id'], sequence=sequence, type=kind)
            if data is not None: event['data'] = data
            print(json.dumps(event), flush=True)
        def stop(signum, frame):
            emit('failed', dict(code='cancelled', publication_occurred=published)); sys.exit(130)
        signal.signal(signal.SIGTERM, stop)
        emit('started'); emit('phase_started', dict(phase='discovery'))
        if mode == 'slow_scan':
            while True: time.sleep(.05)
        if mode == 'prepare_failure': emit('failed', dict(code='capture_discovery_failed', publication_occurred=False)); sys.exit(2)
        if mode == 'protocol': print('bad JSON', flush=True); sys.exit(0)
        rows = json.loads(pathlib.Path('inventory.json').read_text())
        for row in rows: emit('capture_category', {key:row[key] for key in ('domain', 'status', 'reason')})
        emit('phase_completed', dict(phase='discovery'))
        if selection is not None and mode in ('invalid_workspace_selection', 'workspace_dependency_missing', 'workspace_path_conflict', 'capture_source_unavailable'):
            emit('failed', dict(code=mode, publication_occurred=False)); sys.exit(2)
        if request['operation'] == 'capture_prepare':
            summary = dict(selected_domains=0, selected_items=0, secure_identity_count=0)
            if selection:
                summary['selected_domains'] = len(selection['categories']) + len(selection['items'])
                summary['selected_items'] = sum(map(len, selection['items'].values())) + sum(len(row['items']) for row in rows if row['domain'] in selection['categories'])
            emit('result', dict(prepared_capture_id='a'*64, inventory=[] if mode == 'empty_inventory' else rows,
                 selection=selection, summary=summary, secure_identities=dict(status='unavailable', items=[])))
            emit('completed'); sys.exit(0)
        assert params['expected_prepared_capture_id'] == 'a'*64
        if mode == 'stale_prepared_capture': emit('failed', dict(code=mode, publication_occurred=False)); sys.exit(2)
        emit('phase_started', dict(phase='bundle_creation'))
        if mode == 'kill_save': os.kill(os.getpid(), signal.SIGKILL)
        if mode == 'published_cancel': published = True
        if mode in ('slow_save', 'published_cancel'):
            while True: time.sleep(.05)
        if mode == 'execute_failure': emit('failed', dict(code='capture_failed', publication_occurred=False)); sys.exit(2)
        counts = {row['domain']:len(row['items']) for row in rows if row['domain'] in selection['categories'] and row['selection_mode']=='items'}
        counts.update({key:len(value) for key,value in selection['items'].items()})
        emit('result', dict(publication_occurred=mode!='unpublished', destination=params['destination'],
             prepared_capture_id='b'*64 if mode=='wrong_binding' else 'a'*64,
             bundle=dict(format_version=1, selected_categories=[row['domain'] for row in rows if row['domain'] in selection['categories'] and row['selection_mode']=='category'], selected_item_counts=counts, secure_component=False)))
        emit('completed'); sys.exit(0)
        """, core.appendingPathComponent("fixture.py"))
        let runtime = CoreRuntime(operationLogs: nil)
        let model = CaptureModel(runtime: runtime, location: CoreLocation(root: core, python: python, home: root, temporaryBase: root, toolDirectories: []))
        model.scan(); await model.waitForCompletion()
        precondition(model.state == .review && model.selectedDomainCount == 2 && model.selectedItemCount == 2)
        precondition(model.bulkState == .all && model.selection.secureIdentities.isEmpty)
        let renderSelection = model.selection
        try render(model, runtime, state: "review")
        try render(model, runtime, state: "review", expanded: true)
        precondition(model.selection == renderSelection && model.state == .review)
        let packages = model.categories.first { $0.id == "homebrew-packages" }!
        let finder = model.categories.first { $0.id == "macos-finder" }!
        precondition(packages.itemSelectable && packages.notices[0].requiresAttention)
        precondition(finder.selectable && !finder.itemSelectable && finder.headerSummary == "Whole category")
        precondition(!model.categories.first { $0.id == "future-domain" }!.selectable
                     && model.categories.first { $0.id == "future-domain" }!.headerSummary == "Not Supported")
        precondition(model.categories.first { $0.id == "vscode-settings" }!.display.hasAttention)
        model.selectItem(finder.id, item: "invented-setting", included: true)
        precondition(model.selection.items[finder.id] == nil && Set(model.selection.categories) == [finder.id, packages.id])
        model.selectItem(packages.id, item: "one", included: false)
        precondition(model.selectionState(packages) == .mixed && model.bulkState.bulkActionTitle == "Select All" && model.selectedItemCount == 1)
        precondition(model.selectionSummary == "2 domains selected · 1 item selected")
        model.toggleAll(); precondition(model.bulkState == .all && model.selectedItemCount == 2)
        model.toggleAll(); precondition(model.bulkState == .none && !model.canCreate && model.selection.categories.isEmpty && model.selection.items.isEmpty)
        model.selectCategory(finder.id, included: true)
        precondition(model.selectedDomainCount == 1 && model.selectedItemCount == 0 && model.selection.categories == [finder.id])
        model.selectCategory("vscode-settings", included: true)
        precondition(model.selectedDomainCount == 1)
        print("PASS: Real prepare payload mapping, item/category-only modes, mixed/bulk selection and observation/unsupported warnings")

        for name in ["Saved Environment", "Saved Environment.mbt", "Saved Environment.mbt.mbt"] {
            let normalized = CaptureDestination.normalized(root.appendingPathComponent(name))
            precondition(normalized.lastPathComponent == "Saved Environment.mbt")
            precondition(normalized.deletingLastPathComponent().path == root.path)
        }
        precondition(CaptureDestination.normalized(root.appendingPathComponent("my.archive.txt")).lastPathComponent == "my.archive.txt.mbt")
        let target = root.appendingPathComponent("selected.mbt")
        model.prepare(destination: target); await model.waitForCompletion()
        precondition(model.state == .confirmation && model.preparation?.summary.selectedDomains == 1)
        precondition(model.confirmationSummary == "1 domain selected · 0 items selected")
        precondition(model.confirmationAreas.map(\.content) == ["1 of 1"])

        precondition(model.destination == target && model.preparation?.selection?.secureIdentities.isEmpty == true)
        model.editSelection(); precondition(model.state == .review && model.preparation == nil)
        model.selectCategory(packages.id, included: true)
        model.prepare(destination: target); await model.waitForCompletion()
        precondition(model.state == .confirmation && model.preparation?.summary.selectedItems == 2)
        precondition(model.confirmationWarnings.map(\.id) == [packages.id])
        precondition(model.confirmationAreas.first { $0.id == packages.id }?.requiresAttention == true)

        let ordinaryFailure = CaptureFailure.runtime(.coreFailure("capture_validation_failed"))
        precondition(!ordinaryFailure.isOutdatedPreparation && ordinaryFailure.presentationTitle == "Needs Attention")
        precondition(ordinaryFailure.presentationMessage == ordinaryFailure.message)

        let captureSummary = CaptureSummaryPresentation.review(categories: model.categories, domainCount: model.selectedDomainCount, itemCount: model.selectedItemCount)
        precondition(captureSummary.domainCount == model.selectedDomainCount && captureSummary.itemCount == model.selectedItemCount)
        precondition(captureSummary.attentionCount == 2 && captureSummary.unsupportedCount == 2)
        let rows = CaptureReviewRow.project(model.categories)
        precondition(rows.flatMap(\.categories).count == model.categories.count)
        precondition(Set(rows.flatMap(\.categories).map(\.id)) == Set(model.categories.map(\.id)))
        precondition(rows.map(\.id) == ["app-store", "homebrew-packages", "macos-settings", "vscode-settings", "shell-zsh", "future-domain"])
        precondition(CaptureReviewRow.project([]).isEmpty)
        precondition(SelectionState.mixed.captureTitle == "Partially Selected")
        precondition(CaptureReviewRow.attentionMessage(rows) == "2 categories need attention")
        precondition(CaptureReviewRow.attentionMessage(rows.filter { !$0.needsAttention }) == nil)
        let futureRow = try JSONDecoder().decode(CoreCaptureInventoryRow.self,
            from: JSONSerialization.data(withJSONObject: row("future-domain", mode: "future", status: "unsupported")))
        let future = CaptureReviewRow.project([CaptureCategory(row: futureRow)])
        precondition(future.count == 1 && future[0].categories[0].id == "future-domain")
        precondition(future[0].categories[0].title == "future-domain" && !future[0].categories[0].selectable)
        precondition(CaptureReviewRow.attentionMessage(future) == nil)

        let confirmedSelection = model.selection
        try render(model, runtime, state: "confirmation")
        try render(model, runtime, state: "confirmation", expanded: true)
        precondition(model.selection == confirmedSelection && model.state == .confirmation)
        let preparedScope = model.preparation!
        let plannedTasks = CaptureTaskPresentation(categories: preparedScope.inventory.map { CaptureCategory(row: $0) }, selection: preparedScope.selection!, phase: .confirmation)
        let waitingTasks = CaptureTaskPresentation(categories: model.categories, selection: model.selection, phase: .progress)
        precondition(plannedTasks.domains.map(\.id) == waitingTasks.domains.map(\.id))
        precondition(waitingTasks.domains.flatMap(\.items).allSatisfy { $0.state == .waiting && $0.item.reason == nil })
        precondition(plannedTasks.domains.flatMap(\.items).contains { $0.item.reason == "source_partial" })
        precondition(plannedTasks.domains.first?.id == "homebrew-packages")
        let preparedPackages = plannedTasks.domains.first!
        precondition(preparedPackages.items.filter { $0.state == .planned }.count == 2)
        precondition(preparedPackages.items.filter { $0.item.reason == "source_partial" }.count == 1)
        let contents = CaptureConfirmationContents(preparedPackages.items)
        precondition(contents.ordinary.count == 2 && contents.problems.count == 1)
        precondition(contents.problems.first?.item.reason == "source_partial")
        precondition(Set(contents.ordinary.map(\.id)).isDisjoint(with: Set(contents.problems.map(\.id))))
        let reordered = CaptureConfirmationContents([contents.problems[0]] + contents.ordinary + [contents.problems[0]])
        precondition(reordered.ordinary.map(\.id) == contents.ordinary.map(\.id) && reordered.problems.count == 1)
        precondition(contents.itemProblems.isEmpty && contents.categoryProblems.count == 1)
        let wholeCategory = TaskItemPresentation(id: "whole", item: DisplayItem(id: "whole", title: "Future Domain",
            status: .ready, action: "Whole category"), state: .planned, captureRole: .wholeCategory)
        precondition(CaptureConfirmationContents([wholeCategory]).ordinary.isEmpty)
        precondition(CaptureConfirmationContents([wholeCategory]).explanations.count == 1)
        let settingsRow = try JSONDecoder().decode(CoreCaptureInventoryRow.self,
            from: JSONSerialization.data(withJSONObject: row("vscode-settings", mode: "category", reason: "source_partial")))
        let settingsDomain = CaptureTaskPresentation(categories: [CaptureCategory(row: settingsRow)],
            selection: CoreCaptureSelection(categories: ["vscode-settings"], items: [:], secureIdentities: []), phase: .confirmation).domains[0]
        let settingsContents = CaptureConfirmationContents(settingsDomain.items)
        precondition(settingsContents.ordinary.map { $0.item.title } == ["JSON configuration"])
        precondition(settingsContents.explanations[0].item.action.contains("settings.json"))
        precondition(settingsContents.categoryProblems.count == 1 && settingsContents.itemProblems.isEmpty)

        var firstProblem = contents.problems[0]
        firstProblem.captureRole = nil
        let secondProblem = TaskItemPresentation(id: "independent", item: DisplayItem(id: "independent", title: firstProblem.item.title,
            status: firstProblem.item.status, action: firstProblem.item.action, reason: firstProblem.item.reason), state: .attention)
        let mixedProblems = CaptureConfirmationContents([wholeCategory, contents.problems[0], firstProblem, secondProblem])
        precondition(mixedProblems.ordinary.isEmpty && mixedProblems.itemProblems.map(\.id) == [firstProblem.id, secondProblem.id])
        precondition(mixedProblems.categoryProblems.isEmpty, "Same structured fact is shown once at item level")
        let independentCategory = TaskItemPresentation(id: "category-source", item: DisplayItem(id: "category-source", title: firstProblem.item.title,
            status: .attention, action: firstProblem.item.action, reason: firstProblem.item.reason), state: .attention, captureRole: .categoryWarning)
        let combined = CaptureConfirmationContents([independentCategory, firstProblem, secondProblem])
        precondition(combined.itemProblems.map(\.id) == [firstProblem.id, secondProblem.id] && combined.categoryProblems.count == 1)
        precondition(CaptureConfirmationContents(contents.ordinary).problems.isEmpty)



        model.create(); await model.waitForCompletion()
        precondition(model.state == .result && model.publicationEvidence == .occurred && model.publication?.destination == target.path)
        precondition(model.publication?.bundle.capturedDomains.count == 2 && model.resultNotices.count == 1)
        try render(model, runtime, state: "result")
        try render(model, runtime, state: "result", expanded: true)
        let captured = model.publication!.bundle
        let resultTasks = CaptureTaskPresentation(categories: preparedScope.inventory.map { CaptureCategory(row: $0) }, selection: preparedScope.selection!,
            phase: .result, publication: model.publication, notices: model.resultNotices)
        precondition(resultTasks.domains.map(\.id) == plannedTasks.domains.map(\.id))
        precondition(resultTasks.domains.first { $0.id == "homebrew-packages" }?.state == .attention)
        precondition(resultTasks.domains.first { $0.id == "macos-settings" }?.state == .completed)
        precondition(CaptureConfirmationContents(resultTasks.domains.first { $0.id == "macos-settings" }!.items).ordinary.map { $0.item.title } == ["Finder"])
        let unknownResult = CaptureTaskPresentation(categories: model.categories, selection: model.selection, phase: .result,
            capturedDomains: captured.capturedDomains)
        precondition(unknownResult.domains.allSatisfy { $0.state == .unverified })
        precondition(unknownResult.domains.flatMap(\.items).allSatisfy { $0.state != .completed })

        precondition(resultTasks.domains.flatMap(\.items).contains { $0.state == .attention && $0.item.reason == "source_partial" })
        let resultMetrics = CaptureSummaryPresentation(domainCount: captured.capturedDomains.count, itemCount: captured.itemCount, attentionCount: 1, unsupportedCount: 0, captured: true)
        precondition(resultMetrics.metrics.first?.title == "Captured Domains" && resultMetrics.domainCount == 2 && resultMetrics.itemCount == 2)
        let requests = try String(contentsOf: core.appendingPathComponent("requests.jsonl"), encoding: .utf8).split(separator: "\n")
        let sent = try requests.map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! Object }
        precondition(sent.map { $0["operation"] as! String } == ["capture_prepare", "capture_prepare", "capture_prepare", "capture_execute"])
        precondition((sent[0]["parameters"] as! Object)["selection"] is NSNull)
        let execution = sent.last!["parameters"] as! Object
        precondition(execution["expected_prepared_capture_id"] as? String == String(repeating: "a", count: 64))
        precondition((execution["selection"] as! Object)["categories"] as? [String] == ["homebrew-packages", "macos-finder"])
        print("PASS: Destination → fresh selected preparation → inline confirmation → bound execution and published result/warnings")
        if CommandLine.arguments.contains("--result-actions-only") {
            let before = try Data(contentsOf: core.appendingPathComponent("requests.jsonl"))
            model.done()
            precondition(model.state == .idle && model.publication == nil && model.preparation == nil && model.destination == nil)
            precondition(model.inventory.isEmpty && model.selectedCategories.isEmpty && model.selectedItems.isEmpty && model.operationID == nil)
            precondition(!runtime.isActive && (try! Data(contentsOf: core.appendingPathComponent("requests.jsonl"))) == before)
            model.scan(); await model.waitForCompletion()
            precondition(model.state == .review && !model.inventory.isEmpty)
            print("PASS: Done returns Capture to pre-scan idle without Core requests; Capture Again retains scan")
            return
        }


        for code in ["invalid_workspace_selection", "workspace_dependency_missing", "workspace_path_conflict", "capture_source_unavailable"] {
            try write("success", core.appendingPathComponent("mode"))
            model.scan(); await model.waitForCompletion()
            let selection = model.selection
            try write(code, core.appendingPathComponent("mode"))
            model.prepare(destination: root.appendingPathComponent("not-yet-saving.mbt")); await model.waitForCompletion()
            precondition(model.state == .failed && !model.savingAttempted && model.publicationEvidence == .notOccurred)
            precondition(model.failure?.technicalReason == code && model.selection == selection)
            precondition(model.failure?.message != "Capture could not complete. Scan this Mac again before another attempt.")
            if ["workspace_dependency_missing", "workspace_path_conflict"].contains(code) {
                precondition(model.canReviewSelection)
                model.editSelection()
                precondition(model.state == .review && model.selection == selection)
            }
        }
        precondition(CaptureFailure.runtime(.coreFailure("private_token_shaped_value")).technicalReason == nil)
        for mode in ["prepare_failure", "empty_inventory", "protocol"] {
            try write(mode, core.appendingPathComponent("mode"))
            model.scan(); await model.waitForCompletion()
            precondition(model.state == .failed && model.publication == nil && model.inventory.isEmpty && !model.canCreate)
        }
        try write("slow_scan", core.appendingPathComponent("mode"))
        model.scan(); await waitUntil(runtime) { !$0.events.isEmpty }
        model.cancel(); await model.waitForCompletion()
        precondition(model.state == .cancelled && model.publication == nil)
        for mode in ["stale_prepared_capture", "execute_failure", "unpublished", "wrong_binding", "kill_save", "slow_save", "published_cancel"] {
            try write("success", core.appendingPathComponent("mode"))
            model.scan(); await model.waitForCompletion()
            model.prepare(destination: root.appendingPathComponent(mode + ".mbt")); await model.waitForCompletion()
            precondition(model.state == .confirmation)
            try write(mode, core.appendingPathComponent("mode"))
            model.create()
            if ["slow_save", "published_cancel"].contains(mode) {
                await waitUntil(runtime) { $0.events.contains { $0.phase == "bundle_creation" } }
                if mode == "slow_save" { try render(model, runtime, state: "saving") }
                model.cancel()
            }
            await model.waitForCompletion()
            precondition(model.state != .result && model.publication == nil && model.preparation == nil)
            precondition(model.savingAttempted && !model.canReviewSelection)
            if mode == "stale_prepared_capture" {
                precondition(model.failure?.presentationTitle == "Capture Preparation Is Outdated")
                precondition(model.failure?.presentationMessage == "The selected environment has changed since confirmation. Scan this Mac again to prepare an updated capture.")
                precondition(model.failure?.technicalReason == "stale_prepared_capture" && model.publicationEvidence == .notOccurred)

                precondition(model.failure == .runtime(.coreFailure(mode)))
                let countBefore = try String(contentsOf: core.appendingPathComponent("requests.jsonl"), encoding: .utf8).split(separator: "\n").count
                model.create(); await model.waitForCompletion()
                let countAfter = try String(contentsOf: core.appendingPathComponent("requests.jsonl"), encoding: .utf8).split(separator: "\n").count
                precondition(countBefore == countAfter, "No silent retry of stale execution")
            }
            if mode == "kill_save" { precondition(model.failure == .interrupted && model.publicationEvidence == .unknown && model.publicationMayHaveStarted) }
            if mode == "published_cancel" { precondition(model.state == .cancelled && model.publicationEvidence == .occurred && model.destination != nil) }
            if mode == "slow_save" { precondition(model.state == .cancelled && model.publicationEvidence == .notOccurred) }
        }
        try write("success", core.appendingPathComponent("mode"))
        model.scan(); await model.waitForCompletion()
        let existing = root.appendingPathComponent("existing.mbt")
        try write("existing user data", existing)
        model.prepare(destination: existing)
        let unchanged = try String(contentsOf: existing, encoding: .utf8)
        precondition(model.state == .failed && model.failure == .invalidDestination && unchanged == "existing user data")
        let macOSDomains = CaptureMacOSSettingsGroup.domainIDs
        let includedLabels = ["Show extensions", "Auto-hide", "Window tabbing", "Key repeat", "Tap to click", "Save location"]
        let groupedInventory = macOSDomains.enumerated().map { index, domain -> Object in
            var category = row(domain, mode: "category")
            category["included_settings"] = [["id": "setting-\(index)", "label": includedLabels[index]]]
            return category
        }
            + [row("homebrew-packages", mode: "items", items: ["one"])]
        try JSONSerialization.data(withJSONObject: groupedInventory).write(to: core.appendingPathComponent("inventory.json"))
        model.scan(); await model.waitForCompletion()
        precondition(model.macOSSettings.state == .all && model.macOSSettings.summary == "6 of 6 selected")
        precondition(model.macOSSettings.children.enumerated().allSatisfy { index, category in
            category.row.includedSettings?.map(\.label) == [includedLabels[index]] && category.row.items.isEmpty
        })
        precondition(model.selectedDomainCount == 7 && model.selectedItemCount == 1 && !model.macOSSettings.hasAttention)
        let settingsSelection = model.selection
        try render(model, runtime, state: "macOS-settings", settingsOnly: true)
        precondition(model.selection == settingsSelection && model.selectedDomainCount == 7 && model.selectedItemCount == 1)
        let nestedTasks = CaptureTaskPresentation(categories: model.categories, selection: model.selection, phase: .confirmation)
        let children = CaptureSettingsPresentation.children(nestedTasks.domains)
        precondition(children.map(\.id) == macOSDomains)
        precondition(children.flatMap(\.items).map(\.id) == nestedTasks.domains.first { $0.id == "macos-settings" }!.items.map(\.id))
        precondition(CaptureSettingsPresentation.labels(model.inventory).values.flatMap { $0 }.count == 6)

        let macOSReviewRows = CaptureReviewRow.project(model.categories)
        precondition(macOSReviewRows.map(\.id) == ["homebrew-packages", "macos-settings"])
        precondition(macOSReviewRows.last?.categories.count == 6)
        let fullMacOS = CaptureTaskPresentation(categories: model.categories, selection: model.selection, phase: .confirmation)
            .domains.first { $0.id == "macos-settings" }!
        precondition(CaptureConfirmationContents(fullMacOS.items).ordinary.map { $0.item.title } == ["Finder", "Dock", "Windows", "Keyboard", "Trackpad", "Screenshots"])


        precondition(model.availableAreaCount == 7 && model.selectionSummary == "7 domains selected · 1 item selected")
        model.selectCategory("macos-finder", included: false)
        precondition(model.macOSSettings.state == .mixed && model.macOSSettings.summary == "5 of 6 selected")
        let partialMacOS = CaptureTaskPresentation(categories: model.categories, selection: model.selection, phase: .confirmation)
            .domains.first { $0.id == "macos-settings" }!
        precondition(CaptureConfirmationContents(partialMacOS.items).ordinary.map { $0.item.title } == ["Dock", "Windows", "Keyboard", "Trackpad", "Screenshots"])

        precondition(model.selectionSummary == "6 of 7 domains selected · 1 item selected")
        precondition(!model.selection.categories.contains("macos-finder"))
        model.selectMacOSSettings(included: false)
        precondition(model.macOSSettings.state == .none && model.macOSSettings.summary == "0 of 6 selected")
        precondition(model.selectedDomainCount == 1 && model.selectedItemCount == 1)
        model.selectMacOSSettings(included: true)
        precondition(model.macOSSettings.state == .all && Set(model.selectedCategories) == Set(macOSDomains))
        precondition(model.selection.items.isEmpty && Set(model.selection.categories) == Set(macOSDomains + ["homebrew-packages"]))
        model.toggleAll(); precondition(model.bulkState == .none && model.macOSSettings.state == .none)
        precondition(model.selectionSummary == "0 of 7 domains selected · 0 items selected")
        model.toggleAll(); precondition(model.bulkState == .all && model.macOSSettings.state == .all)
        model.prepare(destination: root.appendingPathComponent("grouped.mbt")); await model.waitForCompletion()
        precondition(model.state == .confirmation && model.preparation?.summary.selectedDomains == 7)
        precondition(model.confirmationSummary == "7 domains selected · 1 item selected")
        precondition(model.confirmationAreas.count == 2)
        precondition(model.confirmationAreas.first { $0.id == "macos-settings" }?.content == "6 of 6")
        precondition(model.confirmationAreas.first { $0.id == "homebrew-packages" }?.content == "1")

        precondition(Set(model.preparation!.selection!.categories) == Set(macOSDomains + ["homebrew-packages"]))
        model.create(); await model.waitForCompletion()
        precondition(model.state == .result && model.publication?.bundle.capturedDomains.count == 7)
        let compactInventory = groupedInventory + [row("ssh-configuration", mode: "category", reason: "source_partial")]
        try JSONSerialization.data(withJSONObject: compactInventory).write(to: core.appendingPathComponent("inventory.json"))
        model.scan(); await model.waitForCompletion()
        model.selectCategory("macos-dock", included: false)
        model.prepare(destination: root.appendingPathComponent("compact-summary")); await model.waitForCompletion()
        precondition(model.state == .confirmation && model.destination?.lastPathComponent == "compact-summary.mbt")
        precondition(model.confirmationAreas.first { $0.id == "macos-settings" }?.content == "5 of 6")
        precondition(model.confirmationAreas.first { $0.id == "ssh-configuration" }?.content == "Included")
        precondition(model.confirmationWarnings.map(\.id) == ["ssh-configuration"])
        let sshPrepared = model.preparation!
        let sshCategory = sshPrepared.inventory.map { CaptureCategory(row: $0) }.first { $0.id == "ssh-configuration" }!
        let sshResult = CaptureTaskPresentation(categories: sshPrepared.inventory.map { CaptureCategory(row: $0) }, selection: sshPrepared.selection!, phase: .result, capturedDomains: Set(sshPrepared.selection!.categories).union(sshPrepared.selection!.items.keys),
            notices: [DisplayCategory(id: sshCategory.id, title: sshCategory.title, symbol: sshCategory.symbol, items: sshCategory.notices)])
        precondition(sshResult.domains.first { $0.id == "ssh-configuration" }?.state == .attention)
        precondition(sshResult.domains.first { $0.id == "ssh-configuration" }?.items.contains { $0.item.reason == "source_partial" && $0.state == .attention } == true)
        precondition(model.confirmationSummary == "7 domains selected · 1 item selected")
        model.editSelection()
        precondition(model.state == .review && model.preparation == nil && model.selectionState(model.categories.first { $0.id == "macos-dock" }!) == .none)
        print("PASS: Prepared summary-only rows, category Included, partial macOS grouping, visible deduplicated warnings and destination normalization")
        let attentionInventory = [row("macos-finder", mode: "category", status: "observation_error", reason: "observation_failed"),
                                  row("macos-dock", mode: "category", status: "unsupported", reason: "source_excluded"),
                                  row("macos-windows", mode: "category", status: "unavailable", reason: "source_absent")]
            + macOSDomains.dropFirst(3).map { row($0, mode: "category", reason: $0 == "macos-trackpad" ? "source_partial" : nil) }
        try JSONSerialization.data(withJSONObject: attentionInventory).write(to: core.appendingPathComponent("inventory.json"))
        model.scan(); await model.waitForCompletion()
        precondition(model.macOSSettings.state == .all && model.macOSSettings.summary == "3 of 3 selected" && model.macOSSettings.hasAttention)
        precondition(model.availableAreaCount == 3 && model.selectionSummary == "3 domains selected · 0 items selected")
        model.selectMacOSSettings(included: false); precondition(model.selectedDomainCount == 0)
        precondition(model.selectionSummary == "0 of 3 domains selected · 0 items selected")
        model.selectMacOSSettings(included: true)
        model.selectCategory("macos-finder", included: true)
        precondition(Set(model.selection.categories) == Set(macOSDomains.dropFirst(3)) && model.selection.items.isEmpty)
        print("PASS: macOS Settings all/mixed/none, parent/child/global selection, real IDs through prepare/execute and unavailable/attention aggregation")
        let initialWhole = [row("homebrew-packages", mode: "items", items: ["one", "two"])]
        try JSONSerialization.data(withJSONObject: initialWhole).write(to: core.appendingPathComponent("inventory.json"))
        model.scan(); await model.waitForCompletion()
        let refreshedWhole = [row("homebrew-packages", mode: "items", items: ["one", "two", "three"])]
        try JSONSerialization.data(withJSONObject: refreshedWhole).write(to: core.appendingPathComponent("inventory.json"))
        model.prepare(destination: root.appendingPathComponent("fresh-whole.mbt")); await model.waitForCompletion()
        precondition(model.state == .confirmation && model.selectedItemCount == 3 && model.preparation?.summary.selectedItems == 3)
        let large = [row("homebrew-packages", mode: "items", items: (0..<2048).map { "package-\($0)" })]
        try JSONSerialization.data(withJSONObject: large).write(to: core.appendingPathComponent("inventory.json"))
        model.scan(); await model.waitForCompletion()
        precondition(model.selectedItemCount == 2048 && model.selection.categories == ["homebrew-packages"] && model.selection.items.isEmpty)
        let compactRequest = try CoreRequest(.capturePrepare(selection: model.selection)).encoded()
        precondition(compactRequest.count < 4096)
        model.prepare(destination: root.appendingPathComponent("large.mbt")); await model.waitForCompletion()
        precondition(model.state == .confirmation && model.preparation?.summary.selectedItems == 2048)
        model.editSelection()
        model.selectItem("homebrew-packages", item: "package-0", included: false)
        model.prepare(destination: root.appendingPathComponent("oversized-subset.mbt")); await model.waitForCompletion()
        precondition(model.state == .failed && model.failure == .runtime(.requestTooLarge) && model.publication == nil)
        precondition(model.failure?.message.contains("whole categories") == true)
        print("PASS: Large Select All uses compact whole-domain V1 selection; fresh confirmation reflects refreshed scope")
        let unresolved = CaptureModel(runtime: CoreRuntime(resolver: CoreLocationResolver(resources: root.appendingPathComponent("missing-runtime")), operationLogs: nil))
        unresolved.scan(); await unresolved.waitForCompletion()
        precondition(unresolved.state == .failed && unresolved.inventory.isEmpty && unresolved.publication == nil)
        #if DEBUG
        let demo = DemoSession(); demo.load(.captureSuccess)
        precondition(demo.captureState == .result && unresolved.publication == nil)
        #else
        precondition(!BuildFeatures.sampleExperience)
        #endif
        print("PASS: Prepare/protocol failure, cancellation, stale binding, no-clobber and no false success/fallback after failure/interruption/publication")
        try await realCore(root: root, repository: URL(fileURLWithPath: CommandLine.arguments[1]), python: python)
    }
    @MainActor static func waitUntil(_ runtime: CoreRuntime, predicate: (CoreRuntime) -> Bool) async {
        for _ in 0..<200 {
            if predicate(runtime) { return }
            try! await Task.sleep(nanoseconds: 20_000_000)
        }
        preconditionFailure("Fixture did not reach expected phase")
    }
    @MainActor static func realCore(root: URL, repository: URL, python: URL) async throws {
        // Automated disposable HOME/tools only; never the real-Mac manual gate.
        let core = root.appendingPathComponent("real-core"), home = root.appendingPathComponent("real-home"), bin = root.appendingPathComponent("real-bin")
        for url in [core.appendingPathComponent("config"), core.appendingPathComponent("scripts"), home, bin] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        for name in ["modules", "bootstrap.sh", "config/toolkit.conf", "scripts/ssh-identity-migrate.sh"] {
            try FileManager.default.copyItem(at: repository.appendingPathComponent(name), to: core.appendingPathComponent(name))
        }
        let mode = bin.appendingPathComponent("mode"), marker = root.appendingPathComponent("mutation-attempts")
        try write("normal", mode)
        try write("""
        #!/bin/bash
        case "$*" in
          'list --formula'|'list --formula --full-name'|'list --formula --installed-on-request')
            echo one
            if [[ "$(/bin/cat \(quote(mode.path)))" == normal ]]; then echo two; else echo changed; fi;;
          --version) echo 'Homebrew 7.0.7';;
          help\\ *) echo "$2 --formula --cask --full-name --json --appdir";;
          'info --json=v2 --installed --cask') echo '{"casks":[]}';;
          'list --cask') exit 0;;
          --prefix) echo /opt/homebrew;;
          *) echo attempted >> \(quote(marker.path)); exit 99;;
        esac
        """, bin.appendingPathComponent("brew"), executable: true)
        try write("#!/bin/bash\nif [[ \"$1\" == read || \"$1\" == read-type ]]; then echo 'does not exist' >&2; exit 1; fi\necho attempted >> " + quote(marker.path) + "\nexit 99\n", bin.appendingPathComponent("defaults"), executable: true)
        for name in ["sudo", "killall", "age"] { try write("#!/bin/bash\necho attempted >> " + quote(marker.path) + "\nexit 99\n", bin.appendingPathComponent(name), executable: true) }
        for name in ["code", "mas"] { try write("#!/bin/bash\nexit 2\n", bin.appendingPathComponent(name), executable: true) }
        for name in ["curl", "xcode-select"] { try write("#!/bin/bash\nexit 0\n", bin.appendingPathComponent(name), executable: true) }
        try write("#!/bin/bash\necho 99\n", bin.appendingPathComponent("sw_vers"), executable: true)
        try write("[user]\nname = PRIVATE_FIXTURE_NAME\n", home.appendingPathComponent(".gitconfig"))
        try write("export EDITOR=vi\n", home.appendingPathComponent(".zshrc"))
        let generated = core.appendingPathComponent("config/generated")
        try FileManager.default.createDirectory(at: generated, withIntermediateDirectories: true)
        try write("private ordinary state", generated.appendingPathComponent("sentinel"))
        try write("private ordinary selection", core.appendingPathComponent("config/blueprint.conf"))
        let beforeHome = try snapshot(home), beforeConfig = try snapshot(core.appendingPathComponent("config"))
        let runtime = CoreRuntime(operationLogs: nil)
        let model = CaptureModel(runtime: runtime, location: CoreLocation(root: core, python: python, home: home, temporaryBase: root, toolDirectories: [bin]))
        model.scan(); await model.waitForCompletion()
        precondition(model.state == .review, "Real scan failed: \(String(describing: model.failure))")
        let packages = model.categories.first { $0.id == "homebrew-packages" }!
        precondition(packages.row.items.map(\.itemID) == ["one", "two"])
        model.toggleAll(); model.selectItem(packages.id, item: "one", included: true)
        let target = root.appendingPathComponent("real-captured.mbt")
        model.prepare(destination: root.appendingPathComponent("real-captured.mbt.mbt")); await model.waitForCompletion()
        precondition(model.state == .confirmation && model.destination == target)
        model.create(); await model.waitForCompletion()
        precondition(!FileManager.default.fileExists(atPath: root.appendingPathComponent("real-captured.mbt.mbt").path))
        precondition(model.state == .result, "Real publication failed: \(String(describing: model.failure))")
        let observed = runtime.events.filter { $0.type == "capture_category" }
        precondition(observed.count == 16 && model.publication?.bundle.capturedDomains.count == 1)
        precondition(Set(observed.compactMap { $0.data?["domain"]?.string }) == Set(model.inventory.map(\.domain)))
        precondition(observed.contains { $0.data?["status"]?.string == "unavailable" })
        precondition(observed.contains { $0.data?["domain"]?.string == "shell-zsh" })
        let file = try target.resourceValues(forKeys: [.isRegularFileKey])
        precondition(file.isRegularFile == true && model.publication?.bundle.selectedItemCounts[packages.id] == 1)
        let permissions = try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as! NSNumber
        precondition(permissions.intValue & 0o777 == 0o600)
        let inspect = CoreRequest(.bundleInspect(path: target.path))
        runtime.start(inspect, location: CoreLocation(root: core, python: python, home: home, temporaryBase: root, toolDirectories: [bin]))
        await runtime.waitForCompletion()
        precondition(runtime.state == .completed && runtime.latestResult?.data?["selected_item_counts"]?.object?[packages.id] == .integer(1))
        model.scan(); await model.waitForCompletion()
        model.toggleAll(); model.selectItem(packages.id, item: "one", included: true)
        let staleTarget = root.appendingPathComponent("stale.mbt")
        model.prepare(destination: staleTarget); await model.waitForCompletion()
        try write("changed", mode)
        model.create(); await model.waitForCompletion()
        precondition(model.state == .failed && model.failure == .runtime(.coreFailure("stale_prepared_capture")) && !FileManager.default.fileExists(atPath: staleTarget.path))
        // A real category-only capture must not gain a Homebrew launch/save prerequisite.
        try FileManager.default.removeItem(at: bin.appendingPathComponent("brew"))
        model.scan(); await model.waitForCompletion()
        precondition(model.state == .review && model.categories.first { $0.id == packages.id }?.row.status == "unavailable")
        let shell = model.categories.first { $0.id == "shell-zsh" }!
        precondition(shell.selectable && !shell.itemSelectable)
        model.toggleAll(); model.selectCategory(shell.id, included: true)
        let categoryTarget = root.appendingPathComponent("category-only.mbt")
        model.prepare(destination: categoryTarget); await model.waitForCompletion()
        precondition(model.state == .confirmation && model.preparation?.summary.selectedItems == 0)
        model.create(); await model.waitForCompletion()
        precondition(model.state == .result && model.publication?.bundle.selectedCategories == [shell.id])
        precondition(model.publication?.bundle.itemCount == 0 && model.selection.items.isEmpty)
        let originalBundle = try Data(contentsOf: target)
        model.scan(); await model.waitForCompletion()
        model.toggleAll(); model.selectCategory(shell.id, included: true)
        model.prepare(destination: target); await model.waitForCompletion()
        precondition(model.state == .failed && (try? Data(contentsOf: target)) == originalBundle)
        model.scan(); await model.waitForCompletion()
        model.toggleAll(); model.selectCategory(shell.id, included: true)
        model.prepare(destination: target, replacementConfirmed: true); await model.waitForCompletion()
        precondition(model.state == .confirmation)
        try write("export EDITOR=nano\n", home.appendingPathComponent(".zshrc"))
        model.create(); await model.waitForCompletion()
        precondition(model.state == .failed && (try? Data(contentsOf: target)) == originalBundle)
        try write("export EDITOR=vi\n", home.appendingPathComponent(".zshrc"))
        model.scan(); await model.waitForCompletion()
        model.toggleAll(); model.selectCategory(shell.id, included: true)
        model.prepare(destination: target, replacementConfirmed: true); await model.waitForCompletion()
        precondition(model.state == .confirmation)
        model.create(); await model.waitForCompletion()
        precondition(model.state == .result && model.publication?.bundle.selectedCategories == [shell.id])
        precondition((try? Data(contentsOf: target)) != originalBundle)
        let safetyScript = root.appendingPathComponent("replacement-safety.py")
        try write("""
        import sys, hashlib
        from pathlib import Path
        from unittest.mock import patch
        sys.path.insert(0, sys.argv[1])
        import bundle
        target, stage, home = map(Path, sys.argv[2:])
        stage.mkdir()
        bundle.unpack(target, stage, str(home))
        original = target.read_bytes()
        fingerprint = hashlib.sha256(original).hexdigest()
        for method, error in [('validate_archive', bundle.Invalid('injected validation failure')), ('os.replace', OSError('injected publication failure'))]:
            with patch('bundle.' + method, side_effect=error):
                try:
                    bundle.pack(stage, target, str(home), replacement_sha256=fingerprint)
                    raise AssertionError('failure injection did not fail')
                except (bundle.Invalid, OSError):
                    pass
            assert target.read_bytes() == original
            assert not list(target.parent.glob('.bundle-*'))
        try:
            bundle.pack(stage, target, str(home), replacement_sha256='0' * 64)
            raise AssertionError('changed destination accepted')
        except bundle.Invalid:
            pass
        assert target.read_bytes() == original
        print('PASS: replacement validation/publication failures preserve original Bundle; changed digest rejected')
        """, safetyScript)
        let safety = Process()
        safety.executableURL = python
        safety.arguments = ["-B", safetyScript.path, core.appendingPathComponent("modules/bundle").path, target.path, root.appendingPathComponent("replacement-stage").path, home.path]
        try safety.run(); safety.waitUntilExit()
        precondition(safety.terminationStatus == 0)
        let afterHome = try snapshot(home), afterConfig = try snapshot(core.appendingPathComponent("config"))
        precondition(beforeHome == afterHome && beforeConfig == afterConfig)
        precondition(!FileManager.default.fileExists(atPath: marker.path) && !FileManager.default.fileExists(atPath: core.appendingPathComponent("logs").path))
        print("PASS: Swift → production Capture → private .mbt → authoritative inspection, real stale rejection and category-only save without Homebrew; HOME/config unchanged")
        try await workspacePrepare(root: root, repository: repository, core: core, home: home, bin: bin, python: python)
        try await overlapCore(root: root, core: core, home: home, bin: bin, python: python)
    }

    @MainActor static func workspacePrepare(root: URL, repository: URL, core: URL, home: URL, bin: URL, python: URL) async throws {
        let setup = root.appendingPathComponent("workspace-fixture.py")
        try write("""
        import sys
        from pathlib import Path
        sys.path.insert(0, sys.argv[1])
        from workspace_fixture import repository, linked
        home = Path(sys.argv[2])
        if sys.argv[3] == 'initial':
            base, oid = repository(home, 'Projects/base')
            linked(base, home / 'Projects/feature', oid)
            repository(home, 'Projects/ordinary')
        else:
            repository(home, 'standalone')
            repository(home, 'standalone/nested')
        """, setup)
        func fixtures(_ mode: String) throws {
            let process = Process(); process.executableURL = python
            process.arguments = ["-B", setup.path, repository.appendingPathComponent("scripts").path, home.path, mode]
            try process.run(); process.waitUntilExit(); precondition(process.terminationStatus == 0)
        }
        try fixtures("initial")
        try write("#!/bin/bash\necho 26.7.1\n", bin.appendingPathComponent("sw_vers"), executable: true)
        let before = try snapshot(home)
        let runtime = CoreRuntime(operationLogs: OperationLogStore(directory: root.appendingPathComponent("workspace-logs")))
        let location = CoreLocation(root: core, python: python, home: home, temporaryBase: root, toolDirectories: [bin])
        let model = CaptureModel(runtime: runtime, location: location)
        let destination = root.appendingPathComponent("workspace-confirmation.mbt")
        func prepare() async {
            model.prepare(destination: destination); await model.waitForCompletion()
            precondition(!model.savingAttempted && model.publication == nil)
            precondition(!FileManager.default.fileExists(atPath: destination.path))
            precondition(runtime.operation == .capturePrepare)
        }
        model.scan(); await model.waitForCompletion()
        precondition(model.state == .review && model.bulkState == .all)
        let git = model.categories.first { $0.id == "git-repositories" }!
        precondition(git.row.items.count == 3)
        let base = git.row.items.first { $0.label == "base" }!.itemID
        let ordinary = git.row.items.first { $0.label == "ordinary" }!.itemID
        await prepare(); precondition(model.state == .confirmation)
        precondition(model.preparation?.selection?.categories.contains("git-repositories") == true)
        model.editSelection(); model.selectItem(git.id, item: ordinary, included: false)
        await prepare(); precondition(model.state == .confirmation)
        precondition(model.preparation?.selection?.items[git.id]?.count == 2)
        model.editSelection(); model.selectItem(git.id, item: base, included: false)
        let conflictingSelection = model.selection
        await prepare()
        precondition(model.state == .failed && model.failure?.technicalReason == "workspace_dependency_missing")
        precondition(model.failure?.message.contains("base or parent") == true && model.canReviewSelection)
        precondition(model.selection == conflictingSelection)
        model.editSelection(); precondition(model.state == .review && model.failure == nil)
        model.selectCategory(git.id, included: false)
        await prepare(); precondition(model.state == .confirmation)
        precondition(model.preparation?.selection?.categories.contains(git.id) == false && model.preparation?.selection?.items[git.id] == nil)
        let after = try snapshot(home)
        precondition(after == before)
        try fixtures("overlap")
        let beforeOverlap = try snapshot(home)
        for (folders, repositories) in [(true, true), (true, false), (false, true), (false, false)] {
            model.scan(); await model.waitForCompletion()
            precondition(model.state == .review && model.bulkState == .all)
            precondition(model.categories.first { $0.id == git.id }?.row.items.count == 5)
            model.selectCategory("workspace-folders", included: folders)
            model.selectCategory(git.id, included: repositories)
            let requested = model.selection
            let target = root.appendingPathComponent("role-\(folders)-\(repositories).mbt")
            model.prepare(destination: target); await model.waitForCompletion()
            precondition(model.state == .confirmation && model.preparation?.selection == requested)
            precondition(!model.savingAttempted && !FileManager.default.fileExists(atPath: target.path))
            model.create(); await model.waitForCompletion()
            precondition(model.state == .result && model.publicationEvidence == .occurred)
            precondition(FileManager.default.fileExists(atPath: target.path))
            runtime.start(CoreRequest(.bundleInspect(path: target.path)), location: location)
            await runtime.waitForCompletion()
            precondition(runtime.state == .completed)
            let counts = runtime.latestResult?.data?["selected_item_counts"]?.object
            precondition(counts?["workspace-folders"] == .integer(folders ? 2 : 0))
            precondition(counts?[git.id] == .integer(repositories ? 5 : 0))
            print("PASS: Workspace/Git roles folders=\(folders), git=\(repositories): Scan → Review → Destination → Prepare → Confirmation → publication → bundle_inspect")
        }
        let afterOverlap = try snapshot(home)
        precondition(afterOverlap == beforeOverlap)
        print("PASS: Workspace/Git role matrix, ordinary/linked/nested checkouts and explicit dependencies; fixture HOME unchanged")
    }

    @MainActor static func overlapCore(root: URL, core: URL, home: URL, bin: URL, python: URL) async throws {
        // A macOS HOME already has Library. Establish it before Discovery so the
        // first catalog cache write does not change the observed top-level folders.
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Library"), withIntermediateDirectories: true)
        let app = home.appendingPathComponent("Applications/Fixture.app/Contents")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleIdentifier": "org.example.Fixture", "CFBundleExecutable": "Fixture"],
            format: .xml, options: 0).write(to: app.appendingPathComponent("Info.plist"))
        try write("#!/bin/sh\n", app.appendingPathComponent("MacOS/Fixture"), executable: true)
        let metadata: Object = ["casks": [
            ["token": "fixture-cask", "installed": "1.0", "tap": "homebrew/cask", "version": "1.0",
             "disabled": false, "sha256": String(repeating: "a", count: 64),
             "url": "https://example.org/fixture.dmg",
             "artifacts": [["app": ["Fixture.app"], "target": app.deletingLastPathComponent().path]]] as Object]]
        let metadataPath = bin.appendingPathComponent("cask.json")
        try JSONSerialization.data(withJSONObject: metadata).write(to: metadataPath)
        try write("""
        #!/bin/bash
        case "$*" in
          'list --formula'|'list --formula --full-name'|'list --formula --installed-on-request') exit 0;;
          --version) echo 'Homebrew 7.0.7';;
          help\\ *) echo "$2 --formula --cask --full-name --json --appdir";;
          'info --json=v2 --installed --cask'|'info --json=v2 --cask fixture-cask') cat \(quote(metadataPath.path));;
          'list --cask') echo fixture-cask;;
          --prefix) echo /opt/homebrew;;
          *) exit 99;;
        esac
        """, bin.appendingPathComponent("brew"), executable: true)
        try write("#!/bin/bash\necho '12345 Fixture (1.0)'\necho '67890 Other (1.0)'\n",
                  bin.appendingPathComponent("mas"), executable: true)
        let catalog = bin.appendingPathComponent("catalog.json")
        let helper = core.appendingPathComponent("modules/apps/application_identity.py")
        // Only external catalog transport is replaced in this disposable Core.
        try write(try String(contentsOf: helper) + "\ndef fetch_catalog(ids):\n    values = json.loads(Path("
                  + String(data: JSONSerialization.data(withJSONObject: catalog.path, options: [.fragmentsAllowed, .withoutEscapingSlashes]), encoding: .utf8)!
                  + ").read_bytes())\n    return {key: value for key, value in values.items() if key in ids}\n", helper)
        let location = CoreLocation(root: core, python: python, home: home, temporaryBase: root, toolDirectories: [bin])
        let runtime = CoreRuntime(operationLogs: nil), model = CaptureModel(runtime: CoreRuntime(operationLogs: nil), location: location)
        for (name, confirmed, onlyDuplicate) in [("unresolved", false, false), ("confirmed", true, false), ("only-duplicate", true, true)] {
            try JSONSerialization.data(withJSONObject: confirmed ? ["12345": "org.example.Fixture"] : [:]).write(to: catalog)
            model.scan(); await model.waitForCompletion()
            precondition(model.state == .review)
            model.toggleAll()
            model.selectCategory("homebrew-casks", included: true)
            model.selectItem("app-store", item: "12345", included: true)
            if !onlyDuplicate { model.selectItem("app-store", item: "67890", included: true) }
            let requested = model.selection, target = root.appendingPathComponent("overlap-\(name).mbt")
            model.prepare(destination: target); await model.waitForCompletion()
            precondition(model.state == .confirmation, "\(name): \(String(describing: model.failure))")
            let prepared = model.preparation!
            precondition(prepared.selection == requested && model.selection == requested)
            precondition((prepared.effectiveSelection != nil) == confirmed)
            precondition(prepared.summary.selectedItems == (confirmed ? (onlyDuplicate ? 1 : 2) : 3))
            let tasks = CaptureTaskPresentation(categories: prepared.inventory.map { CaptureCategory(row: $0) },
                selection: prepared.publicationSelection!, phase: .confirmation)
            precondition(tasks.domains.flatMap(\.items).count == prepared.summary.selectedItems)
            if confirmed { try overlapContractRejections(prepared) }
            model.create(); await model.waitForCompletion()
            precondition(model.state == .result, "\(name) publication: \(String(describing: model.failure))")
            precondition(model.publication!.bundle.itemCount == prepared.summary.selectedItems)
            let resultTasks = CaptureTaskPresentation(categories: prepared.inventory.map { CaptureCategory(row: $0) },
                selection: prepared.publicationSelection!, phase: .result, publication: model.publication)
            precondition(resultTasks.domains.flatMap(\.items).allSatisfy { $0.state == .completed })
            runtime.start(CoreRequest(.bundleInspect(path: target.path)), location: location)
            await runtime.waitForCompletion()
            precondition(runtime.state == .completed)
            precondition(runtime.latestResult?.data?["selected_item_counts"]?.object?["app-store"]?.integer == (confirmed ? (onlyDuplicate ? 0 : 1) : 2))
            // A publication with the original requested counts must still be rejected.
            if confirmed {
                let invalid: Object = ["publication_occurred": true, "destination": target.path,
                    "prepared_capture_id": prepared.preparedCaptureID,
                    "bundle": ["format_version": 1, "secure_component": false, "selected_categories": [],
                               "selected_item_counts": ["homebrew-casks": 1, "app-store": onlyDuplicate ? 1 : 2]]]
                let publication = try JSONDecoder().decode(CoreCapturePublication.self, from: JSONSerialization.data(withJSONObject: invalid))
                do { try publication.validate(preparation: prepared, destination: target); preconditionFailure("Original counts accepted") }
                catch {}
            }
        }
        model.scan(); await model.waitForCompletion()
        model.toggleAll(); model.selectCategory("homebrew-casks", included: true); model.selectCategory("app-store", included: true)
        let stale = root.appendingPathComponent("overlap-stale.mbt")
        model.prepare(destination: stale); await model.waitForCompletion()
        precondition(model.state == .confirmation && model.preparation?.effectiveSelection != nil)
        try FileManager.default.removeItem(at: home.appendingPathComponent("Library/Application Support/Macseed/ApplicationIdentities/12345.json"))
        try write("{}", catalog)
        model.create(); await model.waitForCompletion()
        precondition(model.state == .failed && model.failure?.technicalReason == "stale_prepared_capture")
        precondition(!FileManager.default.fileExists(atPath: stale.path))
        print("PASS: Swift → production Capture overlap: effective confirmation/publication, unresolved preservation, strict rejection and changed-decision stale protection")
    }

    static func overlapContractRejections(_ prepared: CoreCapturePreparation) throws {
        var invalid = prepared
        invalid.effectiveSelection = nil
        do { try invalid.validate(expected: prepared.selection); preconditionFailure("Missing effective scope accepted") } catch {}
        invalid = prepared; invalid.applicationDuplicates = nil
        do { try invalid.validate(expected: prepared.selection); preconditionFailure("Missing duplicate evidence accepted") } catch {}
        invalid = prepared; invalid.applicationDuplicates = []
        do { try invalid.validate(expected: prepared.selection); preconditionFailure("Empty duplicate evidence accepted") } catch {}
        invalid = prepared
        invalid.effectiveSelection = CoreCaptureSelection(categories: [], items: [:], secureIdentities: [])
        do { try invalid.validate(expected: prepared.selection); preconditionFailure("Unrelated reduction accepted") } catch {}
    }
}
