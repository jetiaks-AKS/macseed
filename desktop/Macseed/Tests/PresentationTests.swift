import Foundation
import AppKit
import SwiftUI

private final class PreviewExpansionState: ObservableObject {
    @Published var ids: Set<String> = []
}

private struct PreviewExpansionHost: View {
    @ObservedObject var state: PreviewExpansionState
    let content: (Binding<Set<String>>) -> AnyView
    var body: some View { content(Binding(get: { state.ids }, set: { state.ids = $0 })) }
}

private final class SecureSelectionFixture: ObservableObject {
    @Published var selected: Set<String> = []
    @Published var groupsExpanded: Set<String> = []
    @Published var advancedSelected = false
    var expanded: Bool {
        get { groupsExpanded.contains(CaptureHierarchy.secureTransferID) }
        set {
            if newValue { groupsExpanded.insert(CaptureHierarchy.secureTransferID) }
            else { groupsExpanded.remove(CaptureHierarchy.secureTransferID) }
        }
    }
}

private struct SecureSelectionFixtureView: View {
    @ObservedObject var state: SecureSelectionFixture
    let inventory: CoreCaptureSecureInventory
    var body: some View {
        CaptureGroupedContent(rows: [TaskDomainPresentation(id: "git-configuration", title: "Git Configuration", symbol: "gearshape", items: []),
            TaskDomainPresentation(id: "ssh-configuration", title: "SSH Configuration", symbol: "key", items: [])],
            expanded: $state.groupsExpanded,
            secureTransferGroup: AnyView(secure),
            developerSelection: { group in group == .git ? AnyView(NativeSelectionCheckbox("", isOn: $state.advancedSelected, accessibilityTitle: "Select Git")) : AnyView(EmptyView()) }, summary: { _ in state.advancedSelected ? "All Selected" : "Not Selected" },
            attention: { _ in nil }) { row in Text(row.title).padding(16) }
    }
    private var secure: some View {
        CaptureSecureTransferView(inventory: inventory, selected: state.selected, editable: true,
            select: { id, included in
                if included { state.selected.insert(id) } else { state.selected.remove(id) }
            }, selectAll: { state.selected = $0 ? Set(inventory.items.map(\.id)) : [] }, expansion: $state.expanded)
    }
}

private final class SelectionHelpFixtureState: ObservableObject {
    @Published var selected = false
    @Published var groups: Set<String> = Set(DeveloperSelectionGroup.allCases.map(\.id))
    @Published var categoryExpanded = false
    @Published var showsSSH = true
    var titleFrames: [String: CGRect] = [:]
}

private struct SelectionHelpFixtureView: View {
    @ObservedObject var state: SelectionHelpFixtureState
    let flow: SelectionHelpFlow
    var body: some View {
        VStack(spacing: 0) {
            Text(flow == .capture ? "Capture Selection" : "Rebuild Selection").font(.title2).padding(16)
            WorkflowList {
                CaptureGroupedContent(rows: ["git-repositories", "ssh-configuration", "workspace-folders"]
                    .filter { state.showsSSH || $0 != "ssh-configuration" }
                    .map { TaskDomainPresentation(id: $0, title: CaptureCategory.title(for: $0), symbol: WorkspaceCategoryStyle.symbol($0), items: []) },
                    expanded: $state.groups,
                    developerSelection: { _ in AnyView(NativeSelectionCheckbox("", isOn: $state.selected)) },
                    summary: { _ in "Not Selected" }, attention: { _ in nil }) { row in
                    HStack(spacing: 12) {
                        NativeSelectionCheckbox("", isOn: $state.selected, accessibilityTitle: "Fixture category selection").frame(width: 28)
                        DisclosureGroup(isExpanded: $state.categoryExpanded) { Text("Fixture details") } label: {
                            SelectionCategoryTitle(id: row.id, title: DeveloperSelectionGroup.title(row.id, fallback: row.title),
                                symbol: row.symbol, flow: flow, toggle: { state.categoryExpanded.toggle() })
                                .fixedSize(horizontal: true, vertical: false)
                                .background(GeometryReader { proxy in Color.clear.preference(key: WorkflowAnchorFrames.self,
                                    value: [row.id: proxy.frame(in: .named("selection-help"))]) })
                        }.disclosureGroupStyle(SelectionCategoryDisclosureStyle())
                    }.padding(.horizontal, 16)
                    Color.clear.frame(height: 200)
                }
            }.environment(\.workflowListViewport, true).padding(.horizontal, 20)
            Divider()
            Text("Selection fixture").frame(maxWidth: .infinity, minHeight: 48)
        }.background(Color(nsColor: .windowBackgroundColor))
            .coordinateSpace(name: "selection-help").onPreferenceChange(WorkflowAnchorFrames.self) { state.titleFrames = $0 }
    }
}

private struct WorkflowAnchorFrames: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private final class CaptureRefinementState: ObservableObject {
    @Published var experiencedVisible = false
}

private struct CaptureRefinementHost: View {
    @ObservedObject var state: CaptureRefinementState
    let model: CaptureModel
    let runtime: CoreRuntime
    var body: some View {
        CaptureView(model: model, runtime: runtime, showsActions: false,
            categoryTreeExpansion: .constant(DeveloperSelectionGroup.disclosureIDs(
                model.categories.map(\.id) + [CaptureHierarchy.secureTransferID])),
            experiencedVisibility: $state.experiencedVisible)
    }
}

@main struct PresentationTests {
    @MainActor static func capturePreviewRefinementChecks(captureOnly: Bool = false) async throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: "/private/tmp/macseed-preview-refinement-" + UUID().uuidString)
        let output = URL(fileURLWithPath: "build/Debug/CapturePreviewRefinement")
        let fm = FileManager.default
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
        for folder in ["modules/core/application-interface", "config", "home", "tmp"] {
            try fm.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        defer { try? fm.removeItem(at: root) }
        for path in ["bootstrap.sh", "config/toolkit.conf", "modules/core/application-interface/core.py"] {
            try Data().write(to: root.appendingPathComponent(path))
        }
        try "#!/bin/bash\nexec /usr/bin/python3 -B fixture.py\n".write(
            to: root.appendingPathComponent("modules/core/application-interface/core.sh"), atomically: false, encoding: .utf8)
        // Structured disposable inventory only. No Discovery, encryption or publication.
        try """
        import json, sys
        request = json.load(sys.stdin)
        assert request['operation'] == 'capture_prepare'
        selection = request['parameters']['selection']
        rows = [dict(domain=domain, status='present', selection_mode='items',
                     items=[dict(item_id='fixture', label=label)])
                for domain, label in [('homebrew-packages','Ordinary fixture'),('git-configuration','Developer fixture')]]
        identities = [dict(item_id='a'*64, label='fixture_key', key_type='ssh-ed25519',
            fingerprint='SHA256:'+'A'*43, validation='candidate_requires_pair_validation')]
        summary = dict(selected_domains=0, selected_items=0, secure_identity_count=0)
        if selection:
            summary = dict(selected_domains=len(selection['categories'])+len(selection['items']),
                selected_items=sum(map(len,selection['items'].values()))
                    + sum(len(row['items']) for row in rows if row['domain'] in selection['categories']),
                secure_identity_count=len(selection['secure_identities']))
        result = dict(prepared_capture_id='b'*64, inventory=rows, selection=selection, summary=summary,
            secure_identities=dict(status='present', items=identities))
        for sequence, (kind, data) in enumerate([('started',{}),('result',result),('completed',{})],1):
            print(json.dumps(dict(protocol_version=1, operation_id=request['operation_id'],
                sequence=sequence, type=kind, data=data)), flush=True)
        """.write(to: root.appendingPathComponent("fixture.py"), atomically: false, encoding: .utf8)
        let runtime = CoreRuntime(operationLogs: nil)
        let model = CaptureModel(runtime: runtime, location: .init(root: root, python: URL(fileURLWithPath: "/usr/bin/python3"),
            home: root.appendingPathComponent("home"), temporaryBase: root.appendingPathComponent("tmp"), toolDirectories: []))
        model.scan(); await model.waitForCompletion()
        precondition(model.state == .review && model.selectedSecureIdentities.isEmpty)
        let visibility = CaptureRefinementState()
        precondition(!visibility.experiencedVisible)
        var windows: [NSWindow] = []
        defer { windows.forEach { $0.close() } }
        func host<V: View>(_ content: V, width: CGFloat = 721, dark: Bool = false) -> NSHostingView<some View> {
            let view = NSHostingView(rootView: content.frame(width: width).background(Color(nsColor: .windowBackgroundColor)))
            view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let window = NSWindow(contentRect: .init(x: 0, y: 0, width: width, height: 900),
                styleMask: [.titled], backing: .buffered, defer: false)
            windows.append(window); window.isReleasedWhenClosed = false
            window.contentView = view; window.orderFront(nil)
            return view
        }
        func settle(_ view: NSView) async throws {
            try await Task.sleep(for: .milliseconds(80))
            view.setFrameSize(view.fittingSize); view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        }
        func selectionBoxes(_ view: NSView) -> [NSButton] {
            let own = (view as? NSButton).map { $0.target is NativeSelectionCheckbox.Coordinator ? [$0] : [] } ?? []
            return own + view.subviews.flatMap(selectionBoxes)
        }
        func save(_ view: NSView, _ name: String) throws {
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
        }
        let review = host(CaptureRefinementHost(state: visibility, model: model, runtime: runtime))
        try await settle(review)
        let hiddenHeight = review.fittingSize.height
        try save(review, "capture-default-collapsed")
        precondition(selectionBoxes(review).count == 1, "Only Standard Setup has visible selection controls")
        // The collapsed experienced heading is the final row. Click its title,
        // then the leading chevron, through the same native event path as a user.
        let headingY = hiddenHeight - 16
        func clickHeading(x: CGFloat) {
            let window = review.window!
            let point = review.convert(NSPoint(x: x, y: review.isFlipped ? headingY : review.bounds.height - headingY), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                window.sendEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!)
            }
        }
        let originalSelection = model.selection
        clickHeading(x: 80); try await settle(review)
        precondition(visibility.experiencedVisible, "Clicking the section title expands the experienced container")
        precondition(selectionBoxes(review).contains { $0.accessibilityLabel() == "Select SSH Keys" })
        precondition(selectionBoxes(review).count >= 5, "Developer groups and Secure Transfer child checkboxes are visible")
        precondition(review.fittingSize.height > hiddenHeight + 80 && model.selection == originalSelection)
        precondition(model.selectedSecureIdentities.isEmpty, "Visibility is never Secure Transfer opt-in")
        model.selectItem("git-configuration", item: "fixture", included: true)
        model.selectSecureIdentity(String(repeating: "a", count: 64), included: true)
        let selected = model.selection
        precondition(CaptureReviewPresentation.experiencedSelectionSummary(model) == "1 developer category selected · 1 SSH identity selected")
        clickHeading(x: 80); try await settle(review)
        precondition(!visibility.experiencedVisible && model.selection == selected && selectionBoxes(review).count == 1)
        precondition(review.fittingSize.height < hiddenHeight + 45, "Only the small selection indicator remains; no hidden container space")
        try save(review, "capture-hidden-selections")
        clickHeading(x: 4); try await settle(review)
        precondition(visibility.experiencedVisible && model.selection == selected, "The leading disclosure chevron preserves selection and opt-in")
        model.prepare(destination: root.appendingPathComponent("fixture.mbt")); await model.waitForCompletion()
        precondition(model.state == .confirmation && model.selection == selected && visibility.experiencedVisible,
            "Disposable Prepare must retain selection and visibility: \(model.state), \(String(describing: model.failure))")
        model.editSelection(); try await settle(review)
        precondition(model.state == .review && model.selection == selected && visibility.experiencedVisible)
        try save(review, "capture-visible")
        let captureSource = try String(contentsOfFile: "Sources/CaptureView.swift")
        let workspaceSource = try String(contentsOfFile: "Sources/ProductionWorkspace.swift")
        precondition(captureSource.contains("experiencedVisible = false") && !captureSource.contains("@AppStorage"))
        precondition(workspaceSource.contains("experiencedVisibility: $captureExperiencedVisible")
            && workspaceSource.contains("captureExperiencedVisible = false"))
        print("PASS: Capture starts collapsed; title/chevron expand and collapse; no empty container; selections/opt-in unchanged; hidden counts; Back/Next retain workflow state")
        if captureOnly { return }

        func item(_ id: String, _ state: TaskRowState) -> TaskItemPresentation {
            .init(id: id, item: .init(id: id, title: id, status: state == .matching ? .matching : state == .planned ? .ready : .attention,
                action: state == .matching ? "" : "Existing explanation"), state: state)
        }
        func domain(_ id: String, _ items: [TaskItemPresentation]) -> TaskDomainPresentation {
            .init(id: id, title: CaptureCategory.title(for: id), symbol: WorkspaceCategoryStyle.symbol(id), items: items)
        }
        let matching = (0..<103).map { item("matching-only-\($0)", .matching) }
        let mixed = [domain("homebrew-casks", Array(matching.prefix(50)) + [item("planned-app", .planned), item("attention-app", .attention)]),
            domain("macos-settings", [matching[50], item("planned-setting", .planned)]),
            domain("git-configuration", Array(matching.dropFirst(51))),
            domain("ssh-configuration", [item("attention-ssh", .unverified)])]
        let settings = [domain("macos-finder", [matching[50]]), domain("macos-dock", [item("planned-setting", .planned)])]
        let ready = RestorePrerequisiteSummaryPresentation(conditions: [], ready: true)
        let installedItem = TaskItemPresentation(id: "manual-app", item: .init(id: "manual-app", title: "Manual application", status: .matching, action: ""),
            state: .matching, assistedAppStore: .init(appID: "123456", status: .installed))
        let installed = AppStoreRestorePresentation(domains: [domain("app-store", [installedItem])])
        let counts = RestorePreviewMetrics.counts(mixed)
        precondition(counts.matching == 103 && counts.changes == 2 && counts.attention == 2)
        let summarySource = try String(contentsOfFile: "Sources/RestoreView.swift")
            .components(separatedBy: "struct RestorePreviewMetrics: View {")[1]
            .components(separatedBy: "// Called only from")[0]
        precondition(summarySource.contains("if counts.matching > 0 { Self.metric(\"Already Match\"")
            && summarySource.contains("if counts.changes > 0") && summarySource.contains("if counts.attention > 0")
            && !summarySource.contains("no action needed."))
        let preview = RestorePreviewContent(title: "Needs Attention", state: .attention, domains: mixed, alreadyMatches: false,
            previewEvaluated: true, prerequisites: ready, areas: [], settingsCategories: settings,
            categoryExpansion: .constant(true), appStore: installed, reviewAppStore: {}, showsActions: false)
        precondition(preview.visibleDomains.map(\.id) == ["homebrew-casks", "macos-settings", "ssh-configuration"])
        precondition(preview.visibleSettings.map(\.id) == ["macos-dock"])
        precondition(RestorePreviewVisibility.items(mixed[0].items).map(\.id) == ["planned-app", "attention-app"])
        precondition(RestorePreviewMetrics.badges(mixed[0]).map { "\($0.0):\($0.1)" } == ["Planned:1", "Attention:1"])
        precondition(preview.allMatchCount == nil && preview.prerequisitesSatisfied && !preview.showsPrerequisites
            && preview.manualInventory?.allInstalled == true && preview.manualWork == nil)
        for state in [TaskRowState.attention, .unverified, .failed, .partial, .skipped, .waiting, .notRun, .planned] {
            precondition(RestorePreviewVisibility.includes(domain("problem", [item("retained", state)])))
        }
        var diagnosticMatch = matching[0]; diagnosticMatch.previewProblem = "Observation failed"
        precondition(!RestorePreviewVisibility.isMatching(diagnosticMatch))
        let allMatching = [domain("git-configuration", matching)]
        var noOp = RestorePreviewContent(title: "", state: .matching, domains: allMatching, alreadyMatches: true,
            previewEvaluated: true, prerequisites: ready, areas: [], appStore: installed, reviewAppStore: {}, showsActions: false)
        precondition(noOp.allMatchCount == 104 && noOp.visibleDomains.isEmpty && !noOp.canRebuild)
        noOp.previewEvaluated = false
        precondition(noOp.allMatchCount == nil && !noOp.prerequisitesSatisfied)
        noOp.previewEvaluated = true; noOp.needsRefresh = true
        precondition(noOp.allMatchCount == nil && !noOp.prerequisitesSatisfied)
        noOp.needsRefresh = false; noOp.retrying = true
        precondition(noOp.allMatchCount == nil)
        noOp.retrying = false
        var pendingItem = installedItem
        pendingItem.assistedAppStore = .init(appID: "123456", status: .unverified)
        noOp.appStore = AppStoreRestorePresentation(domains: [domain("app-store", [pendingItem])])
        precondition(noOp.allMatchCount == nil && noOp.manualWork != nil)
        noOp.appStore = installed
        let empty = RestorePreviewContent(title: "", state: .matching, domains: [], alreadyMatches: true,
            previewEvaluated: true, prerequisites: ready, areas: [], appStore: .init(domains: []), showsActions: false)
        precondition(empty.allMatchCount == nil && empty.manualInventory == nil && empty.visibleDomains.isEmpty)
        let failed = RestorePreviewContent(title: "Failed", state: .failed, domains: allMatching, alreadyMatches: true,
            previewEvaluated: true, prerequisites: .init(conditions: [], ready: false), areas: [], showsActions: false)
        precondition(failed.allMatchCount == nil && !failed.prerequisitesSatisfied)
        precondition(mixed.flatMap(\.items).count == 107 && matching.count == 103, "Filtering never changes the input inventory")
        print("PASS: 103/2/2 full counts retained; matching-only categories/settings/leaves hidden; blue/orange badges and all problem states retained")
        print("PASS: all-match requires completed positive evidence; zero/failed/stale/pending manual states remain distinct")

        let confirmation = [domain("git-configuration", (0..<5).map { item("git-\($0)", .planned) }),
            domain("workspace-folders", (0..<7).map { item("folder-\($0)", .planned) }),
            domain("ssh-configuration", [item("ssh-warning", .attention)]),
            TaskDomainPresentation(id: CaptureHierarchy.secureTransferID, title: "Secure Transfer", symbol: "lock.shield",
                items: [item("first-identity", .planned), item("second-identity", .planned)])]
        let confirmationIDs = CaptureHierarchy.disclosureIDs(confirmation.map(\.id), scope: .advanced)
        let shared = try String(contentsOfFile: "Sources/TaskComponents.swift")
        let secure = shared.components(separatedBy: "private var captureSecureTransferGroup:")[1].components(separatedBy: "private func captureSettings")[0]
        precondition(secure.contains("if !captureResultLayout") && secure.contains("domainRow(domain)"))
        precondition(shared.contains("CaptureRowColumns(title: domainTitle(domain), status: domainStatus(domain))")
            && shared.contains("CaptureStatusText.textInset"))
        precondition(shared.contains(#"return "\(domain.items.count) SSH \(domain.items.count == 1 ? "identity" : "identities")""#))
        let reviewSource = try String(contentsOfFile: "Sources/CapturePresentation.swift")
        precondition(reviewSource.contains("if experiencedVisibility?.wrappedValue == false, let hiddenSelectionSummary")
            && reviewSource.contains("Text(hiddenSelectionSummary)"))
        for width: CGFloat in [721, 921] {
            var anchors: [String: CGRect] = [:]
            let columns = VStack(spacing: 0) {
                ForEach(confirmation) { row in
                    CaptureRowColumns(title: Text(row.title), status: VStack(alignment: .leading, spacing: 3) {
                        TaskStatusLabel(state: row.state, title: row.state == .planned ? "Ready to Save" : nil)
                            .background(GeometryReader { proxy in Color.clear.preference(key: WorkflowAnchorFrames.self,
                                value: [row.id + ".status": proxy.frame(in: .named("confirmation-columns"))]) })
                        Text("\(row.items.count) included").font(.caption).padding(.leading, CaptureStatusText.textInset)
                            .background(GeometryReader { proxy in Color.clear.preference(key: WorkflowAnchorFrames.self,
                                value: [row.id + ".count": proxy.frame(in: .named("confirmation-columns"))]) })
                    })
                }
            }.coordinateSpace(name: "confirmation-columns").onPreferenceChange(WorkflowAnchorFrames.self) { anchors = $0 }
            let measured = host(columns, width: width); try await settle(measured)
            precondition(anchors.count == confirmation.count * 2)
            for suffix in [".status", ".count"] {
                let positions = confirmation.map { anchors[$0.id + suffix]!.minX }
                precondition(positions.max()! - positions.min()! < 1, "Every category uses one status/count column")
            }
        }
        for dark in [false, true] { for width: CGFloat in [721, 921] {
            let view = host(preview, width: width, dark: dark); try await settle(view)
            precondition(view.fittingSize.width <= width + 1)
            let filtered = host(TaskDomainItems(domain: mixed[0], restorePreview: true, hideMatchingPreviewItems: true), width: width, dark: dark)
            let actions = host(TaskDomainItems(domain: domain("homebrew-casks", Array(mixed[0].items.suffix(2))),
                restorePreview: true), width: width, dark: dark)
            try await settle(filtered); try await settle(actions)
            precondition(abs(filtered.fittingSize.height - actions.fittingSize.height) < 1,
                "50 matching leaves reserve no space; planned and attention rows retain their full layout")
            try save(view, "preview-mixed-\(Int(width))-\(dark)")
            let capture = host(TaskDomainList(domains: confirmation, stateTitles: [.planned: "Ready to Save"], compactReadyItems: true,
                captureHierarchy: true, expansion: .constant(confirmationIDs)), width: width, dark: dark)
            try await settle(capture)
            let collapsed = host(TaskDomainList(domains: confirmation, stateTitles: [.planned: "Ready to Save"],
                compactReadyItems: true, captureHierarchy: true, expansion: .constant([])), width: width, dark: dark)
            try await settle(collapsed)
            precondition(capture.fittingSize.height > collapsed.fittingSize.height + 40,
                "Secure Transfer identities and ordinary details retain independent expansion")
            try save(capture, "capture-confirmation-\(Int(width))-\(dark)")
        } }
        let matched = host(noOp); try await settle(matched)
        precondition(matched.fittingSize.height < 500, "All-match Preview omits empty automatic/advanced containers")
        try save(matched, "preview-all-matching-manual-inventory")
        let manualOnly = RestorePreviewContent(title: "", state: .matching, domains: [], alreadyMatches: true,
            previewEvaluated: true, prerequisites: ready, areas: [], appStore: installed, reviewAppStore: {}, showsActions: false)
        precondition(manualOnly.allMatchCount == 1 && manualOnly.manualInventory != nil && manualOnly.manualWork == nil)
        let manualView = host(manualOnly); try await settle(manualView)
        precondition(abs(manualView.fittingSize.height - matched.fittingSize.height) < 2,
            "Fully installed inventory is counted without reserving a manual section")
        try save(manualView, "preview-manual-only")
        let restoreSource = try String(contentsOfFile: "Sources/RestoreView.swift")
        let leading = restoreSource.components(separatedBy: "private var listLeadingContent:")[1].components(separatedBy: "struct RestorePreparationActions:")[0]
        precondition(leading.range(of: "prerequisiteDetails")!.lowerBound < leading.range(of: "Manual Installation")!.lowerBound)
        precondition(!leading.contains("domains.isEmpty") && !leading.contains("pinnedList"))
        precondition(restoreSource.contains("Button(retrying ? \"Checking…\" : \"Fix Issues…\") { checkAgain?() }"))
        print("PASS: native mixed/all-match/manual-only presentation and expandable Capture identities; Light/Dark at 721/921 pt; conditional prerequisite/manual order")
    }

    @MainActor static func previewCleanupChecks() throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        func item(_ id: String, _ state: TaskRowState) -> TaskItemPresentation {
            .init(id: id, item: .init(id: id, title: id,
                status: state == .matching ? .matching : state == .planned ? .ready : .unverified,
                action: state == .planned ? "Will install" : state == .matching ? "" : "Installer preparation required"), state: state)
        }
        func domain(_ id: String, _ items: [TaskItemPresentation]) -> TaskDomainPresentation {
            .init(id: id, title: CaptureCategory.title(for: id), symbol: WorkspaceCategoryStyle.symbol(id), items: items, previewOnly: true)
        }
        let bridge = CoreRestorePreparation.Condition(domain: CoreRestorePreparation.secureDomain,
            code: "secure_bridge_required", status: "external_action_required", selectedItemIndex: nil, scope: "execution_launch")
        let matching = [domain("homebrew-casks", (0..<115).map { item("matching-\($0)", .matching) }),
            domain(CoreRestorePreparation.secureDomain, [item(CoreRestorePreparation.secureItem, .matching)])]
        func content(_ conditions: [CoreRestorePreparation.Condition], ready: Bool = true) -> RestorePreviewContent {
            RestorePreviewContent(title: "", state: .matching, domains: matching, alreadyMatches: true,
                previewEvaluated: true, prerequisites: .init(conditions: conditions, ready: ready), areas: [], showsActions: false)
        }
        let matched = content([bridge])
        precondition(bridge.isSecureLaunchRequirement && bridge.status != "satisfied")
        precondition(matched.prerequisitesSatisfied && !matched.showsPrerequisites && matched.allMatchCount == 116 && !matched.canRebuild,
            "Execution-launch bridge metadata must not manufacture a prerequisite error after all-match comparison")
        precondition(content([]).allMatchCount == 116 && !content([]).showsPrerequisites)
        let satisfied = CoreRestorePreparation.Condition(domain: "homebrew-casks", code: "homebrew_available",
            status: "satisfied", selectedItemIndex: nil, scope: "operation")
        precondition(!content([satisfied]).showsPrerequisites && content([satisfied]).allMatchCount == 116)
        let blocked = CoreRestorePreparation.Condition(domain: "homebrew-packages", code: "homebrew_unavailable",
            status: "external_action_required", selectedItemIndex: nil, scope: "operation")
        let problem = content([bridge, blocked], ready: false)
        precondition(problem.showsPrerequisites && problem.allMatchCount == nil
            && problem.prerequisites.manualConditions.map(\.code) == ["homebrew_unavailable"])
        precondition(content([], ready: false).showsPrerequisites && content([], ready: false).allMatchCount == nil,
            "Unexplained false readiness remains unconfirmed, never success")
        var incomplete = matched; incomplete.previewEvaluated = false
        precondition(incomplete.allMatchCount == nil)
        incomplete = matched; incomplete.needsRefresh = true
        precondition(incomplete.allMatchCount == nil)
        incomplete = matched; incomplete.retryMessage = "Automation access denied."
        precondition(incomplete.showsPrerequisites && incomplete.allMatchCount == nil)
        let empty = RestorePreviewContent(title: "", state: .matching, domains: [], alreadyMatches: true,
            previewEvaluated: true, prerequisites: .init(conditions: [], ready: true), areas: [], showsActions: false)
        precondition(empty.allMatchCount == nil && !empty.showsPrerequisites)

        var app = item("manual-app", .matching); app.assistedAppStore = .init(appID: "123456", status: .installed)
        var installed = matched; installed.appStore = .init(domains: [domain("app-store", [app])])
        precondition(installed.manualInventory?.items.count == 1 && installed.manualWork == nil && installed.allMatchCount == 117)
        var manualOnly = empty
        for status in [AssistedAppStoreItem.Status.missing, .unverified] {
            app.assistedAppStore = .init(appID: "123456", status: status)
            manualOnly.appStore = .init(domains: [domain("app-store", [app])])
            precondition(manualOnly.manualWork?.attentionCount == 1 && manualOnly.allMatchCount == nil && manualOnly.visibleDomains.isEmpty)
        }
        manualOnly.reviewAppStore = {}

        let changes = domain("homebrew-casks", [item("jordanbaird-ice", .planned), item("tailscale-app", .attention)])
        let expanded = RestorePreviewCategoryStatus(domain: changes, stateTitles: [:], parentState: .attention, expanded: true)
        precondition(expanded.isRedundant)
        precondition(!RestorePreviewCategoryStatus(domain: changes, stateTitles: [:], parentState: .attention).isRedundant)
        precondition(!RestorePreviewCategoryStatus(domain: changes, stateTitles: [:], parentState: .planned, expanded: true).isRedundant)
        precondition(!RestorePreviewCategoryStatus(domain: changes, stateTitles: [:], expanded: true).isRedundant,
            "Main headers never lose status text")
        for state in [TaskRowState.unverified, .failed, .partial, .waiting] {
            let distinct = domain("homebrew-casks", [item("distinct", state)])
            precondition(!RestorePreviewCategoryStatus(domain: distinct, stateTitles: [:], parentState: distinct.state, expanded: true).isRedundant)
        }
        let pkg = CoreRestorePreparation.Condition(domain: "homebrew-casks", code: "cask_execution_requirements_unsupported",
            status: "unsupported", selectedItemIndex: 2, scope: "item", diagnostic: .init(primitive: "pkgutil", condition: "preparation_required"))
        let mixed = RestorePreviewContent(title: "", state: .attention,
            domains: [domain("homebrew-casks", matching[0].items + changes.items)], alreadyMatches: false,
            previewEvaluated: true, prerequisites: .init(conditions: [pkg], ready: true, hasInstallerPreparations: true), areas: [],
            categoryExpansion: .constant(true), showsActions: false, checkAgain: {})
        precondition(mixed.showsPrerequisites && mixed.showsFixIssues && mixed.visibleDomains.count == 1)
        precondition(RestorePreviewMetrics.badges(changes).map(\.0) == ["Planned", "Attention"])
        let source = try String(contentsOfFile: "Sources/RestoreView.swift")
        precondition(!source.contains("Prerequisites could not be confirmed") && !source.contains("All prerequisites satisfied"))
        precondition(source.contains("if showsPrerequisites { prerequisiteDetails }") && source.contains("if let appStore = manualWork"))
        precondition(source.contains("Button(retrying ? \"Checking…\" : \"Fix Issues…\") { checkAgain?() }"))
        precondition(source.contains("Your approval may be required. No applications will be installed yet."))
        let metrics = source.components(separatedBy: "struct RestorePreviewMetrics: View {")[1].components(separatedBy: "// Called only from")[0]
        precondition(metrics.contains("if counts.matching > 0 { Self.metric(\"Already Match\"")
            && metrics.contains("if counts.changes > 0 { Self.metric(\"Changes Planned\"")
            && metrics.contains("if counts.attention > 0 { Self.metric(\"Need Attention\"")
            && metrics.contains("WorkspaceThreeMetrics { cards(counts) }") && !metrics.contains("no action needed."))
        precondition(source.contains("WorkspaceMetricCard(title: \"Everything Already Matches\", value: \"\\(count) ")
            && source.contains("All selected items already match this Mac.\\nNo changes needed."))
        let output = URL(fileURLWithPath: "build/Debug/PreviewCleanup")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        func render(_ content: RestorePreviewContent, _ name: String) throws -> CGFloat {
            let host = NSHostingView(rootView: content.frame(width: 721).background(Color(nsColor: .windowBackgroundColor)))
            let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 721, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
            defer { window.close() }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
            host.setFrameSize(host.fittingSize); host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
            return host.fittingSize.height
        }
        let matchedHeight = try render(matched, "all-matching-secure-bridge")
        let installedHeight = try render(installed, "all-matching-installed-apps")
        precondition(matchedHeight < 250 && abs(matchedHeight - installedHeight) < 1,
            "Satisfied prerequisites and installed manual inventory reserve no section space")
        let manualHeight = try render(manualOnly, "manual-only-unverified")
        precondition(manualHeight > matchedHeight, "Pending manual work keeps its section; all-match has only one card")
        _ = try render(mixed, "mixed-global-fix-issues")
        for (matches, changes, attention) in [(103, 2, 2), (115, 0, 1)] {
            let rows = [domain("homebrew-casks", (0..<matches).map { item("match-\($0)", .matching) }
                + (0..<changes).map { item("planned-\($0)", .planned) }
                + (0..<attention).map { item("attention-\($0)", .attention) })]
            let counts = RestorePreviewMetrics.counts(rows)
            precondition(counts.matching == matches && counts.changes == changes && counts.attention == attention)
            let cards = RestorePreviewContent(title: "", state: .attention, domains: rows, alreadyMatches: false,
                previewEvaluated: true, prerequisites: .init(conditions: [], ready: true), areas: [], showsActions: false)
            _ = try render(cards, "cards-\(matches)-\(changes)-\(attention)")
        }
        print("PASS: dynamic nonzero green/blue/orange cards; one full-width all-match card; genuine blockers/incomplete states and action-focused filtering retained")
    }

    @MainActor static func captureConfirmationPrivacyChecks(_ source: String) {
        let selected = CaptureModel.confirmationPrivacyMessage(includesSSHIdentities: true).lowercased()
        precondition(selected.contains("ssh identities are encrypted separately"),
            "Selected identities must disclose their separate encryption")
        precondition(selected.contains("other saved settings are not encrypted"),
            "Identity encryption must not imply that ordinary settings are encrypted")
        precondition(selected.contains("bundle passphrase") && selected.contains("safe"),
            "Secure Capture must retain passphrase safekeeping guidance")
        let ordinary = CaptureModel.confirmationPrivacyMessage(includesSSHIdentities: false).lowercased()
        precondition(ordinary.contains("saved settings are not encrypted"))
        precondition(!["ssh", "identities", "secure transfer", "passphrase"].contains(where: ordinary.contains),
            "Capture without identities must omit irrelevant Secure Transfer guidance")

        let confirmation = source.components(separatedBy: "case .confirmation:")[1]
            .components(separatedBy: "case .result:")[0]
        let preparedSelection = #"let\s+selection\s*=\s*prepared\s*\.\s*publicationSelection"#
        let contextualMessage = #"Text\s*\(\s*CaptureModel\s*\.\s*confirmationPrivacyMessage\s*\(\s*includesSSHIdentities\s*:\s*!\s*selection\s*\.\s*secureIdentities\s*\.\s*isEmpty\s*\)\s*\)"#
        precondition(confirmation.range(of: preparedSelection, options: .regularExpression) != nil
            && confirmation.range(of: contextualMessage, options: .regularExpression) != nil,
            "CaptureView must render the model's privacy message for the prepared publication selection")
        print("PASS: Capture Confirmation contextual encryption boundary, passphrase guidance and prepared-selection presentation")
    }

    @MainActor static func externalIdentityChecks() async throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        var windows: [NSWindow] = []
        defer { windows.forEach { $0.close() } }
        let source = try String(contentsOfFile: "Sources/CaptureView.swift")
        let picker = source.components(separatedBy: "private func chooseSSHIdentity()")[1].components(separatedBy: "private var disclosureIDs")[0]
        precondition(picker.contains("NSOpenPanel()") && picker.contains("allowsMultipleSelection = false")
            && picker.contains("canChooseDirectories = false") && picker.contains("resolvesAliases = false")
            && picker.contains("model.addSSHIdentity"))
        captureConfirmationPrivacyChecks(source)
        precondition(source.contains("manualIDs: model.manualIdentityIDs"))
        var items: [CoreCaptureSecureInventory.Identity] = []
        for index in 0..<3 {
            let label = index == 0 ? "id_standard" : String(repeating: "external_", count: 8) + String(index)
            let fingerprint = "SHA256:" + Data(repeating: UInt8(index), count: 32).base64EncodedString().replacingOccurrences(of: "=", with: "")
            items.append(.init(itemID: String(repeating: String(index), count: 64), label: label,
                keyType: "ssh-ed25519", fingerprint: fingerprint, validation: "candidate_requires_pair_validation",
                source: index == 0 ? nil : "manual"))
        }
        let inventory = CoreCaptureSecureInventory(status: "present", reason: nil, items: items)
        try inventory.validate()
        let all = Set(inventory.items.map(\.id)), manual = Set(inventory.items.dropFirst().map(\.id))
        for (selection, expected) in [(Set<String>(), SelectionState.none), (Set([inventory.items[1].id]), .mixed), (all, .all)] {
            precondition(CaptureSecureTransferView(inventory: inventory, selected: selection).selectionState == expected)
        }
        let output = URL(fileURLWithPath: "build/Debug/ExternalSSH")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for width: CGFloat in [580, 1040] { for dark in [false, true] {
            var added = false, removed: String?, selection = Set([inventory.items[1].id]), expanded = true
            let view = CaptureSecureTransferView(inventory: inventory, selected: selection, editable: true,
                select: { id, included in if included { selection.insert(id) } else { selection.remove(id) } },
                selectAll: { selection = $0 ? all : [] }, expansion: Binding(get: { expanded }, set: { expanded = $0 }),
                addIdentity: { added = true }, removeIdentity: { removed = $0 }, manualIDs: manual)
            let host = NSHostingView(rootView: view.frame(width: width).background(Color(nsColor: .windowBackgroundColor)))
            let window = NSWindow(contentRect: .init(x: 0, y: 0, width: width, height: host.fittingSize.height), styleMask: [.borderless], backing: .buffered, defer: false)
            windows.append(window)
            window.isReleasedWhenClosed = false; window.contentView = host; host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.orderFront(nil); try await Task.sleep(for: .milliseconds(60)); host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            precondition(host.fittingSize.width <= width + 1 && host.fittingSize.height < 850)
            func buttons(_ view: NSView) -> [NSButton] { (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons) }
            let masters = buttons(host).filter { $0.target is NativeSelectionCheckbox.Coordinator }
            precondition(masters.count == 4 && masters[0].state == .mixed)
            precondition(NSApp.sendAction(masters[0].action!, to: masters[0].target, from: masters[0]))
            precondition(selection == all && expanded)
            view.selectAll(false); precondition(selection.isEmpty && expanded)
            view.expansion?.wrappedValue = false; precondition(selection.isEmpty)
            view.addIdentity?(); view.removeIdentity(inventory.items[1].id)
            precondition(added && removed == inventory.items[1].id && selection.isEmpty)
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("manual-\(Int(width))-\(dark ? "dark" : "light").png"))
        } }
        print("PASS: native Add picker contract; same rows/master; unchecked additions/removal callbacks; disclosure independence; destination confirmation")
        print("PASS: manual identity rows, long names and fingerprints render in Light/Dark at 580/1040 pt (4 renders)")
    }

    @MainActor static func settingsToolsChecks() async throws {
        _ = NSApplication.shared
        let source = try String(contentsOfFile: "Sources/FoundationSettings.swift")
        let tabs = ["General", "Tools & Dependencies", "Operation Logs"]
        var previous = source.startIndex
        precondition(source.components(separatedBy: ".tabItem").count == 4)
        for title in tabs {
            let found = source.range(of: "Label(\"" + title + "\"", range: previous..<source.endIndex)!
            previous = found.upperBound
        }
        let general = source.components(separatedBy: "struct FoundationGeneralSettings:")[1].components(separatedBy: "struct FoundationToolsSettings:")[0]
        precondition(general.contains("DesktopAppearance.allCases") && general.contains("About Macseed…") && !general.contains("HomebrewDependencySection"))
        let tools = source.components(separatedBy: "struct FoundationToolsSettings:")[1].components(separatedBy: "struct BundledAgeObservation:")[0]
        precondition(tools.contains("HomebrewDependencySection(model: homebrew)") && tools.contains("GroupBox(\"Built-in Tools\")"))
        precondition(source.contains("await age.checkIfNeeded()") && tools.contains("await age.check()") && !tools.contains("await homebrew.check()"))
        precondition(source.contains("OperationLogWindowController.shared.open(runtime: CoreRuntime.shared, target: nil)") && source.contains("selectedTab = \"general\""))
        precondition(!source.contains("Label(\"Updates\"") && !source.contains("v1.3.2") && !source.contains("SHA256"))
        let brewSource = try String(contentsOfFile: "Sources/HomebrewSetup.swift")
        let section = brewSource.components(separatedBy: "struct HomebrewDependencySection:")[1].components(separatedBy: "struct HomebrewPrerequisiteAction:")[0]
        precondition(section.contains("GroupBox(\"External Dependencies\")") && section.contains("await model.check()") && section.contains("model.beginSetup(returningTo: NSApp.keyWindow)"))
        precondition(section.contains("$model.remindersEnabled") && section.contains("openWindow(id: \"homebrew-setup\")"))
        let suite = "macseed.settings.presentation." + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let output = URL(fileURLWithPath: "build/Debug/SettingsTools")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let homebrew = HomebrewSetupModel(host: .init(architecture: .appleSilicon, majorVersion: 27, version: "27.2"),
            preferences: preferences, detect: { .usable }, packageStagingBase: output.appendingPathComponent("unused-packages"))
        await homebrew.check()
        var next = BundledAgeObservation(status: .available, version: "v1.3.2", architecture: "arm64")
        var checks = 0
        let age = BundledAgeSettingsModel { checks += 1; return next }
        await age.check()
        func render<V: View>(_ view: V, name: String, width: CGFloat, dark: Bool) async throws {
            let host = NSHostingView(rootView: view.frame(width: width).background(Color(nsColor: .windowBackgroundColor)))
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let fitting = host.fittingSize
            precondition(abs(fitting.width - width) < 1 && fitting.height > 80 && fitting.height < 530, "Settings must retain compact native geometry")
            let window = NSWindow(contentRect: .init(origin: .zero, size: fitting), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host
            window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(60))
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            precondition(host.fittingSize.width <= width + 1)
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("\(name)-\(Int(width))-\(dark ? "dark" : "light").png"))
            window.close()
        }
        for dark in [false, true] {
            for width: CGFloat in [440, 620] {
                try await render(FoundationGeneralSettings(showAbout: {}).defaultAppStorage(preferences), name: "general", width: width, dark: dark)
                try await render(FoundationToolsSettings(homebrew: homebrew, age: age), name: "tools-available", width: width, dark: dark)
            }
            try await render(FoundationSettingsView(homebrew: homebrew, showAbout: {}).defaultAppStorage(preferences), name: "tabs", width: 440, dark: dark)
        }
        precondition(checks == 1, "SwiftUI body/reappearance must not repeat validation")
        next = .init(status: .invalid); await age.check()
        for dark in [false, true] { for width: CGFloat in [440, 620] {
            try await render(FoundationToolsSettings(homebrew: homebrew, age: age), name: "tools-invalid", width: width, dark: dark)
        } }
        precondition(checks == 2)
        print("PASS: three native Settings tabs; General Appearance/About; moved shared Homebrew controls/reminders; unchanged Logs action; no updater placeholders")
        print("PASS: Light/Dark native Settings renders at 440/620 pt; healthy/invalid age; compact geometry; no body-driven repeated checks (14 renders)")
    }

    @MainActor static func securePassphraseChecks() async throws {
        if !CommandLine.arguments.contains("--secure-dialog-only") { try await secureComparisonChecks() }
        let source = try String(contentsOfFile: "Sources/RestoreView.swift", encoding: .utf8)
        let selection = source.components(separatedBy: "struct RestoreSelectionContent: View {")[1].components(separatedBy: "// Only section placement")[0]
        let secure = selection.components(separatedBy: "private var secureTransferGroup: AnyView?")[1]
        precondition(secure.contains("WorkflowExpansion.binding(CaptureHierarchy.secureTransferID") && secure.contains("if treeExpansion"))
        precondition(secure.contains("Encrypted SSH keys. Existing keys won't be overwritten."))
        precondition(selection.contains("RestoreSelectionPresentation.disclosureIDs(areas, advanced: advanced, secureAvailable: model.inspection?.secureComponent == true)") && !selection.contains("ids.insert(CoreRestorePreparation.secureDomain)"))
        let capture = try String(contentsOfFile: "Sources/CaptureView.swift", encoding: .utf8)
        let capturePresentation = try String(contentsOfFile: "Sources/CapturePresentation.swift", encoding: .utf8)
        let captureSecure = capturePresentation.components(separatedBy: "struct CaptureSecureTransferView: View")[1]
        precondition(captureSecure.contains("expanded:") && captureSecure.contains("if "))
        let details = try String(contentsOfFile: "Sources/TaskComponents.swift", encoding: .utf8)
        precondition(details.contains("restorePreview && item.sourceDomain == CoreRestorePreparation.secureDomain"))
        let output = URL(fileURLWithPath: "build/Debug/Stage16HPassphrase")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        func descendants<T: NSView>(_ view: NSView, _: T.Type) -> [T] {
            (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, T.self) }
        }
        let runtime = CoreRuntime(operationLogs: nil)
        let identity = CoreSecureChallenge.Identity(name: String(repeating: "fixture_", count: 10), keyType: "ssh-ed25519",
            fingerprint: "SHA256:" + Data(repeating: 1, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: ""), position: 3, total: 12)
        let challenge = CoreSecureChallenge(identity: identity, operationID: "presentation", challengeID: String(repeating: "a", count: 32), kind: .sshKeyUnlock, attempt: 2)
        for width: CGFloat in [580, 1040] { for dark in [false, true] {
            let host = NSHostingView(rootView: CaptureSecureInputView(runtime: runtime, challenge: challenge, restoring: true)
                .frame(width: width).background(Color(nsColor: .windowBackgroundColor)))
            let window = NSWindow(contentRect: .init(x: 0, y: 0, width: width, height: host.fittingSize.height), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.orderFront(nil); try? await Task.sleep(for: .milliseconds(60)); host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            precondition(host.fittingSize.width <= width + 1 && host.fittingSize.height < 640)
            let fields = descendants(host, NSTextField.self).filter { $0.isEditable }
            precondition(fields.count == 1 && fields[0] is NSSecureTextField && fields[0].stringValue.isEmpty)
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("unlock-\(Int(width))-\(dark ? "dark" : "light").png"))
            window.close()
        } }
        var entry = CaptureSecureEntry()
        entry.passphrase = "disposable validation input"
        precondition(entry.consume(for: .sshKeyUnlock) != nil && entry.passphrase.isEmpty && entry.confirmation.isEmpty)
        entry.passphrase = "disposable validation input"; entry.clear()
        precondition(entry.passphrase.isEmpty && entry.confirmation.isEmpty)
        precondition(capture.contains(".onChange(of: runtime.secureChallenge)") && capture.contains(".onDisappear { entry.clear()"))
        print("PASS: Selection static description/no secure disclosure; Capture/Preview remain expandable; matching caption scope retained")
        print("PASS: identity-bound SecureField, long name/fingerprint and retry layout at 580/1040pt Light/Dark; transient input clearing (4 renders)")
    }

    static func bundledAgeErrorChecks() throws {
        let capture = CaptureFailure.runtime(.coreFailure("age_unavailable"))
        precondition(capture.technicalReason == "age_unavailable" && capture.message.contains("bundled") && capture.message.contains("reinstall Macseed"))
        let condition = CoreRestorePreparation.Condition(domain: CoreRestorePreparation.secureDomain, code: "age_unavailable",
            status: "external_action_required", selectedItemIndex: nil, scope: "operation")
        let prerequisite = RestorePrerequisiteView(condition: condition, label: "Secure Transfer")
        precondition(prerequisite.message.contains("bundled") && prerequisite.message.contains("Refresh Preview"))
        precondition(!capture.message.contains("Homebrew") && !prerequisite.message.contains("Homebrew"))
        let source = try String(contentsOfFile: "Sources/RestoreModel.swift", encoding: .utf8)
        precondition(source.contains("case \"secure_comparison_unavailable\": message = \"Secure comparison could not use the bundled tool"))
        print("PASS: existing Capture failure and Rebuild prerequisite/error surfaces explain missing/damaged bundled tool without external-install advice")
    }

    static func secureStartupErrorChecks() throws {
        var finish = OperationLogRecord(.finish)
        finish.processLaunched = true; finish.terminalValid = true; finish.eventType = "failed"
        finish.exitCode = 2; finish.signalled = false; finish.runtimeError = "secure_comparison_failed"
        finish.verificationStatus = "not_run"; finish.detailStatus = "not_run"; finish.incomplete = false
        precondition(OperationLogSanitizer.valid(finish))
        let rows = OperationLogSummaryPresentation.rows(finish: finish, active: false, records: [finish])
        precondition(rows.first { $0.id == "process" }?.value == "Failed" && rows.first { $0.id == "verification" }?.value == "Not Run")
        let id = UUID()
        var header = OperationLogRecord(.header); header.storageID = id; header.operation = .secureRestoreCompare; header.operationID = UUID()
        var report = DiagnosticReportBuilder(id: id, environment: .current())
        report.receive(header); report.receive(finish)
        precondition(report.snapshot().text.contains("Reason: secure_comparison_failed"))
        precondition(!report.snapshot().text.contains("secure_payload_invalid"))
        let view = try String(contentsOfFile: "Sources/RestoreView.swift", encoding: .utf8)
        precondition(view.contains("Can't Prepare Rebuild") && view.contains("if let failure = model.failure { Text(failure) }"))
        print("PASS: existing Can't Prepare Rebuild surface and log/report retain startup reason, failed process and Verification Not Run")
    }

    static func prelaunchRequestChecks() throws {
        var rejected = OperationLogRecord(.finish)
        rejected.processLaunched = false; rejected.terminalValid = false; rejected.signalled = false
        rejected.runtimeError = "request_too_large"; rejected.verificationStatus = "not_run"; rejected.detailStatus = "not_run"; rejected.incomplete = true
        precondition(OperationLogSanitizer.valid(rejected) && rejected.failedBeforeLaunch)
        let rows = OperationLogSummaryPresentation.rows(finish: rejected, active: false, records: [rejected])
        precondition(rows.first { $0.id == "process" }?.value == "Failed Before Launch")
        precondition(rows.first { $0.id == "verification" }?.value == "Not Run")
        var legacy = rejected; legacy.processLaunched = nil
        precondition(OperationLogPresentation.outcome(legacy) == "Failed Before Launch")
        legacy.runtimeError = "interrupted"
        precondition(OperationLogPresentation.outcome(legacy) == "Interrupted or Unknown")
        var launched = rejected; launched.processLaunched = true; launched.runtimeError = "incomplete_stream"; launched.exitCode = 2
        precondition(OperationLogSanitizer.valid(launched) && OperationLogPresentation.outcome(launched) == "Interrupted or Unknown")
        var contradiction = launched; contradiction.processLaunched = false
        precondition(!OperationLogSanitizer.valid(contradiction) && !contradiction.failedBeforeLaunch)
        let id = UUID()
        var header = OperationLogRecord(.header); header.storageID = id; header.operation = .secureRestoreCompare; header.operationID = UUID()
        var builder = DiagnosticReportBuilder(id: id, environment: .current(), date: Date())
        builder.receive(header); builder.receive(rejected)
        let report = builder.snapshot().text
        precondition(report.contains("Process Result: Failed Before Launch") && report.contains("Reason: request_too_large"))
        precondition(report.contains("Terminal validity: Not applicable (not launched)") && report.contains("Verification status: not_run"))
        var interruptedBuilder = DiagnosticReportBuilder(id: id, environment: .current(), date: Date())
        interruptedBuilder.receive(header); interruptedBuilder.receive(launched)
        precondition(interruptedBuilder.snapshot().text.contains("Process Result: Unknown"))
        print("PASS: existing log/diagnostic presentation distinguishes encoder rejection, legacy request_too_large, actual launched interruption and contradictory evidence")
    }

    @MainActor static func secureComparisonChecks() async throws {
        let secureID = CoreRestorePreparation.secureDomain
        let selected = CoreRestoreSelection(categories: ["ssh-configuration"], items: ["homebrew-packages": ["first", "second", "matched"]])
        let catalog = CoreRestoreInspection.Inventory(groups: [
            .init(id: "Homebrew", domains: ["homebrew-packages"]), .init(id: "SSH Configuration", domains: ["ssh-configuration"])], inventory: [
                .init(domain: "homebrew-packages", label: "Homebrew Packages", selectionMode: "items", availability: "available", reason: nil,
                    items: ["first", "second", "matched"].map { .init(itemID: $0, label: $0) }),
                .init(domain: "ssh-configuration", label: "SSH Configuration", selectionMode: "category", availability: "available", reason: nil, items: [])])
        let raw: [String: Any] = ["prepared_plan_id": String(repeating: "a", count: 64), "plan_diagnostics": ["bundle": String(repeating: "b", count: 64)],
            "selection": ["categories": selected.categories, "items": selected.items], "selected_groups": ["Homebrew", "SSH Configuration"],
            "selected_categories": selected.categories, "selected_item_counts": ["homebrew-packages": 3],
            "include_secure": true, "secure_restore_status": "selected_pending",
            "plan": [["domain": "homebrew-packages", "item_id": "first", "action": "install", "disposition": "planned"],
                     ["domain": "homebrew-packages", "item_id": "second", "action": "install", "disposition": "planned"],
                     ["domain": "homebrew-packages", "item_id": "matched", "action": "none", "disposition": "satisfied"],
                     ["domain": "ssh-configuration", "item_id": "scope", "action": "restore", "disposition": "planned"],
                     ["domain": secureID, "item_id": CoreRestorePreparation.secureItem, "action": "validate_and_import", "disposition": "pending_unlock", "reason": "secure_unlock_required"]],
            "readiness": ["ready": true, "ready_scope": "environment", "conditions": [["domain": secureID, "code": "secure_bridge_required", "status": "external_action_required", "scope": "execution_launch"]], "reentry": "restore_prepare"],
            "has_planned_changes": true, "has_executable_changes": true, "warning_count": 0, "error_count": 0]
        let unresolved = try JSONDecoder().decode(CoreRestorePreparation.self, from: JSONSerialization.data(withJSONObject: raw))
        let pending = RestoreTaskPresentation(preview: .init(unresolved, catalog: catalog), plan: unresolved)
        precondition(RestorePreviewMetrics.counts(pending.domains).changes == 3 && !unresolved.secureComparedReady)
        precondition(pending.domains.first { $0.id == secureID }!.items.allSatisfy { !$0.item.action.contains("All saved") && !$0.item.action.contains("Some saved") })
        let output = URL(fileURLWithPath: "build/Debug/Stage16HSecureCompare")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        _ = NSApplication.shared
        for decision: CoreSecureComparison.Decision in [.allMatch, .importRequired, .conflict] {
            var plan = unresolved
            let comparison = CoreSecureComparison(decision: decision, targetState: decision == .conflict ? nil : String(repeating: "c", count: 64),
                sourceFingerprint: String(repeating: "b", count: 64), preparedPlanID: plan.preparedPlanID,
                selection: selected, includeSecure: true, comparisonOperationID: "comparison-fixture")
            try comparison.validate(plan: plan, operationID: "comparison-fixture")
            for field in ["prepared_plan_id", "source_fingerprint", "comparison_operation_id", "target_state", "include_secure", "selection"] {
                var invalid = try JSONSerialization.jsonObject(with: JSONEncoder().encode(comparison)) as! [String: Any]
                switch field {
                case "include_secure": invalid[field] = false
                case "selection": invalid[field] = ["categories": [], "items": [:]]
                default: invalid[field] = "invalid"
                }
                do {
                    let decoded = try JSONDecoder().decode(CoreSecureComparison.self, from: JSONSerialization.data(withJSONObject: invalid))
                    try decoded.validate(plan: plan, operationID: "comparison-fixture")
                    preconditionFailure("Malformed comparison binding accepted")
                } catch { }
            }
            plan.secureComparison = comparison
            let tasks = RestoreTaskPresentation(preview: .init(plan, catalog: catalog), plan: plan)
            let counts = RestorePreviewMetrics.counts(tasks.domains)
            precondition(counts.matching == (decision == .allMatch ? 2 : 1))
            precondition(counts.changes == (decision == .importRequired ? 4 : 3))
            precondition(counts.attention == (decision == .conflict ? 1 : 0))
            let secure = tasks.domains.first { $0.id == secureID }!
            let explanation: String
            switch decision {
            case .allMatch: explanation = "All selected SSH identities already match this Mac. Nothing to restore."
            case .importRequired: explanation = "Some selected SSH identities are missing. Rebuild can import them without overwriting existing keys."
            case .conflict: explanation = "An existing SSH identity conflicts with the saved version. No keys will be overwritten."
            }
            precondition(secure.items.count == 1 && secure.items[0].item.title == "Encrypted SSH identity package"
                && secure.items[0].item.action == explanation)
            // Missing destination evidence must never invent the legacy location.
            precondition(!secure.items[0].item.action.contains("~/.ssh"))
            for (scope, location) in [(CoreRestorePreparation.SecureDestinationScope.defaultLocation, "Selected keys will be restored to ~/.ssh."),
                                      (.custom, "Selected keys will be restored to selected locations."),
                                      (.mixed, "Selected keys will use default and custom locations.")] {
                var scoped = plan; scoped.secureDestinationScope = scope
                let scopedTasks = RestoreTaskPresentation(preview: .init(scoped, catalog: catalog), plan: scoped)
                let message = scopedTasks.domains.first { $0.id == secureID }!.items[0].item.action
                let expected = decision == .importRequired ? location + " Existing keys won't be overwritten." : explanation
                precondition(message == expected + (scope == .defaultLocation ? "" : "\nSSH configuration may need updating."))
                precondition(scope == .defaultLocation || !message.contains("~/.ssh"))
                precondition(RestorePreviewMetrics.counts(scopedTasks.domains) == counts)
            }
            precondition(RestorePreviewMetrics.badges(secure).map(\.1) == (decision == .allMatch ? [] : [1]))
            let advanced = RestorePreviewHierarchy.sections(tasks.domains).first { $0.group == .advanced }!
            precondition(advanced.rows.allSatisfy { $0.id != secureID } && RestorePreviewMetrics.counts(advanced.rows).changes == 1)
            let ids = RestorePreviewHierarchy.disclosureIDs(tasks.domains, settings: [])
            for width: CGFloat in [580, 1040] { for dark in [false, true] {
                let host = NSHostingView(rootView: VStack(spacing: 20) {
                    RestorePreviewMetrics(domains: tasks.domains)
                    TaskDomainList(domains: tasks.domains, restoreSettingsPreview: true, restorePreviewHierarchy: true, expansion: .constant(ids))
                }.padding(16).frame(width: width).background(Color(nsColor: .windowBackgroundColor)))
                let window = NSWindow(contentRect: .init(x: 0, y: 0, width: width, height: host.fittingSize.height), styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.contentView = host; host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.orderFront(nil); try? await Task.sleep(for: .milliseconds(60)); host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
                precondition(host.fittingSize.width <= width + 1 && host.fittingSize.height.isFinite)
                let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("\(decision.rawValue)-\(Int(width))-\(dark ? "dark" : "light").png"))
                window.close()
            } }
        }
        let source = try String(contentsOfFile: "Sources/RestoreView.swift")
        precondition(source.contains("[.preparing, .rebuilding].contains(model.state) ? runtime.secureChallenge"))
        precondition(source.contains("secureTransferGroup: secureTransferGroup"))
        print("PASS: authenticated match/import/conflict projection; ordinary counts unchanged, one secure pill, no zero pills, strict binding/incomplete gate")
        print("PASS: existing sibling-group Preview and shared metric components at 580/1040pt Light/Dark (12 renders)")
    }

    static func secureRestoreAvailabilityChecks(_ source: String) {
        precondition(!source.contains("Secure Transfer is not available"))
        let selection = source.components(separatedBy: "private var secureTransferGroup: AnyView?")[1]
            .components(separatedBy: "struct RestorePresentationSection:")[0]
        precondition(selection.contains("guard model.inspection?.secureComponent == true else { return nil }"))
        precondition(selection.contains("model.selectSecureTransfer($0)")
                     && selection.contains(".disabled(model.state != .review || model.runtime.isActive)"))
        precondition(selection.contains("Encrypted SSH keys. Existing keys won't be overwritten."))
        let normalizedSelection = selection.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        precondition(selection.contains("model.identitySelectionSummary") && selection.contains("Text(destinationSummary)"))
        precondition(normalizedSelection.contains("Text(\"Encrypted SSH keys. Existing keys won't be overwritten.\") .font(.callout).foregroundStyle(.secondary)"))
        precondition(selection.contains("summary: model.includeSecure ? model.identitySelectionSummary ?? \"Selected\" : \"Off\""))
        precondition(selection.contains("isExpanded: WorkflowExpansion.binding(CaptureHierarchy.secureTransferID, in: treeExpansion)"))
        precondition(selection.contains("if treeExpansion.wrappedValue.contains(CaptureHierarchy.secureTransferID)"))
        precondition(selection.contains("model.customizeDestinations()") && selection.contains("model.canCustomizeDestinations"))
        precondition(selection.contains("VStack(alignment: .leading, spacing: 6)")
                     && selection.range(of: "Button(\"Customize…\")")!.lowerBound < selection.range(of: "Text(destinationSummary)")!.lowerBound,
                     "Customize must precede its summary in a compact leading-aligned column")
        precondition(selection.contains("if model.secureIdentitySelectionSupported, let inventory = model.destinationInventory")
                     && selection.contains("model.selectIdentity(identity.id, included: $0)"),
                     "Inline keys reuse the authenticated inventory and Customize selection")
        let destinations = source.components(separatedBy: "struct RestoreDestinationsView: View")[1]
        precondition(destinations.contains("panel.canChooseDirectories = true") && destinations.contains("panel.canChooseFiles = false")
                     && destinations.contains("panel.canCreateDirectories = false") && destinations.contains("panel.resolvesAliases = false")
                     && destinations.contains("model.setDestination(nil, for: identity.id)")
                     && destinations.contains("model.selectIdentity(identity.id, included: $0)")
                     && destinations.contains(".disabled(!model.selectedIdentityIDs.contains(identity.id))")
                     && destinations.contains("model.identitySelectionSummary") && !destinations.contains("Toggle("))
        let destinationSummary = destinations.components(separatedBy: "if let summary = model.identitySelectionSummary")[1]
            .components(separatedBy: "ScrollView")[0]
        precondition(destinationSummary.contains("if model.secureIdentitySelectionSupported")
                     && destinationSummary.contains("Button(model.allIdentitiesSelected ? \"Deselect All\" : \"Select All\")")
                     && destinationSummary.contains("model.selectAllIdentities(!model.allIdentitiesSelected)")
                     && destinationSummary.contains(".buttonStyle(.bordered).controlSize(.regular).fontWeight(.medium).fixedSize()")
                     && destinationSummary.range(of: "Button(")!.lowerBound < destinationSummary.range(of: "Text(summary)")!.lowerBound
                     && destinationSummary.contains("Text(summary).font(.callout).foregroundStyle(.secondary)")
                     && !destinationSummary.contains("Spacer()") && !destinationSummary.contains(".buttonStyle(.link)"),
                     "The regular bordered bulk action must lead the secondary counter below the explanation")
        for version in [1, 2] {
            let raw: [String: Any] = ["protocol_version": 1, "product_version": "3.4.0", "operations": ["secure_restore_inventory"],
                "features": ["secure_restore_destinations": ["version": 1, "selection_version": version]]]
            let capability = try! JSONDecoder().decode(CoreCapabilities.self, from: JSONSerialization.data(withJSONObject: raw))
            precondition(capability.supportsSecureRestoreDestinations && capability.supportsSecureRestoreSelection == (version == 2))
            let mapping = CoreRestoreDestinations(version: version, bundleID: String(repeating: "b", count: 64), items: [
                .init(identityID: String(repeating: "a", count: 64), directory: nil, selected: version == 2 ? false : nil)])
            try! mapping.validate()
            let request = CoreRequest(.restorePrepare(path: "/fixture.mbt", disabledGroups: [], includeSecure: true), restoreDestinations: mapping)
            let encoded = String(data: try! request.encoded(), encoding: .utf8)!
            precondition(!encoded.contains("selected") && !encoded.contains(mapping.items[0].identityID))
        }
        precondition(source.contains("Read-only preview — no changes are made."))
        precondition(!source.contains("Custom key locations may differ") && !source.contains("SSH configuration may need updating."))
        print("PASS: Secure Transfer availability, explicit selection, busy guard, no-clobber explanation and read-only Preview")
    }

    @MainActor static func secureRestoreChecks() async throws {
        let secureID = CoreRestorePreparation.secureDomain
        let catalog = CoreRestoreInspection.Inventory(groups: [
            .init(id: "Homebrew", domains: ["homebrew-packages"]), .init(id: "SSH Configuration", domains: ["ssh-configuration"])], inventory: [
                .init(domain: "homebrew-packages", label: "Homebrew Packages", selectionMode: "items", availability: "available", reason: nil,
                    items: ["first", "second", "matched"].map { .init(itemID: $0, label: $0) }),
                .init(domain: "ssh-configuration", label: "SSH Configuration", selectionMode: "category", availability: "available", reason: nil, items: [])])
        let selected = CoreRestoreSelection(categories: ["ssh-configuration"], items: ["homebrew-packages": ["first", "second", "matched"]])
        let ordinaryRows: [[String: Any]] = [
            ["domain": "homebrew-packages", "item_id": "first", "action": "install", "disposition": "planned"],
            ["domain": "homebrew-packages", "item_id": "second", "action": "install", "disposition": "planned"],
            ["domain": "homebrew-packages", "item_id": "matched", "action": "none", "disposition": "satisfied"],
            ["domain": "ssh-configuration", "item_id": "scope", "action": "restore", "disposition": "planned"]]
        func plan(selectedSecure: Bool = true, blocked: Bool = false) throws -> CoreRestorePreparation {
            var rows = ordinaryRows
            var conditions: [[String: Any]] = []
            if selectedSecure {
                rows.append(["domain": secureID, "item_id": CoreRestorePreparation.secureItem, "action": "validate_and_import", "disposition": "pending_unlock", "reason": "secure_unlock_required"])
                conditions.append(["domain": secureID, "code": "secure_bridge_required", "status": "external_action_required", "scope": "execution_launch"])
                if blocked { conditions.append(["domain": secureID, "code": "age_unavailable", "status": "external_action_required", "scope": "operation"]) }
            }
            let raw: [String: Any] = ["prepared_plan_id": String(repeating: "a", count: 64),
                "selection": ["categories": selected.categories, "items": selected.items], "selected_groups": ["Homebrew", "SSH Configuration"],
                "selected_categories": selected.categories, "selected_item_counts": ["homebrew-packages": 3],
                "include_secure": selectedSecure, "secure_restore_status": selectedSecure ? "selected_pending" : "not_selected", "plan": rows,
                "readiness": ["ready": !blocked, "ready_scope": "environment", "conditions": conditions, "reentry": "restore_prepare"],
                "has_planned_changes": true, "has_executable_changes": true, "warning_count": 0, "error_count": 0]
            var result = try JSONDecoder().decode(CoreRestorePreparation.self, from: JSONSerialization.data(withJSONObject: raw))
            if selectedSecure && !blocked {
                result.secureComparison = CoreSecureComparison(decision: .importRequired, targetState: String(repeating: "c", count: 64),
                    sourceFingerprint: String(repeating: "b", count: 64), preparedPlanID: result.preparedPlanID,
                    selection: selected, includeSecure: true, comparisonOperationID: "comparison-fixture")
            }
            return result
        }
        let prepared = try plan(), preview = RestorePreviewPresentation(prepared, catalog: catalog)
        try prepared.validate(expected: selected, catalog: catalog, expectedIncludeSecure: true)
        let tasks = RestoreTaskPresentation(preview: preview, plan: prepared)
        let counts = RestorePreviewMetrics.counts(tasks.domains)
        precondition(counts.changes == 4 && counts.matching == 1 && counts.attention == 0)
        let secure = tasks.domains.first { $0.id == secureID }!
        precondition(RestorePreviewMetrics.badges(secure).map(\.1) == [1])
        let advanced = RestorePreviewHierarchy.sections(tasks.domains).first { $0.group == .advanced }!
        precondition(advanced.rows.allSatisfy { $0.id != secureID } && RestorePreviewMetrics.counts(advanced.rows).changes == 1)
        let blockedPlan = try plan(blocked: true)
        let blockedTasks = RestoreTaskPresentation(preview: .init(blockedPlan, catalog: catalog), plan: blockedPlan)
        precondition(RestorePreviewMetrics.counts(blockedTasks.domains).changes == 3 && RestorePreviewMetrics.counts(blockedTasks.domains).attention == 1)
        precondition(RestorePrerequisiteSummaryPresentation(conditions: prepared.readiness.conditions, ready: true).blockers.isEmpty)
        precondition(RestorePrerequisiteSummaryPresentation(conditions: blockedPlan.readiness.conditions, ready: false).blockers.count == 1)
        let off = try plan(selectedSecure: false)
        let offTasks = RestoreTaskPresentation(preview: .init(off, catalog: catalog), plan: off)
        precondition(offTasks.domains.map(\.id) == tasks.domains.filter { $0.id != secureID }.map(\.id))
        precondition(RestoreExecutionCategories.orderedRows(tasks.domains).map(\.id) == RestoreExecutionCategories.orderedRows(offTasks.domains).map(\.id) + [secureID])
        let ids = RestorePreviewHierarchy.disclosureIDs(tasks.domains, settings: [])
        precondition(ids.contains(secureID) && ids.contains(DeveloperSelectionGroup.ssh.id) && ids.contains(DeveloperSelectionGroup.git.id))
        precondition(WorkflowExpansion.toggled([], available: ids) == ids)

        func event(_ type: String, _ data: [String: Any], sequence: Int = 1) throws -> CoreEvent {
            try CoreEvent(line: JSONSerialization.data(withJSONObject: ["protocol_version": 1, "operation_id": "secure-fixture", "sequence": sequence, "type": type, "data": data]))
        }
        let operation = try event("operation_record", ["domain": secureID, "item_id": CoreRestorePreparation.secureItem, "action": "validate_and_import", "outcome": "success", "reason": "match"])
        let verified = try event("verification_record", ["domain": secureID, "item_id": CoreRestorePreparation.secureItem, "predicate": "identity_set_matches_package", "conformity": "verified", "support": "supported", "observed_at": "2026-11-04T00:00:00Z"], sequence: 2)
        let coverage = try event("coverage_record", ["domain": secureID, "item_id": CoreRestorePreparation.secureItem, "disposition": "resolved", "source_status": "observed_present"], sequence: 3)
        let waiting = try event("secure_challenge_waiting", ["kind": "bundle_unlock", "attempt": 1])
        for evidence in [[], [operation], [verified], [operation, verified], [operation, coverage]] {
            let projected = RestoreTaskPresentation(preview: preview, plan: prepared, events: evidence, executing: true, operationProgress: true)
            let item = projected.domains.first { $0.id == secureID }!.items[0]
            precondition(!RestoreResultDetails.verified(item) && item.state != .completed)
        }
        let receipts = [operation, verified, coverage]
        let completed = RestoreTaskPresentation(preview: preview, plan: prepared, events: receipts + receipts, executing: true, operationProgress: true)
        let resultDomain = completed.domains.first { $0.id == secureID }!
        precondition(RestoreResultDetails.verified(resultDomain.items[0]))
        precondition(RestoreFinalDomain.counts(resultDomain).map(\.1) == [1])
        precondition(RestoreResultSummary(domains: [resultDomain]).issues.isEmpty)
        let progress = RestoreTaskPresentation(preview: preview, plan: prepared, events: [waiting], executing: true, operationProgress: true)
        precondition(progress.domains.first { $0.id == secureID }!.executionStatusTitle == "Awaiting Secure Input")
        let later = try event("phase_started", ["phase": "bootstrap"], sequence: 4)
        let row = RestoreProgressRow.freeze(preview: preview, plan: prepared).first { $0.id == secureID }!
        precondition(row.project(events: receipts + [later]).status == .complete)
        let changed = try event("verification_record", ["domain": secureID, "item_id": "opaque:fixture", "conformity": "mismatch"], sequence: 5)
        precondition(!CoreSecureRestoreEvidence(events: receipts + [changed]).verified)
        var entry = CaptureSecureEntry(passphrase: "disposable input", confirmation: "")
        precondition(entry.valid(for: .bundleUnlock) && !entry.valid(for: .importConfirmation))
        _ = entry.consume(for: .bundleUnlock); precondition(entry.passphrase.isEmpty)

        let source = try String(contentsOfFile: "Sources/RestoreView.swift")
        precondition(!source.contains("Secure Transfer is not available in this build."))
        let selection = source.components(separatedBy: "struct RestoreSelectionContent:")[1].components(separatedBy: "struct RestorePresentationSection:")[0]
        precondition(selection.contains("CaptureGroupedContent(rows: areas") && selection.contains("ordinaryTitle: \"Standard Setup\""))
        precondition(selection.contains("secureTransferGroup: secureTransferGroup") && selection.contains("model.selectSecureTransfer($0)"))
        let dialog = try String(contentsOfFile: "Sources/CaptureView.swift")
        precondition(dialog.contains("runtime.respond(to: challenge, with: .confirmImport)") && dialog.contains("if !confirmingImport {"))
        let groups = try String(contentsOfFile: "Sources/TaskComponents.swift")
        precondition(groups.contains("counts: restorePreviewHierarchy ? [] : RestorePreviewMetrics.badges(domain)"))
        let group = groups.components(separatedBy: "private var previewGroups:")[1].components(separatedBy: "private func previewAccordion")[0]
        let developerRows = DeveloperSelectionGroup.allCases.flatMap { group in tasks.domains.filter { DeveloperSelectionGroup.group(for: $0.id) == group } }
        precondition(developerRows.filter { $0.id == secureID }.count == 1)
        precondition(Set(developerRows.map(\.id)) == Set(tasks.domains.filter { DeveloperSelectionGroup.group(for: $0.id) != nil }.map(\.id)))
        precondition(group.contains("ForEach(developerGroups)") && group.contains("previewMembers(rows, parentState: summary.state)"))
        print("PASS: Secure Restore hierarchy, independent scope, 3+1 planned/green preservation, genuine blocker, zero-pill omission, FD consent reuse, strict receipt projection and one logical Result count")

        _ = NSApplication.shared
        let output = URL(fileURLWithPath: "build/Debug/Stage16HSecureRestore")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for width: CGFloat in [580, 1040] { for dark in [false, true] {
            for phase in ["mixed-preview", "flat-progress"] {
                let content = Group {
                    if phase == "mixed-preview" {
                        VStack(spacing: 20) {
                            RestorePreviewMetrics(domains: tasks.domains)
                            TaskDomainList(domains: tasks.domains, restoreSettingsPreview: true, restorePreviewHierarchy: true, expansion: .constant(ids))
                        }
                    } else { RestoreRebuildProgressContent(tasks: progress, activity: "Preparing secure import…", stopping: false) }
                }.padding(16).frame(width: width).background(Color(nsColor: .windowBackgroundColor))
                let host = NSHostingView(rootView: content)
                let window = NSWindow(contentRect: .init(x: 0, y: 0, width: width, height: host.fittingSize.height), styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.contentView = host; host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.orderFront(nil); try? await Task.sleep(for: .milliseconds(60)); host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
                precondition(host.fittingSize.width <= width + 1 && host.fittingSize.height.isFinite)
                let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("\(phase)-\(Int(width))-\(dark ? "dark" : "light").png"))
                window.close()
            }
        } }
        print("PASS: Existing Preview/count-pill and flat Progress components render at 580/1040pt Light/Dark")
    }
    @MainActor static func captureDisclosureChecks() throws {
        let ids = ["homebrew-packages", "macos-finder", "vscode-extensions", "vscode-settings",
                   "git-configuration", "ssh-configuration", CaptureHierarchy.secureTransferID]
        let ordinary = CaptureHierarchy.disclosureIDs(ids, scope: .ordinary)
        let experienced = CaptureHierarchy.disclosureIDs(ids, scope: .advanced)
        precondition(ordinary.isDisjoint(with: experienced))
        precondition(ordinary.isSuperset(of: ["macos-settings", "macos-finder", CaptureHierarchy.sectionID(.vscode), CaptureHierarchy.Group.vscode.id, "vscode-extensions"]))
        precondition(experienced == [DeveloperSelectionGroup.git.id, "git-configuration", "ssh-configuration", CaptureHierarchy.sshID, CaptureHierarchy.secureTransferID])
        for scope in [ordinary, experienced] {
            let other = scope == ordinary ? experienced : ordinary
            let all = CaptureHierarchy.toggled(other, ids: scope)
            precondition(WorkflowExpansion.allExpanded(all, available: scope))
            precondition(CaptureHierarchy.toggled(all, ids: scope) == other)
            for id in scope {
                let mixed = all.subtracting([id])
                precondition(!WorkflowExpansion.allExpanded(mixed, available: scope))
                precondition(CaptureHierarchy.toggled(mixed, ids: scope) == all)
            }
        }
        precondition(CaptureHierarchy.disclosureIDs([CaptureHierarchy.secureTransferID], scope: .ordinary).isEmpty)
        precondition(CaptureHierarchy.disclosureIDs([CaptureHierarchy.secureTransferID], scope: .advanced) == [CaptureHierarchy.sshID, CaptureHierarchy.secureTransferID])
        let presentation = try String(contentsOfFile: "Sources/CapturePresentation.swift")
        let grouping = presentation.components(separatedBy: "struct CaptureGroupedContent<")[1].components(separatedBy: "struct CaptureTaskPresentation")[0]
        precondition(grouping.contains("DisclosureGroup(isExpanded: experiencedVisibility)")
            && grouping.contains(".disclosureGroupStyle(HeaderDisclosureStyle())") && !grouping.contains("Toggle("))
        precondition(grouping.contains("if experiencedVisibility?.wrappedValue != false, let advancedControls"),
            "Experienced Expand All is available only while the container is expanded")
        precondition(grouping.components(separatedBy: "WorkspaceCardSurface()").count - 1 == 2,
                     "Exactly one ordinary and one experienced surface, with no per-sibling card")
        precondition(CaptureHierarchy.sshID != CaptureHierarchy.secureTransferID)
        precondition(!WorkspacePresentationTaxonomy.Group.advanced.domains.contains(CaptureHierarchy.sshID))
        precondition(grouping.components(separatedBy: "CaptureGroupHeader(title: group.title").count - 1 == 1)
        let view = try String(contentsOfFile: "Sources/CaptureView.swift")
        let review = view.components(separatedBy: "case .review:")[1].components(separatedBy: "case .confirmation:")[0]
        let reviewHeading = review.components(separatedBy: "WorkflowList {")[0]
        precondition(reviewHeading.contains("Text(\"Review and select\").font(.headline)") && !reviewHeading.contains("Button("))
        precondition(review.components(separatedBy: "Review and select").count - 1 == 1)
        precondition(review.contains("ordinaryTitle: \"Standard Setup\"") && review.components(separatedBy: "CaptureExpandButton(").count - 1 == 2)
        let tasks = try String(contentsOfFile: "Sources/TaskComponents.swift")
        let confirmationHeading = tasks.components(separatedBy: "if captureHierarchy {")[1].components(separatedBy: "} else if !restorePreviewHierarchy {")[0]
        precondition(confirmationHeading.contains("Text(title).font(.headline)") && !confirmationHeading.contains("Button")
            && !confirmationHeading.contains("WorkflowList"))
        let confirmation = view.components(separatedBy: "case .confirmation:")[1].components(separatedBy: "case .result:")[0]
        precondition(confirmation.contains("Text(\"Save this environment?\")")
            && confirmation.components(separatedBy: "title: \"Included in this capture\"").count - 1 == 1)
        let confirmationGroups = tasks.components(separatedBy: "} else if captureHierarchy {")[1].components(separatedBy: "} else {")[0]
        for content in [review, confirmationGroups] {
            precondition(content.components(separatedBy: "ordinaryTitle: \"Standard Setup\"").count - 1 == 1)
            precondition(content.components(separatedBy: "CaptureExpandButton(").count - 1 == 2)
            precondition(content.contains("title: \"Standard Setup\"") && content.contains("title: \"For Experienced Users\""))
        }
        precondition(grouping.components(separatedBy: "WorkspaceSectionHeader(title: \"For Experienced Users\")").count - 1 == 1)
        precondition(grouping.contains("if !ordinary.isEmpty {") && grouping.contains("if !advanced.isEmpty || hasSSH {"))
        print("PASS: Plain Capture workflow headings, Standard Setup/For Experienced Users labels, exactly two scoped controls, empty-section omission and shared surfaces")
    }

    @MainActor static func secureSelectionChecks() async throws {
        _ = NSApplication.shared
        // Keep ownership of every native fixture window through the last assertion.
        var windows: [NSWindow] = []
        defer { windows.forEach { $0.close() } }
        func descendants<T: NSView>(_ view: NSView, _: T.Type) -> [T] {
            (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, T.self) }
        }
        func host<V: View>(_ content: V, width: CGFloat) -> (NSHostingView<some View>, NSWindow) {
            let view = NSHostingView(rootView: content.frame(width: width).background(Color(nsColor: .windowBackgroundColor)))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
            windows.append(window)
            window.isReleasedWhenClosed = false; window.contentView = view; window.orderFront(nil)
            return (view, window)
        }
        func settle(_ view: NSView) async {
            try? await Task.sleep(for: .milliseconds(40))
            view.setFrameSize(view.fittingSize); view.layoutSubtreeIfNeeded()
        }
        func boxes(_ view: NSView) -> [NSButton] {
            descendants(view, NSButton.self).filter { $0.target is NativeSelectionCheckbox.Coordinator }
        }
        func activate(_ button: NSButton) {
            // performClick spins an animated tracking loop that can stop the
            // async main run loop. Dispatch the same native target/action directly.
            precondition(button.isEnabled && NSApp.sendAction(button.action!, to: button.target, from: button))
        }
        let identities: [CoreCaptureSecureInventory.Identity] = (0..<2).map { index in
            let id = String(repeating: index == 0 ? "a" : "b", count: 64)
            let label = index == 0 ? "fixture_key" : "fixture_" + String(repeating: "W", count: 72)
            let fingerprint = "SHA256:" + Data(repeating: UInt8(index + 1), count: 32).base64EncodedString().replacingOccurrences(of: "=", with: "")
            return CoreCaptureSecureInventory.Identity(itemID: id, label: label, keyType: "ssh-ed25519",
                fingerprint: fingerprint, validation: "candidate_requires_pair_validation")
        }
        let inventory = CoreCaptureSecureInventory(status: "present", reason: nil, items: identities)
        try inventory.validate()
        let output = URL(fileURLWithPath: "build/Debug/SSHUnifiedSelection")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (width, dark): (CGFloat, Bool) in [(580, false), (1040, false), (580, true), (1040, true)] {
            // Compare actual shared-row rendering with a checkbox versus its
            // empty column, using the same symbol to measure the column itself.
            func iconBounds(_ header: CaptureGroupHeader) -> CGRect {
                let renderer = ImageRenderer(content: header.frame(width: width).environment(\.colorScheme, dark ? .dark : .light))
                let bitmap = NSBitmapImageRep(cgImage: renderer.cgImage!)
                var pixels: [CGPoint] = []
                for x in 0..<Int(width / 2) { for y in 0..<bitmap.pixelsHigh {
                    let color = bitmap.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
                    if color.alphaComponent > 0.9 && color.blueComponent > 0.4
                        && color.blueComponent > color.redComponent * 1.4 && color.blueComponent > color.greenComponent * 1.1 {
                        pixels.append(CGPoint(x: x, y: y))
                    }
                } }
                precondition(!pixels.isEmpty)
                return CGRect(x: pixels.map(\.x).min()!, y: pixels.map(\.y).min()!,
                    width: pixels.map(\.x).max()! - pixels.map(\.x).min()!, height: pixels.map(\.y).max()! - pixels.map(\.y).min()!)
            }
            let selectedHeader = CaptureGroupHeader(title: "Git", symbol: "key",
                selection: AnyView(NativeSelectionCheckbox("", isOn: .constant(false))), expanded: .constant(false))
            let emptyHeader = CaptureGroupHeader(title: "SSH", symbol: "key", reservesSelectionColumn: true, expanded: .constant(false))
            precondition(iconBounds(selectedHeader) == iconBounds(emptyHeader), "SSH reserves the exact group checkbox column")
            let state = SecureSelectionFixture()
            let (view, window) = host(SecureSelectionFixtureView(state: state, inventory: inventory), width: width)
            view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            await settle(view)
            precondition(boxes(view).count == 1 && state.selected.isEmpty && !state.advancedSelected)
            state.groupsExpanded = [DeveloperSelectionGroup.git.id, CaptureHierarchy.sshID]
            await settle(view)
            let collapsedHeight = view.fittingSize.height
            func master() -> NSButton { boxes(view).first { $0.accessibilityLabel() == "Select SSH Keys" }! }
            func advancedMaster() -> NSButton { boxes(view).first { $0.accessibilityLabel() == "Select Git" }! }
            precondition(boxes(view).count == 2 && master().state == .off && state.selected.isEmpty && !state.advancedSelected)
            let advancedFrame = advancedMaster().convert(advancedMaster().bounds, to: view)
            let secureFrame = master().convert(master().bounds, to: view)
            precondition(abs(secureFrame.minX - advancedFrame.minX - CaptureReviewPresentation.hierarchyStep) < 1
                         && secureFrame.minY > advancedFrame.minY + 96,
                         "SSH Keys is a category under the sibling SSH group; SSH adds no master checkbox")
            activate(master()); await settle(view)
            precondition(master().state == .on && state.selected.count == 2 && !state.expanded && !state.advancedSelected)
            func clickDisclosure(_ checkbox: NSButton) {
                let row = checkbox.convert(checkbox.bounds, to: view)
                let x: CGFloat = checkbox.accessibilityLabel() == "Select SSH Keys" ? width - 22 : 22
                let point = view.convert(NSPoint(x: x, y: row.midY), to: nil)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
                    NSApp.sendEvent(event)
                }
            }
            clickDisclosure(master())
            await settle(view)
            precondition(state.expanded && state.selected.count == 2 && boxes(view).count == 4)
            clickDisclosure(advancedMaster()); await settle(view)
            precondition(state.expanded && !state.groupsExpanded.contains(DeveloperSelectionGroup.git.id) && state.selected.count == 2 && boxes(view).count == 4)
            activate(advancedMaster()); await settle(view)
            precondition(state.advancedSelected && state.selected.count == 2)
            clickDisclosure(advancedMaster()); await settle(view)
            precondition(state.expanded && state.groupsExpanded.contains(DeveloperSelectionGroup.git.id) && boxes(view).count == 4)
            func item(_ index: Int) -> NSButton { boxes(view).first { $0.accessibilityLabel() == "Include SSH identity " + identities[index].label }! }
            activate(item(0)); await settle(view)
            precondition(master().state == .mixed && state.selected == [identities[1].id] && state.expanded)
            activate(master()); await settle(view)
            precondition(master().state == .on && state.selected.count == 2)
            activate(master()); await settle(view)
            precondition(master().state == .off && state.selected.isEmpty && state.advancedSelected)
            activate(item(0)); await settle(view)
            precondition(master().state == .mixed)
            activate(item(1)); await settle(view)
            precondition(master().state == .on)
            let (itemReference, itemWindow) = host(CaptureItemSelectionRow(title: "Fixture item", included: .constant(false))
                .padding(.leading, 16 + CaptureChildRowGrid.leadingInset + CaptureReviewPresentation.hierarchyStep * 2).padding(.trailing, 16), width: width)
            await settle(itemReference)
            let expectedItemX = boxes(itemReference)[0].convert(boxes(itemReference)[0].bounds, to: itemReference).minX
            for index in 0..<2 {
                let checkbox = item(index)
                precondition(abs(checkbox.convert(checkbox.bounds, to: view).minX - expectedItemX) < 1, "Identity checkbox uses the normal nested-item column")
                precondition(checkbox.accessibilityLabel() == "Include SSH identity " + identities[index].label)
            }
            itemWindow.orderOut(nil)
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let scale = CGFloat(bitmap.pixelsWide) / view.bounds.width
            let background = bitmap.colorAt(x: 0, y: 0)!.usingColorSpace(.sRGB)!
            let first = item(0).convert(item(0).bounds, to: view)
            let startX = Int(ceil(first.maxX * scale))
            let nameStart = (startX..<min(bitmap.pixelsWide, startX + Int(40 * scale))).first { x in
                (Int(first.minY * scale)..<Int(first.maxY * scale)).contains { y in
                    let color = bitmap.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
                    return abs(color.redComponent - background.redComponent) > 0.2
                }
            }
            precondition(nameStart != nil && CGFloat(nameStart! - startX) / scale <= 12, "Rendered name must be close to its checkbox")
            precondition(abs(view.fittingSize.width - width) < 1, "Long names/fingerprints must wrap within the available width")
            try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("selection-\(Int(width))-\(dark ? "dark" : "light").png"))
            clickDisclosure(master()); await settle(view)
            precondition(!state.expanded && state.selected.count == 2 && boxes(view).count == 2 && view.fittingSize.height == collapsedHeight)
            print("PASS: Git / SSH children, independent native selection/disclosure, preserved tri-state and identity geometry at \(Int(width))pt \(dark ? "Dark" : "Light")")
            window.orderOut(nil)
        }
        let source = try String(contentsOfFile: "Sources/CapturePresentation.swift")
        let secureSource = source.components(separatedBy: "struct CaptureSecureTransferView:")[1].components(separatedBy: "extension SelectionState")[0]
        precondition(secureSource.contains(".disclosureGroupStyle(SelectionCategoryDisclosureStyle())") && !secureSource.contains("Toggle("), "One native Secure Transfer selection control, independent from help and disclosure")
        let groupedSource = source.components(separatedBy: "struct CaptureGroupedContent<")[1].components(separatedBy: "struct CaptureTaskPresentation")[0]
        precondition(groupedSource.contains("selection.group.") && groupedSource.contains("if group == .ssh, let secureTransferGroup"))
        precondition(!groupedSource.contains("capture.container.secure-transfer"), "No duplicate Secure Transfer surface")
        let secureDomain = TaskDomainPresentation(id: CaptureHierarchy.secureTransferID, title: "Secure Transfer", symbol: "lock.shield",
            items: [TaskItemPresentation(id: identities[0].id, item: DisplayItem(id: identities[0].id, title: identities[0].label, status: .ready,
                action: "The SSH key pair will be validated and encrypted during saving."), state: .planned)])
        for domains in [[secureDomain], [TaskDomainPresentation(id: "ssh-configuration", title: "SSH Configuration", symbol: "key", items: []), secureDomain]] {
            let (view, window) = host(TaskDomainList(domains: domains, stateTitles: [.planned: "Ready to Save"], compactReadyItems: true,
                captureHierarchy: true, expansion: .constant([CaptureHierarchy.sshID, CaptureHierarchy.secureTransferID])), width: 580)
            await settle(view)
            precondition(boxes(view).isEmpty && view.fittingSize.height > 96, "Secure-only and mixed Confirmation keep prepared items read-only and reachable")
            window.orderOut(nil)
        }
        let metricsSource = source.components(separatedBy: "struct CaptureReviewMetrics:")[1].components(separatedBy: "struct CaptureConfirmationContents")[0]
        let domainPosition = metricsSource.range(of: "if summary.domainCount > 0 {")!.lowerBound
        let securePosition = metricsSource.range(of: "if summary.secureIdentityCount > 0 {")!.lowerBound
        let attentionPosition = metricsSource.range(of: "if summary.attentionCount > 0 {")!.lowerBound
        precondition(domainPosition < securePosition && securePosition < attentionPosition)
        for width: CGFloat in [580, 1040] {
            for (secure, attention) in [(0, 0), (2, 0), (0, 1), (2, 1)] {
                let summary = CaptureSummaryPresentation(domainCount: 3, itemCount: 8, attentionCount: attention, unsupportedCount: 0, secureIdentityCount: secure)
                let (view, window) = host(CaptureReviewMetrics(summary: summary), width: width)
                await settle(view)
                precondition(view.fittingSize.height == (width == 580 && secure > 0 && attention > 0 ? 260 : 80),
                             "Conditional metrics retain the existing responsive layout")
                if secure > 0 && attention > 0 {
                    let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("metrics-\(Int(width)).png"))
                }
                window.orderOut(nil)
            }
        }
        print("PASS: Selected Domains → selected SSH identities → genuine Needs Attention; conditional visibility and responsive order")
    }

    @MainActor static func secureCaptureChecks() async throws {
        _ = NSApplication.shared
        var input = CaptureSecureEntry()
        precondition(!input.valid(for: .bundleEncrypt) && !input.valid(for: .sshKeyUnlock))
        input.passphrase = "disposable presentation input"
        precondition(input.valid(for: .sshKeyUnlock) && !input.valid(for: .bundleEncrypt))
        input.confirmation = input.passphrase
        precondition(input.valid(for: .bundleEncrypt) && !input.valid(for: .bundleUnlock) && !input.valid(for: .importConfirmation))
        guard case .secret(let bytes) = input.consume(for: .bundleEncrypt) else { preconditionFailure("Missing response") }
        precondition(bytes == Data("disposable presentation input".utf8) && input.passphrase.isEmpty && input.confirmation.isEmpty)
        for invalid in ["", "line\nbreak", "tab\tvalue", "nul\0value", String(repeating: "é", count: 65)] {
            input.passphrase = invalid; input.confirmation = invalid
            precondition(!input.valid(for: .bundleEncrypt) && input.consume(for: .bundleEncrypt) == nil)
            input.clear(); precondition(input.passphrase.isEmpty && input.confirmation.isEmpty)
        }
        input.passphrase = String(repeating: "é", count: 64); input.confirmation = input.passphrase
        precondition(input.valid(for: .bundleEncrypt))
        input.clear()
        func descendants<T: NSView>(_ view: NSView, _: T.Type) -> [T] {
            (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, T.self) }
        }
        let runtime = CoreRuntime(operationLogs: nil)
        for kind in [CoreSecureChallenge.Kind.bundleEncrypt, .sshKeyUnlock] {
            let challenge = CoreSecureChallenge(operationID: UUID().uuidString, challengeID: UUID().uuidString.replacingOccurrences(of: "-", with: ""), kind: kind, attempt: 2)
            let host = NSHostingView(rootView: CaptureSecureInputView(runtime: runtime, challenge: challenge))
            host.setFrameSize(host.fittingSize); host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
            host.layoutSubtreeIfNeeded()
            let fields = descendants(host, NSTextField.self).filter { $0.isEditable }
            precondition(fields.count == (kind == .bundleEncrypt ? 2 : 1) && fields.allSatisfy { $0 is NSSecureTextField },
                         "All native secret inputs must be secure fields")
        }
        let identity = CoreCaptureSecureInventory.Identity(itemID: String(repeating: "a", count: 64), label: "fixture_key", keyType: "ssh-ed25519",
            fingerprint: "SHA256:" + Data(repeating: 1, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: ""), validation: "candidate_requires_pair_validation")
        let inventory = CoreCaptureSecureInventory(status: "present", reason: nil, items: [identity])
        try inventory.validate()
        var selection: (String, Bool)?
        let host = NSHostingView(rootView: CaptureSecureTransferView(inventory: inventory, editable: true,
            select: { selection = ($0, $1) }, expansion: .constant(true)).frame(width: 900))
        host.setFrameSize(host.fittingSize); host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        host.layoutSubtreeIfNeeded()
        let checkboxes = descendants(host, NSButton.self).filter { $0.target is NativeSelectionCheckbox.Coordinator }
        precondition(checkboxes.count == 2 && checkboxes.allSatisfy { $0.state == .off } && selection == nil,
                     "Secure Transfer master and identity must default off; controls: \(checkboxes.count)")
        checkboxes.first { $0.accessibilityLabel() == "Include SSH identity " + identity.label }!.performClick(nil)
        precondition(selection?.0 == identity.id && selection?.1 == true)
        precondition(CaptureHierarchy.group(for: CaptureHierarchy.secureTransferID) != .advanced)
        let source = try String(contentsOfFile: "Sources/CaptureView.swift")
        precondition(source.contains("secureTransferGroup: AnyView(CaptureSecureTransferView(inventory: model.secureInventory")
            && source.contains(".id(challenge.id)") && source.contains(".interactiveDismissDisabled()")
            && source.contains(".onChange(of: runtime.secureChallenge)")
            && source.contains(".onDisappear { entry.clear(); runtime.cancelSecureChallenge(challenge) }"))
        print("PASS: Native secure fields, confirmation/UTF-8 limits, transient input clearing, explicit default-off identity checkbox and developer group placement")
    }

    @MainActor static func homebrewSetupChecks() async {
        _ = NSApplication.shared
        let suite = "org.macseed.homebrew-test.presentation." + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        var observation = HomebrewObservation.absent, pauseResolve = true
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("macseed-homebrew-layout-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: staging) }
        let model = HomebrewSetupModel(host: .init(architecture: .appleSilicon, majorVersion: 27, version: "27.2"),
            preferences: preferences, detect: { observation }, packageService: .init(resolve: {
                while pauseResolve { try await Task.sleep(nanoseconds: 10_000_000) }
                return HomebrewDownloadPlan(releaseID: 1, version: "1.2.3", assetID: 1,
                    url: URL(string: "https://github.com/Homebrew/brew/releases/download/1.2.3/Homebrew.pkg")!,
                    sha256: String(repeating: "0", count: 64), size: 1)
            }, download: { _, file, _ in try Data([0]).write(to: file, options: .withoutOverwriting) },
            verify: { _, _ in try await Task.sleep(nanoseconds: 60_000_000_000) },
            openInstaller: { _ in preconditionFailure("No Installer launch in layout test") }), packageStagingBase: staging)
        await model.prepareLaunch()
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            pauseResolve = true
            let host = NSHostingView(rootView: HomebrewSetupView(model: model, notNow: {})
                .background(Color(nsColor: .windowBackgroundColor)))
            host.appearance = NSAppearance(named: appearance)
            func size() async -> NSSize {
                try! await Task.sleep(nanoseconds: 50_000_000)
                host.layoutSubtreeIfNeeded()
                return host.fittingSize
            }
            model.beginSetup()
            let initial = await size()
            precondition((650...750).contains(initial.width) && initial.height < 400, "Compact initial setup")
            model.selectMethod(.terminal)
            let terminal = await size()
            precondition(terminal.width == initial.width && terminal.height > initial.height && terminal.height < 550)
            model.installPackage()
            let package = await size()
            precondition(package.width == initial.width && package.height > initial.height && package.height < 550,
                         "Resolving/cancellation controls must fit the compact setup width and height")
            model.cancelPackageDownload(); await model.waitForPackageDownload()
            pauseResolve = false
            model.installPackage()
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            while model.packageState != .verifying {
                precondition(ProcessInfo.processInfo.systemUptime < deadline, "Verification did not start")
                try! await Task.sleep(nanoseconds: 10_000_000)
            }
            let verification = await size()
            precondition(verification.width == initial.width && verification.height < 550)
            let output = URL(fileURLWithPath: "build/Debug/HomebrewStartup", isDirectory: true)
            try! FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            host.setFrameSize(verification); host.layoutSubtreeIfNeeded()
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let appearanceName = appearance == .aqua ? "light" : "dark"
            try! bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("safety-verifying-" + appearanceName + ".png"))
            model.cancelPackageDownload(); await model.waitForPackageDownload()
            precondition(model.packageState == .cancelled)
            model.beginSetup()
            let reopened = await size()
            precondition(reopened == initial, "Reopening starts compact")
            observation = .usable; await model.check()
            let available = await size()
            precondition(available.width == initial.width && available.height < initial.height)
            let settings = NSHostingView(rootView: FoundationGeneralSettings(showAbout: {}).frame(width: 440))
            settings.appearance = NSAppearance(named: appearance)
            precondition(settings.fittingSize.width == 440, "Preserve approved Settings width")
            observation = .absent; await model.check()
        }
        print("PASS: compact Homebrew layout in Light/Dark; Terminal expands; Installer replaces it; reopen contracts; Available is compact; Settings retains width")
    }

    @MainActor static func sidebarLayoutChecks() async {
        _ = NSApplication.shared
        func splitController(in view: NSView) -> NSSplitViewController? {
            if let split = view as? NSSplitView, let controller = split.delegate as? NSSplitViewController {
                return controller
            }
            return view.subviews.lazy.compactMap { splitController(in: $0) }.first
        }
        func navigationList(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            return view.subviews.lazy.compactMap { navigationList(in: $0) }.first
        }
        func settle(_ window: NSWindow) async {
            window.contentView?.layoutSubtreeIfNeeded()
            try! await Task.sleep(nanoseconds: 80_000_000)
            window.contentView?.layoutSubtreeIfNeeded()
        }
        func detailWidth(_ split: NSSplitViewController) -> CGFloat {
            let detail = split.splitViewItems.last!.viewController.view
            // On macOS 26 the native floating sidebar occupies a safe-area inset
            // rather than reducing the full-bleed detail view's frame.
            return detail.bounds.width - detail.safeAreaInsets.left - detail.safeAreaInsets.right
        }
        func check<V: View>(_ view: V, name: String, tasks: [ProductTask?], navigate: (ProductTask?, NSView) -> Void) async {
            let host = NSHostingController(rootView: view.frame(minWidth: MainWindowPolicy.minimum.width,
                                                               minHeight: MainWindowPolicy.minimum.height))
            host.sizingOptions = []
            let window = NSWindow(contentViewController: host)
            window.isReleasedWhenClosed = false
            MainWindowPolicy.apply(to: window)
            window.setContentSize(NSSize(width: 1600, height: 800))
            window.orderFront(nil)
            defer { window.close() }
            await settle(window)
            guard let split = splitController(in: host.view), let sidebar = split.splitViewItems.first else {
                preconditionFailure("Missing native sidebar in \(name)")
            }
            func waitForLayout(_ transition: String, task: ProductTask?, before: CGFloat, until ready: () -> Bool) async {
                let deadline = ProcessInfo.processInfo.systemUptime + 5
                repeat {
                    window.contentView?.layoutSubtreeIfNeeded()
                    if ready() { return }
                    // toggleSidebar animates. A nested RunLoop.run cannot release
                    // the main actor when this fixture resumes after an await.
                    try! await Task.sleep(nanoseconds: 10_000_000)
                } while ProcessInfo.processInfo.systemUptime < deadline
                let detail = split.splitViewItems.last!.viewController.view
                preconditionFailure("Sidebar \(transition) did not converge within 5s: \(name), \(String(describing: task)), "
                    + "collapsed=\(sidebar.isCollapsed), sidebarWidth=\(sidebar.viewController.view.frame.width), "
                    + "before=\(before), after=\(detailWidth(split)), bounds=\(detail.bounds), insets=\(detail.safeAreaInsets), "
                    + "windowContent=\(host.view.bounds.size), isVisible=\(window.isVisible), occlusionState=\(window.occlusionState.rawValue)")
            }
            for task in tasks {
                navigate(task, host.view)
                for width in [1600.0, 1200, 1000, 1200, 1600, 1000] {
                    window.setContentSize(NSSize(width: width, height: 800))
                    await settle(window)
                    let thickness = sidebar.viewController.view.frame.width
                    precondition(abs(host.view.bounds.width - width) < 1)
                    precondition(!sidebar.isCollapsed && abs(thickness - 215) < 1,
                                 "Visible sidebar must stay 215pt wide during resize")
                    precondition(!sidebar.viewController.view.isHiddenOrHasHiddenAncestor)
                    precondition(sidebar.viewController.view.visibleRect.width >= 214)
                    precondition(!sidebar.canCollapseFromWindowResize)
                    precondition(detailWidth(split) > width - 240, "Detail must retain the remaining width")
                }
                let visibleDetailWidth = detailWidth(split)
                let visibleBounds = split.splitViewItems.last!.viewController.view.bounds
                let visibleInsets = split.splitViewItems.last!.viewController.view.safeAreaInsets
                let selectedRows = navigationList(in: sidebar.viewController.view)?.selectedRowIndexes
                split.toggleSidebar(nil)
                await waitForLayout("collapse", task: task, before: visibleDetailWidth) {
                    sidebar.isCollapsed && detailWidth(split) > visibleDetailWidth + 200
                        && abs(detailWidth(split) - host.view.bounds.width) < 1
                }
                precondition(sidebar.isCollapsed, "Existing sidebar toggle must hide the sidebar")
                precondition(detailWidth(split) > visibleDetailWidth + 200,
                    "Hidden sidebar must release its width to detail: \(name), \(String(describing: task)), "
                    + "before=\(visibleDetailWidth), bounds=\(visibleBounds), insets=\(visibleInsets), "
                    + "after=\(detailWidth(split)), bounds=\(split.splitViewItems.last!.viewController.view.bounds), "
                    + "insets=\(split.splitViewItems.last!.viewController.view.safeAreaInsets), "
                    + "windowContent=\(host.view.bounds.size), isVisible=\(window.isVisible), "
                    + "occlusionState=\(window.occlusionState.rawValue). "
                    + "Run this native geometry gate in an unlocked macOS GUI session; a locked session can suspend sidebar layout.")
                for width in [1600.0, 1200, 1000] {
                    window.setContentSize(NSSize(width: width, height: 800))
                    await settle(window)
                    precondition(sidebar.isCollapsed, "Resize must preserve explicit hidden state")
                }
                split.toggleSidebar(nil)
                await waitForLayout("expansion", task: task, before: visibleDetailWidth) {
                    !sidebar.isCollapsed && abs(sidebar.viewController.view.frame.width - 215) < 1
                        && !sidebar.viewController.view.isHiddenOrHasHiddenAncestor
                        && sidebar.viewController.view.visibleRect.width >= 214
                        && abs(detailWidth(split) - visibleDetailWidth) < 1
                }
                precondition(!sidebar.isCollapsed && abs(sidebar.viewController.view.frame.width - 215) < 1,
                             "Existing toggle must restore the normal sidebar width")
                precondition(abs(detailWidth(split) - visibleDetailWidth) < 1,
                             "Expanded sidebar must restore the original effective detail width")
                precondition(!sidebar.viewController.view.isHiddenOrHasHiddenAncestor)
                precondition(sidebar.viewController.view.visibleRect.width >= 214)
                precondition(navigationList(in: sidebar.viewController.view)?.selectedRowIndexes == selectedRows,
                             "Resize and toggle must preserve navigation selection")
            }
            print("PASS: \(name) sidebar resize/toggle at 1600/1200/1000pt across \(tasks.count) navigation destinations")
        }
        let tasks = [nil] + ProductTask.allCases.map(Optional.some)
        #if DEBUG
        let session = DemoSession()
        await check(DemoWorkspace(session: session), name: "preview", tasks: tasks) { task, _ in session.navigate(task) }
        #endif
        // No Core launch or local operation-log writes in this native layout fixture.
        let runtime = CoreRuntime(resolver: CoreLocationResolver(resources: nil), operationLogs: nil)
        await check(ProductionWorkspace(runtime: runtime), name: "production", tasks: tasks) { task, view in
            guard let table = navigationList(in: view) else { preconditionFailure("Missing native navigation list") }
            let row = task.map { ProductTask.allCases.firstIndex(of: $0)! + 2 } ?? 1
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            precondition(table.selectedRow == row)
        }
        precondition(!runtime.isActive && runtime.events.isEmpty)
        print("PASS: Native sidebar stays fixed at 1600/1200/1000pt; toggle hides/restores it and expands detail")
    }

    @MainActor static func captureResultActionsChecks() {
        let source = try! String(contentsOfFile: "Sources/CaptureView.swift")
        let failure = source.components(separatedBy: "            case .failed, .cancelled:")[1]
        precondition(failure.contains("if model.savingAttempted {") && failure.contains("switch model.publicationEvidence"))
        precondition(failure.range(of: "if model.savingAttempted {")!.lowerBound < failure.range(of: "switch model.publicationEvidence")!.lowerBound)
        precondition(source.contains("if model.canReviewSelection {") && source.contains("Button(\"Review Selection\") { model.editSelection() }"))
        let result = source.components(separatedBy: "            case .result:")[1]
            .components(separatedBy: "            case .failed, .cancelled:")[0]
        precondition(result.contains("model.resultPresentation") && result.contains("CaptureResultContent(result: result)"))
        let presentation = try! String(contentsOfFile: "Sources/CapturePresentation.swift")
        let content = presentation.components(separatedBy: "struct CaptureResultContent: View {")[1].components(separatedBy: "// Wording only;")[0]
        precondition(content.contains("CaptureBundleLocationView(destination: result.destination, showsReveal: true)"))
        let outcomes = presentation.components(separatedBy: "struct CaptureResultOutcomes: View {")[1].components(separatedBy: "struct CaptureResultContent:")[0]
        precondition(outcomes.components(separatedBy: "CaptureOutcomeCard(title: \"Save Complete\"").count == 2)
        precondition(outcomes.contains("if !result.attention.isEmpty") && outcomes.contains("detail: result.attentionSummary"))
        precondition(!content.contains("Needs Attention") && !content.contains("result.scope") && !content.contains("result.message"))
        for obsolete in ["Environment Saved", "Captured Environment", "Domains Saved", "Items Saved", "TaskDomainList", "DisclosureGroup", "Completed"] {
            precondition(!result.contains(obsolete) && !content.contains(obsolete), "Compact Result must not recreate the saved inventory or competing outcomes")
        }
        let location = source.components(separatedBy: "struct CaptureBundleLocationView: View {")[1]
            .components(separatedBy: "struct CaptureActionsView: View {")[0]
        precondition(location.contains("HStack {") && location.contains("if showsReveal {"))
        precondition(location.range(of: "Text(destination.path)")!.lowerBound < location.range(of: "Button(\"Reveal in Finder\")")!.lowerBound)
        precondition(location.contains("activateFileViewerSelecting([destination])"))
        let actions = source.components(separatedBy: "struct CaptureActionsView: View {")[1]
        let footer = actions.components(separatedBy: "            case .result:")[1]
            .components(separatedBy: "            case .failed, .cancelled:")[0]
        precondition(!footer.contains("Reveal in Finder"))
        precondition(footer.range(of: "Spacer()")!.lowerBound < footer.range(of: "Button(\"Capture Again\")")!.lowerBound)
        precondition(footer.range(of: "Button(\"Capture Again\")")!.lowerBound < footer.range(of: "Button(\"Done\")")!.lowerBound)
        precondition(footer.contains("model.scan()") && footer.contains("model.done()"))
        precondition(actions.range(of: "OperationLogButton(")!.lowerBound < actions.range(of: "switch model.state")!.lowerBound)
        for width in [600.0, 850.0] {
            let view = CaptureBundleLocationView(destination: URL(fileURLWithPath: "/Users/fixture/Saved Environments/My Mac.mbt"), showsReveal: true)
            let renderer = ImageRenderer(content: view.padding(14).frame(width: width))
            precondition(renderer.nsImage != nil)
        }
        precondition(WorkspaceSettingLabels.title(domain: "macos-screenshots", identity: "com.apple.screencapture/disable-shadow") == "Window shadow")
        precondition(WorkspaceSettingLabels.title(domain: "macos-screenshots", identity: "com.apple.screencapture/show-thumbnail") == "Floating thumbnail")
        print("PASS: Capture Result file-local Reveal; footer View Log, Capture Again, Done; Screenshots labels")
    }

    @MainActor static func restoreSummaryChecks() {
        let rosetta = CoreRestorePreparation.Diagnostic(primitive: "rosetta", condition: "installation_required")
        precondition(rosetta.explanation.contains("softwareupdate --install-rosetta"))
        precondition(rosetta.explanation.contains("Refresh Preview") && rosetta.explanation.contains("manually"))
        precondition(rosetta.technicalDescription == "primitive: rosetta\ncondition: installation_required")
        let requirement = CoreRestorePreparation.Condition(domain: "homebrew-casks", code: "cask_rosetta_required",
            status: "external_action_required", selectedItemIndex: 1, scope: "item", diagnostic: rosetta)
        precondition(requirement.isItemLocal && !rosetta.automationPreparationAvailable)
        let rosettaSummary = RestorePrerequisiteSummaryPresentation(conditions: [requirement], ready: true)
        precondition(!rosettaSummary.canFixIssues)

        let casks = ["firefox", "iina", "keka"].map {
            DisplayItem(id: "homebrew-casks:" + $0, title: $0, status: .attention,
                        action: "Repeated generic message", reason: "cask_execution_requirements_unsupported")
        }
        let git = ["core.editor", "init.defaultBranch"].map {
            DisplayItem(id: "git-configuration:" + $0, title: $0, status: .attention,
                        action: "Repeated generic message", reason: "target_conflict")
        }
        let categories = [DisplayCategory(id: "homebrew-casks", title: "Homebrew Applications", symbol: "app", items: casks),
                          DisplayCategory(id: "git-configuration", title: "Git Configuration", symbol: "gear", items: git)]
        let summary = RestoreIssueSummaryPresentation(categories: categories + [categories[0]])
        precondition(summary.count == 5 && summary.title == "5 items need attention")
        precondition(summary.areas.map(\.title) == ["Homebrew Applications", "Git Configuration"])
        precondition(summary.areas.map { $0.items.count } == [3, 2] && !summary.detailsInitiallyExpanded)
        precondition(summary.areas[0].items.map(\.title) == ["firefox", "iina", "keka"])
        precondition(summary.areas[1].items.map(\.title) == ["core.editor", "init.defaultBranch"])
        precondition(summary.areas[0].items.allSatisfy { $0.action.contains("not supported") && $0.reason == "cask_execution_requirements_unsupported" })
        precondition(summary.areas[1].items.allSatisfy { $0.action.contains("preserved") && $0.reason == "target_conflict" })
        let catalog = CoreRestoreInspection.Inventory(groups: [], inventory: [
            CoreRestoreInspection.Area(domain: "homebrew-casks", label: "Homebrew Applications", selectionMode: "items", availability: "available", reason: nil, items: [])])
        let repeatedArea = DisplayItem(id: "homebrew-casks", title: "Homebrew Applications", status: .attention, action: "This area needs attention.")
        let unknown = DisplayItem(id: "homebrew-casks", title: "Homebrew Applications", status: .unverified, action: "Final conformity is unverified.", reason: "mismatch")
        let result = RestoreIssueSummaryPresentation.result(casks + [casks[0], repeatedArea, unknown], catalog: catalog)
        precondition(result.count == 4 && result.attentionCount == 3 && result.unverifiedCount == 1)
        precondition(result.areas.count == 1 && result.areas[0].unverifiedCount == 1)
        precondition(result.areas[0].items.contains { $0.status == .unverified && $0.reason == "mismatch" })
        func condition(_ code: String, _ status: String, scope: String? = nil) -> CoreRestorePreparation.Condition {
            CoreRestorePreparation.Condition(domain: "homebrew-casks", code: code, status: status, selectedItemIndex: scope == "item" ? 1 : nil, scope: scope)
        }
        let satisfied = RestorePrerequisiteSummaryPresentation(conditions: [condition("ready", "satisfied")], ready: true)
        precondition(satisfied.title == "Ready" && satisfied.blockers.isEmpty && !satisfied.detailsInitiallyExpanded)
        let local = RestorePrerequisiteSummaryPresentation(conditions: [condition("cask_execution_requirements_unsupported", "unsupported", scope: "item")], ready: true)
        precondition(local.title == "Ready" && local.blockers.isEmpty)
        let blocked = RestorePrerequisiteSummaryPresentation(conditions: [condition("homebrew_unavailable", "external_action_required")], ready: false)
        precondition(blocked.title == "Needs Attention" && blocked.blockers.count == 1)
        let source = try! String(contentsOfFile: "Sources/RestoreSummary.swift", encoding: .utf8)
        let previewSource = String(source.components(separatedBy: "// Preview owns area/count summaries only")[1])
        let prerequisiteSummarySource = String(source.components(separatedBy: "struct RestorePrerequisiteSummaryView:")[1].components(separatedBy: "// Preview owns area/count summaries only")[0])
        precondition(!previewSource.contains("Show Details") && !previewSource.contains("summary.title"))
        precondition(previewSource.contains("ForEach(summary.areas)"))
        precondition(previewSource.contains("Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8)"))
        precondition(previewSource.contains("GridRow {") && previewSource.contains(".monospacedDigit()"))
        precondition(!previewSource.contains("Spacer()") && !previewSource.contains(".infinity"))
        precondition(!previewSource.contains("DisclosureGroup") && !previewSource.contains("ForEach(area.items)"))
        precondition(!previewSource.contains("item.title") && !previewSource.contains("item.action") && !previewSource.contains("item.reason"))
        precondition(!previewSource.contains("Technical") && !previewSource.contains("cask_execution_requirements_unsupported"))
        precondition(previewSource.contains("Text(String(area.items.count))") && previewSource.contains(".accessibilityLabel(area.title)"))
        precondition(prerequisiteSummarySource.contains("DisclosureGroup(isExpanded: $expanded)"))
        precondition(!prerequisiteSummarySource.contains("Show Details"))
        precondition(prerequisiteSummarySource.contains("if !summary.manualConditions.isEmpty") && !prerequisiteSummarySource.contains("Needs Preparation"))
        precondition(prerequisiteSummarySource.contains("ForEach(summary.manualDomains"))
        precondition(prerequisiteSummarySource.contains("showsHeading: false") && !prerequisiteSummarySource.contains("technicalTitle: \"Technical Details\""))
        for areaSource in [previewSource, prerequisiteSummarySource] {
            let labelSource = areaSource == previewSource
                ? String(areaSource.components(separatedBy: "private struct RestorePreviewAttentionAreaView:")[1])
                : String(areaSource.components(separatedBy: "} label: {").last!)
            precondition(labelSource.contains("Image(systemName: \"exclamationmark.triangle\")"))
            precondition(labelSource.contains(".foregroundStyle(RestoreStatusTone.warning.color)"))
            precondition(labelSource.contains(".accessibilityHidden(true)"))
            precondition(labelSource.range(of: "Image(systemName:")!.lowerBound < labelSource.range(of: "Text(")!.lowerBound)
        }
        precondition(blocked.affectedDomains == ["homebrew-casks"])
        precondition(RestorePrerequisiteSummaryPresentation.status([condition("authorization_required", "external_action_required")]) == "Authorization Required")
        let view = try! String(contentsOfFile: "Sources/RestoreView.swift", encoding: .utf8)
        precondition(!view.contains("DisclosureGroup(\"Technical reason\")") && !view.contains("DisclosureGroup(\"Technical Details\")"))
        precondition(view.contains("RestoreRebuildProgressContent(tasks:") && view.contains("RestoreResultContent(result:"))
        precondition(view.contains("TaskDomainList(domains: visibleDomains.map"))
        precondition(view.contains("Text(item.title)") && view.contains("Text(item.action)"))

        precondition(TaskRowState.aggregate([.completed, .skipped]) == .partial)
        precondition(TaskRowState.aggregate([.completed, .failed]) == .partial)
        precondition(TaskRowState.aggregate([.failed, .waiting]) == .failed)
        precondition(TaskRowState.aggregate([.unverified]) == .unverified)
        precondition(TaskRowState.aggregate([.working, .attention]) == .working)
        precondition(TaskRowState.aggregate([.skipped]) == .skipped)
        precondition(OperationSummaryHeader.elapsed(Date(timeIntervalSince1970: 0), Date(timeIntervalSince1970: 342)) == "5m 42s")
        let components = try! String(contentsOfFile: "Sources/TaskComponents.swift", encoding: .utf8)
        precondition(!components.contains("ProgressView(value:"))
        precondition(components.contains("Log unavailable"))
        precondition(!components.contains("Technical Details") && components.contains("ForEach(hideMatchingPreviewItems ? RestorePreviewVisibility.items(domain.items) : domain.items)"))
        print("PASS: Reusable task states, elapsed metadata, metric cards and unavailable View Log")

        print("PASS: Compact Restore summary counts/area aggregation, collapsed details, concrete names/reasons, prerequisites and result deduplication with Unverified evidence")
    }
    @MainActor static func renderRestoreV2() {
        let restoreSource = try! String(contentsOfFile: "Sources/RestoreView.swift", encoding: .utf8)
        let resultSource = restoreSource.components(separatedBy: "struct RestoreResultContent:")[1].components(separatedBy: "struct RestorePreviewMetrics:")[0]
        precondition(!resultSource.contains("Text(\"Execution\")") && !resultSource.contains("receipts") && !resultSource.contains("Confirmed completed"))
        precondition(resultSource.range(of: "RestoreResultSummaryView")!.lowerBound < resultSource.range(of: "RestoreExecutionCategories")!.lowerBound)
        for status in ["complete", "incomplete", "not_run"] {
            let payload: [String: CoreJSON] = ["verification": .object(["status": .string(status), "verified_count": .integer(12),
                "mismatch_count": .integer(1), "unverified_count": .integer(2), "unresolved_count": .integer(3)])]
            let image = ImageRenderer(content: RestoreVerificationResult(outcome: .attention, payload: payload).frame(width: 760))
            precondition(image.nsImage != nil)
        }
        precondition(ImageRenderer(content: RestoreVerificationResult(outcome: .attention, payload: nil).frame(width: 760)).nsImage != nil)
        print("PASS: Result places confirmed summary before categories; Verification projection preserves missing counts")
        precondition(!resultSource.contains("DisclosureGroup(\"Technical Details\")"))
        precondition(!resultSource.contains("Verified selected work"))
        precondition(!resultSource.contains("result.compactTechnicalDetails") && !resultSource.contains("Copy Diagnostic Details"))
        precondition(!resultSource.contains("result.diagnosticReport") && !resultSource.contains("NSPasteboard.general"))

        precondition(!resultSource.contains("DisclosureGroup(\"Needs Attention\")") && !resultSource.contains("View Details"))
        precondition(resultSource.contains("showsWarnings: false"))
        let progressSource = restoreSource.components(separatedBy: "struct RestoreRebuildProgressContent:")[1].components(separatedBy: "struct RestoreExecutionCategories:")[0]
        precondition(!progressSource.contains("Label(\"Verification\"") && !progressSource.contains("Checking selected requirements"))
        precondition(progressSource.contains("ProgressView()") && !progressSource.contains("RestoreOperationCounts") && progressSource.contains("RestoreExecutionCategories"))
        precondition(RestoreVerificationResult.resultTone("OK") == .success)
        precondition(RestoreVerificationResult.resultTone("Failed") == .error)
        precondition(RestoreVerificationResult.resultTone("Stopped") == .neutral)
        for result in ["Incomplete", "Interrupted", "Needs Attention"] { precondition(RestoreVerificationResult.resultTone(result) == .warning) }
        for count in [Int?.none, 0] {
            precondition(RestoreVerificationResult.countTone(count, problem: .error) == .neutral)
            precondition(RestoreVerificationResult.countTone(count, problem: .warning) == .neutral)
        }
        precondition(RestoreVerificationResult.countTone(1, problem: .error) == .error)
        precondition(RestoreVerificationResult.countTone(1, problem: .warning) == .warning)
        // Production execution categories stay compact with 2 or 120 operations.
        func executionDomains(_ count: Int) -> [TaskDomainPresentation] {
            ["homebrew-casks", "homebrew-packages"].map { domain in
                TaskDomainPresentation(id: domain, title: domain, symbol: "shippingbox",
                    items: (0..<count).map { index in
                        TaskItemPresentation(id: "\(domain)-\(index)",
                            item: DisplayItem(id: "\(domain)-\(index)", title: "Item \(index)", status: .waiting, action: "Install"), state: .waiting)
                    })
            }
        }
        let smallExecution = ImageRenderer(content: RestoreExecutionCategories(domains: executionDomains(1)).frame(width: 1000))
        let largeExecution = ImageRenderer(content: RestoreExecutionCategories(domains: executionDomains(60)).frame(width: 1000))
        precondition(smallExecution.nsImage != nil && largeExecution.nsImage != nil)
        precondition(abs(smallExecution.nsImage!.size.height - largeExecution.nsImage!.size.height) < 2)
        for state in [TaskRowState.waiting, .working, .awaitingVerification, .completed, .matching, .attention, .notRun] {
            var rows = executionDomains(1)
            for index in rows.indices {
                rows[index].activityState = state
                if [.completed, .matching, .notRun].contains(state) { rows[index].confirmedFinalState = state }
            }
            let rendered = ImageRenderer(content: RestoreExecutionCategories(domains: rows).frame(width: 1000))
            precondition(rendered.nsImage != nil)
            precondition(abs(rendered.nsImage!.size.height - smallExecution.nsImage!.size.height) < 2)
        }
        precondition(TaskRowState.notRun.tone == .neutral && TaskRowState.notRun.rawValue == "Not Run")
        precondition(TaskRowState.aggregate([.notRun, .notRun]) == .notRun)
        print("PASS: Production Rebuild categories keep fixed height and neutral Not Run presentation")
        let domains = [TaskRowState.completed, .partial, .attention, .skipped, .failed].enumerated().map { index, state in
            TaskDomainPresentation(id: "domain-\(index)", title: "Domain \(index + 1)", symbol: "folder",
                items: [TaskItemPresentation(id: "item-\(index)",
                    item: DisplayItem(id: "item-\(index)", title: "Concrete item", status: .information, action: "Observed result"), state: state)],
                activityState: state)
        }
        let counters = domains.map { (state: $0.state, count: 1) }
        let large = TaskDomainPresentation(id: "large", title: "Homebrew", symbol: "shippingbox",
            items: (1...24).map { index in
                TaskItemPresentation(id: "large-\(index)", item: DisplayItem(id: "large-\(index)",
                    title: "Captured application \(index)", status: .attention,
                    action: "This application's installation requirements are not supported.",
                    reason: "cask_execution_requirements_unsupported"), state: .skipped)
            })
        let compactCapture = TaskDomainPresentation(id: "capture-details", title: "Homebrew Packages", symbol: "shippingbox",
            items: (1...12).map { index in
                TaskItemPresentation(id: "capture-\(index)", item: DisplayItem(id: "capture-\(index)",
                    title: index == 1 ? String(repeating: "long-package-name-", count: 12) : "package-\(index)",
                    status: .ready, action: "Supported state available to save."), state: .planned)
            } + [TaskItemPresentation(id: "capture-warning", item: DisplayItem(id: "capture-warning", title: "Needs Attention",
                status: .attention, action: "Some supported state may be unavailable in this category.", reason: "source_partial"), state: .attention, captureRole: .categoryWarning)])
        for width in [730, 930, 1330] {
            let captureRenderer = ImageRenderer(content: TaskDomainItems(domain: compactCapture, compactReadyItems: true)
                .padding(24).frame(width: CGFloat(width)).background(Color(nsColor: .windowBackgroundColor)))
            captureRenderer.scale = 1
            let captureImage = captureRenderer.nsImage!
            let captureBitmap = NSBitmapImageRep(data: captureImage.tiffRepresentation!)!
            precondition(captureBitmap.pixelsWide == width)
            try! captureBitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/Debug/CaptureConfirmation-details-\(width).png"))
            let content = VStack(alignment: .leading, spacing: 22) {
                OperationSummaryHeader(title: "Rebuild Completed with Issues", message: "Review the observed results and affected items.",
                    state: .partial, counters: counters, startedAt: Date().addingTimeInterval(-342),
                    finishedAt: Date())
                PendingOperationLogButton()
                TaskDomainList(domains: domains)
                DisclosureGroup(isExpanded: .constant(true)) {
                    TaskDomainItems(domain: large)
                } label: { Text("Homebrew · 24 captured items") }
                    .disclosureGroupStyle(TaskDisclosureStyle())
            }.padding(24).frame(width: CGFloat(width)).background(Color(nsColor: .windowBackgroundColor))
            let renderer = ImageRenderer(content: content)
            renderer.scale = 1
            if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) {
                precondition(bitmap.pixelsWide == width)
                try! png.write(to: URL(fileURLWithPath: "build/Debug/RestoreUIv2-\(width).png"))
            } else { preconditionFailure("Restore UI snapshot could not render") }
        }
        let source = try! String(contentsOfFile: "Sources/TaskComponents.swift", encoding: .utf8)
        let style = source.components(separatedBy: "struct TaskDisclosureStyle:")[1].components(separatedBy: "struct TaskStatusLabel:")[0]
        precondition(style.contains("Button { configuration.isExpanded.toggle() }") && style.contains(".contentShape(Rectangle())"))
        precondition(style.contains(".buttonStyle(.plain)") && style.contains(".accessibilityValue("))
        precondition(!style.contains("onTapGesture"))
        let workspace = try! String(contentsOfFile: "Sources/ProductionWorkspace.swift", encoding: .utf8)
        precondition(workspace.contains(".modifier(WorkspaceContentGeometry())") && !workspace.contains(" : 800"))
        precondition(source.contains("TaskRowLayout.statusWidth"))
        precondition(source.contains("TaskDisclosureStyle(includesIndicator:") && !source.contains("Technical Details"))
        precondition(source.contains("spacing: 12") && source.contains("minHeight: 52"))
        let summary = try! String(contentsOfFile: "Sources/RestoreSummary.swift", encoding: .utf8)
        let attention = summary.components(separatedBy: "// Preview owns area/count summaries only")[1]
        precondition(attention.contains("if !summary.areas.isEmpty") && attention.contains("Text(\"Needs Attention\").font(.headline)"))
        let app = try! String(contentsOfFile: "Sources/MacseedApp.swift", encoding: .utf8)
        precondition(app.contains(".background(MainWindowConfiguration())") && app.contains(".windowResizability(.contentSize)"))
        precondition(app.contains("MainWindowPolicy.preferred.width") && !app.contains("MainWindowPolicy.maximum"))
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: MainWindowPolicy.preferred),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        MainWindowPolicy.apply(to: window)
        precondition(window.contentMinSize == NSSize(width: 1000, height: 700))
        precondition(window.contentMaxSize.width > 1600 && window.contentMaxSize.height > 1050)
        precondition(MainWindowPolicy.preferred == NSSize(width: 1200, height: 800))
        precondition(window.styleMask.contains(.resizable))
        precondition(!window.collectionBehavior.contains(.fullScreenNone) && window.collectionBehavior.contains(.fullScreenPrimary))
        window.close()
        print("PASS: Native category disclosures, attention heading, main window bounds/fullscreen policy and responsive range renders")
    }

    @MainActor static func renderInitialStates() {
        _ = NSApplication.shared
        let runtime = CoreRuntime()
        let capture = CaptureModel(runtime: runtime)
        let restore = RestoreModel(runtime: runtime)
        for task in [ProductTask.capture, .restore] {
            for (label, width) in [("narrow", 1000), ("wide", 1600)] {
                let content = HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Macseed").font(.title2.weight(.semibold))
                        Label("Home", systemImage: "square.grid.2x2")
                        ForEach(ProductTask.allCases) { task in Label(task.title, systemImage: task.symbol) }
                        Spacer()
                    }.padding(20).frame(width: 215).background(.regularMaterial)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            WorkspaceHeader(title: task.title, subtitle: task.subtitle, symbol: task.symbol)
                            if task == .capture { CaptureView(model: capture, runtime: runtime, showsActions: false) }
                            else { RestoreView(model: restore, runtime: runtime, showsRebuildActions: false) }
                        }.modifier(WorkspaceContentGeometry())
                    }
                }.frame(width: CGFloat(width), height: 800).background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.colorScheme, .light)
                let host = NSHostingView(rootView: content)
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .aqua); window.contentView = host
                host.frame = NSRect(x: 0, y: 0, width: width, height: 800)
                host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
                let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let name = task == .capture ? "Capture" : "Restore"
                try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/Debug/\(name)InitialUIv2-\(label).png"))
                window.close()
            }
        }
        precondition(runtime.state == .idle && capture.state == .idle && restore.state == .choose)
        print("PASS: Native initial Capture/Restore cards narrow/wide; no Core execution")
    }

    @MainActor static func renderHomeBranding() {
        precondition(ProductTask.allCases.map(\.title) == ["Capture", "Rebuild", "Check"])
        precondition(ProductTask.allCases.map(\.subtitle) == ["Capture apps, settings, and workspace.",
            "Rebuild from a saved environment.", "Check a saved environment."])
        let tagline = "A smarter way to capture, rebuild, and check your Mac setup."
        for file in ["Branding.swift", "MacseedApp.swift"] {
            precondition(try! String(contentsOfFile: "Sources/" + file).contains(tagline))
        }
        precondition(MacseedAppIcon().leafScale == 1)
        precondition(MacseedAppIcon.systemLeafScale == 1.22)
        for scheme in [ColorScheme.light, .dark] {
            for width in [730, 1000, 1500] {
                let renderer = ImageRenderer(content: TaskHome(select: { _ in })
                    .padding(28).frame(width: CGFloat(width))
                    .background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.colorScheme, scheme))
                renderer.scale = 1
                guard let image = renderer.cgImage else { preconditionFailure("Home must render") }
                let bitmap = NSBitmapImageRep(cgImage: image)
                precondition(bitmap.pixelsWide == width && bitmap.pixelsHigh < 700)
                try! bitmap.representation(using: .png, properties: [:])!.write(to:
                    URL(fileURLWithPath: "build/Debug/Home-\(scheme)-\(width).png"))
            }
        }
        print("PASS: Leaf Home hero and three action tiles render at supported widths in Light/Dark")
    }

    static func appIconChecks() {
        let root = URL(fileURLWithPath: "Assets.xcassets/AppIcon.appiconset")
        let json = try! JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("Contents.json"))) as! [String: Any]
        let images = json["images"] as! [[String: String]]
        precondition(images.count == 10)
        for entry in images {
            let width = Int(entry["size"]!.split(separator: "x")[0])! * Int(entry["scale"]!.dropLast())!
            let bitmap = NSBitmapImageRep(data: try! Data(contentsOf: root.appendingPathComponent(entry["filename"]!)))!
            precondition(bitmap.pixelsWide == width && bitmap.pixelsHigh == width)
            let blue = bitmap.colorAt(x: width / 2, y: width / 2)!.usingColorSpace(.sRGB)!
            precondition(blue.alphaComponent > 0.9 && blue.blueComponent > blue.redComponent)
        }
        precondition(NSImage(contentsOfFile: "Resources/Macseed.icns") != nil)
        let bundle = Bundle(path: "build/Debug/Macseed.app")!
        precondition(MacseedBundleIcon.load(bundle: bundle) != nil)
        precondition(try! Data(contentsOf: bundle.url(forResource: "Macseed", withExtension: "icns")!) == Data(contentsOf: URL(fileURLWithPath: "Resources/Macseed.icns")))
        print("PASS: Shared leaf AppIcon variants, visible small-scale mark and valid ICNS")
    }

    @MainActor static func renderUnifiedSettings() {
        let domainIDs = CaptureMacOSSettingsGroup.domainIDs
        let rows: [CoreRestorePreparation.Row] = domainIDs.enumerated().map { index, domain in
            let key = WorkspaceSettingLabels.names.keys.filter { $0.hasPrefix(domain + ":") }.sorted().first!
            let identity = String(key.dropFirst(domain.count + 1))
            let data = try! JSONSerialization.data(withJSONObject: ["domain": domain, "item_id": identity,
                "action": "set_preference", "disposition": index == 5 ? "satisfied" : "planned"])
            return try! JSONDecoder().decode(CoreRestorePreparation.Row.self, from: data)
        }
        let items = rows.enumerated().map { index, row in
            TaskItemPresentation(id: "restore-\(index)", item: DisplayItem(id: "restore-\(index)", title: row.itemID,
                status: row.disposition == "satisfied" ? .matching : .ready, action: row.disposition == "satisfied" ? "Already Matches" : "Will restore setting"),
                state: row.disposition == "satisfied" ? .matching : .planned)
        }
        let parent = TaskDomainPresentation(id: "macOS Settings", title: "macOS Settings", symbol: "slider.horizontal.3", items: items, previewOnly: true)
        let categories = domainIDs.enumerated().map { index, domain in
            DisplayCategory(id: domain, title: CaptureCategory.title(for: domain), symbol: WorkspaceCategoryStyle.symbol(domain), items: [items[index].item])
        }
        let children = RestoreSettingsPresentation.children([parent], categories: categories)
        precondition(children.map(\.id) == domainIDs && children.flatMap(\.items).map(\.id) == items.map(\.id))
        let titles = RestoreSettingsPresentation.titles(rows)
        precondition(titles.count == 6 && titles["restore-0"] == "Show extensions")
        for width in [400, 785, 985] {
            let content = VStack(alignment: .leading, spacing: 20) {
                RestorePreviewMetrics(domains: [parent])
                TaskDomainList(domains: [parent], settingsCategories: children, itemTitles: titles,
                    expansion: .constant(["macOS Settings"]), settingsExpansion: .constant(true))
            }.padding(28).frame(width: CGFloat(width)).background(Color(nsColor: .windowBackgroundColor))
            let renderer = ImageRenderer(content: content)
            renderer.scale = 1
            let bitmap = NSBitmapImageRep(data: renderer.nsImage!.tiffRepresentation!)!
            precondition(bitmap.pixelsWide == width && bitmap.pixelsHigh < 1800, "Narrow content must reflow without unbounded card/item height")
            try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/Debug/RestoreUnified-setting-labels-\(width).png"))
            let unsupported = CoreRestoreInspection.Area(domain: "macos-finder", label: "Finder", selectionMode: "category", availability: "unsupported", reason: "source_unsupported", items: [])
            precondition(ImageRenderer(content: RestoreMacOSAreaDetails(area: unsupported, expansion: .constant(true)).padding(28).frame(width: CGFloat(width))).nsImage != nil)
        }
        print("PASS: Native read-only nested macOS Preview, exact setting names, preserved IDs/counts and unsupported details")
    }

    @MainActor static func presentationTaxonomyChecks() {
        typealias Taxonomy = WorkspacePresentationTaxonomy
        // Read the authoritative registry as data, without importing/running Core.
        // Optional extension domains must participate; a fixed count is not an oracle.
        let registry = Process(), output = Pipe()
        registry.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        registry.arguments = ["python3", "-B", "-c", """
        import ast, json, pathlib
        tree = ast.parse(pathlib.Path('../../modules/bundle/bundle.py').read_text())
        names = {'ITEMS', 'EXTENSION_ITEMS', 'CATEGORIES'}
        result = {}
        for node in tree.body:
            if isinstance(node, ast.Assign) and len(node.targets) == 1 and isinstance(node.targets[0], ast.Name):
                if node.targets[0].id in names:
                    result[node.targets[0].id] = sorted(ast.literal_eval(node.value))
        assert set(result) == names
        print(json.dumps(result))
        """]
        registry.standardOutput = output
        try! registry.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        registry.waitUntilExit()
        precondition(registry.terminationStatus == 0, "Cannot read canonical Core domain registry")
        let registered = try! JSONDecoder().decode([String: [String]].self, from: data)
        let itemDomains = Set(registered["ITEMS"]! + registered["EXTENSION_ITEMS"]!)
        let categoryDomains = Set(registered["CATEGORIES"]!)
        let known = itemDomains.union(categoryDomains)
        let advertised = Taxonomy.Group.allCases.flatMap(\.domains)
        precondition(Set(advertised) == known && advertised.count == known.count,
                     "Every Core domain must be classified exactly once")
        precondition(Taxonomy.Section.allCases.map(\.title) == ["Applications & Tools", "macOS Settings", "Application Extras", "For Experienced Users", "Other Findings"])
        precondition(Taxonomy.Group.allCases.map(\.section) == Taxonomy.Section.allCases)
        precondition(Taxonomy.Group.vscode.section == .applicationExtras && Taxonomy.Group.vscode.title == "VS Code")
        precondition(Taxonomy.Group.vscode.domains == ["vscode-extensions", "vscode-settings"])
        precondition(Taxonomy.Group.advanced.domains == ["git-configuration", "git-repositories", "workspace-folders", "ssh-configuration", "shell-zsh", "vscode-workspaces"])
        precondition(Taxonomy.Group.macOSSettings.domains == CaptureMacOSSettingsGroup.domainIDs)
        precondition(Taxonomy.group(for: "future-domain") == .otherFindings)
        let displayIDs = Taxonomy.Section.allCases.map(\.id) + Taxonomy.Group.allCases.map(\.id)
        precondition(Set(displayIDs).count == displayIDs.count && known.isDisjoint(with: displayIDs))
        precondition(Taxonomy.Group.vscode.id == "presentation.group.vscode" && Taxonomy.Section.advanced.id == "presentation.section.advanced")

        let statuses: [DisplayStatus] = [.matching, .different, .missing, .unverified, .unsupported, .unresolved, .attention]
        let domains = known.sorted() + ["future-domain", "another-future-domain"]
        let rows = domains.enumerated().map { index, id in
            DisplayCategory(id: id, title: id, symbol: "folder", items: (0...(index % 3)).map { item in
                DisplayItem(id: id + ":\(item)", title: "Requirement \(item)", status: statuses[index % statuses.count], action: "Retained evidence")
            })
        }
        let projected = Taxonomy.project(Array(rows.reversed()))
        let leaves = projected.flatMap(\.rows)
        precondition(leaves.count == rows.count && leaves.sorted { $0.id < $1.id } == rows.sorted { $0.id < $1.id })
        precondition(leaves.flatMap(\.items).count == rows.flatMap(\.items).count)
        for status in statuses {
            precondition(leaves.flatMap(\.items).filter { $0.status == status }.count == rows.flatMap(\.items).filter { $0.status == status }.count)
        }
        precondition(projected.last!.group == .otherFindings && projected.last!.rows.map(\.id) == ["another-future-domain", "future-domain"])
        precondition(projected.filter { $0.group.section == .applicationExtras }.flatMap(\.rows).map(\.id) == ["vscode-extensions", "vscode-settings"])
        precondition(Taxonomy.project([DisplayCategory]()).isEmpty)
        for id in ["vscode-workspaces", "workspace-folders", "future-domain"] {
            let only = Taxonomy.project(rows.filter { $0.id == id })
            precondition(only.count == 1 && only[0].rows.map(\.id) == [id])
            precondition(only[0].group == (id == "future-domain" ? .otherFindings : .advanced))
        }

        // Exercise the projection with real Capture inventory rows and existing
        // request types. Explicit subsets/categories survive placement unchanged.
        let categories = domains.map { id -> CaptureCategory in
            let object: [String: Any] = ["domain": id, "status": known.contains(id) ? "present" : "unsupported",
                "selection_mode": itemDomains.contains(id) ? "items" : categoryDomains.contains(id) ? "category" : "future_mode",
                "items": itemDomains.contains(id) ? ["one", "two"].map { ["item_id": $0, "label": $0] } : []]
            return CaptureCategory(row: try! JSONDecoder().decode(CoreCaptureInventoryRow.self, from: JSONSerialization.data(withJSONObject: object)))
        }
        let moved = Taxonomy.project(categories).flatMap(\.rows)
        let selectedCategories: Set<String> = ["vscode-settings", "ssh-configuration", "macos-finder"]
        let selectedItems = ["vscode-extensions": ["one"], "vscode-workspaces": ["two"], "workspace-folders": ["one"]]
        func requests(_ inventory: [CaptureCategory]) -> [CoreJSON] {
            let categoryIDs = inventory.filter { selectedCategories.contains($0.id) }.map(\.id).sorted()
            let items = Dictionary(uniqueKeysWithValues: inventory.compactMap { category -> (String, [String])? in
                guard let chosen = selectedItems[category.id] else { return nil }
                return (category.id, category.row.items.map(\.itemID).filter(chosen.contains).sorted())
            })
            let commands: [CoreCommand] = [
                .capturePrepare(selection: .init(categories: categoryIDs, items: items, secureIdentities: [])),
                .restorePrepare(path: "/private/tmp/taxonomy-reference.mbt", disabledGroups: [], includeSecure: false,
                                selection: .init(categories: categoryIDs, items: items)),
            ]
            return commands.map { try! JSONDecoder().decode(CoreJSON.self, from: CoreRequest($0, operationID: "taxonomy-check").encoded()) }
        }
        precondition(requests(categories) == requests(moved))
        for original in categories {
            let retained = moved.first { $0.id == original.id }!
            precondition(retained.row.selectionMode == original.row.selectionMode && retained.selectable == original.selectable)
        }

        // Capture uses the visual taxonomy; Core group projections retain their IDs.
        let liveCapture = CaptureHierarchy.project(CaptureReviewRow.project(categories))
        precondition(liveCapture.first { $0.group == .vscode }!.rows.map(\.id) == ["vscode-extensions", "vscode-settings"])
        precondition(liveCapture.first { $0.group == .advanced }!.rows.map(\.id) == Taxonomy.Group.advanced.domains)
        precondition(liveCapture.flatMap(\.rows).flatMap(\.categories).map(\.id).sorted() == categories.map(\.id).sorted())
        for section in liveCapture {
            let controls = CaptureReviewPresentation.bulkCategories(categories, group: section.group)
            precondition(controls.map(\.id).sorted() == section.rows.flatMap(\.categories).filter { $0.id != "ssh-configuration" }.map(\.id).sorted(),
                "Capture group masters exclude the sibling SSH configuration")
        }
        precondition(CaptureReviewPresentation.bulkCategories(categories, group: .advanced).contains { $0.id == "workspace-folders" })
        precondition(SelectionState.none.bulkActionTitle == "Select All" && SelectionState.mixed.bulkActionTitle == "Select All"
            && SelectionState.all.bulkActionTitle == "Deselect All")
        let topGroups = liveCapture.filter { $0.group != .otherFindings }.map(\.group)
        precondition(topGroups.map(CaptureHierarchy.sectionTitle) == ["Applications & Tools", "macOS Settings", "Application Extras", "For Experienced Users"])
        let capturePresentation = try! String(contentsOfFile: "Sources/CapturePresentation.swift")
        precondition(capturePresentation.contains("WorkspaceSectionHeader(title: \"For Experienced Users\")"))
        precondition(Set(topGroups.map(CaptureHierarchy.sectionID)).count == 4)
        precondition(CaptureHierarchy.sectionID(.vscode) != Taxonomy.Group.vscode.id,
            "Application Extras and its VS Code child must have independent disclosures")
        precondition(CaptureHierarchy.initialExpansion.isEmpty)
        precondition(CaptureHierarchy.ordinaryGroups == [.applicationsTools, .macOSSettings, .vscode])
        precondition(!CaptureHierarchy.initialExpansion.contains(CaptureHierarchy.sectionID(.advanced)))
        precondition(CaptureHierarchy.title("vscode-workspaces", fallback: "old title") == "VS Code Workspace")
        let appDisclosure = CaptureHierarchy.childDisclosureIDs(domains, group: .applicationsTools)
        let extrasDisclosure = CaptureHierarchy.childDisclosureIDs(domains, group: .vscode)
        precondition(appDisclosure == Set(Taxonomy.Group.applicationsTools.domains) && appDisclosure.isDisjoint(with: extrasDisclosure))
        precondition(extrasDisclosure == Set(Taxonomy.Group.vscode.domains + [Taxonomy.Group.vscode.id]))
        let selection = CoreCaptureSelection(categories: known.sorted(), items: [:], secureIdentities: [])
        let confirmation = CaptureTaskPresentation(categories: categories, selection: selection, phase: .confirmation)
        let taskGroups = CaptureHierarchy.project(confirmation.domains)
        precondition(taskGroups.first { $0.group == .macOSSettings }!.rows.map(\.id) == ["macos-settings"])
        precondition(taskGroups.flatMap(\.rows).flatMap(\.items).map(\.id) == confirmation.domains.flatMap(\.items).map(\.id))
        let ordinaryIDs = CaptureHierarchy.disclosureIDs(domains + ["macos-settings"], scope: .ordinary)
        let advancedIDs = CaptureHierarchy.disclosureIDs(domains, scope: .advanced)
        precondition(ordinaryIDs.isDisjoint(with: advancedIDs) && !ordinaryIDs.contains("future-domain"))
        precondition(CaptureHierarchy.disclosureIDs(["git-repositories"], scope: .ordinary).isEmpty)
        precondition(ordinaryIDs.contains(Taxonomy.Group.vscode.id) && Set(DeveloperSelectionGroup.allCases.map(\.id)).isSubset(of: advancedIDs) && !advancedIDs.contains(Taxonomy.Group.advanced.id))
        let expanded = CaptureHierarchy.toggled(["future-domain"], ids: advancedIDs)
        precondition(CaptureHierarchy.toggled(expanded, ids: ordinaryIDs).isSuperset(of: expanded))
        precondition(CaptureHierarchy.toggled(expanded, ids: advancedIDs) == ["future-domain"])
        let coreGroups = [CoreRestoreInspection.Group(id: "Applications", domains: ["app-store", "vscode-extensions"]),
                          .init(id: "VS Code Settings", domains: ["vscode-settings"]),
                          .init(id: "Workspace", domains: ["workspace-folders", "git-repositories", "vscode-workspaces"]),
                          .init(id: "Future", domains: ["future-domain"])]
        let liveRestore = RestorePresentationSection.project(coreGroups)
        precondition(liveRestore.first { $0.id == "Workspace" }!.groups.flatMap(\.domains) == coreGroups[2].domains)
        precondition(liveRestore.last!.groups.flatMap(\.domains) == ["future-domain"])
        let liveStatus = EnvironmentStatusSection.project(rows, groups: coreGroups)
        precondition(liveStatus.first { $0.id == "Applications & Tools" }!.entries.contains { $0.id == "vscode-extensions" })
        precondition(liveStatus.first { $0.id == "Workspace" }!.entries.map(\.id) == coreGroups[2].domains)
        precondition(liveStatus.last!.entries.contains { $0.id == "future-domain" })
        print("PASS: Capture taxonomy covers Core registry once, preserves unknown evidence/counts/requests, scopes expansion and leaves Restore/Status placement unchanged")
    }

    @MainActor static func visualContractChecks() {
        presentationTaxonomyChecks()
        let source = try! String(contentsOfFile: "Sources/ContentView.swift")
        let domains = WorkspaceCategoryStyle.groups.flatMap { $0.1 }.filter { $0 != "macOS Settings" }
        let rows = domains.map { DisplayCategory(id: $0, title: $0, symbol: "", items: []) }
        let sections = WorkspaceCategoryStyle.sections(rows.reversed())
        precondition(sections.map(\.title) == ["Applications & Tools", "Settings", "Git", "SSH Configuration", "Workspace", "Shell"])
        precondition(sections.first { $0.title == "Git" }!.rows.map(\.id) == ["git-configuration"])
        precondition(sections.first { $0.title == "Workspace" }!.rows.map(\.id) == ["workspace-folders", "git-repositories", "vscode-workspaces"])
        precondition(Set(sections.flatMap(\.rows).map(\.id)) == Set(rows.map(\.id)))
        for id in domains {
            precondition(RestoreRowIcon.symbol(for: id) == WorkspaceCategoryStyle.symbol(id))
            precondition(NSImage(systemSymbolName: WorkspaceCategoryStyle.symbol(id), accessibilityDescription: nil) != nil)
        }
        let records = try! String(contentsOfFile: "../../modules/settings/macos/records.sh")
        let definitions = records.components(separatedBy: "cat <<'MACOS_SETTINGS'\n")[1].components(separatedBy: "\nMACOS_SETTINGS")[0]
        for line in definitions.split(separator: "\n") {
            let fields = line.split(separator: "|").map(String.init)
            precondition(WorkspaceSettingLabels.title(domain: "macos-" + fields[0], identity: fields[1] + "/" + fields[2]) == fields[4])
        }
        precondition(WorkspaceSettingLabels.title(domain: "macos-dock", identity: "NSGlobalDomain/tilesize") == nil)
        precondition(WorkspaceSettingLabels.title(domain: "macos-finder", identity: "com.apple.finder/unknown") == nil)
        precondition(source.contains("WorkspaceCircleIcon(symbol: symbol, tint: tint, size: 44)"))
        precondition(source.contains(".padding(12)") && source.contains("tint.opacity(0.06)") && source.contains("cornerRadius: 8"))
        let status = try! String(contentsOfFile: "Sources/EnvironmentStatusView.swift")
        precondition(status.contains("WorkspaceSectionHeader(title: section.id)") && status.contains("WorkspaceMetricCard(title: outcome.title"))
        // Selection accordions coexist with static workflow section headings.
        for path in ["RestoreView.swift", "TaskComponents.swift"] {
            let view = try! String(contentsOfFile: "Sources/" + path)
            precondition(view.contains("WorkspaceSectionHeader(") && view.contains("WorkspaceCardSurface()"))
        }
        let capture = try! String(contentsOfFile: "Sources/CaptureView.swift")
        precondition(capture.contains("CaptureGroupedContent(rows: rows") && capture.contains("captureHierarchy: true"))
        let capturePresentation = try! String(contentsOfFile: "Sources/CapturePresentation.swift")
        precondition(capturePresentation.contains("CaptureGroupHeader(title: CaptureHierarchy.sectionTitle") && capturePresentation.contains("WorkspaceCardSurface()"))
        precondition(capturePresentation.contains("CaptureGroupHeader(title: \"VS Code\"") && capturePresentation.contains("CaptureRowColumns(title: title, status: status)"))
        let review = capture.components(separatedBy: "case .review:")[1].components(separatedBy: "case .confirmation:")[0]
        let globalHeading = review.components(separatedBy: "WorkflowList {")[0]
        precondition(!globalHeading.contains("Controls(") && !globalHeading.contains("Button("))
        precondition(review.contains("secureTransferGroup: AnyView(CaptureSecureTransferView("))
        let grouping = capturePresentation.components(separatedBy: "struct CaptureGroupedContent<")[1].components(separatedBy: "struct CaptureTaskPresentation")[0]
        precondition(grouping.components(separatedBy: "WorkspaceCardSurface()").count - 1 == 2)
        precondition(grouping.contains("capture.container.ordinary") && grouping.contains("capture.container.experienced"))
        precondition(grouping.contains("CaptureHierarchy.ordinaryGroups") && !capturePresentation.contains("Compatibility & Dependencies"))
        precondition(!capturePresentation.contains("compatibilityID"))
        precondition(grouping.contains("members(rows)") && !grouping.contains("NativeSelectionCheckbox"))
        precondition(grouping.contains("CaptureGroupHeader(title: group.title") && grouping.contains("if expanded.contains(group.id)"))
        precondition(grouping.contains("tint: advancedTint, titleTint: advancedTint") && grouping.contains("DeveloperSelectionGroup.accent(colorScheme)"))
        precondition(WorkspacePresentationTaxonomy.Group.advanced.domains == ["git-configuration", "git-repositories", "workspace-folders", "ssh-configuration", "shell-zsh", "vscode-workspaces"])
        let secure = capturePresentation.components(separatedBy: "struct CaptureSecureTransferView:")[1].components(separatedBy: "extension SelectionState")[0]
        precondition(secure.contains(".disclosureGroupStyle(SelectionCategoryDisclosureStyle())") && secure.contains("Color.clear.frame(width: 28, height: 28)"))
        precondition(secure.contains("DisclosureGroup(isExpanded: expansion ?? $expanded)"))
        precondition(secure.contains("if inventory.items.isEmpty { return \"Unavailable\" }") && secure.contains("ForEach(inventory.items)")
            && secure.contains("NativeSelectionCheckbox") && !secure.contains("Divider()"))
        let header = capturePresentation.components(separatedBy: "struct CaptureGroupHeader:")[1].components(separatedBy: "struct CaptureGroupedContent<")[0]
        precondition(header.contains("CaptureAccordionStyle(selection: selection,")
            && header.contains("selectionLeadingInset: nested ? CaptureReviewPresentation.hierarchyStep : 0)")
            && !header.contains("NativeSelectionCheckbox"))
        precondition(header.contains("var tint: Color = .blue"), "Ordinary sections and nested VS Code use the native blue accent")
        precondition(!capture.contains("var categoryExpansion: Binding<Bool>"))
        let restore = try! String(contentsOfFile: "Sources/RestoreView.swift")
        precondition(!restore.contains("struct RestoreHeaderDisclosureStyle") && !restore.contains("struct RestoreSectionHeader"))
        let area = restore.components(separatedBy: "struct RestoreAreaSelectionView:")[1].components(separatedBy: "struct RestorePresentationSection:")[0]
        // Include the binding, content and label, stopping at the disclosure's
        // own style modifier before the adjacent item-selection controls.
        guard let disclosureStart = area.range(of: "DisclosureGroup(isExpanded:"),
              let disclosureEnd = area.range(of: ".disclosureGroupStyle(", range: disclosureStart.upperBound..<area.endIndex) else {
            preconditionFailure("Restore area disclosure boundaries are missing")
        }
        let disclosure = String(area[disclosureStart.lowerBound..<disclosureEnd.lowerBound])
        precondition(!disclosure.contains("model.selectArea") && !disclosure.contains("model.selectItem"))
        let nested = restore.components(separatedBy: "struct RestoreMacOSAreaDetails:")[1].components(separatedBy: "enum RestoreStatusTone:")[0]
        // Included settings are read-only labels; Core's domain/item selection
        // remains in the surrounding Review controls, not these details.
        precondition(nested.contains("ForEach(area.items) { item in Text(item.label) }"))
        precondition(!nested.contains("NativeSelectionCheckbox") && !nested.contains("Toggle("))
        precondition(!nested.contains("model.selectArea") && !nested.contains("model.selectItem"))
        print("PASS: Unified group order, domain identity, exact setting labels, blue SF Symbols, shared card geometry and independent disclosure/selection")
    }

    @MainActor static func finalCorrectionChecks() {
        func captureRow(_ domain: String, reason: String? = nil) -> CoreCaptureInventoryRow {
            let data = try! JSONSerialization.data(withJSONObject: ["domain": domain, "status": "present", "selection_mode": "category",
                "reason": reason as Any? ?? NSNull(), "items": []])
            return try! JSONDecoder().decode(CoreCaptureInventoryRow.self, from: data)
        }
        let ssh = CaptureCategory(row: captureRow("ssh-configuration", reason: "source_partial"))
        let duplicate = CaptureReviewDiagnostics.repeatedNoticeIDs(ssh)
        precondition(duplicate == ["category-warning:ssh-configuration"])
        precondition(ssh.display.items[0].reason == "source_partial" && ssh.notices[0].reason == "source_partial")
        precondition(ssh.display.items.filter { $0.reason != nil }.count + ssh.notices.filter { $0.reason != nil && !duplicate.contains($0.id) }.count == 1)
        let selection = CoreCaptureSelection(categories: [ssh.id], items: [:], secureIdentities: [])
        let confirmed = CaptureTaskPresentation(categories: [ssh], selection: selection, phase: .confirmation)
        precondition(confirmed.domains.flatMap(\.items).filter { $0.item.reason == "source_partial" }.count == 1)
        let publicationData = try! JSONSerialization.data(withJSONObject: ["publication_occurred": true, "destination": "/private/tmp/saved.mbt",
            "prepared_capture_id": String(repeating: "a", count: 64), "bundle": ["format_version": 1, "selected_categories": [ssh.id], "selected_item_counts": [:], "secure_component": false]])
        let publication = try! JSONDecoder().decode(CoreCapturePublication.self, from: publicationData)
        let saved = CaptureTaskPresentation(categories: [ssh], selection: selection, phase: .result, publication: publication,
            notices: [.init(id: ssh.id, title: ssh.title, symbol: ssh.symbol, items: ssh.notices)])
        precondition(saved.domains.flatMap(\.items).filter { $0.item.reason == "source_partial" }.count == 1)
        let independent = DisplayItem(id: "independent-ssh-warning", title: "Warning", status: .attention, action: "Keep this evidence", reason: "target_conflict")
        let withIndependent = CaptureTaskPresentation(categories: [ssh], selection: selection, phase: .result, publication: publication,
            notices: [.init(id: ssh.id, title: ssh.title, symbol: ssh.symbol, items: ssh.notices + [independent])])
        precondition(withIndependent.domains.flatMap(\.items).filter { $0.item.reason != nil }.count == 2)
        let categories = CaptureMacOSSettingsGroup.domainIDs.map { CaptureCategory(row: captureRow($0)) }
        let chosen = CoreCaptureSelection(categories: categories.map(\.id), items: [:], secureIdentities: [])
        let tasks = CaptureTaskPresentation(categories: categories, selection: chosen, phase: .confirmation)
        let children = CaptureSettingsPresentation.children(tasks.domains)
        let labels = Dictionary(uniqueKeysWithValues: categories.map { category in
            (category.id, WorkspaceSettingLabels.names.filter { $0.key.hasPrefix(category.id + ":") }.sorted { $0.key < $1.key }.map(\.value))
        })
        precondition(children.map(\.id) == CaptureMacOSSettingsGroup.domainIDs && labels.values.reduce(0) { $0 + $1.count } == WorkspaceSettingLabels.names.count)
        let taskSource = try! String(contentsOfFile: "Sources/TaskComponents.swift")
        precondition(taskSource.contains("if compactReadyItems {\n                    CaptureIncludedSettingsList(labels: settingLabels)"))
        let restoreSource = try! String(contentsOfFile: "Sources/RestoreView.swift")
        let selectionSource = restoreSource.components(separatedBy: "struct RestoreAreaSelectionView:")[1].components(separatedBy: "enum RestoreStatusTone:")[0]
        precondition(!selectionSource.contains("Individual settings are not separately selectable"))
        for domain in ["vscode-settings", "ssh-configuration", "macos-finder"] {
            let area = CoreRestoreInspection.Area(domain: domain, label: domain, selectionMode: "category", availability: "available", reason: nil, items: [])
            precondition(!RestoreAreaSelectionView.hasDisclosure(area) && !RestoreMacOSAreaDetails.hasDetails(area))
            for code in ["target_conflict", "source_partial", "authorization_required"] {
                let warning = CoreRestoreInspection.Area(domain: domain, label: domain, selectionMode: "category", availability: "available", reason: code, items: [])
                precondition(RestoreMacOSAreaDetails.hasDetails(warning) && warning.reason == code)
                let notices = RestoreAreaSelectionView.notices(warning)
                precondition(notices.count == 1 && notices[0].reason == code && notices[0].status == .attention && notices[0].title == "Needs Attention")
            }
        }
        precondition(restoreSource.contains("Discard Current Rebuild Selection?") && restoreSource.contains("Keep Selection") && restoreSource.contains("Discard and Cancel"))
        if CommandLine.arguments.contains("--no-renders") {
            print("PASS: Addressed diagnostics, compact Capture settings, meaningful Restore disclosures and warning preservation")
            return
        }
        // Exactly two native renders here; the Review/Cancel harness renders Restore once.
        func render<V: View>(_ view: V, name: String, width: Int, height: Int) {
            _ = NSApplication.shared
            NSApp.appearance = NSAppearance(named: .aqua)
            let root = view.padding(28).frame(width: CGFloat(width), height: CGFloat(height), alignment: .topLeading)
                .background(Color(nsColor: .windowBackgroundColor))
            let host = NSHostingView(rootView: root)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; host.frame = window.contentView!.bounds
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/Debug/FinalCorrections-\(name).png"))
            window.close()
        }
        let model = CaptureModel(runtime: CoreRuntime())
        render(VStack(alignment: .leading, spacing: 20) {
            Text("Capture — SSH Configuration").font(.headline)
            CaptureCategorySelectionView(model: model, category: ssh, expansion: .constant(true)).modifier(WorkspaceCardSurface())
        }, name: "Capture-SSH", width: 785, height: 360)
        render(HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Save this environment?").font(.headline)
                ForEach(children) { child in
                    TaskSettingsCategoryDetails(domain: child, stateTitles: [.planned: "Ready to Save"], compactReadyItems: true,
                        settingLabels: labels[child.id]!, expansion: .constant(true))
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("Environment Saved").font(.headline)
                ForEach(children) { child in
                    let completed = TaskDomainPresentation(id: child.id, title: child.title, symbol: child.symbol,
                        items: child.items.map { TaskItemPresentation(id: $0.id, item: $0.item, state: .completed, captureRole: $0.captureRole) })
                    TaskSettingsCategoryDetails(domain: completed, stateTitles: [:], compactReadyItems: true,
                        settingLabels: labels[child.id]!, expansion: .constant(true))
                }
            }
        }, name: "Capture-macOS-Settings", width: 1200, height: 1400)
        print("PASS: Addressed SSH diagnostics, compact Capture settings, meaningful Restore disclosures and Review-only Cancel wiring; two native renders")
    }

    @MainActor static func restoreMacOSChecks() async {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        NSApp.appearance = NSAppearance(named: .aqua)
        let match = TaskItemPresentation(id: "match", item: DisplayItem(id: "match", title: "Show extensions", status: .matching, action: "Already Matches"), state: .matching)
        precondition(RestoreSettingPreviewLeaf(item: match, title: match.item.title).compactMatch)
        for state in [TaskRowState.unverified, .attention, .failed, .planned] {
            let issue = TaskItemPresentation(id: "issue", item: DisplayItem(id: "issue", title: "Setting", status: .information, action: "Reported issue", reason: "retained reason"), state: state)
            precondition(!RestoreSettingPreviewLeaf(item: issue, title: issue.item.title).compactMatch)
        }
        let issue = TaskItemPresentation(id: "issue", item: DisplayItem(id: "issue", title: "Show hidden files", status: .attention, action: "Inspection unavailable", reason: "Observation failed"), state: .unverified)
        let planned = TaskItemPresentation(id: "planned", item: DisplayItem(id: "planned", title: "Install or update", status: .ready, action: ""), state: .planned)
        let finder = TaskDomainPresentation(id: "macos-finder", title: "Finder", symbol: "finder", items: [match, planned, issue], previewOnly: true)
        let dock = TaskDomainPresentation(id: "macos-dock", title: "Dock", symbol: "dock.rectangle", items: [match], previewOnly: true)
        let parent = TaskDomainPresentation(id: "macos-settings", title: "macOS Settings", symbol: "slider.horizontal.3", items: finder.items + dock.items, previewOnly: true)
        let applicationDomains = ["homebrew-casks", "homebrew-packages", "vscode-extensions", "git-configuration", "workspace-folders"].map { id in
            TaskDomainPresentation(id: id, title: CaptureCategory.title(for: id), symbol: WorkspaceCategoryStyle.symbol(id),
                items: id == "homebrew-casks" ? [match, planned] : [match], previewOnly: true)
        }
        let samples = [RestoreTrailingSample(title: "Already Matches", counts: [("Match", 1)]), RestoreTrailingSample(title: "Changes Planned")]
        func bitmap<V: View>(_ view: V, width: CGFloat) -> NSBitmapImageRep {
            let renderer = ImageRenderer(content: view.frame(width: width).environment(\.restoreTrailingSamples, samples))
            renderer.scale = 1
            return NSBitmapImageRep(cgImage: renderer.cgImage!)
        }
        func greenBounds(_ bitmap: NSBitmapImageRep) -> CGRect {
            var points: [CGPoint] = []
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.5 else { continue }
                    if c.greenComponent > c.redComponent * 1.3 && c.greenComponent > c.blueComponent * 1.2 {
                        points.append(CGPoint(x: x, y: y))
                    }
                }
            }
            precondition(!points.isEmpty)
            return CGRect(x: points.map(\.x).min()!, y: points.map(\.y).min()!,
                width: points.map(\.x).max()! - points.map(\.x).min()! + 1,
                height: points.map(\.y).max()! - points.map(\.y).min()! + 1)
        }
        for width: CGFloat in [721, 921] {
            let leaves = applicationDomains.map { domain in
                greenBounds(bitmap(TaskDomainItems(domain: TaskDomainPresentation(id: domain.id, title: domain.title,
                    symbol: domain.symbol, items: [match]), restorePreview: true), width: width))
            } + [finder, dock].map { _ in
                greenBounds(bitmap(RestoreSettingPreviewLeaf(item: match, title: match.item.title), width: width))
            }
            precondition(leaves.allSatisfy { $0.width <= TaskRowLayout.iconWidth && $0.height <= TaskRowLayout.iconWidth },
                "Every matching leaf must show only the Status checkmark, without green status text")
            precondition(leaves.allSatisfy { $0.minX == leaves[0].minX && $0.size == leaves[0].size },
                "Applications and Finder/Dock must share the icon geometry and status column")
            let statusMatch = greenBounds(bitmap(EnvironmentComparisonItem(item: match.item), width: width))
            precondition(leaves.allSatisfy { $0.size == statusMatch.size }, "Preview must retain the existing Status checkmark size")
            let category = greenBounds(bitmap(RestorePreviewRow(title: Text("Category"),
                status: RestorePreviewCategoryStatus(domain: dock, stateTitles: [:])), width: width))
            precondition(abs(category.minX - leaves[0].minX) <= 2 && category.width > 60, "Category Already Matches remains textual")
            let content = TaskDomainList(domains: applicationDomains + [parent], restoreSettingsPreview: true,
                settingsCategories: [finder, dock], expansion: .constant(Set(applicationDomains.map(\.id) + [parent.id, finder.id, dock.id])))
            let image = bitmap(content.padding(16).background(Color(nsColor: .windowBackgroundColor)), width: width)
            try! image.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/Debug/Restore-Compact-Matches-\(Int(width)).png"))
            let controller = NSHostingController(rootView: content.environment(\.workflowListViewport, true))
            controller.sizingOptions = []
            let host = controller.view
            let window = NSWindow(contentViewController: controller)
            window.isReleasedWhenClosed = false; window.setContentSize(CGSize(width: width, height: 300)); window.makeKeyAndOrderFront(nil)
            func settle() async { try? await Task.sleep(for: .milliseconds(40)); host.layoutSubtreeIfNeeded() }
            func scrollViews(_ view: NSView) -> [NSScrollView] { (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews) }
            await settle()
            let scrolls = scrollViews(host)
            precondition(scrolls.count == 1)
            let scroll = scrolls[0]
            let end = scroll.documentView!.frame.height - scroll.contentView.bounds.height
            precondition(end > 0)
            // This presentation check verifies scroll range without requiring
            // input delivery to a key window (unavailable under the system shield).
            for y in [end, CGFloat(0)] {
                scroll.contentView.scroll(to: CGPoint(x: 0, y: y))
                scroll.reflectScrolledClipView(scroll.contentView)
                await settle()
                precondition(abs(scroll.contentView.bounds.minY - y) < 2, "Preview scroll range must remain accessible")
            }
            window.close()
        }
        let statusSource = try! String(contentsOfFile: "Sources/TaskComponents.swift").components(separatedBy: "struct TaskStatusLabel: View")[1].components(separatedBy: "struct OperationMetric:")[0]
        precondition(statusSource.contains(".accessibilityLabel(title ?? state.rawValue)"))
        let sharedSource = try! String(contentsOfFile: "Sources/TaskComponents.swift").components(separatedBy: "struct MatchedLeafIndicator: View")[1].components(separatedBy: "struct TaskStatusLabel:")[0]
        precondition(sharedSource.contains("Image(systemName: \"checkmark\")") && sharedSource.contains(".accessibilityLabel(\"Already Matches\")"))
        let reference = Image(systemName: "checkmark").foregroundStyle(EnvironmentComparisonPalette.color(for: .matching))
            .accessibilityLabel("Already Matches")
        precondition(bitmap(MatchedLeafIndicator(), width: 40).representation(using: .png, properties: [:])
            == bitmap(reference, width: 40).representation(using: .png, properties: [:]), "The shared glyph must preserve the original Status appearance")
        let statusCategory = DisplayCategory(id: "homebrew-packages", title: "Homebrew Packages", symbol: "shippingbox", items: [match.item])
        let statusImage = bitmap(EnvironmentComparisonDomain(category: statusCategory, counts: [.match: 1], expansion: .constant(true))
            .padding(16).background(Color(nsColor: .windowBackgroundColor)), width: 721)
        try! statusImage.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/Debug/Status-Matched-Leaves.png"))
        precondition(TaskRowState.matching.rawValue == "Already Matches" && TaskRowState.matching.symbol == "checkmark.circle.fill")
        precondition(ImageRenderer(content: TaskStatusLabel(state: .planned)).cgImage!.width > 80)
        print("PASS: Status-style matched leaves across Preview apps/packages/extensions/Finder/Dock/Git/Workspace; textual category/planned states, accessibility and native scroll range at 721/921pt")
    }

    @MainActor static func finalUIAlignmentChecks() {
        func category(_ domain: String, reason: String? = nil, included: Bool = false) -> CaptureCategory {
            var row: [String: Any] = ["domain": domain, "status": "present", "selection_mode": "category", "items": []]
            if let reason { row["reason"] = reason }
            if included { row["included_settings"] = [["id": "verified-setting", "label": "Verified setting"]] }
            return CaptureCategory(row: try! JSONDecoder().decode(CoreCaptureInventoryRow.self, from: JSONSerialization.data(withJSONObject: row)))
        }
        let vscode = category("vscode-settings")
        precondition(!CaptureCategorySelectionView.hasDisclosure(vscode))
        precondition(vscode.selectable && vscode.row.selectionMode == "category" && vscode.headerSummary == "Whole category")
        precondition(CaptureCategorySelectionView.hasDisclosure(category("vscode-settings", reason: "observation_issue")))
        precondition(CaptureCategorySelectionView.hasDisclosure(category("vscode-settings", included: true)))
        precondition(CaptureCategorySelectionView.hasDisclosure(category("git-configuration")))
        let match = TaskItemPresentation(id: "match", item: DisplayItem(id: "match", title: "Show extensions", status: .matching, action: "Already Matches"), state: .matching)
        precondition(RestoreSettingPreviewLeaf(item: match, title: match.item.title).compactMatch)
        let attention = TaskItemPresentation(id: "attention", item: DisplayItem(id: "attention", title: "Application", status: .attention, action: "Review prerequisite", reason: "Existing diagnostic"), state: .attention)
        precondition(!RestoreSettingPreviewLeaf(item: attention, title: attention.item.title).compactMatch)
        let children = CaptureMacOSSettingsGroup.domainIDs.enumerated().map { index, id in
            let item = TaskItemPresentation(id: "setting-\(index)", item: DisplayItem(id: "setting-\(index)", title: index == 0 ? "Show extensions" : "Supported preference", status: .matching, action: "Already Matches"), state: .matching)
            return TaskDomainPresentation(id: id, title: CaptureCategory.title(for: id), symbol: WorkspaceCategoryStyle.symbol(id), items: [item], previewOnly: true)
        }
        let domains = [TaskDomainPresentation(id: "homebrew-casks", title: "Homebrew Applications", symbol: "app", items: [attention], previewOnly: true),
            TaskDomainPresentation(id: "homebrew-packages", title: "Homebrew Packages", symbol: "shippingbox", items: [match], previewOnly: true),
            TaskDomainPresentation(id: "macOS Settings", title: "macOS Settings", symbol: "slider.horizontal.3", items: children.flatMap(\.items), previewOnly: true)]
        func preview(_ width: CGFloat) -> some View {
            TaskDomainList(domains: domains, restoreSettingsPreview: true, settingsCategories: children,
                expansion: .constant(["macOS Settings"]), settingsExpansion: .constant(true)).frame(width: width)
        }
        func render<V: View>(_ view: V, name: String, width: Int, height: Int) {
            _ = NSApplication.shared; NSApp.appearance = NSAppearance(named: .aqua)
            let content = view.padding(28).frame(width: CGFloat(width), height: CGFloat(height), alignment: .topLeading)
                .background(Color(nsColor: .windowBackgroundColor))
            let host = NSHostingView(rootView: content)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; host.frame = window.contentView!.bounds
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/Debug/FinalUI-" + name + ".png"))
            window.close()
        }
        render(HStack(alignment: .top, spacing: 24) { preview(729); preview(344) }, name: "Restore-Preview", width: 1153, height: 1280)
        if CommandLine.arguments.contains("--restore-render-only") { print("PASS: Restore wide/narrow alignment render"); return }
        let model = CaptureModel(runtime: CoreRuntime())
        render(VStack(alignment: .leading, spacing: 20) {
            Text("Capture — Review and Select").font(.headline)
            CaptureCategorySelectionView(model: model, category: vscode, expansion: .constant(true)).modifier(WorkspaceCardSurface())
            CaptureCategorySelectionView(model: model, category: category("git-configuration"), expansion: .constant(true)).modifier(WorkspaceCardSurface())
        }, name: "Capture-Review", width: 785, height: 350)
        print("PASS: Aligned Restore status columns at wide/narrow widths, compact match leaves, VS Code placeholder-only disclosure removed, real details preserved; two native renders")
    }

    @MainActor static func executionVisualChecks() {
        func domain(_ id: String, state: TaskRowState) -> TaskDomainPresentation {
            let item = TaskItemPresentation(id: id + ":item", item: DisplayItem(id: id + ":item", title: id,
                status: .information, action: "Existing result", reason: id == "ssh-configuration" ? "source_partial" : nil), state: state)
            return TaskDomainPresentation(id: id, title: id == "macOS Settings" ? id : CaptureCategory.title(for: id),
                symbol: "folder", items: [item], activityState: state, confirmedFinalState: [.completed, .matching, .unverified, .notRun].contains(state) ? state : nil)
        }
        let ids = ["git-repositories", "ssh-configuration", "git-configuration", "macOS Settings", "homebrew-packages", "homebrew-casks", "workspace-folders"]
        let rows = ids.map { domain($0, state: .unverified) }
        let ordered = RestoreExecutionCategories.orderedRows(rows)
        precondition(ordered.map(\.id) == ["homebrew-casks", "homebrew-packages", "macOS Settings",
            "git-configuration", "git-repositories", "workspace-folders", "ssh-configuration"])
        precondition(Set(ordered.map(\.id)) == Set(ids))
        precondition(ordered.allSatisfy { $0.executionStatus == .unverified && $0.executionStatus.tone == .warning })
        for state in [TaskRowState.working, .completed, .attention, .unverified, .notRun, .failed] {
            let original = ids.map { domain($0, state: state) }
            let reordered = RestoreExecutionCategories.orderedRows(original)
            for row in original {
                let after = reordered.first { $0.id == row.id }!
                precondition(after.executionStatus == row.executionStatus && after.executionMessages == row.executionMessages)
                precondition(after.items.map(\.id) == row.items.map(\.id) && after.items.first!.item.reason == row.items.first!.item.reason)
                precondition(WorkspaceCategoryStyle.symbol(row.id) == RestoreRowIcon.symbol(for: row.id))
            }
        }
        let unknown = domain("future-core-group", state: .unverified)
        let withUnknown = RestoreExecutionCategories.orderedRows([rows[0], unknown, rows[1]])
        precondition(withUnknown.map(\.id) == [rows[0].id, rows[1].id, unknown.id])
        precondition(withUnknown.last?.title == unknown.title && withUnknown.last?.items.first?.item == unknown.items.first?.item)
        func render<V: View>(_ view: V, name: String) {
            _ = NSApplication.shared; NSApp.appearance = NSAppearance(named: .aqua)
            let content = view.padding(28).frame(width: 785, height: 1000, alignment: .topLeading)
                .background(Color(nsColor: .windowBackgroundColor))
            let host = NSHostingView(rootView: content)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 785, height: 1000), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; host.frame = window.contentView!.bounds
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/Debug/ExecutionVisual-" + name + ".png"))
            window.close()
        }
        render(VStack(alignment: .leading, spacing: 20) {
            Text("Rebuilding this Mac").font(.title.weight(.bold))
            HStack(spacing: 12) { ProgressView(); Text("Applying selected configuration…").foregroundStyle(.secondary) }
            RestoreExecutionCategories(domains: ids.enumerated().map { domain($0.element, state: $0.offset == 5 ? .working : .waiting) })
            RestoreRebuildActions()
        }, name: "Rebuilding")
        render(VStack(alignment: .leading, spacing: 20) {
            Text("Rebuild Needs Attention").font(.title.weight(.bold))
            RestoreVerificationResult(outcome: .attention, payload: ["verification": .object(["status": .string("complete"),
                "verified_count": .integer(2), "mismatch_count": .integer(1), "unverified_count": .integer(4), "unresolved_count": .integer(0)])])
            RestoreExecutionCategories(domains: ids.enumerated().map { domain($0.element, state: $0.offset == 5 ? .attention : .unverified) }, showsWarnings: false)
        }, name: "Needs-Attention")
        print("PASS: flat Execution/Result order and shared icon mapping; all rows, statuses, warning colors, diagnostics and unknown findings preserved; two native renders")
    }

    @MainActor static func neutralUnverifiedChecks() {
        let label = RestoreResultStatusLabel(state: .unverified)
        precondition(label.symbol == "questionmark.circle" && label.tone == .neutral)
        precondition(TaskRowState.unverified.tone == .warning && TaskRowState.unverified.symbol == "exclamationmark.triangle.fill")
        for state in TaskRowState.allCases where state != .unverified {
            let label = RestoreResultStatusLabel(state: state)
            precondition(label.symbol == state.symbol && label.tone == state.tone)
        }
        precondition(RestoreResultStatusLabel(state: .attention).tone == .warning)
        precondition(RestoreResultStatusLabel(state: .completed).tone == .success && RestoreResultStatusLabel(state: .matching).tone == .success)
        let domains = ["homebrew-casks", "homebrew-packages", "macOS Settings", "ssh-configuration"].enumerated().map { index, id in
            let state: TaskRowState = index == 0 ? .attention : .unverified
            return TaskDomainPresentation(id: id, title: id == "macOS Settings" ? id : CaptureCategory.title(for: id), symbol: "folder",
                items: [TaskItemPresentation(id: id + ":item", item: DisplayItem(id: id + ":item", title: id, status: .information, action: "Existing result"), state: state)], confirmedFinalState: state)
        }
        precondition(domains[1].executionStatus == .unverified)
        let source = try! String(contentsOfFile: "Sources/RestoreView.swift")
        precondition(source.contains("RestoreExecutionCategories(domains: domains, showsWarnings: false, resultStatuses: true,"))
        _ = NSApplication.shared; NSApp.appearance = NSAppearance(named: .aqua)
        let content = VStack(alignment: .leading, spacing: 20) {
            Text("Rebuild Cancelled").font(.title.weight(.bold))
            RestoreVerificationResult(outcome: .stoppedAfterMutation, payload: ["verification": .object(["status": .string("not_run")])])
                .fixedSize(horizontal: false, vertical: true)
            RestoreExecutionCategories(domains: domains, showsWarnings: false, resultStatuses: true)
        }.padding(28).frame(width: 785, height: 850, alignment: .topLeading).background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 785, height: 850), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; host.frame = window.contentView!.bounds
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/Debug/Neutral-Unverified-Rebuild-Cancelled.png"))
        window.close()
        print("PASS: Result-only neutral Unverified/questionmark.circle; other colors/symbols and global Unverified unchanged; one Rebuild Cancelled render")
    }

    @MainActor static func summaryMetricVisibilityChecks() async throws {
        _ = NSApplication.shared; NSApp.appearance = NSAppearance(named: .aqua)
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("macseed-summary-metrics-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: fixture) }
        for folder in ["modules/core/application-interface", "config", "home", "tmp"] {
            try FileManager.default.createDirectory(at: fixture.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        for file in ["bootstrap.sh", "config/toolkit.conf", "modules/core/application-interface/core.py"] {
            try Data().write(to: fixture.appendingPathComponent(file))
        }
        // An isolated JSON emitter exercises the production result projection; no Rebuild runs.
        try "#!/bin/bash\nexec /usr/bin/python3 -B fixture.py\n".write(to: fixture.appendingPathComponent("modules/core/application-interface/core.sh"), atomically: true, encoding: .utf8)
        try """
        import json, sys
        from pathlib import Path
        request=json.load(sys.stdin)
        payload=json.loads(Path('payload.json').read_text())
        for sequence,(kind,data) in enumerate([('started',{}),('result',payload),('completed',{})],1):
            print(json.dumps(dict(protocol_version=1,operation_id=request['operation_id'],sequence=sequence,type=kind,data=data)),flush=True)
        """.write(to: fixture.appendingPathComponent("fixture.py"), atomically: true, encoding: .utf8)
        let planID = String(repeating: "a", count: 64)
        // Complete authoritative Verification, without retained per-command diagnostics.
        let payload: [String: CoreJSON] = ["prepared_plan_id": .string(planID), "execution_status": .string("completed"),
            "target_mutation_may_have_started": .bool(true), "unknown_consequences": .bool(false),
            "warning_count": .integer(0), "error_count": .integer(0),
            "verification": .object(["status": .string("complete"), "verdict": .string("selected_requirements_verified"),
                "verified_count": .integer(132), "mismatch_count": .integer(0), "unverified_count": .integer(0),
                "unresolved_count": .integer(0), "warning_count": .integer(0), "error_count": .integer(0)])]
        try JSONEncoder().encode(payload).write(to: fixture.appendingPathComponent("payload.json"))
        let runtime = CoreRuntime(operationLogs: nil)
        runtime.start(CoreRequest(.restoreExecute(path: fixture.appendingPathComponent("sample.mbt").path,
            disabledGroups: [], includeSecure: false, preparedID: planID, selection: .init(categories: ["git-repositories"], items: [:]))),
            location: .init(root: fixture, python: URL(fileURLWithPath: "/usr/bin/python3"), home: fixture.appendingPathComponent("home"),
                temporaryBase: fixture.appendingPathComponent("tmp"), toolDirectories: []))
        await runtime.waitForCompletion()
        precondition(runtime.state == .completed)
        let result = RestoreExecutionPresentation(runtime: runtime, payload: payload, expectedID: planID)
        precondition(result.outcome == .clean && result.findings.isEmpty)
        let rows = (1...9).map { index in
            TaskItemPresentation(id: "repository-\(index)", item: DisplayItem(id: "repository-\(index)", title: "Repository \(index)", status: .ready, action: "Clone"),
                state: .completed, executionAction: "Clone", resultLabels: ["Applied", "Verified"])
        }
        let domains = [TaskDomainPresentation(id: "git-repositories", title: "Git Repositories", symbol: "folder", items: rows)]
        let clean = RestoreResultSummary(domains: domains, result: result, appStore: nil)
        precondition(clean.verifiedRestorationCount == 9 && RestoreVerificationSummary(payload: payload).verified == 132)
        precondition(clean.attentionCount == 0 && clean.issues.isEmpty && clean.attentionCaption.isEmpty)
        precondition(RestoreResultSummaryView(summary: clean, outcome: .clean).attentionExplanation == nil)

        var positive = clean; positive.automaticAttentionCount = 2
        precondition(RestoreResultSummaryView(summary: positive, outcome: .attention).attentionExplanation == "2 rebuild issues")
        var unknown = clean; unknown.automaticAttentionCount = nil
        precondition(RestoreResultSummaryView(summary: unknown, outcome: .interrupted).attentionExplanation == "Rebuild work needs review")
        var uncounted = clean
        uncounted.issues = [.init(id: "scope", title: "Rebuild", message: "The remaining scope is unknown.", nextAction: "Refresh Preview.", count: nil)]
        precondition(uncounted.attentionCaption.isEmpty)
        precondition(RestoreResultSummaryView(summary: uncounted, outcome: .attention).attentionExplanation == "Rebuild work needs review")
        for outcome in [RestoreExecutionPresentation.Outcome.stoppedBeforeMutation, .stoppedAfterMutation, .interrupted] {
            let view = RestoreResultSummaryView(summary: unknown, outcome: outcome, verificationNotRun: true)
            precondition(view.verificationNotRun && RestoreResultSummaryView.completionTitle(outcome) == "Verification" && view.attentionExplanation != nil)
        }
        let matching = TaskItemPresentation(id: "matching", item: DisplayItem(id: "matching", title: "Existing repository", status: .matching, action: "Inspect"),
            state: .completed, resultLabels: ["Already Matches", "Verified"])
        let noChanges = RestoreResultSummary(domains: [.init(id: "git-repositories", title: "Git Repositories", symbol: "folder", items: [matching])], result: result, appStore: nil)
        precondition(noChanges.noChangesRequired && noChanges.verifiedRestorationCount == 0)
        precondition(RestoreResultSummaryView(summary: noChanges, outcome: .clean).attentionExplanation == nil)
        func apps(_ status: AssistedAppStoreItem.Status) -> AppStoreRestorePresentation {
            let row = TaskItemPresentation(id: "app", item: DisplayItem(id: "app", title: "Application", status: .information, action: ""),
                state: .unverified, assistedAppStore: .init(appID: "425264550", status: status))
            return AppStoreRestorePresentation(domains: [.init(id: "app-store", title: "App Store", symbol: "app", items: [row])])
        }
        let installed = apps(.installed), missing = apps(.missing), unchecked = apps(.unverified)
        for (apps, caption) in [(installed, nil), (missing, "1 app to install"), (unchecked, "1 app to check")] {
            let summary = RestoreResultSummary(domains: domains, result: result, appStore: apps)
            precondition(RestoreResultSummaryView(summary: summary, outcome: .clean).attentionExplanation == caption)
        }
        let output = URL(fileURLWithPath: "build/Debug/SummaryMetrics", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        func height<V: View>(_ view: V, width: CGFloat) -> CGFloat {
            // The one-point marker makes an empty production view measurable.
            ImageRenderer(content: VStack(spacing: 0) { view; Color.clear.frame(height: 1) }.frame(width: width)).nsImage!.size.height - 1
        }
        let emptyCapture = CaptureSummaryPresentation(domainCount: 0, itemCount: 0, attentionCount: 0, unsupportedCount: 0)
        let selectedCapture = CaptureSummaryPresentation(domainCount: 1, itemCount: 0, attentionCount: 0, unsupportedCount: 0)
        let attentionCapture = CaptureSummaryPresentation(domainCount: 0, itemCount: 0, attentionCount: 1, unsupportedCount: 0)
        let emptyDomain = TaskDomainPresentation(id: "empty", title: "Empty", symbol: "folder", items: [])
        for width in [CGFloat(420), 785, 985] {
            precondition(height(CaptureReviewMetrics(summary: emptyCapture), width: width) == 0, "No zero-count Capture card or empty row")
            precondition(height(RestorePreviewMetrics(domains: [emptyDomain]), width: width) == 0, "No empty Preview metric row")
            precondition(height(RestorePreviewMetrics(domains: []), width: width) > 0, "Retain the explicit no-selection message")
            for view in [AnyView(CaptureReviewMetrics(summary: selectedCapture)), AnyView(CaptureReviewMetrics(summary: attentionCapture)),
                         AnyView(AppStoreRestoreMetrics(summary: installed)), AnyView(AppStoreRestoreMetrics(summary: unchecked))] {
                precondition(height(view, width: width) == 80, "A single metric uses the existing responsive layout")
            }
            let cleanView = RestoreResultSummaryView(summary: clean, outcome: .clean)
            let attentionView = RestoreResultSummaryView(summary: positive, outcome: .attention)
            precondition(height(attentionView, width: width) - height(cleanView, width: width) == (width < 450 ? 90 : 0),
                "Clean Result removes the second card at narrow and wide widths")
            let content = VStack(alignment: .leading, spacing: 20) {
                cleanView
                attentionView
                RestoreResultSummaryView(summary: unknown, outcome: .stoppedAfterMutation, verificationNotRun: true)
                CaptureReviewMetrics(summary: selectedCapture)
                AppStoreRestoreMetrics(summary: installed)
            }.padding(16).frame(width: width + 32).background(Color(nsColor: .windowBackgroundColor))
            let bitmap = NSBitmapImageRep(cgImage: ImageRenderer(content: content).cgImage!)
            try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("summary-\(Int(width)).png"))
        }
        print("PASS: summary cards at 420/785/985; clean 9 Verified versus 132 predicates; positive/unknown/manual attention; Not Run; empty Capture/Preview rows; retained no-change outcome")
    }

    @MainActor static func minimalResultSummaryChecks() {
        for value in [CoreJSON.null, .integer(0), .integer(-1), .string("2"), .integer(2)] {
            let payload: [String: CoreJSON] = ["verification": .object(["status": .string("incomplete"), "mismatch_count": value, "unverified_count": value])]
            let summary = RestoreVerificationSummary(payload: payload)
            let expected = value.integer.map { $0 > 0 } ?? false
            precondition(RestoreVerificationResult.showsCount(summary.mismatch) == expected)
            precondition(RestoreVerificationResult.showsCount(summary.unverified) == expected)
            precondition(summary.title == "Verification Incomplete" && summary.overallResult(outcome: .attention) == "Incomplete")
        }
        let missingPayloads: [[String: CoreJSON]?] = [nil, [:], ["verification": .object(["status": .string("not_run")])]]
        for payload in missingPayloads {
            let summary = RestoreVerificationSummary(payload: payload)
            precondition(!RestoreVerificationResult.showsCount(summary.mismatch) && !RestoreVerificationResult.showsCount(summary.unverified))
            precondition(summary.overallResult(outcome: .stoppedBeforeMutation) == "Stopped")
        }
        let notRun = RestoreVerificationSummary(payload: ["verification": .object(["status": .string("not_run"), "details": .object(["verification_records": .array([.object(["conformity": .string("unverified")])])])])])
        precondition(notRun.title == "Verification Not Run" && notRun.unverified == nil)
        for (mismatch, unverified) in [(0, 0), (2, 0), (0, 3), (2, 3)] {
            let summary = RestoreVerificationSummary(payload: ["verification": .object(["status": .string("complete"), "verified_count": .integer(4),
                "mismatch_count": .integer(mismatch), "unverified_count": .integer(unverified), "unresolved_count": .integer(1)])])
            precondition(summary.complete && summary.mismatch == mismatch && summary.unverified == unverified && summary.unresolved == 1)
            precondition(RestoreVerificationResult.showsCount(summary.mismatch) == (mismatch > 0) && RestoreVerificationResult.showsCount(summary.unverified) == (unverified > 0))
            precondition(RestoreResultSummary(domains: []).cards.isEmpty, "Global predicates must not create plan-row cards")
        }
        let source = try! String(contentsOfFile: "Sources/RestoreView.swift")
            .components(separatedBy: "struct RestoreVerificationResult: View {")[1].components(separatedBy: "struct RestoreResultContent:")[0]
        precondition(!source.contains("WorkspaceMetricCard(") && !source.contains("Automatic Rebuild outcomes"))
        precondition(!source.contains("Verification mismatches:") && !source.contains("Verification unverified:"))
        precondition(source.contains("Label(summary.title") && source.contains("Some selected scope remains unresolved"))
        precondition(source.contains("summary.requirementsTitle") && !source.contains("summary.overallResult(outcome:"))
        print("PASS: Result always present; only positive Core aggregates visible; missing/null/zero/invalid counts hidden; partial Verification caveats and Unresolved retained; no renders")
    }

    @MainActor static func resultCleanupChecks() {
        precondition(RestoreResultContent.heading(outcome: .attention, original: "Rebuild Completed with Issues", pendingManualWork: true, automaticProblems: false)
            == "Rebuild Completed")
        precondition(RestoreResultContent.heading(outcome: .attention, original: "Rebuild Completed with Issues", pendingManualWork: false)
            == "Rebuild Completed with Issues")
        precondition(RestoreResultSummaryView.completionTitle(.clean) == "Complete"
            && RestoreResultSummaryView.completionTitle(.attention) == "Complete")
        for outcome: RestoreExecutionPresentation.Outcome in [.partial, .failedBeforeMutation, .failedAfterMutation,
                                                               .interrupted, .stoppedBeforeMutation, .stoppedAfterMutation] {
            precondition(RestoreResultSummaryView.completionTitle(outcome) == "Verification")
        }
        // Manual work never replaces failure, partial, interruption or stop headings,
        // nor supplies evidence that automatic work succeeded.
        for outcome: RestoreExecutionPresentation.Outcome in [.clean, .partial, .failedBeforeMutation, .failedAfterMutation,
                                                               .interrupted, .stoppedBeforeMutation, .stoppedAfterMutation] {
            precondition(RestoreResultContent.heading(outcome: outcome, original: "Authoritative outcome", pendingManualWork: true)
                == "Authoritative outcome")
        }
        let source = try! String(contentsOfFile: "Sources/RestoreView.swift")
        let result = source.components(separatedBy: "struct RestoreResultContent:")[1].components(separatedBy: "struct RestorePreviewMetrics:")[0]
        precondition(!result.contains("result.findings") && !result.contains("Text(\"Needs Attention\")"))
        precondition(!result.contains("RestoreVerificationResult(") && !result.contains("Verification details"))
        let sections = ["RestoreResultSummaryView(summary:", "RestoreExecutionCategories(domains:"]
        let positions = sections.map { result.range(of: $0)!.lowerBound }
        precondition(positions == positions.sorted(), "Summary followed directly by grouped details")
        precondition(result.contains("appStore: manual, reviewAppStore: reviewAppStore,")
            && result.contains("RestoreResultDetails.domains(tasks?.automaticDomains") && result.contains("RestoreResultDetails.manual($0.appStore, result: result)"))
        precondition(!result.contains("RestoreRequiresAttention") && !source.contains("Text(\"Requires Attention\")"))
        precondition(!result.contains("App Store Applications — All Installed"))
        let manualResult = source.components(separatedBy: "struct AppStoreRestoreResultRow:")[1].components(separatedBy: "struct RestoreVerificationResult:")[0]
        precondition(manualResult.contains("Button(\"Review App Store Apps\")") && manualResult.contains("summary.attentionCount"))
        precondition(!manualResult.contains("ForEach") && !manualResult.contains("RestoreResultItemRow") && !manualResult.contains("summary.attentionBreakdown"))
        precondition(result.contains("Text(Self.heading(outcome: result.outcome"))
        precondition(!source.contains("Global Verification includes automatic Restore"))
        precondition(!source.contains("Selected environment: "))
        precondition(!source.contains("This Preview includes attention conditions"))
        let preview = source.components(separatedBy: "struct RestorePreviewContent:")[1].components(separatedBy: "struct RestorePreparationActions:")[0]
        precondition(!preview.contains("let message:") && !preview.contains("let counters:"))
        precondition(!source.contains("message: preview.summary"))
        precondition(result.contains("Text(Self.message(result:") && result.contains("RestoreResultActions(result: result, refresh: refresh, done: done, logRuntime: logRuntime)"))
        let selection = source.components(separatedBy: "if model.state == .review {")[1].components(separatedBy: "} else if let prepared")[0]
        precondition(selection.contains("RestoreSelectionContent(model: model"))
        precondition(!selection.contains("automaticAreas") && !selection.contains("toggleAll"))
        precondition(!selection.contains("if let appStore"), "App Store uses the shared group and row exactly once")
        precondition(preview.contains("WorkspaceSectionHeader(title: \"Manual Installation\", prominent: true)"))
        let taskComponents = try! String(contentsOfFile: "Sources/TaskComponents.swift")
        precondition(taskComponents.contains("WorkspaceSectionHeader(title: \"Automatic Rebuild Tasks\", prominent: true)"))
        precondition(!result.contains("DisclosureGroup(\"Technical Details\") {") && !result.contains("isExpanded:"))
        precondition(!result.contains("result.compactTechnicalDetails") && !result.contains("Copy Diagnostic Details") && !result.contains("result.diagnosticReport"))
        let model = try! String(contentsOfFile: "Sources/RestoreModel.swift")
        precondition(model.contains("let findings: [DisplayItem]") && model.contains("findings = outcome == .clean ? [] : normalized.findings"))
        precondition(RestoreResultStatusLabel(state: .unverified).tone == .neutral && RestoreResultStatusLabel(state: .unverified).symbol == "questionmark.circle")
        for state in [TaskRowState.attention, .completed, .matching, .notRun] {
            precondition(RestoreResultStatusLabel(state: state).tone == state.tone && RestoreResultStatusLabel(state: state).symbol == state.symbol)
        }
        print("PASS: Result findings block absent; category statuses, Summary, safety message, diagnostics available through Operation Log; model findings unchanged; no renders")
    }

    @MainActor static func operationLogChecks() {
        let app = try! String(contentsOfFile: "Sources/FoundationSettings.swift", encoding: .utf8)
        let captureView = try! String(contentsOfFile: "Sources/CaptureView.swift", encoding: .utf8)
        let restoreView = try! String(contentsOfFile: "Sources/RestoreView.swift", encoding: .utf8)
        let statusView = try! String(contentsOfFile: "Sources/EnvironmentStatusView.swift", encoding: .utf8)
        let production = try! String(contentsOfFile: "Sources/ProductionWorkspace.swift", encoding: .utf8)
        precondition(app.contains(".tabItem { Label(\"Operation Logs\", systemImage: \"clock\") }")
                     && app.contains("OperationLogWindowController.shared.open(runtime: CoreRuntime.shared, target: nil)")
                     && app.contains(".onChange(of: selectedTab)"))
        precondition(!production.contains("historyOnly: true"), "Global history belongs in Settings, not a duplicate task footer")
        for localView in [captureView, restoreView, statusView] {
            precondition(localView.contains("OperationLogButton(runtime:"), "Each task retains its local View Log")
        }
        let reference: (CoreOperation) -> OperationLogReference = {
            OperationLogReference(id: UUID(), operationID: "fixture", operation: $0, time: Date())
        }
        let captureStates: [CaptureFlowState] = [.idle, .scanning, .review, .preparing, .confirmation, .saving, .result, .failed, .cancelled]
        for state in captureStates {
            let terminal = [.result, .failed, .cancelled].contains(state)
            precondition(OperationLogVisibility.capture(state, active: false, reference: reference(.captureExecute), terminal: true) == terminal)
            precondition(!OperationLogVisibility.capture(state, active: true, reference: reference(.captureExecute), terminal: true))
            precondition(!OperationLogVisibility.capture(state, active: false, reference: nil, terminal: true))
            precondition(!OperationLogVisibility.capture(state, active: false, reference: reference(.restoreExecute), terminal: true))
        }
        precondition(!OperationLogVisibility.capture(.failed, active: false, reference: reference(.capturePrepare), failure: .invalidDestination, terminal: true), "A local preflight failure must not open the preceding scan log")
        let restoreStates: [RestoreFlowState] = [.choose, .inspecting, .preparing, .review, .preview, .confirming, .rebuilding, .result, .failed, .cancelled]
        for state in restoreStates {
            precondition(OperationLogVisibility.restore(state, active: false, reference: reference(.restoreExecute), terminal: true) == (state == .result))
            precondition(!OperationLogVisibility.restore(state, active: true, reference: reference(.restoreExecute), terminal: true))
            for operation in [CoreOperation.bundleInspect, .restorePrepare] {
                let visible = [.failed, .cancelled].contains(state)
                precondition(OperationLogVisibility.restore(state, active: false, reference: reference(operation), terminal: true) == visible)
            }
        }
        for state: RestoreFlowState in [.review, .preview, .confirming] {
            precondition(OperationLogVisibility.restore(state, active: false, reference: reference(.restorePrepare), terminal: true, failedOperation: true))
            precondition(!OperationLogVisibility.restore(state, active: false, reference: reference(.restoreExecute), terminal: true, failedOperation: true))
            precondition(!OperationLogVisibility.restore(state, active: true, reference: reference(.restorePrepare), terminal: true, failedOperation: true))
        }
        for state: EnvironmentStatusState in [.choose, .running, .result, .failed, .cancelled] {
            let terminal = state == .result || state == .failed || state == .cancelled
            precondition(OperationLogVisibility.status(state, active: false, reference: reference(.environmentCompare), terminal: true) == terminal)
            precondition(!OperationLogVisibility.status(state, active: true, reference: reference(.environmentCompare), terminal: true))
            precondition(!OperationLogVisibility.status(state, active: false, reference: nil, terminal: true))
        }
        precondition(captureView.contains("OperationLogVisibility.capture(model.state"))
        precondition(statusView.contains("OperationLogVisibility.status(model.state"))
        precondition(restoreView.contains("OperationLogVisibility.restore(.result") && restoreView.contains("matching: result.operationID") && !restoreView.contains("latestOperationLog("))
        precondition(!OperationLogVisibility.capture(.result, active: false, reference: reference(.captureExecute), terminal: false))
        precondition(!OperationLogVisibility.status(.failed, active: false, reference: reference(.environmentCompare), terminal: false))
        precondition(!OperationLogVisibility.restore(.result, active: false, reference: reference(.restoreExecute), terminal: false))
        let problem = TaskItemPresentation(id: "fixture", item: DisplayItem(id: "fixture", title: "Fixture", status: .attention, action: ""), state: .failed)
        var working = TaskDomainPresentation(id: "homebrew-casks", title: "Applications", symbol: "app", items: [problem], activityState: .working)
        precondition(working.executionStatus == .working && working.executionStatusTitle == "Working · Needs Attention")
        working.activityState = nil
        precondition(working.executionStatus == .attention && working.executionStatusTitle == "Needs Attention")
        print("PASS: shared completed-operation Capture/Restore/Status View Log matrix, exact operation references and direct Settings history")
        print("PASS: Settings owns shared operation history; Capture/Restore/Status retain local View Log without a duplicate footer")
    }

    static func restoreResultSummaryChecks() {
        func item(_ id: String, _ labels: [String], state: TaskRowState = .completed, reason: String? = nil, known: Bool? = nil) -> TaskItemPresentation {
            TaskItemPresentation(id: id, item: DisplayItem(id: id, title: id, status: .information, action: "", reason: reason), state: state, resultLabels: labels, resultEvidenceAvailable: known)
        }
        let fixtures: [(TaskItemPresentation, String?)] = [
            (item("verified", ["Applied", "Verified"]), "Success"),
            (item("applied", ["Applied"]), "Success"),
            (item("matching", ["Already Matches"]), "Success"),
            (item("not-verified", ["Applied", "Unverified"], state: .attention), "Success"),
            (item("mismatch", ["Applied", "Mismatch"]), "Needs Attention"),
            (item("failed", ["Applied", "Failed"], state: .failed), "Needs Attention"),
            (item("unsupported", ["Skipped", "Unsupported"]), "Needs Attention"),
            (item("skip", ["Skipped"], state: .skipped, reason: "not_applicable"), "Skipped"),
            (item("unknown", ["Unverified"], state: .unverified, known: false), nil),
            (item("unverified", ["Unverified"], state: .unverified, known: true), "Needs Attention"),
            (item("waiting", ["Unverified"], state: .waiting), nil)]
        let displayedGroups = ["Success", "Needs Attention", "Needs Attention", "Needs Attention", "Needs Attention", "Needs Attention",
            "Needs Attention", "Skipped", "Needs Attention", "Needs Attention", "Needs Attention"]
        for (index, fixture) in fixtures.enumerated() {
            let (row, expected) = fixture
            precondition(row.resultGroup == expected && RestoreFinalDomain.group(row) == displayedGroups[index])
            let domain = TaskDomainPresentation(id: row.id, title: row.id, symbol: "folder", items: [row])
            let summary = RestoreResultSummary(domains: [domain, domain])
            precondition(summary.cards.count == (expected == nil ? 0 : 1))
            precondition(summary.cards.first?.count == (expected == nil ? nil : 1))
            precondition(summary.cards.first?.id == expected)
            precondition(RestoreFinalDomain.counts(domain).first?.0 == displayedGroups[index])
        }
        let domain = TaskDomainPresentation(id: "all", title: "All", symbol: "folder", items: fixtures.map { $0.0 })
        let summary = RestoreResultSummary(domains: [domain])
        precondition(summary.cards.map(\.count) == [4, 4, 1] && summary.uncounted == 2)
        precondition(summary.cards[0].explanation == "1 already matches, not verified · 2 applied, not verified · 1 verified")
        for outcome in [RestoreExecutionPresentation.Outcome.clean, .partial, .attention, .failedBeforeMutation, .failedAfterMutation, .stoppedBeforeMutation, .stoppedAfterMutation, .interrupted] {
            for force in [false, true] {
                let request = RestoreStopRequest(operationID: "current", force: force)
                precondition(request.notice(operationID: "another", outcome: outcome) == nil)
                precondition(request.notice(operationID: nil, outcome: outcome) == nil)
                let expected = force ? "Force Stop Requested" : [.stoppedBeforeMutation, .stoppedAfterMutation].contains(outcome) ? "Stopped by User" : "Stop Requested"
                precondition(request.notice(operationID: "current", outcome: outcome) == expected)
            }
        }
        var untouched = item("untouched", ["Unverified"], state: .unverified, known: false)
        untouched.resultNotRun = true
        precondition(untouched.resultTitle == "Not Run" && untouched.resultGroup == nil)
        var unknown = untouched; unknown.resultNotRun = false
        precondition(unknown.resultTitle == "Outcome Unknown" && unknown.resultGroup == nil)
        var startedUnknown = unknown
        startedUnknown.resultEvidenceAvailable = true
        startedUnknown.verificationEvidenceAvailable = false
        precondition(startedUnknown.resultTitle == "Outcome Unknown" && startedUnknown.resultGroup == nil)
        precondition(startedUnknown.hasResultProblemDetails)
        var verifiedUnknown = startedUnknown; verifiedUnknown.verificationEvidenceAvailable = true
        precondition(verifiedUnknown.resultTitle == "Unverified" && verifiedUnknown.resultGroup == "Needs Attention")
        var blocked = untouched; blocked.previewProblem = "target_conflict"
        precondition(blocked.resultGroup == "Needs Attention" && blocked.resultBreakdown == "conflict")
        var applied = item("applied", ["Applied"], known: true)
        applied.sourceDomain = "macos-finder"
        var matching = item("matching", ["Already Matches"], known: true)
        matching.sourceDomain = "macos-dock"
        let settings = TaskDomainPresentation(id: "macOS Settings", title: "macOS Settings", symbol: "gearshape", items: [applied, matching])
        precondition(settings.resultTitle == "Completed")
        precondition(settings.resultChildren.map(\.id) == ["macos-finder", "macos-dock"])
        precondition(settings.resultChildren[0].resultTitle == "Completed" && settings.resultChildren[1].resultTitle == "Already Matches")
        precondition(settings.resultChildren.flatMap(\.items).map(\.id) == [applied.id, matching.id])
        precondition(TaskDomainPresentation(id: "notrun", title: "", symbol: "", items: [untouched]).resultTitle == "Not Run")
        precondition(TaskDomainPresentation(id: "unknown", title: "", symbol: "", items: [unknown]).resultTitle == "Outcome Unknown")
        precondition(TaskDomainPresentation(id: "blocked", title: "", symbol: "", items: [blocked]).resultTitle == "Needs Attention")
        let partial = TaskDomainPresentation(id: "partial", title: "", symbol: "", items: [applied, unknown])
        precondition(partial.resultTitle == "Partial")
        precondition(RestoreFinalDomain.counts(partial).map(\.1) == [2])
        let partialStyle = RestoreResultStatusLabel(state: RestoreFinalDomain.finalStatus(partial), title: partial.resultTitle)
        precondition(partialStyle.tone == .neutral && partialStyle.symbol == "circle.lefthalf.filled")
        let unknownDomain = TaskDomainPresentation(id: "unknown", title: "", symbol: "", items: [unknown])
        let unknownStyle = RestoreResultStatusLabel(state: RestoreFinalDomain.finalStatus(unknownDomain), title: unknownDomain.resultTitle)
        precondition(unknownStyle.tone == .neutral && unknownStyle.symbol == "questionmark.circle")
        precondition(RestoreFinalDomain.visibleLabels(unknown) == ["Outcome Unknown"])
        let mixed = TaskDomainPresentation(id: "mixed", title: "", symbol: "", items: [applied, item("second-applied", ["Applied"], known: true), fixtures[6].0, unknown, item("second-unknown", ["Unverified"], state: .unverified, known: false)])
        precondition(mixed.resultTitle == "Needs Attention")
        precondition(RestoreResultSummary(domains: [mixed]).cards.map(\.count) == [2, 1])
        precondition(RestoreFinalDomain.counts(mixed).map(\.1) == [5])
        for outcome in [RestoreExecutionPresentation.Outcome.stoppedBeforeMutation, .stoppedAfterMutation] {
            precondition(RestoreExecutionPresentation.stopRequestExplanation(outcome: outcome, notice: "Stopped by User") == nil)
        }
        precondition(RestoreExecutionPresentation.stopRequestExplanation(outcome: .interrupted, notice: "Stop Requested")?.contains("does not confirm") == true)
        precondition(RestoreExecutionPresentation.stopRequestExplanation(outcome: .interrupted, notice: nil) == nil)

        precondition(GracefulStopState.receiving("graceful_stop_accepted", current: .requested) == .accepted)
        precondition(GracefulStopState.receiving("graceful_stop_unavailable", current: .requested) == .unavailable)
        let rejectedRequest = RestoreStopRequest(operationID: "current", force: false)
        for outcome in [RestoreExecutionPresentation.Outcome.clean, .partial, .failedBeforeMutation, .failedAfterMutation, .stoppedAfterMutation] {
            precondition(rejectedRequest.notice(operationID: "current", outcome: outcome, response: .unavailable) == nil)
            precondition(rejectedRequest.notice(operationID: "current", outcome: outcome, response: .deliveryFailed) == nil)
        }
        precondition(rejectedRequest.notice(operationID: "current", outcome: .stoppedAfterMutation, response: .accepted) == "Stopped by User")
        precondition(rejectedRequest.notice(operationID: "another", outcome: .stoppedAfterMutation, response: .accepted) == nil)
        var restart = item("restart", ["Unverified"], state: .unverified, known: false)
        restart.auxiliaryCompletionUnreported = true
        var finder = TaskDomainPresentation(id: "macos-finder", title: "Finder", symbol: "finder", items: [applied, restart])
        precondition(finder.resultVisibleItems.map(\.id) == [applied.id])
        precondition(finder.items.count == 2 && restart.resultGroup == nil)
        let completedWithRestart = RestoreResultSummary(domains: [finder])
        precondition(completedWithRestart.uncounted == 0 && completedWithRestart.cards.map(\.count) == [1])
        let unsupportedOnly = TaskDomainPresentation(id: "unsupported", title: "", symbol: "", items: [fixtures[6].0])
        precondition(RestoreResultSummary(domains: [unsupportedOnly]).uncounted == 0)
        let withUnknown = TaskDomainPresentation(id: "unknown", title: "", symbol: "", items: [applied, item("unknown-requirement", ["Unverified"], state: .unverified, known: false), untouched, restart])
        precondition(RestoreResultSummary(domains: [withUnknown]).uncounted == 2)
        precondition(RestoreResultSummary(domains: [withUnknown]).cards.map(\.id) == ["Success"])
        let skippedOnly = TaskDomainPresentation(id: "skipped", title: "", symbol: "", items: [fixtures[7].0])
        precondition(RestoreResultSummary(domains: [skippedOnly]).cards.map(\.id) == ["Skipped"])
        precondition(RestoreFinalDomain.tone("Skipped") == .secondary)
        precondition(summary.cards.count == 3 && summary.cards.reduce(0) { $0 + $1.count } == fixtures.count - summary.uncounted)
        precondition(applied.resultTitle == "Applied, not verified" && applied.resultBreakdown == "applied, not verified")
        precondition(fixtures[0].0.resultTitle == "Verified" && fixtures[0].0.resultBreakdown == "verified")

        finder.resultCategoryIssue = true
        precondition(finder.resultTitle == "Needs Attention" && finder.resultVisibleItems.count == 2)
        precondition(finder.resultCategoryExplanation.contains("exact failed step"))
        var failedRestart = restart
        failedRestart.resultLabels = ["Failed"]; failedRestart.auxiliaryCompletionUnreported = false
        precondition(TaskDomainPresentation(id: "macos-dock", title: "Dock", symbol: "dock", items: [failedRestart]).resultVisibleItems.count == 1)
        precondition(RestoreTaskPresentation.scopeProblemExplained(reason: "module_failed", hasItemProblems: true, independentProblem: false))
        precondition(!RestoreTaskPresentation.scopeProblemExplained(reason: "module_failed", hasItemProblems: true, independentProblem: true))
        precondition(!RestoreTaskPresentation.scopeProblemExplained(reason: "module_failed", hasItemProblems: false, independentProblem: false))
        precondition(!RestoreTaskPresentation.scopeProblemExplained(reason: "another_error", hasItemProblems: true, independentProblem: false))
        precondition(RestoreResultSummary(domains: []).cards.isEmpty)
        let source = try! String(contentsOfFile: "Sources/RestoreView.swift")
        precondition(!source.contains("if !hasOperationLog && !result.technicalDetails.isEmpty"))
        let stopContent = source.components(separatedBy: "if let notice = result.stopNotice {")[1]
            .components(separatedBy: "RestoreResultSummaryView")[0]
        precondition(stopContent.contains("Label(notice, systemImage: \"stop.circle\")")
            && stopContent.contains("if let explanation = result.stopRequestExplanation {")
            && stopContent.contains("Text(explanation)"))
        let restoreBadges = source.components(separatedBy: "struct RestoreCountBadges: View {")[1]
            .components(separatedBy: "\nstruct ")[0]
        precondition(restoreBadges.contains("WorkflowCountPill(count: count, label: label, tint: Self.color(label))")
            && !restoreBadges.contains("Text(label + \" \" + String(count))"))
        let components = try! String(contentsOfFile: "Sources/TaskComponents.swift")
        let countPill = components.components(separatedBy: "struct WorkflowCountPill: View {")[1]
            .components(separatedBy: "\nstruct ")[0]
        precondition(countPill.contains("Text(String(count))") && !countPill.contains("Text(label"))
        precondition(countPill.contains(".accessibilityLabel(label)") && countPill.contains(".accessibilityValue(String(count))"))
        precondition(!source.contains("No item-level completion or Verification was reported.") && !source.contains("Finishing Current Installation"))
        precondition(source.contains("ForEach(domain.resultChildren)") && source.contains("Stopping Rebuild…"))
        print("PASS: shared plan-row summary, disjoint breakdowns, unknown scope, Apply without Verification and operation-bound Stop notices")
    }

    @MainActor static func textStatusLayoutChecks() {
        let long = "Macseed cannot inspect login items without System Events permission. Choose Fix Issues… to allow access and check the current state again."
        for width in [CGFloat(280), 420, 760] {
            let columns = TaskTextStatusLayout.widths(width)
            precondition(columns.text > 0 && columns.status > 0)
            precondition(abs(columns.text + 12 + columns.status - width) < 0.01)
            for size in [DynamicTypeSize.large, .accessibility3] {
                var heights: [CGFloat] = []
                for (action, state, label) in [("Matches.", TaskRowState.matching, "Already Matches"),
                                                (long, TaskRowState.attention, "Needs Attention")] {
                    let item = TaskItemPresentation(id: "fixture", item: DisplayItem(id: "fixture", title: "Application", status: state == .matching ? .matching : .attention, action: action), state: state)
                    let domain = TaskDomainPresentation(id: "homebrew-casks", title: "Homebrew Applications", symbol: "app", items: [item])
                    let renderer = ImageRenderer(content: TaskDomainItems(domain: domain, stateTitles: [state: label])
                        .frame(width: width).environment(\.dynamicTypeSize, size))
                    guard let image = renderer.nsImage else { preconditionFailure("Task row did not render") }
                    precondition(abs(image.size.width - width) < 1 && image.size.height > 0)
                    heights.append(image.size.height)
                    let leaf = ImageRenderer(content: RestoreSettingPreviewLeaf(item: item, title: "Application", stateTitles: [state: label])
                        .frame(width: width).environment(\.dynamicTypeSize, size))
                    precondition(leaf.nsImage != nil)
                    let comparison = ImageRenderer(content: EnvironmentComparisonItem(item: item.item)
                        .frame(width: width).environment(\.dynamicTypeSize, size))
                    precondition(comparison.nsImage != nil)
                }
                precondition(heights[1] > heights[0], "Long descriptions must increase row height")
            }
        }
        let source = try! String(contentsOfFile: "Sources/TaskComponents.swift")
        let items = source.components(separatedBy: "struct TaskDomainItems: View {")[1]
            .components(separatedBy: "struct PendingOperationLogButton:")[0]
        precondition(items.contains("TaskTextStatusLayout") && !items.contains("ViewThatFits"))
        let leaf = source.components(separatedBy: "struct RestoreSettingPreviewLeaf: View {")[1]
        precondition(leaf.contains("RestorePreviewRow") && !leaf.contains("ViewThatFits"))
        print("PASS: text/status columns, long and short descriptions, narrow widths and larger text")
    }

    @MainActor static func unsupportedRepairExplanationChecks() {
        func row(_ diagnostic: [String: String]?) -> CoreRestorePreparation.Row {
            var value: [String: Any] = ["domain": "homebrew-casks", "item_id": "fixture", "action": "reinstall",
                                       "disposition": "blocked", "reason": "cask_execution_requirements_unsupported"]
            if let diagnostic { value["diagnostic"] = diagnostic }
            return try! JSONDecoder().decode(CoreRestorePreparation.Row.self, from: JSONSerialization.data(withJSONObject: value))
        }
        let specific = row(["primitive": "lifecycle", "condition": "ownership_unproven",
                            "stage": "qualification", "predicate": "cleanup_ownership", "reason_code": "ownership_unproven"])
        precondition(specific.unsupportedRepairExplanation!.contains("ownership"))
        precondition(specific.unsupportedRepairExplanation!.contains("official installer"))
        let details = specific.diagnostic!.technicalDescription
        for line in ["stage: qualification", "predicate: cleanup_ownership", "reason_code: ownership_unproven"] {
            precondition(details.contains(line))
        }
        let fallback = "Automatic repair is unavailable. Macseed could not verify that the operation is safe."
        for unknown in [row(nil), row(["primitive": "requirements", "condition": "unsupported_capability"]),
                        row(["primitive": "lifecycle", "condition": "future_condition", "reason_code": "future_reason"])] {
            precondition(unknown.unsupportedRepairExplanation == fallback)
            precondition(!unknown.unsupportedRepairExplanation!.contains("scripts"))
            precondition(unknown.diagnostic?.technicalDescription.contains("stage:") != true)
        }
        let script = row(["primitive": "requirements", "condition": "unsupported_capability", "reason_code": "script_effects_unbounded"])
        precondition(script.unsupportedRepairExplanation!.contains("scripts"))
        var preparation = specific
        preparation.diagnostic = .init(primitive: "pkgutil", condition: "preparation_required")
        precondition(preparation.unsupportedRepairExplanation == nil)
        preparation.diagnostic = .init(primitive: "login_item", condition: "authorization_required")
        precondition(preparation.unsupportedRepairExplanation == nil)
        let source = try! String(contentsOfFile: "Sources/RestoreTasks.swift")
        precondition(source.contains("result == nil && !executing && !operationProgress, let explanation = entry?.unsupportedRepairExplanation"))
        for row in [specific, row(nil)] {
            let item = TaskItemPresentation(id: "fixture", item: DisplayItem(id: "fixture", title: "Application", status: .attention,
                action: row.unsupportedRepairExplanation!, reason: row.reason), state: .attention, diagnostic: row.diagnostic)
            let domain = TaskDomainPresentation(id: "homebrew-casks", title: "Homebrew Applications", symbol: "app", items: [item])
            precondition(ImageRenderer(content: TaskDomainItems(domain: domain, stateTitles: [.attention: "Needs Attention"]).frame(width: 420)).nsImage != nil)
        }
        print("PASS: unsupported Repair explanation, Core diagnostic fields, neutral fallback and existing consent presentation")
    }

    @MainActor static func screenshotsIncludedSettingsChecks() {
        let settings: [[String: String]] = [
            ["id": "location", "label": "Save location"],
            ["id": "disable-shadow", "label": "Window shadow"],
            ["id": "show-thumbnail", "label": "Floating thumbnail"]]
        for included in [settings, [settings[0]], [settings[0], settings[1]], [settings[0], settings[2]], []] {
            let data = try! JSONSerialization.data(withJSONObject: [
                "domain": "macos-screenshots", "status": included.isEmpty ? "unavailable" : "present",
                "selection_mode": "category", "items": [], "included_settings": included])
            let row = try! JSONDecoder().decode(CoreCaptureInventoryRow.self, from: data)
            precondition(CaptureSettingsPresentation.labels([row])["macos-screenshots"] == included.map { $0["label"]! },
                "Only observed settings appear; absent supported keys must not be synthesized")
            for width in included.isEmpty ? [] : [180.0, 600.0] {
                precondition(ImageRenderer(content: IncludedSettingsText(settings: row.includedSettings!).frame(width: width)).nsImage != nil)
            }
        }
        let legacy = try! JSONDecoder().decode(CoreCaptureInventoryRow.self, from: Data(
            #"{"domain":"macos-screenshots","status":"present","selection_mode":"category","items":[]}"#.utf8))
        precondition(CaptureSettingsPresentation.labels([legacy])["macos-screenshots"] == [])
        print("PASS: Screenshots Included Settings preserves observed labels, Save location and absent/legacy metadata without defaults")
    }

    @MainActor static func windowsIncludedSettingsChecks() {
        let settings: [[String: String]] = [
            ["id": "EnableStandardClickToShowDesktop", "label": "Click wallpaper to reveal Desktop"],
            ["id": "EnableTilingByEdgeDrag", "label": "Tile windows by dragging to edges"],
            ["id": "EnableTopTilingByEdgeDrag", "label": "Fill window by dragging to top"],
            ["id": "EnableTiledWindowMargins", "label": "Tiled window margins"]]
        for included in [settings, [settings[0]], []] {
            let data = try! JSONSerialization.data(withJSONObject: [
                "domain": "macos-windows", "status": included.isEmpty ? "unavailable" : "present",
                "selection_mode": "category", "items": [], "included_settings": included])
            let row = try! JSONDecoder().decode(CoreCaptureInventoryRow.self, from: data)
            precondition(CaptureSettingsPresentation.labels([row])["macos-windows"] == included.map { $0["label"]! })
            for setting in included {
                precondition(WorkspaceSettingLabels.names["macos-windows:com.apple.WindowManager/" + setting["id"]!] == setting["label"]!)
            }
            for width in included.isEmpty ? [] : [180.0, 600.0] {
                precondition(ImageRenderer(content: IncludedSettingsText(settings: row.includedSettings!).frame(width: width)).nsImage != nil)
            }
        }
        print("PASS: Windows Included Settings uses observed Core labels and matching Restore labels without defaults")
    }

    @MainActor static func captureCompactSettingsChecks() {
        let source = try! String(contentsOfFile: "Sources/CapturePresentation.swift")
        let settingsDetails = source.components(separatedBy: "struct CaptureSettingsSubcategoryView:")[1].components(separatedBy: "enum CaptureSettingsPresentation")[0]
        precondition(settingsDetails.contains("CaptureIncludedSettingsList(labels: labels)") && settingsDetails.contains("CaptureSettingsPresentation.labels([category.row])"))
        precondition(!settingsDetails.contains("ForEach(settings") && !settingsDetails.contains("padding(.leading, 36)"), "Review reuses compact read-only labels without duplicated layout or indentation")
        let compactLabels = source.components(separatedBy: "struct CaptureIncludedSettingsList:")[1].components(separatedBy: "struct CaptureConfirmationItems:")[0]
        precondition(compactLabels.contains("SettingsFlowLayout") && compactLabels.contains("Array(labels.enumerated())") && compactLabels.contains("CaptureCompactLabel(title: label)"))
        precondition(!compactLabels.contains("NativeSelectionCheckbox") && !compactLabels.contains("Button("))
        for domain in CaptureMacOSSettingsGroup.domainIDs {
            let labels = ["First supported preference", "A longer supported preference label that must wrap completely", "Last supported preference"]
            let row = try! JSONDecoder().decode(CoreCaptureInventoryRow.self, from: JSONSerialization.data(withJSONObject: [
                "domain": domain, "status": "present", "selection_mode": "category", "items": [],
                "included_settings": labels.enumerated().map { ["id": "setting-\($0.offset)", "label": $0.element] }]))
            precondition(CaptureSettingsPresentation.labels([row])[domain] == labels)
            let small = ImageRenderer(content: CaptureIncludedSettingsList(labels: labels).frame(width: 180)).cgImage!
            let wide = ImageRenderer(content: CaptureIncludedSettingsList(labels: labels).frame(width: 600)).cgImage!
            precondition(small.width == 180 && wide.width == 600 && small.height > wide.height,
                "The existing compact labels wrap with available width and retain the complete ordered inventory")
        }
        print("PASS: all six macOS Review categories reuse the existing compact read-only labels, inventory order and responsive wrapping")
    }

    @MainActor static func captureResultAlignmentChecks() {
        _ = NSApplication.shared
        let publication = CoreCapturePublication(publicationOccurred: true, destination: "/Users/Example/Environments/My Mac.mbt",
            preparedCaptureID: String(repeating: "a", count: 64),
            bundle: .init(formatVersion: 1, selectedCategories: ["macos-finder", "vscode-settings"],
                selectedItemCounts: ["homebrew-packages": 93], secureComponent: false))
        func warning(_ id: String, reason: String, domain: String = "homebrew-packages") -> DisplayCategory {
            .init(id: domain, title: domain, symbol: "shippingbox", items: [
                .init(id: id, title: "Needs Attention", status: .attention, action: "private diagnostic must not render", reason: reason)])
        }
        let first = warning("source", reason: "source_partial")
        let independent = warning("tool", reason: "tool_unavailable")
        let clean = CaptureResultPresentation(publication: publication, notices: [warning("ssh", reason: "source_partial", domain: "ssh-configuration")])
        let limited = CaptureResultPresentation(publication: publication, notices: [first, first, independent,
            warning("finder", reason: "observation_failed", domain: "macos-finder")])
        precondition(clean.attention.isEmpty && clean.scope == "3 domains · 93 items saved")
        precondition(clean.affectedCount == 0)
        precondition(limited.attention.count == 2 && limited.attention.flatMap(\.items).count == 3 && limited.attentionSummary == "2 affected categories")
        let unknown = warning("distinct", reason: "private_token_value").items[0]
        precondition(!CaptureResultPresentation.explanation(unknown).contains("private"))
        let sameReason = CaptureResultPresentation(publication: publication, notices: [first, warning("independent-source", reason: "source_partial")])
        precondition(sameReason.attention[0].items.count == 2, "Independent identities must not collapse just because their explanations match")
        let many = CaptureResultPresentation(publication: publication, notices: (1...30).map { warning("issue-\($0)", reason: "source_partial") })
        precondition(many.attention[0].items.count == 30)
        let developerIDs = ["git-repositories", "ssh-configuration", "workspace-folders"]
        let developerPublication = CoreCapturePublication(publicationOccurred: true, destination: publication.destination,
            preparedCaptureID: publication.preparedCaptureID,
            bundle: .init(formatVersion: 1, selectedCategories: developerIDs, selectedItemCounts: [:], secureComponent: false))
        let developerResult = CaptureResultPresentation(publication: developerPublication,
            notices: developerIDs.map { warning($0, reason: "source_partial", domain: $0) })
        precondition(developerResult.attention.map(\.title) == ["Git Repositories / Worktrees", "SSH Configuration", "Workspace Folders"])
        precondition(developerResult.affectedCount == 3 && developerResult.scope == "3 domains · 0 items saved")
        func coloredBounds(_ image: NSBitmapImageRep, warning: Bool) -> CGRect? {
            var xs: [Int] = [], ys: [Int] = []
            for y in 0..<image.pixelsHigh { for x in 0..<image.pixelsWide {
                guard let c = image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.9 else { continue }
                let match = warning ? c.redComponent > 0.5 && c.greenComponent > 0.15 && c.redComponent > c.greenComponent * 1.1 && c.blueComponent < 0.3
                    : c.greenComponent > 0.4 && c.greenComponent > c.redComponent * 1.4 && c.greenComponent > c.blueComponent * 1.2
                if match { xs.append(x); ys.append(y) }
            } }
            guard let x = xs.min(), let y = ys.min() else { return nil }
            return CGRect(x: x, y: y, width: xs.max()! - x + 1, height: ys.max()! - y + 1)
        }
        for width: CGFloat in [420, 729, 929] {
            for (name, result) in [("clean", clean), ("attention", limited)] {
                let view = CaptureResultOutcomes(result: result).frame(width: width).background(Color(nsColor: .windowBackgroundColor))
                let bitmap = NSBitmapImageRep(cgImage: ImageRenderer(content: view).cgImage!)
                let green = coloredBounds(bitmap, warning: false)!
                let amber = coloredBounds(bitmap, warning: true)
                precondition((amber != nil) == (name == "attention"), "Clean publication has one outcome; affected domains add one attention card")
                if let amber {
                    if width >= 729 { precondition(abs(green.minY - amber.minY) <= 2 && amber.minX > green.maxX) }
                    else { precondition(amber.minY > green.maxY, "Only narrow actual detail widths stack outcome cards") }
                }
            }
        }
        func scrolls(_ view: NSView) -> [NSScrollView] { (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrolls) }
        for size in [MainWindowPolicy.minimum, MainWindowPolicy.preferred] {
            for dark in [false, true] {
                NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                for (name, result) in [("clean", clean), ("attention", limited), ("many", many), ("developer", developerResult)] {
                    var frames: [String: CGRect] = [:]
                    let content = HStack(spacing: 0) {
                        Color(nsColor: .controlBackgroundColor).frame(width: 215)
                        VStack(spacing: 0) {
                            WorkflowContentViewport(pinned: true) {
                                VStack(alignment: .leading, spacing: 20) {
                                    WorkspaceHeader(title: ProductTask.capture.title, subtitle: ProductTask.capture.subtitle, symbol: ProductTask.capture.symbol)
                                    CaptureResultContent(result: result)
                                        .background(GeometryReader { Color.clear.preference(key: WorkflowAnchorFrames.self, value: ["result": $0.frame(in: .named("result"))]) })
                                }.modifier(WorkspaceContentGeometry())
                            }
                            Divider()
                            HStack { Text("View Log"); Spacer(); Button("Capture Again") {}; Button("Done") {} }
                                .modifier(WorkspaceFooterPadding())
                                .background(GeometryReader { Color.clear.preference(key: WorkflowAnchorFrames.self, value: ["footer": $0.frame(in: .named("result"))]) })
                        }
                    }.frame(width: size.width, height: size.height).background(Color(nsColor: .windowBackgroundColor))
                        .coordinateSpace(name: "result").onPreferenceChange(WorkflowAnchorFrames.self) { frames = $0 }
                    let host = NSHostingView(rootView: content)
                    let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
                    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)); host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
                    let scroll = scrolls(host)
                    precondition(scroll.count == 1 && frames.count == 2, "Result fixture viewport=\(scroll.count), frames=\(frames), size=\(size)")
                    precondition(frames["footer"]!.maxY <= size.height && frames["result"]!.minY >= 0)
                    if name == "clean" {
                        precondition(scroll[0].documentView!.frame.height <= scroll[0].contentView.bounds.height + 1,
                            "A clean Result must fit without scrolling at the 1000x700 minimum")
                        precondition(frames["result"]!.maxY < frames["footer"]!.minY)
                    }
                    if name == "many" {
                        let bottom = scroll[0].documentView!.frame.height - scroll[0].contentView.bounds.height
                        precondition(bottom > 0, "Independent warnings must remain reachable when they exceed the viewport")
                        let footer = frames["footer"]!
                        scroll[0].contentView.scroll(to: CGPoint(x: 0, y: bottom)); scroll[0].reflectScrolledClipView(scroll[0].contentView)
                        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)); host.layoutSubtreeIfNeeded()
                        precondition(abs(scroll[0].contentView.bounds.minY - bottom) < 2 && frames["footer"] == footer)
                        scroll[0].contentView.scroll(to: .zero); scroll[0].reflectScrolledClipView(scroll[0].contentView)
                    }
                    let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath:
                        "build/Debug/CaptureResult-closure-\(name)-\(Int(size.width))-\(dark ? "dark" : "light").png"))
                    window.close()
                }
            }
        }
        print("PASS: compact Result exact scope, selected/deduplicated independent warnings and safe explanations; clean Result fits minimum window in Light/Dark with fixed footer")
    }

    @MainActor static func restoreResultColumnsChecks() {
        let labels = ["Verified", "Completed", "Already Matches", "Needs Attention", "Skipped"]
        for width in [420.0, 785.0, 985.0] {
            for size in [DynamicTypeSize.large, .accessibility3] {
                let probe = VStack(spacing: 10) {
                    ForEach(0..<6) { row in
                        RestoreResultColumns {
                            Text(row % 2 == 0 ? "Short" : String(repeating: "Long category title ", count: 4))
                                .padding(.leading, RestoreResultColumns.titleInset(depth: row % 2, item: row > 3))
                            WorkflowTrailingLayout(showsCounts: row % 3 > 0, showsChevron: true) {
                                Color.red.frame(width: 40, height: 8)
                                HStack(spacing: 6) {
                                    if row % 3 > 0 { Color.blue.frame(width: 32, height: 8) }
                                    if row % 3 > 1 { Color.blue.frame(width: 32, height: 8) }
                                }.fixedSize()
                                Color(red: 0, green: 1, blue: 0).frame(width: 12, height: 8)
                                Color.clear.frame(width: 70, height: 0)
                            }
                            Color.clear.frame(width: 148, height: 0)
                        }
                    }
                }.frame(width: width).environment(\.dynamicTypeSize, size)
                let image = ImageRenderer(content: probe).cgImage!
                let bitmap = NSBitmapImageRep(cgImage: image)
                var starts = Set<Int>(), countStarts = Set<Int>(), chevronStarts = Set<Int>()
                var rows = 0
                for y in 0..<bitmap.pixelsHigh {
                    var found = false, count = false, chevron = false
                    for x in 0..<bitmap.pixelsWide {
                        guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.9 else { continue }
                        if !found && c.redComponent > 0.5 && c.redComponent > c.greenComponent * 2 && c.redComponent > c.blueComponent * 2 { starts.insert(x); found = true }
                        if !count && c.blueComponent > 0.9 && c.redComponent < 0.1 { countStarts.insert(x); count = true }
                        if !chevron && c.greenComponent > 0.4 && c.redComponent < 0.1 && c.blueComponent < 0.4 { chevronStarts.insert(x); chevron = true }
                    }
                    if found { rows += 1 }
                }
                precondition(starts.count == 1 && countStarts.count == 1 && chevronStarts.count == 1 && rows >= 48,
                    "Column origins: status=\(starts), count=\(countStarts), chevron=\(chevronStarts), rows=\(rows)")
                // 148pt legacy lane - 12pt arrow - 8pt gap - 70pt count rail.
                precondition(countStarts.first! - starts.first! == 58)
                precondition(chevronStarts == [Int(width) - 12], "Badge count cannot move the chevron")
                for (index, label) in labels.enumerated() {
                    let item = TaskItemPresentation(id: "item", item: DisplayItem(id: "item", title: String(repeating: "Long item name ", count: 5), status: .ready,
                        action: ""), state: .completed, resultLabels: [label])
                    let domain = TaskDomainPresentation(id: "fixture", title: String(repeating: "Category ", count: 4), symbol: "folder", items: [item])
                    let view = RestoreFinalDomain(domain: domain, expansion: .constant(true), depth: index % 2)
                        .frame(width: width).environment(\.dynamicTypeSize, size)
                    let rendered = ImageRenderer(content: view.environment(\.restoreTrailingSamples, RestoreTrailingSample.result([domain], appStore: nil)))
                    precondition(rendered.nsImage != nil)
                    if size == .large {
                        let bitmap = NSBitmapImageRep(cgImage: rendered.cgImage!)
                        try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath:
                            "build/Debug/RestoreLayout-expanded-\(index)-\(Int(width)).png"))
                    }
                }
            }
        }
        let source = try! String(contentsOfFile: "Sources/RestoreView.swift")
        let final = source.components(separatedBy: "struct RestoreFinalDomain: View {")[1].components(separatedBy: "struct RestoreResultStatusLabel:")[0]
        precondition(final.components(separatedBy: "RestoreResultColumns {").count == 2)
        precondition(final.contains("RestoreResultCategoryHeader(id: domain.id"))
        let header = source.components(separatedBy: "struct RestoreResultCategoryHeader:")[1].components(separatedBy: "struct RestoreFinalDomain:")[0]
        precondition(header.contains("RestoreResultColumns {"))
        precondition(header.contains("RestoreTrailingControls(status:") && !header.contains("Spacer("))
        let itemSource = source.components(separatedBy: "struct RestoreResultItemRow:")[1].components(separatedBy: "struct RestoreResultStatusLabel:")[0]
        precondition(!itemSource.contains("chevron.right"))
        precondition(!itemSource.contains("Text(\"Technical Details\")") && !itemSource.contains("Button(\"Technical Details\")"))
        precondition(!final.contains("TaskTextStatusLayout") && !final.contains("ViewThatFits") && !final.contains(".offset("))
        precondition(RestoreResultColumns.titleInset(depth: 1) == 52 && RestoreResultColumns.titleInset(depth: 1, item: true) == 88)
        print("PASS: Stable count and chevron rails, preserved status origins, wrapping and larger text at 420/785/985 pt")
    }

    @MainActor static func resultStatusAlignmentChecks() {
        _ = NSApplication.shared; NSApp.appearance = NSAppearance(named: .aqua)
        func origin<V: View>(_ view: V, width: CGFloat, status: TaskRowState = .completed) -> Int {
            // Result rows can represent verified work or outstanding manual work.
            // Match the expected status tint after the renderer's color conversion.
            let swatch = NSBitmapImageRep(cgImage: ImageRenderer(content: status.tone.color.frame(width: 8, height: 8)).cgImage!)
            let expected = swatch.colorAt(x: 4, y: 4)!.usingColorSpace(.sRGB)!
            let bitmap = NSBitmapImageRep(cgImage: ImageRenderer(content: view.frame(width: width).environment(\.restoreTrailingSamples, references)).cgImage!)
            for x in 0..<bitmap.pixelsWide {
                for y in 0..<bitmap.pixelsHigh {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.alphaComponent > 0.9 else { continue }
                    if abs(color.redComponent - expected.redComponent) <= 2 / 255
                        && abs(color.greenComponent - expected.greenComponent) <= 2 / 255
                        && abs(color.blueComponent - expected.blueComponent) <= 2 / 255 { return x }
                }
            }
            preconditionFailure("Expected \(status.rawValue) status at \(width) pt")
        }
        let item = TaskItemPresentation(id: "row", item: DisplayItem(id: "row", title: "Item", status: .ready, action: ""),
            state: .completed, resultLabels: ["Verified"])
        let domain = TaskDomainPresentation(id: "fixture", title: "Category", symbol: "folder", items: [item])
        let missingApp = TaskItemPresentation(id: "425264550", item: DisplayItem(id: "425264550", title: "App Store App",
            status: .missing, action: "Install manually from the App Store."), state: .attention,
            assistedAppStore: AssistedAppStoreItem(appID: "425264550", status: .missing))
        let summary = AppStoreRestorePresentation(domains: [.init(id: "app-store", title: "Apps", symbol: "app", items: [missingApp])])
        precondition(summary.pending.count == 1 && summary.attentionCount == 1 && summary.categoryState == .attention)
        let references = RestoreTrailingSample.result([domain], appStore: summary)
        // Preview still includes already-installed requirements; Result does not.
        let installedApp = TaskItemPresentation(id: "app", item: item.item, state: .matching,
            assistedAppStore: AssistedAppStoreItem(appID: "425264550", status: .installed))
        let previewSummary = AppStoreRestorePresentation(domains: [.init(id: "app-store", title: "Apps", symbol: "app", items: [installedApp])])
        for width: CGFloat in [420, 785, 985] {
            let positions = [
                origin(RestoreFinalDomain(domain: domain), width: width),
                origin(RestoreFinalDomain(domain: domain, depth: 1).padding(.horizontal, 16), width: width),
                origin(RestoreResultItemRow(item: item, notRun: false, depth: 0).padding(.horizontal, 16), width: width),
                origin(RestoreResultItemRow(item: item, notRun: false, depth: 1).padding(.horizontal, 16), width: width),
                origin(AppStoreRestoreResultRow(summary: summary, review: {}, expansion: .constant(false)), width: width, status: .attention)]
            precondition(positions.max()! - positions.min()! <= 3, "Category/nested/item/App Store status origins: \(positions)")
            let previewDomain = TaskDomainPresentation(id: "homebrew-casks", title: "Homebrew Applications", symbol: "app", items: [installedApp])
            // Exercise the actual shared Preview list: its environment supplies
            // identical status/count measurements to manual and automatic rows.
            let preview = TaskDomainList(domains: [previewDomain],
                leadingContent: AnyView(AppStoreRestoreCard(summary: previewSummary, review: {})), restoreSettingsPreview: true)
                .environment(\.restoreTrailingSamples, [RestoreTrailingSample(title: previewSummary.categoryStatus, disclosure: false)])
            let bitmap = NSBitmapImageRep(cgImage: ImageRenderer(content: preview.frame(width: width)).cgImage!)
            var origins: [Int] = []
            var lastY = -100
            for y in 0..<bitmap.pixelsHigh {
                let first = (0..<bitmap.pixelsWide).first { x in
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.alphaComponent > 0.9 else { return false }
                    return color.greenComponent > 0.2 && color.greenComponent > color.redComponent * 1.3 && color.greenComponent > color.blueComponent * 1.2
                }
                if let first {
                    if y - lastY > 8 { origins.append(first) }
                    else { origins[origins.count - 1] = min(origins.last!, first) }
                    lastY = y
                }
            }
            precondition(origins.count == 2 && abs(origins[0] - origins[1]) <= 3,
                "Real Preview manual and automatic status origins: \(origins)")
        }
        print("PASS: Real category, nested, leaf and App Store status origins align at 420/785/985 pt")
    }

    @MainActor static func previewColumnGeometryChecks() {
        _ = NSApplication.shared; NSApp.appearance = NSAppearance(named: .aqua)
        func item(_ id: String, _ state: TaskRowState) -> TaskItemPresentation {
            TaskItemPresentation(id: id, item: DisplayItem(id: id, title: "Requirement " + id,
                status: state == .matching ? .matching : .attention,
                action: id == "cask-1" ? String(repeating: "Long explanatory context stays in the title area. ", count: 4) : ""), state: state)
        }
        let casks = TaskDomainPresentation(id: "homebrew-casks", title: "Homebrew Applications", symbol: "app",
            items: (0..<16).map { item("cask-\($0)", $0 == 0 ? .attention : $0 == 1 ? .planned : .matching) })
        precondition(casks.summary.contains("14") && casks.summary.count > 40, "Verbose source summary remains available")
        let settings = [TaskDomainPresentation(id: "macos-finder", title: "Finder", symbol: "finder", items: [item("finder", .matching)]),
            TaskDomainPresentation(id: "macos-windows", title: "Windows", symbol: "macwindow", items: [item("windows", .matching)])]
        let domains = [casks,
            TaskDomainPresentation(id: "homebrew-packages", title: "Homebrew Packages", symbol: "shippingbox", items: (0..<21).map { item("package-\($0)", .matching) }),
            TaskDomainPresentation(id: "vscode-extensions", title: "VS Code Extensions", symbol: "puzzlepiece", items: (0..<24).map { item("extension-\($0)", .matching) }),
            TaskDomainPresentation(id: "macos-settings", title: "macOS Settings", symbol: "slider.horizontal.3", items: settings.flatMap(\.items))]
            + ["vscode-settings", "git-configuration", "workspace-folders", "git-repositories"].map {
                TaskDomainPresentation(id: $0, title: CaptureCategory.title(for: $0), symbol: WorkspaceCategoryStyle.symbol($0), items: [item($0, .matching)])
            }
        // Measure the status view supplied to the production row, not its tint:
        // status indicators and count pills can share semantic colors.
        let markerColor = Color(red: 1, green: 0, blue: 1)
        // Match the renderer's color conversion, not assumed raw RGB components.
        let markerBitmap = NSBitmapImageRep(cgImage: ImageRenderer(content: markerColor.frame(width: 8, height: 8)).cgImage!)
        let marker = markerBitmap.colorAt(x: 4, y: 4)!.usingColorSpace(.sRGB)!
        func marked<V: View>(_ status: V) -> some View {
            status.overlay(alignment: .leading) {
                markerColor.frame(width: 2, height: 8)
            }
        }
        func rows(expanded: Bool, nested: Bool) -> [(id: String, view: AnyView)] {
            var result: [(id: String, view: AnyView)] = []
            func header(_ domain: TaskDomainPresentation, inset: CGFloat, open: Bool) {
                result.append(("category:" + domain.id, AnyView(RestorePreviewRow(
                    title: WorkspaceCategoryTitle(id: domain.id, title: domain.title, fallbackSymbol: domain.symbol),
                    status: marked(RestorePreviewCategoryStatus(domain: domain, stateTitles: [:])),
                    counts: RestorePreviewMetrics.badges(domain), titleInset: inset, expanded: open)
                    .padding(.vertical, 6))))
            }
            func leaves(_ domain: TaskDomainPresentation, inset: CGFloat) {
                for item in domain.items {
                    result.append(("item:" + item.id, AnyView(RestorePreviewRow(
                        title: VStack(alignment: .leading, spacing: 4) {
                            Text(item.item.title)
                            if !item.item.action.isEmpty {
                                Text(item.item.action).font(.caption).foregroundStyle(.secondary)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading),
                        status: marked(TaskStatusLabel(state: item.state, showsTitle: item.state != .matching)),
                        titleInset: inset).padding(.vertical, 7))))
                }
            }
            for domain in domains {
                header(domain, inset: 0, open: expanded)
                guard expanded else { continue }
                if domain.id == "macos-settings" {
                    for child in settings {
                        header(child, inset: 36, open: nested)
                        if nested { leaves(child, inset: 72) }
                    }
                } else { leaves(domain, inset: 36) }
            }
            return result
        }
        let referenceDomains = domains + settings
        let references = referenceDomains.map {
            RestoreTrailingSample(title: RestorePreviewCategoryStatus.title($0, stateTitles: [:]),
                counts: RestorePreviewMetrics.badges($0))
        } + Set(referenceDomains.flatMap(\.items).map { $0.state.rawValue }).sorted().map {
            RestoreTrailingSample(title: $0, disclosure: false)
        }
        for width: CGFloat in [420, 785, 985] {
            var previous: [String: Int] = [:]
            for (expanded, nested, expected) in [(false, false, 8), (true, false, 75), (true, true, 77)] {
                let entries = rows(expanded: expanded, nested: nested)
                precondition(entries.count == expected && Set(entries.map(\.id)).count == expected)
                let markedRows = VStack(spacing: 0) {
                    ForEach(entries, id: \.id) { $0.view }
                }.padding(.horizontal, 32).frame(width: width)
                    .environment(\.restoreTrailingSamples, references)
                let bitmap = NSBitmapImageRep(cgImage: ImageRenderer(content: markedRows).cgImage!)
                try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/Debug/Preview-markers-\(Int(width))-\(expected).png"))
                var origins: [Int] = [], lastY = -100
                for y in 0..<bitmap.pixelsHigh {
                    let left = (0..<bitmap.pixelsWide).first { x in
                        guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
                        return c.alphaComponent > 0.9 && abs(c.redComponent - marker.redComponent) < 1 / 255
                            && abs(c.greenComponent - marker.greenComponent) < 1 / 255
                            && abs(c.blueComponent - marker.blueComponent) < 1 / 255
                    }
                    if let left {
                        if y - lastY > 1 { origins.append(left) }
                        else { origins[origins.count - 1] = min(origins.last!, left) }
                        lastY = y
                    }
                }
                precondition(origins.count == expected && origins.max()! - origins.min()! <= 3,
                    "Preview status-view markers at \(width), expanded=\(expanded), nested=\(nested): \(origins)")
                let current = Dictionary(uniqueKeysWithValues: zip(entries.map(\.id), origins))
                for (id, origin) in previous {
                    precondition(abs(current[id]! - origin) <= 3, "Expanding Preview moved status \(id) at \(width)")
                }
                previous = current
            }
            // The mixed category's only blue element is its Planned badge. Test
            // that rail separately so it can never masquerade as a status origin.
            let badges = RestorePreviewMetrics.badges(casks)
            precondition(badges.map(\.0) == ["Planned", "Attention"] && badges.map(\.1) == [1, 1],
                "Preview badges contain actionable counts; matches remain in the summary")
            precondition(RestorePreviewMetrics.counts([casks]).matching == 14)
            let badgeProbe = RestorePreviewRow(title: Text(casks.title),
                status: marked(RestorePreviewCategoryStatus(domain: casks, stateTitles: [:])),
                counts: badges, expanded: true)
                .padding(.horizontal, 32).frame(width: width)
                .environment(\.restoreTrailingSamples, references)
            let badgeBitmap = NSBitmapImageRep(cgImage: ImageRenderer(content: badgeProbe).cgImage!)
            try! badgeBitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/Debug/Preview-badge-probe-\(Int(width)).png"))
            var badgeOrigins: [Int] = []
            for y in 0..<badgeBitmap.pixelsHigh {
                for x in 0..<badgeBitmap.pixelsWide {
                    guard let c = badgeBitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.9 else { continue }
                    if c.blueComponent > 0.5 && c.blueComponent > c.redComponent * 1.3 && c.blueComponent > c.greenComponent * 1.2 {
                        badgeOrigins.append(x)
                    }
                }
            }
            precondition(!badgeOrigins.isEmpty && CGFloat(badgeOrigins.min()! - previous["category:" + casks.id]!) > TaskRowLayout.iconWidth,
                "Planned badge must occupy its own rail, outside the status indicator at \(width)")
            // Keep rendering the complete production hierarchy as well as the
            // instrumented rows; markers above do not alter production views.
            let probe = TaskDomainList(domains: domains, restoreSettingsPreview: true, settingsCategories: settings,
                expansion: .constant(Set(domains.map(\.id))), settingsExpansion: .constant(true))
                .padding(16).frame(width: width).background(Color(nsColor: .windowBackgroundColor))
            let renderer = ImageRenderer(content: probe)
            let bitmap = NSBitmapImageRep(cgImage: renderer.cgImage!)
            try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/Debug/RestorePreview-status-grid-\(Int(width)).png"))
            print("PASS: Preview \(width) pt: 8/75/77 status markers align through expansion; Planned badge is measured separately")
        }
        let source = try! String(contentsOfFile: "Sources/TaskComponents.swift")
        let previewHeader = source.components(separatedBy: "if restoreSettingsPreview {\n                RestorePreviewRow")[1].components(separatedBy: "} else { ViewThatFits")[0]
        precondition(!previewHeader.contains("domainSummary") && !previewHeader.contains("Text("))
        let samples = source.components(separatedBy: "transformEnvironment(\\.restoreTrailingSamples)")[1].components(separatedBy: "private func domainRow")[0]
        precondition(!samples.contains("subtitle:") && !samples.contains("domainSummary"))
        print("PASS: Preview category/leaf/nested settings anchors match at 420/785/985; long source summaries/descriptions cannot resize trailing controls")
    }

    @MainActor static func appStoreVisualChecks() {
        func item(_ index: Int, _ status: AssistedAppStoreItem.Status) -> TaskItemPresentation {
            TaskItemPresentation(id: "app-\(index)", item: DisplayItem(id: "app-\(index)", title: "Application \(index)", status: .information, action: ""),
                state: .unverified, assistedAppStore: AssistedAppStoreItem(appID: String(425264550 + index), status: status))
        }
        func summary(_ rows: [TaskItemPresentation]) -> AppStoreRestorePresentation {
            AppStoreRestorePresentation(domains: [.init(id: "app-store", title: "App Store", symbol: "app", items: rows)])
        }
        let automaticItems = (0..<105).map { index in
            TaskItemPresentation(id: "auto-\(index)", item: DisplayItem(id: "auto-\(index)", title: "Requirement", status: .matching, action: ""), state: index < 101 ? .matching : .planned)
        }
        let automatic = [TaskDomainPresentation(id: "homebrew-casks", title: "Homebrew Applications", symbol: "app", items: automaticItems)]
        let metrics = RestorePreviewMetrics.counts(automatic)
        precondition(metrics.matching == 101 && metrics.changes == 4 && metrics.attention == 0)
        let installed = summary((1...16).map { item($0, .installed) })
        precondition(installed.allInstalled && installed.categoryStatus == "All Installed" && installed.counts.count == 1 && installed.counts[0].1 == 16)
        let mixed = summary([item(1, .unverified), item(2, .installed), item(3, .missing)])
        let large = (0..<2048).map { item($0, [.installed, .missing, .unverified][$0 % 3]) }
        let samples = AppStoreRestoreList.statusSamples(large)
        precondition(samples.count == 3 && samples.allSatisfy { !$0.disclosure })
        precondition(Set(samples.map(\.title)) == ["Installed", "Not in App Store", "Unverified"])
        precondition(AppStoreRestoreList.statusSamples(installed.items).count == 1)
        precondition(AppStoreRestoreList.statusSamples([]).isEmpty)
        precondition(mixed.counts.map { $0.0 } == ["Installed", "Missing", "Unverified"] && mixed.counts.allSatisfy { $0.1 == 1 })
        precondition(mixed.pending.map { AppStoreRestorePresentation.status($0) } == [.missing, .unverified])
        precondition(mixed.categoryState == .attention && !mixed.allInstalled)
        var wording = RestoreResultSummary(domains: [])
        wording.automaticAttentionCount = 1
        wording.manualMissingCount = 1
        wording.manualUnverifiedCount = 2
        precondition(wording.attentionCaption == "1 rebuild issue · 1 app to install · 2 apps to check")
        let unknown = summary([item(1, .unverified)])
        precondition(unknown.categoryState == .unverified && unknown.categoryStatus == "Unverified" && unknown.counts.count == 1)
        precondition(summary([]).counts.isEmpty && !summary([]).allInstalled)
        func progress(_ installedCount: Int, _ missing: Int, _ unverified: Int) -> AppStoreRestorePresentation {
            let statuses = Array(repeating: AssistedAppStoreItem.Status.installed, count: installedCount)
                + Array(repeating: .missing, count: missing) + Array(repeating: .unverified, count: unverified)
            return summary(statuses.enumerated().map { item($0.offset, $0.element) })
        }
        for (snapshot, installedCount, attention, breakdown) in [
            (progress(13, 3, 0), 13, 3, "3 missing"),
            (progress(14, 1, 1), 14, 2, "1 missing · 1 unverified"),
            (installed, 16, 0, ""),
            (progress(0, 0, 16), 0, 16, "16 unverified")] {
            precondition(snapshot.installed.count == installedCount && snapshot.attentionCount == attention && snapshot.attentionBreakdown == breakdown)
        }
        let grouped = RestoreExecutionCategories.orderedRows([
            .init(id: "homebrew-casks", title: "Applications", symbol: "app", items: []),
            .init(id: "vscode-extensions", title: "Extensions", symbol: "app", items: []),
            .init(id: "workspace-folders", title: "Workspace", symbol: "folder", items: [])])
        precondition(grouped.map(\.id) == ["homebrew-casks", "vscode-extensions", "workspace-folders"])
        let withManual = RestoreExecutionCategories.orderedRows([
            .init(id: "homebrew-casks", title: "Applications", symbol: "app", items: []),
            .init(id: "homebrew-packages", title: "Packages", symbol: "app", items: []),
            .init(id: "vscode-extensions", title: "Extensions", symbol: "app", items: []),
            .init(id: "workspace-folders", title: "Workspace", symbol: "folder", items: [])], appStore: mixed)
        precondition(withManual.map(\.id) == ["app-store", "homebrew-casks", "homebrew-packages", "vscode-extensions", "workspace-folders"])
        precondition(withManual.filter { $0.id == "app-store" }.count == 1)
        precondition(RestoreExecutionCategories.orderedRows([]).isEmpty)
        let manualOnly = RestoreExecutionCategories.orderedRows([], appStore: mixed)
        precondition(manualOnly.map(\.id) == ["app-store"])
        let allRows = ImageRenderer(content: AppStoreRestoreList(summary: installed).frame(width: 785)).nsImage!
        precondition(allRows.size.height >= 16 * 28, "All Installed rows are immediately visible")
        let pendingRows = ImageRenderer(content: AppStoreRestoreList(summary: mixed).frame(width: 785)).nsImage!
        precondition(pendingRows.size.height >= 3 * 28, "Missing, Unverified and Installed rows are immediately visible")
        for width in [420.0, 785.0, 985.0] {
            let content = VStack(alignment: .leading, spacing: 20) {
                RestorePreviewMetrics(domains: automatic)
                AppStoreRestoreCard(summary: mixed, review: {})
                AppStoreRestoreMetrics(summary: mixed)
                AppStoreRestoreList(summary: mixed)
                RestoreExecutionCategories(domains: [
                    .init(id: "homebrew-casks", title: "Homebrew Applications", symbol: "app", items: []),
                    .init(id: "workspace-folders", title: "Workspace Folders", symbol: "folder", items: [])],
                    showsWarnings: false, resultStatuses: true, appStore: mixed, reviewAppStore: {})
                AppStoreRestoreResultRow(summary: mixed, review: {}, expansion: .constant(true))
            }.padding(16).frame(width: width).background(Color(nsColor: .windowBackgroundColor))
            let renderer = ImageRenderer(content: content)
            let image = renderer.nsImage!
            precondition(image.size.width == width)
            let data = NSBitmapImageRep(cgImage: renderer.cgImage!).representation(using: .png, properties: [:])!
            try! data.write(to: URL(fileURLWithPath: "build/Debug/AppStore-Final-\(Int(width)).png"))
        }
        let source = try! String(contentsOfFile: "Sources/RestoreView.swift")
        let appScreen = source.components(separatedBy: "struct AppStoreRestoreScreen:")[1].components(separatedBy: "struct AppStoreRestoreActions:")[0]
        // Refresh cancellation belongs beside its progress; navigation stays in the footer.
        let cancelRefreshPattern = #"if\s+model\.isRefreshingAppStore\s*\{\s*Button\s*\(\s*"Cancel Refresh"\s*\)"#
            + #"\s*\{\s*model\.cancelAppStoreRefresh\s*\(\s*\)\s*\}"#
            + #"\s*\.disabled\s*\(\s*!model\.canCancelAppStoreRefresh\s*\)\s*\}"#
        guard let cancelRefresh = appScreen.range(of: cancelRefreshPattern, options: .regularExpression) else {
            preconditionFailure("App Store refresh must retain its operation-gated Cancel Refresh action")
        }
        let remainingScreen = appScreen.replacingCharacters(in: cancelRefresh, with: "")
        let buttonPattern = #"\bButton\s*[({]"#
        precondition(remainingScreen.range(of: buttonPattern, options: .regularExpression) == nil,
            "Cancel Refresh is the only inline action; navigation and refresh stay in the footer")
        precondition(appScreen.contains("No App Store applications selected"))
        let appActions = source.components(separatedBy: "struct AppStoreRestoreActions:")[1]
        precondition(appActions.contains("model.closeAppStore()") && appActions.contains("model.refreshAppStore()")
            && !appActions.contains("model.cancelAppStoreRefresh()"), "Footer retains Back/Refresh without duplicate cancellation")
        precondition(appScreen.contains("Text(\"App Store Applications\")") && !appScreen.contains("selected applications"))
        let metricsSource = source.components(separatedBy: "struct AppStoreRestoreMetrics:")[1].components(separatedBy: "struct AppStoreRestoreList:")[0]
        precondition(metricsSource.contains("!summary.installed.isEmpty") && metricsSource.contains("summary.attentionCount > 0"))
        precondition(metricsSource.contains("value: String(summary.installed.count)") && metricsSource.contains("selected"))
        precondition(metricsSource.contains("value: nil") && metricsSource.contains("summary.attentionBreakdown"))
        let card = source.components(separatedBy: "struct AppStoreRestoreCard:")[1].components(separatedBy: "struct AppStoreRestoreMetrics:")[0]
        precondition(card.contains("WorkspaceCategoryTitle(id: \"app-store\", title: \"App Store Applications\""))
        let noValue = WorkspaceMetricCard(title: "Needs Attention", value: nil, symbol: "exclamationmark.triangle", tint: .orange,
            explanation: "1 missing · 1 unverified")
        precondition(noValue.value == nil && noValue.explanation == "1 missing · 1 unverified")
        let categories = source.components(separatedBy: "struct RestoreExecutionCategories:")[1].components(separatedBy: "struct RestoreResultColumns:")[0]
        precondition(!categories.contains("AppStoreRestoreResultSection") && !categories.contains("AppStoreRestoreCard"))
        precondition(categories.contains("domains.filter { $0.id != \"app-store\" }"))
        let category = source.components(separatedBy: "struct AppStoreRestoreList:")[1].components(separatedBy: "struct AppStoreRestoreScreen:")[0]
        precondition(!category.contains("installedExpanded") && !category.contains("DisclosureGroup("))
        precondition(category.contains("let rows = summary.pending + summary.installed") && category.contains("ForEach(rows)"))
        precondition(!category.contains("expansion") && !category.contains("isExpanded") && !category.contains("RestoreResultCategoryHeader") && !category.contains("chevron"))
        let workspace = try! String(contentsOfFile: "Sources/ProductionWorkspace.swift")
        precondition(workspace.contains("AppStoreRestoreActions(model: restore).modifier(WorkspaceFooterPadding())"))
        print("PASS: App Store inventory immediately visible for installed/missing/unverified, no category header or disclosure, actions/status metrics/fixed footer retained")
    }

    @MainActor static func previewExpansionPerformanceChecks() {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        NSApp.appearance = NSAppearance(named: .aqua)
        func flush(_ host: NSView) {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.005))
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
        }
        func scrollView(_ view: NSView) -> NSScrollView? {
            (view as? NSScrollView) ?? view.subviews.lazy.compactMap(scrollView).first
        }
        let stress = CommandLine.arguments.contains("--stress")
        let counts = stress ? [80, 100, 160] : [16, 21, 24]
        let ids = ["homebrew-casks", "homebrew-packages", "vscode-extensions"]
        func item(_ id: String, _ index: Int) -> TaskItemPresentation {
            let state: TaskRowState = index == 0 ? .attention : index == 1 ? .planned : .matching
            return TaskItemPresentation(id: id, item: DisplayItem(id: id, title: "Requirement " + id,
                status: state == .matching ? .matching : .attention, action: "Existing requirement details"), state: state)
        }
        let settings = ["macos-finder", "macos-windows"].map { id in
            TaskDomainPresentation(id: id, title: CaptureCategory.title(for: id), symbol: WorkspaceCategoryStyle.symbol(id),
                items: (0..<4).map { item("\(id)-\($0)", $0) })
        }
        let domains = zip(ids, counts).map { id, count in
            TaskDomainPresentation(id: id, title: CaptureCategory.title(for: id), symbol: WorkspaceCategoryStyle.symbol(id),
                items: (0..<count).map { item("\(id)-\($0)", $0) })
        } + [TaskDomainPresentation(id: "macos-settings", title: "macOS Settings", symbol: "slider.horizontal.3",
                                   items: settings.flatMap(\.items))]
        let manualItem = TaskItemPresentation(id: "manual", item: DisplayItem(id: "manual", title: "Manual application",
            status: .attention, action: ""), state: .attention,
            assistedAppStore: AssistedAppStoreItem(appID: "123", status: .missing))
        let manual = AppStoreRestorePresentation(domains: [
            TaskDomainPresentation(id: "app-store", title: "App Store Applications", symbol: "app", items: [manualItem])])
        let expansion = PreviewExpansionState()
        let content = PreviewExpansionHost(state: expansion) { binding in AnyView(ScrollView {
            TaskDomainList(domains: domains, leadingContent: AnyView(VStack(alignment: .leading, spacing: 12) {
                WorkspaceSectionHeader(title: "Manual Installation", prominent: true)
                AppStoreRestoreCard(summary: manual, review: {})
            }), restoreSettingsPreview: true, settingsCategories: settings, expansion: binding)
                .padding(28).frame(maxWidth: .infinity, alignment: .leading)
        }) }
        let host = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 785, height: 850),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        flush(host)
        let scroller = scrollView(host)!
        let collapsedHeight = scroller.documentView!.frame.height
        func toggle(_ open: Bool) -> Double {
            // Same synchronous Set assignment used by the production button.
            // Include the native SwiftUI update, layout and display, not just the setter.
            let start = CFAbsoluteTimeGetCurrent()
            expansion.ids = open ? Set(domains.map(\.id)) : []
            flush(host)
            return (CFAbsoluteTimeGetCurrent() - start) * 1000
        }
        var measurements: [[String: Double]] = []
        var scrollSteps: [Double] = []
        for iteration in 0..<3 {
            let expand = toggle(true)
            precondition(expansion.ids == Set(domains.map(\.id)))
            precondition(scroller.documentView!.frame.height > collapsedHeight + CGFloat(counts.reduce(0, +)) * 25,
                "Expanded document retains every application, package and extension row")
            let beforeScroll = CFAbsoluteTimeGetCurrent()
            let document = scroller.documentView!
            scroller.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.frame.height - scroller.contentView.bounds.height)))
            scroller.reflectScrolledClipView(scroller.contentView)
            flush(host)
            precondition(scroller.contentView.bounds.minY > 0)
            let scroll = (CFAbsoluteTimeGetCurrent() - beforeScroll) * 1000
            if iteration == 2 {
                let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath:
                    "build/Debug/RestorePreview-expand-bottom-\(counts.reduce(0, +)).png"))
                for step in 0...20 {
                    let start = CFAbsoluteTimeGetCurrent()
                    scroller.contentView.scroll(to: NSPoint(x: 0,
                        y: max(0, document.frame.height - scroller.contentView.bounds.height) * CGFloat(step) / 20))
                    scroller.reflectScrolledClipView(scroller.contentView)
                    flush(host)
                    scrollSteps.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
                }
            }
            scroller.contentView.scroll(to: .zero); scroller.reflectScrolledClipView(scroller.contentView); flush(host)
            let collapse = toggle(false)
            precondition(expansion.ids.isEmpty && abs(scroller.documentView!.frame.height - collapsedHeight) < 2)
            measurements.append(["expand_ms": expand, "collapse_ms": collapse, "scroll_ms": scroll])
        }
        print("EXPANSION_BENCHMARK", String(data: try! JSONSerialization.data(withJSONObject: [
            "items": counts.reduce(0, +) + 8, "width": 785, "measurements": measurements,
            "scroll_step_max_ms": scrollSteps.max() ?? 0], options: [.sortedKeys]), encoding: .utf8)!)
        let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/Debug/RestorePreview-expand-placement.png"))
    }

    @MainActor static func conciseWorkflowChecks() {
        let cloneFailure = TaskItemPresentation(id: "clone", item: DisplayItem(id: "clone", title: "Repository", status: .attention,
            action: "Failed", reason: "git_clone_authentication_failed"), state: .failed,
            resultLabels: ["Failed", "Mismatch", "Unverified"], sourceDomain: "git-repositories")
        precondition(cloneFailure.resultExplanation == "Git authentication failed. Check access to the repository.")
        precondition(TaskItemPresentation.cloneFailureMessage("private stderr") == nil)
        var cloneSanitizer = OperationLogSanitizer()
        let cloneEvent = try! CoreEvent(line: JSONSerialization.data(withJSONObject: ["protocol_version": 1,
            "operation_id": "clone", "sequence": 1, "type": "operation_record", "data": ["domain": "git-repositories",
            "action": "clone", "outcome": "failure", "reason": "git_clone_authentication_failed", "native_exit_code": 128,
            "stderr": "PRIVATE_SSH_KEY", "remote": "PRIVATE_REMOTE"]]))
        let cloneRecord = cloneSanitizer.event(cloneEvent, at: Date())
        precondition(OperationLogSanitizer.valid(cloneRecord))
        let cloneReport = DiagnosticReportPrivacy.text(DiagnosticReportPrivacy.facts(cloneRecord.facts!))
        precondition(cloneReport.contains("git_clone_authentication_failed") && cloneReport.contains("native_exit_code=128"))
        precondition(!cloneReport.contains("PRIVATE_"))
        for file in ["CaptureView", "CapturePresentation", "RestoreView", "RestoreSummary", "EnvironmentStatusView", "TaskComponents", "ContentView"] {
            let source = try! String(contentsOfFile: "Sources/\(file).swift")
            precondition(!source.contains("Technical Details") && !source.contains("Technical reason"), file)
            precondition(!source.contains("Text(condition.code)") && !source.contains("Text(reason)"), file)
        }
        func condition(_ domain: String, _ index: Int?, code: String = "homebrew_unavailable", scope: String = "operation", diagnostic: CoreRestorePreparation.Diagnostic? = nil) -> CoreRestorePreparation.Condition {
            .init(domain: domain, code: code, status: "external_action_required", selectedItemIndex: index, scope: scope, diagnostic: diagnostic)
        }
        let casks = (1...16).map { condition("homebrew-casks", $0) }
        let ssh = condition("ssh-configuration", nil, code: "ssh_configuration_not_ready")
        let prerequisites = RestorePrerequisiteSummaryPresentation(conditions: casks + [condition("homebrew-packages", 1), ssh], ready: false)
        precondition(prerequisites.conditions.count == 18 && prerequisites.manualConditions.count == 3)
        precondition(Set(prerequisites.manualDomains) == ["homebrew-packages", "homebrew-casks", "ssh-configuration"])
        precondition(!prerequisites.isTerminalReady && prerequisites.sharedReasons["homebrew-casks"] == ["homebrew_unavailable"])
        precondition(RestorePrerequisiteView(condition: ssh, label: "SSH Configuration").message.contains("exclude SSH Configuration"))
        let distinct = [condition("homebrew-casks", 1, scope: "item"), condition("homebrew-casks", 2, scope: "item"),
            condition("homebrew-casks", 1, diagnostic: .init(primitive: "login_item", condition: "authorization_denied")),
            condition("homebrew-casks", 1, diagnostic: .init(primitive: "login_item", condition: "observation_failed"))]
        precondition(RestorePrerequisiteSummaryPresentation(conditions: distinct, ready: false).blockers.count == 4)
        let items = (1...16).map { index in
            TaskItemPresentation(id: "brew-\(index)", item: DisplayItem(id: "brew-\(index)", title: "Application \(index)", status: .attention,
                action: "Couldn’t read Homebrew state.", reason: "homebrew_unavailable"), state: .attention, executionAction: "install",
                resultLabels: ["Unverified"], sourceDomain: "homebrew-casks")
        }
        let domain = TaskDomainPresentation(id: "homebrew-casks", title: "Homebrew Applications", symbol: "app", items: items)
        precondition(domain.sharedObservationReason == "homebrew_unavailable")
        precondition(RestorePreviewMetrics.counts([domain]).attention == 16)
        var ownProblem = items[0]; ownProblem.diagnostic = .init(primitive: "payload", condition: "foreign_target")
        let mixed = TaskDomainPresentation(id: domain.id, title: domain.title, symbol: domain.symbol, items: [ownProblem] + items.dropFirst())
        precondition(!mixed.sharedObservationItemIDs.contains(ownProblem.id) && mixed.sharedObservationItemIDs.count == 15,
            "An item's own diagnosis must remain separate from the shared failure")
        let comparisonItems = items.map { DisplayItem(id: $0.id, title: $0.item.title, status: .unverified, action: "Couldn’t read current state.", reason: "retained") }
        let category = DisplayCategory(id: domain.id, title: domain.title, symbol: domain.symbol, items: comparisonItems)
        var facts: [String: [ComparisonTechnicalFact]] = [:]
        for item in comparisonItems {
            facts[item.id] = [.init(recordID: item.id, predicate: "installed", result: "unverified", reason: "observation_failed", phase: "observation", support: "supported", diagnostics: [])]
        }
        precondition(EnvironmentComparisonDomain(category: category, technicalFacts: facts).sharedObservationFailure)
        facts[comparisonItems[0].id] = [.init(recordID: "independent", predicate: "installed", result: "unverified", reason: "prerequisite_unmet", phase: "observation", support: "supported", diagnostics: [])]
        let partial = EnvironmentComparisonDomain(category: category, technicalFacts: facts).sharedObservationItemIDs
        precondition(partial.count == 15 && !partial.contains(comparisonItems[0].id))
        let raw: [String: Any] = ["protocol_version": 1, "operation_id": "fixture", "sequence": 2, "type": "result", "data": [
            "observation_diagnostics": [["tool": "homebrew", "probe": "metadata", "phase": "observation", "reason": "external_observation_worker", "native_exit_code": 0, "duration_ms": 600, "quiescent": true, "stderr": "PRIVATE_SECRET"]],
            "inventory": (0..<30).map { _ in ["domain": "homebrew-casks", "status": "observation_error", "reason": "observation_failed"] }]]
        var sanitizer = OperationLogSanitizer()
        let log = sanitizer.event(try! CoreEvent(line: JSONSerialization.data(withJSONObject: raw)), at: Date())
        precondition(OperationLogSanitizer.valid(log) && log.omitted == true)
        let failure = log.evidence!.first!
        precondition(failure.codes["reason"] == "external_observation_worker" && failure.counts["native_exit_code"] == 0 && failure.counts["duration_ms"] == 600)
        let report = DiagnosticReportPrivacy.text(DiagnosticReportPrivacy.facts(failure))
        precondition(report.contains("external_observation_worker") && report.contains("native_exit_code=0") && !report.contains("PRIVATE_SECRET"))
        let source = try! String(contentsOfFile: "Sources/RestoreView.swift")
        precondition(source.contains("matching: model.operationID") && source.contains("Rebuild is blocked until"))
        precondition(source.contains("Stopping it may leave some changes already applied") && source.contains("Force Stop"))
        #if DEBUG
        // Reuse the existing long-error fixture, with the actual shared components.
        let scenario = RestoreDebugScenario.issues
        precondition(scenario.domains.flatMap(\.items).contains { ($0.item.reason?.count ?? 0) > 100 })
        let views: [(String, AnyView)] = [
            ("Concise-workflow-result", AnyView(TaskDomainList(domains: scenario.domains, expansion: .constant(Set(scenario.domains.map(\.id)))))),
            ("Concise-workflow-preview", AnyView(VStack(alignment: .leading, spacing: 20) {
                RestorePrerequisiteSummaryView(summary: prerequisites, areas: [
                    .init(domain: "homebrew-casks", label: "Homebrew Applications", selectionMode: "items", availability: "available", reason: nil, items: []),
                    .init(domain: "homebrew-packages", label: "Homebrew Packages", selectionMode: "items", availability: "available", reason: nil, items: []),
                    .init(domain: "ssh-configuration", label: "SSH Configuration", selectionMode: "category", availability: "available", reason: nil, items: [])])
                TaskDomainList(domains: [domain], restoreSettingsPreview: true, expansion: .constant([domain.id]), prerequisiteReasons: prerequisites.sharedReasons)
            }))]
        for (name, view) in views {
            let render = ImageRenderer(content: view.padding(20).frame(width: 900).background(Color(nsColor: .windowBackgroundColor)))
            guard let cg = render.cgImage else { preconditionFailure("No error fixture render") }
            let bitmap = NSBitmapImageRep(cgImage: cg)
            try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/Debug/\(name).png"))
        }
        #endif
        print("PASS: concise workflow disclosures, scoped prerequisites, honest item counts, independent errors, privacy and two error fixture renders")
    }

    @MainActor static func workflowDescendantChecks() {
        _ = NSApplication.shared
        let children = CaptureMacOSSettingsGroup.domainIDs.map { id in
            TaskDomainPresentation(id: id, title: CaptureCategory.title(for: id), symbol: WorkspaceCategoryStyle.symbol(id),
                items: (0..<3).map { index in
                    let key = id + ":" + String(index)
                    return TaskItemPresentation(id: key, item: DisplayItem(id: key, title: "Preference", status: .matching, action: ""),
                        state: .completed, resultLabels: ["Verified"], sourceDomain: id)
                })
        }
        let parent = TaskDomainPresentation(id: "macos-settings", title: "macOS Settings", symbol: "slider.horizontal.3", items: children.flatMap(\.items))
        let state = PreviewExpansionState()
        let ids = RestoreExecutionCategories.disclosureIDs([parent])
        let content = PreviewExpansionHost(state: state) { tree in
            AnyView(HStack {
                ScrollView {
                    RestoreFinalDomain(domain: parent, expansion: WorkflowExpansion.binding(parent.id, in: tree), treeExpansion: tree)
                }
                ScrollView {
                    TaskDomainList(domains: [parent], restoreSettingsPreview: true, settingsCategories: children, expansion: tree)
                }
            }.frame(width: 1458, height: 100))
        }
        let host = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1458, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.close() }
        func scrollers(_ view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollers)
        }
        func heights() -> [Int] {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            return scrollers(host).map { Int($0.documentView!.frame.height) }
        }
        let closed = heights()
        // Children do not exist in either rendered hierarchy yet.
        state.ids = WorkflowExpansion.toggled(state.ids, available: ids)
        let opened = heights()
        state.ids = WorkflowExpansion.toggled(state.ids, available: ids)
        precondition(heights() == closed)
        WorkflowExpansion.binding(parent.id, in: Binding(get: { state.ids }, set: { state.ids = $0 })).wrappedValue = true
        let parentOnly = heights()
        for index in 0..<2 {
            precondition(parentOnly[index] > closed[index] + 200)
            precondition(opened[index] > parentOnly[index] + 250, "Expand All must render every macOS leaf: closed=\(closed), open=\(opened), parent=\(parentOnly)")
        }
        precondition(!WorkflowExpansion.allExpanded(state.ids, available: ids))
        print("PASS: native Result/Preview hidden descendants, recursive collapse and manual parent reopen")
    }

    @MainActor static func workflowStatusScrollChecks() async throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared; NSApp.setActivationPolicy(.accessory); NSApp.appearance = NSAppearance(named: .aqua)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("macseed-scroll-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("modules/core/application-interface"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("config"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for path in ["modules/core/application-interface/core.py", "config/toolkit.conf", "bootstrap.sh", "Fixture.mbt"] { try Data().write(to: dir.appendingPathComponent(path)) }
        try "#!/bin/bash\nexec /usr/bin/python3 -B fixture.py\n".write(to: dir.appendingPathComponent("modules/core/application-interface/core.sh"), atomically: false, encoding: .utf8)
        try """
        import json, sys, pathlib, time
        request = json.loads(sys.stdin.buffer.read())
        assert request['operation'] in ('environment_compare', 'capabilities')
        sequence = 0
        def emit(kind, data=None):
            global sequence
            sequence += 1
            event = dict(protocol_version=1, operation_id=request['operation_id'], sequence=sequence, type=kind)
            if data is not None: event['data'] = data
            print(json.dumps(event), flush=True)
        emit('started')
        if request['operation'] == 'capabilities':
            emit('result', dict(protocol_version=1, product_version='fixture', operations=['environment_compare'], features={'bundle_comparison': {'version': 1}}))
        else:
            time.sleep(.15)
            emit('result', json.loads(pathlib.Path('response.json').read_text()))
        emit('completed')
        """.write(to: dir.appendingPathComponent("fixture.py"), atomically: false, encoding: .utf8)
        var records: [[String: Any]] = []
        var counts = ["matching": 0, "differing": 0, "missing": 0, "unverified": 0, "unsupported": 0, "unresolved": 0, "extra": 0, "unknown_difference": 0]
        for domain in ["homebrew-casks", "homebrew-packages", "vscode-extensions", "app-store", "vscode-settings", "git-configuration"] + CaptureMacOSSettingsGroup.domainIDs + ["workspace-folders", "git-repositories"] {
            for index in 0..<6 {
                let kind = ["matching", "differing", "missing", "unverified"][index % 4]
                counts[kind, default: 0] += 1
                records.append(["record_id": "v:\(domain):\(index)", "domain": domain, "item_id": "setting-\(index)", "comparison_kind": kind, "support": "supported"])
            }
        }
        var payload: [String: Any] = ["read_only": true, "publication_occurred": false, "target_mutation_may_have_started": false,
         "comparison": ["status": "complete", "verdict": "differences_detected", "also_incomplete": true, "counts": counts], "comparison_records": records,
         "verification": ["status": "complete"], "extra": ["domains": [], "items": []], "records": ["status": "complete", "verification_records": [], "coverage_records": [["record_id": "c:empty", "domain": "shell-zsh", "item_id": "scope", "disposition": "no_requirement", "source_status": "absent"]], "operation_records": [], "diagnostics": []]]
        payload["reference_presentation"] = ["groups": [
          ["id": "Applications", "domains": ["homebrew-casks", "app-store", "vscode-extensions"]],
          ["id": "Homebrew", "domains": ["homebrew-packages"]],
          ["id": "macOS Settings", "domains": CaptureMacOSSettingsGroup.domainIDs],
          ["id": "VS Code Settings", "domains": ["vscode-settings"]],
          ["id": "Git", "domains": ["git-configuration"]],
          ["id": "Workspace", "domains": ["workspace-folders", "git-repositories"]]], "app_store_names": [:]] as [String: Any]
        try JSONSerialization.data(withJSONObject: payload).write(to: dir.appendingPathComponent("response.json"))
        let location = CoreLocation(root: dir, python: URL(fileURLWithPath: "/usr/bin/python3"), home: dir, temporaryBase: dir, toolDirectories: [])
        let runtime = CoreRuntime(operationLogs: nil)
        runtime.start(CoreRequest(.capabilities), location: location); await runtime.waitForCompletion()
        precondition(runtime.bundleComparisonSupported == true)
        let model = EnvironmentStatusModel(runtime: runtime, location: location)
        model.selectBundle(dir.appendingPathComponent("Fixture.mbt"))
        let host = NSHostingController(rootView: ProductionWorkspace(runtime: runtime, status: model))
        host.sizingOptions = []
        let window = NSWindow(contentViewController: host); window.isReleasedWhenClosed = false
        MainWindowPolicy.apply(to: window); window.setContentSize(MainWindowPolicy.minimum); window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        func settle() { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03)); host.view.layoutSubtreeIfNeeded(); host.view.displayIfNeeded() }
        func descendants<T: NSView>(_ view: NSView, _: T.Type) -> [T] { (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, T.self) } }
        settle()
        let table = descendants(host.view, NSTableView.self).first!
        table.selectRowIndexes(IndexSet(integer: ProductTask.allCases.firstIndex(of: .status)! + 2), byExtendingSelection: false)
        settle()
        model.compare(); await model.waitForCompletion(); settle()
        precondition(model.state == .result, "\(String(describing: model.failure))")
        func scrollView() -> NSScrollView {
            let lists = descendants(host.view, NSScrollView.self).filter { $0.convert($0.bounds, to: host.view).minX > 220 }
            precondition(lists.count == 1, "Status must own exactly one detail scroll view")
            return lists[0]
        }
        func click(_ point: NSPoint) {
            for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
                window.sendEvent(event)
            }
            settle()
        }
        func toggleAll(_ scroll: NSScrollView) {
            // The real button is immediately above the list, at its trailing edge.
            click(scroll.convert(NSPoint(x: scroll.bounds.width - 30, y: -20), to: nil))
        }
        func wheelTo(_ scroll: NSScrollView, bottom: Bool) {
            let target = bottom ? max(0, scroll.documentView!.frame.height - scroll.contentView.bounds.height) : 0
            let start = scroll.contentView.bounds.minY
            var steps = 0
            while abs(scroll.contentView.bounds.minY - target) > 1 && steps < 100 {
                let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                    wheel1: bottom ? -180 : 180, wheel2: 0, wheel3: 0)!
                // Deliver a native wheel event, never scroll(to:) or a scroll-position binding.
                scroll.scrollWheel(with: NSEvent(cgEvent: event)!)
                settle(); steps += 1
            }
            precondition(abs(scroll.contentView.bounds.minY - target) <= 1, "Wheel must reach \(target), got \(scroll.contentView.bounds.minY)")
            precondition(abs(start - target) < 1 || steps > 0)
        }
        func snapshot(_ size: CGSize) {
            let bitmap = host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds)!
            host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
            try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/Debug/Workflow-Native-Status-\(Int(size.width)).png"))
        }
        for size in [MainWindowPolicy.minimum, MainWindowPolicy.preferred] {
            window.setContentSize(size); settle()
            if model.state == .result { model.compare(); await model.waitForCompletion(); settle() }
            precondition(model.state == .result)
            let scroll = scrollView()
            let frame = scroll.convert(scroll.bounds, to: host.view)
            precondition(frame.minY > 150 && frame.maxY < size.height - 70 && frame.height >= 95,
                "The actual split-view viewport must fit between summary and footer: \(frame)")
            precondition(abs(scroll.contentView.bounds.minY) < 1, "New result starts at the top")
            let collapsed = scroll.documentView!.frame.height
            wheelTo(scroll, bottom: true); wheelTo(scroll, bottom: false)
            toggleAll(scroll)
            let expanded = scroll.documentView!.frame.height
            precondition(expanded > collapsed + 3000, "Expand All must render nested settings and every domain's items")
            wheelTo(scroll, bottom: true)
            precondition(abs(scroll.documentView!.frame.height - scroll.contentView.bounds.maxY) < 2, "Last row must be visible above footer")
            wheelTo(scroll, bottom: false)
            precondition(scroll.convert(scroll.bounds, to: host.view) == frame, "Summary and footer remain fixed while scrolling")
            toggleAll(scroll)
            precondition(abs(scroll.documentView!.frame.height - collapsed) < 2, "Collapse All must remove every descendant")
            // Reopen only the first domain; other domains and macOS descendants stay closed.
            click(scroll.convert(NSPoint(x: 200, y: 65), to: nil))
            precondition(scroll.documentView!.frame.height > collapsed + 100 && scroll.documentView!.frame.height < collapsed + 800)
            toggleAll(scroll); wheelTo(scroll, bottom: true)
            let previousID = model.operationID
            counts["matching", default: 0] += 1
            records.append(["record_id": "v:new:\(Int(size.width))", "domain": "homebrew-casks", "item_id": "new-\(Int(size.width))", "comparison_kind": "matching", "support": "supported"])
            payload["comparison_records"] = records
            payload["comparison"] = ["status": "complete", "verdict": "differences_detected", "also_incomplete": true, "counts": counts]
            try JSONSerialization.data(withJSONObject: payload).write(to: dir.appendingPathComponent("response.json"))
            // Use the actual fixed footer's Check Again button, with the list at the bottom.
            click(host.view.convert(NSPoint(x: size.width - 90, y: size.height - 62), to: nil))
            await model.waitForCompletion(); settle()
            precondition(model.operationID != previousID && model.state == .result, "Check Again must execute the fixture request")
            precondition(model.presentation?.counts["matching"] == counts["matching"], "The new result must contain the changed fixture data")
            let fresh = scrollView()
            precondition(abs(fresh.contentView.bounds.minY) < 1 && abs(fresh.documentView!.frame.height - collapsed) < 2,
                "Fresh Comparison resets scroll and disclosure state")
            wheelTo(fresh, bottom: true); wheelTo(fresh, bottom: false)
            snapshot(size)
            print("PASS: native ProductionWorkspace Status \(Int(size.width))x\(Int(size.height)), viewport \(Int(frame.height))pt; wheel top-bottom-top, recursive buttons, last row and fresh Check Again")
        }
    }


    @MainActor static func workflowInteractiveControlsChecks() {
        _ = NSApplication.shared
        // With no status/count pixels, any visible pixel would be a phantom arrow.
        for expanded: Bool? in [nil, false, true] {
            let view = RestoreTrailingControls(status: Color.clear.frame(width: 10, height: 20), counts: [], expanded: expanded)
                .frame(width: 200)
            let bitmap = NSBitmapImageRep(cgImage: ImageRenderer(content: view).cgImage!)
            let hasInk = (0..<bitmap.pixelsHigh).contains { y in
                (0..<bitmap.pixelsWide).contains { x in (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 }
            }
            precondition(hasInk == (expanded != nil), "A leaf must render no disclosure indicator")
        }
        let runtime = CoreRuntime(operationLogs: nil)
        let capture = CaptureModel(runtime: runtime)
        let restore = RestoreModel(runtime: runtime)
        func check<V: View>(_ view: V, boxes: Int) {
            let host = NSHostingView(rootView: view.frame(width: 720))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
            defer { window.close() }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)); host.layoutSubtreeIfNeeded()
            func buttons(_ view: NSView) -> [NSButton] { (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons) }
            let actual = buttons(host).filter { $0.target is NativeSelectionCheckbox.Coordinator }
            precondition(actual.count == boxes, "Expected \(boxes) real checkboxes, got \(actual.count)")
            precondition(actual.allSatisfy { $0.isEnabled && $0.target != nil && $0.action != nil })
        }
        for selectable in [true, false] {
            let row = try! JSONDecoder().decode(CoreCaptureInventoryRow.self, from: JSONSerialization.data(withJSONObject: [
                "domain": "macos-screenshots", "status": selectable ? "present" : "unavailable", "selection_mode": "category",
                "items": [], "included_settings": selectable ? [["id": "location", "label": "Save location"]] : []]))
            let category = CaptureCategory(row: row)
            check(CaptureSettingsSubcategoryView(model: capture, category: category, expansion: .constant(true)), boxes: selectable ? 1 : 0)
            check(CaptureSettingsSubcategoryView(model: capture, category: category, editable: false, expansion: .constant(true)), boxes: 0)
            for mode in ["category", "items"] {
                let area = CoreRestoreInspection.Area(domain: "macos-screenshots", label: "Screenshots", selectionMode: mode,
                    availability: selectable ? "available" : "unavailable", reason: nil, items: [.init(itemID: "location", label: "Save location")])
                check(RestoreAreaSelectionView(model: restore, area: area, expansion: .constant(true)), boxes: selectable ? (mode == "items" ? 2 : 1) : 0)
                let captureRow = try! JSONDecoder().decode(CoreCaptureInventoryRow.self, from: JSONSerialization.data(withJSONObject: [
                    "domain": "homebrew-casks", "status": selectable ? "present" : "unavailable", "selection_mode": mode,
                    "items": [["item_id": "fixture", "label": "Fixture"]]]))
                check(CaptureCategorySelectionView(model: capture, category: CaptureCategory(row: captureRow), expansion: .constant(true)), boxes: selectable ? (mode == "items" ? 2 : 1) : 0)
            }
        }
        check(CaptureMacOSSettingsView(model: capture), boxes: 0)
        precondition(runtime.state == .idle && capture.selectedItems.isEmpty && restore.selectedItems.isEmpty)
        print("PASS: leaf arrows absent; only supported selection creates enabled native checkboxes; category-only settings retain category selection")
    }

    @MainActor static func workflowLayoutChecks() {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        NSApp.appearance = NSAppearance(named: .aqua)
        let runtime = CoreRuntime()
        var selection: Set<String> = ["selected"]
        var selectionCalls = 0
        func item(_ domain: String, _ index: Int) -> TaskItemPresentation {
            let id = domain + ":" + String(index)
            let state: TaskRowState = index == 0 ? .planned : index == 1 ? .attention : .matching
            return TaskItemPresentation(id: id, item: DisplayItem(id: id, title: "Supported preference \(index)",
                status: state == .matching ? .matching : .attention, action: ""), state: state,
                resultLabels: state == .attention ? ["Failed"] : ["Verified"], sourceDomain: domain)
        }
        let children = CaptureMacOSSettingsGroup.domainIDs.map { id in
            TaskDomainPresentation(id: id, title: CaptureCategory.title(for: id), symbol: WorkspaceCategoryStyle.symbol(id),
                items: (0..<6).map { item(id, $0) })
        }
        let domains = [TaskDomainPresentation(id: "macos-settings", title: "macOS Settings", symbol: "slider.horizontal.3", items: children.flatMap(\.items)),
            TaskDomainPresentation(id: "vscode-extensions", title: "VS Code Extensions", symbol: "puzzlepiece", items: (0..<24).map { item("vscode-extensions", $0) })]
        let ids = TaskDomainList.disclosureIDs(domains, settings: children)
        precondition(ids.count == 8 && Set(children.map(\.id)).isSubset(of: ids))
        precondition(RestoreExecutionCategories.disclosureIDs(domains) == ids)
        precondition(!WorkflowExpansion.allExpanded([], available: []) && WorkflowExpansion.toggled([], available: []).isEmpty)
        precondition(!WorkflowExpansion.allExpanded(Set(domains.map(\.id)), available: ids), "Open parents alone must still say Expand All")
        let expansion = PreviewExpansionState()
        let binding = Binding(get: { expansion.ids }, set: { expansion.ids = $0 })
        expansion.ids = WorkflowExpansion.toggled([], available: ids)
        precondition(children.allSatisfy { WorkflowExpansion.binding($0.id, in: binding).wrappedValue }, "Children must expand before their views exist")
        WorkflowExpansion.binding(children[0].id, in: binding).wrappedValue = false
        precondition(!WorkflowExpansion.allExpanded(expansion.ids, available: ids))
        expansion.ids = WorkflowExpansion.toggled(expansion.ids, available: ids)
        precondition(WorkflowExpansion.allExpanded(expansion.ids, available: ids))
        expansion.ids = WorkflowExpansion.toggled(expansion.ids, available: ids)
        WorkflowExpansion.binding("macos-settings", in: binding).wrappedValue = true
        precondition(children.allSatisfy { !WorkflowExpansion.binding($0.id, in: binding).wrappedValue })

        // The presentation consumes the existing logical counters; raw records and
        // precise leaf statuses remain separate, including unsupported attention.
        let finderCounts: [ComparisonOutcome: Int] = [.match: 10, .different: 1, .missing: 1]
        let macCounts: [ComparisonOutcome: Int] = [.match: 31, .different: 6, .missing: 1, .needsAttention: 2]
        precondition(EnvironmentComparisonDomain.badgeCounts(finderCounts).map { $0.1 } == [10, 2])
        precondition(EnvironmentComparisonDomain.badgeCounts(macCounts).map { $0.1 } == [31, 7, 2])
        precondition(EnvironmentComparisonDomain.badgeCounts([.missing: 2]).first?.0 == "Differences Found")
        precondition(EnvironmentComparisonDomain.badgeCounts([:]).isEmpty)
        precondition(finderCounts[.different] == 1 && finderCounts[.missing] == 1)
        var records: [[String: Any]] = []
        var counts = ["matching": 0, "differing": 0, "missing": 0, "unverified": 0, "unsupported": 0, "unresolved": 0, "extra": 0, "unknown_difference": 0]
        for domain in CaptureMacOSSettingsGroup.domainIDs {
            for index in 0..<6 {
                let kind = index == 0 ? "differing" : index == 1 ? "missing" : "matching"
                counts[kind, default: 0] += 1
                records.append(["record_id": "v:\(domain):\(index)", "domain": domain, "item_id": "setting-\(index)", "comparison_kind": kind, "support": "supported"])
            }
        }
        let payload: [String: Any] = ["read_only": true, "publication_occurred": false, "target_mutation_may_have_started": false,
            "comparison": ["status": "complete", "verdict": "differences_detected", "also_incomplete": false, "counts": counts],
            "comparison_records": records, "verification": ["status": "complete"], "extra": ["domains": [], "items": []],
            "records": ["status": "complete", "verification_records": [], "coverage_records": [], "operation_records": [], "diagnostics": []]]
        let result = try! EnvironmentStatusPresentation(JSONDecoder().decode(CoreComparisonResult.self, from: JSONSerialization.data(withJSONObject: payload)))
        let statusIDs = EnvironmentComparisonView.disclosureIDs(result)
        precondition(statusIDs == Set(["macos-settings"] + children.map(\.id)))
        precondition(result.categories.flatMap(\.items).filter { $0.status == .different }.count == 6)
        precondition(result.categories.flatMap(\.items).filter { $0.status == .missing }.count == 6)
        precondition(ComparisonSummaryOutcome.differences.explanation(result) == "6 Different · 6 Missing")
        precondition(ComparisonSummaryOutcome.differences.count(result) == 12)
        let selectable = TaskDomainList(domains: domains, selectionStates: ["vscode-extensions": .all], selectDomain: { id, included in
            selectionCalls += 1
            if included { selection.insert(id) } else { selection.remove(id) }
        }, settingsCategories: children, expansion: binding)
        _ = ImageRenderer(content: selectable.frame(width: 729)).cgImage
        expansion.ids = WorkflowExpansion.toggled(expansion.ids, available: ids)
        _ = ImageRenderer(content: selectable.frame(width: 729)).cgImage
        precondition(selection == ["selected"] && selectionCalls == 0)
        print("PASS: logical Status aggregation, precise leaves and recursive all/partial/collapse state")

        // Real pills, one to three digits, retain their original oval dimensions.
        for count in [1, 10, 100] {
            let image = ImageRenderer(content: WorkflowCountPill(count: count, label: "Match", tint: .green)).cgImage!
            precondition(image.height == 23 && image.width >= 32 && image.width > image.height)
        }
        for width: CGFloat in [420, 729, 929] {
            let probe = VStack(spacing: 10) {
                ForEach(0..<3) { row in
                    RestoreResultColumns {
                        Text("Category").padding(.leading, CGFloat(row) * 16)
                        WorkflowTrailingLayout(showsCounts: true, showsChevron: true) {
                            Color(red: 1, green: 0, blue: 0).frame(width: CGFloat(60 + row * 40), height: 8)
                            Color(red: 0, green: 0, blue: 1).frame(width: CGFloat(32 + row * 38), height: 8)
                            Color(red: 0, green: 1, blue: 0).frame(width: 12, height: 8)
                            Color.clear.frame(width: 108, height: 0)
                        }
                        Color.clear.frame(width: 280, height: 0)
                    }
                }
            }.frame(width: width)
            let bitmap = NSBitmapImageRep(cgImage: ImageRenderer(content: probe).cgImage!)
            var starts = [Set<Int>(), Set<Int>(), Set<Int>()]
            for y in 0..<bitmap.pixelsHigh {
                var found = Set<Int>()
                for x in 0..<bitmap.pixelsWide {
                    guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.9 else { continue }
                    let kind: Int? = c.redComponent > 0.8 && c.greenComponent < 0.2 ? 0
                        : c.blueComponent > 0.8 && c.redComponent < 0.2 ? 1
                        : c.greenComponent > 0.4 && c.redComponent < 0.2 && c.blueComponent < 0.4 ? 2 : nil
                    if let kind, found.insert(kind).inserted { starts[kind].insert(x) }
                }
            }
            precondition(starts.allSatisfy { $0.count == 1 }, "Stable status/count/arrow origins: \(starts)")
            precondition(starts[2].first! == Int(width) - 12, "Chevron stays at the right edge")
        }
        print("PASS: oval 1/10/100 counts and shared count/arrow rails at narrow and normal widths")

        let manualItem = TaskItemPresentation(id: "manual", item: DisplayItem(id: "manual", title: "Manual application", status: .matching, action: ""), state: .matching,
            assistedAppStore: AssistedAppStoreItem(appID: "123", status: .installed))
        let manual = AppStoreRestorePresentation(domains: [.init(id: "app-store", title: "App Store Applications", symbol: "app", items: [manualItem])])
        let prerequisites = RestorePrerequisiteSummaryPresentation(conditions: [
            .init(domain: "homebrew-packages", code: "homebrew_unavailable", status: "external_action_required", selectedItemIndex: nil, scope: "operation")], ready: false, hasInstallerPreparations: true)
        func scrollViews(_ view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
        }
        func flush(_ host: NSView) {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        }
        for (task, name) in [(ProductTask.capture, "Capture"), (.restore, "Restore-Preview"), (.status, "Status")] {
            for size in [MainWindowPolicy.preferred, MainWindowPolicy.minimum] {
                var anchors: [String: CGRect] = [:]
                expansion.ids = []
                let content = PreviewExpansionHost(state: expansion) { binding in
                    AnyView(HStack(spacing: 0) {
                        Color(nsColor: .controlBackgroundColor).frame(width: 223)
                        VStack(spacing: 0) {
                            WorkflowContentViewport(pinned: true) {
                                VStack(alignment: .leading, spacing: 12) {
                                    WorkspaceHeader(title: task.title, subtitle: task.subtitle, symbol: task.symbol)
                                        .background(GeometryReader { proxy in Color.clear.preference(key: WorkflowAnchorFrames.self, value: ["header": proxy.frame(in: .named("workflow"))]) })
                                    if task == .capture {
                                        CaptureResultContent(result: CaptureResultPresentation(publication:
                                            .init(publicationOccurred: true, destination: "/Users/Example/Environments/My Mac.mbt", preparedCaptureID: String(repeating: "a", count: 64),
                                                bundle: .init(formatVersion: 1, selectedCategories: ["macos-finder"], selectedItemCounts: ["homebrew-packages": 60], secureComponent: false)), notices: []))
                                    } else if task == .restore {
                                        Label("My Mac.mbt", systemImage: "shippingbox").font(.headline)
                                        RestorePreviewContent(title: "Needs Attention", state: .attention, domains: domains,
                                            alreadyMatches: false, prerequisites: prerequisites,
                                            areas: [.init(domain: "homebrew-packages", label: "Homebrew Packages", selectionMode: "items", availability: "available", reason: nil, items: [])],
                                            settingsCategories: children, appStore: manual, reviewAppStore: {}, showsActions: false,
                                            retryMessage: "Review the prerequisites before rebuilding.", checkAgain: {})
                                    } else {
                                        Label("My Mac.mbt", systemImage: "shippingbox").font(.headline)
                                        Text(result.headline).font(.title2.weight(.semibold))
                                        EnvironmentComparisonView(result: result, categoryExpansion: binding)
                                    }
                                }.modifier(WorkspaceContentGeometry())
                            }
                            Divider()
                            HStack { if task != .restore { Text("View Log") }; Spacer(); Button(task == .capture ? "Done" : task == .restore ? "Rebuild" : "Check Again") {} }
                                .modifier(WorkspaceFooterPadding())
                                .background(GeometryReader { proxy in Color.clear.preference(key: WorkflowAnchorFrames.self, value: ["footer": proxy.frame(in: .named("workflow"))]) })
                            Divider()
                            Text("Macseed").font(.caption).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.frame(width: size.width, height: size.height).background(Color(nsColor: .windowBackgroundColor))
                        .coordinateSpace(name: "workflow").onPreferenceChange(WorkflowAnchorFrames.self) { anchors = $0 })
                }
                let host = NSHostingView(rootView: content)
                let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
                flush(host)
                let scrollers = scrollViews(host)
                precondition(scrollers.count == 1, "\(name) must have one list viewport, got \(scrollers.count)")
                let scroll = scrollers[0]
                precondition(scroll.contentView.bounds.height >= 95, "\(name) list collapsed at \(size): \(scroll.contentView.bounds)")
                let collapsedHeight = scroll.documentView!.frame.height
                let fixed = anchors
                precondition(fixed.count == 2)
                precondition(fixed["header"]!.minY >= 0 && fixed["footer"]!.maxY <= size.height - 30,
                    "All fixed content must remain inside the window: \(name) \(size) \(fixed)")
                if task != .restore { expansion.ids = WorkflowExpansion.toggled([], available: task == .status ? statusIDs : ids) }
                flush(host)
                if task == .status { precondition(scroll.documentView!.frame.height > collapsedHeight + 200, "Hidden descendants must render after Expand All") }
                if task == .capture { precondition(scroll.documentView!.frame.height == collapsedHeight, "Result has no hidden category inventory") }
                let bottom = max(0, scroll.documentView!.frame.height - scroll.contentView.bounds.height)
                scroll.contentView.scroll(to: CGPoint(x: 0, y: bottom)); scroll.reflectScrolledClipView(scroll.contentView); flush(host)
                precondition(abs(scroll.contentView.bounds.minY - bottom) < 2, "Last row must be reachable")
                precondition(anchors == fixed, "Header/footer must not scroll")
                let expandedBeforeRefresh = expansion.ids
                expansion.objectWillChange.send(); flush(host)
                precondition(expansion.ids == expandedBeforeRefresh && abs(scroll.contentView.bounds.minY - bottom) < 2,
                    "Ordinary view refresh must preserve disclosure and scroll position")
                let viewport = scroll.convert(scroll.bounds, to: host)
                precondition(viewport.minX >= 223 && viewport.minY >= 0 && viewport.maxY <= host.bounds.height)
                print("WORKFLOW \(name) \(Int(size.width))x\(Int(size.height)): list=\(Int(scroll.contentView.bounds.height)), document=\(Int(scroll.documentView!.frame.height)), fixed header/footer, bottom reached")
                // Show the top of the tree for visual review; no screenshot matrix.
                scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView); flush(host)
                let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/Debug/Workflow-\(name)-\(Int(size.width)).png"))
                window.close()
            }
        }
        precondition(selection == ["selected"] && selectionCalls == 0)
        precondition(runtime.state == .idle && runtime.operation == nil && runtime.events.isEmpty)
        print("PASS: bounded native Capture/Preview/Status viewports at preferred/minimum sizes, fixed chrome, selection and Core inactivity")
    }

    @MainActor static func finalCapturePreviewAlignmentChecks() async throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared; NSApp.setActivationPolicy(.accessory); NSApp.appearance = NSAppearance(named: .aqua)
        // Only a disposable protocol fixture supplies the selection model. No
        // real discovery, capture, restore or system inspection is performed.
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("macseed-alignment-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("modules/core/application-interface"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("config"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["modules/core/application-interface/core.py", "config/toolkit.conf", "bootstrap.sh"] { try Data().write(to: root.appendingPathComponent(path)) }
        try "#!/bin/bash\nexec /usr/bin/python3 -B fixture.py\n".write(to: root.appendingPathComponent("modules/core/application-interface/core.sh"), atomically: false, encoding: .utf8)
        try """
        import json, sys
        request = json.loads(sys.stdin.buffer.read())
        assert request['operation'] == 'capture_prepare' and request['parameters']['selection'] is None
        rows = [dict(domain='macos-' + name, status='present', selection_mode='category', items=[],
                     included_settings=[dict(id='preference', label='Supported preference')])
                for name in ['finder', 'dock', 'windows', 'keyboard', 'trackpad', 'screenshots']]
        result = dict(prepared_capture_id='a'*64, inventory=rows, selection=None,
                      summary=dict(selected_domains=0, selected_items=0, secure_identity_count=0),
                      secure_identities=dict(status='unavailable', items=[]))
        for sequence, (kind, data) in enumerate([('started', {}), ('result', result), ('completed', {})], 1):
            print(json.dumps(dict(protocol_version=1, operation_id=request['operation_id'], sequence=sequence, type=kind, data=data)), flush=True)
        """.write(to: root.appendingPathComponent("fixture.py"), atomically: false, encoding: .utf8)
        let runtime = CoreRuntime()
        let model = CaptureModel(runtime: runtime, location: CoreLocation(root: root, python: URL(fileURLWithPath: "/usr/bin/python3"),
            home: root, temporaryBase: root, toolDirectories: []))
        model.scan(); await model.waitForCompletion()
        precondition(model.state == .review && model.macOSSettings.state == .all)
        let selection = model.selection
        func item(_ id: String, _ title: String, state: TaskRowState, role: CaptureItemRole? = nil) -> TaskItemPresentation {
            TaskItemPresentation(id: id, item: DisplayItem(id: id, title: title, status: .ready, action: ""),
                state: state, captureRole: role)
        }
        func settings(_ state: TaskRowState) -> [TaskDomainPresentation] {
            CaptureMacOSSettingsGroup.domainIDs.map { id in
                .init(id: id, title: CaptureCategory.title(for: id), symbol: WorkspaceCategoryStyle.symbol(id),
                      items: [item(id + ":saved", "Supported configuration", state: state, role: .selectedSubdomain)])
            }
        }
        let ready = settings(.planned)
        let confirmation = [
            TaskDomainPresentation(id: "macos-settings", title: "macOS Settings", symbol: "slider.horizontal.3", items: ready.flatMap(\.items)),
            TaskDomainPresentation(id: "vscode-settings", title: "VS Code Settings", symbol: "curlybraces",
                items: [item("json", "JSON configuration", state: .planned, role: .configuration)])]
        let saved = ["homebrew-casks", "app-store", "homebrew-packages", "vscode-extensions"].map { id in
            TaskDomainPresentation(id: id, title: CaptureCategory.title(for: id), symbol: WorkspaceCategoryStyle.symbol(id),
                items: (1...12).map { item(id + String($0), "Application \($0) with a longer name", state: .completed) })
        }
        func flush(_ host: NSView) {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        }
        func snapshot(_ host: NSView, _ name: String) throws {
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/Debug/Alignment-" + name + ".png"))
        }
        for width: CGFloat in [721, 921] {
            let content = HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Capture Selection").font(.title2)
                    CaptureMacOSSettingsView(model: model, childExpansion: .constant(false))
                        .modifier(WorkspaceCardSurface())
                }.frame(width: width)
                VStack(alignment: .leading, spacing: 20) {
                    Text("Save this environment?").font(.title2)
                    TaskDomainList(domains: confirmation, stateTitles: [.planned: "Ready to Save"], compactReadyItems: true,
                        settingsCategories: ready, expansion: .constant(["macos-settings"]), settingsExpansion: .constant(false))
                }.frame(width: width)
                VStack(alignment: .leading, spacing: 20) {
                    Text("Environment Saved").font(.title2)
                    TaskDomainList(domains: saved, compactReadyItems: true, captureResultLayout: true,
                        expansion: .constant(Set(saved.map(\.id))))
                }.frame(width: width)
            }.padding(20).frame(height: 1350, alignment: .top).background(Color(nsColor: .windowBackgroundColor))
            let host = NSHostingView(rootView: content)
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width * 3 + 80, height: 1350),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil); flush(host)
            try snapshot(host, "Capture-\(Int(width))")
            window.close()
        }
        precondition(model.selection == selection, "Rendering must preserve selection")
        model.toggleAll(); precondition(model.macOSSettings.state == .none)
        model.toggleAll(); precondition(model.selection == selection)
        model.selectCategory("macos-finder", included: false); precondition(model.macOSSettings.state == .mixed)
        model.selectCategory("macos-finder", included: true); precondition(model.selection == selection)
        print("PASS: Selection, Confirmation and wrapping Result fixtures at 721/921pt; selection/bulk controls preserved")

        let prerequisites = RestorePrerequisiteSummaryPresentation(conditions: [
            .init(domain: "homebrew-casks", code: "cask_execution_requirements_unsupported", status: "unsupported",
                selectedItemIndex: 1, scope: "item", diagnostic: .init(primitive: "pkgutil", condition: "preparation_required")),
            .init(domain: "ssh-configuration", code: "ssh_configuration_not_ready", status: "external_action_required", selectedItemIndex: nil, scope: "operation")
        ], ready: false, hasInstallerPreparations: true)
        precondition(prerequisites.canFixIssues && prerequisites.manualDomains == ["ssh-configuration"])
        let previewDomains = saved.filter { $0.id != "app-store" }.map { domain in
            TaskDomainPresentation(id: domain.id, title: domain.title, symbol: domain.symbol, items: domain.items.enumerated().map { index, saved in
                let state: TaskRowState = index == 0 ? .attention : index == 1 ? .matching : .planned
                return TaskItemPresentation(id: saved.id, item: DisplayItem(id: saved.id, title: saved.item.title,
                    status: state == .matching ? .matching : state == .planned ? .missing : .attention, action: ""), state: state)
            })
        }
        func scrollViews(_ view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
        }
        for size in [MainWindowPolicy.minimum, MainWindowPolicy.preferred] {
            var anchors: [String: CGRect] = [:]
            let content = HStack(spacing: 0) {
                Color(nsColor: .controlBackgroundColor).frame(width: 223)
                VStack(spacing: 0) {
                    WorkflowContentViewport(pinned: true) {
                        VStack(alignment: .leading, spacing: 12) {
                            WorkspaceHeader(title: ProductTask.restore.title, subtitle: ProductTask.restore.subtitle, symbol: ProductTask.restore.symbol)
                            RestorePreviewContent(title: "Needs Attention", state: .attention, domains: previewDomains, alreadyMatches: false,
                                prerequisites: prerequisites,
                                areas: [.init(domain: "ssh-configuration", label: "SSH Configuration", selectionMode: "category",
                                    availability: "available", reason: nil, items: [])],
                                categoryExpansion: .constant(true), showsActions: false, checkAgain: {})
                        }.modifier(WorkspaceContentGeometry())
                    }
                    Divider()
                    HStack { Button("Back") {}; Spacer(); Button("Rebuild") {}.disabled(true) }
                        .modifier(WorkspaceFooterPadding())
                        .background(GeometryReader { proxy in Color.clear.preference(key: WorkflowAnchorFrames.self, value: ["footer": proxy.frame(in: .named("alignment"))]) })
                }
            }.frame(width: size.width, height: size.height).background(Color(nsColor: .windowBackgroundColor))
                .coordinateSpace(name: "alignment").onPreferenceChange(WorkflowAnchorFrames.self) { anchors = $0 }
            let host = NSHostingView(rootView: content)
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil); flush(host)
            let scrollers = scrollViews(host)
            precondition(scrollers.count == 1 && scrollers[0].contentView.bounds.height >= 96)
            let scroll = scrollers[0], fixed = anchors
            let bottom = max(0, scroll.documentView!.frame.height - scroll.contentView.bounds.height)
            precondition(bottom > 0)
            scroll.contentView.scroll(to: CGPoint(x: 0, y: bottom)); scroll.reflectScrolledClipView(scroll.contentView); flush(host)
            precondition(abs(scroll.contentView.bounds.minY - bottom) < 2 && anchors == fixed)
            scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView); flush(host)
            try snapshot(host, "Restore-\(Int(size.width))")
            print("PASS: Preview \(Int(size.width))x\(Int(size.height)), viewport \(Int(scroll.contentView.bounds.height))pt, bottom reachable, footer fixed")
            window.close()
        }
    }

    @MainActor static func restorePreviewNoticesChecks() {
        setbuf(stdout, nil)
        _ = NSApplication.shared; NSApp.setActivationPolicy(.accessory); NSApp.appearance = NSAppearance(named: .aqua)
        let topology = CoreRestorePreparation.Condition(domain: "Workspace", code: "workspace_restore_not_enabled",
            status: "unsupported", selectedItemIndex: nil, scope: "operation")
        let pkg = CoreRestorePreparation.Condition(domain: "homebrew-casks", code: "cask_execution_requirements_unsupported",
            status: "unsupported", selectedItemIndex: 1, scope: "item", diagnostic: .init(primitive: "pkgutil", condition: "preparation_required"))
        let ssh = CoreRestorePreparation.Condition(domain: "ssh-configuration", code: "ssh_configuration_not_ready",
            status: "external_action_required", selectedItemIndex: nil, scope: "operation")
        let brew = CoreRestorePreparation.Condition(domain: "homebrew-packages", code: "homebrew_unavailable",
            status: "external_action_required", selectedItemIndex: nil, scope: "operation")
        let areas = [("ssh-configuration", "SSH Configuration"), ("homebrew-packages", "Homebrew Packages")].map {
            CoreRestoreInspection.Area(domain: $0.0, label: $0.1, selectionMode: "category", availability: "available", reason: nil, items: [])
        }
        let domain = TaskDomainPresentation(id: "homebrew-casks", title: "Homebrew Applications", symbol: "app",
            items: (1...16).map { index in
                TaskItemPresentation(id: String(index), item: DisplayItem(id: String(index), title: "Application \(index)",
                    status: .missing, action: ""), state: .planned)
            })
        let scenarios: [(String, [CoreRestorePreparation.Condition], Bool, CGSize)] = [
            ("Ready", [], false, MainWindowPolicy.minimum),
            ("Topology-Preview", [topology], false, MainWindowPolicy.minimum),
            ("Topology-With-Manual", [topology, ssh], false, MainWindowPolicy.minimum),
            ("One-Manual", [ssh], false, MainWindowPolicy.minimum),
            ("Preparation-Only", [pkg], true, MainWindowPolicy.minimum),
            ("Multiple", [pkg, ssh, brew], true, MainWindowPolicy.minimum),
            ("Multiple-Wide", [pkg, ssh, brew], true, MainWindowPolicy.preferred)]
        func scrollViews(_ view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
        }
        func flush(_ host: NSView) {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        }
        for (name, conditions, canFix, size) in scenarios {
            let summary = RestorePrerequisiteSummaryPresentation(conditions: conditions, ready: conditions.isEmpty, hasInstallerPreparations: canFix)
            let preview = RestorePreviewContent(title: "", state: .planned, domains: [domain], alreadyMatches: false,
                previewEvaluated: true, prerequisites: summary, areas: areas, categoryExpansion: .constant(true), showsActions: false, checkAgain: {})
            precondition(preview.showsFixIssues == canFix)
            precondition(preview.showsPrerequisites == (canFix || conditions.contains { $0.code == ssh.code || $0.code == brew.code }))
            var anchors: [String: CGRect] = [:]
            let content = HStack(spacing: 0) {
                Color(nsColor: .controlBackgroundColor).frame(width: 223)
                VStack(spacing: 0) {
                    WorkflowContentViewport(pinned: true) {
                        VStack(alignment: .leading, spacing: 12) {
                            WorkspaceHeader(title: ProductTask.restore.title, subtitle: ProductTask.restore.subtitle, symbol: ProductTask.restore.symbol)
                            preview
                        }.modifier(WorkspaceContentGeometry())
                    }
                    Divider()
                    HStack { Button("Back") {}; Spacer(); Button("Rebuild") {}.disabled(!conditions.isEmpty) }
                        .modifier(WorkspaceFooterPadding())
                        .background(GeometryReader { proxy in Color.clear.preference(key: WorkflowAnchorFrames.self,
                            value: ["footer": proxy.frame(in: .named("notices"))]) })
                }
            }.frame(width: size.width, height: size.height).background(Color(nsColor: .windowBackgroundColor))
                .coordinateSpace(name: "notices").onPreferenceChange(WorkflowAnchorFrames.self) { anchors = $0 }
            let host = NSHostingView(rootView: content)
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil); flush(host)
            let scrollers = scrollViews(host)
            precondition(scrollers.count == 1 && scrollers[0].contentView.bounds.height >= 96)
            let scroll = scrollers[0], fixed = anchors
            let viewport = scroll.convert(scroll.bounds, to: host)
            precondition(viewport.minY >= 0 && viewport.maxY <= fixed["footer"]!.minY && fixed["footer"]!.maxY <= size.height)
            let bottom = max(0, scroll.documentView!.frame.height - scroll.contentView.bounds.height)
            scroll.contentView.scroll(to: CGPoint(x: 0, y: bottom)); scroll.reflectScrolledClipView(scroll.contentView); flush(host)
            precondition(abs(scroll.contentView.bounds.minY - bottom) < 2 && anchors == fixed)
            scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView); flush(host)
            // Bounded Preview cases, without the Capture/Status render matrix.
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/Debug/Preview-Notices-\(name).png"))
            print("PASS: \(name), \(Int(size.width))x\(Int(size.height)), Fix Issues=\(canFix), viewport=\(Int(scroll.contentView.bounds.height)), footer fixed, bottom reachable")
            window.close()
        }
    }

    static func topologyPreviewChecks() {
        let ready = RestorePrerequisiteSummaryPresentation(conditions: [], ready: true)
        precondition(ready.isTerminalReady && !ready.needsAttention && ready.operationAvailabilityMessage == nil)
        precondition(OperationLogSanitizer.vocabularies["predicate"]?.contains("topology") == true)
        precondition(RestorePreviewPresentation.readyText(action: "add_worktree") == "Ready to Create")
        let shared = CoreRestorePreparation.workspacePreviewReasons["workspace_checkout_destination"]!
        precondition(shared.contains("no separate folder creation"))
        let gate = CoreRestorePreparation.Condition(domain: "Workspace", code: "workspace_restore_not_enabled",
            status: "unsupported", selectedItemIndex: nil, scope: "operation")
        let onlyGate = RestorePrerequisiteSummaryPresentation(conditions: [gate], ready: false)
        precondition(!onlyGate.needsAttention && onlyGate.title == "Preview completed" && !onlyGate.isTerminalReady)
        precondition(onlyGate.manualConditions.isEmpty && onlyGate.displayConditions.isEmpty && onlyGate.sharedReasons.isEmpty)
        precondition(onlyGate.operationAvailabilityMessage == "Rebuild Preview completed. Rebuild for Git worktree topology is not yet available.")
        let other = CoreRestorePreparation.Condition(domain: "homebrew-packages", code: "homebrew_unavailable",
            status: "external_action_required", selectedItemIndex: nil, scope: "operation")
        let mixed = RestorePrerequisiteSummaryPresentation(conditions: [gate, other], ready: false)
        precondition(mixed.needsAttention && mixed.title == "Needs Attention" && mixed.manualConditions.map(\.code) == [other.code])
        precondition(mixed.operationAvailabilityMessage == onlyGate.operationAvailabilityMessage)
        precondition(RestorePrerequisiteSummaryPresentation(conditions: [], ready: false).needsAttention)
        for condition in [
            CoreRestorePreparation.Condition(domain: "Workspace", code: gate.code, status: "unsupported", selectedItemIndex: 1, scope: "item"),
            CoreRestorePreparation.Condition(domain: "Workspace", code: "unknown_gate", status: "unsupported", selectedItemIndex: nil, scope: "operation")] {
            let unsupported = RestorePrerequisiteSummaryPresentation(conditions: [condition], ready: false)
            precondition(unsupported.needsAttention && unsupported.manualConditions.count == 1 && unsupported.operationAvailabilityMessage == nil)
        }
        for code in ["workspace_origin_conflict", "workspace_topology_conflict", "workspace_protected_files",
                     "workspace_local_changes", "workspace_branch_unavailable", "workspace_commit_unavailable",
                     "workspace_dependency_pending", "workspace_observation_changed",
                     "workspace_file_count_limit", "workspace_file_bytes_limit", "workspace_symlink_unsupported",
                     "workspace_hooks_unsupported", "workspace_index_unsupported", "workspace_configuration_unsupported"] {
            let message = CoreRestorePreparation.workspacePreviewReasons[code]!
            precondition(!message.isEmpty && !message.contains("/Users/") && !message.contains("https://"))
        }
        precondition(CoreRestorePreparation.workspacePreviewReasons["workspace_file_count_limit"]!.contains("4,096"))
        precondition(CoreRestorePreparation.workspacePreviewReasons["workspace_file_bytes_limit"]!.contains("16 MiB"))
        print("PASS: topology readiness, shared-destination, dependency and preservation explanations")
    }

    @MainActor static func restoreActualChangesChecks() async throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared; NSApp.appearance = NSAppearance(named: .aqua)
        let output = URL(fileURLWithPath: "build/Debug/RestoreActualChanges", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("macseed-result-details-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: fixture) }
        for folder in ["modules/core/application-interface", "config", "home", "tmp"] {
            try FileManager.default.createDirectory(at: fixture.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        for file in ["bootstrap.sh", "config/toolkit.conf", "modules/core/application-interface/core.py"] {
            try Data().write(to: fixture.appendingPathComponent(file))
        }
        try "#!/bin/bash\nexec /usr/bin/python3 -B fixture.py\n".write(to: fixture.appendingPathComponent("modules/core/application-interface/core.sh"), atomically: true, encoding: .utf8)
        try """
        import json, sys
        from pathlib import Path
        request=json.load(sys.stdin)
        payload=json.loads(Path('payload.json').read_text())
        for sequence,(kind,data) in enumerate([('started',{}),('result',payload),('completed',{})],1):
            print(json.dumps(dict(protocol_version=1,operation_id=request['operation_id'],sequence=sequence,type=kind,data=data)),flush=True)
        """.write(to: fixture.appendingPathComponent("fixture.py"), atomically: true, encoding: .utf8)
        let specifications: [(String, String, String, Bool)] =
            (1...24).map { ("vscode-extensions", $0 == 24 ? "ms-python.python" : "extension-\($0)", "install", $0 == 24) }
            + (1...4).map { ("git-repositories", $0 == 4 ? "Macseed" : "Repository \($0)", "clone", $0 == 4) }
            + (1...6).map { ("workspace-folders", $0 == 6 ? "Projects" : "Folder \($0)", "create_directory", $0 == 6) }
            + [("homebrew-casks", "Firefox", "install", false), ("macos-finder", "com.apple.finder/AppleShowAllExtensions", "set_preference", false)]
            + (1...16).map { ("app-store", String(123450 + $0), "inspect", $0 == 16) }
        let ids = Array(Set(specifications.map { $0.0 })).sorted()
        let catalog = CoreRestoreInspection.Inventory(groups: ids.map { .init(id: $0 == "macos-finder" ? "macOS Settings" : $0, domains: [$0]) },
            inventory: ids.map { .init(domain: $0, label: CaptureCategory.title(for: $0), selectionMode: "category", availability: "available", reason: nil, items: []) })
        let planID = String(repeating: "a", count: 64)
        var mixedTasks: RestoreTaskPresentation?
        var mixedResult: RestoreExecutionPresentation?
        for changed in [true, false] {
            let rows: [[String: Any]] = specifications.map { domain, id, action, candidate in
                let affected = changed && candidate
                return ["domain": domain, "item_id": id, "display_name": domain == "app-store" ? (candidate ? "Pages" : "Installed App " + id) : id,
                    "action": action, "disposition": affected ? (domain == "app-store" ? "warning" : "planned") : "satisfied",
                    "reason": domain == "app-store" && affected ? "manual_installation_required" : NSNull()]
            }
            let planRaw: [String: Any] = ["prepared_plan_id": planID, "selection": ["categories": ids, "items": [:]], "selected_categories": ids,
                "selected_item_counts": [:], "selected_groups": catalog.groups.map(\.id), "include_secure": false, "secure_restore_status": "not_selected",
                "plan": rows, "readiness": ["ready": true, "ready_scope": "environment", "conditions": [], "reentry": "restore_prepare"],
                "has_planned_changes": changed, "warning_count": changed ? 1 : 0, "error_count": 0]
            let plan = try JSONDecoder().decode(CoreRestorePreparation.self, from: JSONSerialization.data(withJSONObject: planRaw))
            try plan.validate(expected: .init(categories: ids, items: [:]), catalog: catalog)
            let preview = RestorePreviewPresentation(plan, catalog: catalog)
            let operations: [[String: Any]] = specifications.filter { $0.0 != "app-store" }.map { domain, id, action, candidate in
                ["domain": domain, "item_id": id, "action": action, "outcome": changed && candidate ? "success" : "noop"]
            }
            let observations: [[String: Any]] = specifications.map { domain, id, _, candidate in
                ["domain": domain, "item_id": id, "predicate": domain == "macos-finder" ? "stored_preference" : "selected_requirement",
                    "conformity": changed && candidate && domain == "app-store" ? "mismatch" : "verified"]
            }
            let payload: [String: Any] = ["prepared_plan_id": planID, "execution_status": "completed", "target_mutation_may_have_started": changed,
                "unknown_consequences": false, "warning_count": changed ? 1 : 0, "error_count": 0,
                "verification": ["status": "complete", "verdict": changed ? "needs_attention" : "selected_requirements_verified",
                    "verified_count": observations.count - (changed ? 1 : 0), "mismatch_count": changed ? 1 : 0,
                    "unverified_count": 0, "unresolved_count": 0, "warning_count": changed ? 1 : 0, "error_count": 0,
                    "details": ["status": "complete", "prepared_plan_id": planID, "operation_records": operations,
                        "verification_records": observations, "coverage_records": []]]]
            let payloadData = try JSONSerialization.data(withJSONObject: payload)
            try payloadData.write(to: fixture.appendingPathComponent("payload.json"))
            let runtime = CoreRuntime(operationLogs: nil)
            runtime.start(CoreRequest(.restoreExecute(path: fixture.appendingPathComponent("sample.mbt").path, disabledGroups: [], includeSecure: false,
                preparedID: planID, selection: .init(categories: ids, items: [:]))),
                location: .init(root: fixture, python: URL(fileURLWithPath: "/usr/bin/python3"), home: fixture.appendingPathComponent("home"),
                    temporaryBase: fixture.appendingPathComponent("tmp"), toolDirectories: []))
            await runtime.waitForCompletion()
            precondition(runtime.state == .completed, "Disposable JSON emitter failed: \(String(describing: runtime.error))")
            let result = RestoreExecutionPresentation(runtime: runtime, payload: try JSONDecoder().decode([String: CoreJSON].self, from: payloadData), expectedID: planID, catalog: catalog)
            let tasks = RestoreTaskPresentation(preview: preview, plan: plan, result: result, executing: true, operationProgress: true)
            let summary = RestoreResultSummary(domains: tasks.automaticDomains, result: result, appStore: tasks.appStore)
            let visible = RestoreResultDetails.domains(tasks.automaticDomains)
            let manual = RestoreResultDetails.manual(tasks.appStore)
            precondition(tasks.appStore.items.count == 16 && tasks.automaticDomains.flatMap(\.items).count == 36)
            precondition(summary.appliedCount == (changed ? 3 : 0) && summary.verifiedAppliedCount == summary.appliedCount)
            precondition(summary.verifiedRestorationCount == (changed ? 3 : 0), "Complete excludes pre-existing matches")
            precondition(summary.manualAttentionCount == (changed ? 1 : 0) && summary.automaticAttentionCount == 0)
            precondition(summary.noChangesRequired == !changed && manual.items.count == (changed ? 1 : 0))
            if changed {
                precondition(Set(visible.map(\.id)) == ["vscode-extensions", "git-repositories", "workspace-folders"])
                precondition(visible.allSatisfy { $0.items.count == 1 })
                precondition(visible.flatMap(\.items).allSatisfy { RestoreResultDetails.labels($0) == ["Verified"] })
                precondition(manual.items.first?.item.title == "Pages")
                // Repeated parent/child rows or receipts cannot inflate requirement counts.
                let duplicate = RestoreResultSummary(domains: tasks.automaticDomains + tasks.automaticDomains, result: result, appStore: tasks.appStore)
                precondition(duplicate.appliedCount == 3 && duplicate.verifiedRestorationCount == 3 && duplicate.manualAttentionCount == 1)
                var verificationOnly = try JSONDecoder().decode([String: CoreJSON].self, from: payloadData)
                var verification = verificationOnly["verification"]!.object!, details = verification["details"]!.object!
                details["operation_records"] = .array([]); verification["details"] = .object(details); verificationOnly["verification"] = .object(verification)
                let withoutReceipts = RestoreExecutionPresentation(runtime: runtime, payload: verificationOnly, expectedID: planID, catalog: catalog)
                func project(_ action: String?, itemID: String = "ms-python.python") throws -> RestoreTaskPresentation {
                    let events = try action.map { action in [try CoreEvent(line: JSONSerialization.data(withJSONObject: [
                        "protocol_version": 1, "operation_id": "fixture", "sequence": 1, "type": "execution_event",
                        "data": ["domain": "vscode-extensions", "item_id": itemID, "action": action, "state": "changed"]]))] } ?? []
                    return RestoreTaskPresentation(preview: preview, plan: plan, events: events, result: withoutReceipts, executing: true, operationProgress: true)
                }
                for unconfirmed in [try project(nil), try project("reinstall"), try project("install", itemID: "scope")] {
                    precondition(unconfirmed.automaticDomains.flatMap(\.items).allSatisfy { !RestoreResultDetails.hasChange($0) })
                    let visible = RestoreResultDetails.domains(unconfirmed.automaticDomains).flatMap(\.items)
                    precondition(visible.count == 3 && visible.allSatisfy { RestoreResultDetails.labels($0) == ["Verified"] && !RestoreResultDetails.needsAttention($0) },
                        "Previously planned, verified requirements stay visible without becoming applied changes or attention")
                    let summary = RestoreResultSummary(domains: unconfirmed.automaticDomains, result: withoutReceipts, appStore: nil)
                    precondition(summary.appliedCount == 0 && summary.verifiedRestorationCount == 3)
                }
                let changedEvent = try project("install")
                precondition(changedEvent.automaticDomains.flatMap(\.items).filter(RestoreResultDetails.hasChange).count == 1)
                let earlierMismatch = try CoreEvent(line: JSONSerialization.data(withJSONObject: [
                    "protocol_version": 1, "operation_id": "fixture", "sequence": 1, "type": "verification_record",
                    "data": ["domain": "vscode-extensions", "item_id": "ms-python.python", "predicate": "selected_requirement", "conformity": "mismatch"]]))
                let refreshedEvidence = RestoreTaskPresentation(preview: preview, plan: plan, events: [earlierMismatch], result: result, executing: true, operationProgress: true)
                let refreshedItem = refreshedEvidence.automaticDomains.flatMap(\.items).first { $0.sourceItemID == "ms-python.python" }!
                precondition(RestoreResultDetails.verified(refreshedItem), "Final evidence replaces an earlier observation of the same predicate")
                var scopeFailurePayload = try JSONDecoder().decode([String: CoreJSON].self, from: payloadData)
                var scopeVerification = scopeFailurePayload["verification"]!.object!, scopeDetails = scopeVerification["details"]!.object!
                scopeDetails["module_outcomes"] = .array([.object(["domain": .string("vscode-extensions"), "item_id": .string("scope"),
                    "action": .string("restore"), "state": .string("failed"), "reason": .string("module_failed")])])
                scopeVerification["details"] = .object(scopeDetails); scopeFailurePayload["verification"] = .object(scopeVerification)
                let scopeFailure = RestoreExecutionPresentation(runtime: runtime, payload: scopeFailurePayload, expectedID: planID, catalog: catalog)
                let scopeTasks = RestoreTaskPresentation(preview: preview, plan: plan, result: scopeFailure, executing: true, operationProgress: true)
                let failedDomain = scopeTasks.automaticDomains.first { $0.id == "vscode-extensions" }!
                precondition(failedDomain.resultCategoryIssue && RestoreResultDetails.title(failedDomain) == "Needs Attention",
                    "Retained scope failures remain visible even after runtime event history is truncated")
                mixedTasks = tasks; mixedResult = result
            } else {
                precondition(visible.isEmpty && manual.items.isEmpty && summary.issues.isEmpty)
                precondition(RestoreResultContent.message(result: result, summary: summary).hasPrefix("No changes were needed."))
            }
            if !CommandLine.arguments.contains("--no-renders") {
                renderActualChanges(result: result, tasks: tasks, name: changed ? "Changed" : "No-Changes", output: output)
            }
        }
        let changed = RestoreResultDetails.domains(mixedTasks!.automaticDomains).flatMap(\.items).first!
        var resolvedWarning = changed; resolvedWarning.previewProblem = "prerequisite_unmet"
        precondition(!RestoreResultDetails.needsAttention(resolvedWarning) && RestoreResultDetails.explanation(resolvedWarning) == nil,
            "An applied and verified change must not retain a resolved Preview warning")
        var independentFailure = changed; independentFailure.resultLabels = ["Failed", "Verified"]
        precondition(RestoreResultDetails.isVisible(independentFailure) && RestoreResultDetails.needsAttention(independentFailure)
            && RestoreResultDetails.labels(independentFailure) == ["Failed"], "Conformity cannot erase an execution failure")
        var partialVerification = changed; partialVerification.resultVerificationComplete = false
        precondition(RestoreResultDetails.needsAttention(partialVerification) && !RestoreResultDetails.verified(partialVerification))
        precondition(RestoreResultDetails.labels(partialVerification) == ["Unverified"])
        var secondAction = changed; secondAction.executionAction = "Reinstall"
        let repeatedRequirement = TaskDomainPresentation(id: "vscode-extensions", title: "Extensions", symbol: "folder", items: [changed, secondAction])
        precondition(RestoreFinalDomain.counts(repeatedRequirement).map(\.1) == [1])
        let pending = RestoreResultDetails.manual(mixedTasks!.appStore)
        let duplicatedManual = AppStoreRestorePresentation(domains: [.init(id: "app-store", title: "Apps", symbol: "app", items: pending.items + pending.items)])
        precondition(RestoreResultDetails.manual(duplicatedManual).items.count == 1)
        var noVerification = changed; noVerification.resultLabels = ["Applied"]; noVerification.verificationEvidenceAvailable = false
        precondition(RestoreResultDetails.hasChange(noVerification) && RestoreResultDetails.needsAttention(noVerification))
        precondition(RestoreResultDetails.labels(noVerification) == ["Unverified"])
        for label in ["Failed", "Mismatch", "Unsupported", "Unresolved", "Unverified", "Needs Attention"] {
            var issue = changed; issue.resultLabels = [label]
            precondition(RestoreResultDetails.isVisible(issue) && RestoreResultDetails.needsAttention(issue) && !RestoreResultDetails.hasChange(issue))
        }
        var notRun = changed; notRun.resultLabels = []; notRun.resultNotRun = true
        precondition(RestoreResultDetails.isVisible(notRun) && RestoreResultDetails.labels(notRun) == ["Not Run"])
        var unknown = changed; unknown.resultLabels = ["Unverified"]; unknown.resultEvidenceAvailable = false
        precondition(RestoreResultDetails.isVisible(unknown) && !RestoreResultDetails.hasChange(unknown))
        var skipped = changed; skipped.resultLabels = ["Skipped"]
        precondition(RestoreResultDetails.needsAttention(skipped), "A skip without a neutral reason stays visible")
        let neutralSkip = TaskItemPresentation(id: "planned-skip", item: DisplayItem(id: "planned-skip", title: "Planned requirement",
            status: .ready, action: "", reason: "not_applicable"), state: .skipped, resultLabels: ["Skipped"], resultEvidenceAvailable: true)
        precondition(RestoreResultDetails.isVisible(neutralSkip) && RestoreResultDetails.labels(neutralSkip) == ["Skipped"]
            && !RestoreResultDetails.needsAttention(neutralSkip))
        let matching = mixedTasks!.automaticDomains.first { $0.id == "macOS Settings" }!
        var categoryIssue = matching; categoryIssue.resultCategoryIssue = true
        categoryIssue.resultProblemDomains = ["macos-finder"]; categoryIssue.resultProblemMessages = ["macos-finder": "Independent settings diagnostic"]
        let issueOnly = RestoreResultDetails.domains([categoryIssue])
        precondition(issueOnly.count == 1 && issueOnly[0].items.isEmpty && issueOnly[0].resultChildren.count == 1)
        precondition(issueOnly[0].resultChildren[0].resultCategoryExplanation == "Independent settings diagnostic")
        let uncertainSummary = RestoreResultSummary(domains: [.init(id: "vscode-extensions", title: "Extensions", symbol: "folder", items: [noVerification, noVerification])], result: mixedResult!, appStore: nil)
        precondition(uncertainSummary.appliedCount == 1 && uncertainSummary.verifiedAppliedCount == 0 && uncertainSummary.automaticAttentionCount == 1)
        precondition(uncertainSummary.verifiedRestorationCount == 0)
        print("PASS: Result retains planned Verified requirements and genuine problems; Complete counts unique visible planned requirements, excludes existing matches, preserves mutation evidence and failed/stopped headings; App Store stays category-only")
    }

    @MainActor static func restoreStoppedResultChecks() async throws {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("macseed-stopped-result-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: fixture) }
        for path in ["modules/core/application-interface", "config", "home", "tmp"] {
            try FileManager.default.createDirectory(at: fixture.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        for path in ["bootstrap.sh", "config/toolkit.conf", "modules/core/application-interface/core.py"] {
            try Data().write(to: fixture.appendingPathComponent(path))
        }
        try "#!/bin/bash\nexec /usr/bin/python3 -B fixture.py\n".write(to: fixture.appendingPathComponent("modules/core/application-interface/core.sh"), atomically: true, encoding: .utf8)
        try """
        import json,sys
        from pathlib import Path
        request=json.load(sys.stdin)
        payload=json.loads(Path('payload.json').read_text())
        events=[('started',{}),('execution_event',dict(domain='orchestration',state='graceful_stop_accepted')),
                ('execution_event',dict(domain='workspace-folders',item_id='started',action='create_directory',state='applying')),
                ('failed',payload)]
        for sequence,(kind,data) in enumerate(events,1):
            print(json.dumps(dict(protocol_version=1,operation_id=request['operation_id'],sequence=sequence,type=kind,data=data)),flush=True)
        sys.exit(130 if payload['code']=='cancelled' else 2)
        """.write(to: fixture.appendingPathComponent("fixture.py"), atomically: true, encoding: .utf8)
        let ids = ["git-repositories", "workspace-folders", "homebrew-casks", "macos-finder", "app-store"]
        let catalog = CoreRestoreInspection.Inventory(groups: ids.map { .init(id: $0, domains: [$0]) },
            inventory: ids.map { .init(domain: $0, label: $0, selectionMode: "category", availability: "available", reason: nil, items: []) })
        let rows: [[String: Any]] = [
            ["domain": "git-repositories", "item_id": "cloned", "action": "clone", "disposition": "planned"],
            ["domain": "git-repositories", "item_id": "matching", "action": "clone", "disposition": "satisfied"],
            ["domain": "workspace-folders", "item_id": "started", "action": "create_directory", "disposition": "planned"],
            ["domain": "homebrew-casks", "item_id": "not-started", "action": "install", "disposition": "planned"],
            ["domain": "macos-finder", "item_id": "not-started", "action": "set_preference", "disposition": "planned"]
        ] + (1...16).map { ["domain": "app-store", "item_id": String($0), "action": "inspect", "disposition": "satisfied"] }
        let planID = String(repeating: "b", count: 64)
        let raw: [String: Any] = ["prepared_plan_id": planID, "selection": ["categories": ids, "items": [:]],
            "selected_categories": ids, "selected_item_counts": [:], "selected_groups": ids,
            "include_secure": false, "secure_restore_status": "not_selected", "plan": rows,
            "readiness": ["ready": true, "ready_scope": "environment", "conditions": [], "reentry": "restore_prepare"],
            "has_planned_changes": true, "warning_count": 0, "error_count": 0]
        let plan = try JSONDecoder().decode(CoreRestorePreparation.self, from: JSONSerialization.data(withJSONObject: raw))
        let operations: [[String: Any]] = [
            ["domain": "git-repositories", "item_id": "cloned", "action": "clone", "outcome": "success"],
            ["domain": "git-repositories", "item_id": "matching", "action": "clone", "outcome": "noop"]]
        for scenario in ["stopped", "independent-failure", "unknown", "failed"] {
            let independent = scenario == "independent-failure"
            let payload: [String: Any] = ["code": scenario == "failed" ? "bootstrap_failed" : "cancelled",
                "prepared_plan_id": planID, "target_mutation_may_have_started": true, "unknown_consequences": scenario == "unknown",
                "verification": ["status": "not_run", "verdict": "incomplete", "details": ["status": "partial",
                    "operation_records": operations + (independent ? [["domain": "homebrew-casks", "item_id": "not-started", "action": "install", "outcome": "failure", "reason": "target_conflict"]] : []),
                    "verification_records": [], "module_outcomes": [], "diagnostics": []]]]
            let data = try JSONSerialization.data(withJSONObject: payload)
            try data.write(to: fixture.appendingPathComponent("payload.json"))
            let runtime = CoreRuntime(operationLogs: nil)
            runtime.start(CoreRequest(.restoreExecute(path: fixture.appendingPathComponent("unused.mbt").path, disabledGroups: [], includeSecure: false,
                preparedID: planID, selection: .init(categories: ids, items: [:]))),
                location: .init(root: fixture, python: URL(fileURLWithPath: "/usr/bin/python3"), home: fixture.appendingPathComponent("home"),
                    temporaryBase: fixture.appendingPathComponent("tmp"), toolDirectories: []))
            await runtime.waitForCompletion()
            let result = RestoreExecutionPresentation(runtime: runtime, payload: try JSONDecoder().decode([String: CoreJSON].self, from: data),
                expectedID: planID, catalog: catalog, stopRequest: .init(operationID: runtime.operationID!, force: false))
            let tasks = RestoreTaskPresentation(preview: RestorePreviewPresentation(plan, catalog: catalog), plan: plan,
                events: runtime.events, result: result, executing: true, operationProgress: true)
            let summary = RestoreResultSummary(domains: tasks.automaticDomains, result: result, appStore: tasks.appStore)
            let visible = RestoreResultDetails.domains(tasks.automaticDomains, result: result).flatMap(\.items)
            if ["stopped", "independent-failure"].contains(scenario) {
                precondition(result.outcome == .stoppedAfterMutation && result.title == "Rebuild Stopped" && result.stopNotice == "Stopped by User")
                precondition(RestoreResultDetails.stoppedWithoutVerification(result))
                precondition(Set(visible.compactMap(\.sourceItemID)) == Set(independent ? ["cloned", "started", "not-started"] : ["cloned", "started"]))
                precondition(summary.manualAttentionCount == 0 && summary.verifiedRestorationCount == 0)
                precondition(summary.issues.allSatisfy { !$0.appStore } && !summary.issues.contains { $0.id.hasPrefix("macos-") })
                precondition(RestoreResultDetails.manual(tasks.appStore, result: result).items.isEmpty)
                precondition(visible.allSatisfy { !RestoreResultDetails.labels($0).contains("Verified") })
                precondition(RestoreResultContent.message(result: result, summary: summary).hasPrefix("Completed changes remain."))
                if independent { precondition(visible.contains { RestoreResultDetails.labels($0) == ["Failed"] }) }
                let clone = visible.first { $0.sourceItemID == "cloned" }!
                precondition(clone.resultLabels.contains("Applied") && RestoreResultDetails.labels(clone) == ["Unverified"])
                precondition(RestoreResultDetails.explanation(clone) == "The action completed, but its result was not independently verified.")
            } else {
                precondition(result.outcome == (scenario == "unknown" ? .interrupted : .failedAfterMutation))
                precondition(!RestoreResultDetails.stoppedWithoutVerification(result))
                precondition(visible.map(\.id) == RestoreResultDetails.domains(tasks.automaticDomains).flatMap(\.items).map(\.id),
                    "Failed and unknown-consequence filtering must stay unchanged")
            }
        }
        print("PASS: stopped without Verification retains completed/started work and independent failures; unchecked requirements and manual apps stay out; failed/unknown outcomes unchanged")
    }

    @MainActor static func renderActualChanges(result: RestoreExecutionPresentation, tasks: RestoreTaskPresentation, name: String, output: URL) {
        let content = VStack(spacing: 0) {
            WorkflowContentViewport(pinned: true) {
                VStack(alignment: .leading, spacing: 20) {
                    WorkspaceHeader(title: ProductTask.restore.title, subtitle: ProductTask.restore.subtitle, symbol: ProductTask.restore.symbol)
                    RestoreResultContent(result: result, showsActions: false, tasks: tasks, reviewAppStore: {}, refresh: {}, done: {})
                }.padding(28)
            }
            Divider()
            RestoreResultActions(result: result, refresh: {}, done: {}).modifier(WorkspaceFooterPadding())
        }.frame(width: 985, height: 1100).background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 985, height: 1100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
        func flush() { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1)); host.layoutSubtreeIfNeeded(); host.displayIfNeeded() }
        func snapshot(_ suffix: String) {
            flush()
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try! bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + suffix + ".png"))
        }
        snapshot("")
        if name == "Changed" {
            let point = host.convert(NSPoint(x: 920, y: host.isFlipped ? 343 : 1100 - 343), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                window.sendEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!)
            }
            snapshot("-Expanded")
        }
        window.close()
    }

    @MainActor static func restoreFlatCategoryChecks() {
        let expected = ["homebrew-casks", "homebrew-packages", "macOS Settings", "vscode-extensions", "vscode-settings",
            "git-configuration", "git-repositories", "workspace-folders", "ssh-configuration", "shell-zsh", "vscode-workspaces"]
        func domain(_ id: String) -> TaskDomainPresentation {
            TaskDomainPresentation(id: id, title: "Existing " + id, symbol: "folder", items: [
                TaskItemPresentation(id: id + ":selected", item: DisplayItem(id: id + ":selected", title: "Selected requirement",
                    status: .unverified, action: "Existing explanation", reason: "inspection_unavailable"), state: .unverified,
                    resultLabels: ["Unverified"], sourceDomain: id, sourceItemID: "selected")],
                activityState: id == "git-repositories" ? .working : nil,
                resultCategoryIssue: id == "ssh-configuration", resultCategoryMessage: "Existing category warning")
        }
        let input = [domain("future-selected-domain")] + expected.reversed().map(domain)
        let rows = RestoreExecutionCategories.orderedRows(input)
        precondition(rows.map(\.id) == expected + ["future-selected-domain"])
        precondition(rows.count == input.count && Set(rows.map(\.id)) == Set(input.map(\.id)))
        for original in input {
            let row = rows.first { $0.id == original.id }!
            precondition(row.title == original.title && row.symbol == original.symbol)
            precondition(row.items.map(\.item) == original.items.map(\.item)
                && row.items.map(\.resultLabels) == original.items.map(\.resultLabels))
            precondition(row.executionStatusTitle == original.executionStatusTitle && row.resultTitle == original.resultTitle)
            precondition(row.resultCategoryIssue == original.resultCategoryIssue
                && row.resultCategoryMessage == original.resultCategoryMessage)
        }
        for ids in [[], ["workspace-folders"], ["vscode-workspaces"], ["future-selected-domain"], ["macos-settings"]] {
            precondition(RestoreExecutionCategories.orderedRows(ids.map(domain)).map(\.id) == ids)
        }
        let macOS = CaptureMacOSSettingsGroup.domainIDs
        precondition(RestoreExecutionCategories.orderedRows(macOS.reversed().map(domain)).map(\.id) == macOS)
        let manual = AppStoreRestorePresentation(domains: [.init(id: "app-store", title: "App Store Applications", symbol: "app", items: [
            .init(id: "manual-app", item: DisplayItem(id: "manual-app", title: "Pages", status: .missing, action: "Install manually"),
                state: .attention, assistedAppStore: .init(appID: "123456", status: .missing))])])
        let withManual = RestoreExecutionCategories.orderedRows(input, appStore: manual)
        precondition(withManual.map(\.id) == ["app-store"] + rows.map(\.id))
        precondition(RestoreExecutionCategories.orderedRows([], appStore: manual).map(\.id) == ["app-store"])
        precondition(RestoreExecutionCategories.orderedRows([], appStore: .init(domains: [])).isEmpty)
        print("PASS: flat Progress/Result order preserves exact selected rows, names, states and warnings; sparse/macOS/unknown/manual scopes remain intact")
    }

    @MainActor static func restorePreviewGroupingChecks() {
        setbuf(stdout, nil)
        try! FileManager.default.createDirectory(atPath: "build/Debug/RestorePreviewRefinement", withIntermediateDirectories: true)
        _ = NSApplication.shared
        NSApp.appearance = NSAppearance(named: .aqua)
        // Project a selected Core plan through the same adapters as production.
        // Inspection-only domains are deliberately absent from this plan.
        let specification: [(String, String, String, String, String?)] = [
            ("homebrew-casks", "Firefox", "install", "satisfied", nil),
            ("homebrew-casks", "IINA", "install", "planned", nil),
            ("homebrew-packages", "git", "install", "satisfied", nil),
            ("homebrew-packages", "ripgrep", "install", "planned", nil),
            ("macos-finder", "com.apple.finder/AppleShowAllExtensions", "set_preference", "satisfied", nil),
            ("macos-dock", "com.apple.dock/tilesize", "set_preference", "planned", nil),
            ("macos-dock", "Dock", "restart_process", "planned", nil),
            ("vscode-extensions", "ms-python.python", "install", "planned", nil),
            ("vscode-settings", "settings.json", "replace_with_backup", "planned", nil),
            ("git-configuration", "core.editor", "set_setting", "satisfied", nil),
            ("git-repositories", "Macseed", "clone", "planned", "workspace_dependency_pending"),
            ("git-repositories", "Feature worktree", "add_worktree", "blocked", "workspace_dependency_missing"),
            ("workspace-folders", "Projects", "create_directory", "planned", nil),
            ("ssh-configuration", "scope", "none", "warning", "partial_source_coverage"),
            ("shell-zsh", "Zsh configuration", "none", "satisfied", nil),
            ("vscode-workspaces", "Development.code-workspace", "create_workspace", "conflict", "workspace_descriptor_conflict"),
            ("app-store", "123456", "inspect", "warning", "manual_installation_required"),
            ("app-store", "234567", "inspect", "satisfied", nil)]
        let macOS = ["macos-finder", "macos-dock"]
        let ids = Array(Set(specification.map { $0.0 })).sorted()
        let catalog = CoreRestoreInspection.Inventory(
            groups: [.init(id: "macOS Settings", domains: macOS)] + ids.filter { !macOS.contains($0) }.map { .init(id: $0, domains: [$0]) },
            inventory: ids.map { .init(domain: $0, label: CaptureCategory.title(for: $0), selectionMode: "category", availability: "available", reason: nil, items: []) })
        let rawRows: [[String: Any]] = specification.map { domain, name, action, disposition, reason in
            ["domain": domain, "item_id": name, "display_name": domain == "app-store" ? (name == "123456" ? "Pages" : "Keynote") : name,
             "action": action, "disposition": disposition, "reason": reason as Any? ?? NSNull()]
        }
        let raw: [String: Any] = ["prepared_plan_id": String(repeating: "a", count: 64),
            "selection": ["categories": ids, "items": [:]], "selected_categories": ids,
            "selected_item_counts": [:], "selected_groups": catalog.groups.map(\.id),
            "include_secure": false, "secure_restore_status": "not_selected", "plan": rawRows,
            "readiness": ["ready": false, "ready_scope": "environment", "reentry": "restore_prepare", "conditions": [
                ["domain": "vscode-extensions", "code": "vscode_cli_required", "status": "external_action_required"],
                ["domain": "ssh-configuration", "code": "ssh_configuration_not_ready", "status": "external_action_required"]]],
            "has_planned_changes": true, "warning_count": 2, "error_count": 0]
        let plan = try! JSONDecoder().decode(CoreRestorePreparation.self, from: JSONSerialization.data(withJSONObject: raw))
        try! plan.validate(expected: .init(categories: ids, items: [:]), catalog: catalog)
        let preview = RestorePreviewPresentation(plan, catalog: catalog)
        let tasks = RestoreTaskPresentation(preview: preview, plan: plan)
        let domains = tasks.automaticDomains
        let children = RestoreSettingsPresentation.children(domains, categories: preview.categories)
        let titles = RestoreSettingsPresentation.titles(plan.plan)
        let sections = RestorePreviewHierarchy.sections(domains)
        precondition(sections.map(\.group) == [.applicationsTools, .macOSSettings, .vscode, .advanced])
        precondition(sections[0].rows.map(\.id) == ["homebrew-casks", "homebrew-packages"])
        precondition(sections[1].rows.map(\.id) == ["macOS Settings"] && children.map(\.id) == macOS)
        precondition(sections[2].rows.map(\.id) == ["vscode-extensions", "vscode-settings"])
        precondition(sections[3].rows.map(\.id) == WorkspacePresentationTaxonomy.Group.advanced.domains)
        let regrouped = sections.flatMap(\.rows)
        precondition(Set(regrouped.map(\.id)) == Set(domains.map(\.id)) && regrouped.count == domains.count)
        precondition(!regrouped.contains { $0.id == "app-store" } && tasks.appStore.items.count == 2)
        // Exact item correspondence includes actions, warnings and diagnostic identity.
        for original in domains {
            let row = regrouped.first { $0.id == original.id }!
            precondition(row.items.map(\.id) == original.items.map(\.id))
            for (before, after) in zip(original.items, row.items) {
                precondition(before.item == after.item && before.state == after.state)
                precondition(before.sourceDomain == after.sourceDomain && before.sourceItemID == after.sourceItemID)
                precondition(before.executionAction == after.executionAction && before.previewProblem == after.previewProblem)
                precondition(before.diagnostic?.technicalDescription == after.diagnostic?.technicalDescription)
            }
            precondition(RestorePreviewMetrics.badges(row).map { "\($0.0):\($0.1)" } == RestorePreviewMetrics.badges(original).map { "\($0.0):\($0.1)" })
        }
        let allItems = domains.flatMap(\.items)
        precondition(allItems.count == specification.filter { $0.0 != "app-store" }.count)
        for section in sections {
            let summary = RestorePreviewHierarchy.summary(section.group, rows: section.rows)
            precondition(summary.items.map(\.id) == section.rows.flatMap(\.items).map(\.id))
            precondition(!["Ready to Save", "Saved", "Completed", "Verified"].contains(RestorePreviewCategoryStatus.title(summary, stateTitles: [:])))
        }
        let groupCounts = sections.map { RestorePreviewMetrics.counts([RestorePreviewHierarchy.summary($0.group, rows: $0.rows)]) }
        let total = RestorePreviewMetrics.counts(domains)
        precondition(groupCounts.map(\.matching) == [2, 1, 0, 2])
        precondition(groupCounts.map(\.changes) == [2, 2, 2, 2])
        precondition(groupCounts.map(\.attention) == [0, 0, 0, 3])
        precondition(groupCounts.reduce(0) { $0 + $1.matching } == total.matching
            && groupCounts.reduce(0) { $0 + $1.changes } == total.changes
            && groupCounts.reduce(0) { $0 + $1.attention } == total.attention,
            "Group counts partition the automatic plan; macOS children and manual App Store never add duplicate requirements")
        precondition(RestorePreviewHierarchy.summary(.advanced, rows: sections[3].rows).state == .attention)
        let ordinary = domains.filter { CaptureHierarchy.group(for: $0.id) != .advanced }
        precondition(!RestorePreviewHierarchy.sections(ordinary).contains { $0.group == .advanced })
        precondition(RestorePreviewHierarchy.sections([]).isEmpty)
        let descriptorOnly = domains.filter { $0.id == "vscode-workspaces" }
        precondition(RestorePreviewHierarchy.sections(descriptorOnly).flatMap(\.rows).map(\.id) == ["vscode-workspaces"], "No implicit Git or folder dependencies")
        let unknownItem = TaskItemPresentation(id: "future-warning", item: DisplayItem(id: "future-warning", title: "Unknown requirement", status: .unverified, action: "Inspection unavailable", reason: "inspection_unavailable"), state: .unverified)
        let unknown = TaskDomainPresentation(id: "future-domain", title: "Future domain", symbol: "questionmark", items: [unknownItem], previewOnly: true)
        precondition(RestorePreviewHierarchy.sections([unknown]).first?.group == .otherFindings)
        precondition(RestorePreviewHierarchy.sections([unknown]).flatMap(\.rows).flatMap(\.items).first?.item == unknownItem.item)
        let expandedIDs = RestorePreviewHierarchy.disclosureIDs(domains, settings: children)
        precondition(Set(children.map(\.id)).isSubset(of: expandedIDs))
        precondition(expandedIDs.contains(WorkspacePresentationTaxonomy.Group.vscode.id))
        precondition(!expandedIDs.contains("app-store") && !expandedIDs.contains("macos-keyboard"))
        precondition(WorkflowExpansion.toggled(expandedIDs, available: expandedIDs).isEmpty)
        let prerequisites = RestorePrerequisiteSummaryPresentation(conditions: plan.readiness.conditions, ready: false)
        precondition(prerequisites.manualConditions.map(\.code) == ["vscode_cli_required", "ssh_configuration_not_ready"])
        print("PASS: Preview grouping preserves exact effective plan rows, actions, statuses, counts, macOS details and manual App Store scope; sparse/developer-only/unknown plans retain evidence")

        var actionCalls = 0
        func flush(_ host: NSView) {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        }
        func scrolls(_ view: NSView) -> [NSScrollView] { (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrolls) }
        func buttons(_ view: NSView) -> [NSButton] { (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons) }
        for width: CGFloat in [785, 985] {
            let state = PreviewExpansionState()
            let height: CGFloat = width == 985 ? 1200 : 950
            var footerFrame = CGRect.zero
            let content = PreviewExpansionHost(state: state) { binding in AnyView(VStack(spacing: 0) {
                WorkflowContentViewport(pinned: true) {
                    VStack(alignment: .leading, spacing: 20) {
                        WorkspaceHeader(title: ProductTask.restore.title, subtitle: ProductTask.restore.subtitle, symbol: ProductTask.restore.symbol)
                        HStack { Label("sample.mbt", systemImage: "shippingbox").font(.headline); Spacer(); Button("Change…") { actionCalls += 1 } }
                        RestorePreviewContent(title: "Needs Attention", state: .attention, domains: domains, alreadyMatches: false,
                            prerequisites: prerequisites, areas: catalog.inventory, settingsCategories: children, itemTitles: titles,
                            categoryExpansion: Binding(get: { !binding.wrappedValue.isEmpty }, set: { binding.wrappedValue = $0 ? expandedIDs : [] }),
                            appStore: tasks.appStore, reviewAppStore: { actionCalls += 1 }, showsActions: false)
                    }.padding(28)
                }
                Divider()
                RestorePreviewActions(back: { actionCalls += 1 }, refresh: { actionCalls += 1 }, rebuild: { actionCalls += 1 }, canRebuild: false)
                    .modifier(WorkspaceFooterPadding())
                    .background(GeometryReader { proxy in Color.clear.preference(key: WorkflowAnchorFrames.self, value: ["footer": proxy.frame(in: .named("preview-grouping"))]) })
            }.frame(width: width, height: height).background(Color(nsColor: .windowBackgroundColor))
                .coordinateSpace(name: "preview-grouping").onPreferenceChange(WorkflowAnchorFrames.self) { footerFrame = $0["footer"] ?? .zero }) }
            let host = NSHostingView(rootView: content)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil); flush(host)
            let viewports = scrolls(host)
            precondition(viewports.count == 1, "Prerequisites, manual and automatic tasks share one viewport")
            precondition(buttons(host).allSatisfy { !($0.target is NativeSelectionCheckbox.Coordinator) }, "Preview has no selection controls")
            let scroll = viewports[0], collapsedHeight = scroll.documentView!.frame.height, fixedFooter = footerFrame
            func snapshot(_ name: String, fraction: CGFloat = 0) {
                let maxOffset = max(0, scroll.documentView!.frame.height - scroll.contentView.bounds.height)
                scroll.contentView.scroll(to: NSPoint(x: 0, y: maxOffset * fraction)); scroll.reflectScrolledClipView(scroll.contentView); flush(host)
                precondition(footerFrame == fixedFooter, "Footer stays fixed during expansion and scrolling")
                guard !CommandLine.arguments.contains("--no-renders") else { return }
                let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/Debug/RestorePreviewRefinement/Preview-\(name)-\(Int(width)).png"))
            }
            snapshot("collapsed")
            snapshot("collapsed-automatic", fraction: 1)
            // Same state transition as the existing Expand All button, followed
            // by native layout/display (as in previewExpansionPerformanceChecks).
            state.ids = WorkflowExpansion.toggled(state.ids, available: expandedIDs)
            flush(host)
            precondition(state.ids == expandedIDs && scroll.documentView!.frame.height > collapsedHeight + 500,
                "Expanded IDs: \(state.ids); document: \(scroll.documentView!.frame.height), collapsed: \(collapsedHeight)")
            snapshot("prerequisites-manual")
            snapshot("ordinary", fraction: 0.27)
            snapshot("vscode", fraction: 0.53)
            snapshot("advanced", fraction: 1)
            state.ids = WorkflowExpansion.toggled(state.ids, available: expandedIDs); flush(host)
            precondition(state.ids.isEmpty)
            precondition(abs(scroll.documentView!.frame.height - collapsedHeight) < 2)
            precondition(actionCalls == 0, "Disclosure cannot invoke any workflow action")
            window.close()
        }
        print("PASS: native Preview Expand/Collapse, zero selection controls/actions, one scroll viewport and fixed footer at 785/985pt")
    }

    @MainActor static func restoreSelectionAccordionChecks() {
        _ = NSApplication.shared
        let runtime = CoreRuntime(operationLogs: nil)
        let model = RestoreModel(runtime: runtime)
        let package = CoreRestoreInspection.Area(domain: "homebrew-packages", label: "Homebrew Packages", selectionMode: "items",
            availability: "available", reason: nil, items: [.init(itemID: "stable-package", label: "ripgrep")])
        let extensions = CoreRestoreInspection.Area(domain: "vscode-extensions", label: "Extensions", selectionMode: "items",
            availability: "available", reason: nil, items: [.init(itemID: "stable-extension", label: "ms-python.python")])
        let settings = CoreRestoreInspection.Area(domain: "vscode-settings", label: "Settings", selectionMode: "category",
            availability: "available", reason: nil, items: [])
        let legacy = CoreRestoreInspection(formatVersion: 1, selectedCategories: [], selectedItemCounts: [package.id: 0], secureComponent: false,
            restoreSelection: .init(groups: [.init(id: "Homebrew", domains: [package.id])], inventory: [package]))
        precondition(RestoreSelectionPresentation.includedAreas(legacy).isEmpty, "Explicit zero selected items must not expose legacy inventory")
        precondition(!RestoreAreaSelectionView.hasDisclosure(settings), "No fabricated details for aggregate inspection")
        precondition(TaskRowLayout.statusWidth == 200 && CaptureReviewPresentation.hierarchyStep == 12)
        let checkbox = AnyView(NativeSelectionCheckbox("", isOn: .constant(true), accessibilityTitle: "Master"))
        for width: CGFloat in [729, 929] {
            let content = VStack(spacing: 0) {
                CaptureGroupHeader(title: "Applications & Tools", summary: "All Selected", selection: checkbox, expanded: .constant(true))
                RestoreAreaSelectionView(model: model, area: package, expansion: .constant(true))
                CaptureGroupHeader(title: "VS Code", summary: "All Selected", nested: true, selection: checkbox, expanded: .constant(true))
                RestoreAreaSelectionView(model: model, area: extensions, expansion: .constant(true), hierarchyIndent: 24)
                RestoreAreaSelectionView(model: model, area: settings, hierarchyIndent: 24)
            }.frame(width: width)
            let host = NSHostingView(rootView: content)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: host.fittingSize.height), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; host.frame = window.contentView!.bounds
            host.layoutSubtreeIfNeeded()
            func buttons(_ view: NSView) -> [NSButton] { (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons) }
            let boxes = buttons(host).filter { $0.target is NativeSelectionCheckbox.Coordinator }
            precondition(boxes.count == 7 && boxes.allSatisfy { $0.allowsMixedState && $0.action != nil })
            let origins = boxes.map { $0.convert($0.bounds, to: host).minX }
            precondition(abs(origins[1] - origins[0] - 12) < 1, "Domain checkbox must be indented 12pt: \(origins)")
            precondition(abs(origins[3] - origins[0] - 12) < 1, "VS Code subgroup must be indented 12pt")
            precondition(abs(origins[4] - origins[1] - 12) < 1 && abs(origins[6] - origins[4]) < 1, "VS Code child domains must align at 24pt")
            precondition(abs(origins[5] - origins[2] - 12) < 1, "Extension items must be one level deeper than package items")
            window.close()
        }
        let source = try! String(contentsOfFile: "Sources/RestoreView.swift")
        let selection = source.components(separatedBy: "if model.state == .review {")[1].components(separatedBy: "} else if let prepared")[0]
        precondition(selection.contains("RestoreSelectionContent(") && !selection.contains("toggleAll"))
        let content = source.components(separatedBy: "struct RestoreSelectionContent:")[1].components(separatedBy: "struct RestorePresentationSection:")[0]
        precondition(content.contains("CaptureGroupedContent(rows: areas") && content.contains("model.selectionAreas"))
        precondition(content.components(separatedBy: "CaptureExpandButton(").count == 3)
        precondition(!content.contains("advancedFooter:") && !content.contains("restore_prepare") && !content.contains("ScrollView"))
        precondition(runtime.state == .idle && model.selection.categories.isEmpty && model.selection.items.isEmpty)
        print("PASS: Restore Selection native checkbox hierarchy at narrow/wide widths, shared 200pt status rail, independent disclosures, one WorkflowList and aggregate settings")
    }

    static func sshResolutionPresentationChecks() throws {
        let base: [String: Any] = ["version": 1, "action": "create", "ready": false, "pending": true,
            "dependencies": ["version": 1, "findings": ["missing"]], "remote_authentication": "not_assessed"]
        let pending = try JSONDecoder().decode(CoreSSHResolution.self, from: JSONSerialization.data(withJSONObject: base))
        precondition(pending.valid && !pending.ready && pending.pending)
        var expected = base; expected["ready"] = true; expected["pending"] = false
        expected["dependencies"] = ["version": 1, "findings": ["selected_expected"]]
        let qualified = try JSONDecoder().decode(CoreSSHResolution.self, from: JSONSerialization.data(withJSONObject: expected))
        precondition(qualified.valid && qualified.ready && qualified.remoteAuthentication == "not_assessed")
        expected["remote_authentication"] = "verified"
        let invalid = try JSONDecoder().decode(CoreSSHResolution.self, from: JSONSerialization.data(withJSONObject: expected))
        precondition(!invalid.valid)
        let row = CoreRestoreInspection.Area(domain: "ssh-configuration", label: "SSH Configuration", selectionMode: "items",
            availability: "available", reason: nil, items: [.init(itemID: "opaque", label: "production")])
        precondition(RestoreAreaSelectionView.hasDisclosure(row))
        precondition(RestoreAreaSelectionView.notices(row).isEmpty)
        let limited = CoreRestoreInspection.Area(domain: row.id, label: row.label, selectionMode: "items",
            availability: "available", reason: "unsupported_content", items: row.items)
        precondition(RestoreAreaSelectionView.notices(limited).first?.status == .attention,
                     "A real Bundle/category limitation must retain its warning")
        let unsafe = CoreRestoreInspection.Area(domain: row.id, label: row.label, selectionMode: "items",
            availability: "unsupported", reason: "unsafe_target", items: row.items)
        precondition(RestoreAreaSelectionView.notices(unsafe).first?.status == .unsupported)
        let selection = CoreRestoreSelection(categories: ["ssh-configuration"], items: [:])
        let disclosure = CoreCommand.sshRestoreReview(path: "/fixture.mbt", selection: selection)
        let secureChoice = CoreCommand.sshRestoreReview(path: "/fixture.mbt", selection: selection, includeSecure: true)
        precondition(!disclosure.requiresSecretBridge && secureChoice.requiresSecretBridge)
        let proposal = CoreSSHApprovals(version: 1, bundleID: String(repeating: "b", count: 64), items: [
            .init(hostID: "restore:" + String(repeating: "c", count: 64), index: 0, original: "/old/key",
                  reference: "~/keys/key", identityID: nil, approved: false)])
        _ = try CoreRequest(disclosure, sshApprovals: proposal).encoded()
        do {
            _ = try CoreRequest(.restorePrepare(path: "/fixture.mbt", disabledGroups: [], includeSecure: false), sshApprovals: proposal).encoded()
            preconditionFailure("An unapproved review proposal must never become Prepare consent")
        } catch CoreRuntimeError.invalidRequest { }
        let catalog = CoreRestoreInspection.Inventory(groups: [.init(id: "SSH Configuration", domains: ["ssh-configuration"])], inventory: [row])
        let dependency: [String: Any] = ["domain": "ssh-configuration", "item_id": "identity-references", "action": "none", "disposition": "warning", "reason": "identity_dependencies_unresolved"]
        let secure: [String: Any] = ["domain": "secure-ssh-identities", "item_id": "encrypted_identity_set", "action": "validate_and_import", "disposition": "pending_unlock", "reason": "secure_unlock_required"]
        let values: [String: Any] = ["prepared_plan_id": String(repeating: "a", count: 64), "selection": ["categories": ["ssh-configuration"], "items": [:]],
            "selected_groups": ["SSH Configuration"], "selected_categories": ["ssh-configuration"], "selected_item_counts": [:],
            "include_secure": true, "secure_restore_status": "selected_pending", "plan": [dependency, secure], "ssh_resolution": base,
            "readiness": ["ready": true, "ready_scope": "environment", "conditions": [["domain": "secure-ssh-identities", "code": "secure_bridge_required", "status": "external_action_required", "scope": "execution_launch"]], "reentry": "restore_prepare"],
            "has_planned_changes": true, "warning_count": 0, "error_count": 0]
        var plan = try JSONDecoder().decode(CoreRestorePreparation.self, from: JSONSerialization.data(withJSONObject: values))
        precondition(!plan.sshDependenciesReady)
        plan.secureComparison = .init(decision: .importRequired, targetState: String(repeating: "c", count: 64),
            sourceFingerprint: String(repeating: "b", count: 64), preparedPlanID: plan.preparedPlanID,
            selection: selection, includeSecure: true, comparisonOperationID: "fixture", sshResolution: qualified)
        let preview = RestorePreviewPresentation(plan, catalog: catalog)
        let key = preview.categories.first { $0.id == "ssh-configuration" }!.items[0]
        precondition(plan.sshDependenciesReady && key.title == "SSH key references" && key.status == .ready && key.restoreReadyText == "After Secure Transfer")
        let importTasks = RestoreTaskPresentation(preview: preview, plan: plan)
        let importDomain = importTasks.domains.first { $0.id == CoreRestorePreparation.secureDomain }!
        precondition(RestorePreviewVisibility.includes(importDomain) && importDomain.state == .planned,
                     "Planned Secure Transfer remains visible independently of SSH key advisories")
        plan.secureComparison?.sshResolution = pending
        precondition(!plan.sshDependenciesReady && RestorePreviewPresentation(plan, catalog: catalog).categories[0].items[0].status == .attention)
        let blockedTasks = RestoreTaskPresentation(preview: RestorePreviewPresentation(plan, catalog: catalog), plan: plan)
        precondition(blockedTasks.automaticAttentionCount > 0 && blockedTasks.domains.contains(where: RestorePreviewVisibility.includes))
        var conflict = values
        conflict["include_secure"] = false; conflict["secure_restore_status"] = "not_selected"
        conflict.removeValue(forKey: "ssh_resolution") // Legacy v1 still cannot silently skip a selected conflict.
        conflict["plan"] = [["domain": "ssh-configuration", "item_id": "config", "action": "none", "disposition": "conflict", "reason": "target_conflict"]]
        let legacy = try JSONDecoder().decode(CoreRestorePreparation.self, from: JSONSerialization.data(withJSONObject: conflict))
        precondition(!legacy.sshDependenciesReady)
        let conflictTasks = RestoreTaskPresentation(preview: RestorePreviewPresentation(legacy, catalog: catalog), plan: legacy)
        precondition(conflictTasks.automaticAttentionCount > 0 && RestorePreviewVisibility.includes(conflictTasks.domains[0]))
        for finding in ["missing", "unresolved", "unsafe_target", "local_satisfied", "no_file_dependency"] {
            var independent = values
            independent["include_secure"] = false; independent["secure_restore_status"] = "not_selected"
            independent["has_planned_changes"] = false
            independent["readiness"] = ["ready": true, "ready_scope": "environment", "conditions": [], "reentry": "restore_prepare"] as [String: Any]
            independent["ssh_resolution"] = ["version": 1, "action": "noop", "ready": true, "pending": false,
                "dependencies": ["version": 1, "findings": [finding]], "remote_authentication": "not_assessed"] as [String: Any]
            independent["plan"] = [["domain": "ssh-configuration", "item_id": "config", "action": "none", "disposition": "satisfied", "reason": NSNull()], dependency]
            let prepared = try JSONDecoder().decode(CoreRestorePreparation.self, from: JSONSerialization.data(withJSONObject: independent))
            let presentation = RestorePreviewPresentation(prepared, catalog: catalog)
            let tasks = RestoreTaskPresentation(preview: presentation, plan: prepared)
            precondition(prepared.sshDependenciesReady && tasks.automaticAttentionCount == 0)
            precondition(tasks.domains.count == 1 && tasks.domains[0].items.count == 1 && tasks.domains[0].state == .matching)
            let advisory = ["missing", "unresolved", "unsafe_target"].contains(finding)
            precondition((tasks.domains[0].sshKeyAdvisory != nil) == advisory)
            precondition(!RestorePreviewVisibility.includes(tasks.domains[0]),
                         "An advisory alone must not make matching configuration a Preview work item")
            precondition(RestorePreviewMetrics.counts(tasks.domains).attention == 0)
            let otherMatches = TaskDomainPresentation(id: "homebrew-packages", title: "Homebrew Packages", symbol: "shippingbox",
                items: (0..<101).map { index in
                    let id = "matching-\(index)"
                    return TaskItemPresentation(id: id, item: .init(id: id, title: id, status: .matching, action: ""), state: .matching)
                })
            let domains = tasks.domains + [otherMatches]
            let counts = RestorePreviewMetrics.counts(domains)
            precondition(counts.matching == 102 && counts.changes == 0 && counts.attention == 0)
            let content = RestorePreviewContent(title: "", state: .matching, domains: domains, alreadyMatches: true,
                previewEvaluated: true, prerequisites: .init(conditions: [], ready: true), areas: [], showsActions: false)
            precondition(content.allMatchCount == 102 && content.visibleDomains.isEmpty && !content.showsPrerequisites,
                         "All matching requirements with an unverified key show only Everything Already Matches")
            let blockedContent = RestorePreviewContent(title: "", state: .matching, domains: domains, alreadyMatches: true,
                previewEvaluated: true, prerequisites: .init(conditions: [], ready: false), areas: [], showsActions: false)
            precondition(blockedContent.allMatchCount == nil && blockedContent.showsPrerequisites,
                         "Removing an advisory work item must not hide failed readiness")
        }
        for (reason, disposition, status, readyText) in [
            ("git_ssh_local_ready", "planned", DisplayStatus.ready, "Ready to Restore"),
            ("git_ssh_restore_pending", "planned", .ready, "Conditional"),
            ("git_ssh_identity_unresolved", "blocked", .attention, ""),
            ("git_ssh_configuration_conflict", "blocked", .attention, "")
        ] {
            var gitPlan = values
            gitPlan["plan"] = [["domain": "git-repositories", "item_id": "1", "action": "clone", "disposition": disposition, "reason": reason]]
            gitPlan["include_secure"] = false; gitPlan.removeValue(forKey: "ssh_resolution")
            let prepared = try JSONDecoder().decode(CoreRestorePreparation.self, from: JSONSerialization.data(withJSONObject: gitPlan))
            let presentation = RestorePreviewPresentation(prepared, catalog: catalog)
            let item = presentation.categories[0].items[0]
            precondition(presentation.categories.count == 1 && presentation.categories[0].items.count == 1,
                         "SSH qualification describes the clone, not an additional task")
            precondition(item.status == status && (item.restoreReadyText ?? "") == readyText)
            if status == .ready { precondition(item.action.contains("Remote authentication has not been tested")) }
        }
        print("PASS: SSH advisories preserve all-match presentation; Git clone dependency states retain one task and do not imply remote authentication")
    }

    @MainActor static func developerSelectionChecks() async throws {
        let groups = DeveloperSelectionGroup.allCases
        precondition(groups.map(\.title) == ["Git", "SSH", "Workspace", "Shell"])
        precondition(Set(groups.flatMap(\.domains)).count == 7)
        precondition(DeveloperSelectionGroup.state([.all, .all]) == .all)
        precondition(DeveloperSelectionGroup.state([.all, .none]) == .mixed)
        precondition(DeveloperSelectionGroup.state([.mixed]) == .mixed)
        precondition(DeveloperSelectionGroup.state([]) == .none)
        precondition(DeveloperSelectionGroup.summary(.all, available: false) == "Unavailable")
        let ids = groups.flatMap(\.domains)
        let developer = DeveloperSelectionGroup.disclosureIDs(ids)
        precondition(Set(groups.map(\.id)).isSubset(of: developer) && !developer.contains(CaptureHierarchy.sectionID(.advanced)))
        let standard = CaptureHierarchy.disclosureIDs(["homebrew-packages", "macos-finder", "vscode-settings"], scope: .ordinary)
        precondition(developer.isDisjoint(with: standard))
        precondition(CaptureHierarchy.toggled(standard, ids: developer).isSuperset(of: standard))
        // Shared read-only taxonomy and its default disclosure policy are unchanged.
        precondition(WorkspacePresentationTaxonomy.group(for: "git-configuration") == .advanced)
        precondition(CaptureHierarchy.initialExpansion.isEmpty)
        precondition(CaptureHierarchy.disclosureIDs(["git-configuration"], scope: .advanced).contains(DeveloperSelectionGroup.git.id))
        for id in ids.filter({ $0 != "git-configuration" }) { for flow in [SelectionHelpFlow.capture, .rebuild] {
            precondition(SelectionCategoryHelp.text(id, flow: flow)?.isEmpty == false)
        } }
        precondition(SelectionCategoryHelp.text(CaptureHierarchy.secureTransferID, flow: .capture)?.contains("not encrypted") == true)
        precondition(SelectionCategoryHelp.text("ssh-configuration", flow: .rebuild)?.contains("explicit approval") == true)
        let qualified = ["Git Configuration", "Git Repositories / Worktrees", "SSH Configuration", "SSH Keys",
            "Workspace Folders", "VS Code Workspace", "Zsh Configuration"]
        precondition(zip(ids, qualified).allSatisfy { DeveloperSelectionGroup.label($0, fallback: "old") == $1 })
        precondition(DeveloperSelectionGroup.label(CoreRestorePreparation.secureDomain, fallback: "Secure Transfer") == "SSH Keys")
        precondition(DeveloperSelectionGroup.label("ssh-configuration", fallback: "old", parent: .git) == "SSH Configuration")
        precondition(DeveloperSelectionGroup.label("ssh-configuration", fallback: "old", parent: .ssh) == "Configuration")
        precondition(DeveloperSelectionGroup.label("workspace-folders", fallback: "old", parent: .workspace) == "Folders")
        precondition(DeveloperSelectionGroup.label("future", fallback: "Preserved") == "Preserved")
        for id in CaptureMacOSSettingsGroup.domainIDs + ["git-configuration", "homebrew-packages", "future"] {
            for flow in [SelectionHelpFlow.capture, .rebuild] { precondition(SelectionCategoryHelp.text(id, flow: flow) == nil) }
        }
        precondition(WorkspacePresentationTaxonomy.Section.allCases.allSatisfy { $0.title != "Advanced" })
        _ = NSApplication.shared
        // Pixel evidence is scoped to category icons; status symbols keep their own semantic colors.
        for scheme in [ColorScheme.light, .dark] {
            for id in ids + [CoreRestorePreparation.secureDomain, "macos-finder", "homebrew-packages"] {
                let icon = WorkspaceCategoryIcon(symbol: "key", domainID: id).padding(8).background(Color.white).environment(\.colorScheme, scheme)
                let bitmap = NSBitmapImageRep(cgImage: ImageRenderer(content: icon).cgImage!)
                var blue = false, orange = false
                for x in 0..<bitmap.pixelsWide { for y in 0..<bitmap.pixelsHigh {
                    let c = bitmap.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
                    guard c.alphaComponent > 0.9 else { continue }
                    blue = blue || (c.blueComponent > c.redComponent * 1.4 && c.blueComponent > 0.4)
                    orange = orange || (c.redComponent > c.greenComponent * 1.15 && c.redComponent > 0.5 && c.redComponent > c.blueComponent * 1.4)
                } }
                precondition(DeveloperSelectionGroup.group(for: id) == nil ? blue && !orange : orange && !blue, "Icon \(id) \(scheme): blue=\(blue) orange=\(orange)")
            }
        }
        let capture = try String(contentsOfFile: "Sources/CaptureView.swift")
        let restore = try String(contentsOfFile: "Sources/RestoreView.swift")
        let task = try String(contentsOfFile: "Sources/TaskComponents.swift")
        let check = try String(contentsOfFile: "Sources/EnvironmentStatusView.swift")
        precondition(capture.components(separatedBy: "developerSelection:").count == 2 && restore.components(separatedBy: "developerSelection:").count == 2)
        precondition(!task.contains("developerSelection:") && !check.contains("NativeSelectionCheckbox"))
        secureRestoreAvailabilityChecks(restore)
        try sshResolutionPresentationChecks()
        _ = NSApplication.shared; NSApp.appearance = NSAppearance(named: .aqua)
        var disclosed = false
        func fixture(_ showingHelp: Bool) -> some View {
            VStack {
                SelectionCategoryTitle(id: "ssh-configuration", title: "Configuration", symbol: "key", flow: .rebuild,
                    toggle: { disclosed.toggle() }, helpPresentation: .constant(showingHelp))
                Spacer()
            }.padding(24).frame(width: 420, height: 360).background(Color(nsColor: .windowBackgroundColor))
        }
        let host = NSHostingView(rootView: fixture(false))
        let window = NSWindow(contentRect: .init(x: 100, y: 200, width: 420, height: 360), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100))
        host.rootView = fixture(true)
        try await Task.sleep(for: .milliseconds(500)); host.layoutSubtreeIfNeeded()
        precondition(!disclosed, "Help never triggers the category disclosure")
        let popovers = NSApp.windows.filter { $0 !== window && $0.isVisible }
        guard let popover = popovers.first, let content = popover.contentView else { preconditionFailure("Native help popover did not open") }
        func hostingView(_ view: NSView) -> NSView? {
            if String(describing: type(of: view)).contains("HostingView") { return view }
            return view.subviews.lazy.compactMap(hostingView).first
        }
        guard let help = hostingView(content) else { preconditionFailure("Native popover has no rendered SwiftUI content") }
        help.layoutSubtreeIfNeeded(); help.displayIfNeeded()
        precondition(help.bounds.width > 0 && help.bounds.height > 0)
        // Optional local visual evidence: SwiftUI popovers use a compositor layer
        // that cacheDisplay does not capture. Capture only this fixture's window;
        // automated suites do not require screen-recording permission.
        if CommandLine.arguments.contains("--native-help-screenshot") {
            let output = URL(fileURLWithPath: "build/Debug/DeveloperSelection")
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let screenshot = Process()
            screenshot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            screenshot.arguments = ["-x", "-o", "-l", String(popover.windowNumber), output.appendingPathComponent("contextual-help-popover-light.png").path]
            try screenshot.run(); screenshot.waitUntilExit()
            precondition(screenshot.terminationStatus == 0, "Fixture popover screenshot failed")
        }
        host.rootView = fixture(false)
        print("PASS: canonical developer labels/groups/accent, selective native help, protected legacy taxonomy, consent and all-match/Preview semantics")
    }
    @MainActor static func selectionHelpChecks() async throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared; NSApp.setActivationPolicy(.accessory)
        let previousAppearance = NSApp.appearance
        defer { NSApp.appearance = previousAppearance }
        let output = URL(fileURLWithPath: "build/Debug/SelectionHelpPolish")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        func descendants<T: NSView>(_ view: NSView, _: T.Type) -> [T] {
            (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, T.self) }
        }
        for flow in [SelectionHelpFlow.capture, .rebuild] {
            for (width, height): (CGFloat, CGFloat) in [(580, 520), (985, 700)] {
                for dark in [false, true] {
                    NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    let state = SelectionHelpFixtureState()
                    let host = NSHostingView(rootView: SelectionHelpFixtureView(state: state, flow: flow))
                    let window = NSWindow(contentRect: .init(x: 100, y: 100, width: width, height: height),
                        styleMask: [.titled, .closable], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false; window.contentView = host
                    window.makeKeyAndOrderFront(nil)
                    defer { window.close() }
                    func settle() async {
                        try? await Task.sleep(for: .milliseconds(180))
                        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
                    }
                    await settle()
                    let scrolls = descendants(host, NSScrollView.self)
                    precondition(scrolls.count == 1)
                    let scroll = scrolls[0], document = scroll.documentView!
                    let viewport = scroll.convert(scroll.bounds, to: host)
                    let originalGroups = state.groups
                    func popovers() -> [NSWindow] { NSApp.windows.filter { $0 !== window && $0.isVisible } }
                    func trigger(_ id: String) -> CGRect {
                        guard let frame = state.titleFrames[id] else { preconditionFailure("Missing native help title: \(id)") }
                        precondition(frame.height >= 24)
                        // The compact title ends with the production 24pt Info
                        // button. Measure the live row rather than hard-code its position.
                        return CGRect(x: frame.maxX - 24, y: frame.midY - 12, width: 24, height: 24)
                    }
                    func press(_ id: String) async {
                        let frame = trigger(id)
                        let point = host.convert(NSPoint(x: frame.midX, y: host.isFlipped ? frame.midY : host.bounds.height - frame.midY), to: nil)
                        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                            window.sendEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!)
                        }
                        await settle()
                    }
                    func screenshot(_ suffix: String, popover: Bool = false) throws {
                        guard CommandLine.arguments.contains("--native-help-screenshot") else { return }
                        let name = "\(flow == .capture ? "capture" : "rebuild")-\(Int(width))-\(dark ? "dark" : "light")-\(suffix).png"
                        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                        process.arguments = ["-x", "-o", "-l", String((popover ? popovers().first! : window).windowNumber), output.appendingPathComponent(name).path]
                        try process.run(); process.waitUntilExit(); precondition(process.terminationStatus == 0)
                    }
                    func reveal(_ id: String, atBottom: Bool) async {
                        let rect = document.convert(trigger(id), from: host)
                        let y = atBottom ? rect.maxY - scroll.contentView.bounds.height + 12 : rect.minY - 12
                        let limit = max(0, document.bounds.height - scroll.contentView.bounds.height)
                        scroll.contentView.scroll(to: .init(x: 0, y: min(max(0, y), limit)))
                        scroll.reflectScrolledClipView(scroll.contentView); await settle()
                    }
                    try screenshot("icon")
                    await press("git-repositories")
                    precondition(popovers().count == 1, "Info opens one native popover")
                    await press("git-repositories")
                    precondition(popovers().isEmpty, "Pressing Info again closes it")
                    await press("git-repositories")
                    scroll.contentView.scroll(to: .init(x: 0, y: 20)); scroll.reflectScrolledClipView(scroll.contentView); await settle()
                    precondition(popovers().isEmpty, "Moving the containing clip view dismisses help")
                    try screenshot("after-scroll")
                    await reveal("ssh-configuration", atBottom: true)
                    // The window is near the screen's bottom edge; native popover
                    // placement, not application offsets, must keep help usable.
                    let screen = window.screen!.visibleFrame
                    window.setFrameOrigin(.init(x: screen.minX + 30, y: screen.minY + 8)); await settle()
                    await press("ssh-configuration")
                    precondition(popovers().count == 1)
                    precondition(screen.insetBy(dx: -1, dy: -1).contains(popovers()[0].frame), "Bottom-edge native help remains on screen")
                    try screenshot("bottom-open")
                    try screenshot("bottom-popover", popover: true)
                    // Invoke the native Escape/cancel responder action. The
                    // command-line fixture need not steal application focus.
                    let popup = popovers()[0]
                    popup.cancelOperation(nil)
                    await settle(); precondition(popovers().isEmpty, "Escape dismisses native help")
                    await press("ssh-configuration")
                    let clipAmount = max(80, scroll.convert(scroll.bounds, to: host).maxY - trigger("ssh-configuration").minY + 12)
                    window.setContentSize(.init(width: width, height: height - clipAmount)); await settle()
                    precondition(!scroll.convert(scroll.bounds, to: host).contains(trigger("ssh-configuration")), "Resize fixture must clip the source trigger")
                    precondition(popovers().isEmpty, "Clipping the trigger during a resize dismisses help")
                    window.setContentSize(.init(width: width, height: height)); await settle()
                    await reveal("ssh-configuration", atBottom: true)
                    await press("ssh-configuration")
                    state.showsSSH = false; await settle()
                    precondition(popovers().isEmpty, "Removing the source category dismisses help")
                    state.showsSSH = true; await settle()
                    await reveal("ssh-configuration", atBottom: false)
                    window.setFrameOrigin(.init(x: screen.minX + 30, y: screen.maxY - window.frame.height - 8)); await settle()
                    await press("ssh-configuration")
                    precondition(popovers().count == 1 && screen.insetBy(dx: -1, dy: -1).contains(popovers()[0].frame), "Top-edge help remains usable")
                    // Opening another visible category keeps only one native help.
                    await press("workspace-folders")
                    precondition(popovers().count <= 1, "Changing categories never stacks native help")
                    // Native popovers may consume the first outside click to
                    // dismiss; a subsequent click then opens the new category.
                    if popovers().isEmpty { await press("workspace-folders") }
                    precondition(popovers().count == 1, "Only one contextual help is presented")
                    await press("workspace-folders")
                    precondition(popovers().isEmpty, "The new category owns and toggles its help")
                    await press("workspace-folders")
                    scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView); await settle()
                    precondition(popovers().isEmpty && !state.selected && !state.categoryExpanded && state.groups == originalGroups)
                    precondition(scroll.convert(scroll.bounds, to: host) == viewport, "Help does not change the list/footer geometry")
                    window.close()
                    print("PASS: \(flow) help \(Int(width))x\(Int(height)) \(dark ? "Dark" : "Light"): native toggle/cancel, scroll/clipping/removal dismissal, screen edges, one help, 24pt target and unchanged selection/disclosure/footer")
                }
            }
        }
    }
    @MainActor static func main() async {
        if CommandLine.arguments.contains("--selection-help-only") { try! await selectionHelpChecks(); return }
        if CommandLine.arguments.contains("--developer-selection-only") { try! await developerSelectionChecks(); return }
        if CommandLine.arguments.contains("--ssh-resolution-only") { try! sshResolutionPresentationChecks(); return }
        if CommandLine.arguments.contains("--workflow-contracts-only") { workflowContractChecks(); return }
        if CommandLine.arguments.contains("--preview-column-geometry-only") { previewColumnGeometryChecks(); return }
        if CommandLine.arguments.contains("--preview-cleanup-only") {
            try! previewCleanupChecks()
            restorePreviewNoticesChecks()
            return
        }
        if CommandLine.arguments.contains("--capture-preview-refinement-only") {
            try! await capturePreviewRefinementChecks()
            try! captureDisclosureChecks()
            restorePreviewNoticesChecks()
            restorePreviewGroupingChecks()
            return
        }
        if CommandLine.arguments.contains("--external-identities-only") { try! await externalIdentityChecks(); return }
        if CommandLine.arguments.contains("--settings-tools-only") { try! await settingsToolsChecks(); return }
        if CommandLine.arguments.contains("--bundled-age-only") { try! bundledAgeErrorChecks(); return }
        if CommandLine.arguments.contains("--secure-passphrase-only") || CommandLine.arguments.contains("--secure-dialog-only") { try! await securePassphraseChecks(); return }
        if CommandLine.arguments.contains("--secure-startup-only") { try! secureStartupErrorChecks(); return }
        if CommandLine.arguments.contains("--prelaunch-request-only") { try! prelaunchRequestChecks(); return }
        if CommandLine.arguments.contains("--secure-compare-only") { try! await secureComparisonChecks(); return }
        if CommandLine.arguments.contains("--secure-availability-only") {
            secureRestoreAvailabilityChecks(try! String(contentsOfFile: "Sources/RestoreView.swift"))
            return
        }
        if CommandLine.arguments.contains("--secure-restore-only") { try! await secureRestoreChecks(); return }
        if CommandLine.arguments.contains("--capture-disclosure-only") {
            try! await capturePreviewRefinementChecks(captureOnly: true)
            try! captureDisclosureChecks()
            return
        }
        if CommandLine.arguments.contains("--secure-selection-only") { try! await secureSelectionChecks(); return }
        if CommandLine.arguments.contains("--secure-capture-only") { try! await secureCaptureChecks(); return }
        if CommandLine.arguments.contains("--homebrew-setup-only") { await homebrewSetupChecks(); return }
        if CommandLine.arguments.contains("--operation-log-only") { operationLogChecks(); return }
        if CommandLine.arguments.contains("--sidebar-layout-only") { await sidebarLayoutChecks(); return }
        if CommandLine.arguments.contains("--summary-metrics-only") {
            try! await summaryMetricVisibilityChecks(); minimalResultSummaryChecks(); return
        }
        if CommandLine.arguments.contains("--status-grouping-only") { textStatusLayoutChecks(); return }
        if CommandLine.arguments.contains("--restore-stopped-result-only") {
            try! await restoreStoppedResultChecks(); restoreResultSummaryChecks(); return
        }
        if CommandLine.arguments.contains("--restore-actual-changes-only") {
            try! await restoreActualChangesChecks(); restoreResultSummaryChecks(); resultCleanupChecks(); return
        }
        if CommandLine.arguments.contains("--restore-flat-categories-only") { restoreFlatCategoryChecks(); executionVisualChecks(); appStoreVisualChecks(); return }
        if CommandLine.arguments.contains("--restore-preview-grouping-only") { restorePreviewGroupingChecks(); return }
        if CommandLine.arguments.contains("--restore-selection-only") { restoreSelectionAccordionChecks(); return }
        topologyPreviewChecks()
        if CommandLine.arguments.contains("--topology-preview-only") { return }
        if CommandLine.arguments.contains("--preview-notices-only") { restorePreviewNoticesChecks(); return }
        if CommandLine.arguments.contains("--final-alignment-only") { try! await finalCapturePreviewAlignmentChecks(); return }
        if CommandLine.arguments.contains("--restore-macos-only") { await restoreMacOSChecks(); return }
        if CommandLine.arguments.contains("--workflow-scroll-only") { try! await workflowStatusScrollChecks(); return }
        if CommandLine.arguments.count == 1 {
            try! await selectionHelpChecks()
            try! await developerSelectionChecks()
            try! await secureSelectionChecks()
            try! await capturePreviewRefinementChecks()
            try! previewCleanupChecks()
            try! await settingsToolsChecks()
            await homebrewSetupChecks()
            try! await summaryMetricVisibilityChecks()
            await sidebarLayoutChecks()
        }
        runChecks()
    }

    @MainActor static func runChecks() {
        restoreSelectionAccordionChecks()
        if CommandLine.arguments.contains("--workflow-descendants-only") { workflowDescendantChecks(); return }
        if CommandLine.arguments.contains("--workflow-controls-only") { workflowInteractiveControlsChecks(); operationLogChecks(); resultStatusAlignmentChecks(); screenshotsIncludedSettingsChecks(); workflowDescendantChecks(); return }
        if CommandLine.arguments.contains("--workflow-layout-only") { workflowDescendantChecks(); workflowLayoutChecks(); return }
        if CommandLine.arguments.contains("--concise-workflows-only") { conciseWorkflowChecks(); operationLogChecks(); resultCleanupChecks(); restoreResultSummaryChecks(); return }
        if CommandLine.arguments.contains("--preview-expansion-only") { previewExpansionPerformanceChecks(); return }
        if CommandLine.arguments.contains("--preview-appstore-layout-only") { previewColumnGeometryChecks(); resultStatusAlignmentChecks(); appStoreVisualChecks(); return }
        if CommandLine.arguments.contains("--selection-preview-only") { resultCleanupChecks(); resultStatusAlignmentChecks(); return }
        if CommandLine.arguments.contains("--appstore-visual-only") { appStoreVisualChecks(); return }
        if CommandLine.arguments.contains("--restore-result-columns-only") { restoreResultColumnsChecks(); resultStatusAlignmentChecks(); resultCleanupChecks(); minimalResultSummaryChecks(); appStoreVisualChecks(); return }
        if CommandLine.arguments.contains("--capture-checkpoint-only") { captureCompactSettingsChecks(); captureResultActionsChecks(); screenshotsIncludedSettingsChecks(); windowsIncludedSettingsChecks(); captureResultAlignmentChecks(); return }
        if CommandLine.arguments.contains("--windows-included-only") { windowsIncludedSettingsChecks(); return }
        if CommandLine.arguments.contains("--screenshots-included-only") { screenshotsIncludedSettingsChecks(); return }
        if CommandLine.arguments.contains("--capture-result-actions-only") { captureResultActionsChecks(); return }
        if CommandLine.arguments.contains("--rosetta-only") { restoreSummaryChecks(); return }
        if CommandLine.arguments.contains("--unsupported-repair-explanation-only") { unsupportedRepairExplanationChecks(); return }
        if CommandLine.arguments.contains("--text-status-layout-only") { textStatusLayoutChecks(); return }
        if CommandLine.arguments.contains("--pkg-preparation-only") || CommandLine.arguments.contains("--fix-issues-only") {
            let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            let view = try! String(contentsOf: root.appendingPathComponent("Sources/RestoreView.swift"))
            let model = try! String(contentsOf: root.appendingPathComponent("Sources/RestoreModel.swift"))
            precondition(view.contains("Prepare installers?") && view.contains("Download and Inspect"))
            precondition(view.contains("model.installerPreparationRows") && view.contains("model.cancelInstallerPreparation()"))
            precondition(model.contains("installerConsentPlanID") && model.contains("installerPreparations: identities"))
            let pkg = CoreRestorePreparation.Condition(domain: "homebrew-casks",
                code: "cask_execution_requirements_unsupported", status: "unsupported", selectedItemIndex: 1, scope: "item",
                diagnostic: .init(primitive: "pkgutil", condition: "preparation_required"))
            let automation = CoreRestorePreparation.Condition(domain: "homebrew-casks",
                code: "cask_metadata_unavailable", status: "external_action_required", selectedItemIndex: 2, scope: "operation",
                diagnostic: .init(primitive: "login_item", condition: "application_unavailable"))
            let ready = RestorePrerequisiteSummaryPresentation(conditions: [], ready: true)
            precondition(!ready.isVisible && !ready.canFixIssues)
            let pkgOnly = RestorePrerequisiteSummaryPresentation(conditions: [pkg], ready: true, hasInstallerPreparations: true)
            precondition(pkgOnly.title == "Needs Preparation" && pkgOnly.isVisible && pkgOnly.canFixIssues && pkgOnly.displayConditions.count == 1)
            precondition(pkg.diagnostic!.explanation == "Installer preparation required before this application can be restored.")
            let permissionOnly = RestorePrerequisiteSummaryPresentation(conditions: [automation], ready: false)
            precondition(permissionOnly.title == "Needs Preparation" && permissionOnly.canFixIssues && permissionOnly.isVisible)
            let denied = CoreRestorePreparation.Condition(domain: "homebrew-casks",
                code: "cask_metadata_unavailable", status: "external_action_required", selectedItemIndex: 2, scope: "operation",
                diagnostic: .init(primitive: "login_item", condition: "authorization_denied"))
            let manualPermission = RestorePrerequisiteSummaryPresentation(conditions: [denied], ready: false)
            precondition(manualPermission.isVisible && !manualPermission.canFixIssues)
            precondition(denied.diagnostic!.explanation.contains("System Settings"))
            let both = RestorePrerequisiteSummaryPresentation(conditions: [pkg, automation], ready: false, hasInstallerPreparations: true)
            precondition(both.canFixIssues && both.displayConditions.count == 2 && both.affectedDomains == ["homebrew-casks"])
            let manual = CoreRestorePreparation.Condition(domain: "homebrew-casks", code: "homebrew_unavailable",
                status: "external_action_required", selectedItemIndex: nil, scope: "operation")
            let blocked = RestorePrerequisiteSummaryPresentation(conditions: [manual], ready: false)
            precondition(blocked.isVisible && !blocked.canFixIssues && blocked.displayConditions.count == 1)
            for (summary, visible) in [(ready, false), (pkgOnly, true), (permissionOnly, true), (both, true), (blocked, false)] {
                let preview = RestorePreviewContent(title: "Needs Attention", state: .attention,
                    domains: [], alreadyMatches: false, prerequisites: summary, areas: [])
                precondition(preview.showsFixIssues == visible && !preview.canRebuild)
            }
            precondition(pkgOnly.preparationCount == 1 && pkgOnly.manualConditions.isEmpty)
            precondition(pkgOnly.preparationMessage == "1 preparation requirement needs attention.")
            precondition(permissionOnly.preparationCount == 1 && permissionOnly.manualConditions.isEmpty)
            precondition(both.preparationCount == 2 && both.manualConditions.isEmpty)
            precondition(both.preparationMessage == "2 preparation requirements need attention.")
            precondition(manualPermission.manualConditions.count == 1 && blocked.manualConditions.count == 1)
            let mixed = RestorePrerequisiteSummaryPresentation(conditions: [pkg, automation, denied], ready: false, hasInstallerPreparations: true)
            precondition(mixed.preparationCount == 2 && mixed.manualConditions.count == 1)
            let summarySource = try! String(contentsOf: root.appendingPathComponent("Sources/RestoreSummary.swift"))
            let summaryView = summarySource.components(separatedBy: "struct RestorePrerequisiteSummaryView: View {")[1]
                .components(separatedBy: "private struct RestoreBlockingPrerequisiteAreaView:")[0]
            precondition(!summaryView.contains("Needs Preparation") && !summaryView.contains("preparationMessage"))
            precondition(summaryView.contains("if !summary.manualConditions.isEmpty"))
            precondition(summaryView.contains("conditions: summary.manualConditions.filter"))
            precondition(!summaryView.contains("summary.displayConditions") && !summaryView.contains("summary.affectedDomains"))
            let content = view.components(separatedBy: "struct RestorePreviewContent: View {")[1]
            precondition(content.range(of: "if showsFixIssues {")!.lowerBound < content.range(of: "TaskDomainList(")!.lowerBound)
            precondition(view.contains("Macseed will guide you through available fixes. Your approval may be required. No applications will be installed yet."))
            print("PASS: Fix Issues presentation: hidden ready state, PKG, Automation, combined conditions and manual blockers")
            return
        }
        restoreResultSummaryChecks()
        if CommandLine.arguments.contains("--visual-contract-only") { visualContractChecks(); return }
        if CommandLine.arguments.contains("--result-cleanup-only") { resultCleanupChecks(); return }
        if CommandLine.arguments.contains("--minimal-result-summary-only") { minimalResultSummaryChecks(); return }
        if CommandLine.arguments.contains("--neutral-unverified-only") { neutralUnverifiedChecks(); return }
        if CommandLine.arguments.contains("--execution-visual-only") { executionVisualChecks(); return }
        if CommandLine.arguments.contains("--final-ui-only") { finalUIAlignmentChecks(); return }
        if CommandLine.arguments.contains("--final-corrections") { finalCorrectionChecks(); return }
        if CommandLine.arguments.contains("--restore-only") { renderRestoreV2(); return }
        try! captureDisclosureChecks()
        try! sshResolutionPresentationChecks()
        let finalItem = TaskItemPresentation(id: "result-item", item: DisplayItem(id: "result-item", title: "Example", status: .information, action: "Confirmed outcome"), state: .completed, resultLabels: ["Applied", "Verified"])
        for state in [TaskRowState.completed, .attention, .failed, .unverified, .notRun] {
            let domain = TaskDomainPresentation(id: "homebrew-casks", title: "Homebrew Applications", symbol: "app", items: [finalItem], confirmedFinalState: state)
            for width in [CGFloat(500), CGFloat(900)] {
                for expanded in [false, true] {
                    let renderer = ImageRenderer(content: RestoreFinalDomain(domain: domain, expansion: .constant(expanded)).frame(width: width))
                    precondition(renderer.nsImage != nil)
                }
            }
        }
        for count in 1...10 {
            let boundary = 300 + 28 + OperationSummaryLayout.metricWidth(count)
            precondition(!OperationSummaryLayout.horizontal(width: boundary - 1, count: count))
            precondition(OperationSummaryLayout.horizontal(width: boundary, count: count))
            precondition(OperationSummaryLayout.horizontal(width: boundary + 1, count: count))
        }
        precondition(OperationMetricsLayout.columns(width: 477, count: 4) == 3)
        precondition(OperationMetricsLayout.columns(width: 478, count: 4) == 4)

        if CommandLine.arguments.count == 4 && CommandLine.arguments[1] == "--appearance-read" {
            let stored = UserDefaults(suiteName: CommandLine.arguments[2])!.string(forKey: DesktopAppearance.preferenceKey)
            precondition(stored == CommandLine.arguments[3])
            return
        }
        #if DEBUG
        precondition(RestoreDebugScenarios.shared.selected == .real)
        precondition(RestoreDebugScenario.real.domains.isEmpty)
        for scenario in RestoreDebugScenario.allCases where scenario != .real {
            precondition(scenario.counters.reduce(0) { $0 + $1.count } == scenario.domains.count)
            precondition(Set(scenario.domains.map(\.id)).count == scenario.domains.count)
        }
        precondition(RestoreDebugScenario.preview.domains.contains { $0.state == .partial })
        precondition(!RestoreDebugScenario.preview.domains.contains { $0.state == .failed })
        precondition(Set(RestoreDebugScenario.rebuilding.domains.map(\.state)) == Set([.completed, .working, .waiting, .skipped, .failed]))
        precondition(Set(RestoreDebugScenario.issues.domains.map(\.state)) == Set([.completed, .attention, .skipped, .failed]))
        precondition(RestoreDebugScenario.done.domains.allSatisfy { $0.state == .completed && $0.items.allSatisfy { $0.item.reason == nil } })
        let scenarioSource = try! String(contentsOfFile: "Sources/SampleProvider.swift", encoding: .utf8)
        let fixtureSource = scenarioSource.components(separatedBy: "// Manual presentation fixtures only.")[1]
        precondition(!fixtureSource.contains("CoreRuntime") && !fixtureSource.contains("RestoreModel") && !fixtureSource.contains("Process("))
        let commandSource = try! String(contentsOfFile: "Sources/MacseedApp.swift", encoding: .utf8)
        precondition(commandSource.contains("#if DEBUG\nstruct RestoreScenarioCommands"))
        print("PASS: DEBUG Restore scenarios use presentation fixtures, truthful Preview states and no runtime actions")
        #endif
        let components = try! String(contentsOfFile: "Sources/TaskComponents.swift", encoding: .utf8)
        precondition(!components.contains("DisclosureGroup(\"Technical"))
        for state in [TaskRowState.attention, .working] {
            var row = TaskItemPresentation(id: "diagnostic", item: DisplayItem(id: "diagnostic", title: "Fixture",
                status: .attention, action: "Inspect", reason: "observation_failed"), state: state)
            precondition(row.item.reason == "observation_failed")
            row.assistedAppStore = AssistedAppStoreItem(appID: "12345", status: .unverified)
            precondition(row.item.reason == "observation_failed")
        }
        let workspaceSource = try! String(contentsOfFile: "Sources/ProductionWorkspace.swift", encoding: .utf8)
        precondition(workspaceSource.range(of: "rebuildActionArea(synthetic: true)")!.lowerBound > workspaceSource.range(of: ".modifier(WorkspaceContentGeometry())")!.lowerBound)
        precondition(workspaceSource.contains("stop: synthetic ? nil : { restore.requestStop() }"))
        #if DEBUG
        precondition(RestoreDebugScenario.rebuilding.domains.flatMap(\.items).filter { $0.state == .working }.allSatisfy { $0.item.reason == nil })
        precondition(fixtureSource.contains("RestorePreviewContent(title:"))
        #endif
        captureResultActionsChecks()
        screenshotsIncludedSettingsChecks()
        windowsIncludedSettingsChecks()
        captureResultAlignmentChecks()
        restoreResultColumnsChecks()
        restoreSummaryChecks()
        resultCleanupChecks()
        minimalResultSummaryChecks()
        previewColumnGeometryChecks()
        resultStatusAlignmentChecks()
        appStoreVisualChecks()
        precondition(CaptureMetricCard.tone(attention: false, count: 0) == .blue)
        precondition(CaptureMetricCard.tone(attention: false, count: 5) == .blue)
        precondition(CaptureMetricCard.tone(attention: true, count: 0) == .neutral)
        precondition(CaptureMetricCard.tone(attention: true, count: 1) == .amber)
        visualContractChecks()
        renderUnifiedSettings()
        renderRestoreV2()
        renderInitialStates()
        appIconChecks()
        renderHomeBranding()
        let suite = "MacseedAppearanceTests-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        precondition(DesktopAppearance(storedValue: preferences.string(forKey: DesktopAppearance.preferenceKey)) == .system)
        precondition(DesktopAppearance(storedValue: "invalid") == .system)
        for mode in DesktopAppearance.allCases {
            preferences.set(mode.rawValue, forKey: DesktopAppearance.preferenceKey)
            let reopened = UserDefaults(suiteName: suite)!
            precondition(DesktopAppearance(storedValue: reopened.string(forKey: DesktopAppearance.preferenceKey)) == mode)
            precondition(preferences.synchronize())
            let nextLaunch = Process()
            nextLaunch.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            nextLaunch.arguments = ["--appearance-read", suite, mode.rawValue]
            try! nextLaunch.run()
            nextLaunch.waitUntilExit()
            precondition(nextLaunch.terminationStatus == 0, "Appearance persists across processes")
        }
        precondition(DesktopAppearance.system.appearanceName == nil)
        precondition(DesktopAppearance.light.appearanceName == .aqua)
        precondition(DesktopAppearance.dark.appearanceName == .darkAqua)
        print("PASS: Appearance defaults to System, persists all modes and maps to AppKit appearance")
        workflowContractChecks()
        sampleInteractionChecks()
    }

    @MainActor static func workflowContractChecks() {
        #if DEBUG
        setbuf(stdout, nil)
        precondition(BuildFeatures.sampleExperience)
        var sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
        if !FileManager.default.fileExists(atPath: sources.appendingPathComponent("EnvironmentStatusView.swift").path) {
            // build.sh uses relative source paths; native-control tests can run
            // from the repository root or another working directory.
            sources = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
        }
        let components = try! String(contentsOf: sources.appendingPathComponent("TaskComponents.swift"), encoding: .utf8)
        let workspaceSource = try! String(contentsOf: sources.appendingPathComponent("ProductionWorkspace.swift"), encoding: .utf8)
        let content = try! String(contentsOf: sources.appendingPathComponent("ContentView.swift"), encoding: .utf8)
        let statusView = try! String(contentsOf: sources.appendingPathComponent("EnvironmentStatusView.swift"), encoding: .utf8)
        precondition(statusView.contains("Check This Mac") && statusView.contains("Choose Saved Environment…"))
        precondition(statusView.contains("panel.canChooseDirectories = false") && statusView.contains("UTType(filenameExtension: \"mbt\")"))
        precondition(statusView.contains("model.selectBundle(url)"))
        precondition(statusView.contains("EnvironmentComparisonDomain(category: child, technicalFacts: technicalFacts,"))
        precondition(statusView.contains("DisclosureGroup(isExpanded: expansion ?? $expanded)"))
        precondition(statusView.contains("@ReferenceViewState<Bool> private var expanded = false"))
        precondition(statusView.contains("if model.state != .choose && horizontal { Spacer() }"))
        precondition(statusView.contains("if model.reference != nil {"))
        precondition(!statusView.contains("Text(result.summary)"))
        precondition(content.contains(".font(.system(size: prominent ? 15 : 13, weight: .semibold)).foregroundStyle(Color(nsColor: .labelColor))"))
        precondition(!statusView.contains("if let reason = item.comparisonTechnicalDetails"))
        precondition(statusView.contains("if !suppressExplanation, let explanation = item.comparisonExplanation"))
        precondition(statusView.contains("MatchedLeafIndicator()"))

        for technical in ["Choose Blueprint…", "Generated Configuration", "blueprint.path"] {
            precondition(!statusView.contains(technical), "Status uses a Bundle, not internal reference controls")
        }
        precondition(statusView.contains("EnvironmentComparisonView(result: result)"))
        precondition(statusView.contains("$0 == .needsAttention ? result.needsAttention : ($0.count(result) ?? 0) > 0"))
        precondition(statusView.contains("EnvironmentComparisonMetricsLayout {"))
        precondition(!statusView.contains("Additional applications") && !statusView.contains("additionalExpanded"))
        precondition(statusView.contains("tint: outcome.tint"))
        precondition(statusView.contains("Unsupported or incomplete checks"))
        precondition(statusView.contains("enum EnvironmentComparisonPalette"))
        precondition(statusView.contains("EnvironmentComparisonPalette.color(for: status)"))
        precondition(!statusView.contains("summaryTint"))

        precondition(statusView.contains("result.categoryCount($0, category: entry.category, children: entry.children)"))
        precondition(statusView.contains("counts[$0, default: 0] > 0") && statusView.contains("ComparisonOutcome.allCases.filter"))
        let countPill = components.components(separatedBy: "struct WorkflowCountPill: View {")[1]
            .components(separatedBy: "\nstruct ")[0]
        precondition(countPill.contains(".foregroundStyle(tint).background(tint.opacity(0.12), in: Capsule())"))
        precondition(!statusView.contains("Full Diagnostic Details") && !statusView.contains("fact.predicateTitle"))
        let domainView = statusView.components(separatedBy: "struct EnvironmentComparisonDomain: View")[1].components(separatedBy: "struct EnvironmentComparisonItem: View")[0]
        precondition(domainView.contains("WorkflowCountPill(count: count, label: label, tint: tint)") && domainView.contains("if let counts"))
        precondition(domainView.contains("WorkspaceCategoryIcon(symbol: category.symbol, domainID: category.id)") && content.contains("DeveloperSelectionGroup.accent(colorScheme)"))
        precondition(countPill.contains(".padding(.horizontal, 6).frame(minWidth: 32, minHeight: 23)"))
        precondition(content.contains("Rectangle().fill(Color.primary.opacity(0.22)).frame(height: 1.5)"))

        precondition(EnvironmentComparisonRowLayout.statusLabelWidth == 152)
        precondition(domainView.contains("WorkflowTrailingLayout(showsCounts: !Self.badgeCounts(counts).isEmpty, showsChevron: false, statusWidth: EnvironmentComparisonRowLayout.statusLabelWidth)"))
        precondition(domainView.contains("title: EnvironmentComparisonView.visibleCategory(category).comparisonStatusText)"))
        precondition(!domainView.contains("warningCompanion") && !domainView.contains("warning && outcomes"))

        let sectionHeader = content.components(separatedBy: "struct WorkspaceSectionHeader:")[1].components(separatedBy: "struct WorkspaceCategoryIcon:")[0]
        precondition(!sectionHeader.contains("Capsule()") && !sectionHeader.contains("counts"))
        precondition(domainView.contains("EnvironmentComparisonDomain(category: child, technicalFacts: technicalFacts,"))

        precondition(WorkspaceActionLayout.columns(659) == 1 && WorkspaceActionLayout.columns(660) == 3)
        precondition(WorkspaceMetricLayout.columns(899) == 2 && WorkspaceMetricLayout.columns(900) == 4)
        for task in ProductTask.allCases { precondition(NSImage(systemSymbolName: task.symbol, accessibilityDescription: nil) != nil) }
        precondition(statusView.contains("WorkspacePrimaryActionCard(title: \"Choose Saved Environment\""))
        precondition(!statusView.contains("WorkspaceResultHeader(title:") && statusView.contains("ForEach(Self.summaryOutcomes(result))"))

        let production = try! String(contentsOf: sources.appendingPathComponent("ProductionWorkspace.swift"), encoding: .utf8)
        let scrollEnd = production.range(of: "                if navigation.task == .status && status.state == .result {")!
        precondition(production[scrollEnd.lowerBound...].contains("EnvironmentStatusActions(model: status, runtime: runtime, reviewInRestore:"))
        precondition(production.contains("EnvironmentStatusView(model: status, runtime: runtime, showsActions: status.state != .result)"))
        precondition(statusView.contains("Button(\"Review in Rebuild\", action: reviewInRestore).buttonStyle(.bordered)"))
        precondition(statusView.contains(".disabled(busy || handoffBlocked)"))
        precondition(production.contains("reviewInRestore: reviewStatusInRestore, handoffBlocked: busy || syntheticRestore"))
        precondition(production.contains("Replace Current Rebuild Session?") && production.contains("Use Selected Environment"))
        precondition(production.contains("restore.choose(bundle)") && production.contains("if restore.source == bundle { task = .restore; return }"))


        let app = try! String(contentsOf: sources.appendingPathComponent("MacseedApp.swift"), encoding: .utf8)
            + String(contentsOf: sources.appendingPathComponent("FoundationSettings.swift"), encoding: .utf8)
        let captureView = try! String(contentsOf: sources.appendingPathComponent("CaptureView.swift"), encoding: .utf8)
        precondition(!captureView.contains("Capture does not rebuild or change settings on this Mac."))
        captureConfirmationPrivacyChecks(captureView)
        precondition(captureView.contains("No completed publication was reported.") && captureView.contains("Publication could not be confirmed."))
        precondition(captureView.contains("failure.isOutdatedPreparation") && captureView.contains("Text(failure.presentationTitle)"))

        let progressStart = captureView.range(of: "            case .scanning:")!
        let progressEnd = captureView.range(of: "            case .review:")!
        let progress = String(captureView[progressStart.upperBound..<progressEnd.lowerBound])
        precondition(!progress.contains("OperationSummaryHeader") && !progress.contains("TaskDomainList") && captureView.contains("Button(\"Cancel\", role: .cancel) { model.cancel() }"))
        precondition(!progress.contains("capture_category") && !progress.contains("categories checked"))
        let scan = String(progress.prefix(upTo: progress.range(of: "            case .preparing:")!.lowerBound))
        precondition(scan.contains("ProgressView()") && scan.contains("Text(progressText)") && !scan.contains("OperationSummaryHeader"))
        let checkingStart = progress.range(of: "            case .preparing:")!
        let checkingEnd = progress.range(of: "            case .saving:")!
        let checking = String(progress[checkingStart.upperBound..<checkingEnd.lowerBound])
        precondition(checking.contains("Checking Your Environment") && checking.contains("ProgressView()") && checking.contains("Text(progressText)"))
        precondition(!checking.contains("OperationSummaryHeader") && !checking.contains("selectionSummary"))
        let saving = String(progress[checkingEnd.upperBound...])
        precondition(saving.contains("Saving Your Environment") && saving.contains("ProgressView()") && !saving.contains("selectionSummary"))
        precondition(captureView.contains("Rechecking selected environment…"))


        precondition(captureView.contains("case \"validation\": return \"Checking selected environment…\""))
        let restoreView = try! String(contentsOf: sources.appendingPathComponent("RestoreView.swift"), encoding: .utf8)
        let restoreModel = try! String(contentsOf: sources.appendingPathComponent("RestoreModel.swift"), encoding: .utf8)
        precondition(restoreView.contains("NSOpenPanel()") && restoreView.contains("panel.canChooseDirectories = false"))
        precondition(restoreView.contains("canRebuild: model.canRebuild") && restoreView.contains(".disabled(!canRebuild || rebuild == nil)") && restoreView.contains("model.confirmRebuild()"))
        precondition(restoreView.contains("await model.checkPrerequisites()") && restoreView.contains("\"Fix Issues…\"") && restoreView.contains("checkAgain?()"))
        precondition(restoreView.contains("needsRefresh || retrying"))
        precondition(restoreView.contains(".disclosureGroupStyle(TaskDisclosureStyle())") && restoreView.contains("CaptureChildRowGrid.leadingInset"))
        let sections = RestorePresentationSection.project([])
        precondition(sections.map(\.id) == ["Applications & Tools", "Settings", "Git", "SSH Configuration", "Workspace", "Shell"])
        let aggregateSource = String(restoreView.components(separatedBy: "struct RestoreMacOSSelectionView:")[1].components(separatedBy: "struct RestoreMacOSAreaDetails:")[0])
        precondition(aggregateSource.contains("DisclosureGroup") && aggregateSource.contains("ForEach(detailAreas)") && !aggregateSource.contains("model.selectItem"))
        precondition(aggregateSource.contains("CaptureMacOSSettingsGroup.domainIDs.compactMap") && aggregateSource.contains("group.domains.contains($0.id)")
                     && aggregateSource.contains("$0.sourcePresent != false") && aggregateSource.contains("$0.captureSelected != false"))
        precondition(aggregateSource.contains("model.selectArea(area.id") && aggregateSource.contains("RestoreMacOSAreaDetails(area: area"))
        precondition(aggregateSource.contains("model.selectGroup(group") && aggregateSource.contains("Included"))
        precondition(restoreView.contains("CaptureGroupedContent(rows: areas"))
        precondition(restoreView.contains("showsSelectionActions") && restoreView.contains("if showsSelectionActions"))
        precondition(restoreView.components(separatedBy: "Button(\"Preview Rebuild\"").count == 2)
        precondition(workspaceSource.contains("showsSelectionActions: false"))
        precondition(workspaceSource.contains("else if restore.state == .review { selectionActionArea }"))
        precondition(workspaceSource.range(of: "else if restore.state == .review { selectionActionArea }")!.lowerBound
            > workspaceSource.range(of: ".modifier(WorkspaceContentGeometry())")!.lowerBound,
            "Selection actions must be placed after the workflow content viewport")
        precondition(restoreView.contains("Preparing Rebuild Preview") && restoreView.contains("Stopping Preview…"))
        precondition(restoreView.contains("Read-only inspection — no changes will be made to this Mac."))
        let stopConfirmation = restoreView.components(separatedBy: ".sheet(isPresented: Binding(get: { model.stopConfirmation")[1]
            .components(separatedBy: "private func chooseBundle()")[0]
        precondition(stopConfirmation.contains("Button(model.forceStopConfirmation ? \"Continue Waiting\" : \"Continue Rebuild\") { model.dismissStopConfirmation() }.keyboardShortcut(.defaultAction)"))
        precondition(restoreView.contains(".onExitCommand { model.dismissStopConfirmation() }"))
        precondition(restoreView.contains("Button(\"Change…\", action: chooseBundle).disabled(model.busy || runtime.isActive)"))
        for width in [400, 1000] {
            let renderer = ImageRenderer(content: RestoreSelectionActions(status: "Some items excluded", canPreview: false, preview: {})
                .padding(28).frame(width: CGFloat(width)))
            precondition(renderer.nsImage != nil)
        }
        print("PASS: Selection footer narrow/wide, single Preview action, honest preparation and safe Stop confirmation bindings")

        precondition(RestoreRowIcon.symbol(for: "vscode-settings") == "slider.horizontal.3")
        precondition(aggregateSource.contains("WorkspaceCategoryTitle(id: \"macos-settings\","))
        precondition(restoreView.contains("SelectionCategoryTitle(id: area.id, title: DeveloperSelectionGroup.title(area.id, fallback: area.label)")
            && restoreView.contains("symbol: RestoreRowIcon.symbol(for: area.id), flow: .rebuild"))
        precondition(restoreView.contains("RestoreSelectionPresentation.ordered(model.selectionAreas)")
            && restoreView.contains("CaptureGroupedContent(rows: areas, expanded: treeExpansion,"))
        func luminance(_ color: NSColor) -> Double {
            let rgb = color.usingColorSpace(.sRGB)!
            func linear(_ value: CGFloat) -> Double {
                let v = Double(value)
                return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
        }
        for name in [NSAppearance.Name.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua] {
            NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
                let success = luminance(RestoreStatusTone.successColor)
                let background = luminance(NSColor.windowBackgroundColor)
                let contrast = (max(success, background) + 0.05) / (min(success, background) + 0.05)
                precondition(contrast >= 4.5, "Success text contrast in \(name.rawValue): \(contrast)")
            }
        }
        print("PASS: Restore success text contrast in Light/Dark and increased-contrast appearances")
        precondition(RestoreStatusTone.status(.matching) == .success)
        precondition(RestoreStatusTone.domain("Already Matches") == .success)
        precondition(RestoreStatusTone.prerequisite("satisfied") == .success)
        precondition(RestoreStatusTone.domain("Needs Attention") == .warning)
        precondition(RestoreStatusTone.domain("Error") == .error)
        precondition(RestoreStatusTone.domain("Changes Planned") == .neutral)
        precondition(RestoreStatusTone.status(.unsupported) != .success && RestoreStatusTone.status(.unverified) != .success)
        precondition(restoreView.contains("Text(item.title).foregroundStyle(.primary)") && restoreView.contains("Text(label).foregroundStyle(.primary)"))
        precondition(restoreView.contains("Label(item.status.rawValue, systemImage: item.status.symbol)"))
        precondition(restoreView.contains("if item.status == .matching || item.status == .ready {"))
        precondition(restoreView.contains("Text(item.status == .matching ? \"OK\" : item.restoreReadyText"))
        precondition(restoreView.contains("NSColor.systemGreen") && restoreView.contains("appearance.performAsCurrentDrawingAppearance") && restoreView.contains(".darkAqua"))
        precondition(restoreView.contains("Text(item.action).font(.callout).foregroundStyle(.secondary)"))
        let prerequisiteSource = String(restoreView.components(separatedBy: "struct RestorePrerequisiteView")[1].components(separatedBy: "struct RestoreView:")[0])
        precondition(!prerequisiteSource.contains("checkmark.circle"))
        let progressSource = String(restoreView.components(separatedBy: "case .rebuilding:")[1].components(separatedBy: "case .result:")[0])
        precondition(progressSource.contains("RestoreRebuildProgressContent(tasks:"))
        precondition(progressSource.contains("events: model.categoryPresentationEvents, executing: true, operationProgress: true"))
        precondition(restoreView.contains("RestoreResultContent(result:"))
        precondition(!restoreView.contains("result.details.filter"))
        precondition(prerequisiteSource.contains("case \"satisfied\": \"Ready\""))
        precondition(!prerequisiteSource.contains("This prerequisite is available for the selected plan."))
        precondition(prerequisiteSource.contains("if condition.status != \"satisfied\" {\n                Text(message)"))
        precondition(!prerequisiteSource.contains("DisclosureGroup(technicalTitle)") && !prerequisiteSource.contains("Text(condition.code)"))
        precondition(RestoreRowGrid.titleInset == RestoreRowGrid.checkboxWidth + RestoreRowGrid.disclosureWidth + RestoreRowGrid.iconWidth + RestoreRowGrid.spacing * 3)
        precondition(restoreView.contains(".disclosureGroupStyle(TaskDisclosureStyle())"))
        precondition(content.contains(".frame(width: TaskRowLayout.iconWidth)") && restoreView.contains("WorkspaceCategoryIcon(symbol: symbol)"))
        precondition(restoreView.contains("ItemDetails(items: notices).padding(.leading, RestoreRowGrid.titleInset + hierarchyIndent)"))
        secureRestoreAvailabilityChecks(restoreView)
        // Views may reference the operation type for logs, but only the model
        // constructs Execute requests and starts the Core operation.
        precondition(!restoreView.contains(".restoreExecute(") && !restoreView.contains("runtime.start("))
        let confirmRebuild = restoreModel.components(separatedBy: "func confirmRebuild()")[1]
            .components(separatedBy: "func requestStop()")[0]
        let executePattern = #"CoreRequest\s*\(\s*\.restoreExecute\s*\(\s*path\s*:\s*source\.path\s*,\s*disabledGroups\s*:\s*\[\s*\]\s*,"#
            + #"\s*includeSecure\s*:\s*includeSecure\s*,\s*preparedID\s*:\s*plan\.preparedPlanID\s*,"#
            + #"\s*selection\s*:\s*selection\s*,\s*secureComparison\s*:\s*plan\.secureComparison\s*\)\s*,\s*restoreDestinations\s*:\s*privateDestinations\s*,"#
            + #"\s*sshApprovals\s*:\s*privateSSHApprovals\s*\)"#
        precondition(restoreView.contains("model.confirmRebuild()")
            && confirmRebuild.range(of: executePattern, options: .regularExpression) != nil
            && confirmRebuild.contains("runtime.start(request, location: location)"),
            "Confirmed Rebuild must dispatch the selected scope, prepared secure comparison and explicit SSH approvals through the model")
        let executeGuard = confirmRebuild.components(separatedBy: "let request =")[0].filter { !$0.isWhitespace }
        precondition(executeGuard.contains("guardstate==.confirming,!runtime.isActive")
            && executeGuard.contains("plan.selection==canonicalSelection,plan.includeSecure==includeSecure")
            && executeGuard.contains("plan.sshDependenciesReady")
            && executeGuard.contains("!includeSecure||plan.secureComparedReadyelse{return}"),
            "Execute must reject a busy runtime, stale selection, unresolved SSH dependencies or unready selected Secure Transfer")
        let defaultRestoreRuntime = CoreRuntime()
        let defaultRestore = RestoreModel(runtime: defaultRestoreRuntime)
        precondition(!defaultRestore.includeSecure, "Secure Transfer must remain off by default")
        defaultRestore.selectSecureTransfer(true)
        precondition(!defaultRestore.includeSecure && defaultRestoreRuntime.state == .idle,
            "Secure Transfer cannot be enabled before reviewing an inspected secure bundle")
        print("PASS: Model-owned Execute, default-off Secure Transfer, explicit selection and prepared comparison guards")
        precondition(!restoreModel.contains("areas selected ·") && !restoreModel.contains("items selected"))
        precondition(restoreModel.contains("Everything selected") && restoreModel.contains("Some items excluded") && restoreModel.contains("Nothing selected"))
        precondition(restoreView.contains("RestoreSelectionActions(status: model.selectionSummary, canPreview: model.canPreview"))
        precondition(restoreView.contains(".disabled(!canPreview)"))
        precondition(restoreView.contains("TaskDomainList(domains: visibleDomains.map"))
        // Keep the callback check bound to this initializer while allowing formatting changes.
        let prerequisiteSummaryPattern = #"RestorePrerequisiteSummaryView\s*\(\s*summary\s*:\s*prerequisites\s*,\s*areas\s*:\s*areas\s*,"#
            + #"\s*homebrewRecheck\s*:\s*reviewModel\s*\.\s*map\s*\{\s*model\s+in\s*\{"#
            + #"\s*model\s*\.\s*refreshPreview\s*\(\s*\)\s*\}\s*\}\s*,\s*showsHeading\s*:\s*false\s*\)"#
        precondition(restoreView.range(of: prerequisiteSummaryPattern, options: .regularExpression) != nil,
                     "Preview prerequisites must retain their summary/areas and recheck Homebrew through model.refreshPreview()")
        precondition(restoreView.contains("var showsFixIssues: Bool { prerequisites.canFixIssues }"))
        precondition(restoreView.contains("if showsFixIssues {") && !restoreView.contains("prerequisites.blockers"))
        let taskSource = try! String(contentsOf: sources.appendingPathComponent("TaskComponents.swift"), encoding: .utf8)
        precondition(taskSource.contains("private var expanded = []") && taskSource.contains("ForEach(hideMatchingPreviewItems ? RestorePreviewVisibility.items(domain.items) : domain.items)"))
        let previewContent = restoreView.components(separatedBy: "struct RestorePreviewContent: View")[1]
        let previewBody = previewContent.components(separatedBy: "private var previewHeading:")[0]
        let leadingContent = previewContent.components(separatedBy: "private var listLeadingContent:")[1]
            .components(separatedBy: "struct RestorePreparationActions:")[0]
        precondition(previewBody.contains("TaskDomainList(domains: visibleDomains.map")
            && previewBody.contains("leadingContent: listLeadingContent")
            && leadingContent.range(of: "prerequisiteDetails")!.lowerBound < leadingContent.range(of: "Manual Installation")!.lowerBound
            && !leadingContent.contains("pinnedList"),
            "Both viewport modes keep prerequisites before manual and automatic tasks inside the scrolling list")
        precondition(restoreView.contains("Rebuild this Mac?") && restoreView.contains("Stop rebuilding?") && restoreView.contains("Stopping it may leave some changes already applied to this Mac."))
        precondition(restoreView.contains("model.confirmStop()") && restoreView.contains("model.checkCurrentState()"))
        precondition(restoreModel.contains("plan.preparedPlanID, selection: selection") && restoreModel.contains("invalidate(); state = .result"))
        precondition(!restoreView.contains("Button(\"Resume\")") && !restoreView.contains("ProgressView(value:"))
        precondition(!restoreModel.contains("CaptureCategory.title") && !restoreModel.contains("RestoreSelection.groups"))
        precondition(restoreModel.contains("supportsRestoreSelection") && restoreModel.contains("selection: selection"))
        let confirmationStart = captureView.range(of: "            case .confirmation:")!
        let confirmationEnd = captureView.range(of: "            case .result:")!
        let confirmation = String(captureView[confirmationStart.upperBound..<confirmationEnd.lowerBound])
        precondition(!confirmation.contains("prepared.summary.selectedDomains") && !confirmation.contains("prepared.summary.selectedItems"))
        precondition(confirmation.contains("model.confirmationWarnings") && confirmation.contains("TaskDomainList("))
        precondition(confirmation.contains("CaptureBundleLocationView") && confirmation.contains("phase: .confirmation"))
        precondition(!confirmation.contains("NativeSelectionCheckbox") && !confirmation.contains("source_partial"))
        precondition(captureView.contains("model.editSelection()") && captureView.contains("model.create()"))
        let capturePresentation = try! String(contentsOf: sources.appendingPathComponent("CapturePresentation.swift"), encoding: .utf8)
        precondition(!capturePresentation.contains("Technical Details") && capturePresentation.contains("TaskDisclosureStyle()"))
        let confirmationItems = capturePresentation.components(separatedBy: "struct CaptureConfirmationItems: View")[1]
        precondition(!confirmationItems.contains("Text(\"Needs Attention\")") && !confirmationItems.contains("? domain.title"))
        precondition(confirmationItems.contains("item.captureRole != .categoryWarning") && !confirmationItems.contains("Technical Details"))

        precondition(capturePresentation.contains("model.selectItem(category.id") && capturePresentation.contains("model.selectCategory(category.id"))
        let workspace = try! String(contentsOf: sources.appendingPathComponent("ProductionWorkspace.swift"), encoding: .utf8)
        let captureViewPattern = #"CaptureView\s*\(\s*model\s*:\s*capture\s*,\s*runtime\s*:\s*runtime\s*,\s*showsActions\s*:\s*false\s*,"#
            + #"\s*experiencedVisibility\s*:\s*\$captureExperiencedVisible\s*\)"#
        precondition(workspace.range(of: captureViewPattern, options: .regularExpression) != nil,
            "Workspace owns Capture actions and preserves the experienced section disclosure binding")
        precondition(workspace.range(of: "CaptureActionsView(model:")!.lowerBound > workspace.range(of: ".modifier(WorkspaceContentGeometry())")!.lowerBound)
        precondition(!captureView.contains("individual items") && captureView.contains("panel.nameFieldStringValue = \"Saved Environment\""))
        let reviewStart = captureView.range(of: "            case .review:")!
        let reviewEnd = captureView.range(of: "            case .confirmation:")!
        let captureReview = String(captureView[reviewStart.upperBound..<reviewEnd.lowerBound])
        precondition(!confirmation.contains("CaptureReviewMetrics") && confirmation.contains("compactReadyItems: true") && confirmation.contains("Included in this capture"))
        precondition(!confirmation.contains("OperationSummaryHeader") && !confirmation.contains("scopeSummary"))
        let capturedResultEnd = captureView.range(of: "            case .failed, .cancelled:")!
        let capturedResult = String(captureView[confirmationEnd.upperBound..<capturedResultEnd.lowerBound])
        precondition(capturedResult.contains("model.resultPresentation") && capturedResult.contains("CaptureResultContent(result: result)"))
        precondition(!capturedResult.contains("Captured Environment") && !capturedResult.contains("TaskDomainList"))
        precondition(!capturedResult.contains("OperationSummaryHeader") && !capturedResult.contains("Ready to Save"))


        precondition(captureReview.contains("CaptureReviewRow.project") && captureReview.contains("CaptureCategorySelectionView"))
        precondition(captureReview.contains("CaptureReviewMetrics(summary: selectionSummary)") && !captureReview.contains("attentionMessage(rows)") && captureReview.contains("Choose supported state to capture."))
        for removed in ["OperationSummaryHeader", "CaptureSectionSelectionView", "Ready to Capture", "Selected Domains", "Selected Items"] {
            precondition(!captureReview.contains(removed))
        }
        let groupStart = captureView.range(of: "struct CaptureMacOSSettingsView: View")!
        let groupEnd = captureView.range(of: "struct CaptureView: View")!
        let macOSGroup = String(captureView[groupStart.lowerBound..<groupEnd.lowerBound])
        precondition(macOSGroup.contains("treeExpansion: Binding<Set<String>>?"))
        precondition(macOSGroup.contains("CaptureSettingsSubcategoryView(model: model, category: category") && capturePresentation.contains(".frame(width: 28, height: 28)"))
        precondition(!macOSGroup.contains("NativeSelectionCheckbox") && !macOSGroup.contains("selectMacOSSettings"))
        precondition(!macOSGroup.contains("CategoryRow(") && !macOSGroup.contains("Included as a whole category"))
        precondition(macOSGroup.contains("CaptureSettingsSubcategoryView") && !macOSGroup.contains("DisclosureGroup("), "The shared accordion owns the macOS parent; children retain category selection and disclosure")
        precondition(CaptureChildRowGrid.leadingInset == 24 && CaptureChildRowGrid.titleInset == 20)
        precondition(content.contains(".padding(.leading, CaptureChildRowGrid.leadingInset).padding(.vertical, 8)"))
        precondition(macOSGroup.contains(".padding(.leading, 16 + (editable ? CaptureChildRowGrid.leadingInset : 0))"), "macOS areas share the selectable child checkbox column")
        precondition(capturePresentation.contains("accessibilityTitle: \"Select \" + category.title"))
        captureCompactSettingsChecks()
        precondition(macOSGroup.contains("Supported settings only") && capturePresentation.contains("category.row.includedSettings"))
        let metadataStart = captureView.range(of: "struct IncludedSettingsText: View")!
        let metadataView = String(captureView[metadataStart.lowerBound..<groupStart.lowerBound])
        precondition(metadataView.contains("SettingsFlowLayout") && metadataView.contains("Text(setting.label"))
        for control in ["Button(", "NativeSelectionCheckbox", ".truncationMode", ".lineLimit(", "Capsule", "+N more"] {
            precondition(!metadataView.contains(control), "Setting labels stay informational and complete")
        }
        let labelSizes = [CGSize(width: 80, height: 16), CGSize(width: 110, height: 16), CGSize(width: 65, height: 16), CGSize(width: 140, height: 16)]
        let wide = SettingsFlowLayout.frames(sizes: labelSizes, width: 600)
        let narrow = SettingsFlowLayout.frames(sizes: labelSizes, width: 180)
        precondition(wide.count == labelSizes.count && narrow.count == labelSizes.count)
        precondition(wide.allSatisfy { $0.minY == 0 } && narrow.last!.maxY > wide.last!.maxY)
        precondition(zip(narrow, labelSizes).allSatisfy { $0.size == $1 && $0.maxX <= 180 })
        precondition(SettingsFlowLayout.frames(sizes: labelSizes, width: 600) == wide, "Re-expansion restores layout without losing labels")
        print("PASS: Included settings are Core-supplied read-only labels; flow reflows by width without losing scope")
        print("PASS: macOS children use separate native checkbox/header targets and nested domain disclosures without individual setting selection")
        precondition(content.contains("struct WorkspaceHeader: View") && content.contains("struct InsetSidebarSurface: ViewModifier"))
        precondition(content.contains("MacseedHomeHero()") && content.contains("WorkspaceHeader(title: task.title"))
        precondition(production.contains("WorkspaceHeader(title: task.title"))
        precondition(content.contains(".modifier(InsetSidebarSurface())") && production.contains(".modifier(InsetSidebarSurface())"))
        precondition(!content.contains(".systemBlue") && !production.contains(".systemBlue"))
        precondition(app.contains(".pickerStyle(.segmented)") && !app.contains(".preferredColorScheme(") && !app.contains(".onChange(of: appearanceValue)"))
        operationLogChecks()
        print("PASS: Shared neutral material sidebar/header in production and preview; native Appearance setting")
        let categoryStart = content.range(of: "struct CategoryRow: View")!
        precondition(content[categoryStart.lowerBound...].contains("@ViewState<Bool> private var expanded = false"))
        precondition(statusView.contains("ForEach(Self.visibleSections(result)) { section in") && statusView.contains("EnvironmentComparisonDomain(category: entry.category, children: entry.children, technicalFacts: result.technicalFacts, counts: Dictionary("))
        let referenceRuntime = CoreRuntime()
        let referenceModel = EnvironmentStatusModel(runtime: referenceRuntime)
        let directory = URL(fileURLWithPath: "/private/tmp/presentation-saved-environment")
        let blueprint = URL(fileURLWithPath: "/private/tmp/presentation-blueprint.conf")
        referenceModel.selectReference(directory)
        precondition(try! referenceModel.reference!.command.parameters()!.object?["blueprint_path"] == .null)
        referenceModel.selectBlueprint(blueprint)
        precondition(try! referenceModel.reference!.command.parameters()!.object?["blueprint_path"] == .string(blueprint.path))
        referenceModel.selectBlueprint(nil)
        precondition(try! referenceModel.reference!.command.parameters()!.object?["blueprint_path"] == .null)
        precondition(referenceModel.reference?.generatedDirectory == directory && referenceRuntime.state == .idle)
        print("PASS: Product reference wording, concise workflow explanations, collapsed categories and optional Blueprint semantics")
        #endif
    }

    @MainActor static func sampleInteractionChecks() {
        #if DEBUG
        if CommandLine.arguments.contains("--native-controls") {
            _ = NSApplication.shared
            let previousAppearance = NSApp.appearance
            let main = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
            let settings = NSWindow(contentRect: main.frame, styleMask: [.titled], backing: .buffered, defer: false)
            let sheet = NSPanel(contentRect: main.frame, styleMask: [.titled], backing: .buffered, defer: false)
            let windows = [main, settings, sheet]
            var schemes: [Int: ColorScheme] = [:]
            for (index, window) in windows.enumerated() {
                window.isReleasedWhenClosed = false
                window.contentView = NSHostingView(rootView: AppearanceProbe { schemes[index] = $0 })
                window.orderFront(nil)
            }
            main.beginSheet(sheet)
            for from in DesktopAppearance.allCases {
                for to in DesktopAppearance.allCases {
                    from.apply(to: NSApp)
                    // A window override must not survive the app preference.
                    settings.appearance = NSAppearance(named: .darkAqua)
                    to.apply(to: NSApp)
                    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                    precondition(NSApp.appearance?.name == to.appearanceName)
                    let active = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
                    for (index, window) in windows.enumerated() {
                        precondition(window.appearance == nil)
                        precondition(window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == active)
                        precondition(window.contentView!.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == active)
                        precondition(schemes[index] == (active == .darkAqua ? .dark : .light), "SwiftUI inherits app appearance after every transition")
                    }
                }
            }
            main.endSheet(sheet)
            for window in windows { window.close() }
            NSApp.appearance = previousAppearance
            print("PASS: Every Appearance transition updates main/Settings/sheet and SwiftUI coherently; System removes overrides")
            for state in [SelectionState.none, .mixed, .all] {
                var selected: Bool?
                let control = NativeSelectionCheckbox("Include Applications", state: state,
                                                      setIncluded: { selected = $0 })
                let coordinator = control.makeCoordinator()
                let button = control.makeButton(coordinator: coordinator)
                button.frame = NSRect(x: 0, y: 0, width: 220, height: 28)
                precondition(button.allowsMixedState)
                precondition(button.state == (state == .mixed ? .mixed : (state == .all ? .on : .off)))
                precondition(button.hitTest(NSPoint(x: 8, y: 14)) != nil, "Checkbox hit area")
                precondition(button.hitTest(NSPoint(x: 100, y: 14)) != nil, "Associated label hit area")
                precondition(button.hitTest(NSPoint(x: 230, y: 14)) == nil, "No spill into sibling disclosure")
                button.performClick(nil)
                precondition(selected == (state != .all), "Native action: mixed/none -> all, all -> none")
            }
            let compact = NativeSelectionCheckbox("", state: .mixed, accessibilityTitle: "Select Applications", setIncluded: { _ in })
            let coordinator = compact.makeCoordinator()
            let button = compact.makeButton(coordinator: coordinator)
            button.frame = NSRect(x: 0, y: 0, width: 28, height: 28)
            precondition(button.title.isEmpty && button.accessibilityLabel() == "Select Applications")
            precondition(button.hitTest(NSPoint(x: 8, y: 14)) != nil)
            precondition(button.hitTest(NSPoint(x: 24, y: 14)) != nil)
            precondition(button.hitTest(NSPoint(x: 32, y: 14)) == nil)
            print("PASS: Native checkbox all/none/mixed actions and separate checkbox/label bounds")
            return
        }
        precondition(SampleProvider.capture == SampleProvider.capture)
        precondition(SampleProvider.restore("A") == SampleProvider.restore("A"))
        precondition(SampleProvider.progress.count == 3)
        let bulk = DemoSession()
        bulk.load(.captureReview)
        let total = bulk.selectedCaptureItemCount
        precondition(bulk.captureBulkState.bulkActionTitle == "Deselect All")
        precondition(bulk.secureBulkState.bulkActionTitle == "Select All")
        bulk.selectIdentity(bulk.secureIdentityNames[0], included: true)
        precondition(bulk.secureBulkState == .mixed)
        let identities = bulk.identitySelection
        bulk.toggleAllCapture()
        precondition(bulk.captureSelection.isEmpty && bulk.selectedCaptureItemCount == 0)
        precondition(bulk.identitySelection == identities)
        precondition(bulk.captureBulkState.bulkActionTitle == "Select All")
        bulk.toggleAllCapture()
        precondition(bulk.selectedCaptureItemCount == total && bulk.identitySelection == identities)
        bulk.selectCaptureItem(bulk.captureCategories[0].items[0].id, included: false)
        precondition(bulk.captureBulkState == .mixed && bulk.captureBulkState.bulkActionTitle == "Select All")
        bulk.toggleAllCapture()
        precondition(bulk.selectedCaptureItemCount == total)
        bulk.toggleAllIdentities()
        precondition(bulk.identitySelection.count == bulk.secureIdentityNames.count)
        precondition(bulk.secureBulkState.bulkActionTitle == "Deselect All")
        bulk.toggleAllIdentities()
        precondition(bulk.identitySelection.isEmpty && bulk.selectedCaptureItemCount == total)
        bulk.load(.prerequisite)
        precondition(bulk.restoreCategories.first { $0.id == "Homebrew" }!.hasAttention)
        precondition(bulk.restoreCategories.first { $0.id == "Workspace" }!.hasAttention)
        precondition(!bulk.restoreCategories.first { $0.id == "Applications" }!.hasAttention)
        precondition(bulk.restoreBulkState.bulkActionTitle == "Deselect All")
        let revision = bulk.revision
        bulk.toggleAllRestore()
        precondition(bulk.restoreSelection.isEmpty && !bulk.canRebuild && !bulk.needsHomebrew)
        precondition(bulk.revision > revision && bulk.confirmedRevision == nil)
        bulk.toggleAllRestore()
        precondition(bulk.restoreSelection.count == bulk.restoreCategories.count && bulk.needsHomebrew)
        bulk.selectRestore("Workspace", included: false)
        precondition(bulk.restoreBulkState == .mixed && bulk.restoreBulkState.bulkActionTitle == "Select All")
        bulk.toggleAllRestore()
        precondition(bulk.restoreBulkState == .all)
        bulk.checkAgain()
        precondition(!bulk.restoreCategories.first { $0.id == "Homebrew" }!.hasAttention)
        bulk.rebuild()
        let activeSelection = bulk.restoreSelection
        bulk.toggleAllRestore()
        precondition(bulk.restoreSelection == activeSelection)
        precondition(!SampleProvider.status[0].hasAttention)
        precondition(SampleProvider.status[1].hasAttention && SampleProvider.status[2].hasAttention)
        precondition(!SampleProvider.completion(selection: ["Git"]).detailsInitiallyExpanded)
        print("PASS: Independent bulk actions, mixed labels/counts, Restore guards and collapsed-header attention")

        let captureAfterRestore = DemoSession()
        captureAfterRestore.load(.prerequisite)
        precondition(captureAfterRestore.needsHomebrew)
        captureAfterRestore.navigate(.capture)
        captureAfterRestore.scan()
        captureAfterRestore.finishScan()
        precondition(captureAfterRestore.captureSelection.contains("homebrew"))
        precondition(captureAfterRestore.canCreate, "Restore prerequisite must not block Capture")
        let selectedItems = captureAfterRestore.selectedCaptureItemCount
        let selectedCategories = captureAfterRestore.captureSelection.count
        captureAfterRestore.createCapture()
        precondition(captureAfterRestore.captureState == .result)
        precondition(captureAfterRestore.selectedCaptureItemCount == selectedItems)
        precondition(captureAfterRestore.captureSelection.count == selectedCategories)
        precondition(captureAfterRestore.identitySelection.isEmpty)
        print("PASS: Capture after blocked Restore has no Homebrew prerequisite; result selection counts preserved")

        let model = DemoSession()
        model.navigate(.capture)
        model.scan()
        model.navigate(.restore)
        precondition(model.task == .capture, "Busy operation cannot be detached")
        precondition(!model.canGoBack)
        model.goBack()
        precondition(model.captureState == .scanning)
        model.finishScan()
        let apps = SampleProvider.capture[0]
        precondition(model.captureSelectionState(apps) == .all)
        let count = model.selectedCaptureItemCount
        model.selectCaptureItem(apps.items[0].id, included: false)
        precondition(model.captureSelectionState(apps) == .mixed)
        precondition(model.selectedCaptureItemCount == count - 1)
        precondition(model.captureSelection.contains(apps.id))
        model.selectCapture(apps.id, included: false)
        precondition(model.captureSelectionState(apps) == .none)
        precondition(!model.captureSelection.contains(apps.id))
        model.selectCapture(apps.id, included: true)
        precondition(model.captureSelectionState(apps) == .all)
        precondition(model.selectedCaptureItemCount == count)
        model.selectCaptureItem("unknown", included: true)
        precondition(model.selectedCaptureItemCount == count)
        for category in model.captureCategories {
            model.selectCaptureItem(category.items[0].id, included: false)
            precondition(model.captureSelectionState(category) == (category.items.count == 1 ? .none : .mixed))
            precondition(model.selectedCaptureItemCount == count - 1)
            model.selectCapture(category.id, included: true)
            precondition(model.captureSelectionState(category) == .all)
            precondition(model.selectedCaptureItemCount == count)
        }
        for category in SampleProvider.capture { model.selectCapture(category.id, included: false) }
        precondition(!model.canCreate)
        model.createCapture()
        precondition(model.captureState == .review)
        model.selectIdentity(SampleProvider.identities[0], included: true)
        model.createCapture()
        precondition(model.secureSheet)
        precondition(!model.canGoBack)
        model.goBack()
        precondition(model.captureState == .review && model.secureSheet)
        model.completeSecureDemo()
        precondition(model.captureState == .result && !model.secureSheet)
        print("PASS: Capture selection, busy navigation and secure transition")

        model.navigate(.restore)
        model.chooseBundle("A")
        precondition(model.needsHomebrew && !model.canRebuild)
        model.rebuild()
        precondition(model.restoreState == .review)
        model.selectRestore("Homebrew", included: false)
        precondition(model.canRebuild, "Unselected group must not block Rebuild")
        model.selectRestore("Homebrew", included: true)
        model.checkAgain()
        model.rebuild()
        precondition(!model.canGoBack)
        model.goBack()
        precondition(model.restoreState == .rebuilding)
        let oldRevision = model.confirmedRevision
        model.chooseBundle("B")
        precondition(model.bundle == "A", "Cannot change Bundle during Rebuild")
        model.nextEvent()
        model.stop()
        precondition(model.restoreState == .stopped && model.confirmedRevision == nil)
        precondition(model.result?.readyCount == nil, "Partial work must not invent verification")
        precondition(model.result?.details.first { $0.id == "remaining" }?.action == "Refresh Preview")
        model.chooseBundle("B")
        precondition(model.previousStoppedBundle == "A")
        precondition(model.bundle == "B" && model.revision != oldRevision)
        precondition(model.confirmedRevision == nil && model.result == nil && model.progressIndex == 0)
        precondition(model.needsHomebrew, "New Bundle gets fresh prerequisite state")
        model.checkAgain()
        model.selectRestore("Workspace", included: false)
        model.rebuild()
        model.nextEvent(); model.nextEvent(); model.nextEvent()
        precondition(model.restoreState == .result && model.result?.attentionCount == 0)
        precondition(model.result?.readyCount == model.restoreSelection.count)
        precondition(SampleProvider.completion(selection: ["Git"]).readyCount == 1)
        print("PASS: Prerequisites, Stop Rebuild and A-to-B fresh operation")

        for preset in DemoPreset.allCases {
            let first = DemoSession()
            let second = DemoSession()
            first.load(preset); second.load(preset)
            precondition(first.task == second.task && first.captureState == second.captureState)
            precondition(first.restoreState == second.restoreState && first.result == second.result)
            precondition(first.captureSelection == second.captureSelection)
            precondition(first.captureItemSelection == second.captureItemSelection)
            precondition(first.identitySelection == second.identitySelection)
            precondition(first.restoreSelection == second.restoreSelection)
        }
        model.load(.success)
        precondition(model.result?.detailsInitiallyExpanded == false)
        precondition(model.result?.attentionDetails.isEmpty == true)
        model.goBack()
        precondition(model.restoreState == .review && model.confirmedRevision == nil)
        model.goBack()
        precondition(model.restoreState == .choose)
        model.goBack()
        precondition(model.task == nil)
        model.load(.captureSuccess)
        model.goBack()
        precondition(model.captureState == .review)
        model.goBack()
        precondition(model.captureState == .idle)
        model.goBack()
        precondition(model.task == nil)
        model.load(.attention)
        precondition(model.result?.attentionCount == 1)
        precondition(model.result?.attentionDetails.count == 1)
        model.load(.differences)
        precondition(model.statusState == .result)
        model.goBack()
        precondition(model.statusState == .choose)
        model.goBack()
        precondition(model.task == nil)
        print("PASS: Parent all/none/mixed, child counts, Back guards and Result disclosure")
        precondition(Set(SampleProvider.restore("A").map(\.id)) == Set([
            "Applications", "VS Code Settings", "Homebrew", "macOS Settings", "Shell", "Git", "SSH Configuration", "Workspace"
        ]))
        print("PASS: All presets deterministic, Status and Protocol-compatible group selection")
        #else
        precondition(!BuildFeatures.sampleExperience)
        print("PASS: Release has no sample experience")
        #endif
    }
}

private struct AppearanceProbe: View {
    @Environment(\.colorScheme) private var scheme
    let changed: (ColorScheme) -> Void
    var body: some View {
        Text("Appearance test")
            .onChange(of: scheme, initial: true) { _, value in changed(value) }
    }
}
