import Combine
import Foundation
import CryptoKit
import Darwin

enum CaptureFlowState { case idle, scanning, review, preparing, confirmation, saving, result, failed, cancelled }
enum CapturePublicationEvidence { case notOccurred, occurred, unknown }

enum CaptureFailure: Error, Equatable {
    case invalidEvidence, invalidDestination, emptySelection, cancelled, interrupted
    case runtime(CoreRuntimeError)
    var message: String {
        switch self {
        case .invalidEvidence: "The scan results are incomplete. Scan this Mac again before saving."
        case .invalidDestination: "Choose a new .mbt file in an accessible folder. Existing saved environments require explicit Replace confirmation."
        case .emptySelection: "Choose supported state to capture."
        case .cancelled: "Capture cancelled. Scan this Mac again before another attempt."
        case .interrupted: "Capture interrupted. Scan this Mac again before another attempt."
        case .runtime(.coreFailure(let code)):
            switch code {
            case "stale_prepared_capture", "capture_source_unavailable", "invalid_selection":
                "The Mac or selected state changed. Scan this Mac again, review the new selection and confirm it."
            case "invalid_destination": "The destination is unavailable or changed since Replace was confirmed. Scan again and choose a new file."
            case "capture_discovery_failed", "capture_inventory_invalid": "Couldn’t finish scanning this Mac. Scan again before saving."
            case "capture_validation_failed": "The selected environment could not be validated for saving. Scan again and review the selection."
            case "invalid_workspace_selection": "The Workspace selection could not be validated. Scan again and review the selected folders and repositories."
            case "workspace_dependency_missing": "A selected workspace descriptor or checkout needs its folders and base or parent repositories selected. Review Selection and include those dependencies, or deselect the dependent item."
            case "workspace_path_conflict": "Selected Workspace paths conflict or use ambiguous aliases. Review the selection and deselect the conflicting items before trying again."
            case "external_identity_unsafe", "external_identity_pair_missing", "external_identity_pair_invalid", "external_identity_name_invalid", "external_identity_invalid_request", "external_identity_changed":
                "A manually added SSH pair is missing, unsafe or changed. Scan again and add a supported matching private/public pair."
            case "external_identity_duplicate": "An SSH identity or destination name is duplicated. Review the selected pairs."
            case "invalid_secure_selection": "The selected SSH identities are no longer available. Scan again and review the selection."
            case "secure_bridge_required", "secure_bridge_unavailable": "Secure Capture is unavailable in this session. Review the SSH identity selection."
            case "age_unavailable": "The bundled Secure Transfer tool is missing or damaged. Rebuild or reinstall Macseed, then try again."
            case "secure_timeout", "secure_channel_timeout": "Secure input timed out. Scan again before another attempt."
            case "secure_key_unlock_rejected": "The SSH key could not be unlocked within Core's attempt limit. Scan again before another attempt."
            case "secure_export_failed", "secure_input_invalid", "secure_channel_invalid", "secure_tool_failed", "secure_payload_invalid":
                "Secure Capture could not complete. Review the SSH identity selection before trying again."
            default: "Capture could not complete. Scan this Mac again before another attempt."
            }
        case .runtime(.runtimeUnavailable), .runtime(.pythonUnavailable), .runtime(.invalidRuntimeConfiguration), .runtime(.writableCoreRequired):
            "Capture is unavailable in this build. Check the app setup before scanning again."
        case .runtime(.requestTooLarge):
            "The item selection is too large to save in this build. Scan again and choose whole categories or a smaller item selection."
        case .runtime(.secureChannelTimeout): "Secure input timed out. Scan again before another attempt."
        case .runtime(.secureChannelInvalid), .runtime(.secureChannelDisconnected):
            "The secure connection failed. Scan again before another attempt."
        case .runtime: "Capture communication failed. Scan this Mac again before another attempt."
        }
    }
    var technicalReason: String? {
        if case .runtime(.coreFailure(let code)) = self,
           OperationLogSanitizer.reasons.contains(code) { return code }
        return nil
    }
    var isWorkspaceSelectionConflict: Bool {
        if case .runtime(.coreFailure(let code)) = self {
            return ["workspace_dependency_missing", "workspace_path_conflict"].contains(code)
        }
        return false
    }
}

struct CaptureCategory: Identifiable {
    let row: CoreCaptureInventoryRow
    var id: String { row.domain }
    var selectable: Bool { row.status == "present" && (["items", "category"].contains(row.selectionMode)) && (row.selectionMode == "category" || !row.items.isEmpty) }
    var itemSelectable: Bool { selectable && row.selectionMode == "items" }
    var title: String { Self.title(for: id) }
    static func title(for domain: String) -> String {
        let names = ["homebrew-packages": "Homebrew Packages", "homebrew-casks": "Homebrew Applications", "app-store": "App Store Applications",
                     "vscode-extensions": "VS Code Extensions", "vscode-settings": "VS Code Settings", "git-configuration": "Git Configuration",
                     "git-repositories": "Git Repositories", "vscode-workspaces": "VS Code Workspaces", "workspace-folders": "Workspace Folders", "ssh-configuration": "SSH Configuration",
                     "shell-zsh": "Shell Configuration", "macos-finder": "Finder", "macos-dock": "Dock", "macos-windows": "Windows",
                     "macos-keyboard": "Keyboard", "macos-trackpad": "Trackpad", "macos-screenshots": "Screenshots"]
        return names[domain] ?? domain
    }
    var symbol: String {
        switch id {
        case "homebrew-packages": "shippingbox"
        case "homebrew-casks", "app-store": "app"
        case "workspace-folders", "git-repositories", "vscode-workspaces": "folder"
        case "ssh-configuration": "key"
        case "shell-zsh": "terminal"
        default: "slider.horizontal.3"
        }
    }
    var headerSummary: String {
        if row.status == "observation_error" { return "Needs Attention" }
        if !["items", "category"].contains(row.selectionMode) { return "Not Supported" }
        if row.status != "present" { return row.status == "observation_error" ? "Needs Attention" : (row.status == "unsupported" ? "Not Supported" : "Unavailable") }
        return row.selectionMode == "items" ? "\(row.items.count) \(row.items.count == 1 ? "item" : "items")" : "Whole category"
    }
    var display: DisplayCategory {
        let items: [DisplayItem]
        if itemSelectable {
            items = row.items.map { item in
                DisplayItem(id: item.itemID, title: item.label.hasPrefix("opaque:") ? "Private item" : item.label,
                            status: .ready, action: "Supported state available to save.")
            }
        } else {
            let status: DisplayStatus = row.status == "observation_error" ? .unverified : (row.status == "unsupported" || !["category", "items"].contains(row.selectionMode) ? .unsupported : (selectable ? .ready : .information))
            let action: String = selectable ? "Included as a whole category. Individual settings are not separately selectable."
                : (row.status == "observation_error" ? "Couldn’t read this category. It cannot be selected."
                    : (row.status == "unsupported" ? "This state is not supported for capture." : "No selectable state is available for this category."))
            items = [DisplayItem(id: "category-state:" + id, title: title, status: status, action: action, reason: row.reason)]
        }
        return DisplayCategory(id: id, title: title, symbol: symbol, items: items)
    }
    var notices: [DisplayItem] {
        guard selectable, let reason = row.reason else { return [] }
        return [DisplayItem(id: "category-warning:" + id, title: "Needs Attention", status: .attention,
                            action: "Some supported state may be unavailable in this category.", reason: reason)]
    }
}

struct CaptureConfirmationArea: Identifiable {
    let id: String
    let title: String
    let content: String
    let requiresAttention: Bool
}

// Destination naming belongs to Desktop, before validation and the Core request.
enum CaptureDestination {
    static func normalized(_ url: URL) -> URL {
        guard url.isFileURL else { return url }
        var name = url.lastPathComponent
        while name.lowercased().hasSuffix(".mbt") { name.removeLast(4) }
        return url.deletingLastPathComponent().appendingPathComponent(name + ".mbt")
    }
}

// Presentation grouping only: these remain six independent V1 domains.
struct CaptureMacOSSettingsGroup {
    static let domainIDs = ["macos-finder", "macos-dock", "macos-windows", "macos-keyboard", "macos-trackpad", "macos-screenshots"]
    let categories: [CaptureCategory]
    let selected: Set<String>
    var children: [CaptureCategory] {
        Self.domainIDs.compactMap { id in categories.first { $0.id == id } }
    }
    var availableIDs: [String] { children.filter(\.selectable).map(\.id) }
    var state: SelectionState { SelectionState.summarize(selected: selected, children: availableIDs) }
    var summary: String { "\(selected.intersection(availableIDs).count) of \(availableIDs.count) selected" }
    var hasAttention: Bool { children.contains { $0.row.status == "observation_error" || !$0.notices.isEmpty } }
}

enum CaptureSelectionScope: CaseIterable {
    case ordinary, advanced
    func contains(_ domain: String) -> Bool {
        guard domain != "ssh-configuration" else { return false }
        return switch WorkspacePresentationTaxonomy.group(for: domain).section {
        case .applicationsTools, .macOSSettings, .applicationExtras: self == .ordinary
        case .advanced: self == .advanced
        case .otherFindings: false
        }
    }
}

@MainActor final class CaptureModel: ObservableObject {
    @Published private(set) var state: CaptureFlowState = .idle
    @Published private(set) var inventory: [CoreCaptureInventoryRow] = []
    @Published private(set) var selectedCategories: Set<String> = []
    @Published private(set) var selectedItems: [String: Set<String>] = [:]
    @Published private(set) var secureInventory: CoreCaptureSecureInventory = .unavailable
    @Published private(set) var selectedSecureIdentities: Set<String> = []
    @Published private(set) var addingIdentity = false
    @Published private(set) var identityError: String?
    private var externalSources: [String: String] = [:]
    private var externalCandidates: [String: CoreCaptureSecureInventory.Identity] = [:]
    @Published private(set) var preparation: CoreCapturePreparation?
    @Published private(set) var destination: URL?
    @Published private(set) var publication: CoreCapturePublication?
    @Published private(set) var publicationEvidence: CapturePublicationEvidence = .notOccurred
    @Published private(set) var publicationMayHaveStarted = false
    @Published private(set) var savingAttempted = false
    @Published private(set) var failure: CaptureFailure?
    @Published private(set) var operationID: String?
    @Published private(set) var resultNotices: [DisplayCategory] = []
    let runtime: CoreRuntime
    private let location: CoreLocation?
    private var replacementSHA256: String?
    private var work: Task<Void, Never>?
    init(runtime: CoreRuntime, location: CoreLocation? = nil) { self.runtime = runtime; self.location = location }
    var busy: Bool { addingIdentity || [.scanning, .preparing, .saving].contains(state) }
    var categories: [CaptureCategory] { inventory.map { CaptureCategory(row: $0) } }
    var macOSSettings: CaptureMacOSSettingsGroup { CaptureMacOSSettingsGroup(categories: categories, selected: selectedCategories) }
    func selectMacOSSettings(included: Bool) {
        for domain in macOSSettings.availableIDs { selectCategory(domain, included: included) }
    }
    var selection: CoreCaptureSelection {
        // V1 permits whole item domains. Keep Select All requests compact even
        // for large inventories; partial domains retain their exact item IDs.
        let wholeItems = Set(categories.filter { $0.itemSelectable && selectionState($0) == .all }.map(\.id))
        return CoreCaptureSelection(categories: selectedCategories.union(wholeItems).sorted(),
                                    items: selectedItems.filter { !$0.value.isEmpty && !wholeItems.contains($0.key) }.mapValues { $0.sorted() },
                                    secureIdentities: selectedSecureIdentities.sorted())
    }
    var selectedDomainCount: Int { selectedCategories.count + selectedItems.filter { !$0.value.isEmpty }.count }
    var selectedItemCount: Int { selectedItems.values.reduce(0) { $0 + $1.count } }
    var availableAreaCount: Int { categories.filter(\.selectable).count }
    var selectionSummary: String {
        let selected = selectedDomainCount
        let available = availableAreaCount
        let domains = available == 1 ? "domain" : "domains"
        let areaSummary = selected == available
            ? "\(selected) \(domains) selected"
            : "\(selected) of \(available) \(domains) selected"
        let items = selectedItemCount == 1 ? "item" : "items"
        return "\(areaSummary) · \(selectedItemCount) \(items) selected" + secureSummary(selectedSecureIdentities.count)
    }
    private func secureSummary(_ count: Int) -> String {
        count == 0 ? "" : " · \(count) SSH \(count == 1 ? "identity" : "identities") selected"
    }
    func selectSecureIdentity(_ id: String, included: Bool) {
        guard state == .review, !runtime.isActive, secureInventory.status == "present",
              secureInventory.items.contains(where: { $0.itemID == id }) else { return }
        preparation = nil
        if included { selectedSecureIdentities.insert(id) } else { selectedSecureIdentities.remove(id) }
    }
    func selectAllSecureIdentities(included: Bool) {
        for identity in secureInventory.items { selectSecureIdentity(identity.id, included: included) }
    }
    var manualIdentityIDs: Set<String> { Set(externalSources.keys) }
    private var selectedExternalPaths: [String] { selectedSecureIdentities.sorted().compactMap { externalSources[$0] } }
    static func confirmationPrivacyMessage(includesSSHIdentities: Bool) -> String {
        includesSSHIdentities
            ? "SSH identities are encrypted separately. Other saved settings are not encrypted. Keep the Bundle passphrase safe."
            : "Saved settings are not encrypted."
    }
    func addSSHIdentity(_ url: URL) {
        guard state == .review, !busy, !runtime.isActive else { return }
        guard url.isFileURL, secureInventory.items.count < 32 else {
            identityError = "Choose a private SSH key file. Secure Transfer supports up to 32 identities."; return
        }
        preparation = nil; identityError = nil; addingIdentity = true
        let request = CoreRequest(.captureIdentityInspect, externalIdentityPaths: [url.path])
        runtime.start(request, location: location)
        work = Task {
            defer { addingIdentity = false }
            await runtime.waitForCompletion()
            guard runtime.operationID == request.operationID else { identityError = "The identity check was invalidated. Add the identity again."; return }
            guard runtime.state == .completed, let result = runtime.latestResult else {
                identityError = Self.externalIdentityMessage(runtime.state == .cancelled ? "cancelled" : runtime.error.flatMap { CaptureFailure.runtime($0).technicalReason })
                return
            }
            do {
                struct Inspection: Decodable { let identity: CoreCaptureSecureInventory.Identity }
                let identity = try result.decodeData(Inspection.self).identity
                try CoreCaptureSecureInventory(status: "present", reason: nil, items: [identity]).validate()
                guard identity.source == "manual" else { throw CoreRuntimeError.malformedEvent }
                guard !secureInventory.items.contains(where: { $0.label.caseInsensitiveCompare(identity.label) == .orderedSame || $0.fingerprint == identity.fingerprint }) else {
                    identityError = "This identity or destination name is already listed. Use the existing row or choose a different pair."; return
                }
                externalSources[identity.id] = url.path; externalCandidates[identity.id] = identity
                secureInventory = CoreCaptureSecureInventory(status: "present", reason: nil, items: secureInventory.items + [identity])
                // Adding a candidate is not authorization to transfer it.
            } catch { identityError = "The SSH identity could not be validated. Choose a supported matching private/public pair." }
        }
    }
    func removeSSHIdentity(_ id: String) {
        guard state == .review, !busy, !runtime.isActive, externalSources[id] != nil else { return }
        externalSources[id] = nil; externalCandidates[id] = nil
        selectedSecureIdentities.remove(id); preparation = nil; identityError = nil
        let items = secureInventory.items.filter { $0.id != id }
        secureInventory = .init(status: items.isEmpty ? "unavailable" : "present", reason: nil, items: items)
    }
    private static func externalIdentityMessage(_ reason: String?) -> String {
        switch reason {
        case "external_identity_pair_missing": "The private key and its matching .pub file must both exist in the selected folder. Macseed will not generate a public key."
        case "external_identity_name_invalid": "Use a key name of up to 80 ASCII letters, digits, dots, underscores or hyphens, starting with a letter or digit. Select the private file, not .pub; SSH configuration and control names are reserved."
        case "external_identity_unsafe": "The pair or its folder is unsafe. Use regular files you own, private key mode 600, public key mode 600 or 644, and folders without unsafe links or shared write access."
        case "external_identity_changed": "The SSH pair changed during inspection. Check the files and add the identity again."
        case "external_identity_duplicate": "This identity or destination name is already listed. Choose a different pair."
        case "cancelled", "interrupted": "The SSH identity check was cancelled."
        default: "The SSH pair could not be validated. Choose a supported OpenSSH private key with its matching .pub file."
        }
    }
    var confirmationAreas: [CaptureConfirmationArea] {
        guard let prepared = preparation, let selection = prepared.publicationSelection else { return [] }
        let selected = Set(selection.categories).union(selection.items.keys)
        let categories = prepared.inventory.map { CaptureCategory(row: $0) }
        let macOS = categories.filter { CaptureMacOSSettingsGroup.domainIDs.contains($0.id) }
        let chosenMacOS = macOS.filter { selected.contains($0.id) }
        var rows: [CaptureConfirmationArea] = []
        for category in categories where selected.contains(category.id) {
            if CaptureMacOSSettingsGroup.domainIDs.contains(category.id) {
                if category.id == chosenMacOS.first?.id {
                    rows.append(CaptureConfirmationArea(id: "macos-settings", title: "macOS Settings",
                        content: "\(chosenMacOS.count) of \(macOS.count)",
                        requiresAttention: chosenMacOS.contains { $0.row.reason != nil }))
                }
            } else {
                let count = selection.items[category.id]?.count ?? category.row.items.count
                rows.append(CaptureConfirmationArea(id: category.id, title: category.title,
                    content: category.itemSelectable ? "\(count)" : "Included",
                    requiresAttention: category.row.reason != nil))
            }
        }
        return rows
    }
    var confirmationWarnings: [CaptureCategory] {
        guard let prepared = preparation, let selection = prepared.publicationSelection else { return [] }
        let selected = Set(selection.categories).union(selection.items.keys)
        return prepared.inventory.filter { selected.contains($0.domain) && $0.reason != nil }.map { CaptureCategory(row: $0) }
    }
    var confirmationSummary: String {
        guard let summary = preparation?.summary else { return "" }
        return "\(summary.selectedDomains) \(summary.selectedDomains == 1 ? "domain" : "domains") selected · \(summary.selectedItems) \(summary.selectedItems == 1 ? "item" : "items") selected" + secureSummary(summary.secureIdentityCount)
    }
    var canCreate: Bool { state == .review && (selectedDomainCount > 0 || !selectedSecureIdentities.isEmpty) && !runtime.isActive }
    func selectionState(_ category: CaptureCategory) -> SelectionState {
        guard category.selectable else { return .none }
        if !category.itemSelectable { return selectedCategories.contains(category.id) ? .all : .none }
        return SelectionState.summarize(selected: selectedItems[category.id] ?? [], children: category.row.items.map(\.itemID))
    }
    func categories(in scope: CaptureSelectionScope) -> [CaptureCategory] {
        categories.filter { scope.contains($0.id) }
    }
    var bulkState: SelectionState { bulkState(in: .ordinary) }
    func bulkState(in scope: CaptureSelectionScope) -> SelectionState {
        bulkState(for: categories(in: scope))
    }
    func bulkState(for categories: [CaptureCategory]) -> SelectionState {
        let selectable = categories.filter(\.selectable)
        if !selectable.isEmpty && selectable.allSatisfy({ selectionState($0) == .all }) { return .all }
        return selectable.contains { selectionState($0) != .none } ? .mixed : .none
    }
    func selectionSummary(for categories: [CaptureCategory]) -> String {
        let domains = categories.filter { selectionState($0) != .none }.count
        let items = categories.reduce(0) { $0 + (selectedItems[$1.id]?.count ?? 0) }
        return "\(domains) \(domains == 1 ? "domain" : "domains") · \(items) \(items == 1 ? "item" : "items") selected"
    }
    func selectCategory(_ domain: String, included: Bool) {
        guard state == .review, !runtime.isActive, let category = categories.first(where: { $0.id == domain }), category.selectable else { return }
        preparation = nil
        if category.itemSelectable { selectedItems[domain] = included ? Set(category.row.items.map(\.itemID)) : nil }
        else if included { selectedCategories.insert(domain) } else { selectedCategories.remove(domain) }
    }
    func selectItem(_ domain: String, item: String, included: Bool) {
        guard state == .review, !runtime.isActive, let category = categories.first(where: { $0.id == domain }), category.itemSelectable,
              category.row.items.contains(where: { $0.itemID == item }) else { return }
        preparation = nil
        if included { selectedItems[domain, default: []].insert(item) }
        else { selectedItems[domain]?.remove(item); if selectedItems[domain]?.isEmpty == true { selectedItems[domain] = nil } }
    }
    func toggleAll(in scope: CaptureSelectionScope = .ordinary) {
        toggleCategories(categories(in: scope))
    }
    func toggleCategories(_ categories: [CaptureCategory]) {
        guard state == .review, !runtime.isActive else { return }
        let included = bulkState(for: categories) != .all
        for category in categories where category.selectable { selectCategory(category.id, included: included) }
    }
    func scan() {
        guard !busy, !runtime.isActive else { return }
        inventory = []; selectedCategories = []; selectedItems = [:]; preparation = nil; destination = nil
        secureInventory = .unavailable; selectedSecureIdentities = []
        externalSources = [:]; externalCandidates = [:]; identityError = nil
        replacementSHA256 = nil; publication = nil; resultNotices = []; publicationEvidence = .notOccurred; publicationMayHaveStarted = false; failure = nil
        run(CoreRequest(.capturePrepare(selection: nil)), state: .scanning, expected: nil)
    }
    func prepare(destination: URL, replacementConfirmed: Bool = false) {
        guard canCreate else { return }
        savingAttempted = false
        let destination = CaptureDestination.normalized(destination)
        self.destination = destination
        replacementSHA256 = nil
        guard destination.isFileURL, destination.pathExtension == "mbt",
              (try? FileManager.default.destinationOfSymbolicLink(atPath: destination.path)) == nil else {
            preparation = nil; fail(.invalidDestination); return
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            guard replacementConfirmed, let fingerprint = try? CaptureReplacement.fingerprint(destination) else {
                preparation = nil; fail(.invalidDestination); return
            }
            replacementSHA256 = fingerprint
        }
        preparation = nil; failure = nil
        let expected = selection
        run(CoreRequest(.capturePrepare(selection: expected), externalIdentityPaths: selectedExternalPaths), state: .preparing, expected: expected)
    }
    func editSelection() {
        guard state == .confirmation || canReviewSelection, !runtime.isActive else { return }
        preparation = nil; failure = nil; state = .review
    }
    var canReviewSelection: Bool {
        state == .failed && !savingAttempted && failure?.isWorkspaceSelectionConflict == true && !runtime.isActive
    }
    func create() {
        guard state == .confirmation, !runtime.isActive, let preparation, let selection = preparation.selection, let destination else { return }
        if let replacementSHA256, (try? CaptureReplacement.fingerprint(destination)) != replacementSHA256 {
            fail(.invalidDestination); return
        }
        publicationEvidence = .unknown; publicationMayHaveStarted = false; failure = nil; publication = nil
        run(CoreRequest(.captureExecute(selection: selection, destination: destination.path, preparedID: preparation.preparedCaptureID, replacementSHA256: replacementSHA256), externalIdentityPaths: selectedExternalPaths), state: .saving, expected: selection)
    }
    private func run(_ request: CoreRequest, state next: CaptureFlowState, expected: CoreCaptureSelection?) {
        savingAttempted = next == .saving
        operationID = request.operationID; state = next
        runtime.start(request, location: location)
        work = Task {
            await runtime.waitForCompletion()
            guard runtime.operationID == request.operationID else { fail(.invalidEvidence); return }
            if next == .saving {
                publicationMayHaveStarted = runtime.events.contains { $0.type == "phase_started" && $0.phase == "bundle_creation" }
                publicationEvidence = runtime.publicationOccurred.map { $0 ? .occurred : .notOccurred } ?? .unknown
            }
            switch runtime.state {
            case .completed:
                do {
                    guard let result = runtime.latestResult else { throw CaptureFailure.invalidEvidence }
                    if next == .saving {
                        guard let preparation, let destination else { throw CaptureFailure.invalidEvidence }
                        let published = try result.decodeData(CoreCapturePublication.self)
                        try published.validate(preparation: preparation, destination: destination)
                        publication = published; publicationEvidence = .occurred
                        resultNotices = captureNotices()
                        self.state = .result
                    } else {
                        let prepared = try result.decodeData(CoreCapturePreparation.self)
                        try prepared.validate(expected: expected)
                        inventory = prepared.inventory
                        let remaining = externalCandidates.values.filter { candidate in !prepared.secureIdentities.items.contains { $0.id == candidate.id } }
                        secureInventory = remaining.isEmpty ? prepared.secureIdentities : .init(status: "present", reason: nil,
                            items: prepared.secureIdentities.items + remaining.sorted { $0.label < $1.label })
                        if next == .scanning {
                            selectedCategories = []; selectedItems = [:]; self.state = .review
                            for category in categories(in: .ordinary) where category.selectable { selectCategory(category.id, included: true) }
                        } else {
                            // A whole-domain selection includes its freshly observed inventory.
                            // Confirmation/counts must show that exact new Core scope.
                            for category in categories where category.itemSelectable && expected?.categories.contains(category.id) == true {
                                selectedItems[category.id] = Set(category.row.items.map(\.itemID))
                            }
                            preparation = prepared; self.state = .confirmation
                        }
                    }
                } catch { fail(.invalidEvidence) }
            case .cancelled:
                if next == .saving && runtime.termination?.exitCode == nil { publicationEvidence = .notOccurred }
                preparation = nil; failure = .cancelled; self.state = .cancelled
            case .failed:
                fail(runtime.error == .interrupted ? .interrupted : .runtime(runtime.error ?? .malformedEvent))
            default: fail(.invalidEvidence)
            }
        }
    }
    var resultPresentation: CaptureResultPresentation? {
        guard state == .result, publicationEvidence == .occurred, let publication, publication.publicationOccurred else { return nil }
        return CaptureResultPresentation(publication: publication, notices: resultNotices,
                                         secureIdentityCount: preparation?.summary.secureIdentityCount ?? 0)
    }
    private func captureNotices() -> [DisplayCategory] {
        // Only Core's selected-category event facts contribute result warnings.
        let chosen = Set(preparation?.publicationSelection?.categories ?? []).union(preparation?.publicationSelection?.items.keys.map { $0 } ?? [])
        var notices: [DisplayCategory] = runtime.events.compactMap { event in
            guard event.type == "capture_category", let domain = event.data?["domain"]?.string, chosen.contains(domain),
                  let reason = event.data?["reason"]?.string, let category = categories.first(where: { $0.id == domain }) else { return nil }
            return DisplayCategory(id: domain, title: category.title, symbol: category.symbol,
                                   items: [DisplayItem(id: domain, title: "Needs Attention", status: .attention,
                                                       action: "Some supported state may be unavailable in this captured category.", reason: reason)])
        }
        // A validated Bundle confirms publication, but absent selected-category
        // observation evidence cannot establish a clean result for that category.
        let observed = Set(runtime.events.compactMap { event -> String? in
            guard event.type == "capture_category", event.data?["status"]?.string == "present" else { return nil }
            return event.data?["domain"]?.string
        })
        for category in categories where chosen.contains(category.id) && !observed.contains(category.id) {
            notices.append(DisplayCategory(id: category.id, title: category.title, symbol: category.symbol,
                items: [DisplayItem(id: "capture-evidence:" + category.id, title: "Unverified", status: .unverified,
                    action: "The selected category's capture details could not be confirmed.")]))
        }
        return notices
    }
    private func fail(_ error: CaptureFailure) { preparation = nil; publication = nil; failure = error; state = .failed }
    func cancel() { if busy { runtime.cancel() } }
    func done() {
        guard state == .result, !runtime.isActive else { return }
        inventory = []; selectedCategories = []; selectedItems = [:]; preparation = nil; destination = nil
        secureInventory = .unavailable; selectedSecureIdentities = []
        externalSources = [:]; externalCandidates = [:]; identityError = nil
        replacementSHA256 = nil; publication = nil; resultNotices = []; publicationEvidence = .notOccurred
        publicationMayHaveStarted = false; failure = nil; operationID = nil
        savingAttempted = false
        state = .idle
    }
    func cancelReview() {
        guard state == .review, !runtime.isActive else { return }
        state = .idle; preparation = nil; destination = nil
        secureInventory = .unavailable; selectedSecureIdentities = []
        externalSources = [:]; externalCandidates = [:]; identityError = nil
    }
    func waitForCompletion() async { await work?.value }
}

// Consent is bound to the exact regular, owned file; this performs no publication.
enum CaptureReplacement {
    static func fingerprint(_ url: URL) throws -> String {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw CaptureFailure.invalidDestination }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_uid == getuid(), before.st_size <= 48 * 1024 * 1024 else { throw CaptureFailure.invalidDestination }
        var hash = SHA256()
        var observedSize = 0
        while let data = try handle.read(upToCount: 65536), !data.isEmpty {
            observedSize += data.count
            guard observedSize <= 48 * 1024 * 1024 else { throw CaptureFailure.invalidDestination }
            hash.update(data: data)
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else {
            throw CaptureFailure.invalidDestination
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
