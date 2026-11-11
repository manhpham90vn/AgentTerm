import AgenttyClient
import AgenttyHost
import AgenttyProtocol
import AgenttyTerminal
import AppKit
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
    @Published var selectedDiffFile: String?
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

    /// Devices that were paired with this Mac.
    @Published private(set) var devices: [DeviceInfo] = []
    /// The pairing code on show, while the pairing sheet is open.
    @Published private(set) var pairingCode: PairingCode?
    /// The device that used the code on show, to confirm it in the sheet.
    @Published private(set) var justPaired: DeviceInfo?
    /// The conversation being handed off, while its sheet is open.
    @Published var pendingHandoff: Conversation?

    private var connection: AgenttyConnection?
    private var controllers: [SessionID: TerminalController] = [:]
    private var port = agenttyDefaultPort
    private var connectAttempts = 0
    private var launchedDaemon = false
    private var selectNextAttached = false
    private var diffTimer: Timer?
    private var diffGeneration = 0
    private var historyGeneration = 0
    private let foldersKey = "folders"
    private var pendingFolderSelection: String?

    init() {
        if let value = ProcessInfo.processInfo.environment["AGENTTY_PORT"].flatMap(UInt16.init) { port = value }
        connect()
        folderChanged()
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

    func sessions(in folder: Folder) -> [SessionInfo] { sessions.filter { $0.cwd == folder.path } }

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
        let connection = AgenttyConnection(host: "127.0.0.1", port: port, token: token, clientName: "Mac")
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

    private func connectionChanged(_ state: AgenttyConnection.State) {
        switch state {
        case .connecting:
            break
        case .connected:
            connectAttempts = 0
            status = .connected
            connection?.send(.agents(refresh: false))
        case .closed(let reason):
            connection = nil
            controllers.removeAll()
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
            status = .failed(reason ?? "The Agentty host is not running.")
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
        case .welcome:
            break
        case .sessions(let list):
            sessions = list
            // Pick up sessions that were already running before this window opened.
            for info in list where controllers[info.id] == nil {
                connection?.send(.attach(session: info.id, size: info.size))
            }
        case .agents(let list):
            agents = list
            agentsLoaded = true
        case .folders(let list):
            folders = list.map(Folder.init)
            if selectedFolder == nil || !list.contains(selectedFolder ?? "") { selectedFolder = list.first }
            migrateLocalFolders(known: list)
        case .attached(let info):
            if controllers[info.id] == nil { controllers[info.id] = makeController(for: info.id) }
            if !sessions.contains(where: { $0.id == info.id }) { sessions.append(info) }
            if selectNextAttached || selectedSession == nil {
                selectNextAttached = false
                selectedSession = info.id
            }
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
        case .pairingCode(let code, let expiresAt):
            pairingCode = PairingCode(code: code, expiresAt: expiresAt)
        case .devices(let list):
            // A device that appears while a code is on show used that code.
            if pairingCode != nil, let new = list.first(where: { device in !devices.contains { $0.id == device.id } }) {
                justPaired = new
                pairingCode = nil
            }
            devices = list
        case .paired, .diff, .diffFile, .history, .directory, .handoffPlan:
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
        let size = currentController?.naturalSize ?? TermSize(cols: 100, rows: 30)
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
        selectedDiffFile = nil
        refreshDiff()
        // The list of every conversation does not depend on the folder.
        if !historyShowsAll {
            history = nil
            refreshHistory()
        }
    }

    // MARK: Handoff

    /// Agents a conversation of `agent` can be handed to.
    func handoffTargets(from agent: String) -> [AgentInfo] {
        installedAgents.filter { $0.id != agent }
    }

    func agentID(of session: SessionInfo) -> String? {
        agents.first { $0.name == session.title }?.id
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
            let newest = AgentHistory.conversations(in: session.cwd)
                .first { $0.agent == agent && $0.updatedAt >= session.createdAt.addingTimeInterval(-5) }
            DispatchQueue.main.async {
                guard let self else { return }
                if let newest {
                    self.requestHandoff(newest)
                } else {
                    self.notice = "\(name) has not saved a conversation for this session yet, so there is nothing to hand off."
                }
            }
        }
    }

    /// Passes a conversation on to another agent: writes the handoff file,
    /// then starts `target` in a new session with a prompt to read it.
    /// `note` is what the user wants the receiving agent to know.
    /// `plan` and `prompt` are what the handoff sheet showed, the prompt
    /// possibly edited there.
    func handoff(_ conversation: Conversation, to target: AgentInfo, plan: Handoff.Plan, prompt: String, note: String) {
        guard status == .connected else { return }
        let size = currentController?.naturalSize ?? TermSize(cols: 100, rows: 30)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try Handoff.prepare(conversation, to: target.id, plan: plan, prompt: prompt, note: note) }
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let prepared):
                    self.selectNextAttached = true
                    self.connection?.send(.create(CreateRequest(command: prepared.command, cwd: conversation.cwd, title: target.name, size: size)))
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
        let size = currentController?.naturalSize ?? TermSize(cols: 100, rows: 30)
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
                if let selected = self.selectedDiffFile, !snapshot.files.contains(where: { $0.path == selected }) {
                    self.selectedDiffFile = nil
                }
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
