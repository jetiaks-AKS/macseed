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
    @MainActor static func sshHostSelectionChecks(model: CaptureModel, runtime: CoreRuntime, core: URL, root: URL) async throws {
        let hosts = ["github", "production", "home-server", "test-vps"]
        try JSONSerialization.data(withJSONObject: [row("ssh-configuration", mode: "items", items: hosts),
            row("macos-finder", mode: "category")]).write(to: core.appendingPathComponent("inventory.json"))
        let keyID = String(repeating: "a", count: 64)
        let identity: Object = ["item_id": keyID, "label": "fixture_key", "key_type": "ssh-ed25519",
            "validation": "candidate_requires_pair_validation", "fingerprint": "SHA256:" + Data(repeating: 1, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: "")]
        try JSONSerialization.data(withJSONObject: ["status": "present", "items": [identity]]).write(to: core.appendingPathComponent("secure-inventory.json"))
        model.scan(); await model.waitForCompletion()
        let ssh = model.categories.first { $0.id == "ssh-configuration" }!
        precondition(ssh.itemSelectable && model.selectionState(ssh) == .none && model.selection.secureIdentities.isEmpty)
        model.selectCategory(ssh.id, included: true)
        precondition(model.selectionState(ssh) == .all && model.selection.categories.contains(ssh.id))
        for host in hosts.suffix(2) { model.selectItem(ssh.id, item: host, included: false) }
        precondition(model.selection.items[ssh.id] == ["github", "production"])
        precondition(CaptureReviewPresentation.selectionLabel(ssh, model: model) == "2 of 4 selected")
        let selected = model.selection
        model.selectItem(ssh.id, item: "unknown", included: true)
        precondition(model.selection == selected)
        model.selectSecureIdentity(keyID, included: true)
        for _ in 0..<2 {
            model.toggleAll(in: .advanced)
            precondition(model.selection.items[ssh.id] == ["github", "production"] && model.selectedSecureIdentities == [keyID],
                         "Advanced bulk selection excludes both SSH profiles and keys")
        }
        model.selectItem(ssh.id, item: "production", included: false)
        precondition(model.selectedSecureIdentities == [keyID])
        model.selectItem(ssh.id, item: "production", included: true)
        model.selectSecureIdentity(keyID, included: false)
        precondition(model.selection == selected)
        try render(model, runtime, state: "ssh-host-selection", tree: CaptureHierarchy.disclosureIDs([ssh.id], scope: .advanced).subtracting([CaptureHierarchy.secureTransferID]))
        let expandedSSH = CaptureHierarchy.disclosureIDs([ssh.id, CaptureHierarchy.secureTransferID], scope: .advanced)
        precondition(expandedSSH.contains(CaptureHierarchy.sshID) && model.selection == selected)
        precondition(!model.selection.categories.contains(CaptureHierarchy.sshID) && model.selection.items[CaptureHierarchy.sshID] == nil)
        try render(model, runtime, state: "ssh-unified-config-only-mock-ui-light", tree: expandedSSH)
        model.selectSecureIdentity(keyID, included: true)
        try render(model, runtime, state: "ssh-unified-both-mock-ui-light", tree: expandedSSH)
        model.selectSecureIdentity(keyID, included: false)
        model.prepare(destination: root.appendingPathComponent("hosts.mbt")); await model.waitForCompletion()
        precondition(model.state == .confirmation && model.preparation?.summary.selectedItems == 2)
        precondition(model.preparation?.selection?.items[ssh.id] == ["github", "production"])
        model.editSelection(); model.selectItem(ssh.id, item: "production", included: false)
        precondition(model.preparation == nil && model.state == .review)
        model.selectItem(ssh.id, item: "github", included: false)
        precondition(model.selectionState(ssh) == .none && model.selection.items[ssh.id] == nil)
        precondition(model.selection.categories == ["macos-finder"] && model.selection.secureIdentities.isEmpty)
        model.selectCategory(ssh.id, included: true)
        precondition(model.selectedItems[ssh.id] == Set(hosts))
        model.selectItem(ssh.id, item: "home-server", included: false)
        model.prepare(destination: root.appendingPathComponent("saved-hosts.mbt")); await model.waitForCompletion()
        model.create(); await model.waitForCompletion()
        precondition(model.state == .result && model.publication?.bundle.selectedItemCounts[ssh.id] == 3)
        print("PASS: Capture Host default-off, full/subset/empty scope, invalid IDs, fresh confirmation, publication counts and native checkboxes")
    }
    @MainActor static func render(_ model: CaptureModel, _ runtime: CoreRuntime, state: String, expanded: Bool = false, settingsOnly: Bool = false, scrollToBottom: Bool = false, tree: Set<String>? = nil, dark: Bool = false) throws {
        guard !CommandLine.arguments.contains("--no-renders") else { return }
        _ = NSApplication.shared
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        for (width, viewportHeight) in [(785, 660), (985, 760), (1385, 1010)] {
            let height = settingsOnly ? 1120 : viewportHeight
            let content = VStack(spacing: 0) {
                WorkflowContentViewport(pinned: !settingsOnly && [.review, .confirmation, .result].contains(model.state)) {
                    VStack(alignment: .leading, spacing: 20) {
                        WorkspaceHeader(title: ProductTask.capture.title, subtitle: ProductTask.capture.subtitle, symbol: ProductTask.capture.symbol)
                        if settingsOnly {
                            CaptureMacOSSettingsView(model: model, childExpansion: .constant(true))
                                .modifier(WorkspaceCardSurface())
                        } else {
                            CaptureView(model: model, runtime: runtime, showsActions: false,
                                categoryTreeExpansion: tree.map { .constant($0) } ?? (expanded ? .constant(
                                    CaptureHierarchy.disclosureIDs(model.categories.map(\.id), scope: .ordinary)
                                        .union(CaptureHierarchy.disclosureIDs(model.categories.map(\.id), scope: .advanced))) : nil),
                                experiencedVisibility: state.hasPrefix("ssh-") ? .constant(true) : nil)
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
            func checkboxes(_ view: NSView) -> [NSButton] {
                if let button = view as? NSButton, button.target is NativeSelectionCheckbox.Coordinator { return [button] }
                return view.subviews.flatMap(checkboxes)
            }
            if [.confirmation, .result].contains(model.state) {
                precondition(checkboxes(host).isEmpty, "Prepared and published scope is read-only")
            }
            if state == "ssh-host-selection" {
                let boxes = checkboxes(host)
                let selected = model.selection
                for name in ["github", "production", "home-server", "test-vps"] {
                    let box = boxes.first { $0.accessibilityLabel() == name }!
                    precondition(box.state == (["github", "production"].contains(name) ? .on : .off))
                }
                for _ in 0..<2 {
                    let box = checkboxes(host).first { $0.accessibilityLabel() == "home-server" }!
                    precondition(NSApp.sendAction(box.action!, to: box.target, from: box))
                    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
                    host.layoutSubtreeIfNeeded()
                }
                precondition(model.selection == selected && model.selection.secureIdentities.isEmpty)
                precondition(checkboxes(host).contains { $0.accessibilityLabel() == "Select SSH Configuration" && $0.state == .mixed })
            }
            if state.hasPrefix("policy-review") {
                let actual = checkboxes(host)
                let visible = model.categories.filter { $0.selectable && (expanded || CaptureHierarchy.group(for: $0.id) == .otherFindings) }
                let expected = visible.count + (expanded ? visible.filter(\.itemSelectable).reduce(0) { $0 + $1.row.items.count } : 0)
                precondition(actual.count == expected, "Capture wrappers must not introduce selection checkboxes: \(actual.count) != \(expected)")
                precondition(actual.allSatisfy { $0.isEnabled && $0.target != nil && $0.action != nil && !($0.accessibilityLabel() ?? "").isEmpty })
                if let checkbox = actual.first(where: { $0.accessibilityLabel() == "Select future-eligible" }) {
                    let selection = model.selection
                    checkbox.performClick(nil)
                    precondition(model.selectedCategories.contains("future-eligible"))
                    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)); host.layoutSubtreeIfNeeded()
                    let updated = checkboxes(host).first { $0.accessibilityLabel() == "Select future-eligible" }!
                    updated.performClick(nil)
                    precondition(model.selection == selection)
                    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)); host.layoutSubtreeIfNeeded()
                }
            }
            if state.hasPrefix("policy-review") && expanded {
                let folders = model.categories.first { $0.id == "workspace-folders" }!
                let original = model.selection
                func flush() { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03)); host.layoutSubtreeIfNeeded() }
                checkboxes(host).first { $0.accessibilityLabel() == "Select Workspace Folders" }!.performClick(nil); flush()
                precondition(model.selectedItems[folders.id] == Set(folders.row.items.map(\.itemID)))
                checkboxes(host).first { $0.accessibilityLabel() == "Select Workspace Folders" }!.performClick(nil); flush()
                precondition(model.selectedItems[folders.id] == nil)
                for item in folders.row.items {
                    checkboxes(host).first { $0.accessibilityLabel() == item.label }!.performClick(nil); flush()
                }
                precondition(model.selectedItems[folders.id] == Set(folders.row.items.map(\.itemID)))
                checkboxes(host).first { $0.accessibilityLabel() == "Select Workspace Folders" }!.performClick(nil); flush()
                for id in original.items[folders.id] ?? [] { model.selectItem(folders.id, item: id, included: true) }
                flush(); precondition(model.selection == original, "Native folder category and six item controls preserve the other scopes")
            }
            if scrollToBottom {
                func scrollView(_ view: NSView) -> NSScrollView? {
                    (view as? NSScrollView) ?? view.subviews.lazy.compactMap(scrollView).first
                }
                if let scroll = scrollView(host), let document = scroll.documentView {
                    let y = document.isFlipped ? max(0, document.bounds.height - scroll.contentView.bounds.height) : 0
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: y)); scroll.reflectScrolledClipView(scroll.contentView)
                }
            }
            host.displayIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { preconditionFailure("Native Capture render unavailable") }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/Debug/CaptureUIv2-\(state)\(expanded ? "-expanded" : "")-\(width)\(dark ? "-dark" : "").png"))
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
        if CommandLine.arguments.contains("--secure-invalidation-only") {
            try await secureCaptureInvalidationCheck(root: root, repository: URL(fileURLWithPath: CommandLine.arguments[1]), python: python)
            return
        }
        if CommandLine.arguments.contains("--secure-capture-only") {
            try await secureCaptureChecks(root: root, repository: URL(fileURLWithPath: CommandLine.arguments[1]), python: python)
            return
        }
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
        secure_path = pathlib.Path('secure-inventory.json')
        secure = json.loads(secure_path.read_text()) if secure_path.exists() else dict(status='unavailable', items=[])
        assert selection is None or set(selection['secure_identities']) <= {item['item_id'] for item in secure['items']}
        if request['operation'] == 'capture_execute': assert selection['secure_identities'] == []
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
        for row in rows:
            if request['operation'] == 'capture_execute' and mode == 'missing_category_event' and row['domain'] == 'homebrew-packages': continue
            emit('capture_category', {key:row[key] for key in ('domain', 'status', 'reason')})
        extra = pathlib.Path('extra-notices.json')
        if request['operation'] == 'capture_execute' and extra.exists():
            for event in json.loads(extra.read_text()): emit('capture_category', event)
        emit('phase_completed', dict(phase='discovery'))
        if selection is not None and mode in ('invalid_workspace_selection', 'workspace_dependency_missing', 'workspace_path_conflict', 'capture_source_unavailable'):
            emit('failed', dict(code=mode, publication_occurred=False)); sys.exit(2)
        if request['operation'] == 'capture_prepare':
            summary = dict(selected_domains=0, selected_items=0, secure_identity_count=0)
            if selection:
                summary['selected_domains'] = len(selection['categories']) + len(selection['items'])
                summary['selected_items'] = sum(map(len, selection['items'].values())) + sum(len(row['items']) for row in rows if row['domain'] in selection['categories'])
                summary['secure_identity_count'] = len(selection['secure_identities'])
            emit('result', dict(prepared_capture_id='a'*64, inventory=[] if mode == 'empty_inventory' else rows,
                 selection=selection, summary=summary, secure_identities=secure))
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
        if mode == 'missing_item_counts': counts = {}
        if mode == 'wrong_item_counts': counts = {key:value+1 for key,value in counts.items()}
        emit('result', dict(publication_occurred=mode!='unpublished', destination=params['destination'],
             prepared_capture_id='b'*64 if mode=='wrong_binding' else 'a'*64,
             bundle=dict(format_version=1, selected_categories=[row['domain'] for row in rows if row['domain'] in selection['categories'] and row['selection_mode']=='category'], selected_item_counts=counts, secure_component=False)))
        emit('completed'); sys.exit(0)
        """, core.appendingPathComponent("fixture.py"))
        let runtime = CoreRuntime(operationLogs: nil)
        let model = CaptureModel(runtime: runtime, location: CoreLocation(root: core, python: python, home: root, temporaryBase: root, toolDirectories: []))
        if CommandLine.arguments.contains("--ssh-confirmation-only") {
            let id = String(repeating: "a", count: 64)
            try JSONSerialization.data(withJSONObject: [row("ssh-configuration", mode: "category")]).write(to: core.appendingPathComponent("inventory.json"))
            try JSONSerialization.data(withJSONObject: ["status": "present", "items": [[
                "item_id": id, "label": "fixture-key", "key_type": "ssh-ed25519", "validation": "candidate_requires_pair_validation",
                "fingerprint": "SHA256:" + Data(repeating: 1, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: "")]]])
                .write(to: core.appendingPathComponent("secure-inventory.json"))
            model.scan(); await model.waitForCompletion()
            model.selectCategory("ssh-configuration", included: true)
            for secure in [false, true] {
                if model.state == .confirmation { model.editSelection() }
                model.selectSecureIdentity(id, included: secure)
                model.prepare(destination: root.appendingPathComponent(secure ? "secure.mbt" : "settings.mbt")); await model.waitForCompletion()
                precondition(model.state == .confirmation)
                let included = !model.preparation!.publicationSelection!.secureIdentities.isEmpty
                precondition(included == secure)
                let message = CaptureModel.confirmationPrivacyMessage(includesSSHIdentities: included)
                precondition(message.contains("not encrypted") && !message.contains("~/.ssh") && !message.contains("manually"))
                precondition(message.contains("passphrase") == secure && message.contains("SSH identities") == secure)
                if secure { precondition(message.contains("encrypted separately") && message.contains("safe")) }
            }
            precondition(!FileManager.default.fileExists(atPath: root.appendingPathComponent("secure.mbt").path), "Confirmation does not save or import")
            print("PASS: Capture Confirmation concise encryption boundary and passphrase disclosure only for selected SSH identities; no destination restriction")
            return
        }
        if CommandLine.arguments.contains("--ssh-host-selection-only") {
            try await sshHostSelectionChecks(model: model, runtime: runtime, core: core, root: root)
            return
        }
        if CommandLine.arguments.contains("--capture-disclosure-only") {
            try await captureDisclosureChecks(model: model, runtime: runtime, core: core)
            return
        }
        if CommandLine.arguments.contains("--secure-selection-only") {
            try await secureSelectionChecks(model: model, core: core)
            return
        }
        if CommandLine.arguments.contains("--capture-result-only") {
            try await captureResultChecks(model: model, runtime: runtime, core: core, root: root)
            return
        }
        if CommandLine.arguments.contains("--capture-visual-only") {
            try await captureVisualChecks(model: model, runtime: runtime, core: core)
            return
        }
        if CommandLine.arguments.contains("--capture-policy-only") {
            try await capturePolicyChecks(model: model, runtime: runtime, core: core, root: root)
            return
        }
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


        try await captureResultChecks(model: model, runtime: runtime, core: core, root: root)
        try await capturePolicyChecks(model: model, runtime: runtime, core: core, root: root)
        try await captureVisualChecks(model: model, runtime: runtime, core: core)
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
        for mode in ["stale_prepared_capture", "execute_failure", "unpublished", "wrong_binding", "missing_item_counts", "wrong_item_counts", "kill_save", "slow_save", "published_cancel"] {
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
            precondition(model.state != .result && model.publication == nil && model.preparation == nil && model.resultPresentation == nil)
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
        model.selectCategory("ssh-configuration", included: true)
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
        try await secureSelectionChecks(model: model, core: core)
        try await realCore(root: root, repository: URL(fileURLWithPath: CommandLine.arguments[1]), python: python)
        try await secureCaptureChecks(root: root, repository: URL(fileURLWithPath: CommandLine.arguments[1]), python: python)
    }
    @MainActor static func secureSelectionChecks(model: CaptureModel, core: URL) async throws {
        let path = core.appendingPathComponent("inventory.json"), securePath = core.appendingPathComponent("secure-inventory.json")
        let original = try Data(contentsOf: path)
        defer { try? original.write(to: path); try? FileManager.default.removeItem(at: securePath) }
        try write("success", core.appendingPathComponent("mode"))
        let rows = [row("homebrew-packages", mode: "items", items: ["fixture-package"]),
                    row("ssh-configuration", mode: "category"), row("git-configuration", mode: "category")]
        try JSONSerialization.data(withJSONObject: rows).write(to: path)
        let ids = [String(repeating: "a", count: 64), String(repeating: "b", count: 64)]
        let identities: [Object] = ids.enumerated().map { index, id in
            ["item_id": id, "label": "fixture_key_\(index)", "key_type": "ssh-ed25519", "validation": "candidate_requires_pair_validation",
             "fingerprint": "SHA256:" + Data(repeating: UInt8(index + 1), count: 32).base64EncodedString().replacingOccurrences(of: "=", with: "")]
        }
        try JSONSerialization.data(withJSONObject: ["status": "present", "items": identities]).write(to: securePath)
        model.scan(); await model.waitForCompletion()
        func check(_ state: SelectionState, _ status: String) {
            let view = CaptureSecureTransferView(inventory: model.secureInventory, selected: model.selectedSecureIdentities)
            precondition(view.selectionState == state && view.selectionStatus == status)
        }
        precondition(model.state == .review && model.selectedSecureIdentities.isEmpty)
        check(.none, "Off")
        let ordinary = model.selection
        model.selectAllSecureIdentities(included: true)
        check(.all, "All Selected")
        precondition(model.selection.secureIdentities == ids && model.selection.categories == ordinary.categories && model.selection.items == ordinary.items)
        precondition(model.selectedDomainCount == 1 && model.selectedItemCount == 1)
        model.selectSecureIdentity(ids[0], included: false)
        check(.mixed, "1 of 2 selected")
        for _ in 0..<2 {
            model.toggleAll(in: .advanced)
            precondition(model.selectedSecureIdentities == [ids[1]], "Advanced bulk controls must preserve partial secure selection")
        }
        model.selectCategory("ssh-configuration", included: true)
        precondition(model.selectedSecureIdentities == [ids[1]])
        model.selectAllSecureIdentities(included: true)
        check(.all, "All Selected")
        model.selectAllSecureIdentities(included: false)
        check(.none, "Off")
        precondition(model.selectedCategories.contains("ssh-configuration"), "Clearing identities must preserve SSH Configuration")
        model.toggleAll(in: .advanced); model.toggleAll(in: .advanced)
        check(.none, "Off")
        model.selectSecureIdentity(ids[0], included: true)
        check(.mixed, "1 of 2 selected")
        model.selectSecureIdentity(ids[1], included: true)
        check(.all, "All Selected")
        for _ in 0..<2 {
            model.toggleAll(in: .advanced)
            precondition(model.selectedSecureIdentities == Set(ids), "Advanced bulk controls must preserve all secure selection")
        }
        model.prepare(destination: core.appendingPathComponent("selection-only.mbt")); await model.waitForCompletion()
        precondition(model.state == .confirmation && model.preparation?.selection?.secureIdentities == ids)
        model.selectAllSecureIdentities(included: false)
        precondition(model.preparation != nil && model.selectedSecureIdentities == Set(ids), "Confirmation must remain read-only")
        model.editSelection()
        precondition(model.preparation == nil)
        model.selectAllSecureIdentities(included: false)
        precondition(model.preparation == nil && model.selectedSecureIdentities.isEmpty)
        model.prepare(destination: core.appendingPathComponent("fresh-selection-only.mbt")); await model.waitForCompletion()
        precondition(model.preparation?.selection?.secureIdentities.isEmpty == true && model.preparation?.summary.secureIdentityCount == 0)
        model.editSelection()
        model.selectAllSecureIdentities(included: true)
        for category in model.categories { model.selectCategory(category.id, included: false) }
        precondition(model.canCreate && model.selectedDomainCount == 0 && model.selectedItemCount == 0)
        precondition(model.bulkState(in: .advanced) == .none && model.selection.secureIdentities == ids)
        let advancedDisclosures = CaptureHierarchy.disclosureIDs(model.categories.map(\.id), scope: .advanced)
        precondition(!advancedDisclosures.contains(CaptureHierarchy.secureTransferID))
        let expanded: Set<String> = [CaptureHierarchy.secureTransferID]
        let toggled = CaptureHierarchy.toggled(expanded, ids: advancedDisclosures)
        precondition(toggled.contains(CaptureHierarchy.secureTransferID) && model.selection.secureIdentities == ids)
        model.prepare(destination: core.appendingPathComponent("secure-only-selection.mbt")); await model.waitForCompletion()
        precondition(model.state == .confirmation && model.preparation?.summary.selectedDomains == 0
            && model.preparation?.summary.selectedItems == 0 && model.preparation?.summary.secureIdentityCount == 2)
        model.scan(); await model.waitForCompletion()
        check(.none, "Off")
        let summary = CaptureSummaryPresentation.review(categories: model.categories, domainCount: model.selectedDomainCount,
            itemCount: model.selectedItemCount, selectedDomains: Set(model.selection.categories), secureIdentityCount: model.selectedSecureIdentities.count)
        precondition(summary.attentionCount == 0, "Unselected identities must not fabricate attention")
        print("PASS: Secure master OFF-PARTIAL-ALL, independent Advanced/SSH Configuration/disclosure, secure-only preparation, fresh Scan reset and ordinary counts")
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
        let inventoryDomains = Set(model.inventory.map(\.domain))
        precondition(inventoryDomains.count == model.inventory.count, "Capture inventory domains must be unique")
        let observedDomains = observed.map { event -> String in
            guard let domain = event.data?["domain"]?.string, !domain.isEmpty,
                  inventoryDomains.contains(domain) else {
                preconditionFailure("Capture category event must name an inventory domain")
            }
            return domain
        }
        precondition(observedDomains.count == model.inventory.count, "Each inventory domain must emit one Capture category event")
        precondition(Set(observedDomains).count == observedDomains.count, "Capture category events must not duplicate domains")
        precondition(Set(observedDomains) == inventoryDomains, "Capture category events must cover the inventory exactly")
        precondition(inventoryDomains.contains("vscode-workspaces"), "Capture inventory must include the optional workspace scope")
        precondition(model.publication?.bundle.capturedDomains == Set(["homebrew-packages"]))
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

    @MainActor static func captureResultChecks(model: CaptureModel, runtime: CoreRuntime, core: URL, root: URL) async throws {
        let inventoryPath = core.appendingPathComponent("inventory.json")
        let extras = core.appendingPathComponent("extra-notices.json")
        let original = try Data(contentsOf: inventoryPath)
        defer { try! original.write(to: inventoryPath); try? FileManager.default.removeItem(at: extras) }
        for variant in ["clean", "warning", "independent", "missing_category_event"] {
            let rows = [row("homebrew-packages", mode: "items", items: (1...6).map { "package-\($0)" }, reason: ["clean", "missing_category_event"].contains(variant) ? nil : "source_partial"),
                        row("macos-finder", mode: "category", reason: variant == "independent" ? "source_partial" : nil),
                        row("vscode-settings", mode: "category"),
                        row("ssh-configuration", mode: "category", reason: "source_partial"),
                        row("shell-zsh", mode: "category", status: "unsupported", reason: "source_excluded"),
                        row("git-repositories", mode: "items", status: "unavailable", reason: "tool_unavailable")]
            try JSONSerialization.data(withJSONObject: rows).write(to: inventoryPath)
            let events: [Object] = variant == "independent" ? [
                ["domain": "homebrew-packages", "status": "present", "reason": "source_partial"],
                ["domain": "homebrew-packages", "status": "present", "reason": "tool_unavailable"],
                ["domain": "homebrew-packages", "status": "present", "reason": "tool_unavailable"]] : []
            try JSONSerialization.data(withJSONObject: events).write(to: extras)
            try write("success", core.appendingPathComponent("mode"))
            model.scan(); await model.waitForCompletion()
            precondition(model.resultPresentation == nil && !model.selection.categories.contains("ssh-configuration"))
            model.prepare(destination: root.appendingPathComponent("result-\(variant).mbt")); await model.waitForCompletion()
            precondition(model.state == .confirmation && model.resultPresentation == nil)
            if variant == "missing_category_event" { try write(variant, core.appendingPathComponent("mode")) }
            model.create(); await model.waitForCompletion()
            precondition(model.state == .result && model.publicationEvidence == .occurred)
            let result = model.resultPresentation!
            precondition(result.scope == "3 domains · 6 items saved" && result.destination == model.destination)
            precondition(model.publication!.bundle.capturedDomains == ["homebrew-packages", "macos-finder", "vscode-settings"])
            precondition(model.resultNotices.allSatisfy { !["ssh-configuration", "shell-zsh", "git-repositories"].contains($0.id) })
            let expectedIssues = variant == "clean" ? 0 : variant == "independent" ? 3 : 1
            precondition(result.attention.flatMap(\.items).count == expectedIssues)
            precondition(result.attention.map(\.id) == (variant == "clean" ? [] : variant == "independent" ? ["homebrew-packages", "macos-finder"] : ["homebrew-packages"]))
            precondition(result.affectedCount == (variant == "clean" ? 0 : variant == "independent" ? 2 : 1))
            precondition(result.attentionSummary == "\(result.affectedCount) affected " + (result.affectedCount == 1 ? "category" : "categories"))
            if variant == "missing_category_event" {
                precondition(result.attention[0].items[0].status == .unverified && model.publicationEvidence == .occurred)
                precondition(CaptureResultPresentation.explanation(result.attention[0].items[0]).contains("could not be confirmed"))
            }
            if variant == "independent" {
                precondition(model.resultNotices.count == 5, "Keep raw selected event evidence; deduplicate only the presentation")
                precondition(result.attention[0].items.map(\.reason) == ["source_partial", "tool_unavailable"])
            }
            try render(model, runtime, state: "closure-result-" + variant)
            try render(model, runtime, state: "closure-result-" + variant, dark: true)
            let requests = try Data(contentsOf: core.appendingPathComponent("requests.jsonl"))
            model.done()
            precondition(model.state == .idle && model.resultPresentation == nil && model.resultNotices.isEmpty
                && model.publication == nil && model.destination == nil && model.preparation == nil && model.operationID == nil)
            precondition((try! Data(contentsOf: core.appendingPathComponent("requests.jsonl"))) == requests)
            model.scan(); await model.waitForCompletion()
            model.prepare(destination: root.appendingPathComponent("again-\(variant).mbt")); await model.waitForCompletion()
            model.create(); await model.waitForCompletion()
            precondition(model.resultPresentation != nil)
            model.scan(); await model.waitForCompletion()
            precondition(model.state == .review && model.resultPresentation == nil && model.publication == nil && model.resultNotices.isEmpty && model.destination == nil)
        }
        print("PASS: compact Capture Result uses exact validated publication counts, selected warnings only, independent issues without duplicates; unselected SSH/unsupported/unavailable excluded; Done and Capture Again reset")
    }

    @MainActor static func capturePolicyChecks(model: CaptureModel, runtime: CoreRuntime, core: URL, root: URL) async throws {
        let inventoryPath = core.appendingPathComponent("inventory.json"), mode = core.appendingPathComponent("mode")
        let original = try Data(contentsOf: inventoryPath)
        defer { try! original.write(to: inventoryPath); try! write("success", mode) }
        let groups = WorkspacePresentationTaxonomy.Group.allCases
        let ordinary = groups.filter { [.applicationsTools, .macOSSettings, .vscode].contains($0) }.flatMap(\.domains)
        let advanced = WorkspacePresentationTaxonomy.Group.advanced.domains
        let itemDomains: Set<String> = ["app-store", "homebrew-casks", "homebrew-packages", "vscode-extensions", "git-configuration", "git-repositories", "workspace-folders", "vscode-workspaces"]
        let folderIDs = (1...6).map { "folder-\($0)" }
        let inventory = (ordinary + advanced).map { row($0, mode: itemDomains.contains($0) ? "items" : "category",
            items: $0 == "workspace-folders" ? folderIDs : itemDomains.contains($0) ? ["one", "two"] : [],
            reason: $0 == "git-configuration" ? "source_partial" : nil) }
            + [row("future-eligible", mode: "category"), row("future-unsupported", mode: "future_mode", status: "unsupported")]
        try JSONSerialization.data(withJSONObject: inventory).write(to: inventoryPath)
        try write("success", mode)
        model.scan(); await model.waitForCompletion()
        precondition(model.state == .review && model.inventory.count == inventory.count)
        precondition(Set(model.selection.categories) == Set(ordinary) && model.selection.items.isEmpty)
        precondition(model.selectedDomainCount == ordinary.count && model.selectedItemCount == ordinary.filter(itemDomains.contains).count * 2)
        precondition(model.bulkState(in: .ordinary) == .all && model.bulkState(in: .advanced) == .none)
        precondition(model.categories(in: .advanced).allSatisfy { model.selectionState($0) == .none })
        precondition(CaptureReviewRow.project(model.categories(in: .advanced)).contains(where: \.needsAttention))
        precondition(!model.selectedCategories.contains("future-eligible"))
        precondition(CaptureReviewRow.project(model.categories).contains(where: { $0.id == "workspace-folders" }))
        precondition(CaptureReviewPresentation.attention(model.categories(in: .advanced), model: model) == nil,
            "An unselected optional limitation must not become a Capture warning")
        precondition(CaptureReviewPresentation.summary([], model: model) == "Unavailable")
        precondition(CaptureReviewPresentation.summary(model.categories(in: .ordinary), model: model) == "All Selected")
        precondition(CaptureReviewPresentation.summary(model.categories(in: .advanced), model: model) == "Not Selected")
        precondition(CaptureReviewPresentation.summary(model.categories.filter { $0.id == "future-unsupported" }, model: model) == "Unavailable")
        let initial = model.selection
        let macOS = CaptureReviewPresentation.bulkCategories(model.categories, group: .macOSSettings)
        precondition(Set(macOS.map(\.id)) == Set(CaptureMacOSSettingsGroup.domainIDs))
        model.toggleCategories(macOS)
        precondition(model.macOSSettings.state == .none && model.selection.categories.count == ordinary.count - 6)
        model.toggleCategories(macOS)
        precondition(model.selection == initial)
        model.selectCategory(macOS[0].id, included: false)
        precondition(CaptureReviewPresentation.summary(macOS, model: model) == "Partially Selected")
        precondition(macOS.dropFirst().allSatisfy { model.selectionState($0) == .all })
        model.selectCategory(macOS[0].id, included: true)
        precondition(model.selection == initial)
        let apps = CaptureReviewPresentation.bulkCategories(model.categories, group: .applicationsTools)
        let extras = CaptureReviewPresentation.bulkCategories(model.categories, group: .vscode)
        let advancedControls = CaptureReviewPresentation.bulkCategories(model.categories, group: .advanced)
        precondition(apps.map(\.id) == WorkspacePresentationTaxonomy.Group.applicationsTools.domains)
        precondition(extras.map(\.id) == ["vscode-extensions", "vscode-settings"])
        let displayedAdvanced = CaptureHierarchy.project(CaptureReviewRow.project(model.categories)).first { $0.group == .advanced }!.rows.flatMap(\.categories).filter { $0.id != "ssh-configuration" }
        func assertAdvanced(_ state: SelectionState, _ summary: String, _ action: String) {
            precondition(advancedControls.map(\.id) == displayedAdvanced.map(\.id), "Advanced bulk controls must cover the same domains as the displayed summary, including Workspace Folders")
            precondition(model.bulkState(for: advancedControls) == state && model.bulkState(in: .advanced) == state)
            precondition(CaptureReviewPresentation.summary(displayedAdvanced, model: model) == summary)
            precondition(model.bulkState(for: advancedControls).bulkActionTitle == action)
            let current = model.selection
            precondition(current.categories.filter(CaptureSelectionScope.ordinary.contains) == initial.categories
                && current.items.filter { CaptureSelectionScope.ordinary.contains($0.key) } == initial.items,
                "Advanced bulk actions must preserve ordinary selection exactly")
        }
        assertAdvanced(.none, "Not Selected", "Select All")
        precondition(model.selectedItems["workspace-folders"] == nil)
        model.toggleCategories(advancedControls)
        assertAdvanced(.all, "All Selected", "Deselect All")
        precondition(model.selectedItems["workspace-folders"] == Set(folderIDs), "Explicit Advanced Select All must include all six folders")
        precondition(model.selection.categories.contains("workspace-folders") && model.selection.items["workspace-folders"] == nil,
            "All six stable folder IDs retain compact whole-domain encoding")
        let allAdvanced = model.selection
        model.prepare(destination: root.appendingPathComponent("all-advanced-folders.mbt")); await model.waitForCompletion()
        precondition(model.state == .confirmation && model.preparation?.selection == allAdvanced)
        precondition(model.preparation?.inventory.first { $0.domain == "workspace-folders" }?.items.map(\.itemID) == folderIDs)
        model.editSelection(); precondition(model.selection == allAdvanced)
        model.selectItem("workspace-folders", item: folderIDs.last!, included: false)
        assertAdvanced(.mixed, "Partially Selected", "Select All")
        precondition(model.selection.items["workspace-folders"] == Array(folderIDs.dropLast()))
        let request = try JSONSerialization.jsonObject(with: CoreRequest(.capturePrepare(selection: model.selection), operationID: "advanced-folder-subset").encoded()) as! Object
        let encoded = (request["parameters"] as! Object)["selection"] as! Object
        precondition((encoded["items"] as! Object)["workspace-folders"] as? [String] == Array(folderIDs.dropLast()))
        precondition(!(encoded["categories"] as! [String]).contains("workspace-folders"))
        model.toggleCategories(advancedControls)
        assertAdvanced(.all, "All Selected", "Deselect All")
        precondition(model.selectedItems["workspace-folders"] == Set(folderIDs))
        model.toggleCategories(advancedControls)
        assertAdvanced(.none, "Not Selected", "Select All")
        precondition(model.selectedItems["workspace-folders"] == nil)
        // Manually selected folders participate in the same explicit Deselect All.
        for id in folderIDs { model.selectItem("workspace-folders", item: id, included: true) }
        assertAdvanced(.mixed, "Partially Selected", "Select All")
        for category in advancedControls where category.id != "workspace-folders" { model.selectCategory(category.id, included: true) }
        assertAdvanced(.all, "All Selected", "Deselect All")
        model.toggleCategories(advancedControls)
        assertAdvanced(.none, "Not Selected", "Select All")
        precondition(model.selectedItems["workspace-folders"] == nil && model.selection == initial)
        print("PASS: Advanced bulk scope matches summary; six folders selected/cleared, manual folders cleared, partial Select All, ordinary scope preserved and compact/subset Core requests unchanged")
        model.toggleCategories(apps)
        precondition(model.bulkState(for: apps) == .none && model.bulkState(for: extras) == .all && model.macOSSettings.state == .all)
        model.toggleCategories(extras)
        precondition(model.bulkState(for: apps) == .none && model.bulkState(for: extras) == .none && model.macOSSettings.state == .all)
        model.toggleCategories(advancedControls)
        precondition(model.selectedItems["workspace-folders"] == Set(folderIDs), "Advanced Select All deliberately includes its entire eligible scope")
        precondition(CaptureReviewPresentation.attention(advancedControls, model: model) == "Selected Requirements Need Attention")
        model.selectCategory("vscode-workspaces", included: false)
        precondition(model.selectedItems["workspace-folders"] == Set(folderIDs), "Individual descriptor changes preserve explicit folder choices")
        model.selectCategory("vscode-workspaces", included: true)
        model.toggleCategories(advancedControls)
        precondition(model.selectedItems["workspace-folders"] == nil, "Advanced Deselect All also clears folders")
        precondition(CaptureReviewRow.project(model.categories).contains(where: { $0.id == "workspace-folders" }))
        model.toggleCategories(apps); model.toggleCategories(extras)
        precondition(model.selection == initial)
        func scopeSelection(_ scope: CaptureSelectionScope) -> CoreCaptureSelection {
            .init(categories: model.selection.categories.filter(scope.contains), items: model.selection.items.filter { scope.contains($0.key) }, secureIdentities: [])
        }
        model.selectItem("git-repositories", item: "one", included: true)
        model.selectItem("vscode-workspaces", item: "two", included: true)
        model.selectCategory("ssh-configuration", included: true)
        let advancedSubset = scopeSelection(.advanced)
        precondition(model.bulkState(in: .advanced) == .mixed && model.selection.items["vscode-workspaces"] == ["two"])
        precondition(model.selection.items["workspace-folders"] == nil && !model.selection.categories.contains("workspace-folders"))
        model.toggleAll()
        precondition(model.bulkState == .none && scopeSelection(.advanced) == advancedSubset && model.canCreate)
        model.toggleAll()
        precondition(model.bulkState == .all && scopeSelection(.advanced) == advancedSubset)
        model.selectItem("vscode-extensions", item: "two", included: false)
        precondition(model.selectedCategories.contains("vscode-settings") && model.selection.items["vscode-extensions"] == ["one"])
        model.selectCategory("vscode-settings", included: false)
        precondition(model.selection.items["vscode-extensions"] == ["one"])
        let ordinarySubset = scopeSelection(.ordinary)
        model.toggleAll(in: .advanced)
        precondition(model.bulkState(in: .advanced) == .all && scopeSelection(.ordinary) == ordinarySubset)
        precondition(Set(scopeSelection(.advanced).categories) == Set(advanced).subtracting(["ssh-configuration"]) && scopeSelection(.advanced).items.isEmpty)
        model.toggleAll(in: .advanced)
        precondition(model.bulkState(in: .advanced) == .none && scopeSelection(.ordinary) == ordinarySubset)
        model.selectItem("vscode-workspaces", item: "two", included: true)
        model.selectItem("workspace-folders", item: folderIDs[0], included: true)
        let requested = model.selection
        let ids = model.categories.map(\.id) + ["macos-settings"]
        let ordinaryIDs = CaptureHierarchy.disclosureIDs(ids, scope: .ordinary)
        let advancedIDs = CaptureHierarchy.disclosureIDs(ids, scope: .advanced)
        var expanded = CaptureHierarchy.toggled([], ids: advancedIDs)
        expanded = CaptureHierarchy.toggled(expanded, ids: ordinaryIDs)
        precondition(advancedIDs.isSubset(of: expanded) && ordinaryIDs.isSubset(of: expanded))
        expanded = CaptureHierarchy.toggled(expanded, ids: ordinaryIDs)
        precondition(expanded == advancedIDs && model.selection == requested)
        expanded = CaptureHierarchy.toggled(expanded, ids: advancedIDs)
        precondition(expanded.isEmpty && model.selection == requested)
        try render(model, runtime, state: "policy-review")
        try render(model, runtime, state: "policy-review-advanced", scrollToBottom: true)
        try render(model, runtime, state: "policy-review-advanced", expanded: true, scrollToBottom: true)
        try render(model, runtime, state: "policy-review", expanded: true)
        model.prepare(destination: root.appendingPathComponent("policy.mbt")); await model.waitForCompletion()
        precondition(model.state == .confirmation && model.selection == requested && model.preparation?.selection == requested)
        try render(model, runtime, state: "policy-confirmation", expanded: true)
        try render(model, runtime, state: "policy-confirmation", expanded: true, dark: true)
        model.editSelection()
        precondition(model.selection == requested && model.preparation == nil)
        model.selectItem("git-repositories", item: "one", included: true)
        precondition(model.preparation == nil)
        let changed = model.selection
        try write("workspace_dependency_missing", mode)
        model.prepare(destination: root.appendingPathComponent("policy.mbt")); await model.waitForCompletion()
        precondition(model.state == .failed && model.canReviewSelection && model.selection == changed && model.preparation == nil)
        model.editSelection(); precondition(model.state == .review && model.selection == changed)
        try write("success", mode)
        model.prepare(destination: root.appendingPathComponent("policy.mbt")); await model.waitForCompletion()
        precondition(model.preparation?.selection == changed)
        model.create(); await model.waitForCompletion()
        precondition(model.state == .result && model.publicationEvidence == .occurred)
        precondition(model.publication?.bundle.selectedItemCounts["vscode-workspaces"] == 1)
        try render(model, runtime, state: "policy-result", expanded: true)
        try render(model, runtime, state: "policy-result", expanded: true, dark: true)
        model.scan(); await model.waitForCompletion()
        precondition(model.selection == initial && model.bulkState(in: .advanced) == .none)
        let sent = try String(contentsOf: core.appendingPathComponent("requests.jsonl")).split(separator: "\n").map {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as! Object
        }
        precondition((sent.last!["parameters"] as! Object)["selection"] is NSNull, "Scan must still inspect the complete inventory")
        let execute = sent.last { $0["operation"] as? String == "capture_execute" }!["parameters"] as! Object
        let executed = try JSONDecoder().decode(CoreCaptureSelection.self, from: JSONSerialization.data(withJSONObject: execute["selection"]!))
        precondition(executed == changed && executed.items["vscode-workspaces"] == ["two"])

        // Advanced-only and unavailable observations remain honest and explicit.
        var advancedOnly = advanced.map { row($0, mode: itemDomains.contains($0) ? "items" : "category", items: itemDomains.contains($0) ? ["one", "two"] : []) }
        advancedOnly += [row("vscode-settings", mode: "category", status: "observation_error", reason: "observation_failed"),
                         row("homebrew-casks", mode: "items", status: "unsupported", items: ["one"], reason: "source_unsupported"),
                         row("future-eligible", mode: "category")]
        try JSONSerialization.data(withJSONObject: advancedOnly).write(to: inventoryPath)
        model.scan(); await model.waitForCompletion()
        precondition(model.state == .review && model.selectedDomainCount == 0 && !model.canCreate && model.bulkState == .none)
        model.toggleAll(); precondition(model.selectedDomainCount == 0)
        model.toggleAll(in: .advanced)
        precondition(Set(model.selection.categories) == Set(advanced).subtracting(["ssh-configuration"]) && model.canCreate && model.bulkState == .none)
        model.prepare(destination: root.appendingPathComponent("advanced-only.mbt")); await model.waitForCompletion()
        precondition(model.state == .confirmation && Set(model.preparation!.selection!.categories) == Set(advanced).subtracting(["ssh-configuration"]))
        model.editSelection()
        let gitIndex = advancedOnly.firstIndex { $0["domain"] as? String == "git-repositories" }!
        advancedOnly[gitIndex] = row("git-repositories", mode: "items", items: ["one", "two", "three"])
        try JSONSerialization.data(withJSONObject: advancedOnly).write(to: inventoryPath)
        model.prepare(destination: root.appendingPathComponent("advanced-fresh.mbt")); await model.waitForCompletion()
        precondition(model.state == .confirmation && model.selectedItems["git-repositories"] == ["one", "two", "three"])
        precondition(Set(model.selection.categories) == Set(advanced).subtracting(["ssh-configuration"]), "Fresh whole-domain Prepare must preserve explicit Advanced intent")
        let sshIndex = advancedOnly.firstIndex { $0["domain"] as? String == "ssh-configuration" }!
        advancedOnly[sshIndex] = row("ssh-configuration", mode: "category", status: "unsupported", reason: "source_unsupported")
        let shellIndex = advancedOnly.firstIndex { $0["domain"] as? String == "shell-zsh" }!
        advancedOnly[shellIndex] = row("shell-zsh", mode: "category", status: "unavailable", reason: "source_unavailable")
        try JSONSerialization.data(withJSONObject: advancedOnly).write(to: inventoryPath)
        model.scan(); await model.waitForCompletion()
        precondition(model.selectedDomainCount == 0)
        let eligibleControls = CaptureReviewPresentation.bulkCategories(model.categories, group: .advanced)
        model.toggleCategories(eligibleControls)
        precondition(Set(model.selection.categories) == Set(advanced).subtracting(["ssh-configuration"]).subtracting(["ssh-configuration", "shell-zsh"]))
        precondition(model.bulkState(for: eligibleControls).bulkActionTitle == "Deselect All"
            && CaptureReviewPresentation.summary(model.categories(in: .advanced), model: model) == "All Selected")
        for id in ["ssh-configuration", "shell-zsh"] {
            model.selectCategory(id, included: true)
            precondition(model.selectionState(model.categories.first { $0.id == id }!) == .none)
        }
        model.toggleCategories(eligibleControls)
        precondition(model.selectedDomainCount == 0 && model.bulkState(for: eligibleControls).bulkActionTitle == "Select All")
        precondition(CaptureReviewPresentation.attention(model.categories(in: .ordinary), model: model) == "Scan Incomplete",
            "Real observation errors remain visible even when unselectable")
        let ordinarySummary = CaptureSummaryPresentation.review(categories: model.categories, domainCount: model.selectedDomainCount,
            itemCount: model.selectedItemCount, selectedDomains: Set(model.selection.categories).union(model.selection.items.keys))
        precondition(ordinarySummary.attentionCount == 1 && ordinarySummary.unsupportedCount == 2)
        print("PASS: Capture ordinary/Advanced defaults, independent bulk scopes, exact subsets/compact requests, independent VS Code, expansion, Review/failure preservation, Capture Again and Advanced-only capture")
    }

    @MainActor static func captureVisualChecks(model: CaptureModel, runtime: CoreRuntime, core: URL) async throws {
        let path = core.appendingPathComponent("inventory.json")
        let original = try Data(contentsOf: path)
        defer { try! original.write(to: path) }
        let items: [String: [String]] = [
            "app-store": ["Pages", "An application with a deliberately long name for document editing and collaboration across multiple projects"], "homebrew-casks": ["Firefox", "Rectangle"],
            "homebrew-packages": ["git", "python"], "vscode-extensions": ["ms-python.python", "publisher.a-very-long-extension-name-with-language-support-and-project-navigation"],
            "git-configuration": ["User name", "Default branch"], "git-repositories": ["project-alpha", "a-project-with-a-long-name-that-must-remain-readable"],
            "workspace-folders": ["Projects", "Documents/design"], "vscode-workspaces": ["team.code-workspace", "design.code-workspace"]]
        let settingLabels = Dictionary(uniqueKeysWithValues: CaptureMacOSSettingsGroup.domainIDs.map { domain in
            (domain, WorkspaceSettingLabels.names.filter { $0.key.hasPrefix(domain + ":") }.sorted { $0.key < $1.key }.map(\.value))
        })
        var inventory = WorkspacePresentationTaxonomy.Group.allCases.flatMap(\.domains).map { id -> Object in
            var value = row(id, mode: items[id] == nil ? "category" : "items", items: items[id] ?? [], reason: id == "git-configuration" ? "source_partial" : nil)
            if let labels = settingLabels[id] {
                value["included_settings"] = labels.enumerated().map { ["id": "preference-\($0.offset)", "label": $0.element] }
            }
            return value
        }
        let ssh = inventory.firstIndex { $0["domain"] as? String == "ssh-configuration" }!
        inventory[ssh] = row("ssh-configuration", mode: "category", status: "unsupported", reason: "source_unsupported")
        try JSONSerialization.data(withJSONObject: inventory).write(to: path)
        model.scan(); await model.waitForCompletion()
        precondition(model.state == .review && model.bulkState(in: .advanced) == .none)
        precondition(CaptureSettingsPresentation.labels(model.inventory) == settingLabels, "All six domains retain every inventory label in source order")
        let apps = model.categories.first { $0.id == "app-store" }!
        let settings = model.categories.first { $0.id == "vscode-settings" }!
        let folders = model.categories.first { $0.id == "workspace-folders" }!
        precondition(CaptureReviewPresentation.selectionLabel(apps, model: model) == "2 of 2 selected")
        precondition(CaptureReviewPresentation.selectionLabel(settings, model: model) == "Selected")
        precondition(CaptureReviewPresentation.selectionLabel(folders, model: model) == "Not Selected")
        model.selectItem(apps.id, item: apps.row.items[0].itemID, included: false)
        precondition(CaptureReviewPresentation.selectionLabel(apps, model: model) == "1 of 2 selected")
        model.selectCategory(apps.id, included: false)
        precondition(CaptureReviewPresentation.selectionLabel(apps, model: model) == "Not Selected")
        model.selectCategory(apps.id, included: true)
        let advanced = CaptureHierarchy.project(CaptureReviewRow.project(model.categories)).first { $0.group == .advanced }!
        precondition(advanced.rows.map(\.id) == ["git-configuration", "git-repositories", "workspace-folders", "ssh-configuration", "shell-zsh", "vscode-workspaces"])
        let defaults = model.selection
        let beforeExpansion = model.selection
        let top = CaptureHierarchy.initialExpansion
        precondition(top.isEmpty, "Every fresh disclosure starts collapsed, including VS Code and nested rows")
        let all = CaptureHierarchy.disclosureIDs(model.categories.map(\.id) + ["macos-settings"], scope: .ordinary)
            .union(CaptureHierarchy.disclosureIDs(model.categories.map(\.id), scope: .advanced))
        precondition(CaptureReviewRow.project(model.categories).contains(where: { $0.id == "workspace-folders" }))
        precondition(CaptureReviewPresentation.attention(model.categories(in: .advanced), model: model) == nil)
        precondition(CaptureSummaryPresentation.review(categories: model.categories, domainCount: model.selectedDomainCount,
            itemCount: model.selectedItemCount, selectedDomains: Set(model.selection.categories)).attentionCount == 0)
        for dark in [false, true] {
            try render(model, runtime, state: "2d-default", tree: top, dark: dark)
            try render(model, runtime, state: "2d-expanded", tree: all, dark: dark)
            try render(model, runtime, state: "2d-macos-labels", tree: Set(CaptureMacOSSettingsGroup.domainIDs + ["macos-settings"]), dark: dark)
            try render(model, runtime, state: "2d-macos-labels-bottom", scrollToBottom: true, tree: Set(CaptureMacOSSettingsGroup.domainIDs + ["macos-settings"]), dark: dark)
            try render(model, runtime, state: "2d-advanced-rows", scrollToBottom: true, tree: [CaptureHierarchy.sectionID(.advanced)], dark: dark)
            try render(model, runtime, state: "2d-application-extras",
                tree: [CaptureHierarchy.Group.vscode.section.id, CaptureHierarchy.Group.vscode.id], dark: dark)
            try render(model, runtime, state: "2d-long-extensions", scrollToBottom: true,
                tree: [CaptureHierarchy.Group.vscode.section.id, CaptureHierarchy.Group.vscode.id, "vscode-extensions"], dark: dark)
            try render(model, runtime, state: "2d-advanced-unselected", scrollToBottom: true, tree: all, dark: dark)
        }
        precondition(model.selection == beforeExpansion)
        try await accordionNativeChecks(model: model, runtime: runtime, core: core)
        model.selectItem("vscode-workspaces", item: "team.code-workspace", included: true)
        precondition(CaptureReviewRow.project(model.categories).contains(where: { $0.id == "workspace-folders" }) && model.selectedItems["workspace-folders"] == nil)
        model.selectItem("workspace-folders", item: "Projects", included: true)
        model.selectItem("git-repositories", item: "project-alpha", included: true)
        for dark in [false, true] { try render(model, runtime, state: "2d-folder-requirements", scrollToBottom: true, tree: all, dark: dark) }
        model.selectCategory("vscode-workspaces", included: false)
        precondition(CaptureReviewRow.project(model.categories).contains(where: { $0.id == "workspace-folders" }) && model.selectedItems["workspace-folders"] == ["Projects"])
        model.selectCategory("workspace-folders", included: false)
        precondition(CaptureReviewRow.project(model.categories).contains(where: { $0.id == "workspace-folders" }))
        let git = inventory.firstIndex { $0["domain"] as? String == "git-repositories" }!
        inventory[git] = row("git-repositories", mode: "items", status: "observation_error", reason: "observation_failed")
        try JSONSerialization.data(withJSONObject: inventory).write(to: path)
        model.scan(); await model.waitForCompletion()
        precondition(model.selection == defaults && CaptureReviewPresentation.attention(model.categories(in: .advanced), model: model) == "Scan Incomplete")
        try render(model, runtime, state: "2d-scan-incomplete", scrollToBottom: true, tree: top, dark: true)
        guard !CommandLine.arguments.contains("--no-renders") else {
            print("PASS: Capture group selection, explicit folders, neutral optional limitations and retained scan-integrity failures")
            return
        }
        // All real category headers render the same warning status; measuring its
        // orange pixels exercises the actual production rows, not a layout formula.
        inventory = WorkspacePresentationTaxonomy.Group.allCases.flatMap(\.domains).map {
            row($0, mode: items[$0] == nil ? "category" : "items", items: items[$0] ?? [], reason: "source_partial")
        }
        try JSONSerialization.data(withJSONObject: inventory).write(to: path)
        model.scan(); await model.waitForCompletion(); model.toggleAll(in: .advanced)
        for dark in [false, true] {
            NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            for width: CGFloat in [729, 1329] { // 1000/1600pt window minus the 215pt sidebar and content margins.
                var origins: [Int] = []
                for category in model.categories {
                    let inset = CaptureHierarchy.group(for: category.id) == .vscode ? 2 * CaptureChildRowGrid.leadingInset : CaptureChildRowGrid.leadingInset
                    let view = CaptureCategorySelectionView(model: model, category: category, expansion: .constant(false),
                        displayTitle: category.id == "git-repositories" ? "A deliberately long Git Repositories / Worktrees category label" : CaptureHierarchy.title(category.id, fallback: category.title), leadingInset: inset)
                    origins.append(captureStatusOrigin(view, width: width))
                }
                for child in model.macOSSettings.children {
                    origins.append(captureStatusOrigin(CaptureSettingsSubcategoryView(model: model, category: child, expansion: .constant(false))
                        .padding(.leading, 16 + CaptureChildRowGrid.leadingInset).padding(.trailing, 16), width: width))
                }
                try capturePolishGeometryChecks(model: model, width: width, dark: dark)
                precondition(origins.max()! - origins.min()! <= 2, "Capture status columns must align at every depth: \(origins)")
                print("PASS: Capture status origins \(origins.min()!)…\(origins.max()!) at \(Int(width))pt, \(dark ? "Dark" : "Light")")
            }
        }
        let selection = model.selection
        var open = false
        let host = NSHostingView(rootView: CaptureGroupHeader(title: "Applications & Tools", summary: "All Selected",
            expanded: Binding(get: { open }, set: { open = $0 })).frame(width: 729, height: 60))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 729, height: 60), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)); host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        let click = host.convert(NSPoint(x: 110, y: host.bounds.midY), to: nil)
        for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
            window.sendEvent(NSEvent.mouseEvent(with: type, location: click, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                eventNumber: 1, clickCount: 1, pressure: 1)!)
        }
        precondition(open && model.selection == selection, "Clicking the Applications title must disclose without changing selection")
        window.close()
        print("PASS: Capture unified accordion, title disclosure, direct Advanced folders, selected/scan warning distinction, exact trailing columns at minimum/wide widths, Light/Dark native fixtures")
    }

    @MainActor final class AccordionExpansion: ObservableObject {
        @Published var ids = Set<String>()
    }
    @MainActor static func captureDisclosureChecks(model: CaptureModel, runtime: CoreRuntime, core: URL) async throws {
        // Only injected inventory/prepare responses. Never Execute or read real identities.
        let rows = [row("homebrew-packages", mode: "items", items: (0..<24).map { "fixture-package-\($0)" }),
                    row("macos-finder", mode: "category"), row("vscode-extensions", mode: "items", items: ["fixture.extension"]),
                    row("vscode-settings", mode: "category"), row("git-configuration", mode: "items", items: (0..<12).map { "Fixture setting \($0)" }),
                    row("ssh-configuration", mode: "category")]
        try JSONSerialization.data(withJSONObject: rows).write(to: core.appendingPathComponent("inventory.json"))
        let identities: [Object] = (0..<2).map { index -> Object in
            let id = String(repeating: index == 0 ? "a" : "b", count: 64)
            let name = index == 0 ? "fixture_key" : "fixture_" + String(repeating: "W", count: 72)
            let fingerprint = "SHA256:" + Data(repeating: UInt8(index + 1), count: 32).base64EncodedString().replacingOccurrences(of: "=", with: "")
            return ["item_id": id, "label": name,
             "key_type": "ssh-ed25519", "validation": "candidate_requires_pair_validation",
             "fingerprint": fingerprint]
        }
        try JSONSerialization.data(withJSONObject: ["status": "present", "items": identities]).write(to: core.appendingPathComponent("secure-inventory.json"))
        model.scan(); await model.waitForCompletion()
        precondition(model.state == .review && model.selectedSecureIdentities.isEmpty)
        _ = NSApplication.shared
        var windows: [NSWindow] = []
        defer { windows.forEach { $0.close() } }
        let output = URL(fileURLWithPath: "build/Debug/Stage16HCaptureHeaders")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        struct LiveCapture: View {
            @ObservedObject var expansion: AccordionExpansion
            let model: CaptureModel
            let runtime: CoreRuntime
            var body: some View {
                VStack(spacing: 0) {
                    WorkflowContentViewport(pinned: true) {
                        CaptureView(model: model, runtime: runtime, showsActions: false, categoryTreeExpansion: $expansion.ids,
                            experiencedVisibility: .constant(true))
                            .padding(16)
                    }
                    Divider()
                    CaptureActionsView(model: model, runtime: runtime).modifier(WorkspaceFooterPadding())
                        .background(GeometryReader { Color.clear.preference(key: AccordionFrames.self, value: ["footer": $0.frame(in: .named("capture"))]) })
                }.coordinateSpace(name: "capture")
            }
        }
        func descendants<T: NSView>(_ view: NSView, _: T.Type) -> [T] {
            (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, T.self) }
        }
        func exercise(width: CGFloat, dark: Bool, phase: String, expectedOrdinary: Bool = true, expectedAdvanced: Bool = true, expectedSecure: Bool = true) async throws {
            let expansion = AccordionExpansion()
            var frames: [String: CGRect] = [:]
            let host = NSHostingView(rootView: LiveCapture(expansion: expansion, model: model, runtime: runtime)
                .onPreferenceChange(AccordionFrames.self) { frames = $0 }
                .frame(width: width, height: 740).background(Color(nsColor: .windowBackgroundColor)))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 740), styleMask: [.titled], backing: .buffered, defer: false)
            windows.append(window); window.isReleasedWhenClosed = false; window.contentView = host
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua); window.makeKeyAndOrderFront(nil)
            func settle() async {
                try? await Task.sleep(for: .milliseconds(60)); host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            }
            await settle()
            let scrolls = descendants(host, NSScrollView.self)
            precondition(scrolls.count == 1, "Capture must have one content viewport")
            let scroll = scrolls[0], document = scroll.documentView!
            // Measure the existing header component, then click its actual native
            // control in the document. No test replacement for disclosure actions.
            let headerProbe = NSHostingView(rootView: HStack(alignment: .firstTextBaseline, spacing: 12) {
                WorkspaceSectionHeader(title: "For Experienced Users")
                CaptureExpandButton(ids: ["fixture"], title: "Fixture", expanded: .constant([])).padding(.trailing, 42)
            }.frame(width: width - 32))
            let headerHeight = headerProbe.fittingSize.height
            var expertY = headerHeight / 2
            let ordinaryY = headerHeight / 2
            func scrollTo(_ y: CGFloat) async {
                let limit = max(0, document.frame.height - scroll.contentView.bounds.height)
                scroll.contentView.scroll(to: NSPoint(x: 0, y: min(max(0, y), limit)))
                scroll.reflectScrolledClipView(scroll.contentView); await settle()
            }
            func click(x: CGFloat, y: CGFloat) async {
                await scrollTo(y - scroll.contentView.bounds.height / 2)
                let point = document.convert(NSPoint(x: x, y: y), to: nil)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    window.sendEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!)
                }
                await settle()
            }
            func ordinaryAction() async {
                let height = document.frame.height
                await click(x: document.bounds.width - 75, y: ordinaryY)
                expertY += document.frame.height - height
            }
            func experiencedAction() async { await click(x: document.bounds.width - 75, y: expertY) }
            func snapshot(_ suffix: String) throws {
                let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("\(phase)-\(Int(width))-\(dark ? "dark" : "light")-\(suffix).png"))
            }
            try snapshot("collapsed")
            let selected = model.selection, domainCount = model.selectedDomainCount, itemCount = model.selectedItemCount
            let prepared = model.preparation?.preparedCaptureID, operation = model.operationID
            let requests = try Data(contentsOf: core.appendingPathComponent("requests.jsonl"))
            let sourceIDs: [String]
            if let preparation = model.preparation, let selection = preparation.publicationSelection {
                let tasks = CaptureTaskPresentation(categories: preparation.inventory.map { CaptureCategory(row: $0) }, selection: selection,
                    phase: .confirmation, secureIdentities: preparation.secureIdentities.items)
                sourceIDs = tasks.domains.map(\.id) + CaptureSettingsPresentation.children(tasks.domains).map(\.id)
                precondition(tasks.domains.contains { $0.id == CaptureHierarchy.secureTransferID } == expectedSecure)
                precondition(tasks.domains.contains { CaptureHierarchy.group(for: $0.id) == .advanced } == expectedAdvanced)
                precondition(tasks.domains.allSatisfy { $0.items.allSatisfy { $0.state == .planned } })
                if expectedSecure {
                    precondition(tasks.domains.first { $0.id == CaptureHierarchy.secureTransferID }!.items.contains { $0.item.title == "fixture_key" })
                }
            } else { sourceIDs = model.categories.map(\.id) + [CaptureHierarchy.secureTransferID] }
            let leaves = model.state == .review ? model.categories.filter { !CaptureCategorySelectionView.hasDisclosure($0) }.map(\.id) : []
            let ordinary = CaptureHierarchy.disclosureIDs(sourceIDs, scope: .ordinary).subtracting(leaves)
            let experienced = CaptureHierarchy.disclosureIDs(sourceIDs, scope: .advanced).subtracting(leaves)
            if expectedOrdinary {
                let count = Set(sourceIDs.filter { CaptureSelectionScope.ordinary.contains($0) || $0 == "macos-settings" }.map { CaptureHierarchy.group(for: $0) }).count
                expertY += headerHeight + 24 + CGFloat(count) * 48 + CGFloat(max(0, count - 1)) / window.backingScaleFactor
            }
            if expectedOrdinary {
                await ordinaryAction()
                precondition(expansion.ids == ordinary, "Ordinary native action must open only its tree: \(expansion.ids)")
                // A category chevron changes only its own ID; the mixed scope reopens all.
                let height = document.frame.height
                await click(x: 22, y: ordinaryY + headerHeight / 2 + 12 + 24)
                expertY += document.frame.height - height
                precondition(expansion.ids == ordinary.subtracting([CaptureHierarchy.sectionID(.applicationsTools)]))
                await ordinaryAction(); precondition(expansion.ids == ordinary)
                await ordinaryAction(); precondition(expansion.ids.isEmpty)
            }
            if !experienced.isEmpty {
                await experiencedAction()
                precondition(expansion.ids == experienced, "Experienced native action must include Secure Transfer: \(expansion.ids)")
                let advancedControl = descendants(host, NSButton.self).first { $0.accessibilityLabel() == "Select Advanced" }
                let groupY = advancedControl.map { $0.convert($0.bounds, to: document).midY }
                    ?? (expertY + headerHeight / 2 + 12 + 24)
                if expectedAdvanced {
                    await click(x: 22, y: groupY)
                    precondition(expansion.ids == experienced.subtracting([CaptureHierarchy.sectionID(.advanced)]))
                }
                if expectedSecure {
                    await click(x: 22, y: groupY + (expectedAdvanced ? 48 + 1 / window.backingScaleFactor : 0))
                    precondition(!expansion.ids.contains(CaptureHierarchy.sshID) && expansion.ids.contains(CaptureHierarchy.secureTransferID),
                                 "Collapsing SSH preserves its child disclosure state")
                    precondition(!expectedAdvanced || !expansion.ids.contains(CaptureHierarchy.sectionID(.advanced)))
                }
                await experiencedAction(); precondition(expansion.ids == experienced)
                if expectedOrdinary {
                    await ordinaryAction(); precondition(expansion.ids == ordinary.union(experienced))
                    await experiencedAction(); precondition(expansion.ids == ordinary)
                    await experiencedAction(); precondition(expansion.ids == ordinary.union(experienced))
                    await ordinaryAction(); precondition(expansion.ids == experienced)
                }
                await experiencedAction(); precondition(expansion.ids.isEmpty)
            }
            if expectedAdvanced && expectedSecure && model.state == .review {
                let boxes = descendants(host, NSButton.self)
                precondition(boxes.contains { $0.accessibilityLabel() == "Select Advanced" }
                             && !boxes.contains { $0.accessibilityLabel() == "Select SSH Keys" },
                             "Collapsed SSH has no master checkbox and hides its category controls")
            }
            if expectedOrdinary { await ordinaryAction() }
            if !experienced.isEmpty { await experiencedAction() }
            let footerBefore = frames["footer"]!
            await scrollTo(document.frame.height)
            if expectedOrdinary {
                precondition(abs(scroll.contentView.bounds.minY - max(0, document.frame.height - scroll.contentView.bounds.height)) < 1,
                             "Expanded content is reachable; compact selections need no scrolling")
                // Reaching and clicking the ordinary header after scrolling proves
                // it belongs to the document, not a pinned overlay outside the list.
                await ordinaryAction(); precondition(expansion.ids == experienced)
                await ordinaryAction(); precondition(expansion.ids == ordinary.union(experienced))
                await scrollTo(document.frame.height)
            }
            precondition(frames["footer"] == footerBefore, "Bottom action bar remains fixed")
            let viewport = scroll.convert(scroll.bounds, to: host)
            precondition(viewport.maxY <= footerBefore.minY + 1 && viewport.maxX <= host.bounds.maxX + 1)
            precondition(document.frame.width <= scroll.contentView.bounds.width + 1, "No horizontal clipping")
            if model.state == .confirmation {
                precondition(!descendants(host, NSButton.self).contains { $0.target is NativeSelectionCheckbox.Coordinator })
            }
            precondition(model.selection == selected && model.selectedDomainCount == domainCount && model.selectedItemCount == itemCount)
            precondition(model.preparation?.preparedCaptureID == prepared && model.operationID == operation && !runtime.isActive && runtime.secureChallenge == nil)
            let currentRequests = try Data(contentsOf: core.appendingPathComponent("requests.jsonl"))
            precondition(currentRequests == requests, "Disclosure must never call Core")
            try snapshot("expanded-bottom")
            window.orderOut(nil)
            print("PASS: \(phase) native controls, nested/mixed scopes, selection/preparation unchanged, scrolling and fixed footer at \(Int(width))pt \(dark ? "Dark" : "Light")")
        }
        for (width, dark): (CGFloat, Bool) in [(580, false), (1040, false), (580, true), (1040, true)] {
            try await exercise(width: width, dark: dark, phase: "review")
        }
        model.toggleAll(in: .advanced)
        model.selectAllSecureIdentities(included: true)
        model.prepare(destination: core.appendingPathComponent("disclosure.mbt")); await model.waitForCompletion()
        precondition(model.state == .confirmation)
        for (width, dark): (CGFloat, Bool) in [(580, false), (1040, false), (580, true), (1040, true)] {
            try await exercise(width: width, dark: dark, phase: "confirmation")
        }
        model.editSelection()
        for category in model.categories { model.selectCategory(category.id, included: false) }
        precondition(model.canCreate && model.selectedDomainCount == 0 && model.selectedItemCount == 0)
        model.prepare(destination: core.appendingPathComponent("secure-only-disclosure.mbt")); await model.waitForCompletion()
        precondition(model.state == .confirmation && model.preparation?.summary.selectedDomains == 0)
        try await exercise(width: 580, dark: false, phase: "secure-only", expectedOrdinary: false, expectedAdvanced: false)
        model.editSelection(); model.selectAllSecureIdentities(included: false); model.selectCategory("homebrew-packages", included: true)
        model.prepare(destination: core.appendingPathComponent("ordinary-only-disclosure.mbt")); await model.waitForCompletion()
        try await exercise(width: 580, dark: false, phase: "ordinary-only", expectedAdvanced: false, expectedSecure: false)
    }
    private struct AccordionFrames: PreferenceKey {
        static var defaultValue: [String: CGRect] = [:]
        static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue(), uniquingKeysWith: { _, new in new }) }
    }
    @MainActor static func accordionNativeChecks(model: CaptureModel, runtime: CoreRuntime, core: URL) async throws {
        guard !CommandLine.arguments.contains("--no-renders") else { return }
        let expansion = AccordionExpansion()
        let binding = Binding(get: { expansion.ids }, set: { expansion.ids = $0 })
        func boxes(_ view: NSView) -> [NSButton] {
            if let button = view as? NSButton, button.target is NativeSelectionCheckbox.Coordinator { return [button] }
            return view.subviews.flatMap(boxes)
        }
        func scrolls(_ view: NSView) -> [NSScrollView] { (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrolls) }
        func flush(_ host: NSView) {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        }
        struct LiveCapture: View {
            @ObservedObject var expansion: AccordionExpansion
            let model: CaptureModel
            let runtime: CoreRuntime
            var body: some View {
                CaptureView(model: model, runtime: runtime, showsActions: false, categoryTreeExpansion: $expansion.ids)
            }
        }
        for size in [CGSize(width: 1000, height: 700), CGSize(width: 1600, height: 1050)] {
            for dark in [false, true] {
                NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                expansion.ids = []
                var frames: [String: CGRect] = [:]
                let content = HStack(spacing: 0) {
                    Color(nsColor: .controlBackgroundColor).frame(width: 215) // Reserved native sidebar width.
                    VStack(spacing: 0) {
                        WorkflowContentViewport(pinned: true) {
                            VStack(alignment: .leading, spacing: 20) {
                                WorkspaceHeader(title: ProductTask.capture.title, subtitle: ProductTask.capture.subtitle, symbol: ProductTask.capture.symbol)
                                    .background(GeometryReader { Color.clear.preference(key: AccordionFrames.self, value: ["header": $0.frame(in: .named("capture"))]) })
                                LiveCapture(expansion: expansion, model: model, runtime: runtime)
                            }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Divider()
                        CaptureActionsView(model: model, runtime: runtime).modifier(WorkspaceFooterPadding())
                            .background(GeometryReader { Color.clear.preference(key: AccordionFrames.self, value: ["footer": $0.frame(in: .named("capture"))]) })
                    }
                }.frame(width: size.width, height: size.height).background(Color(nsColor: .windowBackgroundColor)).coordinateSpace(name: "capture")
                    .onPreferenceChange(AccordionFrames.self) { frames = $0 }
                let host = NSHostingView(rootView: content)
                let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil); flush(host)
                precondition(boxes(host).isEmpty, "All fresh top-level sections are collapsed with no parent checkbox")
                let selected = model.selection, requests = try Data(contentsOf: core.appendingPathComponent("requests.jsonl"))
                expansion.ids.insert(CaptureHierarchy.sectionID(.macOSSettings)); flush(host)
                precondition(boxes(host).count == 6, "macOS has exactly six independent native category checkboxes")
                let finder = boxes(host).first { $0.accessibilityLabel() == "Select Finder" }!
                finder.performClick(nil); flush(host)
                precondition(model.macOSSettings.state == .mixed && model.macOSSettings.children.filter { model.selectionState($0) == .all }.count == 5)
                boxes(host).first { $0.accessibilityLabel() == "Select Finder" }!.performClick(nil); flush(host)
                precondition(model.selection == selected)
                expansion.ids.formUnion(CaptureMacOSSettingsGroup.domainIDs); flush(host)
                precondition(boxes(host).count == 6, "Expanded compact preference labels add no per-setting checkbox")
                expansion.ids.insert(CaptureHierarchy.sectionID(.advanced)); flush(host)
                precondition(boxes(host).contains { $0.accessibilityLabel() == "Select Workspace Folders" }, "Folders are directly accessible after opening Advanced alone")
                precondition(!boxes(host).contains { ($0.accessibilityLabel() ?? "").contains("Secure Transfer") }, "Secure Transfer has no enabled checkbox")
                expansion.ids.remove(CaptureHierarchy.sectionID(.advanced)); flush(host)
                expansion.ids.insert(CaptureHierarchy.sectionID(.applicationsTools)); flush(host)
                precondition(boxes(host).count == 9, "Opening Applications preserves the independent macOS disclosure")
                expansion.ids.insert(CaptureHierarchy.sectionID(.vscode)); flush(host)
                precondition(boxes(host).count == 9, "VS Code remains independently collapsed")
                expansion.ids.insert(CaptureHierarchy.Group.vscode.id); flush(host)
                precondition(boxes(host).count == 11, "VS Code adds only its two real Core selectors")
                expansion.ids = CaptureHierarchy.disclosureIDs(model.categories.map(\.id), scope: .ordinary)
                    .union(CaptureHierarchy.disclosureIDs(model.categories.map(\.id), scope: .advanced)); flush(host)
                precondition(boxes(host).contains { $0.accessibilityLabel() == "Select Workspace Folders" }, "Folder-only Capture has a reachable selector with no descriptor selection")
                precondition(model.selection == selected && (try! Data(contentsOf: core.appendingPathComponent("requests.jsonl"))) == requests)
                let scroll = scrolls(host)
                precondition(scroll.count == 1 && scroll[0].contentView.bounds.height > 100)
                precondition(scroll[0].documentView!.frame.width <= scroll[0].contentView.bounds.width + 1 && !scroll[0].hasHorizontalScroller)
                let fixed = frames
                let bottom = max(0, scroll[0].documentView!.frame.height - scroll[0].contentView.bounds.height)
                scroll[0].contentView.scroll(to: CGPoint(x: 0, y: bottom)); scroll[0].reflectScrolledClipView(scroll[0].contentView); flush(host)
                precondition(frames == fixed && fixed.count == 2 && fixed["footer"]!.maxY <= size.height + 1)
                precondition(abs(scroll[0].contentView.bounds.minY - bottom) < 2)
                // A fresh Scan resets the actual mounted view's disclosure binding.
                model.scan(); await model.waitForCompletion(); flush(host)
                precondition(expansion.ids.isEmpty && boxes(host).isEmpty && model.selection == selected)
                // Real read-only Capture rendering never exposes draft checkboxes.
                expansion.ids = CaptureHierarchy.disclosureIDs(model.categories.map(\.id), scope: .ordinary)
                model.toggleAll(in: .advanced)
                let preparedSelection = model.selection
                expansion.ids = CaptureHierarchy.disclosureIDs(model.categories.map(\.id), scope: .ordinary)
                    .union(CaptureHierarchy.disclosureIDs(model.categories.map(\.id), scope: .advanced))
                model.prepare(destination: core.appendingPathComponent("accordion.mbt")); await model.waitForCompletion(); flush(host)
                precondition(model.state == .confirmation && boxes(host).isEmpty && model.preparation?.selection == preparedSelection)
                let confirmationScroll = scrolls(host)
                precondition(confirmationScroll.count == 1 && !confirmationScroll[0].hasHorizontalScroller)
                precondition(confirmationScroll[0].documentView!.frame.width <= confirmationScroll[0].contentView.bounds.width + 1)
                let confirmedFrames = frames
                let last = max(0, confirmationScroll[0].documentView!.frame.height - confirmationScroll[0].contentView.bounds.height)
                confirmationScroll[0].contentView.scroll(to: CGPoint(x: 0, y: last)); confirmationScroll[0].reflectScrolledClipView(confirmationScroll[0].contentView); flush(host)
                precondition(abs(confirmationScroll[0].contentView.bounds.minY - last) < 2 && frames == confirmedFrames)
                confirmationScroll[0].contentView.scroll(to: .zero); confirmationScroll[0].reflectScrolledClipView(confirmationScroll[0].contentView); flush(host)
                let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/Debug/CaptureClosure-confirmation-\(Int(size.width))-\(dark ? "dark" : "light").png"))
                let preparedScope = model.preparation!
                let tasks = CaptureTaskPresentation(categories: preparedScope.inventory.map { CaptureCategory(row: $0) },
                    selection: preparedScope.publicationSelection!, phase: .confirmation)
                let sheet = TaskDomainList(domains: tasks.domains, stateTitles: [.planned: "Ready to Save"], compactReadyItems: true,
                    title: "Included in this capture", captureHierarchy: true, settingsCategories: CaptureSettingsPresentation.children(tasks.domains),
                    settingLabels: CaptureSettingsPresentation.labels(preparedScope.inventory), expansion: .constant(expansion.ids))
                    .padding(28).frame(width: size.width - 215).background(Color(nsColor: .windowBackgroundColor))
                let sheetBitmap = NSBitmapImageRep(cgImage: ImageRenderer(content: sheet).cgImage!)
                try sheetBitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath:
                    "build/Debug/CaptureClosure-confirmation-sheet-\(Int(size.width))-\(dark ? "dark" : "light").png"))
                let prepared = model.preparation!.preparedCaptureID
                binding.wrappedValue = CaptureHierarchy.toggled(expansion.ids, ids: expansion.ids); flush(host)
                precondition(model.preparation?.preparedCaptureID == prepared && model.selection == preparedSelection)
                model.editSelection(); flush(host)
                precondition(model.state == .review && model.selection == preparedSelection)
                model.scan(); await model.waitForCompletion(); flush(host)
                precondition(model.selection == selected)
                window.close()
                print("PASS: live Capture accordion \(Int(size.width))x\(Int(size.height)) \(dark ? "Dark" : "Light"): six native macOS selectors, independent disclosures, one scroll viewport, fixed footer, fresh Scan reset, read-only preparation")
            }
        }
    }

    @MainActor static func capturePolishGeometryChecks(model: CaptureModel, width: CGFloat, dark: Bool) throws {
        func bitmap<V: View>(_ view: V) -> NSBitmapImageRep {
            let image = ImageRenderer(content: view.frame(width: width).background(Color(nsColor: .windowBackgroundColor))).cgImage!
            return NSBitmapImageRep(cgImage: image)
        }
        func bounds(_ image: NSBitmapImageRep, from: Int, to: Int, blue: Bool) -> CGRect? {
            let background = image.colorAt(x: 0, y: 0)!.usingColorSpace(.sRGB)!
            var xs: [Int] = [], ys: [Int] = []
            for x in from..<to {
                for y in 0..<image.pixelsHigh {
                    guard let c = image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.9 else { continue }
                    let matches = blue ? c.blueComponent > 0.4 && c.blueComponent > c.redComponent * 1.4 && c.blueComponent > c.greenComponent * 1.1
                        : abs(c.redComponent - background.redComponent) > 0.15
                    if matches { xs.append(x); ys.append(y) }
                }
            }
            guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return nil }
            return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        }
        let sibling = bitmap(CaptureCategorySelectionView(model: model,
            category: CaptureCategory(row: .init(domain: "ssh-configuration", status: "unavailable", reason: nil,
                selectionMode: "category", items: [], includedSettings: nil)), expansion: .constant(false),
            displayTitle: "Configuration", leadingInset: CaptureChildRowGrid.leadingInset))
        let secure = bitmap(CaptureSecureTransferView(expansion: .constant(false)))
        let siblingIcon = bounds(sibling, from: 0, to: Int(width / 2), blue: true)!
        let secureIcon = bounds(secure, from: 0, to: Int(width / 2), blue: true)!
        precondition(abs(siblingIcon.midX - secureIcon.midX) <= 2 && abs(siblingIcon.midY - secureIcon.midY) <= 2,
            "Secure Transfer's icon must share the nested child column and baseline: \(siblingIcon), \(secureIcon)")
        precondition(sibling.pixelsHigh == 48 && secure.pixelsHigh == sibling.pixelsHigh)
        let textStart = Int(width - 16 - 26 - TaskRowLayout.statusWidth + CaptureStatusText.textInset) - 2
        let textEnd = Int(width - 16 - 26)
        let siblingStatus = bounds(sibling, from: textStart, to: textEnd, blue: false)!
        let secureStatus = bounds(secure, from: textStart, to: textEnd, blue: false)!
        precondition(abs(siblingStatus.minX - secureStatus.minX) <= 1 && abs(siblingStatus.minY - secureStatus.minY) <= 1
            && abs(siblingStatus.width - secureStatus.width) <= 1 && abs(siblingStatus.height - secureStatus.height) <= 1,
            "Secure Transfer's Unavailable label must share the exact child status rail: \(siblingStatus), \(secureStatus)")
        for group in CaptureHierarchy.ordinaryGroups + [.advanced] {
            let header = bitmap(CaptureGroupHeader(title: CaptureHierarchy.sectionTitle(group), summary: "Not Selected",
                symbol: CaptureHierarchy.symbol(group), tint: group == .advanced ? .secondary : .blue, expanded: .constant(false)))
            precondition((bounds(header, from: 0, to: Int(width / 2), blue: true) != nil) == (group != .advanced),
                "Ordinary section icons are blue; only the Advanced expert icon is neutral")
        }
        let vscode = bitmap(CaptureGroupHeader(title: "VS Code", summary: "All Selected", symbol: "curlybraces", nested: true, expanded: .constant(false)))
        precondition(bounds(vscode, from: 0, to: Int(width / 2), blue: true) != nil)
        print("PASS: ordinary/VS Code blue icons, neutral Advanced, Secure Transfer 48pt row and exact sibling icon/status rails at \(Int(width))pt \(dark ? "Dark" : "Light")")
    }

    @MainActor static func captureStatusOrigin<V: View>(_ view: V, width: CGFloat) -> Int {
        let renderer = ImageRenderer(content: view.frame(width: width).background(Color(nsColor: .windowBackgroundColor)))
        guard let cg = renderer.cgImage else { preconditionFailure("Capture status row render unavailable") }
        let bitmap = NSBitmapImageRep(cgImage: cg)
        // Native selection controls may use the user's accent color too; inspect
        // only the trailing half, where the production status column lives.
        for x in (bitmap.pixelsWide / 2)..<bitmap.pixelsWide {
            for y in 0..<bitmap.pixelsHigh {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.alphaComponent > 0.9 else { continue }
                if color.redComponent > 0.5 && color.greenComponent > 0.15 && color.redComponent > color.greenComponent * 1.1 && color.blueComponent < 0.3 { return x }
            }
        }
        preconditionFailure("Expected selected requirement warning in Capture status column")
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
        func scanWithExplicitAdvancedSelection() async {
            model.scan(); await model.waitForCompletion()
            precondition(model.state == .review)
            let ordinaryAvailable = model.categories(in: .ordinary).contains(where: \.selectable)
            precondition(model.bulkState == (ordinaryAvailable ? .all : .none))
            precondition(model.bulkState(in: .advanced) == .none)
            // This dependency/role fixture deliberately includes the eligible
            // Advanced baseline before narrowing folders and repositories.
            model.toggleAll(in: .advanced)
            precondition(model.bulkState(in: .advanced) == .all)
        }
        await scanWithExplicitAdvancedSelection()
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
            await scanWithExplicitAdvancedSelection()
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

    @MainActor static func secureCaptureChecks(root: URL, repository: URL, python: URL) async throws {
        // build.sh places this harness beside the app whose authenticated helper
        // it qualifies. Never search external tools or prepare/download age here.
        let builtApplication = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
            .deletingLastPathComponent().appendingPathComponent("Macseed.app")
        let base = root.appendingPathComponent("secure-capture"), core = base.appendingPathComponent("core")
        let home = base.appendingPathComponent("home"), bin = base.appendingPathComponent("bin")
        let application = base.appendingPathComponent("Fixture.app")
        let embeddedAge = application.appendingPathComponent("Contents/Helpers/age")
        for directory in [core.appendingPathComponent("config"), core.appendingPathComponent("scripts"), home.appendingPathComponent(".ssh"), bin,
                          embeddedAge.deletingLastPathComponent()] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        for name in ["modules", "bootstrap.sh", "config/toolkit.conf", "scripts/ssh-identity-migrate.sh"] {
            try FileManager.default.copyItem(at: repository.appendingPathComponent(name), to: core.appendingPathComponent(name))
        }
        // As in the existing Capture API harness, unrelated collectors are inert in
        // this disposable checkout. Capture, secure export, Bundle and Preview stay production.
        let bootstrap = core.appendingPathComponent("bootstrap.sh")
        let source = try String(contentsOf: bootstrap, encoding: .utf8)
        let marker = "source modules/discovery/workspace.sh\n"
        precondition(source.components(separatedBy: marker).count == 2)
        let disabled = ["discover_git", "discover_ssh_configuration", "discover_zsh", "export_vscode_settings", "discover_workspace",
                        "export_finder_settings", "export_dock_settings", "export_windows_settings", "export_keyboard_settings", "export_trackpad_settings", "export_screenshots_settings"]
        try write(source.replacingOccurrences(of: marker, with: marker + disabled.map { "\($0)() { return 1; }\n" }.joined()), bootstrap)
        let brewSource = core.appendingPathComponent("modules/discovery/homebrew.sh")
        try write(try String(contentsOf: brewSource, encoding: .utf8).replacingOccurrences(of: "export_brew_packages()", with: "fixture_export_brew_packages()")
            + "\nexport_brew_packages() { fixture_export_brew_packages || return $?; return 1; }\n", brewSource)
        try write("""
        #!/bin/bash
        case "$*" in
          'list --formula'|'list --formula --full-name'|'list --formula --installed-on-request') echo fixture-formula;;
          --version) echo 'Homebrew 7.0.7';;
          help\\ *) echo "$2 --formula --cask --full-name --json --appdir";;
          'info --json=v2 --installed --cask') echo '{"casks":[]}';;
          'list --cask') exit 0;;
          --prefix) echo /opt/homebrew;;
          *) exit 99;;
        esac
        """, bin.appendingPathComponent("brew"), executable: true)
        for tool in ["code", "mas", "sudo", "defaults", "killall", "curl"] {
            try write("#!/bin/sh\nexit 99\n", bin.appendingPathComponent(tool), executable: true)
        }
        try write("#!/bin/sh\necho 26.7.1\n", bin.appendingPathComponent("sw_vers"), executable: true)
        let location = CoreLocation(root: core, python: python, home: home, temporaryBase: root, toolDirectories: [bin], applicationBundle: application)
        let keySecret = Data(("disposable-key-" + UUID().uuidString).utf8)
        let bundleSecret = Data(("disposable-bundle-" + UUID().uuidString).utf8)
        func tool(_ executable: URL, arguments: [String], input: Data = Data(), applicationBundle: URL? = nil) throws {
            let process = Process(), stdin = Pipe(), stderr = Pipe()
            process.executableURL = executable; process.arguments = arguments
            process.environment = location.environment(temporary: root)
            if let applicationBundle { process.environment?["MACSEED_DESKTOP_BUNDLE"] = applicationBundle.path }
            process.standardInput = stdin; process.standardOutput = FileHandle.nullDevice; process.standardError = stderr
            try process.run(); try stdin.fileHandleForWriting.write(contentsOf: input); try stdin.fileHandleForWriting.close()
            _ = stderr.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            precondition(process.terminationStatus == 0, "Disposable Secure Capture helper failed: \(process.terminationStatus)")
        }
        // Authenticate the original app path before copying; production validates
        // the disposable copy again on every secure operation, including decrypt.
        try tool(python, arguments: ["-B", core.appendingPathComponent("modules/migration/age_runtime.py").path, "--check"],
                 applicationBundle: builtApplication)
        try FileManager.default.copyItem(at: builtApplication.appendingPathComponent("Contents/Helpers/age"), to: embeddedAge)
        try tool(python, arguments: ["-B", "-c", "import shutil; assert shutil.which('age') is None, 'Secure Capture fixture must have no external age on PATH'"])
        let setup = base.appendingPathComponent("keys.py")
        try write("""
        import sys,subprocess
        from pathlib import Path
        sys.path.insert(0,sys.argv[1])
        from secret_input import tool
        ssh=Path(sys.argv[2]);secret=sys.stdin.buffer.read()
        subprocess.run(['/usr/bin/ssh-keygen','-q','-t','ed25519','-N','','-f',str(ssh/'fixture_plain')],check=True)
        status,_,_=tool(['/usr/bin/ssh-keygen','-q','-t','ed25519','-f',str(ssh/'fixture_protected')],secret,secret_repeats=2)
        assert status==0
        """, setup)
        try tool(python, arguments: ["-B", setup.path, core.appendingPathComponent("modules/migration").path, home.appendingPathComponent(".ssh").path], input: keySecret)
        let initialHome = try snapshot(home)
        let logs = OperationLogStore(directory: base.appendingPathComponent("operations"))
        let runtime = CoreRuntime(operationLogs: logs)
        let model = CaptureModel(runtime: runtime, location: location)
        func scan(_ labels: Set<String>, ordinary: Bool = false) async {
            model.scan(); await model.waitForCompletion()
            precondition(model.state == .review && model.secureInventory.items.count == 2 && model.selectedSecureIdentities.isEmpty)
            model.toggleAll(in: .advanced)
            precondition(model.selectedSecureIdentities.isEmpty, "Advanced bulk selection must not opt in identities")
            for category in model.categories where category.selectable { model.selectCategory(category.id, included: ordinary && category.id == "homebrew-packages") }
            model.selectSecureIdentity("unknown", included: true)
            precondition(model.selectedSecureIdentities.isEmpty)
            for identity in model.secureInventory.items where labels.contains(identity.label) { model.selectSecureIdentity(identity.id, included: true) }
            precondition(model.selectedSecureIdentities.count == labels.count)
        }
        func prepare(_ name: String) async -> URL {
            let target = base.appendingPathComponent(name + ".mbt")
            model.prepare(destination: target); await model.waitForCompletion()
            precondition(model.state == .confirmation, "Secure prepare failed: \(String(describing: model.failure))")
            precondition(runtime.secureChallenge == nil && model.preparation?.summary.secureIdentityCount == model.selectedSecureIdentities.count)
            return target
        }
        func execute(_ mode: String = "success") async -> [CoreSecureChallenge] {
            model.create()
            var challenges: [CoreSecureChallenge] = [], seen = Set<String>()
            let deadline = Date().addingTimeInterval(50)
            while model.busy && Date() < deadline {
                if let challenge = runtime.secureChallenge, seen.insert(challenge.id).inserted {
                    challenges.append(challenge)
                    if let previous = challenges.dropLast().last {
                        precondition(!runtime.respond(to: previous, with: .secret(bundleSecret)), "Stale UI response accepted")
                    }
                    let response: CoreSecureResponse
                    if mode == "cancel" { response = .cancel }
                    else if challenge.kind == .sshKeyUnlock {
                        response = .secret(mode == "wrong-limit" || (mode == "retry" && challenge.attempt == 1) ? Data("wrong-disposable-input".utf8) : keySecret)
                    } else { precondition(challenge.kind == .bundleEncrypt); response = .secret(bundleSecret) }
                    precondition(runtime.respond(to: challenge, with: response))
                    precondition(runtime.secureChallenge == nil)
                }
                try? await Task.sleep(for: .milliseconds(10))
            }
            if model.busy { model.cancel(); await model.waitForCompletion(); preconditionFailure("Secure Capture exceeded fixture deadline") }
            await model.waitForCompletion()
            precondition(runtime.secureChallenge == nil)
            if let last = challenges.last { precondition(!runtime.respond(to: last, with: .secret(bundleSecret))) }
            return challenges
        }
        await scan(["fixture_protected"], ordinary: true)
        let publishedTarget = await prepare("protected")
        let prepared = model.preparation!
        let prepareData = try JSONEncoder().encode(runtime.latestResult!.fields["data"]!)
        try secureCaptureContractChecks(prepareData, expected: prepared.selection!)
        let challenges = await execute("retry")
        precondition(challenges.map(\.kind) == [.sshKeyUnlock, .sshKeyUnlock, .bundleEncrypt] && challenges.map(\.attempt) == [1, 2, 1])
        precondition(model.state == .result && model.publication?.bundle.secureComponent == true && model.publicationEvidence == .occurred)
        precondition(model.resultPresentation?.scope.contains("1 SSH identity encrypted") == true)
        precondition(model.resultPresentation?.attention.map(\.id) == ["homebrew-packages"], "Partial ordinary coverage must remain visible")
        let publicationData = try JSONEncoder().encode(runtime.latestResult!.fields["data"]!)
        var wrongPublication = try JSONSerialization.jsonObject(with: publicationData) as! Object
        var wrongBundle = wrongPublication["bundle"] as! Object; wrongBundle["secure_component"] = false; wrongPublication["bundle"] = wrongBundle
        let invalidPublication = try JSONDecoder().decode(CoreCapturePublication.self, from: JSONSerialization.data(withJSONObject: wrongPublication))
        do { try invalidPublication.validate(preparation: prepared, destination: publishedTarget); preconditionFailure("Missing secure publication accepted") } catch {}
        let verify = base.appendingPathComponent("verify-export.py")
        try write("""
        import os,sys,tarfile,tempfile
        from pathlib import Path
        sys.path.insert(0,sys.argv[1]);import bundle
        sys.path.insert(0,sys.argv[2]);from secret_input import decrypt
        source=Path(sys.argv[3]);home=Path(sys.argv[4]);secret=sys.stdin.buffer.read()
        class Input:
            def ask(self,kind,attempt):
                assert kind=='bundle_unlock';return secret
        with tempfile.TemporaryDirectory(dir=source.parent) as temporary:
            stage=Path(temporary)/'stage';stage.mkdir(mode=0o700)
            bundle.unpack(source,stage,str(home))
            with (stage/'secure.age').open('rb') as encrypted,tempfile.TemporaryFile(dir=temporary) as plain:
                decrypt(encrypted.fileno(),plain,Input());plain.seek(0)
                with tarfile.open(fileobj=plain) as archive:
                    assert set(archive.getnames())=={'manifest','keys/fixture_protected','keys/fixture_protected.pub'}
                    for suffix in ('','.pub'):
                        assert archive.extractfile('keys/fixture_protected'+suffix).read()==(home/'.ssh'/('fixture_protected'+suffix)).read_bytes()
        """, verify)
        try tool(python, arguments: ["-B", verify.path, core.appendingPathComponent("modules/bundle").path,
                                     core.appendingPathComponent("modules/migration").path, publishedTarget.path, home.path], input: bundleSecret)
        let homeAfterExport = try snapshot(home)
        precondition(homeAfterExport == initialHome)
        print("PASS: Native Secure Capture → real protected-key retry → age export → validated publication; decrypted fixture contains only the explicitly selected pair; partial ordinary coverage retained")

        await scan(["fixture_plain"])
        _ = await prepare("secure-only")
        precondition(model.canCreate == false && model.preparation?.summary.selectedDomains == 0)
        let plainChallenges = await execute()
        precondition(plainChallenges.map(\.kind) == [.bundleEncrypt] && model.state == .result)
        await scan([] , ordinary: true)
        _ = await prepare("ordinary")
        let ordinaryChallenges = await execute()
        precondition(ordinaryChallenges.isEmpty && model.state == .result && model.publication?.bundle.secureComponent == false)
        for mode in ["cancel", "wrong-limit"] {
            await scan(["fixture_protected"])
            let target = await prepare(mode)
            let values = await execute(mode)
            precondition(!FileManager.default.fileExists(atPath: target.path) && model.publicationEvidence == .notOccurred)
            if mode == "cancel" { precondition(model.state == .cancelled && values.count == 1) }
            else { precondition(model.state == .failed && values.map(\.attempt) == [1, 2, 3] && model.failure?.technicalReason == "secure_key_unlock_rejected") }
        }
        await scan(["fixture_plain"])
        let stale = await prepare("stale")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: home.appendingPathComponent(".ssh/fixture_plain").path)
        let staleChallenges = await execute()
        precondition(staleChallenges.isEmpty && model.failure?.technicalReason == "stale_prepared_capture" && !FileManager.default.fileExists(atPath: stale.path))
        await scan(["fixture_plain"])
        let occupied = await prepare("occupied")
        try write("retained fixture", occupied)
        let occupiedChallenges = await execute()
        precondition(occupiedChallenges.isEmpty && model.failure?.technicalReason == "invalid_destination")
        let occupiedBytes = try String(contentsOf: occupied, encoding: .utf8); precondition(occupiedBytes == "retained fixture")
        await scan(["fixture_plain"])
        model.prepare(destination: occupied, replacementConfirmed: true); await model.waitForCompletion()
        precondition(model.state == .confirmation)
        try write("changed fixture", occupied)
        model.create(); precondition(model.failure == .invalidDestination)
        for failure in ["missing", "corrupt", "symlink"] {
            await scan(["fixture_plain"])
            let target = await prepare("age-" + failure)
            try FileManager.default.removeItem(at: embeddedAge)
            if failure == "corrupt" {
                try write("corrupt bundled age", embeddedAge)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: embeddedAge.path)
            } else if failure == "symlink" {
                try FileManager.default.createSymbolicLink(at: embeddedAge, withDestinationURL: builtApplication.appendingPathComponent("Contents/Helpers/age"))
            }
            let noAgeChallenges = await execute()
            precondition(noAgeChallenges.isEmpty && model.failure?.technicalReason == "age_unavailable")
            precondition(model.publicationEvidence == .notOccurred && !FileManager.default.fileExists(atPath: target.path))
            if failure != "missing" { try FileManager.default.removeItem(at: embeddedAge) }
            try FileManager.default.copyItem(at: builtApplication.appendingPathComponent("Contents/Helpers/age"), to: embeddedAge)
        }
        let homeAfterChecks = try snapshot(home)
        precondition(homeAfterChecks == initialHome, "Capture must preserve disposable source key bytes")
        let history = try await logs.history()
        precondition(!history.isEmpty && history.allSatisfy { $0.finish != nil })
        let privateValues = [keySecret, bundleSecret] + prepared.secureIdentities.items.flatMap { [Data($0.label.utf8), Data($0.fingerprint.utf8)] }
        for bytes in try snapshot(logs.directory).values { precondition(privateValues.allSatisfy { bytes.range(of: $0) == nil }) }
        for entry in history {
            let report = try await DiagnosticReportBuilder.generate(id: entry.id, environment: .current()) { id, cursor in try await logs.page(id, after: cursor) }
            precondition(privateValues.allSatisfy { report.utf8.range(of: $0) == nil })
        }
        print("PASS: Secure-only and ordinary Capture without external age; default-off/bulk isolation, cancellation, three wrong attempts, stale source, destination/no-clobber and missing/corrupt/linked bundled age; no secrets/names/fingerprints in persisted logs or reports")
        try await secureCaptureInvalidationCheck(root: base, repository: repository, python: python)
    }

    static func secureCaptureContractChecks(_ data: Data, expected: CoreCaptureSelection) throws {
        let original = try JSONSerialization.jsonObject(with: data) as! Object
        for scenario in ["count", "duplicate", "label", "type", "fingerprint", "validation", "empty"] {
            var value = original, secure = original["secure_identities"] as! Object
            var items = secure["items"] as! [Object]
            switch scenario {
            case "count": var summary = value["summary"] as! Object; summary["secure_identity_count"] = 0; value["summary"] = summary
            case "duplicate": items.append(items[0])
            case "label": items[0]["label"] = "unsafe\n"
            case "type": items[0]["key_type"] = "unsupported"
            case "fingerprint": items[0]["fingerprint"] = "not-a-public-fingerprint"
            case "validation": items[0]["validation"] = "verified"
            default: items = []
            }
            secure["items"] = items; value["secure_identities"] = secure
            do {
                let decoded = try JSONDecoder().decode(CoreCapturePreparation.self, from: JSONSerialization.data(withJSONObject: value))
                try decoded.validate(expected: expected); preconditionFailure("Invalid secure inventory accepted: \(scenario)")
            } catch {}
        }
    }

    @MainActor static func secureCaptureInvalidationCheck(root: URL, repository: URL, python: URL) async throws {
        let core = root.appendingPathComponent("timeout-core"), adapter = core.appendingPathComponent("modules/core/application-interface")
        try FileManager.default.createDirectory(at: adapter, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: core.appendingPathComponent("config"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: repository.appendingPathComponent("modules/core/application-interface/core.sh"), to: adapter.appendingPathComponent("core.sh"))
        for name in ["secret_input.py", "age_runtime.py"] {
            try FileManager.default.copyItem(at: repository.appendingPathComponent("modules/migration/" + name), to: adapter.appendingPathComponent(name))
        }
        try write("TOOLKIT_VERSION=fixture\n", core.appendingPathComponent("config/toolkit.conf"))
        try write("", core.appendingPathComponent("bootstrap.sh"))
        try write("""
        import json,sys,time,uuid
        from secret_input import inherited_socket,metadata
        request=json.load(sys.stdin);channel=inherited_socket(int(sys.argv[3]))
        def emit(sequence,kind,data=None):
            print(json.dumps(dict(protocol_version=1,operation_id=request['operation_id'],sequence=sequence,type=kind,**({'data':data} if data else {}))),flush=True)
        restore=request['operation']=='restore_execute'
        emit(1,'started');emit(2,'phase_started',{'phase':'secure_import' if restore else 'secure_packaging'})
        metadata(channel,dict(type='challenge',protocol_version=1,operation_id=request['operation_id'],challenge_id=uuid.uuid4().hex,kind='bundle_unlock' if restore else 'bundle_encrypt',attempt=1))
        time.sleep(.2)
        emit(3,'failed',dict(code='secure_channel_timeout',publication_occurred=False));channel.close();sys.exit(2)
        """, adapter.appendingPathComponent("core.py"))
        let runtime = CoreRuntime(operationLogs: nil)
        let capture = CoreRequest(.captureExecute(selection: .init(categories: [], items: [:], secureIdentities: [String(repeating: "a", count: 64)]),
            destination: root.appendingPathComponent("unused.mbt").path, preparedID: String(repeating: "b", count: 64)))
        let restore = CoreRequest(.restoreExecute(path: root.appendingPathComponent("unused.mbt").path, disabledGroups: [], includeSecure: true,
            preparedID: String(repeating: "a", count: 64)))
        var previousChallenge: CoreSecureChallenge?
        for request in [capture, restore] {
            runtime.start(request, location: CoreLocation(root: core, python: python, home: root, temporaryBase: root, toolDirectories: []))
            await waitUntil(runtime) { $0.secureChallenge != nil }
            let challenge = runtime.secureChallenge!
            precondition(challenge.operationID == request.operationID)
            precondition(challenge.kind == (request.command.operation == .restoreExecute ? .bundleUnlock : .bundleEncrypt))
            if let previousChallenge {
                precondition(!runtime.respond(to: previousChallenge, with: .secret(Data("late".utf8))),
                    "A timed-out Capture reply must not answer the following Restore challenge")
                precondition(runtime.secureChallenge == challenge)
            }
            await runtime.waitForCompletion()
            precondition(runtime.state == .failed && runtime.secureChallenge == nil && runtime.publicationOccurred == false)
            precondition(runtime.error == .coreFailure("secure_channel_timeout"))
            precondition(!runtime.respond(to: challenge, with: .secret(Data("late".utf8))))
            previousChallenge = challenge
        }
        print("PASS: Capture/Restore timeout invalidates native input; late replies cannot cross operation boundaries")
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
