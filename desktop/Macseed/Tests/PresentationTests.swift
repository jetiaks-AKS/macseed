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
        precondition(prerequisiteSummarySource.contains("Text(\"Ready\")") && prerequisiteSummarySource.contains("ForEach(summary.affectedDomains"))
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
        precondition(view.contains("DisclosureGroup(\"Technical reason\")") && view.contains("DisclosureGroup(\"View Details\")"))
        precondition(view.components(separatedBy: "TaskDomainList(domains: tasks.domains)").count == 3 && view.contains("TaskDomainList(domains: domains)"))
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
        for width in [730, 930, 1330] {
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
        precondition(workspace.contains("(navigation.task == .restore || navigation.task == .capture) ? .infinity : 800"))
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

    @MainActor static func main() {
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
        precondition(workspaceSource.range(of: "rebuildActionArea(synthetic: true)")!.lowerBound > workspaceSource.range(of: ".padding(28).frame(maxWidth:")!.lowerBound)
        precondition(workspaceSource.contains("stop: synthetic ? nil : { restore.requestStop() }"))
        #if DEBUG
        precondition(RestoreDebugScenario.rebuilding.domains.flatMap(\.items).filter { $0.state == .working }.allSatisfy { $0.item.reason == nil })
        precondition(fixtureSource.contains("RestorePreviewContent(title:"))
        #endif
        restoreSummaryChecks()
        renderRestoreV2()
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
        let statusView = try! String(contentsOf: sources.appendingPathComponent("EnvironmentStatusView.swift"), encoding: .utf8)
        let detailsStart = statusView.range(of: "DisclosureGroup(\"Reference Details\", isExpanded: $referenceDetailsExpanded)")!
        let detailsEnd = statusView.range(of: "} else {\n                Text(\"Choose a saved environment", range: detailsStart.upperBound..<statusView.endIndex)!
        let details = String(statusView[detailsStart.lowerBound..<detailsEnd.lowerBound])
        let primary = String(statusView[..<detailsStart.lowerBound]) + String(statusView[detailsEnd.lowerBound...])
        precondition(primary.contains("Label(\"Saved Environment\"") && primary.contains("Choose Saved Environment…"))
        for technical in ["generatedDirectory.path", "blueprint.path", "Generated Configuration", "No Blueprint", "Choose Blueprint…"] {
            precondition(details.contains(technical) && !primary.contains(technical), "Technical reference/Blueprint UI only inside disclosure")
        }
        precondition(statusView.contains("@ReferenceViewState<Bool> private var referenceDetailsExpanded = false"))
        precondition(details.contains(".disclosureGroupStyle(HeaderDisclosureStyle())"))
        precondition(!statusView.contains("Bundle comparison is not supported"))
        let content = try! String(contentsOf: sources.appendingPathComponent("ContentView.swift"), encoding: .utf8)
        let production = try! String(contentsOf: sources.appendingPathComponent("ProductionWorkspace.swift"), encoding: .utf8)
        let app = try! String(contentsOf: sources.appendingPathComponent("MacseedApp.swift"), encoding: .utf8)
        let captureView = try! String(contentsOf: sources.appendingPathComponent("CaptureView.swift"), encoding: .utf8)
        let progressStart = captureView.range(of: "            case .scanning, .preparing, .saving:")!
        let progressEnd = captureView.range(of: "            case .review:")!
        let progress = String(captureView[progressStart.upperBound..<progressEnd.lowerBound])
        precondition(progress.contains("OperationSummaryHeader") && !progress.contains("TaskDomainList") && captureView.contains("Button(\"Cancel\", role: .cancel) { model.cancel() }"))
        precondition(!progress.contains("capture_category") && !progress.contains("categories checked"))
        precondition(captureView.contains("case \"validation\": return \"Checking selected environment…\""))
        let restoreView = try! String(contentsOf: sources.appendingPathComponent("RestoreView.swift"), encoding: .utf8)
        let restoreModel = try! String(contentsOf: sources.appendingPathComponent("RestoreModel.swift"), encoding: .utf8)
        precondition(restoreView.contains("NSOpenPanel()") && restoreView.contains("panel.canChooseDirectories = false"))
        precondition(restoreView.contains("canRebuild: model.canRebuild") && restoreView.contains(".disabled(!canRebuild || rebuild == nil)") && restoreView.contains("model.confirmRebuild()"))
        precondition(restoreView.contains("checkAgain: { model.refreshPreview() }") && restoreView.contains("Button(\"Check Again\") { checkAgain?() }"))
        precondition(restoreView.contains(".disclosureGroupStyle(HeaderDisclosureStyle())") && restoreView.contains("CaptureChildRowGrid.leadingInset"))
        let sections = RestorePresentationSection.project([])
        precondition(sections.map(\.id) == ["Applications & Tools", "Settings", "Shell", "Git", "SSH Configuration", "Workspace"])
        let aggregateSource = String(restoreView.components(separatedBy: "struct RestoreMacOSSelectionView")[1].components(separatedBy: "enum RestoreStatusTone")[0])
        precondition(!aggregateSource.contains("DisclosureGroup") && !aggregateSource.contains("ForEach") && !aggregateSource.contains("Supported settings only"))
        precondition(aggregateSource.contains("model.selectGroup(group") && aggregateSource.contains("Included"))
        precondition(restoreView.contains("RestoreSectionHeader(title: section.id)"))
        precondition(RestoreRowIcon.symbol(for: "vscode-settings") == "gearshape")
        precondition(aggregateSource.contains("RestoreRowIcon(symbol: \"slider.horizontal.3\")"))
        precondition(restoreView.contains("RestoreRowIcon(symbol: RestoreRowIcon.symbol(for: area.id))"))
        precondition(restoreView.contains("RestorePresentationSection.visible(model.groups, inventory: model.areas)"))
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
        precondition(progressSource.contains("TaskDomainList(domains: tasks.domains)"))
        precondition(progressSource.contains("events: runtime.events, executing: true"))
        precondition(restoreView.contains("events: runtime.events, result: result"))
        precondition(!restoreView.contains("result.details.filter"))
        precondition(prerequisiteSource.contains("case \"satisfied\": \"Already Satisfied\""))
        precondition(!prerequisiteSource.contains("This prerequisite is available for the selected plan."))
        precondition(prerequisiteSource.contains("if condition.status != \"satisfied\" {\n                Text(message)"))
        precondition(prerequisiteSource.contains("DisclosureGroup(technicalTitle) { Text(condition.code)"))
        precondition(RestoreRowGrid.titleInset == RestoreRowGrid.checkboxWidth + RestoreRowGrid.disclosureWidth + RestoreRowGrid.iconWidth + RestoreRowGrid.spacing * 3)
        precondition(restoreView.contains(".disclosureGroupStyle(RestoreHeaderDisclosureStyle())"))
        precondition(restoreView.contains("Color.clear.frame(width: RestoreRowGrid.disclosureWidth") && restoreView.contains(".frame(width: RestoreRowGrid.iconWidth, alignment: .center)"))
        precondition(restoreView.contains("ItemDetails(items: notices).padding(.leading, RestoreRowGrid.titleInset)"))
        precondition(restoreView.contains("Secure Transfer is not available") && restoreView.contains("Restore Preview is read-only"))
        precondition(!restoreView.contains("restoreExecute") && restoreModel.contains(".restoreExecute(") && restoreModel.contains("includeSecure: false"))
        precondition(!restoreModel.contains("areas selected ·") && !restoreModel.contains("items selected"))
        precondition(restoreModel.contains("Everything selected") && restoreModel.contains("Some items excluded") && restoreModel.contains("Nothing selected"))
        precondition(restoreView.contains("Text(model.selectionSummary).font(.callout).foregroundStyle(.secondary)"))
        precondition(restoreView.contains(".disabled(!model.canPreview)"))
        precondition(restoreView.contains("TaskDomainList(domains: tasks.domains)"))
        precondition(restoreView.contains("RestorePrerequisiteSummaryView") && restoreView.contains("prerequisites.blockers"))
        let taskSource = try! String(contentsOf: sources.appendingPathComponent("TaskComponents.swift"), encoding: .utf8)
        precondition(taskSource.contains("private var expanded = []") && taskSource.contains("ForEach(domain.items)"))
        let previewContent = restoreView.components(separatedBy: "struct RestorePreviewContent: View")[1]
        precondition(previewContent.range(of: "RestorePreviewAttentionSummaryView(summary:")!.lowerBound < previewContent.range(of: "TaskDomainList(domains: domains)")!.lowerBound)
        precondition(restoreView.contains("Rebuild this Mac?") && restoreView.contains("Stop rebuilding?") && restoreView.contains("Completed changes will remain."))
        precondition(restoreView.contains("model.confirmStop()") && restoreView.contains("model.checkCurrentState()"))
        precondition(restoreModel.contains("plan.preparedPlanID, selection: selection") && restoreModel.contains("invalidate(); state = .result"))
        precondition(!restoreView.contains("Button(\"Resume\")") && !restoreView.contains("ProgressView(value:"))
        precondition(!restoreModel.contains("CaptureCategory.title") && !restoreModel.contains("RestoreSelection.groups"))
        precondition(restoreModel.contains("supportsRestoreSelection") && restoreModel.contains("selection: selection"))
        let confirmationStart = captureView.range(of: "            case .confirmation:")!
        let confirmationEnd = captureView.range(of: "            case .result:")!
        let confirmation = String(captureView[confirmationStart.upperBound..<confirmationEnd.lowerBound])
        precondition(confirmation.contains("prepared.summary.selectedDomains") && confirmation.contains("model.confirmationSummary"))
        precondition(confirmation.contains("model.confirmationWarnings") && confirmation.contains("TaskDomainList("))
        precondition(confirmation.contains("CaptureBundleLocationView") && confirmation.contains("phase: .confirmation"))
        precondition(!confirmation.contains("NativeSelectionCheckbox") && !confirmation.contains("source_partial"))
        precondition(captureView.contains("model.editSelection()") && captureView.contains("model.create()"))
        let capturePresentation = try! String(contentsOf: sources.appendingPathComponent("CapturePresentation.swift"), encoding: .utf8)
        precondition(capturePresentation.contains("Technical Details") && capturePresentation.contains("TaskDisclosureStyle()"))
        precondition(capturePresentation.contains("model.selectItem(category.id") && capturePresentation.contains("model.selectCategory(category.id"))
        let workspace = try! String(contentsOf: sources.appendingPathComponent("ProductionWorkspace.swift"), encoding: .utf8)
        precondition(workspace.contains("CaptureView(model: capture, runtime: runtime, showsActions: false)"))
        precondition(workspace.range(of: "CaptureActionsView(model:")!.lowerBound > workspace.range(of: ".padding(28).frame(maxWidth:")!.lowerBound)
        precondition(!captureView.contains("individual items") && captureView.contains("panel.nameFieldStringValue = \"Saved Environment\""))
        let groupStart = captureView.range(of: "struct CaptureMacOSSettingsView: View")!
        let groupEnd = captureView.range(of: "struct CaptureView: View")!
        let macOSGroup = String(captureView[groupStart.lowerBound..<groupEnd.lowerBound])
        precondition(macOSGroup.contains("@CaptureViewState<Bool> private var expanded = false"))
        precondition(macOSGroup.contains("NativeSelectionCheckbox(category.title") && macOSGroup.contains(".frame(width: 28, height: 28)"))
        precondition(macOSGroup.contains(".disclosureGroupStyle(TaskDisclosureStyle())"))
        precondition(!macOSGroup.contains("CategoryRow(") && !macOSGroup.contains("Included as a whole category"))
        precondition(macOSGroup.components(separatedBy: "DisclosureGroup(").count == 3, "Only parent and progressive technical reasons disclose")
        precondition(CaptureChildRowGrid.leadingInset == 24 && CaptureChildRowGrid.titleInset == 20)
        precondition(content.contains(".padding(.leading, CaptureChildRowGrid.leadingInset).padding(.vertical, 8)"))
        precondition(macOSGroup.contains(".padding(.leading, editable ? CaptureChildRowGrid.leadingInset : 0)"), "macOS areas share the selectable child checkbox column")
        precondition(macOSGroup.contains(".frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)"))
        precondition(macOSGroup.contains("IncludedSettingsText(settings: settings).padding(.leading, editable ? CaptureChildRowGrid.titleInset : 0)"), "Metadata starts at the native checkbox title column")
        precondition(macOSGroup.contains("Supported settings only") && macOSGroup.contains("category.row.includedSettings"))
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
        print("PASS: macOS Settings uses separate native checkbox/header targets and plain domain rows without nested category disclosure")
        precondition(content.contains("struct WorkspaceHeader: View") && content.contains("struct InsetSidebarSurface: ViewModifier"))
        precondition(content.contains("WorkspaceHeader(title: \"Macseed\"") && content.contains("WorkspaceHeader(title: task.rawValue"))
        precondition(production.contains("WorkspaceHeader(title: task.rawValue"))
        precondition(content.contains(".modifier(InsetSidebarSurface())") && production.contains(".modifier(InsetSidebarSurface())"))
        precondition(!content.contains(".systemBlue") && !production.contains(".systemBlue"))
        precondition(app.contains(".pickerStyle(.segmented)") && !app.contains(".preferredColorScheme(") && !app.contains(".onChange(of: appearanceValue)"))
        print("PASS: Shared neutral material sidebar/header in production and preview; native Appearance setting")
        let categoryStart = content.range(of: "struct CategoryRow: View")!
        precondition(content[categoryStart.lowerBound...].contains("@ViewState<Bool> private var expanded = false"))
        precondition(statusView.contains("ForEach(result.categories) { category in CategoryRow(category: category) }"))
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
