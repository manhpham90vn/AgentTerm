import AgentTermProtocol
import AgentTermTerminal
import SwiftUI

/// Which Mac is on screen: this one, or one it is paired with. At the top
/// of the sidebar, since everything under it belongs to that Mac.
struct MacSwitcher: View {
    @EnvironmentObject private var model: AppModel
    @State private var forgetting: RemoteMac?

    var body: some View {
        Menu {
            Button {
                model.switchTo(nil)
            } label: {
                Label("This Mac", systemImage: model.isRemote ? "desktopcomputer" : "checkmark")
            }
            if !model.remoteMacs.isEmpty {
                Divider()
                ForEach(model.remoteMacs) { mac in
                    Button {
                        model.switchTo(mac)
                    } label: {
                        Label(mac.name, systemImage: model.remote?.id == mac.id ? "checkmark" : "macbook")
                    }
                }
            }
            Divider()
            Button("Pair with Another Mac…") { model.showPairMac = true }
            if !model.remoteMacs.isEmpty {
                Menu("Forget") {
                    ForEach(model.remoteMacs) { mac in
                        Button(mac.name) { forgetting = mac }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: model.isRemote ? "macbook" : "desktopcomputer")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(model.isRemote ? Color.accentColor : .secondary)
                Text(model.remote?.name ?? "This Mac")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("Use this Mac, or another Mac this one is paired with")
        .accessibilityLabel("Mac")
        .accessibilityValue(model.remote?.name ?? "This Mac")
        .accessibilityIdentifier("mac-switcher")
        .confirmationDialog(
            "Forget \(forgetting?.name ?? "this Mac")?", isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }),
            titleVisibility: .visible, presenting: forgetting
        ) { mac in
            Button("Forget", role: .destructive) { model.forget(mac) }
            Button("Cancel", role: .cancel) {}
        } message: { mac in
            Text("Sessions keep running on \(mac.name). To use it from here again you pair with it once more.")
        }
    }
}

/// Pairs with another Mac. A Mac has no camera pointed at the other one's
/// screen, so the link under the code is pasted here instead of scanned.
struct PairMacSheet: View {
    @EnvironmentObject private var model: AppModel
    @State private var link = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Pair with Another Mac").font(.system(size: 17, weight: .semibold))
            Text(
                "On the other Mac, open AgentTerm and choose Pair iPhone. Copy the link shown under the code and paste it here. This Mac then shows that Mac's sessions, folders, changes and files, as the iPhone app does."
            )
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            TextField("\(AppChannel.current.linkScheme)://pair?…", text: $link)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .onSubmit(pair)
                .disabled(model.isPairingMac)
                .accessibilityLabel("Pairing link")
                .accessibilityIdentifier("pair-mac-link")
            if let problem = model.pairMacError {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Both Macs have to reach each other: on the same Tailscale network, as for the iPhone.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            HStack {
                if model.isPairingMac { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) {
                    model.cancelPairingMac()
                    model.showPairMac = false
                }
                .keyboardShortcut(.cancelAction)
                Button("Pair", action: pair)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isPairingMac)
                    .accessibilityIdentifier("pair-mac")
            }
        }
        .padding(22)
        .frame(width: 460)
        .onAppear { model.pairMacError = nil }
    }

    private func pair() {
        model.pairMac(link: link)
    }
}

/// Picks a folder of the other Mac to add to its list. An open panel would
/// show this Mac's disk, so the other Mac's host lists its folders instead.
struct BrowseFoldersSheet: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Add a Folder on \(model.macName)").font(.system(size: 15, weight: .semibold))
                Text(model.browseListing?.path ?? " ")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 10)
            Theme.hairline.frame(height: 1)
            if let listing = model.browseListing {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if let parent = listing.parent {
                            row("arrow.turn.left.up", "Enclosing Folder") { model.browse(parent) }
                        }
                        ForEach(listing.folders, id: \.self) { name in
                            row("folder", name) { model.browse((listing.path as NSString).appendingPathComponent(name)) }
                        }
                        if listing.folders.isEmpty {
                            Text("No folders in here.")
                                .font(.system(size: 12))
                                .foregroundStyle(.tertiary)
                                .padding(18)
                        }
                    }
                    .padding(.vertical, 6)
                }
            } else {
                LoadingView("Loading the folders…") { model.browse(nil) }
            }
            Theme.hairline.frame(height: 1)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.showBrowseFolders = false }
                    .keyboardShortcut(.cancelAction)
                Button("Add This Folder") { if let path = model.browseListing?.path { model.addRemoteFolder(path) } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.browseListing == nil)
                    .accessibilityIdentifier("add-remote-folder")
            }
            .padding(14)
        }
        .frame(width: 440, height: 420)
    }

    private func row(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 18)
                Text(title).font(.system(size: 13)).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
