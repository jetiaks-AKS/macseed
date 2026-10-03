import AppKit
import SwiftUI

private typealias ReferenceViewState<Value> = SwiftUI.State<Value>

struct EnvironmentStatusView: View {
    @ObservedObject var model: EnvironmentStatusModel
    @ObservedObject var runtime: CoreRuntime
    @ReferenceViewState<Bool> private var referenceDetailsExpanded = false
    private var busy: Bool { runtime.isActive || model.state == .running }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let reference = model.reference {
                HStack {
                    Label("Saved Environment", systemImage: "folder")
                    Button("Change…", action: chooseReference).disabled(busy)
                }
                DisclosureGroup("Reference Details", isExpanded: $referenceDetailsExpanded) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(reference.generatedDirectory.path).font(.caption).textSelection(.enabled)
                        Text("Generated Configuration · " + (reference.blueprint == nil ? "No Blueprint" : "Selected Blueprint"))
                            .font(.callout).foregroundStyle(.secondary)
                        if let blueprint = reference.blueprint {
                            Label(blueprint.path, systemImage: "doc.text").font(.caption).textSelection(.enabled)
                        }
                        HStack {
                            Button("Choose Blueprint…", action: chooseBlueprint)
                            if reference.blueprint != nil { Button("No Blueprint") { model.selectBlueprint(nil) } }
                        }.disabled(busy)
                    }
                }.disclosureGroupStyle(HeaderDisclosureStyle())
            } else {
                Text("Choose a saved environment to compare with this Mac.")
                Button("Choose Saved Environment…", action: chooseReference).disabled(busy)
            }

            switch model.state {
            case .choose:
                Button("Compare") { model.compare() }.buttonStyle(.borderedProminent).disabled(model.reference == nil || busy)
            case .running:
                ProgressView(runtime.stopping ? "Stopping comparison…" : "Comparing saved environment…")
                Button("Cancel") { model.cancel() }.disabled(runtime.stopping)
            case .result:
                if let result = model.presentation {
                    Label(result.headline, systemImage: result.needsAttention ? "exclamationmark.triangle" : "checkmark.circle")
                        .font(.title2).foregroundStyle(result.needsAttention ? Color.orange : Color.primary)
                    if !result.summary.isEmpty { Text(result.summary) }
                    Text(result.message).foregroundStyle(.secondary)
                    ForEach(result.categories) { category in CategoryRow(category: category) }
                        .id(model.operationID)
                }
                Button("Check Again") { model.compare() }.disabled(busy)
            case .failed, .cancelled:
                Label(model.state == .cancelled ? "Comparison Cancelled" : "Needs Attention",
                      systemImage: model.state == .cancelled ? "stop.circle" : "exclamationmark.triangle")
                    .font(.title2).foregroundStyle(model.state == .cancelled ? Color.secondary : Color.orange)
                if let failure = model.failure {
                    Text(failure.message)
                    if let reason = failure.technicalReason {
                        DisclosureGroup("Technical reason") { Text(reason).font(.caption.monospaced()).textSelection(.enabled) }
                            .disclosureGroupStyle(HeaderDisclosureStyle())
                    }
                }
                Button("Check Again") { model.compare() }.disabled(model.reference == nil || busy)
            }
            Text("Nothing will be removed or changed.").font(.callout).foregroundStyle(.secondary)
        }
        .onChange(of: model.reference) { _, _ in referenceDetailsExpanded = false }
    }

    private func chooseReference() {
        let panel = NSOpenPanel()
        panel.title = "Choose Saved Environment"
        panel.message = "Choose the folder containing your saved environment."
        panel.prompt = "Choose Saved Environment"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        present(panel) { model.selectReference($0) }
    }
    private func chooseBlueprint() {
        let panel = NSOpenPanel()
        panel.title = "Choose Blueprint"
        panel.message = "Choose an optional Blueprint to limit the comparison scope."
        panel.prompt = "Choose Blueprint"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        present(panel) { model.selectBlueprint($0) }
    }
    private func present(_ panel: NSOpenPanel, selected: @escaping (URL) -> Void) {
        // A native chooser is the only modal boundary; all result/error states stay inline.
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window) { response in
                if response == .OK, let url = panel.url { selected(url) }
            }
        } else {
            panel.begin { response in if response == .OK, let url = panel.url { selected(url) } }
        }
    }
}
