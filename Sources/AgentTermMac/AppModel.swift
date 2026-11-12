import AgentTermClient
import AgentTermHost
import AgentTermProtocol
import AgentTermTelemetry
import AgentTermTerminal
import AppKit
import Combine
import SwiftUI

struct PairingCode: Equatable {
    let code: String
    let expiresAt: Date
}

struct Folder: Identifiable, Hashable {
    let path: String
    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
}

enum ConnectionStatus: Equatable {
    case connecting
    case connected
    case failed(String)
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var status: ConnectionStatus = .connecting
    @Published private(set) var folders: [Folder] = []
    @Published private(set) var sessions: [SessionInfo] = []
    @Published private(set) var agents: [AgentInfo] = []
    @Published private(set) var agentsLoaded = false
    @Published var selectedFolder: String? { didSet { if selectedFolder != oldValue { folderChanged() } } }
    @Published var selectedSession: SessionID?
    /// Sessions currently sized by another device, with that device's grid.
    @Published private(set) var foreignSizes: [SessionID: TermSize] = [:]
    @Published private(set) var diff: DiffSnapshot?
    /// The change whose diff has a tab in the middle pane, with the folder
    /// it is in. The tab keeps both: looking at a session of another folder
    /// changes which folder the side panel shows, and must not close it.
    @Published private(set) var diffTab: OpenDiff?

    struct OpenDiff: Equatable {
        let folder: String
        var file: FileDiff
    }
    /// Whether the diff's tab is the one in front.
    @Published private(set) var diffInFront = false
    private var observers: Set<AnyCancellable> = []
    /// The commit message being written, by folder.
    @Published var commitMessages: [String: String] = [:]
    @Published private(set) var isCommitting = false
    /// What each agent's account has used and has left, by agent.
    @Published private(set) var accountUsage: [String: AccountUsage] = [:]

    /// Asks the agents' services again.
    func refreshAccountUsage() {
        connection?.send(.accountUsage(refresh: true))
    }

    /// How the running host's version compares with this app's. A host
    /// keeps running across an update of the app, so after one it can be
    /// the old version's.
    @Published private(set) var hostMatch = ProtocolMatch.same

    /// Stops the host that is running and starts this app's own in its
    /// place. Its sessions end with it.
    func restartHost() {
        stoppingHost = true
        let port = port
        hostMatch = .same
        otherHost = nil
        otherHostPID = nil
        launchedDaemon = false
        connectAttempts = 0
        DispatchQueue.global(qos: .userInitiated).async {
            if let listener = DaemonLauncher.listener(onPort: port) { DaemonLauncher.stop(listener.pid) }
        }
    }

    /// Set when the host that answered is not the one this app ships with:
    /// the path of that other host. It may be an older version.
    @Published private(set) var otherHost: String?
    private var otherHostPID: pid_t?

    /// Looks at which program is the host, off the main thread.
    private func checkWhoseHost() {
        let port = port
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let listener = DaemonLauncher.listener(onPort: port)
            let foreign = listener.flatMap { DaemonLauncher.isBundled($0.path) ? nil : $0 }
            DispatchQueue.main.async {
                self?.otherHost = foreign?.path
                self?.otherHostPID = foreign?.pid
            }
        }
    }

    /// Stops the other copy's host and starts this app's own in its place.
    /// The sessions the other host holds end with it.
    func replaceOtherHost() {
        guard let pid = otherHostPID else { return }
        stoppingHost = true
        otherHost = nil
        otherHostPID = nil
        // The connection closes when the host goes; reconnecting then
        // starts the bundled one.
        launchedDaemon = false
        connectAttempts = 0
        DaemonLauncher.stop(pid)
    }

    /// How the tabs of the middle pane are arranged: order, pins and groups.
    /// The host keeps it, so the phones show the same pins and groups.
    @Published var tabLayout = AppModel.savedTabLayout() {
        didSet {
            guard tabLayout != oldValue else { return }
            saveTabLayout()
            if tabLayoutKnown, !applyingHostLayout { connection?.send(.setTabLayout(tabLayout)) }
        }
    }
    /// True once the host has sent the arrangement it keeps.
    var tabLayoutKnown = false
    private var applyingHostLayout = false

    /// Whether the Mac is kept awake while sessions run. Nil until the host
    /// has said, which an older host never does.
    @Published private(set) var keepAwake: Bool?

    func setKeepAwake(_ on: Bool) {
        keepAwake = on
        connection?.send(.setKeepAwake(on))
    }

    /// The display too, only on power, and for how long. The host keeps
    /// them, so the iPhone shows the same.
    @Published private(set) var keepAwakeOptions = KeepAwakeOptions()

    func setKeepAwakeOptions(_ options: KeepAwakeOptions) {
        keepAwakeOptions = options
        connection?.send(.setKeepAwakeOptions(options))
    }

    /// How things are shown: the temperature's unit, diffs in one panel or
    /// two, changes as a list or a tree. The host keeps them, so a choice
    /// made here shows on the iPhone too, and the other way round. The views
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

    /// Which agent writes commit messages, and how it is asked. Kept by the host.
    @Published private(set) var commitWriter = CommitWriterSettings()

    func setCommitWriter(_ settings: CommitWriterSettings) {
        commitWriter = settings
        connection?.send(.setCommitWriter(settings))
    }

    /// The folders an agent is writing a commit message for right now.
    @Published private(set) var writingCommitMessage: Set<String> = []

    /// Asks an agent for the message of what is staged in the selected
    /// folder. The host runs it; the answer lands in the message field.
    func writeCommitMessage() {
        guard let directory = selectedFolder, status == .connected, !writingCommitMessage.contains(directory) else { return }
        writingCommitMessage.insert(directory)
        connection?.send(.writeCommitMessage(path: directory))
    }

    func cancelCommitMessage() {
        guard let directory = selectedFolder, writingCommitMessage.contains(directory) else { return }
        connection?.send(.cancelCommitMessage(path: directory))
    }

    /// How this Mac is doing: processor, memory, network, heat, battery, uptime.
    /// Kept apart from this model, so that figures arriving every few
    /// seconds redraw only the view that shows them.
    let system = SystemStatsStore()

    /// The hosts of this Mac's SSH configuration, as the host read them.
    @Published private(set) var sshHosts: [String] = []

    func refreshSSHHosts() {
        // A host from before 0.4.0 does not know the request, and would
        // answer with an error for the user to wonder about.
        guard hostVersion >= 6 else { return }
        connection?.send(.sshHosts)
    }

    /// The protocol version the running host speaks. Zero until it has said.
    private var hostVersion = 0

    /// Opens `ssh <host>` in a new session.
    func connectSSH(_ host: String) {
        guard status == .connected else { return }
        lastError = nil
        selectNextAttached = true
        Telemetry.shared.record(.sessionStart(agent: .init(id: nil)))
        connection?.send(.connectSSH(host: host, size: startingSize))
    }

    /// "push" or "pull" while one is under way in a folder.
    @Published private(set) var syncing: [String: String] = [:]
    /// A first push that waits to be confirmed: it gives the branch an upstream.
    @Published var pendingFirstPush: FirstPush?

    struct FirstPush: Identifiable {
        let folder: String
        let branch: String
        let remote: String
        var id: String { folder + branch }
    }

    /// Pushes the selected folder's branch. A branch that follows nothing
    /// yet is asked about first, saying where it would go.
    func push() {
        guard let directory = selectedFolder, let diff, let branch = diff.branch else { return }
        if diff.upstream == nil, let remote = diff.pushRemote {
            pendingFirstPush = FirstPush(folder: directory, branch: branch, remote: remote)
        } else {
            sync("push", in: directory) { GitActions.push(in: $0) }
        }
    }

    func pushConfirmed(_ push: FirstPush) {
        sync("push", in: push.folder) { GitActions.push(in: $0) }
    }

    func pull() {
        guard let directory = selectedFolder else { return }
        sync("pull", in: directory) { GitActions.pull(in: $0) }
    }

    private func sync(_ what: String, in directory: String, _ action: @escaping (String) -> String?) {
        guard syncing[directory] == nil else { return }
        syncing[directory] = what
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let problem = action(directory)
            DispatchQueue.main.async {
                guard let self else { return }
                self.syncing[directory] = nil
                if let problem { self.notice = problem }
                self.refreshDiff()
                self.files.refresh()
            }
        }
    }

    /// True once the host has listed its sessions.
    var sessionsKnown = false

    /// True between the host's welcome and the connection closing.
    private var wasConnected = false
    /// True while the host is being stopped on purpose.
    private var stoppingHost = false

    /// The tab being dragged in the strip, from the moment it is picked up.
    var draggedTab: String?
    /// The folder being dragged in the list.
    var draggedFolder: String?

    /// A request to close many tabs that would end running sessions, and so
    /// waits to be confirmed.
    @Published var pendingCloseRequest: CloseRequest?

    /// Closing every tab but the one named. Nothing named closes them all.
    struct CloseRequest: Identifiable {
        var keepSession: SessionID?
        var keepFile: String?
        var keepDiff = false
        let id = UUID()
    }
    /// Past agent conversations of the selected folder. `nil` while loading.
    @Published private(set) var history: [Conversation]?
    /// History lists the selected folder's conversations, or every
    /// conversation on this Mac when this is on.
    @Published var historyShowsAll = UserDefaults.standard.bool(forKey: "historyShowsAll") {
        didSet {
            guard historyShowsAll != oldValue else { return }
            UserDefaults.standard.set(historyShowsAll, forKey: "historyShowsAll")
            history = nil
            refreshHistory()
        }
    }
    /// The folder list on the left.
    @Published var showSidebar = UserDefaults.standard.object(forKey: "showSidebar") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showSidebar, forKey: "showSidebar") }
    }
    /// The Git and History panel on the right.
    @Published var showDiff = UserDefaults.standard.object(forKey: "showSidePanel") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showDiff, forKey: "showSidePanel") }
    }
    @Published var showPairing = false
    @Published private(set) var lastError: String?
    /// Shown in an alert, for problems that are not tied to the launch screen.
    @Published var notice: String?
    /// Point size of the terminal text, for every session.
    @Published private(set) var terminalFontSize: Double = {
        let saved = UserDefaults.standard.double(forKey: "terminalFontSize")
        return AppModel.fontSizes.contains(saved) ? saved : AppModel.defaultFontSize
    }()
    static let fontSizes: ClosedRange<Double> = 9...24
    static let defaultFontSize: Double = 13

    /// The room the terminal has in the window, measured by the view.
    var terminalArea: CGSize = .zero

    /// The grid a new session should start with: what fits the terminal's
    /// place in the window, so its first output is drawn for the right width.
    private var startingSize: TermSize {
        TerminalMetrics.grid(for: terminalArea, fontSize: terminalFontSize)
            ?? currentController?.naturalSize
            ?? TermSize(cols: 100, rows: 30)
    }

    /// The Files tab's tree and open file, for the selected folder.
    let files = FilesModel()

    /// Devices that were paired with this Mac.
    @Published private(set) var devices: [DeviceInfo] = []
    /// The pairing code on show, while the pairing sheet is open.
    @Published private(set) var pairingCode: PairingCode?
    /// The device that used the code on show, to confirm it in the sheet.
    @Published private(set) var justPaired: DeviceInfo?
    /// The conversation being handed off, while its sheet is open.
    @Published var pendingHandoff: Conversation?

    private var connection: AgentTermConnection?
    private var controllers: [SessionID: TerminalController] = [:]
    private var port = agenttermDefaultPort
    private var connectAttempts = 0
    private var launchedDaemon = false
    private var selectNextAttached = false
    private var diffTimer: Timer?
    private var diffGeneration = 0
    private var historyGeneration = 0
    private let foldersKey = "folders"
    private var pendingFolderSelection: String?

    init() {
        if let value = ProcessInfo.processInfo.environment["AGENTTERM_PORT"].flatMap(UInt16.init) { port = value }
        connect()
        folderChanged()
        // A file that comes to the front takes the diff's place there.
        files.$active.sink { [weak self] active in
            if active != nil { self?.diffInFront = false }
        }.store(in: &observers)
        // The arrangement of the tabs follows the tabs that exist.
        $sessions.combineLatest(files.$documents, $diffTab, $diff)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.syncTabs() }
            .store(in: &observers)
        // The SSH configuration may have been edited while the app was behind.
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.refreshSSHHosts() }
            .store(in: &observers)
        diffTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.showDiff, NSApp.isActive else { return }
                self.refreshDiff()
            }
        }
    }

    // MARK: Derived state

    var installedAgents: [AgentInfo] { agents.filter(\.isInstalled) }

    var currentController: TerminalController? { selectedSession.flatMap { controllers[$0] } }

    /// A folder's sessions in the order of the tabs, so the list on the
    /// left and the strip of tabs agree, and arranging one arranges both.
    func sessions(in folder: Folder) -> [SessionInfo] { inTabOrder(sessions.filter { $0.cwd == folder.path }) }

    func inTabOrder(_ list: [SessionInfo]) -> [SessionInfo] {
        let place = Dictionary(tabLayout.order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return list.enumerated().sorted { a, b in
            let pa = place[TabID.session(a.element)] ?? Int.max, pb = place[TabID.session(b.element)] ?? Int.max
            return pa != pb ? pa < pb : a.offset < b.offset
        }.map(\.element)
    }

    /// Sessions started somewhere that is not one of the listed folders.
    var looseSessions: [SessionInfo] {
        let known = Set(folders.map(\.path))
        return sessions.filter { !known.contains($0.cwd) }
    }

    var workingDirectory: String { selectedFolder ?? HostEnvironment.homeDirectory }

    // MARK: Connection

    private func connect() {
        guard let token = try? HostEnvironment.loadOrCreateToken() else {
            status = .failed("Could not read the pairing token.")
            return
        }
        let connection = AgentTermConnection(host: "127.0.0.1", port: port, token: token, clientName: "Mac")
        self.connection = connection
        connection.onState = { [weak self, weak connection] state in
            MainActor.assumeIsolated {
                guard let self, let connection, self.connection === connection else { return }
                self.connectionChanged(state)
            }
        }
        connection.onMessage = { [weak self] message in
            MainActor.assumeIsolated { self?.handle(message) }
        }
        connection.onOutput = { [weak self] session, data in
            MainActor.assumeIsolated { self?.controllers[session]?.feed(data) }
        }
        connection.connect()
    }

    private func connectionChanged(_ state: AgentTermConnection.State) {
        switch state {
        case .connecting:
            break
        case .connected:
            connectAttempts = 0
            status = .connected
            connection?.send(.agents(refresh: false))
            checkWhoseHost()
        case .closed(let reason):
            // The host went away under a working connection, and not because
            // the user asked for it to be restarted: worth a report.
            if wasConnected, !stoppingHost { Telemetry.shared.recordProblem(.hostExitedUnexpectedly) }
            wasConnected = false
            stoppingHost = false
            connection = nil
            controllers.removeAll()
            sessionsKnown = false
            keepAwake = nil
            hostVersion = 0
            system.stats = nil
            sshHosts = []
            writingCommitMessage = []
            syncing = [:]
            hostMatch = .same
            tabLayoutKnown = false
            sessions = []
            foreignSizes = [:]
            selectedSession = nil
            retryConnection(reason: reason)
        }
    }

    /// The daemon may simply not be running yet: start it, then keep trying
    /// for a few seconds before giving up.
    private func retryConnection(reason: String?) {
        if !launchedDaemon, let executable = DaemonLauncher.bundledExecutable {
            launchedDaemon = true
            DaemonLauncher.launch(executable: executable, arguments: ["--port", String(port)])
        }
        connectAttempts += 1
        guard connectAttempts <= 20 else {
            status = .failed(reason ?? "The AgentTerm host is not running.")
            return
        }
        status = .connecting
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.connection == nil else { return }
            self.connect()
        }
    }

    func reconnect() {
        connectAttempts = 0
        launchedDaemon = false
        status = .connecting
        connect()
    }

    private func handle(_ message: ServerMessage) {
        switch message {
        case .welcome(let version, _):
            hostVersion = version
            refreshSSHHosts()
            hostMatch = ProtocolMatch(host: version)
            if hostMatch != .same { Telemetry.shared.record(.versionMismatch(hostIsOlder: hostMatch == .hostOlder)) }
            wasConnected = true
        case .sessions(let list):
            sessionsKnown = true
            sessions = list
            // Pick up sessions that were already running before this window opened.
            for info in list where controllers[info.id] == nil {
                connection?.send(.attach(session: info.id, size: info.size))
            }
        case .agents(let list):
            agents = list
            agentsLoaded = true
        case .keepAwake(let on):
            keepAwake = on
        case .keepAwakeOptions(let options):
            keepAwakeOptions = options
        case .commitWriter(let settings):
            commitWriter = settings
        case .displaySettings(let settings):
            hostSent(display: settings)
        case .commitMessage(let path, let message):
            writingCommitMessage.remove(path)
            // The agent's answer is a draft: it goes in the field, to be
            // read and changed before anything is committed.
            if let message { commitMessages[path] = message }
        case .sshHosts(let list):
            sshHosts = list
        case .systemStats(let stats):
            system.stats = stats
        case .tabLayout(let layout):
            let first = !tabLayoutKnown
            tabLayoutKnown = true
            if first, layout.order.isEmpty, !tabLayout.order.isEmpty {
                // A host that has none yet takes the one saved here.
                connection?.send(.setTabLayout(tabLayout))
            } else {
                applyingHostLayout = true
                tabLayout = layout
                applyingHostLayout = false
            }
            // Outside the guard: what this window adds or drops is sent on.
            syncTabs()
        case .folders(let list):
            folders = list.map(Folder.init)
            // A diff of a folder that is no longer listed has nowhere to go back to.
            if let tab = diffTab, !list.contains(tab.folder) { closeDiffTab() }
            if selectedFolder == nil || !list.contains(selectedFolder ?? "") { selectedFolder = list.first }
            migrateLocalFolders(known: list)
        case .attached(let info):
            if controllers[info.id] == nil { controllers[info.id] = makeController(for: info.id) }
            // What follows is the session's earlier output, until `replayed`.
            controllers[info.id]?.beginReplay(size: info.size)
            if !sessions.contains(where: { $0.id == info.id }) { sessions.append(info) }
            if selectNextAttached || selectedSession == nil {
                // A session that was just started comes to the front, also
                // when a file was showing.
                if selectNextAttached {
                    files.active = nil
                    diffInFront = false
                }
                selectNextAttached = false
                selectedSession = info.id
            }
        case .replayed(let id):
            controllers[id]?.endReplay()
        case .resized(let id, let size, let driver):
            if let index = sessions.firstIndex(where: { $0.id == id }) { sessions[index].size = size }
            guard let controller = controllers[id] else { return }
            controller.hostResized(to: size, driver: driver)
            foreignSizes[id] = controller.foreignSize
        case .exited(let id, _):
            controllers[id] = nil
            foreignSizes[id] = nil
            sessions.removeAll { $0.id == id }
            if selectedSession == id {
                selectedSession = sessions.last(where: { $0.cwd == workingDirectory })?.id ?? sessions.last?.id
            }
        case .error(let text):
            lastError = text
            // What stopped an agent from writing a commit message is said
            // where the user is looking, not on the launch screen.
            if !writingCommitMessage.isEmpty {
                // A host from before 0.4.0 does not know the request and
                // will never answer it.
                let unknown = text == "malformed message"
                notice = unknown ? "The host that is running is from an older version of AgentTerm and cannot do this. Restart the host." : text
                if unknown { writingCommitMessage = [] }
            }
        case .pairingCode(let code, let expiresAt):
            pairingCode = PairingCode(code: code, expiresAt: expiresAt)
        case .devices(let list):
            // A device that appears while a code is on show used that code.
            if pairingCode != nil, let new = list.first(where: { device in !devices.contains { $0.id == device.id } }) {
                justPaired = new
                pairingCode = nil
            }
            devices = list
        case .accountUsage(let list):
            accountUsage = Dictionary(list.map { ($0.agent, $0) }, uniquingKeysWith: { $1 })
        case .paired, .diff, .gitSynced, .replaying, .diffFile, .history, .directory, .handoffPlan, .files, .file, .fileSaved, .fileCreated:
            // The Mac app reads changes, history and folders directly: it
            // runs on the machine they are on.
            break
        }
    }

    private func makeController(for id: SessionID) -> TerminalController {
        let controller = TerminalController(session: id, fontSize: terminalFontSize)
        controller.onInput = { [weak self] data in self?.connection?.sendInput(data, to: id) }
        controller.onResize = { [weak self] size in self?.connection?.send(.resize(session: id, size: size)) }
        controller.onClaim = { [weak self] size in self?.connection?.send(.takeControl(session: id, size: size)) }
        return controller
    }

    // MARK: Actions

    /// Starts an agent, or a plain shell when `agent` is nil, in the selected folder.
    func launch(_ agent: AgentInfo?) {
        guard status == .connected else { return }
        lastError = nil
        selectNextAttached = true
        let size = startingSize
        Telemetry.shared.record(.sessionStart(agent: .init(id: agent?.id)))
        connection?.send(.create(CreateRequest(command: agent?.id, cwd: workingDirectory, title: agent?.name, size: size)))
    }

    /// Makes the terminal text larger or smaller, or default when `delta` is nil.
    func changeFontSize(by delta: Double?) {
        let wanted = delta.map { terminalFontSize + $0 } ?? Self.defaultFontSize
        let size = min(max(wanted, Self.fontSizes.lowerBound), Self.fontSizes.upperBound)
        guard size != terminalFontSize else { return }
        terminalFontSize = size
        UserDefaults.standard.set(size, forKey: "terminalFontSize")
        controllers.values.forEach { $0.setFontSize(size) }
    }

    func close(_ session: SessionID) {
        connection?.send(.kill(session: session))
    }

    func takeControl() {
        currentController?.claimSize()
    }

    func refreshAgents() {
        agentsLoaded = false
        connection?.send(.agents(refresh: true))
    }

    func select(session: SessionInfo) {
        files.active = nil
        diffInFront = false
        selectedSession = session.id
        if folders.contains(where: { $0.path == session.cwd }) { selectedFolder = session.cwd }
    }

    func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose project folders to work in"
        guard panel.runModal() == .OK else { return }
        // The host owns the list, so other devices see the same folders.
        for url in panel.urls { connection?.send(.addFolder(path: url.path)) }
        if let first = panel.urls.first { pendingFolderSelection = first.standardizedFileURL.path }
    }

    func remove(_ folder: Folder) {
        connection?.send(.removeFolder(path: folder.path))
    }

    /// Adds folders dropped on the list, from the Finder for one.
    func addFolders(_ urls: [URL]) {
        let folders = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
        for url in folders { connection?.send(.addFolder(path: url.path)) }
        if let first = folders.first { pendingFolderSelection = first.standardizedFileURL.path }
    }

    /// Puts a folder just before another in the list, or last. The host
    /// owns the list, so the phones show the same order.
    func moveFolder(_ path: String, before target: String?) {
        guard path != target else { return }
        connection?.send(.moveFolder(path: path, before: target))
    }

    /// Moves a folder one place up (-1) or down (+1).
    func moveFolder(_ folder: Folder, by offset: Int) {
        guard let index = folders.firstIndex(of: folder), folders.indices.contains(index + offset) else { return }
        // Down: before the one after the next, or last.
        let target = offset < 0 ? folders[index - 1].path : (folders.indices.contains(index + 2) ? folders[index + 2].path : nil)
        moveFolder(folder.path, before: target)
    }

    /// Earlier builds kept the folder list in this app's preferences. Hand
    /// those folders to the host once.
    private func migrateLocalFolders(known: [String]) {
        if let pending = pendingFolderSelection, known.contains(pending) {
            pendingFolderSelection = nil
            selectedFolder = pending
        }
        guard let saved = UserDefaults.standard.stringArray(forKey: foldersKey) else { return }
        UserDefaults.standard.removeObject(forKey: foldersKey)
        for path in saved where !known.contains(path) { connection?.send(.addFolder(path: path)) }
    }

    // MARK: Changes

    private func folderChanged() {
        diff = nil
        // The diff tab stays: it belongs to its own folder, not to the one on show.
        files.setRoot(selectedFolder)
        refreshDiff()
        // The list of every conversation does not depend on the folder.
        if !historyShowsAll {
            history = nil
            refreshHistory()
        }
    }

    // MARK: Handoff

    /// Agents a conversation of `agent` can be handed to.
    /// The agents a conversation can be handed to. In its own folder that is
    /// every other agent; in another folder the same agent can take it too.
    func handoffTargets(from agent: String, sameFolder: Bool = true) -> [AgentInfo] {
        sameFolder ? installedAgents.filter { $0.id != agent } : installedAgents
    }

    func agentID(of session: SessionInfo) -> String? {
        session.agent
    }

    /// How many tabs the strip shows.
    var tabCount: Int { visibleTabs.count }

    /// Shows the tab in the given place of the strip, counted from 1.
    func selectTab(number: Int) {
        let tabs = visibleTabs
        if tabs.indices.contains(number - 1) { selectTab(id: tabs[number - 1]) }
    }

    /// Shows the tab `offset` places after the one in front, wrapping.
    func selectTab(offset: Int) {
        let tabs = visibleTabs
        guard !tabs.isEmpty else { return }
        let current = frontTabID.flatMap { tabs.firstIndex(of: $0) } ?? (offset > 0 ? -1 : 0)
        selectTab(id: tabs[(current + offset + tabs.count) % tabs.count])
    }

    /// Closes the tabs of files and the diff, leaving the terminals. A file
    /// given as `kept` stays open too; `keepDiff` leaves the diff tab.
    /// Pinned tabs are closed one at a time only, never with the rest.
    func closeFileTabs(except kept: String? = nil, keepDiff: Bool = false) {
        if !keepDiff, !tabLayout.isPinned(TabID.diff) { closeDiffTab() }
        files.closeAll(except: kept, keeping: pinnedFilePaths)
    }

    /// The sessions a request would end.
    func sessionsEnded(by request: CloseRequest) -> [SessionInfo] {
        sessions.filter { $0.id != request.keepSession && !tabLayout.isPinned(TabID.session($0)) }
    }

    /// Closes every tab but the one the request keeps. Sessions are running
    /// programs, so ending any is asked about first.
    func closeTabs(_ request: CloseRequest = CloseRequest()) {
        if sessionsEnded(by: request).isEmpty { closeTabsConfirmed(request) } else { pendingCloseRequest = request }
    }

    func closeTabsConfirmed(_ request: CloseRequest) {
        closeFileTabs(except: request.keepFile, keepDiff: request.keepDiff)
        for session in sessionsEnded(by: request) { close(session.id) }
        // What was kept comes to the front.
        if let kept = request.keepSession, let session = sessions.first(where: { $0.id == kept }) {
            // Not past a file with unsaved changes that is asking what to do.
            if files.pendingClose == nil { select(session: session) }
        } else if let kept = request.keepFile {
            if files.pendingClose == nil { files.active = kept }
        } else if request.keepDiff {
            if files.pendingClose == nil { showDiffTab() }
        }
    }

    /// Closes the tab in front: a file is closed, a session is ended.
    func closeFrontTab() {
        if diffInFront {
            closeDiffTab()
        } else if let path = files.active {
            files.requestClose(path)
        } else if let id = selectedSession {
            close(id)
        }
    }

    /// Opens the handoff sheet for a conversation.
    func requestHandoff(_ conversation: Conversation) {
        guard !handoffTargets(from: conversation.agent).isEmpty else {
            notice = "No other agent is installed to hand this off to."
            return
        }
        pendingHandoff = conversation
    }

    /// Opens the handoff sheet for what a running session is working on. The
    /// session's conversation is the newest one its agent has in that folder.
    func requestHandoff(session: SessionInfo) {
        guard let agent = agentID(of: session) else { return }
        let name = session.title
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let conversations = AgentHistory.conversations(in: session.cwd).filter { $0.agent == agent }
            // The host already worked out which conversation the session is
            // having; without that, the newest one since it started.
            let newest =
                conversations.first { $0.sessionID == session.conversationID }
                ?? conversations.first { $0.updatedAt >= session.createdAt.addingTimeInterval(-5) }
            DispatchQueue.main.async {
                guard let self else { return }
                if let newest {
                    self.requestHandoff(newest)
                } else {
                    self.notice = "\(name) has no conversation to hand off in this session yet. It saves one after your first message."
                }
            }
        }
    }

    /// Passes a conversation on to another agent: writes the handoff file,
    /// then starts `target` in a new session with a prompt to read it.
    /// `note` is what the user wants the receiving agent to know.
    /// `plan` and `prompt` are what the handoff sheet showed, the prompt
    /// possibly edited there.
    /// `folder` is where the receiving agent starts: the conversation's own
    /// folder, or another one to carry the work over to.
    func handoff(_ conversation: Conversation, to target: AgentInfo, plan: Handoff.Plan, prompt: String, note: String, in folder: String? = nil) {
        guard status == .connected else { return }
        Telemetry.shared.record(
            .handoff(from: .init(id: conversation.agent), to: .init(id: target.id), otherFolder: folder != nil && folder != conversation.cwd))
        let size = startingSize
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try Handoff.prepare(conversation, to: target.id, plan: plan, prompt: prompt, note: note, in: folder) }
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let prepared):
                    self.selectNextAttached = true
                    self.connection?.send(.create(CreateRequest(command: prepared.command, cwd: prepared.directory, title: target.name, size: size)))
                    // The new session lives in the folder it was handed to:
                    // that folder is shown, and added to the list if it is
                    // new, so its changes and files are what the side panel has.
                    if self.folders.contains(where: { $0.path == prepared.directory }) {
                        self.selectedFolder = prepared.directory
                    } else {
                        self.pendingFolderSelection = prepared.directory
                        self.connection?.send(.addFolder(path: prepared.directory))
                    }
                case .failure(let error):
                    self.notice = "\(error)"
                }
            }
        }
    }

    // MARK: History

    func refreshHistory() {
        let everywhere = historyShowsAll
        let directory = selectedFolder
        guard everywhere || directory != nil else {
            history = []
            return
        }
        historyGeneration += 1
        let generation = historyGeneration
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let found = everywhere ? AgentHistory.allConversations() : AgentHistory.conversations(in: directory ?? "")
            DispatchQueue.main.async {
                guard let self, generation == self.historyGeneration,
                    self.historyShowsAll == everywhere, everywhere || self.selectedFolder == directory
                else { return }
                if self.history != found { self.history = found }
            }
        }
    }

    /// Reopens a past conversation in its agent, in a new session.
    func resume(_ conversation: Conversation) {
        guard status == .connected else { return }
        lastError = nil
        selectNextAttached = true
        let size = startingSize
        let name = agents.first { $0.id == conversation.agent }?.name
        connection?.send(.create(CreateRequest(command: conversation.resumeCommand, cwd: conversation.cwd, title: name, size: size)))
    }

    func refreshDiff() {
        guard let directory = selectedFolder else {
            diff = nil
            return
        }
        diffGeneration += 1
        let generation = diffGeneration
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let snapshot = GitDiff.snapshot(directory: directory)
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == self.diffGeneration, self.selectedFolder == directory else { return }
                if self.diff != snapshot { self.diff = snapshot }
                if let tab = self.diffTab, tab.folder == directory {
                    // The tab shows the change as it is now. A file that was
                    // just staged or unstaged is followed into its new list.
                    let now = snapshot.files.first { $0.id == tab.file.id } ?? snapshot.files.first { $0.path == tab.file.path }
                    if let now {
                        if now != tab.file { self.diffTab = OpenDiff(folder: directory, file: now) }
                    } else {
                        // A change that is gone, committed for one, takes its tab with it.
                        self.closeDiffTab()
                    }
                }
            }
        }
    }

    /// The change that has a tab in the middle pane, if any.
    var diffTabFile: FileDiff? { diffTab?.file }

    /// The change to mark in the Git tab's list: the diff tab's, while the
    /// list is of its folder.
    var diffTabFileInList: FileDiff? { diffTab?.folder == selectedFolder ? diffTab?.file : nil }

    /// Shows a change's diff in the middle pane. There is one diff tab; it
    /// follows the change picked in the Git tab.
    func openDiff(_ file: FileDiff) {
        guard let folder = selectedFolder else { return }
        diffTab = OpenDiff(folder: folder, file: file)
        showDiffTab()
    }

    func showDiffTab() {
        guard let tab = diffTab else { return }
        files.active = nil
        diffInFront = true
        // Its folder comes with it, as a session's does: the Git tab lists
        // that folder's changes, staging acts on it, and the diff is read again.
        if selectedFolder != tab.folder, folders.contains(where: { $0.path == tab.folder }) { selectedFolder = tab.folder }
    }

    func closeDiffTab() {
        diffTab = nil
        diffInFront = false
    }

    /// Stages files for the next commit. No files means every change.
    func stage(_ files: [FileDiff]) {
        let paths = files.map(\.path)
        git { GitActions.stage(paths, in: $0) }
    }

    /// Takes files out of the next commit. No files means all of them.
    func unstage(_ files: [FileDiff]) {
        let paths = files.map(\.path)
        git { GitActions.unstage(paths, in: $0) }
    }

    /// Commits what is staged in the selected folder with the message written for it.
    func commit() {
        guard let directory = selectedFolder, !isCommitting else { return }
        let message = commitMessages[directory] ?? ""
        isCommitting = true
        git({ GitActions.commit(message: message, in: $0) }) { [weak self] succeeded in
            self?.isCommitting = false
            if succeeded { self?.commitMessages[directory] = nil }
        }
    }

    /// Runs a git change in the selected folder off the main thread, then
    /// shows what git said if it failed and reads the changes again.
    private func git(_ action: @escaping (String) -> String?, then: ((Bool) -> Void)? = nil) {
        guard let directory = selectedFolder else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let problem = action(directory)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let problem { self.notice = problem }
                then?(problem == nil)
                self.refreshDiff()
                self.files.refresh()
            }
        }
    }

    // MARK: Pairing

    /// Asks the host for a fresh pairing code. Earlier codes stop working.
    func requestPairingCode() {
        justPaired = nil
        pairingCode = nil
        connection?.send(.createPairingCode)
    }

    /// Called when the pairing sheet closes: a code nobody is looking at
    /// should not keep working.
    func cancelPairingCode() {
        pairingCode = nil
        justPaired = nil
        connection?.send(.cancelPairingCode)
    }

    /// Takes a device's access away. It has to be paired again to come back.
    func revoke(_ device: DeviceInfo) {
        connection?.send(.revokeDevice(id: device.id))
    }

    var hostPort: UInt16 { port }
}
