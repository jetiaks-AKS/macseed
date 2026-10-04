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
                        Text(group.summary).font(.callout).foregroundStyle(.secondary)
                        if group.hasAttention {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange).accessibilityLabel("Needs Attention")
                        }
                    }
                }
                .disclosureGroupStyle(HeaderDisclosureStyle())
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
                            DisclosureGroup("Technical reason") {
                                Text(reason).font(.caption.monospaced()).textSelection(.enabled)
                            }.disclosureGroupStyle(HeaderDisclosureStyle())
                        }
                    }.padding(.vertical, 4)
                }.padding(.leading, editable ? CaptureChildRowGrid.leadingInset : 0)
            }
        }.padding(.vertical, 7)
    }
}

struct CaptureView: View {
    @ObservedObject var model: CaptureModel
    @ObservedObject var runtime: CoreRuntime
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
                ProgressView(progressText)
                Button("Cancel", role: .cancel) { model.cancel() }.disabled(runtime.stopping)
                if model.state == .saving {
                    Text("Once saving begins, stopping does not promise that a published file will be removed.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            case .review:
                HStack {
                    Text("Review and select").font(.title2)
                    Spacer()
                    Button(model.bulkState.bulkActionTitle) { model.toggleAll() }
                        .disabled(!model.categories.contains(where: \.selectable) || runtime.isActive)
                }
                Text("Ordinary settings are private but unencrypted. Only supported reproducible state is included.")
                    .font(.callout).foregroundStyle(.secondary)
                ForEach(model.categories) { category in
                    if CaptureMacOSSettingsGroup.domainIDs.contains(category.id) {
                        if category.id == model.categories.first(where: { CaptureMacOSSettingsGroup.domainIDs.contains($0.id) })?.id {
                            CaptureMacOSSettingsView(model: model)
                        }
                    } else {
                        CategoryRow(category: category.display,
                                    captureState: category.selectable ? model.selectionState(category) : nil,
                                    selectCategory: category.selectable ? { model.selectCategory(category.id, included: $0) } : nil,
                                    itemSelected: category.itemSelectable ? { model.selectedItems[category.id]?.contains($0) == true } : nil,
                                    selectItem: category.itemSelectable ? { model.selectItem(category.id, item: $0, included: $1) } : nil,
                                    headerSummary: category.headerSummary, categoryDetails: category.notices)
                    }
                }.id(model.operationID)
                Text(model.selectionSummary).font(.callout).foregroundStyle(.secondary)
                Divider()
                Label("Secure Transfer", systemImage: "lock.shield").font(.headline)
                Text("Private SSH identity transfer is not available in this build. No private SSH identities will be captured.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("Choose Destination…", action: chooseDestination).buttonStyle(.borderedProminent).disabled(!model.canCreate)
                    Button("Cancel") { model.cancelReview() }.disabled(runtime.isActive)
                }
                if !model.canCreate { Text("Choose supported state to capture.").foregroundStyle(.secondary) }
            case .confirmation:
                Text("Save this environment?").font(.title2)
                Text("Review the final capture before creating the saved environment.")
                    .foregroundStyle(.secondary)
                if let destination = model.destination {
                    Label(destination.lastPathComponent, systemImage: "shippingbox")
                    Text(destination.deletingLastPathComponent().path).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Text(model.confirmationSummary)
                Text("The saved settings are private but unencrypted. Private SSH identities are not included.")
                    .font(.callout).foregroundStyle(.secondary)
                Text("Included").font(.headline)
                ForEach(model.confirmationAreas) { area in
                    HStack {
                        Text(area.title)
                        Spacer()
                        Text(area.content).foregroundStyle(.secondary)
                        if area.requiresAttention {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange).accessibilityLabel("Needs Attention")
                        }
                    }
                }
                if !model.confirmationWarnings.isEmpty {
                    let count = model.confirmationWarnings.count
                    Label("\(count) \(count == 1 ? "area needs" : "areas need") attention", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    ForEach(model.confirmationWarnings) { category in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(category.title).font(.headline)
                            Text("Some supported state may be unavailable.").foregroundStyle(.secondary)
                            if let reason = category.row.reason {
                                DisclosureGroup("Technical reason") {
                                    Text(reason).font(.caption.monospaced()).textSelection(.enabled)
                                }.disclosureGroupStyle(HeaderDisclosureStyle())
                            }
                        }
                    }
                }
                HStack {
                    Button("Create Saved Environment") { model.create() }.buttonStyle(.borderedProminent).disabled(runtime.isActive)
                    Button("Back") { model.editSelection() }.disabled(runtime.isActive)
                }
            case .result:
                if let saved = model.publication {
                    Label("Environment Saved", systemImage: "checkmark.circle").font(.title2)
                    let path = URL(fileURLWithPath: saved.destination)
                    Text(path.lastPathComponent).font(.headline)
                    Text(path.path).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    Text("\(saved.bundle.capturedDomains.count) \(saved.bundle.capturedDomains.count == 1 ? "area" : "areas")"
                         + " · \(saved.bundle.itemCount) \(saved.bundle.itemCount == 1 ? "item" : "items") captured")
                    if !model.resultNotices.isEmpty {
                        Label("Needs Attention", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        ForEach(model.resultNotices) { category in CategoryRow(category: category) }
                    }
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([path]) }
                }
                Button("Capture Again") { model.scan() }.disabled(runtime.isActive)
            case .failed, .cancelled:
                Label(model.state == .cancelled ? "Capture Cancelled" : "Needs Attention",
                      systemImage: model.state == .cancelled ? "stop.circle" : "exclamationmark.triangle")
                    .font(.title2).foregroundStyle(model.state == .cancelled ? Color.secondary : Color.orange)
                if let failure = model.failure {
                    Text(failure.message)
                    if let reason = failure.technicalReason {
                        DisclosureGroup("Technical reason") { Text(reason).font(.caption.monospaced()).textSelection(.enabled) }
                            .disclosureGroupStyle(HeaderDisclosureStyle())
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
                Button("Scan Again") { model.scan() }.disabled(runtime.isActive)
            }
            Text("Capture does not rebuild or change settings on this Mac.").font(.callout).foregroundStyle(.secondary)
        }
    }

    private func chooseDestination() {
        let panel = NSSavePanel()
        panel.title = "Save Environment"
        panel.prompt = "Choose Destination"
        panel.message = "Choose a new file. Existing saved environments are never replaced."
        panel.nameFieldStringValue = "Saved Environment"
        panel.allowedContentTypes = [UTType(filenameExtension: "mbt", conformingTo: .data)!]
        panel.allowsOtherFileTypes = false
        panel.isExtensionHidden = false
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window) { response in
                if response == .OK, let url = panel.url { model.prepare(destination: url) }
            }
        } else {
            panel.begin { response in if response == .OK, let url = panel.url { model.prepare(destination: url) } }
        }
    }
}
