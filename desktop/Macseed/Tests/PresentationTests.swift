import Foundation
import AppKit
import SwiftUI

@main struct PresentationTests {
    @MainActor static func restoreSummaryChecks() {
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
        precondition(prerequisiteSummarySource.contains("Label(\"Ready\"") && prerequisiteSummarySource.contains("systemImage: \"checkmark\""))
        precondition(prerequisiteSummarySource.contains("ForEach(summary.affectedDomains"))
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
        precondition(resultSource.range(of: "RestoreVerificationResult")!.lowerBound < resultSource.range(of: "RestoreExecutionCategories")!.lowerBound)
        for status in ["complete", "incomplete", "not_run"] {
            let payload: [String: CoreJSON] = ["verification": .object(["status": .string(status), "verified_count": .integer(12),
                "mismatch_count": .integer(1), "unverified_count": .integer(2), "unresolved_count": .integer(3)])]
            let image = ImageRenderer(content: RestoreVerificationResult(outcome: .attention, payload: payload).frame(width: 760))
            precondition(image.nsImage != nil)
        }
        precondition(ImageRenderer(content: RestoreVerificationResult(outcome: .attention, payload: nil).frame(width: 760)).nsImage != nil)
        print("PASS: Result reuses three Preview metric cards above categories and preserves missing Verification counts")
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
        let disclosure = area.components(separatedBy: "DisclosureGroup(isExpanded:")[1].components(separatedBy: "if (expansion")[0]
        precondition(!disclosure.contains("model.selectArea") && !disclosure.contains("model.selectItem"))
        let nested = restore.components(separatedBy: "struct RestoreMacOSAreaDetails:")[1].components(separatedBy: "enum RestoreStatusTone:")[0]
        precondition(!nested.contains("NativeSelectionCheckbox") && nested.contains("Individual settings are not separately selectable"))
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
        precondition(source.contains("RestoreExecutionCategories(domains: tasks.domains, showsWarnings: false, resultStatuses: true)"))
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
        for (mismatch, unverified, count) in [(0, 0, 1), (2, 0, 2), (0, 3, 2), (2, 3, 3)] {
            let summary = RestoreVerificationSummary(payload: ["verification": .object(["status": .string("complete"), "verified_count": .integer(4),
                "mismatch_count": .integer(mismatch), "unverified_count": .integer(unverified), "unresolved_count": .integer(1)])])
            precondition(summary.complete && summary.mismatch == mismatch && summary.unverified == unverified && summary.unresolved == 1)
            precondition(1 + (RestoreVerificationResult.showsCount(summary.mismatch) ? 1 : 0) + (RestoreVerificationResult.showsCount(summary.unverified) ? 1 : 0) == count)
        }
        let source = try! String(contentsOfFile: "Sources/RestoreView.swift")
            .components(separatedBy: "struct RestoreVerificationResult: View {")[1].components(separatedBy: "struct RestoreResultContent:")[0]
        precondition(source.contains("WorkspaceThreeMetrics {") && source.contains("metric(\"Result\""))
        precondition(source.contains("Self.showsCount(summary.mismatch)") && source.contains("Self.showsCount(summary.unverified)"))
        precondition(source.contains("Label(summary.title") && source.contains("Unresolved: "))
        print("PASS: Result always present; only positive Core aggregates visible; missing/null/zero/invalid counts hidden; partial Verification caveats and Unresolved retained; no renders")
    }

    @MainActor static func resultCleanupChecks() {
        let source = try! String(contentsOfFile: "Sources/RestoreView.swift")
        let result = source.components(separatedBy: "struct RestoreResultContent:")[1].components(separatedBy: "struct RestorePreviewMetrics:")[0]
        precondition(!result.contains("result.findings") && !result.contains("Text(\"Needs Attention\")"))
        precondition(result.contains("RestoreVerificationResult(outcome: result.outcome, payload: result.structuredEvidence)"))
        precondition(result.contains("RestoreExecutionCategories(domains: tasks.domains, showsWarnings: false, resultStatuses: true)"))
        precondition(result.contains("Text(result.message)") && result.contains("RestoreResultActions(result: result, refresh: refresh, done: done)"))
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

    @MainActor static func main() {
        if CommandLine.arguments.contains("--result-cleanup-only") { resultCleanupChecks(); return }
        if CommandLine.arguments.contains("--minimal-result-summary-only") { minimalResultSummaryChecks(); return }
        if CommandLine.arguments.contains("--neutral-unverified-only") { neutralUnverifiedChecks(); return }
        if CommandLine.arguments.contains("--execution-visual-only") { executionVisualChecks(); return }
        if CommandLine.arguments.contains("--final-ui-only") { finalUIAlignmentChecks(); return }
        if CommandLine.arguments.contains("--restore-macos-only") { restoreMacOSChecks(); return }
        if CommandLine.arguments.contains("--final-corrections") { finalCorrectionChecks(); return }
        if CommandLine.arguments.contains("--restore-only") { renderRestoreV2(); return }
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
        precondition(components.contains("if item.state != .working, let reason = item.item.reason"))
        let workspaceSource = try! String(contentsOfFile: "Sources/ProductionWorkspace.swift", encoding: .utf8)
        precondition(workspaceSource.range(of: "rebuildActionArea(synthetic: true)")!.lowerBound > workspaceSource.range(of: ".modifier(WorkspaceContentGeometry())")!.lowerBound)
        precondition(workspaceSource.contains("stop: synthetic ? nil : { restore.requestStop() }"))
        #if DEBUG
        precondition(RestoreDebugScenario.rebuilding.domains.flatMap(\.items).filter { $0.state == .working }.allSatisfy { $0.item.reason == nil })
        precondition(fixtureSource.contains("RestorePreviewContent(title:"))
        #endif
        restoreSummaryChecks()
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
        precondition(content.contains(".font(.system(size: 13, weight: .semibold)).foregroundStyle(Color(nsColor: .labelColor))"))
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
        precondition(restoreView.contains("await model.checkPrerequisites()") && restoreView.contains("\"Check Again\"") && restoreView.contains("checkAgain?()"))
        precondition(restoreView.contains("needsRefresh || retrying"))
        precondition(restoreView.contains(".disclosureGroupStyle(HeaderDisclosureStyle())") && restoreView.contains("CaptureChildRowGrid.leadingInset"))
        let sections = RestorePresentationSection.project([])
        precondition(sections.map(\.id) == ["Applications & Tools", "Settings", "Git", "SSH Configuration", "Workspace", "Shell"])
        let aggregateSource = String(restoreView.components(separatedBy: "struct RestoreMacOSSelectionView")[1].components(separatedBy: "enum RestoreStatusTone")[0])
        precondition(aggregateSource.contains("DisclosureGroup") && aggregateSource.contains("ForEach(CaptureMacOSSettingsGroup.domainIDs") && !aggregateSource.contains("model.selectItem"))
        precondition(aggregateSource.contains("model.selectGroup(group") && aggregateSource.contains("Included"))
        precondition(restoreView.contains("WorkspaceSectionHeader(title: section.id)"))
        precondition(restoreView.contains("showsSelectionActions") && restoreView.contains("if showsSelectionActions"))
        precondition(restoreView.components(separatedBy: "Button(\"Preview Restore\"").count == 2)
        precondition(workspaceSource.contains("showsSelectionActions: false"))
        precondition(workspaceSource.contains("else if restore.state == .review { selectionActionArea }"))
        precondition(workspaceSource.range(of: "selectionActionArea: some View")!.lowerBound > workspaceSource.range(of: "ScrollView {")!.lowerBound)
        precondition(restoreView.contains("Preparing Restore Preview") && restoreView.contains("Stopping Preview…"))
        precondition(restoreView.contains("Read-only inspection — no changes will be made to this Mac."))
        precondition(restoreView.contains("Button(\"Continue Rebuild\")") && restoreView.contains(".keyboardShortcut(.defaultAction)"))
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
        precondition(!restoreView.contains("restoreExecute") && restoreModel.contains(".restoreExecute(") && restoreModel.contains("includeSecure: false"))
        precondition(!restoreModel.contains("areas selected ·") && !restoreModel.contains("items selected"))
        precondition(restoreModel.contains("Everything selected") && restoreModel.contains("Some items excluded") && restoreModel.contains("Nothing selected"))
        precondition(restoreView.contains("RestoreSelectionActions(status: model.selectionSummary, canPreview: model.canPreview"))
        precondition(restoreView.contains(".disabled(!canPreview)"))
        precondition(restoreView.contains("TaskDomainList(domains: domains.map"))
        precondition(restoreView.contains("RestorePrerequisiteSummaryView") && restoreView.contains("prerequisites.blockers"))
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
