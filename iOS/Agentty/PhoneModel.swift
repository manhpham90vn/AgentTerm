import AgenttyClient
import AgenttyProtocol
import AgenttyTerminal
import SwiftUI

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
    case file(folder: String, file: String)
    /// Every conversation on the Mac.
    case allHistory
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
    @Published private(set) var status: LinkStatus = .offline(nil)
    @Published private(set) var sessions: [SessionInfo] = []
    @Published private(set) var folders: [String] = []
    @Published private(set) var agents: [AgentInfo] = []
    @Published private(set) var agentsLoaded = false
    /// The screens on the navigation stack.
    @Published var path: [Route] = []
    /// A folder's uncommitted changes, by folder. Without the diffs.
    @Published private(set) var diffs: [String: DiffSnapshot] = [:]
    /// The diff of a file, by `patchKey`. A missing file is stored as nil.
    @Published private(set) var patches: [String: FileDiff?] = [:]
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

    private var connection: AgenttyConnection?
    /// Where a pairing code came from, until the Mac answers it.
    private var pendingPairing: PairingInfo?
    private var openCreatedSession = false
    private var reattachAfterConnect = false
    private var retryScheduled = false
    private var active = true
    private static let fontSizeKey = "terminalFontSize"
    private static let currentHostKey = "currentHost"
    static let fontSizes: ClosedRange<Double> = 9...18

    init() {
        let saved = UserDefaults.standard.double(forKey: Self.fontSizeKey)
        fontSize = Self.fontSizes.contains(saved) ? saved : 12
        hosts = PairingStore.load()
        let last = UserDefaults.standard.string(forKey: Self.currentHostKey)
        pairing = hosts.first { $0.id == last } ?? hosts.first
        if pairing != nil { connect() }
    }

    // MARK: Derived state

    var installedAgents: [AgentInfo] { agents.filter(\.isInstalled) }

    var groups: [FolderGroup] {
        var result = folders.map { folder in
            FolderGroup(path: folder, sessions: sessions.filter { $0.cwd == folder })
        }
        // Sessions started outside the listed folders still need a home.
        let known = Set(folders)
        let loose = Dictionary(grouping: sessions.filter { !known.contains($0.cwd) }, by: \.cwd)
        result += loose.keys.sorted().map { FolderGroup(path: $0, sessions: loose[$0] ?? []) }
        if result.isEmpty { result = [FolderGroup(path: nil, sessions: [])] }
        return result
    }

    func session(_ id: SessionID) -> SessionInfo? { sessions.first { $0.id == id } }

    /// The session whose terminal is on screen, if one is on top.
    var openSessionID: SessionID? {
        if case .session(let id)? = path.last { return id }
        return nil
    }

    static func patchKey(folder: String, file: String) -> String { folder + "\n" + file }

    /// Agents a conversation of `agent` can be handed to.
    func handoffTargets(from agent: String) -> [AgentInfo] {
        installedAgents.filter { $0.id != agent }
    }

    func agentID(for session: SessionInfo) -> String {
        agents.first { $0.name == session.title }?.id ?? "shell"
    }

    // MARK: Pairing

    func pair(with url: URL) {
        guard let info = PairingInfo(url: url) else {
            message = "That is not an Agentty pairing code. Show a new one on the Mac and try again."
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
            message = "That is not an Agentty pairing code."
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

    /// Forgets the Mac on screen and moves to another one if there is any.
    func forgetMac() {
        disconnect()
        clearHostState()
        pendingPairing = nil
        isPairing = false
        hosts.removeAll { $0.id == pairing?.id }
        PairingStore.save(hosts)
        setCurrent(hosts.first)
        if pairing != nil { connect() }
    }

    private func setCurrent(_ host: SavedHost?) {
        pairing = host
        UserDefaults.standard.set(host?.id, forKey: Self.currentHostKey)
    }

    /// What was shown belongs to the Mac that is being left.
    private func clearHostState() {
        sessions = []
        folders = []
        agents = []
        agentsLoaded = false
        diffs = [:]
        patches = [:]
        histories = [:]
        listing = nil
        handoffPlan = nil
    }

    // MARK: Connection

    /// Called when the app comes to the front.
    func resume() {
        active = true
        if pairing != nil, connection == nil { connect() }
    }

    func retry() {
        if connection == nil { connect() }
    }

    private func connect() {
        guard let pairing else { return }
        open(host: pairing.host, port: pairing.port, credential: .token(pairing.token))
    }

    private func open(host: String, port: UInt16, credential: AgenttyConnection.Credential) {
        status = .connecting
        let connection = AgenttyConnection(host: host, port: port, credential: credential, clientName: UIDevice.current.name)
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

    private func connectionChanged(_ state: AgenttyConnection.State) {
        switch state {
        case .connecting:
            break
        case .connected:
            // Wait for `welcome`: a wrong token is only known after that.
            break
        case .closed(let reason):
            connection = nil
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            self.retryScheduled = false
            if self.connection == nil, self.pairing != nil, UIApplication.shared.applicationState == .active {
                self.connect()
            }
        }
    }

    private func handle(_ message: ServerMessage) {
        switch message {
        case .welcome:
            status = .connected
            reattachAfterConnect = true
            connection?.send(.agents(refresh: false))
        case .sessions(let list):
            sessions = list
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
                    controller = nil
                    self.open(open)
                }
            }
        case .agents(let list):
            agents = list
            agentsLoaded = true
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
            }
        case .resized(let id, let size, let driver):
            if let index = sessions.firstIndex(where: { $0.id == id }) { sessions[index].size = size }
            guard let controller, controller.session == id else { return }
            controller.hostResized(to: size, driver: driver)
            foreignSize = controller.foreignSize
        case .exited:
            break
        case .paired(_, let token):
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
        case .error(let text):
            if text == "invalid token" {
                let name = pairing?.name ?? "The Mac"
                forgetMac()
                self.message = "\(name) removed this iPhone from its paired devices. Pair it again to reconnect."
            } else if text == "invalid pairing code" {
                self.message = "That pairing code has expired or was already used. Show a new one on the Mac and try again."
            } else {
                // A request that was going to open a session failed.
                openCreatedSession = false
                self.message = text
            }
        case .diff(let folder, let snapshot):
            diffs[folder] = snapshot
        case .diffFile(let folder, let file):
            // The host answers per folder; the file asked for is the one waiting.
            if let file {
                patches[Self.patchKey(folder: folder, file: file.path)] = file
            } else if let waiting = pendingPatch, waiting.folder == folder {
                patches[Self.patchKey(folder: folder, file: waiting.file)] = .some(nil)
            }
            pendingPatch = nil
        case .history(let folder, let conversations):
            histories[folder ?? ""] = conversations
            if let session = pendingSessionHandoff, folder == session.cwd {
                pendingSessionHandoff = nil
                // The session's conversation is the newest one its agent has
                // in that folder since the session started.
                let agent = agentID(for: session)
                if let found = conversations.first(where: { $0.agent == agent && $0.updatedAt >= session.createdAt.addingTimeInterval(-5) }) {
                    sessionHandoff = found
                } else {
                    self.message = "\(session.title) has not saved a conversation for this session yet, so there is nothing to hand off."
                }
            }
        case .directory(let listing):
            self.listing = listing
        case .handoffPlan(let id, let prompt):
            handoffPlan = HandoffPlan(id: id, prompt: prompt)
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

    /// Starts an agent, or a shell when `agent` is nil, and opens it.
    func launch(_ agent: AgentInfo?, in folder: String?) {
        guard status == .connected else { return }
        openCreatedSession = true
        // A typical portrait grid. The real one is reported once the view is laid out.
        let size = TermSize(cols: 48, rows: 30)
        connection?.send(.create(CreateRequest(command: agent?.id, cwd: folder, title: agent?.name, size: size)))
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

    private var pendingPatch: (folder: String, file: String)?
    /// A running session whose conversation is being looked up to hand off.
    private var pendingSessionHandoff: SessionInfo?

    func loadDiff(_ folder: String) {
        connection?.send(.diff(path: folder))
    }

    func loadPatch(folder: String, file: String) {
        pendingPatch = (folder, file)
        connection?.send(.diffFile(path: folder, file: file))
    }

    /// `folder` nil loads every conversation on the Mac.
    func loadHistory(_ folder: String?) {
        connection?.send(.history(path: folder))
    }

    /// Reopens a conversation in its agent and shows its terminal.
    func resume(_ conversation: Conversation) {
        guard status == .connected else { return }
        openCreatedSession = true
        connection?.send(.resume(agent: conversation.agent, sessionID: conversation.sessionID, cwd: conversation.cwd, size: TermSize(cols: 48, rows: 30)))
    }

    /// Asks the Mac what the receiving agent would be told, to show it.
    func requestHandoffPlan(for conversation: Conversation) {
        handoffPlan = nil
        connection?.send(.handoffPlan(agent: conversation.agent))
    }

    /// Hands a conversation's work to another agent and shows its terminal.
    /// `prompt` is the plan's prompt as the user left it.
    func handoff(_ conversation: Conversation, to target: AgentInfo, prompt: String, note: String) {
        guard status == .connected else { return }
        openCreatedSession = true
        let plan = handoffPlan
        let edited = plan.map { prompt != $0.prompt } ?? false
        connection?.send(.handoff(
            agent: conversation.agent, sessionID: conversation.sessionID, cwd: conversation.cwd,
            target: target.id, plan: plan?.id, prompt: edited ? prompt : nil, note: note, size: TermSize(cols: 48, rows: 30)
        ))
        handoffPlan = nil
    }

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
    }

    func changeFontSize(by delta: Double) {
        let size = min(max(fontSize + delta, Self.fontSizes.lowerBound), Self.fontSizes.upperBound)
        guard size != fontSize else { return }
        fontSize = size
        UserDefaults.standard.set(size, forKey: Self.fontSizeKey)
        controller?.setFontSize(size)
    }
}
