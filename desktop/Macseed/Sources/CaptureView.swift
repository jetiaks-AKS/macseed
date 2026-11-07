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

// Six independent Core categories; the shared accordion owns their parent header.
struct CaptureMacOSSettingsView: View {
    @ObservedObject var model: CaptureModel
    var editable = true
    var childExpansion: Binding<Bool>? = nil
    var treeExpansion: Binding<Set<String>>? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Supported settings only").font(.caption).foregroundStyle(.secondary)
                .padding(.leading, 16 + CaptureChildRowGrid.leadingInset + (editable ? CaptureReviewPresentation.hierarchyStep : 0))
            ForEach(model.macOSSettings.children.filter { editable || model.selectionState($0) != .none }) { category in
                CaptureSettingsSubcategoryView(model: model, category: category, editable: editable,
                    expansion: treeExpansion.map { WorkflowExpansion.binding(category.id, in: $0) } ?? childExpansion)
            }.padding(.leading, 16 + (editable ? CaptureChildRowGrid.leadingInset : 0)).padding(.trailing, 16)
        }
    }
}

struct CaptureView: View {
    @ObservedObject var model: CaptureModel
    @ObservedObject var runtime: CoreRuntime
    var showsActions = true
    var categoryTreeExpansion: Binding<Set<String>>? = nil
    var experiencedVisibility: Binding<Bool>? = nil
    @CaptureViewState private var experiencedVisible = false
    @CaptureViewState<Set<String>> private var expandedCategories = CaptureHierarchy.initialExpansion
    private var treeExpansion: Binding<Set<String>> { categoryTreeExpansion ?? $expandedCategories }
    private var experiencedExpansion: Binding<Bool> { experiencedVisibility ?? $experiencedVisible }
    private var progressText: String {
        if runtime.stopping { return "Stopping Capture…" }
        if runtime.secureChallenge != nil { return "Waiting for secure input…" }
        switch runtime.currentPhase {
        case "discovery": return model.state == .saving ? "Rechecking selected environment…" : "Scanning supported environment…"
        case "validation": return "Checking selected environment…"
        case "bundle_creation": return "Creating Saved Environment…"
        case "secure_packaging": return "Validating and encrypting selected SSH identities…"
        default: return model.state == .scanning ? "Starting scan…" : "Preparing selected environment…"
        }
    }
    @Environment(\.workflowListViewport) private var pinnedList
    var body: some View {
        VStack(alignment: .leading, spacing: pinnedList ? 12 : 20) {
            switch model.state {
            case .idle:
                WorkspacePrimaryActionCard(title: "Scan This Mac", symbol: ProductTask.capture.symbol, tint: WorkspaceIdentity.tint(.capture),
                    message: "Scan supported settings and tools, then choose what to carry to another Mac.",
                    notice: "Scanning does not change settings or install anything on this Mac.") {
                    Button("Scan This Mac") { model.scan() }.buttonStyle(.borderedProminent).disabled(runtime.isActive)
                }
            case .scanning:
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .center, spacing: 16) {
                        ProgressView().controlSize(.large)
                            .frame(width: 40, height: 40).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Scanning this Mac").font(.title2.weight(.bold))
                                .accessibilityAddTraits(.isHeader)
                            Text(progressText).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                    Label("Read-only scan — no changes will be made to this Mac.", systemImage: "checkmark.shield")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
            case .preparing:
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .center, spacing: 16) {
                        ProgressView().controlSize(.large)
                            .frame(width: 40, height: 40).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Checking Your Environment").font(.title2.weight(.bold))
                                .accessibilityAddTraits(.isHeader)
                            Text(progressText).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
            case .saving:
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .center, spacing: 16) {
                        ProgressView().controlSize(.large)
                            .frame(width: 40, height: 40).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Saving Your Environment").font(.title2.weight(.bold))
                                .accessibilityAddTraits(.isHeader)
                            Text(progressText).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                    Text("Once saving begins, stopping does not promise that a published file will be removed.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
            case .review:
                let rows = CaptureReviewRow.project(model.categories)
                CaptureReviewMetrics(summary: selectionSummary)
                Text("Review and select").font(.headline).accessibilityAddTraits(.isHeader)
                WorkflowList {
                    CaptureGroupedContent(rows: rows, expanded: treeExpansion,
                        selection: { group, _ in
                            guard (CaptureHierarchy.ordinaryGroups + [.advanced]).contains(group) else { return nil }
                            return AnyView(CaptureGroupControls(model: model, group: group))
                        }, vscodeSelection: AnyView(CaptureGroupControls(model: model, group: .vscode, subgroup: true)),
                        ordinaryTitle: "Standard Setup",
                        ordinaryControls: AnyView(CaptureExpandButton(ids: disclosureIDs(in: .ordinary), title: "Standard Setup", expanded: treeExpansion)),
                        advancedControls: AnyView(CaptureExpandButton(ids: disclosureIDs(in: .advanced), title: "For Experienced Users", expanded: treeExpansion)),
                        experiencedVisibility: experiencedExpansion,
                        hiddenSelectionSummary: CaptureReviewPresentation.experiencedSelectionSummary(model),
                        secureTransferGroup: AnyView(CaptureSecureTransferView(inventory: model.secureInventory, selected: model.selectedSecureIdentities,
                            editable: !runtime.isActive, select: { model.selectSecureIdentity($0, included: $1) },
                            selectAll: { model.selectAllSecureIdentities(included: $0) },
                            expansion: WorkflowExpansion.binding(CaptureHierarchy.secureTransferID, in: treeExpansion),
                            addIdentity: chooseSSHIdentity, removeIdentity: model.removeSSHIdentity,
                            manualIDs: model.manualIdentityIDs, checkingIdentity: model.addingIdentity,
                            identityError: model.identityError, cancelIdentity: model.cancel)),
                        summary: { CaptureReviewPresentation.summary($0.flatMap(\.categories), model: model) },
                        attention: { CaptureReviewPresentation.attention($0.flatMap(\.categories), model: model) }) { row in
                        if row.id == "macos-settings" {
                            CaptureMacOSSettingsView(model: model, treeExpansion: treeExpansion)
                        } else if let category = row.categories.first {
                            CaptureCategorySelectionView(model: model, category: category,
                                expansion: WorkflowExpansion.binding(row.id, in: treeExpansion),
                                displayTitle: CaptureHierarchy.title(category.id, fallback: category.title),
                                leadingInset: CaptureChildRowGrid.leadingInset,
                                hierarchyIndent: CaptureReviewPresentation.hierarchyStep * (CaptureHierarchy.group(for: category.id) == .vscode ? 2 : 1))
                        }
                    }
                    if !model.canCreate { Text("Choose supported state to capture.").foregroundStyle(.secondary) }
                }
            case .confirmation:
                if let prepared = model.preparation, let selection = prepared.publicationSelection {
                    Text("Save this environment?").font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                    Text("Review the final capture before creating the saved environment.").font(.callout).foregroundStyle(.secondary)
                    if let duplicates = prepared.applicationDuplicates, !duplicates.isEmpty {
                        Text("Confirmed duplicate applications will be saved as Homebrew requirements. Your original selection is retained.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if let destination = model.destination {
                        CaptureBundleLocationView(destination: destination)
                            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                    }
                    if !model.confirmationWarnings.isEmpty {
                        Label(model.confirmationWarnings.map { CaptureHierarchy.title($0.id, fallback: $0.title) }.joined(separator: ", ") + " needs attention",
                              systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.orange)
                    }
                    Text(selection.secureIdentities.isEmpty
                         ? "The saved settings are private but unencrypted. Private SSH identities are not included."
                         : "Selected SSH identities will be encrypted separately with a new Bundle passphrase. Other saved settings remain private but unencrypted. Keep the passphrase separate from the saved environment.")
                        .font(.callout).foregroundStyle(.secondary)
                    if let explanation = model.externalDestinationExplanation {
                        Text(explanation).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    let tasks = CaptureTaskPresentation(categories: prepared.inventory.map { CaptureCategory(row: $0) }, selection: selection,
                        phase: .confirmation, secureIdentities: prepared.secureIdentities.items)
                    TaskDomainList(domains: tasks.domains, stateTitles: [.planned: "Ready to Save"], compactReadyItems: true, title: "Included in this capture",
                        captureHierarchy: true, settingsCategories: CaptureSettingsPresentation.children(tasks.domains),
                        settingLabels: CaptureSettingsPresentation.labels(prepared.inventory),
                        expansion: treeExpansion)
                }
            case .result:
                if let result = model.resultPresentation { CaptureResultContent(result: result) }
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
                }
                if let destination = model.destination {
                    if model.savingAttempted {
                        switch model.publicationEvidence {
                        case .occurred: Text("Publication was reported, but Capture did not complete successfully. Check the destination before another attempt.")
                        case .unknown: Text("Publication could not be confirmed. A file or temporary state may remain. Check the destination before another attempt.")
                        case .notOccurred: Text("No completed publication was reported.")
                        }
                    }
                    Text(destination.path).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            if showsActions { CaptureActionsView(model: model, runtime: runtime) }
        }.modifier(OperationLogPresenter(runtime: runtime))
            .sheet(item: Binding(get: { runtime.operationID == model.operationID ? runtime.secureChallenge : nil }, set: { _ in })) { challenge in
                CaptureSecureInputView(runtime: runtime, challenge: challenge).id(challenge.id)
                    .interactiveDismissDisabled()
            }
            .onChange(of: model.state) { _, state in
                if state == .scanning {
                    treeExpansion.wrappedValue = CaptureHierarchy.initialExpansion
                    experiencedExpansion.wrappedValue = false
                }
            }
    }
    private var selectionSummary: CaptureSummaryPresentation {
        CaptureSummaryPresentation.review(categories: model.state == .review ? model.categories : model.categories.filter { model.selectionState($0) != .none }, domainCount: model.selectedDomainCount, itemCount: model.selectedItemCount,
            selectedDomains: Set(model.selection.categories).union(model.selection.items.keys), secureIdentityCount: model.selectedSecureIdentities.count)
    }
    private func chooseSSHIdentity() {
        let panel = NSOpenPanel()
        panel.title = "Add SSH Identity"
        panel.prompt = "Add Identity"
        panel.message = "Choose a private SSH key with its matching .pub file. It will be added unchecked and restored into ~/.ssh by default using its name."
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.canCreateDirectories = false; panel.allowsMultipleSelection = false
        panel.resolvesAliases = false; panel.showsHiddenFiles = true
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window) { response in
                if response == .OK, let url = panel.url { model.addSSHIdentity(url) }
            }
        } else {
            panel.begin { response in if response == .OK, let url = panel.url { model.addSSHIdentity(url) } }
        }
    }
    private func disclosureIDs(in scope: CaptureSelectionScope) -> Set<String> {
        CaptureHierarchy.disclosureIDs(model.categories.map(\.id) + [CaptureHierarchy.secureTransferID], scope: scope)
            .subtracting(model.categories.filter { !CaptureCategorySelectionView.hasDisclosure($0) }.map(\.id))
    }
}

// Transient view-owned input only: never published in a model, event or log.
struct CaptureSecureEntry {
    var passphrase = ""
    var confirmation = ""
    func valid(for kind: CoreSecureChallenge.Kind) -> Bool {
        [.bundleEncrypt, .bundleUnlock, .sshKeyUnlock].contains(kind)
            && (1...CoreSecureTransport.maximumSecret).contains(passphrase.utf8.count)
            && !passphrase.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
            && (kind != .bundleEncrypt || passphrase == confirmation)
    }
    mutating func clear() { passphrase = ""; confirmation = "" }
    mutating func consume(for kind: CoreSecureChallenge.Kind) -> CoreSecureResponse? {
        guard valid(for: kind) else { return nil }
        defer { clear() }
        return .secret(Data(passphrase.utf8))
    }
}

struct CaptureSecureInputView: View {
    @ObservedObject var runtime: CoreRuntime
    let challenge: CoreSecureChallenge
    var restoring = false
    var comparing = false
    var customizing = false
    @CaptureViewState private var entry = CaptureSecureEntry()
    private var encrypting: Bool { challenge.kind == .bundleEncrypt }
    private var confirmingImport: Bool { challenge.kind == .importConfirmation }
    private var title: String {
        if confirmingImport { return "Import SSH Identities?" }
        return encrypting ? "Encrypt SSH Identities" : challenge.kind == .bundleUnlock ? "Unlock SSH Identities" : "Unlock SSH Key"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
            if challenge.kind == .sshKeyUnlock, let identity = challenge.identity {
                VStack(alignment: .leading, spacing: 4) {
                    Text(identity.name).font(.callout.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(identity.typeLabel + " · " + identity.fingerprint).font(.caption.monospaced())
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let position = identity.position, let total = identity.total {
                        Text("Identity \(position) of \(total)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Text(confirmingImport ? "Import the validated encrypted SSH identity package? Existing identities will not be overwritten. This confirmation is required before import."
                 : challenge.kind == .bundleUnlock ? "Enter the Bundle passphrase created when capturing this environment. It unlocks the encrypted Secure Transfer package."
                 : encrypting
                 ? "Choose a new Bundle passphrase for the encrypted SSH identities. Other saved settings are not encrypted."
                 : "Enter the existing passphrase for this SSH key. It verifies this protected identity; it is separate from the Bundle passphrase. The key keeps its original encryption.")
                .font(.callout).foregroundStyle(.secondary)
            if challenge.attempt > 1 {
                Text("The previous passphrase was not accepted. Attempt \(challenge.attempt) of 3.")
                    .font(.callout).foregroundStyle(.orange)
            }
            if !confirmingImport {
                SecureField(encrypting ? "Bundle encryption passphrase" : challenge.kind == .bundleUnlock ? "Bundle passphrase" : "SSH-key passphrase", text: $entry.passphrase)
                    .accessibilityIdentifier("capture.secure.passphrase")
                if encrypting {
                    SecureField("Confirm Bundle passphrase", text: $entry.confirmation)
                        .accessibilityIdentifier("capture.secure.confirmation")
                }
                Text("Up to 128 UTF-8 bytes. Input expires after 120 seconds.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button(customizing ? "Cancel Unlock" : comparing ? "Cancel Preview" : restoring ? "Cancel Rebuild" : "Cancel Capture", role: .cancel) { entry.clear(); runtime.cancelSecureChallenge(challenge) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(confirmingImport ? "Import SSH Identities" : encrypting ? "Encrypt" : "Unlock") {
                    if confirmingImport { entry.clear(); runtime.respond(to: challenge, with: .confirmImport); return }
                    guard let response = entry.consume(for: challenge.kind) else { return }
                    runtime.respond(to: challenge, with: response)
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled((!confirmingImport && !entry.valid(for: challenge.kind)) || runtime.secureChallenge != challenge || runtime.stopping)
            }
        }.padding(24).frame(width: 440)
            .onChange(of: runtime.secureChallenge) { _, current in if current != challenge { entry.clear() } }
            .onDisappear { entry.clear(); runtime.cancelSecureChallenge(challenge) }
    }
}

struct CaptureGroupControls: View {
    @ObservedObject var model: CaptureModel
    let group: CaptureHierarchy.Group
    var subgroup = false
    var body: some View {
        let categories = CaptureReviewPresentation.bulkCategories(model.categories, group: group)
        let state = model.bulkState(for: categories)
        NativeSelectionCheckbox("", state: state, accessibilityTitle: "Select " + (subgroup ? group.title : group.section.title)) { _ in
            model.toggleCategories(categories)
        }.disabled(!categories.contains(where: \.selectable) || model.state != .review || model.runtime.isActive)
            .accessibilityIdentifier("capture.controls." + (subgroup ? group.id : group.section.id))
    }
}

struct CaptureBundleLocationView: View {
    let destination: URL
    var showsReveal = false
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Label(destination.lastPathComponent, systemImage: "shippingbox").font(.headline)
                Text(destination.path).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if showsReveal {
                Spacer()
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([destination]) }
            }
        }
    }
}

struct CaptureActionsView: View {
    @ObservedObject var model: CaptureModel
    @ObservedObject var runtime: CoreRuntime
    var body: some View {
        HStack {
            if let reference = runtime.operationLogReference(matching: model.operationID),
               OperationLogVisibility.capture(model.state, active: runtime.isActive, reference: reference, failure: model.failure, terminal: !runtime.isActive) {
                OperationLogButton(runtime: runtime, reference: reference)
            } else if [.result, .failed, .cancelled].contains(model.state), !runtime.isActive {
                Text("Log unavailable").font(.caption).foregroundStyle(.secondary)
            }
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
                Button("Cancel", role: .cancel) { model.cancel() }.disabled(runtime.stopping)
                Spacer()
            case .result:
                Spacer()
                Button("Capture Again") { model.scan() }.disabled(runtime.isActive)
                Button("Done") { model.done() }.disabled(runtime.isActive)
            case .failed, .cancelled:
                if model.canReviewSelection {
                    Button("Review Selection") { model.editSelection() }.disabled(runtime.isActive)
                }
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
