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
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) { categoryTitle; Spacer(); categoryStatus }
                        VStack(alignment: .leading, spacing: 6) { categoryTitle; categoryStatus }
                    }
                }
                .disclosureGroupStyle(TaskDisclosureStyle())
            }
            if expanded {
                Text("Supported settings only").font(.caption).foregroundStyle(.secondary)
                    .padding(.leading, CaptureChildRowGrid.leadingInset)
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
                                if category.row.status == "observation_error" {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.orange).accessibilityLabel("Needs Attention")
                                }
                            } else if !category.notices.isEmpty {
                                Label("Needs Attention", systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                            } else {
                                Text(model.selectionState(category).captureTitle).font(.callout.weight(.medium))
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
    private var categoryTitle: some View {
        HStack(spacing: 12) {
            Image(systemName: "slider.horizontal.3").frame(width: TaskRowLayout.iconWidth).accessibilityHidden(true)
            Text("macOS Settings").font(.body.weight(.medium))
        }
    }
    private var categoryStatus: some View {
        VStack(alignment: .leading, spacing: 3) {
            if model.macOSSettings.hasAttention { TaskStatusLabel(state: .attention) }
            else { Text(model.macOSSettings.state.captureTitle).font(.callout.weight(.medium)) }
            Text(model.macOSSettings.summary).font(.caption).foregroundStyle(.secondary)
        }.frame(width: TaskRowLayout.statusWidth, alignment: .leading)
    }

}

struct CaptureView: View {
    @ObservedObject var model: CaptureModel
    @ObservedObject var runtime: CoreRuntime
    var showsActions = true
    private var progressText: String {
        if runtime.stopping { return "Stopping Capture…" }
        switch runtime.currentPhase {
        case "discovery": return model.state == .saving ? "Rechecking selected environment…" : "Scanning supported environment…"
        case "validation": return "Checking selected environment…"
        case "bundle_creation": return "Creating Saved Environment…"
        default: return model.state == .scanning ? "Starting scan…" : "Preparing selected environment…"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            switch model.state {
            case .idle:
                WorkspacePrimaryActionCard(title: "Scan This Mac", symbol: ProductTask.capture.symbol, tint: WorkspaceIdentity.tint(.capture),
                    message: "Scan supported settings and tools, then choose what to carry to another Mac.",
                    notice: "Scanning does not change settings or install anything on this Mac.") {
                    Button("Scan This Mac") { model.scan() }.buttonStyle(.borderedProminent).disabled(runtime.isActive)
                }
            case .scanning:
                Text("Scanning this Mac").font(.title.weight(.bold)).accessibilityAddTraits(.isHeader)
                HStack(spacing: 12) {
                    ProgressView()
                    Text(progressText).foregroundStyle(.secondary)
                }
            case .preparing:
                Text("Checking Your Environment").font(.title.weight(.bold)).accessibilityAddTraits(.isHeader)
                HStack(spacing: 12) {
                    ProgressView()
                    Text(progressText).foregroundStyle(.secondary)
                }
            case .saving:
                Text("Saving Your Environment").font(.title.weight(.bold)).accessibilityAddTraits(.isHeader)
                HStack(spacing: 12) {
                    ProgressView()
                    Text(progressText).foregroundStyle(.secondary)
                }
                if model.state == .saving {
                    Text("Once saving begins, stopping does not promise that a published file will be removed.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            case .review:
                let rows = CaptureReviewRow.project(model.categories)
                HStack {
                    Text("Review and select").font(.headline)
                    Spacer()
                    Button(model.bulkState.bulkActionTitle) { model.toggleAll() }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .disabled(!model.categories.contains(where: \.selectable) || runtime.isActive)
                }
                CaptureReviewMetrics(summary: selectionSummary)
                VStack(spacing: 0) {
                    ForEach(rows) { row in
                        if row.id == "macos-settings" {
                            CaptureMacOSSettingsView(model: model)
                        } else if let category = row.categories.first {
                            CaptureCategorySelectionView(model: model, category: category)
                        }
                        if row.id != rows.last?.id { Divider() }
                    }
                }.background(.background, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
                    .id(model.operationID)
                CaptureSecureTransferView()
                if !model.canCreate { Text("Choose supported state to capture.").foregroundStyle(.secondary) }
            case .confirmation:
                if let prepared = model.preparation, let selection = prepared.selection {
                    Text("Save this environment?").font(.title2.weight(.bold)).accessibilityAddTraits(.isHeader)
                    Text("Review the final capture before creating the saved environment.").font(.callout).foregroundStyle(.secondary)
                    if let destination = model.destination {
                        CaptureBundleLocationView(destination: destination)
                            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                    }
                    if !model.confirmationWarnings.isEmpty {
                        Label(model.confirmationWarnings.map(\.title).joined(separator: ", ") + " needs attention",
                              systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.orange)
                    }
                    Text("The saved settings are private but unencrypted. Private SSH identities are not included.")
                        .font(.callout).foregroundStyle(.secondary)
                    TaskDomainList(domains: CaptureTaskPresentation(categories: prepared.inventory.map { CaptureCategory(row: $0) },
                        selection: selection, phase: .confirmation).domains, stateTitles: [.planned: "Ready to Save"], compactReadyItems: true, title: "Included in this capture")
                }
            case .result:
                if let saved = model.publication {
                    Text("Environment Saved").font(.title2.weight(.bold)).accessibilityAddTraits(.isHeader)
                    Text(model.resultNotices.isEmpty ? "Your environment was saved." : "Your environment was saved. Review the captured categories with limitations.")
                        .font(.callout).foregroundStyle(.secondary)
                    CaptureSavedMetrics(publication: saved, notices: model.resultNotices)
                    CaptureBundleLocationView(destination: URL(fileURLWithPath: saved.destination))
                        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                    if let prepared = model.preparation, let selection = prepared.selection {
                        TaskDomainList(domains: CaptureTaskPresentation(categories: prepared.inventory.map { CaptureCategory(row: $0) },
                            selection: selection, phase: .result, publication: saved, notices: model.resultNotices).domains,
                            compactReadyItems: true, title: "Captured Environment")
                    }
                }
            case .failed, .cancelled:
                if model.state == .failed, let failure = model.failure, failure.isOutdatedPreparation {
                    Text(failure.presentationTitle).font(.title2.weight(.bold)).accessibilityAddTraits(.isHeader)
                } else {
                    Label(model.state == .cancelled ? "Capture Cancelled" : "Needs Attention",
                          systemImage: model.state == .cancelled ? "stop.circle" : "exclamationmark.triangle")
                        .font(.title2).foregroundStyle(model.state == .cancelled ? Color.secondary : Color.orange)
                }
                if let failure = model.failure {
                    if failure.isOutdatedPreparation {
                        Text(failure.presentationMessage).font(.callout).foregroundStyle(.secondary)
                    } else {
                        Text(failure.message)
                    }
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
                Button("Choose Destination…", action: chooseDestination).buttonStyle(.borderedProminent).disabled(!model.canCreate || runtime.isActive)
            case .confirmation:
                Button("Back") { model.editSelection() }.disabled(runtime.isActive)
                Spacer()
                Button("Create Saved Environment") { model.create() }.buttonStyle(.borderedProminent).disabled(runtime.isActive)
            case .scanning:
                Button("Cancel", role: .cancel) { model.cancel() }.disabled(runtime.stopping)
                Spacer()
            case .preparing, .saving:
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
