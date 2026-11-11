import AgenttyProtocol
import AgenttyTerminal
import SwiftUI

/// The paired Mac's folders and the sessions running in them.
struct SessionsView: View {
    @EnvironmentObject private var model: PhoneModel
    @State private var confirmingForget = false

    var body: some View {
        NavigationStack(path: $model.path) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    if model.status != .connected {
                        StatusCard()
                    }
                    ForEach(model.groups) { group in
                        FolderSection(group: group)
                    }
                    if model.status == .connected {
                        // Any folder on the Mac, not only the listed ones.
                        Button { model.showBrowser = true } label: {
                            Label("Open Another Folder…", systemImage: "folder.badge.plus")
                                .font(.subheadline.weight(.medium))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.hairline))
                        }
                    }
                    if model.status == .connected && model.folders.isEmpty {
                        Text("Add project folders in Agentty on your Mac and they show up here.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                    }
                    if model.status == .connected && model.agentsLoaded && model.installedAgents.isEmpty {
                        Text("No agent CLI was found on the Mac. You can still open a shell.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .background(Palette.canvas.ignoresSafeArea())
            .navigationTitle(model.pairing?.name ?? "Agentty")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        // Every paired Mac, to switch between them.
                        Section("Macs") {
                            ForEach(model.hosts) { host in
                                Button { model.select(host) } label: {
                                    Label(host.name, systemImage: host.id == model.pairing?.id ? "checkmark" : "desktopcomputer")
                                }
                            }
                            Button { model.showPairSheet = true } label: { Label("Pair Another Mac…", systemImage: "plus") }
                        }
                        NavigationLink(value: Route.allHistory) { Label("All Conversations", systemImage: "clock.arrow.circlepath") }
                        Button { model.refreshAgents() } label: { Label("Check Agents Again", systemImage: "arrow.clockwise") }
                        Button(role: .destructive) { confirmingForget = true } label: { Label("Forget This Mac", systemImage: "xmark.circle") }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityIdentifier("mac-menu")
                }
            }
            .sheet(isPresented: $model.showPairSheet) {
                NavigationStack {
                    PairView(addingAnother: true)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Cancel") { model.showPairSheet = false }
                            }
                        }
                }
                .environmentObject(model)
                .preferredColorScheme(.dark)
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .session(let id):
                    TerminalScreen(session: id)
                case .folder(let folder):
                    FolderScreen(folder: folder)
                case .file(let folder, let file, let staged):
                    PatchScreen(folder: folder, file: file, staged: staged)
                case .document(let path):
                    DocumentScreen(path: path)
                case .allHistory:
                    HistoryList(folder: nil)
                        .background(Palette.canvas.ignoresSafeArea())
                        .navigationTitle("All Conversations")
                        .navigationBarTitleDisplayMode(.inline)
                }
            }
            .sheet(isPresented: $model.showBrowser) {
                BrowseSheet()
                    .environmentObject(model)
                    .preferredColorScheme(.dark)
            }
            .confirmationDialog("Forget this Mac?", isPresented: $confirmingForget, titleVisibility: .visible) {
                Button("Forget", role: .destructive) { model.forgetMac() }
            } message: {
                Text("Sessions keep running on \(model.pairing?.name ?? "the Mac"). To connect again you pair with it once more.")
            }
        }
        // On the stack, not on the list inside it: a sheet or alert attached
        // to the list cannot appear while another screen, such as a
        // terminal, is on top of it.
        .sheet(item: $model.sessionHandoff) { conversation in
            ConversationSheet(conversation: conversation, showsResume: false)
                .environmentObject(model)
                .preferredColorScheme(.dark)
        }
        .alert("Agentty", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.message ?? "")
        }
    }
}

private struct StatusCard: View {
    @EnvironmentObject private var model: PhoneModel

    var body: some View {
        HStack(spacing: 12) {
            if model.status == .connecting {
                ProgressView()
            } else {
                Image(systemName: "wifi.exclamationmark").foregroundStyle(.orange)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(model.status == .connecting ? "Connecting to your Mac…" : "Can't reach your Mac")
                    .font(.subheadline.weight(.semibold))
                if model.status != .connecting {
                    Text("Check that Tailscale is connected here and on the Mac, and that Agentty is open there.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            if model.status != .connecting {
                Button("Retry") { model.retry() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.panel))
    }
}

private struct FolderSection: View {
    @EnvironmentObject private var model: PhoneModel
    let group: FolderGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: group.path == nil ? "house.fill" : "folder.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.tint)
                Text(group.name)
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let path = group.path {
                    // The folder's git changes and conversations, as in the
                    // Mac's side panel.
                    NavigationLink(value: Route.folder(path)) {
                        HStack(spacing: 4) {
                            Text("Git, History, Files")
                            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                        }
                        .font(.footnote.weight(.medium))
                    }
                    .accessibilityIdentifier("folder-details")
                }
            }
            .padding(.horizontal, 4)

            VStack(spacing: 0) {
                ForEach(group.sessions) { session in
                    NavigationLink(value: Route.session(session.id)) {
                        SessionRow(session: session)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if model.canHandOff(session) {
                            Button { model.requestHandoff(session: session) } label: { Label("Hand Off…", systemImage: "arrowshape.turn.up.right") }
                        }
                        Button(role: .destructive) { model.end(session.id) } label: { Label("End Session", systemImage: "xmark.circle") }
                    }
                    Palette.hairline.frame(height: 1).padding(.leading, 38)
                }
                LaunchRow(folder: group.path)
            }
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.panel))
        }
    }
}

private struct SessionRow: View {
    @EnvironmentObject private var model: PhoneModel
    let session: SessionInfo

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: AgentStyle.symbol(for: model.agentID(for: session)))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AgentStyle.accent(for: model.agentID(for: session)))
                .frame(width: 18)
            // The conversation's title once the agent has saved one, the
            // agent's name until then.
            Text(session.displayName)
                .font(.body)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text("\(session.size.cols)×\(session.size.rows)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.tertiary)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }
}

/// One tap starts an agent in this folder.
private struct LaunchRow: View {
    @EnvironmentObject private var model: PhoneModel
    let folder: String?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.installedAgents) { agent in
                    chip(title: agent.name, id: agent.id) { model.launch(agent, in: folder) }
                }
                chip(title: "Shell", id: "shell") { model.launch(nil, in: folder) }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
        }
        .disabled(model.status != .connected)
        .opacity(model.status == .connected ? 1 : 0.45)
    }

    private func chip(title: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: AgentStyle.symbol(for: id))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AgentStyle.accent(for: id))
                Text(title)
                    .font(.system(size: 14, weight: .medium))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Capsule().fill(Palette.raised))
            .overlay(Capsule().strokeBorder(Palette.hairline))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Start \(title)")
    }
}
