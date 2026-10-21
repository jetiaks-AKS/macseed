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
                let selectedRows = navigationList(in: sidebar.viewController.view)?.selectedRowIndexes
                split.toggleSidebar(nil)
                settle(window, duration: 0.4)
                precondition(sidebar.isCollapsed, "Existing sidebar toggle must hide the sidebar")
                precondition(detailWidth(split) > visibleDetailWidth + 200,
                             "Hidden sidebar must release its width to detail")
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
        precondition(prerequisiteSummarySource.contains("showsHeading: false") && prerequisiteSummarySource.contains("technicalTitle: \"Technical Details\""))
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
        precondition(view.contains("DisclosureGroup(\"Technical reason\")") && view.contains("DisclosureGroup(\"Technical Details\")"))
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
        precondition(components.contains("Button {}") && components.contains(".disabled(true)"))
        precondition(components.contains("Technical Details") && components.contains("ForEach(domain.items)"))
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
        precondition(resultSource.contains("DisclosureGroup(\"Technical Details\")"))
        precondition(!resultSource.contains("Verified selected work"))
        precondition(resultSource.contains("result.compactTechnicalDetails") && resultSource.contains("Copy Diagnostic Details"))
        precondition(resultSource.contains("result.diagnosticReport") && resultSource.contains("NSPasteboard.general"))

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
        precondition(source.contains("TaskDisclosureStyle(minimumHeight: 22)"))
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
        print("PASS: Native technical disclosure, attention heading, main window bounds/fullscreen policy and responsive range renders")
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

    @MainActor static func restoreMacOSChecks() {
        _ = NSApplication.shared
        NSApp.appearance = NSAppearance(named: .aqua)
        let match = TaskItemPresentation(id: "match", item: DisplayItem(id: "match", title: "Show extensions", status: .matching, action: "Already Matches"), state: .matching)
        precondition(RestoreSettingPreviewLeaf(item: match, title: match.item.title).compactMatch)
        for state in [TaskRowState.unverified, .attention, .failed, .planned] {
            let issue = TaskItemPresentation(id: "issue", item: DisplayItem(id: "issue", title: "Setting", status: .information, action: "Reported issue", reason: "retained reason"), state: state)
            precondition(!RestoreSettingPreviewLeaf(item: issue, title: issue.item.title).compactMatch)
        }
        let issue = TaskItemPresentation(id: "issue", item: DisplayItem(id: "issue", title: "Show hidden files", status: .attention, action: "Inspection unavailable", reason: "Observation failed"), state: .unverified)
        let finder = TaskDomainPresentation(id: "macos-finder", title: "Finder", symbol: "finder", items: [match, issue], previewOnly: true)
        let parent = TaskDomainPresentation(id: "macOS Settings", title: "macOS Settings", symbol: "slider.horizontal.3", items: [match, issue], previewOnly: true)
        let content = TaskDomainList(domains: [parent], restoreSettingsPreview: true, settingsCategories: [finder], expansion: .constant([parent.id]), settingsExpansion: .constant(true))
            .padding(28).frame(width: 785).background(Color(nsColor: .windowBackgroundColor))
        let renderer = ImageRenderer(content: content); renderer.scale = 1
        let bitmap = NSBitmapImageRep(data: renderer.nsImage!.tiffRepresentation!)!
        try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/Debug/Restore-macOS-Preview.png"))
        print("PASS: Restore compact matching leaves, nonmatching statuses/reasons, native expanded Finder Preview")
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
        precondition(result.contains("DisclosureGroup(\"Technical Details\") {") && !result.contains("isExpanded:"))
        precondition(result.contains("result.compactTechnicalDetails") && result.contains("Copy Diagnostic Details") && result.contains("result.diagnosticReport"))
        let model = try! String(contentsOfFile: "Sources/RestoreModel.swift")
        precondition(model.contains("let findings: [DisplayItem]") && model.contains("findings = outcome == .clean ? [] : normalized.findings"))
        precondition(RestoreResultStatusLabel(state: .unverified).tone == .neutral && RestoreResultStatusLabel(state: .unverified).symbol == "questionmark.circle")
        for state in [TaskRowState.attention, .completed, .matching, .notRun] {
            precondition(RestoreResultStatusLabel(state: state).tone == state.tone && RestoreResultStatusLabel(state: state).symbol == state.symbol)
        }
        print("PASS: Result findings block absent; category statuses, Summary, safety message, collapsed Technical Details and diagnostic copy retained; model findings unchanged; no renders")
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
            let terminal = state == .result || state == .failed || state == .cancelled
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
                precondition(!OperationLogVisibility.restore(state, active: false, reference: reference(operation), terminal: true))
            }
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
        print("PASS: shared terminal-only Capture/Restore/Status View Log matrix, exact operation references and direct Settings history")
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
        precondition(source.contains("if !hasOperationLog && !result.technicalDetails.isEmpty"))
        let stopContent = source.components(separatedBy: "if let notice = result.stopNotice {")[1]
            .components(separatedBy: "RestoreResultSummaryView")[0]
        precondition(stopContent.contains("Label(notice, systemImage: \"stop.circle\")")
            && stopContent.contains("if let explanation = result.stopRequestExplanation {")
            && stopContent.contains("Text(explanation)"))
        precondition(source.contains("Text(String(count))") && !source.contains("Text(label + \" \" + String(count))"))
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
                            HStack(spacing: 8) {
                                Color.red.frame(width: 40, height: 8)
                                if row % 3 > 0 { Color.blue.frame(width: 32, height: 8) }
                                if row % 3 > 1 { Color.blue.frame(width: 32, height: 8) }
                                Color(red: 0, green: 1, blue: 0).frame(width: 12, height: 8)
                            }.frame(maxWidth: .infinity, alignment: .leading)
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
                precondition(starts.count == 1 && countStarts.count == 1 && chevronStarts.count == 3 && rows >= 48,
                    "Column origins: status=\(starts), count=\(countStarts), chevron=\(chevronStarts), rows=\(rows)")
                precondition(countStarts.first! - starts.first! == 48)
                precondition(chevronStarts.sorted() == [48, 88, 128].map { starts.first! + $0 },
                    "Absent badges reserve no slot; every adjacent control has only 8 pt spacing")
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
        precondition(header.contains("RestoreCountBadges(counts: counts)") && !header.contains("Spacer("))
        let itemSource = source.components(separatedBy: "struct RestoreResultItemRow:")[1].components(separatedBy: "struct RestoreResultStatusLabel:")[0]
        precondition(itemSource.components(separatedBy: "Image(systemName: \"chevron.right\"").count == 2)
        precondition(itemSource.contains("Text(\"Technical Details\")") && !itemSource.contains("Button(\"Technical Details\")"))
        precondition(!final.contains("TaskTextStatusLayout") && !final.contains("ViewThatFits") && !final.contains(".offset("))
        precondition(RestoreResultColumns.titleInset(depth: 1) == 52 && RestoreResultColumns.titleInset(depth: 1, item: true) == 88)
        print("PASS: Compact trailing groups: no reserved badge slots, shared status origins, wrapping and larger text at 420/785/985 pt")
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
            let previewSamples = [RestoreTrailingSample(title: previewDomain.state.rawValue),
                RestoreTrailingSample(title: summary.categoryStatus, disclosure: false)]
            let manual = origin(AppStoreRestoreCard(summary: summary, review: {}).environment(\.restoreTrailingSamples, previewSamples), width: width)
            let automatic = origin(TaskDomainList(domains: [previewDomain], restoreSettingsPreview: true)
                .environment(\.restoreTrailingSamples, previewSamples), width: width)
            precondition(abs(manual - automatic) <= 3, "Preview manual and automatic status origins: \(manual), \(automatic)")
        }
        print("PASS: Real category, nested, leaf and App Store status origins align at 420/785/985 pt")
    }

    @MainActor static func previewColumnGeometryChecks() {
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
        for width: CGFloat in [420, 785, 985] {
            let probe = TaskDomainList(domains: domains, restoreSettingsPreview: true, settingsCategories: settings,
                expansion: .constant(Set(domains.map(\.id))), settingsExpansion: .constant(true))
                .padding(16).frame(width: width).background(Color(nsColor: .windowBackgroundColor))
            let renderer = ImageRenderer(content: probe)
            let bitmap = NSBitmapImageRep(cgImage: renderer.cgImage!)
            var origins: [Int] = []
            var lastY = -100
            for y in 0..<bitmap.pixelsHigh {
                var left: Int? = nil
                for x in 0..<bitmap.pixelsWide {
                    guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.9 else { continue }
                    if c.greenComponent > 0.2 && c.greenComponent > c.redComponent * 1.3 && c.greenComponent > c.blueComponent * 1.2 { left = x; break }
                }
                if let left {
                    if y - lastY > 8 { origins.append(left) }
                    else { origins[origins.count - 1] = min(origins.last!, left) }
                    lastY = y
                }
            }
            precondition(origins.count >= 65 && origins.max()! - origins.min()! <= 3,
                "Preview category/leaf/nested settings status origins at \(width): \(origins)")
            try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/Debug/RestorePreview-status-grid-\(Int(width)).png"))
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

    @MainActor static func main() {
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
        if CommandLine.arguments.contains("--restore-macos-only") { restoreMacOSChecks(); return }
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
        precondition(components.contains("if Self.showsTechnicalDetails(item), let reason = item.item.reason"))
        for state in [TaskRowState.attention, .working] {
            var row = TaskItemPresentation(id: "diagnostic", item: DisplayItem(id: "diagnostic", title: "Fixture",
                status: .attention, action: "Inspect", reason: "observation_failed"), state: state)
            precondition(TaskDomainItems.showsTechnicalDetails(row) == (state != .working))
            row.assistedAppStore = AssistedAppStoreItem(appID: "12345", status: .unverified)
            precondition(!TaskDomainItems.showsTechnicalDetails(row))
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
        precondition(statusView.contains("EnvironmentComparisonDomain(category: child, expansion: childExpansion)"))
        precondition(statusView.contains("DisclosureGroup(isExpanded: expansion ?? $expanded)"))
        precondition(statusView.contains("@ReferenceViewState<Bool> private var expanded = false"))
        precondition(statusView.contains("if model.state != .choose { Spacer() }"))
        precondition(statusView.contains("if model.reference != nil {"))
        precondition(!statusView.contains("Text(result.summary)"))
        precondition(content.contains(".font(.system(size: prominent ? 15 : 13, weight: .semibold)).foregroundStyle(Color(nsColor: .labelColor))"))
        precondition(statusView.contains("if let reason = item.comparisonTechnicalDetails"))
        precondition(statusView.contains("if let explanation = item.comparisonExplanation"))
        precondition(statusView.contains(".accessibilityLabel(\"Already Matches\")"))
        precondition(statusView.contains("Image(systemName: \"checkmark\")"))

        for technical in ["Choose Blueprint…", "Generated Configuration", "blueprint.path"] {
            precondition(!statusView.contains(technical), "Status uses a Bundle, not internal reference controls")
        }
        precondition(statusView.contains("EnvironmentComparisonView(result: result)"))
        precondition(statusView.contains("$0 != .notApplicable || $0.count(result) > 0"))
        precondition(statusView.contains("if Self.summaryOutcomes(result).count == 3") && statusView.contains("HStack(spacing: 10)"))

        precondition(statusView.contains("result.categoryCount($0, category: entry.category, children: entry.children)"))
        precondition(statusView.contains("counts[$0, default: 0] > 0") && statusView.contains("ComparisonOutcome.allCases.filter"))
        precondition(statusView.contains(".foregroundStyle(outcome.tint).background(outcome.tint.opacity(0.12), in: Capsule())"))
        precondition(statusView.contains("Full Diagnostic Details") && statusView.contains("fact.predicateTitle"))
        let domainView = statusView.components(separatedBy: "struct EnvironmentComparisonDomain: View")[1].components(separatedBy: "struct EnvironmentComparisonItem: View")[0]
        precondition(domainView.contains("Capsule()") && domainView.contains("if let counts"))
        precondition(domainView.contains("WorkspaceCategoryIcon(symbol: category.symbol)") && content.contains(".fontWeight(.semibold).foregroundStyle(.blue)"))
        precondition(domainView.contains(".padding(.horizontal, 8).frame(minWidth: 46, minHeight: 23)"))
        precondition(content.contains("Rectangle().fill(Color.primary.opacity(0.22)).frame(height: 1.5)"))

        precondition(domainView.contains("if ![.different, .missing].contains(status) { statusLabel }"))
        precondition(domainView.contains("Text(counts == nil ? category.comparisonStatusText : status.rawValue)"))
        precondition(!domainView.contains("warningCompanion") && !domainView.contains("warning && outcomes"))

        let sectionHeader = content.components(separatedBy: "struct WorkspaceSectionHeader:")[1].components(separatedBy: "struct WorkspaceCategoryIcon:")[0]
        precondition(!sectionHeader.contains("Capsule()") && !sectionHeader.contains("counts"))
        precondition(domainView.contains("EnvironmentComparisonDomain(category: child, expansion: childExpansion)"))

        precondition(WorkspaceActionLayout.columns(659) == 1 && WorkspaceActionLayout.columns(660) == 3)
        precondition(WorkspaceMetricLayout.columns(899) == 2 && WorkspaceMetricLayout.columns(900) == 4)
        for task in ProductTask.allCases { precondition(NSImage(systemSymbolName: task.symbol, accessibilityDescription: nil) != nil) }
        precondition(statusView.contains("WorkspacePrimaryActionCard(title: \"Choose Saved Environment\""))
        precondition(!statusView.contains("WorkspaceResultHeader(title:") && statusView.contains("ForEach(ComparisonOutcome.allCases)"))

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
        precondition(restoreView.contains(".disclosureGroupStyle(HeaderDisclosureStyle())") && restoreView.contains("CaptureChildRowGrid.leadingInset"))
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
        precondition(workspaceSource.range(of: "selectionActionArea: some View")!.lowerBound > workspaceSource.range(of: "ScrollView {")!.lowerBound)
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
        precondition(prerequisiteSource.contains("DisclosureGroup(technicalTitle)") && prerequisiteSource.contains("Text(condition.code)"))
        precondition(RestoreRowGrid.titleInset == RestoreRowGrid.checkboxWidth + RestoreRowGrid.disclosureWidth + RestoreRowGrid.iconWidth + RestoreRowGrid.spacing * 3)
        precondition(restoreView.contains(".disclosureGroupStyle(TaskDisclosureStyle())"))
        precondition(content.contains(".frame(width: TaskRowLayout.iconWidth)") && restoreView.contains("WorkspaceCategoryIcon(symbol: symbol)"))
        precondition(restoreView.contains("ItemDetails(items: notices).padding(.leading, RestoreRowGrid.titleInset)"))
        precondition(restoreView.contains("Secure Transfer is not available") && restoreView.contains("Restore Preview is read-only"))
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
        precondition(previewContent.range(of: "RestorePrerequisiteSummaryView(summary:")!.lowerBound < previewContent.range(of: "TaskDomainList(domains: domains.map")!.lowerBound)
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
        precondition(capturePresentation.contains("Technical Details") && capturePresentation.contains("TaskDisclosureStyle()"))
        let confirmationItems = capturePresentation.components(separatedBy: "struct CaptureConfirmationItems: View")[1]
        precondition(!confirmationItems.contains("Text(\"Needs Attention\")") && !confirmationItems.contains("? domain.title"))
        precondition(confirmationItems.contains("item.captureRole != .categoryWarning") && confirmationItems.contains("Technical Details"))

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
        precondition(statusView.contains("ForEach(result.sections) { section in") && statusView.contains("EnvironmentComparisonDomain(category: entry.category, children: entry.children, technicalFacts: result.technicalFacts, counts: Dictionary("))
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
        print("PASS: Product reference wording, technical/Blueprint UI behind collapsed disclosure, collapsed categories and optional Blueprint semantics")
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
