import AppKit
import SwiftUI
import UniformTypeIdentifiers

private typealias CaptureViewState<Value> = SwiftUI.State<Value>

struct SettingsFlowLayout: Layout {
    static func frames(sizes: [CGSize], width: CGFloat) -> [CGRect] {
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        return sizes.map { size in
            if x > 0 && x + size.width > width {
                x = 0; y += rowHeight + 4; rowHeight = 0
            }
            let frame = CGRect(origin: CGPoint(x: x, y: y), size: size)
            x += size.width + 5; rowHeight = max(rowHeight, size.height)
            return frame
        }
    }
    private func frames(width: CGFloat, subviews: Subviews) -> [CGRect] {
        Self.frames(sizes: subviews.map { view in
            let ideal = view.sizeThatFits(.unspecified)
            return view.sizeThatFits(ProposedViewSize(width: min(ideal.width, width), height: nil))
        }, width: width)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let idealWidth = subviews.reduce(CGFloat(0)) { $0 + $1.sizeThatFits(.unspecified).width + 5 }
        let width = proposal.width.flatMap { $0.isFinite ? max(0, $0) : nil } ?? idealWidth
        let frames = frames(width: width, subviews: subviews)
        return CGSize(width: width, height: frames.map(\.maxY).max() ?? 0)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (view, frame) in zip(subviews, frames(width: bounds.width, subviews: subviews)) {
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                       anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }
}

struct IncludedSettingsText: View {
    let settings: [CoreCaptureInventoryRow.IncludedSetting]
    var body: some View {
        SettingsFlowLayout {
            ForEach(Array(settings.enumerated()), id: \.element.id) { index, setting in
                Text(setting.label + (index < settings.count - 1 ? " ·" : ""))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.font(.callout).foregroundStyle(.secondary)
    }
}

struct CaptureMacOSSettingsView: View {
    @ObservedObject var model: CaptureModel
    var editable = true
    @CaptureViewState<Bool> private var expanded = false
    var body: some View {
        let group = model.macOSSettings
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                if editable {
                    NativeSelectionCheckbox("", state: group.state, accessibilityTitle: "Select macOS Settings") {
                        model.selectMacOSSettings(included: $0)
                    }
                    .frame(width: 28, height: 28)
                    .disabled(group.availableIDs.isEmpty)
                }
                DisclosureGroup(isExpanded: $expanded) { EmptyView() } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Label("macOS Settings", systemImage: "slider.horizontal.3").font(.headline)
                            Text("Supported settings only").font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .leading, spacing: 3) {
                            if group.hasAttention { TaskStatusLabel(state: .attention) }
                            Text(group.summary).font(.caption).foregroundStyle(.secondary)
                        }.frame(width: TaskRowLayout.statusWidth, alignment: .leading)
                    }
                }
                .disclosureGroupStyle(TaskDisclosureStyle())
            }
            if expanded {
                ForEach(group.children.filter { editable || model.selectionState($0) != .none }) { category in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            if editable {
                                NativeSelectionCheckbox(category.title, state: model.selectionState(category)) {
                                    model.selectCategory(category.id, included: $0)
                                }
                                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                                .disabled(!category.selectable)
                            } else { Text(category.title) }
                            Spacer()
                            if !category.selectable {
                                Text(category.headerSummary).font(.callout).foregroundStyle(.secondary)
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange).accessibilityLabel("Needs Attention")
                            } else if !category.notices.isEmpty {
                                Label("Needs Attention", systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                            }
                        }
                        if !category.selectable {
                            Text(category.display.items.first?.action ?? "").font(.callout).foregroundStyle(.secondary)
                        } else if let settings = category.row.includedSettings, !settings.isEmpty {
                            IncludedSettingsText(settings: settings).padding(.leading, editable ? CaptureChildRowGrid.titleInset : 0)
                        }
                        if let reason = category.row.reason {
                            DisclosureGroup("Technical Details") {
                                Text(reason).font(.caption.monospaced()).textSelection(.enabled)
                            }.disclosureGroupStyle(TaskDisclosureStyle(minimumHeight: 22))
                        }
                    }.padding(.vertical, 4)
                }.padding(.leading, editable ? CaptureChildRowGrid.leadingInset : 0)
            }
        }.padding(.horizontal, 16).padding(.vertical, 4)
    }
}

struct CaptureView: View {
    @ObservedObject var model: CaptureModel
    @ObservedObject var runtime: CoreRuntime
    var showsActions = true
    private var progressText: String {
        if runtime.stopping { return "Stopping Capture…" }
        switch runtime.currentPhase {
        case "discovery": return "Scanning supported environment…"
        case "validation": return "Checking selected environment…"
        case "bundle_creation": return "Creating Saved Environment…"
        default: return model.state == .scanning ? "Starting scan…" : "Preparing selected environment…"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            switch model.state {
            case .idle:
                Text("Choose which supported settings and tools to carry to another Mac.")
                Button("Scan this Mac") { model.scan() }.buttonStyle(.borderedProminent).disabled(runtime.isActive)
            case .scanning, .preparing, .saving:
                OperationSummaryHeader(title: model.state == .scanning ? "Scanning this Mac" : model.state == .saving ? "Saving Your Environment" : "Checking Your Environment",
                    message: progressText, state: .working, counters: [],
                    suppliedMetrics: model.state == .scanning ? [] : selectionSummary.metrics,
                    scopeSummary: model.state == .scanning ? "Core is scanning supported state." : selectionSummary.scope)
                if model.state == .saving {
                    Text("Once saving begins, stopping does not promise that a published file will be removed.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            case .review:
                OperationSummaryHeader(title: model.canCreate ? "Ready to Capture" : "Choose Supported State",
                    message: "Ordinary settings are private but unencrypted. Only supported reproducible state is included.",
                    state: selectionSummary.attentionCount > 0 ? .attention : .planned, counters: [],
                    suppliedMetrics: selectionSummary.metrics, scopeSummary: model.selectionSummary)
                HStack {
                    Text("Review and select").font(.headline)
                    Spacer()
                    Button(model.bulkState.bulkActionTitle) { model.toggleAll() }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .disabled(!model.categories.contains(where: \.selectable) || runtime.isActive)
                }
                VStack(spacing: 0) {
                    ForEach(model.categories) { category in
                        if CaptureMacOSSettingsGroup.domainIDs.contains(category.id) {
                            if category.id == model.categories.first(where: { CaptureMacOSSettingsGroup.domainIDs.contains($0.id) })?.id {
                                CaptureMacOSSettingsView(model: model)
                                Divider()
                            }
                        } else {
                            CaptureCategorySelectionView(model: model, category: category)
                            if category.id != model.categories.last?.id { Divider() }
                        }
                    }
                }.background(.background, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
                    .id(model.operationID)
                CaptureSecureTransferView()
                if !model.canCreate { Text("Choose supported state to capture.").foregroundStyle(.secondary) }
            case .confirmation:
                if let prepared = model.preparation, let selection = prepared.selection {
                    let summary = CaptureSummaryPresentation(domainCount: prepared.summary.selectedDomains, itemCount: prepared.summary.selectedItems,
                        attentionCount: model.confirmationWarnings.count, unsupportedCount: 0)
                    OperationSummaryHeader(title: "Save this environment?", message: "Review the final capture before creating the saved environment.",
                        state: summary.attentionCount > 0 ? .attention : .planned, counters: [], suppliedMetrics: summary.metrics,
                        scopeSummary: model.confirmationSummary)
                    if let destination = model.destination { CaptureBundleLocationView(destination: destination) }
                    Text("The saved settings are private but unencrypted. Private SSH identities are not included.")
                        .font(.callout).foregroundStyle(.secondary)
                    TaskDomainList(domains: CaptureTaskPresentation(categories: prepared.inventory.map { CaptureCategory(row: $0) },
                        selection: selection, phase: .confirmation).domains, stateTitles: [.planned: "Ready to Save"])
                }
            case .result:
                if let saved = model.publication {
                    let summary = CaptureSummaryPresentation(domainCount: saved.bundle.capturedDomains.count, itemCount: saved.bundle.itemCount,
                        attentionCount: Set(model.resultNotices.map(\.id)).count, unsupportedCount: 0, captured: true)
                    OperationSummaryHeader(title: "Environment Saved", message: summary.attentionCount == 0 ? "Your selected environment was saved successfully." : "Your environment was saved. Review the captured domains that need attention.",
                        state: summary.attentionCount == 0 ? .completed : .partial, counters: [], suppliedMetrics: summary.metrics, scopeSummary: summary.scope)
                    CaptureBundleLocationView(destination: URL(fileURLWithPath: saved.destination))
                    if let prepared = model.preparation, let selection = prepared.selection {
                        TaskDomainList(domains: CaptureTaskPresentation(categories: prepared.inventory.map { CaptureCategory(row: $0) },
                            selection: selection, phase: .result, capturedDomains: saved.bundle.capturedDomains, notices: model.resultNotices).domains)
                    }
                }
            case .failed, .cancelled:
                Label(model.state == .cancelled ? "Capture Cancelled" : "Needs Attention",
                      systemImage: model.state == .cancelled ? "stop.circle" : "exclamationmark.triangle")
                    .font(.title2).foregroundStyle(model.state == .cancelled ? Color.secondary : Color.orange)
                if let failure = model.failure {
                    Text(failure.message)
                    if let reason = failure.technicalReason {
                        DisclosureGroup("Technical Details") { Text(reason).font(.caption.monospaced()).textSelection(.enabled) }
                            .disclosureGroupStyle(TaskDisclosureStyle(minimumHeight: 22))
                    }
                }
                if let destination = model.destination {
                    switch model.publicationEvidence {
                    case .occurred: Text("Publication was reported, but Capture did not complete successfully. Check the destination before another attempt.")
                    case .unknown: Text("Publication could not be confirmed. A file or temporary state may remain. Check the destination before another attempt.")
                    case .notOccurred: Text("No completed publication was reported.")
                    }
                    Text(destination.path).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            if showsActions { CaptureActionsView(model: model, runtime: runtime) }
            Text("Capture does not rebuild or change settings on this Mac.").font(.callout).foregroundStyle(.secondary)
        }
    }
    private var selectionSummary: CaptureSummaryPresentation {
        CaptureSummaryPresentation.review(categories: model.state == .review ? model.categories : model.categories.filter { model.selectionState($0) != .none }, domainCount: model.selectedDomainCount, itemCount: model.selectedItemCount)
    }
}

struct CaptureBundleLocationView: View {
    let destination: URL
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(destination.lastPathComponent, systemImage: "shippingbox").font(.headline)
            Text(destination.path).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }
}

struct CaptureActionsView: View {
    @ObservedObject var model: CaptureModel
    @ObservedObject var runtime: CoreRuntime
    var body: some View {
        HStack {
            switch model.state {
            case .review:
                Button("Cancel") { model.cancelReview() }.disabled(runtime.isActive)
                Spacer()
                Button("Choose Destination…", action: chooseDestination).buttonStyle(.borderedProminent).disabled(!model.canCreate)
            case .confirmation:
                Button("Back") { model.editSelection() }.disabled(runtime.isActive)
                Spacer()
                Button("Create Saved Environment") { model.create() }.buttonStyle(.borderedProminent).disabled(runtime.isActive)
            case .scanning, .preparing, .saving:
                Spacer()
                Button("Cancel", role: .cancel) { model.cancel() }.disabled(runtime.stopping)
            case .result:
                if let saved = model.publication {
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: saved.destination)]) }
                }
                Spacer()
                Button("Capture Again") { model.scan() }.disabled(runtime.isActive)
            case .failed, .cancelled:
                Button("Scan Again") { model.scan() }.disabled(runtime.isActive)
            case .idle: EmptyView()
            }
        }
    }
    private func chooseDestination() {
        let panel = NSSavePanel()
        panel.title = "Save Environment"
        panel.prompt = "Choose Destination"
        panel.message = "Choose a file. Confirm Replace to replace an existing saved environment."
        panel.nameFieldStringValue = "Saved Environment"
        panel.allowedContentTypes = [UTType(filenameExtension: "mbt", conformingTo: .data)!]
        panel.allowsOtherFileTypes = false
        panel.isExtensionHidden = false
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window) { response in
                if response == .OK, let url = panel.url { model.prepare(destination: url, replacementConfirmed: CaptureDestination.normalized(url) == url) }
            }
        } else {
            panel.begin { response in if response == .OK, let url = panel.url { model.prepare(destination: url, replacementConfirmed: CaptureDestination.normalized(url) == url) } }
        }
    }
}
