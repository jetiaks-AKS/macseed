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
    @MainActor static func render(_ model: CaptureModel, _ runtime: CoreRuntime, state: String) throws {
        _ = NSApplication.shared
        for (width, height) in [(785, 660), (985, 760), (1385, 1010)] {
            let content = VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        WorkspaceHeader(title: "Capture this Mac", subtitle: ProductTask.capture.subtitle, symbol: ProductTask.capture.symbol)
                        CaptureView(model: model, runtime: runtime, showsActions: false)
                    }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                CaptureActionsView(model: model, runtime: runtime).padding(.horizontal, 28).padding(.vertical, 12)
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
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/Debug/CaptureUIv2-\(state)-\(width).png"))
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
        let runtime = CoreRuntime()
        let model = CaptureModel(runtime: runtime, location: CoreLocation(root: core, python: python, home: root, temporaryBase: root, toolDirectories: []))
        model.scan(); await model.waitForCompletion()
        precondition(model.state == .review && model.selectedDomainCount == 2 && model.selectedItemCount == 2)
        precondition(model.bulkState == .all && model.selection.secureIdentities.isEmpty)
        try render(model, runtime, state: "review")
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

        let captureSummary = CaptureSummaryPresentation.review(categories: model.categories, domainCount: model.selectedDomainCount, itemCount: model.selectedItemCount)
        precondition(captureSummary.domainCount == model.selectedDomainCount && captureSummary.itemCount == model.selectedItemCount)
        precondition(captureSummary.attentionCount == 2 && captureSummary.unsupportedCount == 2)
        try render(model, runtime, state: "confirmation")
        let preparedScope = model.preparation!
        let plannedTasks = CaptureTaskPresentation(categories: preparedScope.inventory.map { CaptureCategory(row: $0) }, selection: preparedScope.selection!, phase: .confirmation)
        let waitingTasks = CaptureTaskPresentation(categories: model.categories, selection: model.selection, phase: .progress)
        precondition(plannedTasks.domains.map(\.id) == waitingTasks.domains.map(\.id))
        precondition(waitingTasks.domains.flatMap(\.items).allSatisfy { $0.state == .waiting && $0.item.reason == nil })
        precondition(plannedTasks.domains.flatMap(\.items).contains { $0.item.reason == "source_partial" })
        model.create(); await model.waitForCompletion()
        precondition(model.state == .result && model.publicationEvidence == .occurred && model.publication?.destination == target.path)
        precondition(model.publication?.bundle.capturedDomains.count == 2 && model.resultNotices.count == 1)
        try render(model, runtime, state: "result")
        let captured = model.publication!.bundle
        let resultTasks = CaptureTaskPresentation(categories: preparedScope.inventory.map { CaptureCategory(row: $0) }, selection: preparedScope.selection!,
            phase: .result, capturedDomains: captured.capturedDomains, notices: model.resultNotices)
        precondition(resultTasks.domains.map(\.id) == plannedTasks.domains.map(\.id))
        precondition(resultTasks.domains.first { $0.id == "homebrew-packages" }?.state == .partial)
        precondition(resultTasks.domains.first { $0.id == "macos-settings" }?.state == .completed)
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
            if mode == "stale_prepared_capture" {
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
        precondition(model.availableAreaCount == 7 && model.selectionSummary == "7 domains selected · 1 item selected")
        model.selectCategory("macos-finder", included: false)
        precondition(model.macOSSettings.state == .mixed && model.macOSSettings.summary == "5 of 6 selected")
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
        let sshResult = CaptureTaskPresentation(categories: sshPrepared.inventory.map { CaptureCategory(row: $0) }, selection: sshPrepared.selection!, phase: .result,
            notices: [DisplayCategory(id: sshCategory.id, title: sshCategory.title, symbol: sshCategory.symbol, items: sshCategory.notices)])
        precondition(sshResult.domains.first { $0.id == "ssh-configuration" }?.state == .partial)
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
        let unresolved = CaptureModel(runtime: CoreRuntime(resolver: CoreLocationResolver(resources: root.appendingPathComponent("missing-runtime"))))
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
        let runtime = CoreRuntime()
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
    }
}
