import AgentTermEditor
import AgentTermProtocol
import AgentTermTerminal
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var files: FilesModel

    private var closeQuestion: String {
        guard let request = model.pendingCloseRequest else { return "" }
        let count = model.sessionsEnded(by: request).count
        let kept = request.keepSession != nil || request.keepFile != nil || request.keepDiff
        return "End \(count) \(count == 1 ? "session" : "sessions") and close \(kept ? "every other tab" : "every tab")?"
    }

    // The questions are worked out here rather than where they are asked:
    // inside the long chain of the window's sheets and dialogs each of them
    // is one more thing the compiler has to work out at once, and on a slow
    // machine it gives up.
    private var saveQuestion: String {
        let name = files.pendingClose.map { ($0 as NSString).lastPathComponent } ?? ""
        return "Save changes to \"\(name)\"?"
    }

    private var endQuestion: String {
        let name = model.pendingEnd?.displayName ?? "this session"
        return "End \(name)?"
    }

    private var pushQuestion: String {
        guard let push = model.pendingFirstPush else { return "" }
        return "Push “\(push.branch)” to \(push.remote)?"
    }

    var body: some View {
        HStack(spacing: 0) {
            ActivityBar()
            Theme.hairline.frame(width: 1)
            panes
        }
        .background(Theme.canvas)
    }

    private var panes: some View {
        HSplitView {
            if model.showSidebar {
                PlaceList()
                    .frame(minWidth: 210, idealWidth: 250, maxWidth: 380)
            }
            // In parts of their own: in one expression, the compiler of a
            // slower machine (CodeQL's) gave up on it.
            MiddleColumn()
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
            // In Sessions only: in History, Schedules and Settings what is in
            // the middle is what is looked at, and the folder's changes and
            // files have nothing to do with it.
            if model.showDiff && model.place == .sessions {
                RightPanel()
                    .frame(minWidth: 310, idealWidth: 420, maxWidth: 760)
            }
        }
        .background(Theme.canvas)
        .toolbar {
            // The list at the left is hidden from the bar of places, at the
            // window's edge. Middle: which Mac all of the window is about, then starting an
            // agent on it, the main thing to do here. Pairing an iPhone or
            // another Mac is what sets the app apart, so it sits with them
            // and stands out.
            ToolbarItem(placement: .principal) {
                HStack(spacing: 10) {
                    MacSwitcher()
                    Theme.hairline.frame(width: 1, height: 16)
                    LaunchBar()
                    // Pairing a device is done on the Mac it is paired with.
                    if !model.isRemote {
                        Theme.hairline.frame(width: 1, height: 16)
                        PairButton()
                    }
                }
            }
            // Without this flexible space the items below sit right after
            // the agents instead of at the window's edge.
            ToolbarItem(placement: .primaryAction) {
                Spacer()
            }
            // Far right: the side panel's toggle, in the corner above the
            // panel it hides; only where the panel is, in Sessions.
            ToolbarItemGroup(placement: .primaryAction) {
                if model.place == .sessions {
                    Button {
                        model.showDiff.toggle()
                    } label: {
                        Label("Side Panel", systemImage: "sidebar.trailing")
                    }
                    .help(model.showDiff ? "Hide the side panel" : "Show the side panel")
                }
            }
        }
        .sheet(isPresented: $model.showPairing) {
            PairingView(port: model.hostPort)
        }
        .sheet(isPresented: $model.showPairMac) {
            PairMacSheet()
        }
        .sheet(isPresented: $model.showBrowseFolders) {
            BrowseFoldersSheet()
        }
        .confirmationDialog(
            saveQuestion,
            isPresented: Binding(get: { files.pendingClose != nil }, set: { if !$0 { files.pendingClose = nil } }),
            titleVisibility: .visible, presenting: files.pendingClose
        ) { path in
            Button("Save") { files.saveAndClose(path) }
            Button("Don't Save", role: .destructive) { files.close(path) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            endQuestion,
            isPresented: Binding(get: { model.pendingEnd != nil }, set: { if !$0 { model.pendingEnd = nil } }),
            titleVisibility: .visible, presenting: model.pendingEnd
        ) { session in
            Button("End Session", role: .destructive) { model.close(session.id) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The program running in it is stopped.")
        }
        .confirmationDialog(
            closeQuestion,
            isPresented: Binding(get: { model.pendingCloseRequest != nil }, set: { if !$0 { model.pendingCloseRequest = nil } }),
            titleVisibility: .visible, presenting: model.pendingCloseRequest
        ) { request in
            Button("End Sessions and Close", role: .destructive) { model.closeTabsConfirmed(request) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("What is running in the terminals stops. Files with unsaved changes stay open.")
        }
        .confirmationDialog(
            pushQuestion,
            isPresented: Binding(get: { model.pendingFirstPush != nil }, set: { if !$0 { model.pendingFirstPush = nil } }),
            titleVisibility: .visible, presenting: model.pendingFirstPush
        ) { push in
            Button("Push") { model.pushConfirmed(push) }
            Button("Cancel", role: .cancel) {}
        } message: { push in
            Text("The branch does not follow a branch on a remote yet. It is pushed as \(push.remote)/\(push.branch), which it follows from then on.")
        }
        .sheet(item: $model.pendingHandoff) { conversation in
            HandoffSheet(conversation: conversation)
        }
        .sheet(item: $model.panelConversation) { conversation in
            ConversationSheet(conversation: conversation)
        }
        .alert("AgentTerm", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.notice ?? "")
        }
        // The new worktree starts from the last commit (#23).
        .alert("The folder has changes that are not committed", isPresented: Binding(get: { model.worktreeQuestion != nil }, set: { if !$0 { model.worktreeQuestion = nil } })) {
            Button("Start in a New Worktree") {
                let question = model.worktreeQuestion
                model.worktreeQuestion = nil
                if case .agent(let agent)? = question { model.launchInWorktree(agent, confirmed: true) } else { model.launchInWorktree(nil, confirmed: true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "A new worktree starts from the last commit, without them: the agent there will not see them. Nothing git ignores is brought along either, such as .env or node_modules; a setup command for the folder can bring what is needed."
            )
        }
        .alert("Worktree", isPresented: Binding(get: { model.worktreeSaid != nil }, set: { if !$0 { model.worktreeSaid = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.worktreeSaid ?? "")
        }
    }
}

/// "Start in a New Worktree", in an agent's launch menu (#23).
private struct WorktreeLaunchItem: View {
    @EnvironmentObject private var model: AppModel
    let agent: AgentInfo?

    var body: some View {
        Button("Start \(agent?.name ?? "a Shell") in a New Worktree") { model.launchInWorktree(agent) }
            .disabled(model.selectedFolder == nil || model.diff?.branch == nil)
    }
}

/// Quick launch buttons for the agents that are installed, plus a plain shell.
struct LaunchBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 6) {
            ForEach(model.installedAgents) { agent in
                LaunchButton(title: agent.name, id: agent.id) { model.launch(agent) }
                    .help("Start \(agent.name) in \(model.workingDirectory). Its menu starts it in a new worktree.")
                    .contextMenu { WorktreeLaunchItem(agent: agent) }
            }
            LaunchButton(title: "Shell", id: "shell") { model.launch(nil) }
                .help("Start a shell in \(model.workingDirectory)")
                .contextMenu { WorktreeLaunchItem(agent: nil) }
            SSHMenu()
        }
        .disabled(model.status != .connected)
    }
}

/// The hosts of `~/.ssh/config`, each opening `ssh <host>` as a session.
/// Not shown when the configuration names none.
struct SSHMenu: View {
    @EnvironmentObject private var model: AppModel
    var large = false

    var body: some View {
        if !model.sshHosts.isEmpty {
            Menu {
                Section("Hosts in ~/.ssh/config") {
                    ForEach(model.sshHosts, id: \.self) { host in
                        Button(host) { model.connectSSH(host) }
                    }
                }
            } label: {
                HStack(spacing: large ? 8 : 6) {
                    Image(systemName: Theme.symbol(for: "ssh"))
                        .font(.system(size: large ? 13 : 11, weight: .semibold))
                        .foregroundStyle(Theme.accent(for: "ssh"))
                    Text("SSH")
                        .font(.system(size: large ? 13 : 12, weight: .medium))
                    Image(systemName: "chevron.down")
                        .font(.system(size: large ? 9 : 8, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                // One element to assistive tools, not one per part of the label.
                .accessibilityElement(children: .ignore)
                .padding(.horizontal, large ? 14 : 10)
                .padding(.vertical, large ? 9 : 5)
                .background(RoundedRectangle(cornerRadius: large ? 9 : 7, style: .continuous).fill(Theme.raised))
                .overlay(RoundedRectangle(cornerRadius: large ? 9 : 7, style: .continuous).strokeBorder(Theme.hairline))
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Open a session on a host of this Mac's SSH configuration")
            .accessibilityLabel("SSH")
        }
    }
}

/// Opens the pairing sheet. Filled, so it is the one button of the toolbar
/// that catches the eye.
struct PairButton: View {
    @EnvironmentObject private var model: AppModel
    @State private var hovering = false

    private static let tint = Color(red: 0.33, green: 0.52, blue: 0.96)

    var body: some View {
        Button {
            model.showPairing = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "qrcode").font(.system(size: 11, weight: .bold))
                Text("Pair Device").font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Self.tint.opacity(hovering ? 1 : 0.88))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Pair an iPhone or another Mac to use this Mac's sessions from it")
        .accessibilityLabel("Pair Device")
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

/// Shown when the host in use belongs to another copy of the app.
/// Shown when the host that is running speaks another version of the
/// protocol than this app: most often the old host, still running after the
/// app was updated.
private struct HostVersionBanner: View {
    @EnvironmentObject private var model: AppModel
    let match: ProtocolMatch
    @State private var confirming = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 2) {
                Text(match == .hostOlder ? "The host that is running is from an older version of AgentTerm." : "The host that is running is from a newer version of AgentTerm.")
                    .font(.system(size: 12, weight: .medium))
                Text(
                    match == .hostOlder
                        ? "It kept running when the app was updated. Some things will not work until it is restarted."
                        : "Update this app, or restart the host to use this app's own. Some things will not work until then."
                )
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            }
            Spacer(minLength: 8)
            // Another Mac's host is restarted on that Mac, by its own app.
            if !model.isRemote {
                Button("Restart Host…") { confirming = true }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.yellow.opacity(0.12))
        .confirmationDialog(
            model.sessions.isEmpty ? "Restart the host?" : "Restart the host and end \(model.sessions.count) \(model.sessions.count == 1 ? "session" : "sessions")?",
            isPresented: $confirming, titleVisibility: .visible
        ) {
            Button("Restart Host", role: .destructive) { model.restartHost() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The running host is stopped and this app's own is started. Whatever runs in its sessions stops.")
        }
    }
}

/// A part of AgentTerm that stopped without being asked to: which part,
/// what ended with it, and whether it was started again.
private struct FailureBanner: View {
    @EnvironmentObject private var model: AppModel
    let failure: PartFailure

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(failure.headline(on: model.remote?.name))
                    .font(.system(size: 12, weight: .medium))
                Text(failure.details)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Button("Dismiss") { model.dismiss(failure) }
                .controlSize(.small)
                .help("Seen: no longer shown here or on the other devices")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
    }
}

/// An agent of a session that is not in front finished its task or waits
/// for the user (#22): which session, and why. Touching it opens it.
private struct AgentNoticeBanner: View {
    @EnvironmentObject private var model: AppModel
    let notice: AgentNotice

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: AgentStateMark.symbol(for: notice.state)).foregroundStyle(AgentStateMark.color(for: notice.state))
            VStack(alignment: .leading, spacing: 2) {
                Text("\(notice.name) \(notice.why)")
                    .font(.system(size: 12, weight: .medium))
                if let detail = notice.detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            Button("Open") { model.open(notice) }
                .controlSize(.small)
            Button("Dismiss") { model.dismissAgentNotice() }
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(AgentStateMark.color(for: notice.state).opacity(0.12))
        .contentShape(Rectangle())
        .onTapGesture { model.open(notice) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent-notice")
    }
}

private struct OtherHostBanner: View {
    @EnvironmentObject private var model: AppModel
    let path: String
    @State private var confirming = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 2) {
                Text("These sessions are held by the host of another copy of AgentTerm.")
                    .font(.system(size: 12, weight: .medium))
                Text((path as NSString).abbreviatingWithTildeInPath + ". It may be another version, and things may not work as they should.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button("Use This App's Host…") { confirming = true }
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.yellow.opacity(0.12))
        .confirmationDialog(
            model.sessions.isEmpty ? "Restart the host with this app's own?" : "Restart the host and end \(model.sessions.count) \(model.sessions.count == 1 ? "session" : "sessions")?",
            isPresented: $confirming, titleVisibility: .visible
        ) {
            Button("Restart Host", role: .destructive) { model.replaceOtherHost() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The other host is stopped and this app's own is started. Whatever runs in its sessions stops.")
        }
    }
}

struct CenterView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var files: FilesModel
    @State private var showingUsage = false

    var body: some View {
        ZStack {
            Theme.canvas
            switch model.status {
            case .connecting:
                VStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text(model.remote.map { "Connecting to \($0.name)…" } ?? "Starting the AgentTerm host…").foregroundStyle(.secondary)
                }
            case .failed(let reason):
                VStack(spacing: 12) {
                    Image(systemName: "bolt.horizontal.circle").font(.system(size: 34)).foregroundStyle(.secondary)
                    Text(model.remote.map { "Can't reach \($0.name)" } ?? (model.hostBroken ? "The AgentTerm host keeps stopping" : "Can't reach the AgentTerm host"))
                        .font(.headline)
                    // How the last one ended may be known only after it was said that it keeps stopping.
                    Text(model.hostBroken && !model.isRemote ? model.brokenReason : reason)
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .frame(maxWidth: 520)
                    Button("Try Again") { model.reconnect() }
                    if model.isRemote { Button("Use This Mac") { model.switchTo(nil) } }
                }
                .padding(40)
            case .connected:
                if model.diffInFront, let file = model.diffTabFile {
                    // The diff tab is in front.
                    VStack(spacing: 0) {
                        SessionTabs()
                        DiffDocumentView(file: file)
                    }
                } else if let document = files.activeDocument {
                    // A file tab is in front.
                    VStack(spacing: 0) {
                        SessionTabs()
                        DocumentView(document: document)
                    }
                } else if let controller = model.currentController {
                    VStack(spacing: 0) {
                        SessionTabs()
                        let info = model.sessions.first { $0.id == controller.session }
                        if let size = model.foreignSizes[controller.session] {
                            ForeignSizeBanner(size: size)
                        }
                        let foreign = model.foreignSizes[controller.session]
                        TerminalPane(controller: controller, foreignSize: foreign)
                            .id(controller.session)
                            .overlay {
                                // The session's earlier output is on its
                                // way, megabytes of it: a terminal racing
                                // through that says less than a word that
                                // it is loading.
                                if model.replaying.contains(controller.session) {
                                    LoadingView("Loading the session…", cover: Theme.canvas.opacity(0.92))
                                }
                            }
                            // The framed preview of another device's screen
                            // is centered, so it gets no one-sided padding.
                            .padding(.horizontal, foreign == nil ? TerminalInsets.horizontal : 0)
                            .padding(.top, foreign == nil ? TerminalInsets.top : 0)
                            // Room under the last row. The rows fill the
                            // pane from the top, so what is left over under
                            // them is anything from nothing to almost a
                            // row: without this, the last line (an agent's
                            // status line) can sit right on the edge.
                            .padding(.bottom, foreign == nil ? TerminalInsets.bottom : 0)
                            .background(TerminalAreaReader(insets: foreign == nil ? TerminalInsets.total : CGSize(width: 10, height: 12)))
                        if let info, let agent = info.agent {
                            // What the agent's session has used, under its terminal.
                            Theme.hairline.frame(height: 1)
                            UsageBar(agent: agent, name: info.title, usage: info.usage, account: model.accountUsage[agent]) {
                                showingUsage = true
                            }
                            .background(Theme.panel)
                            .help("Show the account's usage")
                            .popover(isPresented: $showingUsage, arrowEdge: .bottom) {
                                ScrollView {
                                    UsageDetails(agent: agent, name: info.title, usage: info.usage, account: model.accountUsage[agent]) {
                                        model.refreshAccountUsage()
                                    }
                                }
                                .frame(width: 380)
                                .frame(maxHeight: 520)
                            }
                        }
                    }
                } else {
                    VStack(spacing: 0) {
                        SessionTabs()
                        WelcomeView().frame(maxWidth: .infinity, maxHeight: .infinity)
                            // Where a terminal would go, less its padding,
                            // and less the strip of tabs it will have then.
                            .background(TerminalAreaReader(insets: TerminalInsets.total, stripShown: !model.sessions.isEmpty || !files.documents.isEmpty || model.diffTabFile != nil))
                    }
                }
            }
        }
    }
}

/// Tells the model how much room a terminal has, so a new session can be
/// started at the size it will be shown at.
/// The list at the window's left: the place's own.
private struct PlaceList: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        switch model.place {
        case .sessions: SidebarView()
        case .history: HistorySidebar()
        case .schedules: SchedulesSidebar()
        case .settings: SettingsSections()
        }
    }
}

/// The middle of the window: how the Mac is doing, what stopped, a notice,
/// and the terminals with the place over them.
private struct MiddleColumn: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            // Right under the launch buttons: how this Mac is doing,
            // with its sessions only.
            if model.place == .sessions { SystemStatsLine(store: model.system) }
            Banners()
            // History and Settings over the terminals rather than in
            // their place, which would start them again when left.
            ZStack {
                Terminals()
                PlaceInTheMiddle()
            }
        }
    }
}

private struct Banners: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let path = model.otherHost {
            OtherHostBanner(path: path)
        } else if model.hostMatch != .same {
            HostVersionBanner(match: model.hostMatch)
        }
        // What stopped without being asked to, until it is dismissed.
        ForEach(model.failures) { failure in
            FailureBanner(failure: failure)
        }
        // An agent of another session finished, or waits for you.
        if let notice = model.agentNotice {
            AgentNoticeBanner(notice: notice)
        }
    }
}

private struct Terminals: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let shown = model.place == .sessions
        CenterView()
            .overlay {
                // A conversation resumed, a handoff: until its session is here.
                if let starting = model.starting { LoadingView(starting, cover: Theme.canvas.opacity(0.92)) }
            }
            .opacity(shown ? 1 : 0)
            .allowsHitTesting(shown)
            .accessibilityHidden(!shown)
    }
}

private struct PlaceInTheMiddle: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        switch model.place {
        case .sessions: EmptyView()
        case .history: ConversationDetail()
        case .schedules: SchedulesView().background(Theme.canvas)
        case .settings: SettingsPane()
        }
    }
}

/// Room around the terminal, so its text does not sit on the pane's edges.
enum TerminalInsets {
    static let horizontal: CGFloat = 14
    static let top: CGFloat = 10
    static let bottom: CGFloat = 8
    /// What the padding takes off the terminal's area.
    static let total = CGSize(width: 2 * horizontal, height: top + bottom)
}

private struct TerminalAreaReader: View {
    @EnvironmentObject private var model: AppModel
    /// What to take off for the padding a terminal gets.
    let insets: CGSize
    /// False on the launch screen with no session: the strip of tabs a
    /// session brings is taken off too.
    var stripShown = true

    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { report(proxy.size) }
                .onChange(of: proxy.size) { _, size in report(size) }
        }
    }

    private func report(_ size: CGSize) {
        let strip = stripShown ? 0 : model.tabStripHeight
        model.terminalArea = CGSize(width: size.width - insets.width, height: size.height - insets.height - strip)
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
                Text(model.selectedFolder.map { ($0 as NSString).lastPathComponent } ?? "AgentTerm")
                    .font(.system(size: 22, weight: .semibold))
                Text(
                    model.selectedFolder == nil
                        ? "Add a project folder, then start an agent in it."
                        : "Start an agent in this folder."
                )
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
                        .contextMenu { WorktreeLaunchItem(agent: agent) }
                }
                LaunchButton(title: "Shell", id: "shell", large: true) { model.launch(nil) }
                    .contextMenu { WorktreeLaunchItem(agent: nil) }
                SSHMenu(large: true)
            }
            if model.agentsLoaded && model.installedAgents.isEmpty {
                VStack(spacing: 6) {
                    Text("No agent CLI was found on \(model.macName).")
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
