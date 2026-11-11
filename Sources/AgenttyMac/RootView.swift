import AgenttyEditor
import AgenttyProtocol
import AgenttyTerminal
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var files: FilesModel

    var body: some View {
        HSplitView {
            if model.showSidebar {
                SidebarView()
                    .frame(minWidth: 210, idealWidth: 250, maxWidth: 380)
            }
            CenterView()
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
            if model.showDiff {
                RightPanel()
                    .frame(minWidth: 310, idealWidth: 420, maxWidth: 760)
            }
        }
        .background(Theme.canvas)
        .toolbar {
            // Far left: the folder list's toggle, next to the list it hides.
            ToolbarItem(placement: .navigation) {
                Button { model.showSidebar.toggle() } label: {
                    Label("Folders", systemImage: "sidebar.leading")
                }
                .help(model.showSidebar ? "Hide the folder list" : "Show the folder list")
            }
            // Middle: starting an agent is the main thing to do here.
            ToolbarItem(placement: .principal) {
                LaunchBar()
            }
            // Without this flexible space the items below sit right after
            // the agents instead of at the window's edge.
            ToolbarItem(placement: .primaryAction) {
                Spacer()
            }
            // Far right: pairing, then the side panel's toggle in the corner
            // above the panel it hides.
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.showPairing = true } label: {
                    Label("Pair iPhone", systemImage: "qrcode")
                }
                .help("Pair an iPhone with a QR code")
                Button { model.showDiff.toggle() } label: {
                    Label("Side Panel", systemImage: "sidebar.trailing")
                }
                .help(model.showDiff ? "Hide the side panel" : "Show the side panel")
            }
        }
        .sheet(isPresented: $model.showPairing) {
            PairingView(port: model.hostPort)
        }
        .confirmationDialog(
            "Save changes to \"\((files.pendingClose as NSString?)?.lastPathComponent ?? "")\"?",
            isPresented: Binding(get: { files.pendingClose != nil }, set: { if !$0 { files.pendingClose = nil } }),
            titleVisibility: .visible, presenting: files.pendingClose
        ) { path in
            Button("Save") { if files.save(path) { files.close(path) } }
            Button("Don't Save", role: .destructive) { files.close(path) }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(item: $model.pendingHandoff) { conversation in
            HandoffSheet(conversation: conversation)
        }
        .alert("Agentty", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.notice ?? "")
        }
    }
}

/// Quick launch buttons for the agents that are installed, plus a plain shell.
struct LaunchBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 6) {
            ForEach(model.installedAgents) { agent in
                LaunchButton(title: agent.name, id: agent.id) { model.launch(agent) }
                    .help("Start \(agent.name) in \(model.workingDirectory)")
            }
            LaunchButton(title: "Shell", id: "shell") { model.launch(nil) }
                .help("Start a shell in \(model.workingDirectory)")
        }
        .disabled(model.status != .connected)
    }
}

struct LaunchButton: View {
    let title: String
    let id: String
    var large = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: large ? 8 : 6) {
                Image(systemName: Theme.symbol(for: id))
                    .font(.system(size: large ? 13 : 11, weight: .semibold))
                    .foregroundStyle(Theme.accent(for: id))
                Text(title)
                    .font(.system(size: large ? 13 : 12, weight: .medium))
            }
            .padding(.horizontal, large ? 14 : 10)
            .padding(.vertical, large ? 9 : 5)
            .background(
                RoundedRectangle(cornerRadius: large ? 9 : 7, style: .continuous)
                    .fill(hovering ? Color.white.opacity(0.12) : Theme.raised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: large ? 9 : 7, style: .continuous)
                    .strokeBorder(Theme.hairline)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct CenterView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var files: FilesModel

    var body: some View {
        ZStack {
            Theme.canvas
            switch model.status {
            case .connecting:
                VStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text("Starting the Agentty host…").foregroundStyle(.secondary)
                }
            case .failed(let reason):
                VStack(spacing: 12) {
                    Image(systemName: "bolt.horizontal.circle").font(.system(size: 34)).foregroundStyle(.secondary)
                    Text("Can't reach the Agentty host").font(.headline)
                    Text(reason).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Try Again") { model.reconnect() }
                }
                .padding(40)
            case .connected:
                if let document = files.activeDocument {
                    // A file tab is in front.
                    VStack(spacing: 0) {
                        SessionTabs()
                        DocumentView(document: document)
                    }
                } else if let controller = model.currentController {
                    VStack(spacing: 0) {
                        SessionTabs()
                        if let size = model.foreignSizes[controller.session] {
                            ForeignSizeBanner(size: size)
                        }
                        let foreign = model.foreignSizes[controller.session]
                        TerminalPane(controller: controller, foreignSize: foreign)
                            .id(controller.session)
                            // The framed preview of another device's screen
                            // is centered, so it gets no one-sided padding.
                            .padding(.leading, foreign == nil ? 10 : 0)
                            .padding(.top, foreign == nil ? 6 : 0)
                            .background(TerminalAreaReader(insets: foreign == nil ? .zero : CGSize(width: 10, height: 6)))
                    }
                } else {
                    VStack(spacing: 0) {
                        SessionTabs()
                        WelcomeView().frame(maxWidth: .infinity, maxHeight: .infinity)
                            // Where a terminal would go, less its padding.
                            .background(TerminalAreaReader(insets: CGSize(width: 10, height: 6)))
                    }
                }
            }
        }
    }
}

/// Tells the model how much room a terminal has, so a new session can be
/// started at the size it will be shown at.
private struct TerminalAreaReader: View {
    @EnvironmentObject private var model: AppModel
    /// What to take off for the padding a terminal gets.
    let insets: CGSize

    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { report(proxy.size) }
                .onChange(of: proxy.size) { _, size in report(size) }
        }
    }

    private func report(_ size: CGSize) {
        model.terminalArea = CGSize(width: size.width - insets.width, height: size.height - insets.height)
    }
}

/// Shown while another device decides the terminal size.
struct ForeignSizeBanner: View {
    @EnvironmentObject private var model: AppModel
    let size: TermSize

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "iphone").foregroundStyle(.secondary)
            Text("Another device is using this session, so it is shown at that device's size (\(size.cols) × \(size.rows)).")
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            Button("Use This Window's Size") { model.takeControl() }
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Theme.panel)
        .overlay(alignment: .bottom) { Theme.hairline.frame(height: 1) }
    }
}

struct WelcomeView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "terminal")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
            VStack(spacing: 6) {
                Text(model.selectedFolder.map { ($0 as NSString).lastPathComponent } ?? "Agentty")
                    .font(.system(size: 22, weight: .semibold))
                Text(model.selectedFolder == nil
                     ? "Add a project folder, then start an agent in it."
                     : "Start an agent in this folder.")
                    .foregroundStyle(.secondary)
            }
            if model.selectedFolder == nil {
                Button("Add Folder…") { model.addFolder() }
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
            HStack(spacing: 10) {
                ForEach(model.installedAgents) { agent in
                    LaunchButton(title: agent.name, id: agent.id, large: true) { model.launch(agent) }
                }
                LaunchButton(title: "Shell", id: "shell", large: true) { model.launch(nil) }
            }
            if model.agentsLoaded && model.installedAgents.isEmpty {
                VStack(spacing: 6) {
                    Text("No agent CLI was found on this Mac.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Check Again") { model.refreshAgents() }.controlSize(.small)
                }
            }
            if let error = model.lastError {
                Text(error).font(.callout).foregroundStyle(Theme.removed)
            }
        }
        .padding(40)
    }
}
