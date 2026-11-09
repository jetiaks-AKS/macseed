import AppKit
import SwiftUI

// Contextual recovery stays inside SSH Keys, separate from its status rail.
struct EnvironmentSecureCheckStatus: View {
    let message: String
    var busy = false
    var available = true
    var customizable = false
    var customize: () -> Void = {}
    var check: () -> Void = {}
    var cancel: () -> Void = {}
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(message, systemImage: "key").font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if busy { Button("Cancel", action: cancel).fixedSize() }
                else {
                    if available { Button("Check Again", action: check).fixedSize() }
                    if customizable { Button("Change Location…", action: customize).fixedSize() }
                }
            }
        }
    }
}

struct EnvironmentSecureSelectionView: View {
    @ObservedObject var model: EnvironmentStatusModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("SSH Key Locations").font(.title2.weight(.semibold))
            Text("All saved keys are checked by default. Custom locations or a smaller scope are optional. Nothing will be changed.")
                .font(.callout).foregroundStyle(.secondary)
            Text("\(model.draftSecureIDs.count) of \(model.secureInventory?.items.count ?? 0) selected")
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    ForEach(model.secureInventory?.items ?? []) { identity in
                        HStack(spacing: 8) {
                            NativeSelectionCheckbox("", isOn: Binding(get: { model.draftSecureIDs.contains(identity.id) },
                                set: { model.selectSecureIdentity(identity.id, included: $0) }), accessibilityTitle: "Check " + identity.name)
                                .frame(width: 20, height: 20)
                            Text(identity.name).font(.headline).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }.gridCellColumns(3)
                        Text(identity.keyType + " · " + identity.fingerprint).font(.caption).foregroundStyle(.secondary)
                            .textSelection(.enabled).gridCellColumns(3)
                        GridRow(alignment: .top) {
                            Text(model.draftSecureDirectories[identity.id] ?? "~/.ssh").font(.callout)
                                .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                                .accessibilityLabel("Check location").frame(maxWidth: .infinity, alignment: .leading)
                            Button("Choose Folder…") { choose(identity.id) }.fixedSize()
                            Button("Use Default") { model.setSecureDirectory(nil, for: identity.id) }.fixedSize()
                                .disabled(model.draftSecureDirectories[identity.id] == nil)
                                .opacity(model.draftSecureDirectories[identity.id] == nil ? 0 : 1)
                                .accessibilityHidden(model.draftSecureDirectories[identity.id] == nil)
                        }.disabled(!model.draftSecureIDs.contains(identity.id)).padding(.bottom, 14)
                    }
                }.padding(.vertical, 4)
            }.frame(height: min(280, CGFloat(model.secureInventory?.items.count ?? 0) * 104))
            Text("Custom locations must already exist. SSH authentication is not tested.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Cancel", role: .cancel) { model.cancelSecureSelection() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Check Selected Keys") { model.compareSSHKeys() }.buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction).disabled(model.draftSecureIDs.isEmpty || model.secureBusy)
            }
        }.padding(24).frame(width: 620).interactiveDismissDisabled()
    }
    private func choose(_ id: String) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.canCreateDirectories = false; panel.resolvesAliases = false
        panel.prompt = "Use Folder"
        guard panel.runModal() == .OK, let url = panel.url, url.isFileURL else { return }
        model.setSecureDirectory(url.path, for: id)
    }
}
