import AppKit
import SwiftUI

// Inline under the selected Host. Core returns only references needing attention.
struct RestoreSSHReferenceCorrection: View {
    @ObservedObject var model: RestoreModel
    let item: CoreSSHReview.Item
    private var secureKeys: [CoreRestoreIdentityInventory.Item] {
        model.destinationInventory?.items.filter { model.includeSecure && model.selectedIdentityIDs.contains($0.id) } ?? []
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("IdentityFile \(item.index + 1)").font(.callout.weight(.medium))
            Text("Original: " + item.reference).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
            if let proposal = model.sshProposals[item.id] {
                Text("Qualified proposal: " + proposal.reference).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                if model.canReviewSSHReferences {
                    Toggle("Approve this path change", isOn: Binding(
                        get: { model.approvedSSHReferences.contains(item.id) },
                        set: { model.approveSSHReference(item, approved: $0) })).toggleStyle(.checkbox)
                }
            }
            if model.canReviewSSHReferences {
                HStack(spacing: 12) {
                    Button("Choose Local Key…") { choose() }
                    if !secureKeys.isEmpty {
                        Menu("Selected Secure Key") {
                            ForEach(secureKeys) { identity in
                                Button(identity.name) { model.proposeSSHReference(model.sshDestination(identity), identityID: identity.id, for: item) }
                            }
                        }
                    }
                    if model.sshProposals[item.id] != nil {
                        Button("Preserve Original") { model.proposeSSHReference(nil, for: item) }
                    }
                }
            }
        }.font(.callout).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
    }
    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false; panel.canCreateDirectories = false; panel.resolvesAliases = false
        panel.prompt = "Use Key"
        guard panel.runModal() == .OK, let url = panel.url, url.isFileURL else { return }
        let home = NSHomeDirectory() + "/"
        let reference = url.path.hasPrefix(home) ? "~/" + url.path.dropFirst(home.count) : url.path
        model.proposeSSHReference(reference, for: item)
    }
}
