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

private struct WorkflowAnchorFrames: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

@main struct PresentationTests {
    @MainActor static func sidebarLayoutChecks() {
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
        func settle(_ window: NSWindow, duration: TimeInterval = 0.08) {
            window.contentView?.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: duration))
            window.contentView?.layoutSubtreeIfNeeded()
        }
        func detailWidth(_ split: NSSplitViewController) -> CGFloat {
            let detail = split.splitViewItems.last!.viewController.view
            // On macOS 26 the native floating sidebar occupies a safe-area inset
            // rather than reducing the full-bleed detail view's frame.
            return detail.bounds.width - detail.safeAreaInsets.left - detail.safeAreaInsets.right
        }
        func check<V: View>(_ view: V, name: String, tasks: [ProductTask?], navigate: (ProductTask?, NSView) -> Void) {
            let host = NSHostingController(rootView: view.frame(minWidth: MainWindowPolicy.minimum.width,
                                                               minHeight: MainWindowPolicy.minimum.height))
            host.sizingOptions = []
            let window = NSWindow(contentViewController: host)
            window.isReleasedWhenClosed = false
            MainWindowPolicy.apply(to: window)
            window.setContentSize(NSSize(width: 1600, height: 800))
            window.orderFront(nil)
            defer { window.close() }
            settle(window)
            guard let split = splitController(in: host.view), let sidebar = split.splitViewItems.first else {
                preconditionFailure("Missing native sidebar in \(name)")
            }
            for task in tasks {
                navigate(task, host.view)
                for width in [1600.0, 1200, 1000, 1200, 1600, 1000] {
                    window.setContentSize(NSSize(width: width, height: 800))
                    settle(window)
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
                settle(window, duration: 0.4)
                precondition(sidebar.isCollapsed, "Existing sidebar toggle must hide the sidebar")
                precondition(detailWidth(split) > visibleDetailWidth + 200,
                    "Hidden sidebar must release its width to detail: \(name), \(String(describing: task)), "
                    + "before=\(visibleDetailWidth), bounds=\(visibleBounds), insets=\(visibleInsets), "
                    + "after=\(detailWidth(split)), bounds=\(split.splitViewItems.last!.viewController.view.bounds), "
                    + "insets=\(split.splitViewItems.last!.viewController.view.safeAreaInsets)")
                for width in [1600.0, 1200, 1000] {
                    window.setContentSize(NSSize(width: width, height: 800))
                    settle(window)
                    precondition(sidebar.isCollapsed, "Resize must preserve explicit hidden state")
                }
                split.toggleSidebar(nil)
                settle(window, duration: 0.4)
                precondition(!sidebar.isCollapsed && abs(sidebar.viewController.view.frame.width - 215) < 1,
                             "Existing toggle must restore the normal sidebar width")
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
        check(DemoWorkspace(session: session), name: "preview", tasks: tasks) { task, _ in session.navigate(task) }
        #endif
        // No Core launch or local operation-log writes in this native layout fixture.
        let runtime = CoreRuntime(resolver: CoreLocationResolver(resources: nil), operationLogs: nil)
        check(ProductionWorkspace(runtime: runtime), name: "production", tasks: tasks) { task, view in
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
        precondition(result.contains("saved.destination), showsReveal: true"))
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
        precondition(view.contains("TaskDomainList(domains: domains.map"))
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
        precondition(!components.contains("Technical Details") && components.contains("ForEach(domain.items)"))
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
                        Label("All Tasks", systemImage: "square.grid.2x2")
                        ForEach(ProductTask.allCases) { task in Label(task.rawValue, systemImage: task.symbol) }
                        Spacer()
                    }.padding(20).frame(width: 215).background(.regularMaterial)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            WorkspaceHeader(title: task.rawValue, subtitle: task.subtitle, symbol: task.symbol)
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

    @MainActor static func visualContractChecks() {
        let source = try! String(contentsOfFile: "Sources/ContentView.swift")
        let domains = WorkspaceCategoryStyle.groups.flatMap { $0.1 }.filter { $0 != "macOS Settings" }
        let rows = domains.map { DisplayCategory(id: $0, title: $0, symbol: "", items: []) }
        let sections = WorkspaceCategoryStyle.sections(rows.reversed())
        precondition(sections.map(\.title) == ["Applications & Tools", "Settings", "Git", "SSH Configuration", "Workspace", "Shell"])
        precondition(sections.first { $0.title == "Git" }!.rows.map(\.id) == ["git-configuration"])
        precondition(sections.first { $0.title == "Workspace" }!.rows.map(\.id) == ["workspace-folders", "git-repositories"])
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
        for path in ["CaptureView.swift", "RestoreView.swift", "TaskComponents.swift"] {
            let view = try! String(contentsOfFile: "Sources/" + path)
            precondition(view.contains("WorkspaceSectionHeader(") && view.contains("WorkspaceCardSurface()"))
        }
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
        precondition(restoreSource.contains("Discard Current Restore Selection?") && restoreSource.contains("Keep Selection") && restoreSource.contains("Discard and Cancel"))
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
        let sections = RestoreExecutionCategories.sections(rows)
        precondition(sections.compactMap(\.title) == ["Applications & Tools", "Settings", "Git", "SSH Configuration", "Workspace"])
        precondition(sections.last!.rows.map(\.id) == ["workspace-folders", "git-repositories"])
        precondition(Set(sections.flatMap(\.rows).map(\.id)) == Set(ids))
        precondition(sections.flatMap(\.rows).allSatisfy { $0.executionStatus == .unverified && $0.executionStatus.tone == .warning })
        for state in [TaskRowState.working, .completed, .attention, .unverified, .notRun, .failed] {
            let original = ids.map { domain($0, state: state) }
            let reordered = RestoreExecutionCategories.sections(original).flatMap(\.rows)
            for row in original {
                let after = reordered.first { $0.id == row.id }!
                precondition(after.executionStatus == row.executionStatus && after.executionMessages == row.executionMessages)
                precondition(after.items.map(\.id) == row.items.map(\.id) && after.items.first!.item.reason == row.items.first!.item.reason)
                precondition(WorkspaceCategoryStyle.symbol(row.id) == RestoreRowIcon.symbol(for: row.id))
            }
        }
        let unknown = domain("future-core-group", state: .unverified)
        let anchored = RestoreExecutionCategories.sections([rows[0], unknown, rows[1]])
        precondition(anchored.map { $0.rows.map(\.id) } == [[rows[0].id], [unknown.id], [rows[1].id]])
        precondition(anchored[1].title == nil && anchored[1].rows[0].title == unknown.title)
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
        print("PASS: Execution/Result section order and shared icon mapping; all rows, statuses, warning colors, diagnostics and unknown group anchors preserved; two native renders")
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
        precondition(source.contains("RestoreExecutionCategories(domains: tasks.automaticDomains, showsWarnings: false, resultStatuses: true,"))
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
        precondition(!source.contains("WorkspaceMetricCard(") && !source.contains("Automatic Restore outcomes"))
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
        precondition(result.contains("appStore: tasks.appStore, reviewAppStore: reviewAppStore)"))
        precondition(!result.contains("RestoreRequiresAttention") && !source.contains("Text(\"Requires Attention\")"))
        precondition(!result.contains("App Store Applications — All Installed"))
        precondition(result.contains("Text(Self.heading(outcome: result.outcome"))
        precondition(!source.contains("Global Verification includes automatic Restore"))
        precondition(!source.contains("Selected environment: "))
        precondition(!source.contains("This Preview includes attention conditions"))
        let preview = source.components(separatedBy: "struct RestorePreviewContent:")[1].components(separatedBy: "struct RestorePreparationActions:")[0]
        precondition(!preview.contains("let message:") && !preview.contains("let counters:"))
        precondition(!source.contains("message: preview.summary"))
        precondition(result.contains("Text(Self.message(result:") && result.contains("RestoreResultActions(result: result, refresh: refresh, done: done, logRuntime: logRuntime)"))
        let selection = source.components(separatedBy: "if model.state == .review {")[1].components(separatedBy: "} else if let prepared")[0]
        precondition(selection.contains("RestorePresentationSection.visible(model.groups, inventory: includedAreas)"))
        precondition(selection.contains("section.areas(in: includedAreas)") && !selection.contains("automaticAreas"))
        precondition(!selection.contains("if let appStore"), "App Store uses the shared group and row exactly once")
        precondition(preview.contains("WorkspaceSectionHeader(title: \"Manual Installation\", prominent: true)"))
        let taskComponents = try! String(contentsOfFile: "Sources/TaskComponents.swift")
        precondition(taskComponents.contains("WorkspaceSectionHeader(title: \"Automatic Restore Tasks\", prominent: true)"))
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
        let app = try! String(contentsOfFile: "Sources/MacseedApp.swift", encoding: .utf8)
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
        for (row, expected) in fixtures {
            precondition(row.resultGroup == expected && RestoreFinalDomain.group(row) == expected)
            let domain = TaskDomainPresentation(id: row.id, title: row.id, symbol: "folder", items: [row])
            let summary = RestoreResultSummary(domains: [domain, domain])
            precondition(summary.cards.count == (expected == nil ? 0 : 1))
            precondition(summary.cards.first?.count == (expected == nil ? nil : 1))
            precondition(summary.cards.first?.id == expected)
            precondition(RestoreFinalDomain.counts(domain).first?.0 == expected)
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
        precondition(RestoreFinalDomain.counts(partial).map(\.1) == [1])
        let partialStyle = RestoreResultStatusLabel(state: RestoreFinalDomain.finalStatus(partial), title: partial.resultTitle)
        precondition(partialStyle.tone == .neutral && partialStyle.symbol == "circle.lefthalf.filled")
        let unknownDomain = TaskDomainPresentation(id: "unknown", title: "", symbol: "", items: [unknown])
        let unknownStyle = RestoreResultStatusLabel(state: RestoreFinalDomain.finalStatus(unknownDomain), title: unknownDomain.resultTitle)
        precondition(unknownStyle.tone == .neutral && unknownStyle.symbol == "questionmark.circle")
        precondition(RestoreFinalDomain.visibleLabels(unknown) == ["Outcome Unknown"])
        let mixed = TaskDomainPresentation(id: "mixed", title: "", symbol: "", items: [applied, item("second-applied", ["Applied"], known: true), fixtures[6].0, unknown, item("second-unknown", ["Unverified"], state: .unverified, known: false)])
        precondition(mixed.resultTitle == "Needs Attention")
        precondition(RestoreResultSummary(domains: [mixed]).cards.map(\.count) == [2, 1])
        precondition(RestoreFinalDomain.counts(mixed).map(\.1) == [2, 1])
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

    @MainActor static func captureResultAlignmentChecks() {
        let ids = ["macos-finder", "macos-dock", "macos-windows", "macos-keyboard", "macos-trackpad", "macos-screenshots"]
        let children = ids.map { id in
            TaskDomainPresentation(id: id, title: CaptureCategory.title(for: id), symbol: WorkspaceCategoryStyle.symbol(id),
                items: [TaskItemPresentation(id: id + ":saved", item: DisplayItem(id: id + ":saved", title: id, status: .ready,
                    action: ""), state: .completed, captureRole: .selectedSubdomain)])
        }
        let parent = TaskDomainPresentation(id: "macos-settings", title: "macOS Settings", symbol: "gearshape", items: children.flatMap(\.items))
        let vscode = TaskDomainPresentation(id: "vscode-settings", title: "VS Code Settings", symbol: "curlybraces",
            items: [TaskItemPresentation(id: "vscode-settings:saved", item: DisplayItem(id: "vscode-settings:saved", title: "JSON", status: .ready,
                action: ""), state: .completed, captureRole: .configuration)])
        let source = try! String(contentsOfFile: "Sources/CaptureView.swift")
        let result = source.components(separatedBy: "            case .result:")[1].components(separatedBy: "            case .failed, .cancelled:")[0]
        precondition(result.contains("captureResultLayout: true"))
        let restore = try! String(contentsOfFile: "Sources/RestoreView.swift")
        precondition(!restore.contains("captureResultLayout: true"))
        for width in [420.0, 785.0, 985.0] {
            for typeSize in [DynamicTypeSize.large, .accessibility3] {
                let view = TaskDomainList(domains: [parent, vscode], compactReadyItems: true, captureResultLayout: true,
                    settingsCategories: children, settingLabels: ["macos-screenshots": ["Save location", "Window shadow", "Floating thumbnail"]],
                    expansion: .constant([parent.id]), settingsExpansion: .constant(false))
                    .padding(20).frame(width: width).environment(\.dynamicTypeSize, typeSize).environment(\.colorScheme, .light)
                let image = ImageRenderer(content: view).cgImage!
                var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
                pixels.withUnsafeMutableBytes { bytes in
                    let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                        bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                }
                var bands: [(y: Int, x: Int)] = []
                for y in 0..<image.height {
                    var left: Int? = nil
                    for x in 0..<image.width {
                        let offset = (y * image.width + x) * 4
                        let r = Int(pixels[offset]), g = Int(pixels[offset + 1]), b = Int(pixels[offset + 2])
                        if g > 60 && g > r * 13 / 10 && g > b * 12 / 10 && pixels[offset + 3] > 150 { left = x; break }
                    }
                    if let left {
                        if let last = bands.last, y - last.y <= 10 {
                            bands[bands.count - 1] = (y, min(left, last.x))
                        } else { bands.append((y, left)) }
                    }
                }
                precondition(bands.count == 8, "All eight Completed statuses must render: \(bands)")
                precondition(bands.map(\.x).max()! - bands.map(\.x).min()! <= 1,
                    "Parent, six settings children and VS Code statuses share a column: \(bands)")
            }
        }
        print("PASS: Capture Result's eight Completed statuses align at narrow/wide widths and increased Dynamic Type")
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
        func origin<V: View>(_ view: V, width: CGFloat) -> Int {
            let bitmap = NSBitmapImageRep(cgImage: ImageRenderer(content: view.frame(width: width).environment(\.restoreTrailingSamples, references)).cgImage!)
            for x in 0..<bitmap.pixelsWide {
                for y in 0..<bitmap.pixelsHigh {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.alphaComponent > 0.9 else { continue }
                    if color.greenComponent > 0.2 && color.greenComponent > color.redComponent * 1.3 && color.greenComponent > color.blueComponent * 1.2 { return x }
                }
            }
            preconditionFailure("Expected a green status")
        }
        let item = TaskItemPresentation(id: "row", item: DisplayItem(id: "row", title: "Item", status: .ready, action: ""),
            state: .completed, resultLabels: ["Verified"])
        let domain = TaskDomainPresentation(id: "fixture", title: "Category", symbol: "folder", items: [item])
        let app = TaskItemPresentation(id: "app", item: item.item, state: .matching,
            assistedAppStore: AssistedAppStoreItem(appID: "425264550", status: .installed))
        let summary = AppStoreRestorePresentation(domains: [.init(id: "app-store", title: "Apps", symbol: "app", items: [app])])
        let references = RestoreTrailingSample.result([domain], appStore: summary)
        for width: CGFloat in [420, 785, 985] {
            let positions = [
                origin(RestoreFinalDomain(domain: domain), width: width),
                origin(RestoreFinalDomain(domain: domain, depth: 1).padding(.horizontal, 16), width: width),
                origin(RestoreResultItemRow(item: item, notRun: false, depth: 0).padding(.horizontal, 16), width: width),
                origin(RestoreResultItemRow(item: item, notRun: false, depth: 1).padding(.horizontal, 16), width: width),
                origin(AppStoreRestoreResultRow(summary: summary, review: {}, expansion: .constant(false)), width: width)]
            precondition(positions.max()! - positions.min()! <= 3, "Category/nested/item/App Store status origins: \(positions)")
            let previewDomain = TaskDomainPresentation(id: "homebrew-casks", title: "Homebrew Applications", symbol: "app", items: [app])
            // Exercise the actual shared Preview list: its environment supplies
            // identical status/count measurements to manual and automatic rows.
            let preview = TaskDomainList(domains: [previewDomain],
                leadingContent: AnyView(AppStoreRestoreCard(summary: summary, review: {})), restoreSettingsPreview: true)
                .environment(\.restoreTrailingSamples, [RestoreTrailingSample(title: summary.categoryStatus, disclosure: false)])
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
        // Match count pills are green too, including in a nonmatching category.
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
            // The mixed category's only green element is its Match badge. Test
            // that rail separately so it can never masquerade as a status origin.
            let badgeProbe = RestorePreviewRow(title: Text(casks.title),
                status: marked(RestorePreviewCategoryStatus(domain: casks, stateTitles: [:])),
                counts: RestorePreviewMetrics.badges(casks), expanded: true)
                .padding(.horizontal, 32).frame(width: width)
                .environment(\.restoreTrailingSamples, references)
            let badgeBitmap = NSBitmapImageRep(cgImage: ImageRenderer(content: badgeProbe).cgImage!)
            var badgeOrigins: [Int] = []
            for y in 0..<badgeBitmap.pixelsHigh {
                for x in 0..<badgeBitmap.pixelsWide {
                    guard let c = badgeBitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.9 else { continue }
                    if c.greenComponent > 0.2 && c.greenComponent > c.redComponent * 1.3 && c.greenComponent > c.blueComponent * 1.2 {
                        badgeOrigins.append(x)
                    }
                }
            }
            precondition(!badgeOrigins.isEmpty && CGFloat(badgeOrigins.min()! - previous["category:" + casks.id]!) > TaskRowLayout.iconWidth,
                "Match badge must occupy its own rail, outside the status indicator at \(width)")
            // Keep rendering the complete production hierarchy as well as the
            // instrumented rows; markers above do not alter production views.
            let probe = TaskDomainList(domains: domains, restoreSettingsPreview: true, settingsCategories: settings,
                expansion: .constant(Set(domains.map(\.id))), settingsExpansion: .constant(true))
                .padding(16).frame(width: width).background(Color(nsColor: .windowBackgroundColor))
            let renderer = ImageRenderer(content: probe)
            let bitmap = NSBitmapImageRep(cgImage: renderer.cgImage!)
            try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/Debug/RestorePreview-status-grid-\(Int(width)).png"))
            print("PASS: Preview \(width) pt: 8/75/77 status markers align through expansion; Match badge is measured separately")
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
        precondition(wording.attentionCaption == "1 restore issue · 1 app to install · 2 apps to check")
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
        let grouped = RestoreExecutionCategories.sections([
            .init(id: "homebrew-casks", title: "Applications", symbol: "app", items: []),
            .init(id: "vscode-extensions", title: "Extensions", symbol: "app", items: []),
            .init(id: "workspace-folders", title: "Workspace", symbol: "folder", items: [])])
        precondition(grouped.first?.title == "Applications & Tools" && grouped.last?.title == "Workspace")
        precondition(grouped.first?.rows.map(\.id) == ["homebrew-casks", "vscode-extensions"])
        let withManual = RestoreExecutionCategories.sections([
            .init(id: "homebrew-casks", title: "Applications", symbol: "app", items: []),
            .init(id: "homebrew-packages", title: "Packages", symbol: "app", items: []),
            .init(id: "vscode-extensions", title: "Extensions", symbol: "app", items: []),
            .init(id: "workspace-folders", title: "Workspace", symbol: "folder", items: [])], appStore: mixed)
        precondition(withManual.first?.rows.map(\.id) == ["homebrew-casks", "homebrew-packages", "vscode-extensions", "app-store"])
        precondition(withManual.flatMap(\.rows).filter { $0.id == "app-store" }.count == 1)
        precondition(RestoreExecutionCategories.sections([]).isEmpty)
        let manualOnly = RestoreExecutionCategories.sections([], appStore: mixed)
        precondition(manualOnly.first?.title == "Applications & Tools" && manualOnly.first?.rows.map(\.id) == ["app-store"])
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
        precondition(!appScreen.contains("Button(") && appScreen.contains("No App Store applications selected"))
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
            // Use the actual fixed footer's Compare Again button, with the list at the bottom.
            click(host.view.convert(NSPoint(x: size.width - 90, y: size.height - 62), to: nil))
            await model.waitForCompletion(); settle()
            precondition(model.operationID != previousID && model.state == .result, "Compare Again must execute the fixture request")
            precondition(model.presentation?.counts["matching"] == counts["matching"], "The new result must contain the changed fixture data")
            let fresh = scrollView()
            precondition(abs(fresh.contentView.bounds.minY) < 1 && abs(fresh.documentView!.frame.height - collapsed) < 2,
                "Fresh Comparison resets scroll and disclosure state")
            wheelTo(fresh, bottom: true); wheelTo(fresh, bottom: false)
            snapshot(size)
            print("PASS: native ProductionWorkspace Status \(Int(size.width))x\(Int(size.height)), viewport \(Int(frame.height))pt; wheel top-bottom-top, recursive buttons, last row and fresh Compare Again")
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
        check(CaptureMacOSSettingsView(model: capture, expansion: .constant(true)), boxes: 0)
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
        let captureDomains = domains.map { domain in
            TaskDomainPresentation(id: domain.id, title: domain.title, symbol: domain.symbol, items: domain.items.map {
                TaskItemPresentation(id: $0.id, item: $0.item, state: .completed, sourceDomain: $0.sourceDomain)
            })
        }
        let captureChildren = captureDomains[0].resultChildren
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
                                    WorkspaceHeader(title: task.rawValue, subtitle: task.subtitle, symbol: task.symbol)
                                        .background(GeometryReader { proxy in Color.clear.preference(key: WorkflowAnchorFrames.self, value: ["header": proxy.frame(in: .named("workflow"))]) })
                                    if task == .capture {
                                        Text("Environment Saved").font(.title2.weight(.semibold))
                                        WorkspaceThreeMetrics {
                                            CaptureMetricCard(title: "Domains Saved", count: 7, symbol: "square.stack")
                                            CaptureMetricCard(title: "Items Saved", count: 60, symbol: "checklist")
                                        }
                                        CaptureBundleLocationView(destination: URL(fileURLWithPath: "/Users/Example/Environments/My Mac.mbt"), showsReveal: true)
                                        TaskDomainList(domains: captureDomains, compactReadyItems: true, title: "Captured Environment", captureResultLayout: true,
                                            settingsCategories: captureChildren, expansion: binding)
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
                            HStack { if task != .restore { Text("View Log") }; Spacer(); Button(task == .capture ? "Done" : task == .restore ? "Rebuild" : "Compare Again") {} }
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
                if task != .restore { precondition(scroll.documentView!.frame.height > collapsedHeight + 200, "Hidden descendants must render after Expand All") }
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
                    CaptureMacOSSettingsView(model: model, expansion: .constant(true), childExpansion: .constant(false))
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
                            WorkspaceHeader(title: "Restore", subtitle: ProductTask.restore.subtitle, symbol: ProductTask.restore.symbol)
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
                prerequisites: summary, areas: areas, categoryExpansion: .constant(true), showsActions: false, checkAgain: {})
            precondition(preview.showsFixIssues == canFix)
            var anchors: [String: CGRect] = [:]
            let content = HStack(spacing: 0) {
                Color(nsColor: .controlBackgroundColor).frame(width: 223)
                VStack(spacing: 0) {
                    WorkflowContentViewport(pinned: true) {
                        VStack(alignment: .leading, spacing: 12) {
                            WorkspaceHeader(title: "Restore", subtitle: ProductTask.restore.subtitle, symbol: ProductTask.restore.symbol)
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
            // Five bounded cases, without the Capture/Status render matrix.
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/Debug/Preview-Notices-\(name).png"))
            print("PASS: \(name), \(Int(size.width))x\(Int(size.height)), Fix Issues=\(canFix), viewport=\(Int(scroll.contentView.bounds.height)), footer fixed, bottom reachable")
            window.close()
        }
    }

    @MainActor static func main() async {
        if CommandLine.arguments.contains("--preview-notices-only") { restorePreviewNoticesChecks(); return }
        if CommandLine.arguments.contains("--final-alignment-only") { try! await finalCapturePreviewAlignmentChecks(); return }
        if CommandLine.arguments.contains("--restore-macos-only") { await restoreMacOSChecks(); return }
        if CommandLine.arguments.contains("--workflow-scroll-only") { try! await workflowStatusScrollChecks(); return }
        runChecks()
    }

    @MainActor static func runChecks() {
        if CommandLine.arguments.contains("--workflow-descendants-only") { workflowDescendantChecks(); return }
        if CommandLine.arguments.contains("--workflow-controls-only") { workflowInteractiveControlsChecks(); operationLogChecks(); resultStatusAlignmentChecks(); screenshotsIncludedSettingsChecks(); workflowDescendantChecks(); return }
        if CommandLine.arguments.contains("--workflow-layout-only") { workflowDescendantChecks(); workflowLayoutChecks(); return }
        if CommandLine.arguments.contains("--concise-workflows-only") { conciseWorkflowChecks(); operationLogChecks(); resultCleanupChecks(); restoreResultSummaryChecks(); return }
        if CommandLine.arguments.contains("--sidebar-layout-only") { sidebarLayoutChecks(); return }
        if CommandLine.arguments.contains("--preview-expansion-only") { previewExpansionPerformanceChecks(); return }
        if CommandLine.arguments.contains("--preview-appstore-layout-only") { previewColumnGeometryChecks(); resultStatusAlignmentChecks(); appStoreVisualChecks(); return }
        if CommandLine.arguments.contains("--selection-preview-only") { resultCleanupChecks(); resultStatusAlignmentChecks(); return }
        if CommandLine.arguments.contains("--appstore-visual-only") { appStoreVisualChecks(); return }
        if CommandLine.arguments.contains("--restore-result-columns-only") { restoreResultColumnsChecks(); resultStatusAlignmentChecks(); resultCleanupChecks(); minimalResultSummaryChecks(); appStoreVisualChecks(); return }
        if CommandLine.arguments.contains("--capture-checkpoint-only") { captureResultActionsChecks(); screenshotsIncludedSettingsChecks(); windowsIncludedSettingsChecks(); captureResultAlignmentChecks(); return }
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
        if CommandLine.arguments.contains("--operation-log-only") { operationLogChecks(); return }
        if CommandLine.arguments.contains("--visual-contract-only") { visualContractChecks(); return }
        if CommandLine.arguments.contains("--result-cleanup-only") { resultCleanupChecks(); return }
        if CommandLine.arguments.contains("--minimal-result-summary-only") { minimalResultSummaryChecks(); return }
        if CommandLine.arguments.contains("--neutral-unverified-only") { neutralUnverifiedChecks(); return }
        if CommandLine.arguments.contains("--execution-visual-only") { executionVisualChecks(); return }
        if CommandLine.arguments.contains("--final-ui-only") { finalUIAlignmentChecks(); return }
        if CommandLine.arguments.contains("--final-corrections") { finalCorrectionChecks(); return }
        if CommandLine.arguments.contains("--restore-only") { renderRestoreV2(); return }
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
        sidebarLayoutChecks()
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
        #if DEBUG
        precondition(BuildFeatures.sampleExperience)
        var sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
        if !FileManager.default.fileExists(atPath: sources.appendingPathComponent("EnvironmentStatusView.swift").path) {
            // build.sh uses relative source paths; native-control tests can run
            // from the repository root or another working directory.
            sources = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
        }
        let content = try! String(contentsOf: sources.appendingPathComponent("ContentView.swift"), encoding: .utf8)
        let statusView = try! String(contentsOf: sources.appendingPathComponent("EnvironmentStatusView.swift"), encoding: .utf8)
        precondition(statusView.contains("Compare This Mac") && statusView.contains("Choose Saved Environment…"))
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
        precondition(domainView.contains("WorkspaceCategoryIcon(symbol: category.symbol)") && content.contains(".fontWeight(.semibold).foregroundStyle(.blue)"))
        precondition(countPill.contains(".padding(.horizontal, 6).frame(minWidth: 32, minHeight: 23)"))
        precondition(content.contains("Rectangle().fill(Color.primary.opacity(0.22)).frame(height: 1.5)"))

        precondition(domainView.contains("WorkflowTrailingLayout(showsCounts: !Self.badgeCounts(counts).isEmpty, showsChevron: false, statusWidth: 152)"))
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
        precondition(statusView.contains("Button(\"Review in Restore\", action: reviewInRestore).buttonStyle(.bordered)"))
        precondition(statusView.contains(".disabled(busy || handoffBlocked)"))
        precondition(production.contains("reviewInRestore: reviewStatusInRestore, handoffBlocked: busy || syntheticRestore"))
        precondition(production.contains("Replace Current Restore Session?") && production.contains("Use Selected Environment"))
        precondition(production.contains("restore.choose(bundle)") && production.contains("if restore.source == bundle { task = .restore; return }"))


        let app = try! String(contentsOf: sources.appendingPathComponent("MacseedApp.swift"), encoding: .utf8)
        let captureView = try! String(contentsOf: sources.appendingPathComponent("CaptureView.swift"), encoding: .utf8)
        precondition(!captureView.contains("Capture does not rebuild or change settings on this Mac."))
        precondition(captureView.contains("The saved settings are private but unencrypted. Private SSH identities are not included."))
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
        precondition(restoreView.contains("WorkspaceSectionHeader(title: section.id)"))
        precondition(restoreView.contains("showsSelectionActions") && restoreView.contains("if showsSelectionActions"))
        precondition(restoreView.components(separatedBy: "Button(\"Preview Restore\"").count == 2)
        precondition(workspaceSource.contains("showsSelectionActions: false"))
        precondition(workspaceSource.contains("else if restore.state == .review { selectionActionArea }"))
        precondition(workspaceSource.range(of: "else if restore.state == .review { selectionActionArea }")!.lowerBound
            > workspaceSource.range(of: ".modifier(WorkspaceContentGeometry())")!.lowerBound,
            "Selection actions must be placed after the workflow content viewport")
        precondition(restoreView.contains("Preparing Restore Preview") && restoreView.contains("Stopping Preview…"))
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
        precondition(restoreView.contains("WorkspaceCategoryTitle(id: area.id, title: area.label, fallbackSymbol: RestoreRowIcon.symbol(for: area.id))"))
        precondition(restoreView.contains("RestorePresentationSection.visible(model.groups, inventory: includedAreas)"))
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
        precondition(restoreView.contains("ItemDetails(items: notices).padding(.leading, RestoreRowGrid.titleInset)"))
        precondition(restoreView.contains("Secure Transfer is not available") && restoreView.contains("Read-only preview — no changes are made."))
        // Views may reference the operation type for logs, but only the model
        // constructs Execute requests and starts the Core operation.
        precondition(!restoreView.contains(".restoreExecute(") && !restoreView.contains("runtime.start("))
        precondition(restoreView.contains("model.confirmRebuild()") && restoreModel.contains("CoreRequest(.restoreExecute(")
                     && restoreModel.contains("runtime.start(request, location: location)") && restoreModel.contains("includeSecure: false"))
        precondition(!restoreModel.contains("areas selected ·") && !restoreModel.contains("items selected"))
        precondition(restoreModel.contains("Everything selected") && restoreModel.contains("Some items excluded") && restoreModel.contains("Nothing selected"))
        precondition(restoreView.contains("RestoreSelectionActions(status: model.selectionSummary, canPreview: model.canPreview"))
        precondition(restoreView.contains(".disabled(!canPreview)"))
        precondition(restoreView.contains("TaskDomainList(domains: domains.map"))
        precondition(restoreView.contains("RestorePrerequisiteSummaryView(summary: prerequisites, areas: areas)"))
        precondition(restoreView.contains("var showsFixIssues: Bool { prerequisites.canFixIssues }"))
        precondition(restoreView.contains("if showsFixIssues {") && !restoreView.contains("prerequisites.blockers"))
        let taskSource = try! String(contentsOf: sources.appendingPathComponent("TaskComponents.swift"), encoding: .utf8)
        precondition(taskSource.contains("private var expanded = []") && taskSource.contains("ForEach(domain.items)"))
        let previewContent = restoreView.components(separatedBy: "struct RestorePreviewContent: View")[1]
        let previewBody = previewContent.components(separatedBy: "private var previewHeading:")[0]
        let taskListStart = previewBody.range(of: "TaskDomainList(domains: domains.map")!.lowerBound
        precondition(previewBody.range(of: "prerequisiteHeader")!.lowerBound < taskListStart
            && previewBody.range(of: "prerequisiteDetails")!.lowerBound < taskListStart,
            "Preview prerequisites precede the task list in both viewport modes")
        precondition(previewBody.contains("leadingContent: listLeadingContent")
            && previewContent.contains("if pinnedList && hasDetails { prerequisiteDetails }"),
            "Pinned Preview retains prerequisite details at the start of the list")
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
        precondition(workspace.contains("CaptureView(model: capture, runtime: runtime, showsActions: false)"))
        precondition(workspace.range(of: "CaptureActionsView(model:")!.lowerBound > workspace.range(of: ".modifier(WorkspaceContentGeometry())")!.lowerBound)
        precondition(!captureView.contains("individual items") && captureView.contains("panel.nameFieldStringValue = \"Saved Environment\""))
        let reviewStart = captureView.range(of: "            case .review:")!
        let reviewEnd = captureView.range(of: "            case .confirmation:")!
        let captureReview = String(captureView[reviewStart.upperBound..<reviewEnd.lowerBound])
        precondition(!confirmation.contains("CaptureReviewMetrics") && confirmation.contains("compactReadyItems: true") && confirmation.contains("Included in this capture"))
        precondition(!confirmation.contains("OperationSummaryHeader") && !confirmation.contains("scopeSummary"))
        let capturedResultEnd = captureView.range(of: "            case .failed, .cancelled:")!
        let capturedResult = String(captureView[confirmationEnd.upperBound..<capturedResultEnd.lowerBound])
        precondition(capturedResult.contains("CaptureSavedMetrics(publication: saved") && capturedResult.contains("saved.destination"))
        precondition(capturedResult.contains("Captured Environment") && capturedResult.contains("compactReadyItems: true"))
        precondition(!capturedResult.contains("OperationSummaryHeader") && !capturedResult.contains("Ready to Save"))


        precondition(captureReview.contains("CaptureReviewRow.project") && captureReview.contains("CaptureCategorySelectionView"))
        precondition(captureReview.contains("CaptureReviewMetrics(summary: selectionSummary)") && !captureReview.contains("attentionMessage(rows)") && captureReview.contains("Choose supported state to capture."))
        for removed in ["OperationSummaryHeader", "CaptureSectionSelectionView", "Ready to Capture", "Selected Domains", "Selected Items"] {
            precondition(!captureReview.contains(removed))
        }
        let groupStart = captureView.range(of: "struct CaptureMacOSSettingsView: View")!
        let groupEnd = captureView.range(of: "struct CaptureView: View")!
        let macOSGroup = String(captureView[groupStart.lowerBound..<groupEnd.lowerBound])
        precondition(macOSGroup.contains("@CaptureViewState<Bool> private var expanded = false"))
        precondition(macOSGroup.contains("CaptureSettingsSubcategoryView(model: model, category: category") && macOSGroup.contains(".frame(width: 28, height: 28)"))
        precondition(macOSGroup.contains(".disclosureGroupStyle(TaskDisclosureStyle())"))
        precondition(!macOSGroup.contains("CategoryRow(") && !macOSGroup.contains("Included as a whole category"))
        precondition(macOSGroup.components(separatedBy: "DisclosureGroup(").count == 2, "Parent disclosure delegates supported category-only details to subcategory views")
        precondition(CaptureChildRowGrid.leadingInset == 24 && CaptureChildRowGrid.titleInset == 20)
        precondition(content.contains(".padding(.leading, CaptureChildRowGrid.leadingInset).padding(.vertical, 8)"))
        precondition(macOSGroup.contains(".padding(.leading, editable ? CaptureChildRowGrid.leadingInset : 0)"), "macOS areas share the selectable child checkbox column")
        precondition(capturePresentation.contains("accessibilityTitle: \"Select \" + category.title"))
        precondition(capturePresentation.contains("ForEach(settings, id:") && capturePresentation.contains("Text(setting.label)"), "Nested metadata keeps authoritative labels without setting checkboxes")
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
        print("PASS: macOS Settings uses separate native checkbox/header targets and nested domain disclosures without individual setting selection")
        precondition(content.contains("struct WorkspaceHeader: View") && content.contains("struct InsetSidebarSurface: ViewModifier"))
        precondition(content.contains("MacseedHomeHero()") && content.contains("WorkspaceHeader(title: task.rawValue"))
        precondition(production.contains("WorkspaceHeader(title: task.rawValue"))
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
