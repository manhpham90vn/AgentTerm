import ActivityKit
import AgentTermClient
import AgentTermProtocol
import AgentTermTelemetry
import AgentTermTerminal
import SwiftUI
import UserNotifications

enum LinkStatus: Equatable {
    case connecting
    case connected
    case offline(String?)
}

/// A screen that can be pushed onto the navigation stack.
enum Route: Hashable {
    case session(SessionID)
    /// A folder's changes and history.
    case folder(String)
    /// The diff of one changed file.
    case file(folder: String, file: String, staged: Bool)
    /// A file on the Mac, to read or edit.
    case document(path: String)
}

/// A file on the Mac as it was last read.
struct RemoteFile: Equatable {
    var content: FileContent
    /// The bytes of an image.
    var data: Data?
}

struct HandoffPlan: Equatable {
    let id: String
    let prompt: String
}

/// A project folder on the Mac with the sessions running in it.
struct FolderGroup: Identifiable {
    /// `nil` is the home directory, offered when the Mac has no folders yet.
    let path: String?
    let sessions: [SessionInfo]

    var id: String { path ?? "~" }
    var name: String { path.map { ($0 as NSString).lastPathComponent } ?? "Home" }
}

@MainActor
final class PhoneModel: ObservableObject {
    /// Every Mac this iPhone is paired with.
    @Published private(set) var hosts: [SavedHost] = []
    /// The Mac on screen. There is one connection at a time, to this Mac.
    @Published private(set) var pairing: SavedHost?
    /// The sheet for pairing one more Mac.
    @Published var showPairSheet = false
    /// A pairing code is being traded for a token.
    @Published private(set) var isPairing = false
    @Published private(set) var status: LinkStatus = .offline(nil) {
        // The Live Activity can only be kept true while connected (#24).
        didSet { if status != oldValue { updateLiveActivity() } }
    }
    @Published private(set) var sessions: [SessionInfo] = []
    /// How the sessions are arranged: order, pins and groups. The Mac keeps
    /// it, and its window and every phone show the same.
    @Published var sessionLayout = TabLayout() {
        didSet {
            guard sessionLayout != oldValue, layoutKnown, !applyingHostLayout else { return }
            connection?.send(.setTabLayout(sessionLayout))
        }
    }
    /// Whether the Mac is kept awake while sessions run. Nil until the Mac
    /// has said, which an older version never does.
    @Published private(set) var keepAwake: Bool?

    /// Whether the Mac's host starts when its user logs in. Nil from a Mac
    /// that cannot do that, or that has not said yet.
    @Published private(set) var startAtLogin: Bool?
    /// Whether agents may open shells the user sees, through AgentTerm's
    /// MCP server installed in their configuration (#10). Nil when the
    /// host does not install it.
    @Published private(set) var agentShells: Bool?

    func setAgentShells(_ on: Bool) {
        agentShells = on
        connection?.send(.setAgentShells(on))
    }

    func setStartAtLogin(_ on: Bool) {
        startAtLogin = on
        connection?.send(.setStartAtLogin(on))
    }

    func setKeepAwake(_ on: Bool) {
        keepAwake = on
        connection?.send(.setKeepAwake(on))
    }

    /// The display too, only on power, and for how long. The Mac keeps
    /// them, and its Settings show the same.
    @Published private(set) var keepAwakeOptions = KeepAwakeOptions()

    func setKeepAwakeOptions(_ options: KeepAwakeOptions) {
        keepAwakeOptions = options
        connection?.send(.setKeepAwakeOptions(options))
    }

    /// How things are shown: the temperature's unit, diffs in one panel or
    /// two, changes as a list or a tree. The host keeps them, so a choice
    /// made here shows on the Mac too, and the other way round. The views
    /// read them from this app's preferences, which are written here.
    @Published private(set) var display = DisplaySettings.stored()
    func setDisplay(_ change: (inout DisplaySettings) -> Void) {
        var settings = display
        change(&settings)
        settings = settings.checked
        guard settings != display else { return }
        display = settings
        settings.store()
        connection?.send(.setDisplaySettings(settings))
    }

    /// The host's settings, or, from a host that keeps none yet, the cue
    /// to hand it this app's.
    private func hostSent(display settings: DisplaySettings?) {
        if let settings {
            display = settings.checked
            display.store()
        } else {
            connection?.send(.setDisplaySettings(display))
        }
    }

    /// Which agent writes commit messages, and how it is asked. Kept by the Mac.
    @Published private(set) var commitWriter = CommitWriterSettings()

    func setCommitWriter(_ settings: CommitWriterSettings) {
        commitWriter = settings
        connection?.send(.setCommitWriter(settings))
    }

    /// The folders an agent is writing a commit message for right now.
    @Published private(set) var writingCommitMessage: Set<String> = []

    /// Asks an agent on the Mac for the message of what is staged. The
    /// answer lands in the message field; nothing is committed.
    func writeCommitMessage(in folder: String) {
        guard status == .connected, !writingCommitMessage.contains(folder) else { return }
        writingCommitMessage.insert(folder)
        connection?.send(.writeCommitMessage(path: folder))
    }

    func cancelCommitMessage(in folder: String) {
        guard writingCommitMessage.contains(folder) else { return }
        connection?.send(.cancelCommitMessage(path: folder))
    }

    /// The agent that would write a commit message: the one chosen, or the
    /// first one installed on the Mac.
    var commitWriterAgent: AgentInfo? {
        commitWriter.writer(among: agents)
    }

    /// "push" or "pull" while one is under way in a folder.
    @Published private(set) var syncing: [String: String] = [:]

    /// Pushes the folder's branch. For a branch that follows nothing yet
    /// the Mac picks the remote the changes name, and sets it to be followed.
    func push(in folder: String) {
        guard status == .connected, syncing[folder] == nil else { return }
        syncing[folder] = "push"
        connection?.send(.gitPush(path: folder))
    }

    func pull(in folder: String) {
        guard status == .connected, syncing[folder] == nil else { return }
        syncing[folder] = "pull"
        connection?.send(.gitPull(path: folder))
    }

    /// How the Mac is doing: processor, memory, network, heat, battery, uptime.
    /// Kept apart from this model, so that figures arriving every few
    /// seconds redraw only the view that shows them, not the lists: a list
    /// that is rebuilt drops the row being dragged in it.
    let system = SystemStatsStore()

    /// The hosts of the Mac's SSH configuration.
    @Published private(set) var sshHosts: [String] = []
    /// The protocol version the Mac's host speaks. Zero until it has said.
    private var hostVersion = 0

    /// Opens `ssh <host>` on the Mac, which makes the Mac the way to that host.
    func connectSSH(_ host: String) {
        guard status == .connected else { return }
        openCreatedSession = true
        Telemetry.shared.record(.sessionStart(agent: .init(id: nil)))
        connection?.send(.connectSSH(host: host, size: startingSize))
    }

    /// How the version of AgentTerm on the Mac compares with this app's.
    @Published private(set) var hostMatch = ProtocolMatch.same
    /// Parts of AgentTerm on the Mac that stopped without being asked to:
    /// the host above all, whose sessions ended with it. Kept by the Mac
    /// until the user has seen them here or on another device.
    @Published private(set) var failures: [PartFailure] = []

    /// The user has seen it: it goes here and on every other device.
    func dismiss(_ failure: PartFailure) {
        failures.removeAll { $0.id == failure.id }
        connection?.send(.dismissFailure(id: failure.id))
    }
    /// The session being dragged in the list, from when it is picked up.
    var draggedSession: String?
    /// The folder being dragged in the list.
    var draggedFolder: String?

    /// Puts a listed folder just before another, or last. The Mac keeps
    /// the list, so its window shows the same order.
    func moveFolder(_ path: String, before target: String?) {
        guard path != target, folders.contains(path) else { return }
        connection?.send(.moveFolder(path: path, before: target))
    }

    /// Moves a listed folder one place up (-1) or down (+1).
    func moveFolder(_ path: String, by offset: Int) {
        guard let index = folders.firstIndex(of: path), folders.indices.contains(index + offset) else { return }
        moveFolder(path, before: offset < 0 ? folders[index - 1] : (folders.indices.contains(index + 2) ? folders[index + 2] : nil))
    }

    func canMoveFolder(_ path: String, by offset: Int) -> Bool {
        guard let index = folders.firstIndex(of: path) else { return false }
        return folders.indices.contains(index + offset)
    }
    /// True once the Mac on screen has listed its sessions.
    /// True once the Mac has listed its sessions.
    @Published private(set) var sessionsKnown = false
    /// The session whose earlier output is being sent, until all of it is here.
    @Published private(set) var replaying: SessionID?
    /// True once it has sent the arrangement.
    private var layoutKnown = false
    private var applyingHostLayout = false
    @Published private(set) var folders: [String] = []
    @Published private(set) var agents: [AgentInfo] = []
    @Published private(set) var agentsLoaded = false
    /// The screens on the navigation stack.
    @Published var path: [Route] = []
    /// The tab in front: "sessions", "history" or "settings".
    @Published var tab = "sessions"
    /// A folder's uncommitted changes, by folder. Without the diffs.
    @Published private(set) var diffs: [String: DiffSnapshot] = [:]
    /// The diff of a file, by `patchKey`. A missing file is stored as nil.
    @Published private(set) var patches: [String: FileDiff?] = [:]
    /// What each agent's account has used and has left, by agent.
    @Published private(set) var accountUsage: [String: AccountUsage] = [:]

    /// Asks the agents' services again.
    func refreshAccountUsage() {
        connection?.send(.accountUsage(refresh: true))
    }

    /// The files and folders in a folder of the Mac, by folder.
    @Published private(set) var fileListings: [String: [FileEntry]] = [:]
    /// Files of the Mac that were opened, by path.
    @Published private(set) var remoteFiles: [String: RemoteFile] = [:]
    /// The file being saved and not answered yet.
    @Published private(set) var savingFile: String?
    /// A file that was just created on the Mac, for the tree to open.
    @Published var createdFile: String?
    private var savingText: String?
    /// The commit message being written, by folder.
    @Published var commitDrafts: [String: String] = [:]
    /// The folder a commit was asked for and not answered yet.
    @Published private(set) var committing: String?
    /// Conversations by folder. The empty key is "everywhere on the Mac".
    @Published private(set) var histories: [String: [Conversation]] = [:]
    /// The conversation of a running session that is being handed off.
    @Published var sessionHandoff: Conversation?
    /// What the receiving agent would be told, while the handoff sheet is open.
    @Published private(set) var handoffPlan: HandoffPlan?
    /// The folder shown in the folder picker.
    @Published private(set) var listing: DirectoryListing?
    @Published var showBrowser = false
    @Published private(set) var controller: TerminalController?
    @Published private(set) var foreignSize: TermSize?
    @Published var message: String?
    @Published private(set) var fontSize: Double

    private var connection: AgentTermConnection?
    /// Where a pairing code came from, until the Mac answers it.
    private var pendingPairing: PairingInfo?
    private var openCreatedSession = false
    private var reattachAfterConnect = false
    private var retryScheduled = false
    /// Attempts to connect since the last time it worked.
    private var failedAttempts = 0
    private var active = true

    // MARK: Agents that finished or need an instruction (#22)

    /// The Mac's schedules (#11), as its host keeps them.
    @Published private(set) var schedules: [Schedule] = []

    /// Each folder's git worktrees (#23, #33), as its host lists them.
    @Published private(set) var worktrees: [String: [WorktreeInfo]] = [:]
    @Published private(set) var worktreeSetups: [String: String] = [:]
    /// What became of the last worktree that was finished.
    @Published var worktreeSaid: String?

    func listWorktrees(_ folder: String) { connection?.send(.listWorktrees(folder: folder)) }
    func finishWorktree(_ worktree: WorktreeInfo, of folder: String, _ finish: WorktreeFinish, deleteBranch: Bool) {
        connection?.send(.finishWorktree(folder: folder, path: worktree.path, finish: finish, deleteBranch: deleteBranch))
    }
    func setWorktreeSetup(_ command: String?, for folder: String) { connection?.send(.setWorktreeSetup(folder: folder, command: command)) }
    func save(_ schedule: Schedule) { connection?.send(.saveSchedule(schedule)) }
    func removeSchedule(_ id: String) { connection?.send(.removeSchedule(id: id)) }

    /// Shown as a banner while the app is in front, until it is opened or
    /// dismissed.
    @Published private(set) var agentNotice: AgentNotice?
    /// Someone is at the Mac: then nothing is told here.
    @Published private(set) var macInUse = false
    /// Whether to be told at all: a switch in the Settings tab.
    @Published var notifyAgents: Bool = UserDefaults.standard.object(forKey: "notifyAgents") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(notifyAgents, forKey: "notifyAgents")
            if notifyAgents { notifications.askOnce() }
        }
    }
    /// What was told of each Mac's sessions, so that each is told once,
    /// also across connections.
    private var told: [String: [SessionID: AgentState]] = [:]
    /// Replies given while the connection was gone, sent once it is back.
    private var pendingAnswers: [(session: SessionID, state: AgentState, text: String)] = []
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    let notifications = AgentNotifications()

    /// Tells of what the host's sessions say now, where the user is: a
    /// banner in the app, a notification just outside it.
    private func tellOfAgents(_ list: [SessionInfo]) {
        guard let mac = pairing?.id else { return }
        var known = told[mac] ?? [:]
        let notices = AgentNotice.notices(in: list, told: &known)
        told[mac] = known
        if let current = agentNotice, !list.contains(where: { $0.id == current.session && $0.state == current.state }) { agentNotice = nil }
        guard notifyAgents, !macInUse else { return }
        for notice in notices {
            // The session on screen is being looked at.
            if active, notice.session == openSessionID { continue }
            if active { agentNotice = notice } else { notifications.post(notice, mac: mac, macName: pairing?.name ?? "the Mac") }
        }
    }

    // MARK: The Live Activity (#24)

    /// Whether to show it at all: a switch in the Settings tab.
    @Published var showsLiveActivity: Bool = UserDefaults.standard.object(forKey: "showsLiveActivity") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(showsLiveActivity, forKey: "showsLiveActivity")
            updateLiveActivity()
        }
    }
    private var liveActivity: Activity<AgentsActivityAttributes>?

    /// Shown only while all three hold: the phone is connected to the Mac,
    /// nobody is at the Mac, and an agent works or waits. Ended as soon as
    /// the connection ends or the Mac is used again, since it could no longer
    /// be kept true; left showing the last state when every agent is done.
    func updateLiveActivity() {
        let working = sessions.filter { $0.state?.isWorking == true }
        let waiting = sessions.filter { $0.state?.isWaiting == true }
        let decision = LiveActivityRule.decide(
            enabled: showsLiveActivity && ActivityAuthorizationInfo().areActivitiesEnabled, connected: status == .connected, macInUse: macInUse,
            sessions: sessions)
        let wanted = decision == .show
        let state = AgentsActivityAttributes.ContentState(
            working: working.count, waiting: waiting.map(\.displayName), firstWaiting: waiting.first?.id,
            done: sessions.filter { if case .done = $0.state { return true } else { return false } }.map(\.displayName))
        let content = ActivityContent(state: state, staleDate: nil)
        if wanted {
            if let liveActivity {
                Task { await liveActivity.update(content) }
            } else {
                liveActivity = try? Activity.request(attributes: AgentsActivityAttributes(mac: pairing?.name ?? "the Mac"), content: content)
            }
        } else if let activity = liveActivity {
            liveActivity = nil
            // Done is true and stays true; anything else could go stale.
            Task { await activity.end(content, dismissalPolicy: decision == .endShowingDone ? .default : .immediate) }
        }
    }

    /// The Live Activity was touched: the session that waits, or the list.
    func openFromLink(_ url: URL) -> Bool {
        guard url.host == "session" else { return false }
        let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "id" }?.value.flatMap(UInt32.init)
        tab = "sessions"
        if let id, sessions.contains(where: { $0.id == id }) { path = [.session(id)] }
        return true
    }

    /// Opens the session a notice is about, in the Sessions tab.
    func open(_ notice: AgentNotice) {
        agentNotice = nil
        guard sessions.contains(where: { $0.id == notice.session }) else { return }
        tab = "sessions"
        path = [.session(notice.session)]
    }

    func dismissAgentNotice() { agentNotice = nil }

    /// A reply to an agent where it was told of: typed into its session by
    /// the host only while the agent still asks what it answers.
    func answer(session: SessionID, to state: AgentState, text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if status == .connected, let connection {
            connection.send(.answer(session: session, to: state, text: text))
        } else {
            pendingAnswers.append((session, state, text))
            resume()
        }
    }

    /// The app left the front: iOS lets it run a little longer, during
    /// which the connection lives and a notification can still be made.
    func enteredBackground() {
        active = false
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Agents") { [weak self] in
            guard let self else { return }
            UIApplication.shared.endBackgroundTask(self.backgroundTask)
            self.backgroundTask = .invalid
        }
    }
    private static let fontSizeKey = "terminalFontSize"
    private static let currentHostKey = "currentHost"
    static let fontSizes: ClosedRange<Double> = 9...18

    init() {
        let saved = UserDefaults.standard.double(forKey: Self.fontSizeKey)
        fontSize = Self.fontSizes.contains(saved) ? saved : 12
        hosts = PairingStore.load()
        let last = UserDefaults.standard.string(forKey: Self.currentHostKey)
        pairing = hosts.first { $0.id == last } ?? hosts.first
        notifications.model = self
        if pairing != nil { connect() }
    }

    // MARK: Derived state

    var installedAgents: [AgentInfo] { agents.filter(\.isInstalled) }

    // MARK: Arranging sessions

    /// What a folder's section lists: its sessions in the order chosen,
    /// pinned ones first, and the label of each group before its sessions.
    enum SessionItem: Identifiable {
        case label(TabGroup, count: Int)
        case session(SessionInfo)

        var id: String {
            switch self {
            case .label(let group, _): return "g:" + group.id
            case .session(let session): return session.layoutID
            }
        }
    }

    func items(for group: FolderGroup) -> [SessionItem] {
        let own = Dictionary(group.sessions.map { ($0.layoutID, $0) }, uniquingKeysWith: { $1 })
        var items: [SessionItem] = []
        var announced: Set<String> = []
        for id in sessionLayout.order {
            guard let session = own[id] else { continue }
            if let tabGroup = sessionLayout.group(of: id) {
                if announced.insert(tabGroup.id).inserted {
                    let count = sessionLayout.members(of: tabGroup.id).filter { own[$0] != nil }.count
                    items.append(.label(tabGroup, count: count))
                }
                if tabGroup.isCollapsed { continue }
            }
            items.append(.session(session))
        }
        // Sessions the arrangement has not heard of yet.
        let known = Set(sessionLayout.order)
        items += group.sessions.filter { !known.contains($0.layoutID) }.map(SessionItem.session)
        return items
    }

    /// Moves a session one place up (-1) or down (+1) among the sessions
    /// its folder shows.
    func move(_ session: SessionInfo, by offset: Int, in group: FolderGroup) {
        let shown = items(for: group).compactMap { item -> String? in
            if case .session(let info) = item { return info.layoutID } else { return nil }
        }
        guard let index = shown.firstIndex(of: session.layoutID), shown.indices.contains(index + offset) else { return }
        if offset < 0 {
            sessionLayout.move(session.layoutID, before: shown[index + offset])
        } else {
            sessionLayout.move(session.layoutID, after: shown[index + offset])
        }
    }

    func canMove(_ session: SessionInfo, by offset: Int, in group: FolderGroup) -> Bool {
        let shown = items(for: group).compactMap { item -> String? in
            if case .session(let info) = item { return info.layoutID } else { return nil }
        }
        guard let index = shown.firstIndex(of: session.layoutID) else { return false }
        return shown.indices.contains(index + offset)
    }

    /// The arrangement belongs to the Mac, which keeps it and sends it.
    private func resetSessionLayout() {
        sessionsKnown = false
        layoutKnown = false
        sessionLayout = TabLayout()
    }

    /// Brings the arrangement up to date with the sessions that run. Only
    /// sessions: the Mac's window has tabs of its own in there, for files.
    private func syncSessionLayout() {
        guard sessionsKnown, layoutKnown else { return }
        var layout = sessionLayout
        layout.sync(with: sessions.map(\.layoutID), owns: SessionInfo.isLayoutID)
        sessionLayout = layout
    }

    var groups: [FolderGroup] {
        var result = folders.map { folder in
            // A session in a worktree of the folder is the folder's (#23).
            FolderGroup(path: folder, sessions: sessions.filter { WorktreePath.belongs($0.cwd, to: folder) })
        }
        // Sessions started outside the listed folders still need a home.
        let known = Set(folders)
        let loose = Dictionary(grouping: sessions.filter { !known.contains($0.cwd) && !known.contains(WorktreePath.project(of: $0.cwd) ?? "") }, by: \.cwd)
        result += loose.keys.sorted().map { FolderGroup(path: $0, sessions: loose[$0] ?? []) }
        if result.isEmpty { result = [FolderGroup(path: nil, sessions: [])] }
        return result
    }

    func session(_ id: SessionID) -> SessionInfo? { sessions.first { $0.id == id } }

    // MARK: What was written for a session and not sent yet

    /// Kept on the phone, per Mac and session, so that leaving the terminal
    /// or closing the app does not lose a message half written. Not
    /// published: the field that shows it holds the text while it is typed.
    private var composeDrafts: [String: String] = UserDefaults.standard.dictionary(forKey: PhoneModel.composeDraftsKey) as? [String: String] ?? [:]
    private static let composeDraftsKey = "composeDrafts"

    /// Session numbers start over when the Mac's host is restarted, so the
    /// time the session began is part of what names it.
    private func composeDraftKey(for id: SessionID) -> String? {
        guard let pairing, let session = session(id) else { return nil }
        return "\(pairing.id)/\(id)/\(Int(session.createdAt.timeIntervalSince1970))"
    }

    func composeDraft(for id: SessionID) -> String {
        composeDraftKey(for: id).flatMap { composeDrafts[$0] } ?? ""
    }

    func setComposeDraft(_ text: String, for id: SessionID) {
        guard let key = composeDraftKey(for: id), composeDrafts[key] != (text.isEmpty ? nil : text) else { return }
        composeDrafts[key] = text.isEmpty ? nil : text
        UserDefaults.standard.set(composeDrafts, forKey: Self.composeDraftsKey)
    }

    /// Drops what was written for sessions of this Mac that have ended.
    private func pruneComposeDrafts(of host: String, keeping sessions: [SessionInfo]) {
        let kept = Set(sessions.map { "\(host)/\($0.id)/\(Int($0.createdAt.timeIntervalSince1970))" })
        let before = composeDrafts.count
        // Also what belonged to a Mac that is no longer paired under that name.
        let paired = Set(hosts.map(\.id))
        composeDrafts = composeDrafts.filter { draft in
            guard let owner = draft.key.split(separator: "/").first.map(String.init), paired.contains(owner) else { return false }
            return owner != host || kept.contains(draft.key)
        }
        if composeDrafts.count != before { UserDefaults.standard.set(composeDrafts, forKey: Self.composeDraftsKey) }
    }

    /// The session whose terminal is on screen, if one is on top.
    var openSessionID: SessionID? {
        if case .session(let id)? = path.last { return id }
        return nil
    }

    static func patchKey(folder: String, file: String, staged: Bool) -> String { folder + "\n" + (staged ? "staged:" : "") + file }

    /// Agents a conversation of `agent` can be handed to.
    /// The agents a conversation can be handed to. In its own folder that is
    /// every other agent; in another folder the same agent can take it too.
    func handoffTargets(from agent: String, sameFolder: Bool = true) -> [AgentInfo] {
        sameFolder ? installedAgents.filter { $0.id != agent } : installedAgents
    }

    func agentID(for session: SessionInfo) -> String {
        session.agent ?? "shell"
    }

    // MARK: Pairing

    func pair(with url: URL) {
        guard let info = PairingInfo(url: url) else {
            message = "That is not an AgentTerm pairing code. Show a new one on the Mac and try again."
            return
        }
        disconnect()
        message = nil
        pendingPairing = info
        isPairing = true
        // The code is only good for getting a token of our own, once.
        open(host: info.host, port: info.port, credential: .pairingCode(info.code))
    }

    func pair(withText text: String) {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            message = "That is not an AgentTerm pairing code."
            return
        }
        pair(with: url)
    }

    /// Shows another paired Mac. The connection moves with it.
    func select(_ host: SavedHost) {
        guard host.id != pairing?.id else { return }
        disconnect()
        clearHostState()
        setCurrent(host)
        connect()
    }

    /// True once a Mac was picked from the list of Macs: the tabs then show
    /// that Mac. The app opens on the list, so which Mac is on screen is
    /// always something the user chose.
    @Published private(set) var entered = false

    /// Picks a Mac from the list and goes into its tabs.
    func enter(_ host: SavedHost) {
        select(host)
        if connection == nil { connect() }
        path = []
        tab = "sessions"
        entered = true
    }

    /// Back to the list of Macs. The Mac that was on screen stays connected
    /// until another is picked, so coming back to it is instant.
    func showMacs() {
        entered = false
    }

    /// Forgets the Mac on screen and goes back to the list of Macs.
    func forgetMac() {
        if let pairing { forget(pairing) }
    }

    /// Forgets a paired Mac: its token is thrown away, and pairing again is
    /// the only way back to it.
    func forget(_ host: SavedHost) {
        let wasCurrent = host.id == pairing?.id
        hosts.removeAll { $0.id == host.id }
        PairingStore.save(hosts)
        pruneComposeDrafts(of: host.id, keeping: [])
        guard wasCurrent else { return }
        disconnect()
        clearHostState()
        pendingPairing = nil
        isPairing = false
        entered = false
        setCurrent(hosts.first)
        if pairing != nil { connect() }
    }

    private func setCurrent(_ host: SavedHost?) {
        pairing = host
        resetSessionLayout()
        UserDefaults.standard.set(host?.id, forKey: Self.currentHostKey)
    }

    /// What was shown belongs to the Mac that is being left.
    private func clearHostState() {
        keepAwake = nil
        startAtLogin = nil
        agentShells = nil
        keepAwakeOptions = KeepAwakeOptions()
        commitWriter = CommitWriterSettings()
        writingCommitMessage = []
        syncing = [:]
        sshHosts = []
        system.stats = nil
        hostVersion = 0
        hostMatch = .same
        failures = []
        sessions = []
        folders = []
        agents = []
        agentsLoaded = false
        diffs = [:]
        patches = [:]
        commitDrafts = [:]
        committing = nil
        accountUsage = [:]
        fileListings = [:]
        remoteFiles = [:]
        savingFile = nil
        createdFile = nil
        histories = [:]
        listing = nil
        handoffPlan = nil
    }

    // MARK: Connection

    /// Called when the app comes to the front.
    func resume() {
        active = true
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
        if pairing != nil, connection == nil {
            connect()
        } else {
            // The connection the app left behind may have died while it
            // was away. Ask, so a dead one is replaced within seconds.
            connection?.check()
        }
    }

    func retry() {
        if connection == nil { connect() }
    }

    private func connect() {
        guard let pairing else { return }
        open(host: pairing.host, port: pairing.port, credential: .token(pairing.token))
    }

    private func open(host: String, port: UInt16, credential: AgentTermConnection.Credential) {
        status = .connecting
        let connection = AgentTermConnection(host: host, port: port, credential: credential, clientName: UIDevice.current.name)
        self.connection = connection
        connection.onState = { [weak self, weak connection] state in
            MainActor.assumeIsolated {
                guard let self, let connection, self.connection === connection else { return }
                self.connectionChanged(state)
            }
        }
        connection.onMessage = { [weak self, weak connection] message in
            MainActor.assumeIsolated {
                guard let self, let connection, self.connection === connection else { return }
                self.handle(message)
            }
        }
        connection.onOutput = { [weak self] session, data in
            MainActor.assumeIsolated {
                guard let controller = self?.controller, controller.session == session else { return }
                controller.feed(data)
            }
        }
        connection.connect()
    }

    private func disconnect() {
        connection?.close()
        connection = nil
        controller = nil
        foreignSize = nil
        path = []
        showBrowser = false
        status = .offline(nil)
    }

    private func connectionChanged(_ state: AgentTermConnection.State) {
        switch state {
        case .connecting:
            break
        case .connected:
            // Wait for `welcome`: a wrong token is only known after that.
            break
        case .closed(let reason):
            connection = nil
            replaying = nil
            status = .offline(reason)
            if isPairing {
                // Pairing did not work out: the Mac refused the code, or
                // could not be reached at all.
                isPairing = false
                pendingPairing = nil
                if message == nil {
                    message = "Could not reach the Mac. Check that Tailscale is connected on this iPhone and on the Mac, then try again."
                }
                // Back to the Mac that was on screen before, if there was one.
                if pairing != nil { connect() }
            } else {
                scheduleRetry()
            }
        }
    }

    /// Keeps trying while the app is in front, so walking back into coverage
    /// reconnects without a tap.
    private func scheduleRetry() {
        guard !retryScheduled, pairing != nil else { return }
        retryScheduled = true
        // At once the first time, since most drops are over as soon as they
        // are noticed; then every few seconds while the Mac stays out of reach.
        let delay: TimeInterval = failedAttempts == 0 ? 0.5 : 3
        failedAttempts += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.retryScheduled = false
            if self.connection == nil, self.pairing != nil, UIApplication.shared.applicationState == .active {
                self.connect()
            }
        }
    }

    private func handle(_ message: ServerMessage) {
        switch message {
        case .welcome(let version, _):
            hostMatch = ProtocolMatch(host: version)
            if hostMatch != .same { Telemetry.shared.record(.versionMismatch(hostIsOlder: hostMatch == .hostOlder)) }
            status = .connected
            for answer in pendingAnswers { connection?.send(.answer(session: answer.session, to: answer.state, text: answer.text)) }
            pendingAnswers.removeAll()
            failedAttempts = 0
            reattachAfterConnect = true
            // Whatever was under way when the connection dropped got no answer.
            writingCommitMessage = []
            syncing = [:]
            connection?.send(.agents(refresh: false))
            // A Mac from before 0.4.0 does not know the request, and would
            // answer with an error for the user to wonder about.
            hostVersion = version
            if version >= 6 { connection?.send(.sshHosts) }
        case .sessions(let list):
            sessions = list
            sessionsKnown = true
            tellOfAgents(list)
            updateLiveActivity()
            if let pairing { pruneComposeDrafts(of: pairing.id, keeping: list) }
            syncSessionLayout()
            if let open = openSessionID, !list.contains(where: { $0.id == open }) {
                // The session ended: back to the screen it was opened from.
                path.removeLast()
                controller = nil
                foreignSize = nil
            }
            if reattachAfterConnect {
                reattachAfterConnect = false
                // The connection was lost while a terminal was on screen.
                if let open = openSessionID {
                    if let controller, controller.session == open, let have = controller.position, hostVersion >= 6 {
                        // The terminal is still here with all it was sent:
                        // only what the session wrote since is asked for.
                        connection?.send(.attach(session: open, size: session(open)?.size ?? .default, have: have))
                    } else {
                        controller = nil
                        self.open(open)
                    }
                }
            }
        case .agents(let list):
            agents = list
            agentsLoaded = true
        case .startAtLogin(let on):
            startAtLogin = on
        case .agentShells(let on):
            agentShells = on
        case .agentShellResult:
            // For `agenttermd mcp`, not for an app.
            break
        case .macInUse(let inUse):
            macInUse = inUse
            updateLiveActivity()
        case .schedules(let list):
            schedules = list
        case .worktrees(let folder, let list, let setup):
            worktrees[folder] = list
            worktreeSetups[folder] = setup
        case .worktreeFinished(_, _, let said):
            worktreeSaid = said
        case .keepAwake(let on):
            keepAwake = on
        case .keepAwakeOptions(let options):
            keepAwakeOptions = options
        case .commitWriter(let settings):
            commitWriter = settings
        case .displaySettings(let settings):
            hostSent(display: settings)
        case .commitMessage(let folder, let text):
            writingCommitMessage.remove(folder)
            // A draft: it goes in the field, to be read before committing.
            if let text { commitDrafts[folder] = text }
        case .sshHosts(let list):
            sshHosts = list
        case .systemStats(let stats):
            system.stats = stats
        case .tabLayout(let layout):
            layoutKnown = true
            applyingHostLayout = true
            sessionLayout = layout
            applyingHostLayout = false
            syncSessionLayout()
        case .folders(let list):
            folders = list
        case .attached(let info):
            if !sessions.contains(where: { $0.id == info.id }) { sessions.append(info) }
            if openCreatedSession {
                openCreatedSession = false
                controller = makeController(for: info.id)
                foreignSize = nil
                showBrowser = false
                // On top of wherever it was started from, so Back returns there.
                path.removeAll { if case .session = $0 { return true } else { return false } }
                path.append(.session(info.id))
                // The terminal is in the Sessions tab, wherever it was started from.
                tab = "sessions"
            }
            // What follows is the session's earlier output, until `replayed`.
            if controller?.session == info.id {
                controller?.beginReplay(size: info.size)
                replaying = info.id
            }
        case .replaying(let id, let from):
            guard let current = controller, current.session == id, current.position != from else { return }
            if current.position != nil {
                // The Mac could not go on from where this terminal stopped
                // and sends all it keeps: that is for a terminal that starts empty.
                controller = makeController(for: id)
                controller?.beginReplay(size: session(id)?.size)
            }
            controller?.position = from
        case .replayed(let id):
            if replaying == id { replaying = nil }
            if controller?.session == id { controller?.endReplay() }
        case .resized(let id, let size, let driver):
            if let index = sessions.firstIndex(where: { $0.id == id }) { sessions[index].size = size }
            guard let controller, controller.session == id else { return }
            controller.hostResized(to: size, driver: driver)
            foreignSize = controller.foreignSize
        case .exited:
            break
        case .paired(_, let token):
            Telemetry.shared.record(.devicePaired)
            guard let info = pendingPairing else { return }
            let saved = SavedHost(id: UUID().uuidString, host: info.host, port: info.port, name: info.name, token: token)
            // Pairing again with a Mac replaces what was saved for it.
            hosts.removeAll { $0.host == saved.host && $0.port == saved.port }
            hosts.append(saved)
            PairingStore.save(hosts)
            clearHostState()
            setCurrent(saved)
            pendingPairing = nil
            isPairing = false
            showPairSheet = false
            // A Mac that was just paired is the one to look at.
            path = []
            tab = "sessions"
            entered = true
        case .error(let text):
            if text == "invalid token" {
                let name = pairing?.name ?? "The Mac"
                forgetMac()
                self.message = "\(name) removed this iPhone from its paired devices. Pair it again to reconnect."
            } else if text == "invalid pairing code" {
                self.message = "That pairing code has expired or was already used. Show a new one on the Mac and try again."
            } else if text == "malformed message" {
                // A Mac from before 0.4.0 does not know what was asked and
                // will never answer it.
                openCreatedSession = false
                writingCommitMessage = []
                syncing = [:]
                self.message = "The AgentTerm on the Mac is an older version and cannot do this. Update it, and restart its host."
            } else {
                // A request that was going to open a session failed.
                openCreatedSession = false
                // So did a commit, if one was waiting. Its message is kept.
                committing = nil
                // And a save: the edits stay in the editor.
                savingFile = nil
                self.message = text
            }
        case .diff(let folder, let snapshot):
            diffs[folder] = snapshot
            if committing == folder {
                // The answer to a commit that git accepted: an error would have come first.
                committing = nil
                commitDrafts[folder] = nil
            }
        case .gitSynced(let folder):
            // Not at the `diff` before it: one asked for while git was still
            // at work would free the buttons for a second push beside the first.
            syncing[folder] = nil
        case .diffFile(let folder, let file):
            // The host answers per folder; the file asked for is the one waiting.
            if let file {
                patches[Self.patchKey(folder: folder, file: file.path, staged: file.isStaged)] = file
            } else if let waiting = pendingPatch, waiting.folder == folder {
                patches[Self.patchKey(folder: folder, file: waiting.file, staged: waiting.staged)] = .some(nil)
            }
            pendingPatch = nil
        case .history(let folder, let conversations):
            histories[folder ?? ""] = conversations
            if let session = pendingSessionHandoff, folder == session.cwd {
                pendingSessionHandoff = nil
                // The session's conversation is the newest one its agent has
                // in that folder since the session started.
                let agent = agentID(for: session)
                let own = conversations.filter { $0.agent == agent }
                let current = self.session(session.id) ?? session
                // The Mac already worked out which conversation the session
                // is having; without that, the newest one since it started.
                if let found = own.first(where: { $0.sessionID == current.conversationID })
                    ?? own.first(where: { $0.updatedAt >= session.createdAt.addingTimeInterval(-5) })
                {
                    sessionHandoff = found
                } else {
                    self.message = "\(session.title) has no conversation to hand off in this session yet. It saves one after your first message."
                }
            }
        case .directory(let listing):
            self.listing = listing
        case .handoffPlan(let id, let prompt):
            handoffPlan = HandoffPlan(id: id, prompt: prompt)
        case .accountUsage(let list):
            accountUsage = Dictionary(list.map { ($0.agent, $0) }, uniquingKeysWith: { $1 })
        case .files(let directory, let entries):
            fileListings[directory] = entries
        case .file(let path, let content, let data):
            remoteFiles[path] = RemoteFile(content: content, data: data)
        case .fileSaved(let path):
            if savingFile == path, let text = savingText { remoteFiles[path] = RemoteFile(content: .text(text), data: nil) }
            savingFile = nil
            savingText = nil
        case .fileCreated(let path, let isDirectory):
            if !isDirectory { createdFile = path }
        case .failures(let list):
            failures = list
        case .pairingCode, .devices:
            break
        }
    }

    private func makeController(for id: SessionID) -> TerminalController {
        let controller = TerminalController(session: id, fontSize: fontSize)
        controller.onInput = { [weak self] data in self?.connection?.sendInput(data, to: id) }
        controller.onResize = { [weak self] size in self?.connection?.send(.resize(session: id, size: size)) }
        controller.onClaim = { [weak self] size in self?.connection?.send(.takeControl(session: id, size: size)) }
        return controller
    }

    // MARK: Actions

    /// The grid a new session should start with. The terminal screen is not
    /// on screen yet, so its room is worked out from the screen: all of the
    /// width, and the height left by the bars above and below. The width is
    /// what matters, since a wrong one makes the shell draw its first prompt
    /// for a width the terminal does not have.
    private var startingSize: TermSize {
        let screen = UIScreen.main.bounds.size
        let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        let safe = window?.safeAreaInsets ?? .zero
        let width = (window?.bounds.width ?? screen.width) - safe.left - safe.right - 6
        // Navigation bar, key bar and compose field take about this much.
        let height = (window?.bounds.height ?? screen.height) - safe.top - safe.bottom - 44 - 52 - 56 - 4
        return TerminalMetrics.grid(for: CGSize(width: width, height: height), fontSize: fontSize) ?? TermSize(cols: 48, rows: 30)
    }

    /// Starts an agent, or a shell when `agent` is nil, and opens it.
    func launch(_ agent: AgentInfo?, in folder: String?) {
        guard status == .connected else { return }
        openCreatedSession = true
        Telemetry.shared.record(.sessionStart(agent: .init(id: agent?.id)))
        connection?.send(.create(CreateRequest(command: agent?.id, cwd: folder, title: agent?.name, size: startingSize)))
    }

    /// Attaches to a session so its terminal can be shown.
    func open(_ id: SessionID) {
        guard controller?.session != id else { return }
        controller = makeController(for: id)
        foreignSize = nil
        // Attach with the size the session already has; ours follows after layout.
        connection?.send(.attach(session: id, size: session(id)?.size ?? .default))
    }

    /// Stops watching a session. The Mac gets its own size back.
    func leave(_ id: SessionID) {
        guard controller?.session == id else { return }
        connection?.send(.detach(session: id))
        controller = nil
        foreignSize = nil
    }

    // MARK: Changes, history, folders

    private var pendingPatch: (folder: String, file: String, staged: Bool)?
    /// A running session whose conversation is being looked up to hand off.
    private var pendingSessionHandoff: SessionInfo?

    func loadDiff(_ folder: String) {
        connection?.send(.diff(path: folder))
    }

    func loadPatch(folder: String, file: String, staged: Bool) {
        pendingPatch = (folder, file, staged)
        connection?.send(.diffFile(path: folder, file: file, staged: staged))
    }

    // MARK: Files

    func loadFiles(_ directory: String) {
        connection?.send(.files(path: directory))
    }

    func loadFile(_ path: String) {
        connection?.send(.readFile(path: path))
    }

    func saveFile(_ path: String, text: String) {
        guard savingFile == nil else { return }
        savingFile = path
        savingText = text
        connection?.send(.writeFile(path: path, text: text))
    }

    func createFile(named name: String, in directory: String, isDirectory: Bool) {
        connection?.send(.createFile(directory: directory, name: name, isDirectory: isDirectory))
    }

    func renameFile(_ path: String, to name: String) {
        remoteFiles[path] = nil
        connection?.send(.renameFile(path: path, name: name))
    }

    func trashFile(_ path: String) {
        remoteFiles[path] = nil
        connection?.send(.trashFile(path: path))
    }

    /// Stages files for the next commit. No files means every change.
    func stage(_ files: [String], in folder: String) {
        connection?.send(.gitStage(path: folder, files: files))
    }

    /// Takes files out of the next commit. No files means all of them.
    func unstage(_ files: [String], in folder: String) {
        connection?.send(.gitUnstage(path: folder, files: files))
    }

    /// Commits what is staged with the message written for the folder.
    func commit(in folder: String) {
        guard committing == nil, let message = commitDrafts[folder] else { return }
        committing = folder
        connection?.send(.gitCommit(path: folder, message: message))
    }

    /// `folder` nil loads every conversation on the Mac.
    func loadHistory(_ folder: String?) {
        connection?.send(.history(path: folder))
    }

    /// Reopens a conversation in its agent and shows its terminal.
    func resume(_ conversation: Conversation) {
        guard status == .connected else { return }
        openCreatedSession = true
        connection?.send(.resume(agent: conversation.agent, sessionID: conversation.sessionID, cwd: conversation.cwd, size: startingSize))
    }

    /// Asks the Mac what the receiving agent would be told, to show it.
    func requestHandoffPlan(for conversation: Conversation) {
        handoffPlan = nil
        connection?.send(.handoffPlan(agent: conversation.agent))
    }

    /// Hands a conversation's work to another agent and shows its terminal.
    /// `prompt` is the plan's prompt as the user left it.
    /// `folder` is where the receiving agent starts; nil is the conversation's own folder.
    func handoff(_ conversation: Conversation, to target: AgentInfo, prompt: String, note: String, in folder: String? = nil) {
        guard status == .connected else { return }
        openCreatedSession = true
        let plan = handoffPlan
        let edited = plan.map { prompt != $0.prompt } ?? false
        Telemetry.shared.record(
            .handoff(from: .init(id: conversation.agent), to: .init(id: target.id), otherFolder: folder != nil && folder != conversation.cwd))
        connection?.send(
            .handoff(
                agent: conversation.agent, sessionID: conversation.sessionID, cwd: conversation.cwd,
                target: target.id, plan: plan?.id, prompt: edited ? prompt : nil, note: note, size: startingSize, folder: folder
            ))
        handoffPlan = nil
    }

    /// Forgets the folder last looked at, so the next browse starts at home.
    func forgetListing() { listing = nil }

    /// Shows the folders inside `path`, or inside the home folder.
    func browse(_ path: String?) {
        connection?.send(.listDirectory(path: path))
    }

    func addFolder(_ path: String) {
        connection?.send(.addFolder(path: path))
    }

    /// Takes a folder off the list the Mac and the iPhone share. Its sessions
    /// keep running.
    func removeFolder(_ path: String) {
        connection?.send(.removeFolder(path: path))
    }

    /// True when a session runs an agent whose work could go to another one.
    func canHandOff(_ session: SessionInfo) -> Bool {
        let agent = agentID(for: session)
        return agent != "shell" && !handoffTargets(from: agent).isEmpty
    }

    /// Finds the conversation a running session is having, to hand it off.
    func requestHandoff(session: SessionInfo) {
        guard status == .connected else { return }
        pendingSessionHandoff = session
        connection?.send(.history(path: session.cwd))
    }

    func end(_ id: SessionID) {
        connection?.send(.kill(session: id))
    }

    func takeControl() {
        controller?.claimSize()
    }

    func refreshAgents() {
        agentsLoaded = false
        connection?.send(.agents(refresh: true))
        if hostVersion >= 6 { connection?.send(.sshHosts) }
    }

    func changeFontSize(by delta: Double) {
        let size = min(max(fontSize + delta, Self.fontSizes.lowerBound), Self.fontSizes.upperBound)
        guard size != fontSize else { return }
        fontSize = size
        UserDefaults.standard.set(size, forKey: Self.fontSizeKey)
        controller?.setFontSize(size)
    }
}

/// Local notifications of agents that finished or need an instruction (#22).
/// There is no push through Apple: the app makes them itself, from what the
/// host says over its connection, while iOS lets the app run.
final class AgentNotifications: NSObject, UNUserNotificationCenterDelegate {
    weak var model: PhoneModel?
    private static let replyCategory = "agent-reply"
    private static let openCategory = "agent-open"
    private var asked = false

    override init() {
        super.init()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        // A reply runs something on the Mac: the phone is unlocked first.
        let reply = UNTextInputNotificationAction(
            identifier: "reply", title: "Reply", options: [.authenticationRequired], textInputButtonTitle: "Send", textInputPlaceholder: "Your answer")
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.replyCategory, actions: [reply], intentIdentifiers: [], options: [.hiddenPreviewsShowTitle]),
            UNNotificationCategory(identifier: Self.openCategory, actions: [], intentIdentifiers: [], options: [.hiddenPreviewsShowTitle]),
        ])
    }

    /// Asks iOS, the first time, whether the app may notify.
    func askOnce() {
        guard !asked else { return }
        asked = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(_ notice: AgentNotice, mac: String, macName: String) {
        askOnce()
        let content = UNMutableNotificationContent()
        content.title = "\(notice.name) \(notice.why)"
        content.subtitle = "\((notice.folder as NSString).lastPathComponent) on \(macName)"
        // What the agent said shows only where iOS shows previews: by
        // default not on the lock screen.
        content.body = notice.detail ?? ""
        content.sound = .default
        content.threadIdentifier = "\(mac)-\(notice.session)"
        content.categoryIdentifier = notice.takesAReply ? Self.replyCategory : Self.openCategory
        content.userInfo = [
            "mac": mac, "session": Int(notice.session),
            "state": String(decoding: MessageCoding.encode(notice.state), as: UTF8.self),
        ]
        let request = UNNotificationRequest(identifier: "\(mac)-\(notice.session)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let session = (info["session"] as? Int).map { SessionID(truncatingIfNeeded: $0) }
        let state = (info["state"] as? String).flatMap { MessageCoding.decode(AgentState.self, from: Data($0.utf8)) }
        DispatchQueue.main.async { [weak self] in
            defer { completionHandler() }
            guard let model = self?.model, let session, let state, model.pairing?.id == info["mac"] as? String else { return }
            if let reply = response as? UNTextInputNotificationResponse {
                model.answer(session: session, to: state, text: reply.userText)
            } else if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
                model.open(AgentNotice(session: session, name: "", folder: "", state: state))
            }
        }
    }

    /// In front, the app shows its own banner instead.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([])
    }
}
