import Foundation
import AppKit
import SwiftUI

@main struct PresentationTests {
    @MainActor static func main() {
        if CommandLine.arguments.count == 4 && CommandLine.arguments[1] == "--appearance-read" {
            let stored = UserDefaults(suiteName: CommandLine.arguments[2])!.string(forKey: DesktopAppearance.preferenceKey)
            precondition(stored == CommandLine.arguments[3])
            return
        }
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
        precondition(progress.contains("ProgressView(progressText)") && progress.contains("model.cancel()"))
        precondition(!progress.contains("capture_category") && !progress.contains("categories checked"))
        precondition(captureView.contains("case \"validation\": return \"Checking selected environment…\""))
        let confirmationStart = captureView.range(of: "            case .confirmation:")!
        let confirmationEnd = captureView.range(of: "            case .result:")!
        let confirmation = String(captureView[confirmationStart.upperBound..<confirmationEnd.lowerBound])
        for detailedView in ["CategoryRow(", "CaptureMacOSSettingsView(", "IncludedSettingsText(", "display.items", "selectedItems"] {
            precondition(!confirmation.contains(detailedView), "Confirmation remains summary-only")
        }
        precondition(confirmation.contains("model.confirmationAreas") && confirmation.contains("model.confirmationSummary"))
        precondition(confirmation.contains("model.confirmationWarnings") && confirmation.contains("Some supported state may be unavailable."))
        precondition(confirmation.contains("DisclosureGroup(\"Technical reason\")") && !confirmation.contains("source_partial"))
        precondition(confirmation.contains("model.editSelection()") && confirmation.contains("model.create()"))
        precondition(!captureView.contains("individual items") && captureView.contains("panel.nameFieldStringValue = \"Saved Environment\""))
        let groupStart = captureView.range(of: "struct CaptureMacOSSettingsView: View")!
        let groupEnd = captureView.range(of: "struct CaptureView: View")!
        let macOSGroup = String(captureView[groupStart.lowerBound..<groupEnd.lowerBound])
        precondition(macOSGroup.contains("@CaptureViewState<Bool> private var expanded = false"))
        precondition(macOSGroup.contains("NativeSelectionCheckbox(category.title") && macOSGroup.contains(".frame(width: 28, height: 28)"))
        precondition(macOSGroup.contains(".disclosureGroupStyle(HeaderDisclosureStyle())"))
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
