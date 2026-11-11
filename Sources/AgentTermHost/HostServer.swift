#if os(macOS)
import AgentTermProtocol
import Foundation
import Network

/// Owns every terminal session and serves them to clients over WebSocket.
///
/// All state is confined to one serial queue.
public final class HostServer {
    public struct Configuration {
        public var port: UInt16
        public var token: String
        /// Also listen on the Mac's Tailscale address so paired phones can connect.
        public var listenOnTailscale: Bool
        /// Bytes of recent output kept per session and replayed on attach.
        public var scrollbackLimit: Int
        /// Overrides agent detection, mainly for tests.
        public var detectAgents: () -> [AgentInfo]
        /// Where the shared folder list is saved. `nil` keeps it in memory only.
        public var foldersFile: URL?
        /// Where paired devices are saved. `nil` keeps them in memory only.
        public var devicesFile: URL?
        /// Home folder whose agent files hold the conversation history.
        public var home: String
        /// Path of `agenttermd`, which Claude Code sessions run as their status
        /// line to report their usage. `nil` leaves Claude Code as it is.
        public var statusLineTool: String?
        /// Where those reports are kept, one file per session.
        public var usageDirectory: URL?
        /// Asks the agents' services what their accounts have left. `nil`
        /// asks nobody, which is what tests want.
        public var fetchAccountUsage: ((String) -> AccountUsage?)?

        public init(
            port: UInt16 = agenttermDefaultPort,
            token: String,
            listenOnTailscale: Bool = true,
            scrollbackLimit: Int = 512 * 1024,
            detectAgents: @escaping () -> [AgentInfo] = AgentDetector.detect,
            foldersFile: URL? = nil,
            devicesFile: URL? = nil,
            home: String = NSHomeDirectory(),
            statusLineTool: String? = nil,
            usageDirectory: URL? = nil,
            fetchAccountUsage: ((String) -> AccountUsage?)? = nil
        ) {
            self.port = port
            self.token = token
            self.listenOnTailscale = listenOnTailscale
            self.scrollbackLimit = scrollbackLimit
            self.detectAgents = detectAgents
            self.foldersFile = foldersFile
            self.devicesFile = devicesFile
            self.home = home
            self.statusLineTool = statusLineTool
            self.usageDirectory = usageDirectory
            self.fetchAccountUsage = fetchAccountUsage
        }
    }

    public enum StartError: Error, CustomStringConvertible {
        case listenerFailed(String)

        public var description: String {
            switch self {
            case .listenerFailed(let reason): return "could not listen: \(reason)"
            }
        }
    }

    private final class Client {
        let id: ClientID
        let connection: NWConnection
        /// Whether the connection arrived on the loopback interface.
        let isLocal: Bool
        var identity: DeviceRegistry.Identity?
        var attached: Set<SessionID> = []

        var authenticated: Bool { identity != nil }
        /// The Mac's own apps may pair and revoke devices.
        var isAdmin: Bool { identity == .local }

        init(id: ClientID, connection: NWConnection, isLocal: Bool) {
            self.id = id
            self.connection = connection
            self.isLocal = isLocal
        }
    }

    private final class Session {
        var info: SessionInfo
        let process: PTYProcess
        var arbiter: SizeArbiter
        var scrollback = Data()

        init(info: SessionInfo, process: PTYProcess) {
            self.info = info
            self.process = process
            self.arbiter = SizeArbiter(fallback: info.size)
        }
    }

    private let configuration: Configuration
    private let queue = DispatchQueue(label: "agentterm.host")
    private let detectionQueue = DispatchQueue(label: "agentterm.host.detect")
    /// Git and file reading for clients, kept off the queue that moves terminal bytes.
    private let workQueue = DispatchQueue(label: "agentterm.host.work", qos: .userInitiated, attributes: .concurrent)
    /// The last changes read per folder, so asking for one file's diff right
    /// after the list does not run git again.
    private var diffCache: [String: (snapshot: DiffSnapshot, at: Date)] = [:]
    /// Handoff plans that were shown to a user, until they are used. The
    /// prompt in a plan names a file, and the handoff has to write that file.
    private var handoffPlans: [String: (plan: Handoff.Plan, at: Date)] = [:]
    private var listeners: [String: NWListener] = [:]
    private var tailscaleTimer: DispatchSourceTimer?
    private var summaryTimer: DispatchSourceTimer?
    private var summarizing = false
    /// What each agent's account has left, and when its service was last asked.
    private var accountUsage: [String: AccountUsage] = [:]
    private var accountAsked: [String: Date] = [:]
    private var accountAsking: Set<String> = []
    /// Services are asked this often while an agent has a session.
    private static let accountInterval: TimeInterval = 300
    private var clients: [ClientID: Client] = [:]
    private var sessions: [SessionID: Session] = [:]
    private var nextClientID: ClientID = 1
    private var nextSessionID: SessionID = 1
    private var agents: [AgentInfo]?
    private var agentWaiters: [ClientID] = []
    private var detecting = false
    private var boundPort: UInt16 = 0
    private var folders: [String] = []
    private let registry: DeviceRegistry

    public init(configuration: Configuration) {
        self.configuration = configuration
        registry = DeviceRegistry(localToken: configuration.token, file: configuration.devicesFile)
        if let file = configuration.foldersFile, let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode([String].self, from: data) {
            folders = saved
        }
    }

    // MARK: Lifecycle

    /// Starts listening on the loopback interface and returns the bound port.
    /// The Tailscale listener is added when the interface is up, now or later.
    @discardableResult
    public func start() throws -> UInt16 {
        let port = try listen(on: "127.0.0.1", port: configuration.port)
        queue.sync { boundPort = port }

        // Names sessions after the conversations their agents are having.
        let summaries = DispatchSource.makeTimerSource(queue: queue)
        summaries.schedule(deadline: .now() + 3, repeating: 6)
        summaries.setEventHandler { [weak self] in self?.refreshSummaries() }
        queue.sync { summaryTimer = summaries }
        summaries.resume()
        guard configuration.listenOnTailscale else { return port }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 15)
        timer.setEventHandler { [weak self] in self?.syncTailscaleListener() }
        queue.sync { tailscaleTimer = timer }
        timer.resume()
        return port
    }

    public func stop() {
        queue.sync {
            tailscaleTimer?.cancel()
            tailscaleTimer = nil
            summaryTimer?.cancel()
            summaryTimer = nil
            listeners.values.forEach { $0.cancel() }
            listeners.removeAll()
            clients.values.forEach { $0.connection.cancel() }
            clients.removeAll()
            sessions.values.forEach { $0.process.hangUp() }
            sessions.removeAll()
        }
    }

    public var sessionCount: Int { queue.sync { sessions.count } }

    private static func parameters(host: String, port: UInt16) -> NWParameters {
        let webSocket = NWProtocolWebSocket.Options()
        webSocket.autoReplyPing = true
        webSocket.maximumMessageSize = 4 * 1024 * 1024
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port) ?? .any
        )
        return parameters
    }

    /// Blocks until the listener is ready. Must not be called on `queue`.
    private func listen(on host: String, port: UInt16) throws -> UInt16 {
        let listener = try makeListener(host: host, port: port)
        let ready = DispatchSemaphore(value: 0)
        var failure: String?
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.signal()
            case .failed(let error): failure = error.localizedDescription; ready.signal()
            case .cancelled: failure = failure ?? "cancelled"; ready.signal()
            default: break
            }
        }
        listener.start(queue: queue)
        if ready.wait(timeout: .now() + 5) == .timedOut { failure = "timed out" }
        if let failure {
            listener.cancel()
            throw StartError.listenerFailed("\(host):\(port): \(failure)")
        }
        listener.stateUpdateHandler = nil
        queue.sync { listeners[host] = listener }
        return listener.port?.rawValue ?? port
    }

    private func makeListener(host: String, port: UInt16) throws -> NWListener {
        let listener = try NWListener(using: Self.parameters(host: host, port: port))
        // Which listener took the connection tells whether it came from this Mac.
        let isLocal = host == "127.0.0.1"
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection, isLocal: isLocal) }
        return listener
    }

    /// Keeps a listener on the current Tailscale address, following the
    /// interface as it comes up, goes away or changes address.
    private func syncTailscaleListener() {
        let address = Tailscale.ipv4Address()
        for (host, listener) in listeners where host != "127.0.0.1" && host != address {
            listener.cancel()
            listeners[host] = nil
        }
        guard let address, listeners[address] == nil,
              let listener = try? makeListener(host: address, port: boundPort)
        else { return }
        listeners[address] = listener
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard case .failed = state, let self, let listener else { return }
            listener.cancel()
            if self.listeners[address] === listener { self.listeners[address] = nil }
        }
        listener.start(queue: queue)
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection, isLocal: Bool) {
        let client = Client(id: nextClientID, connection: connection, isLocal: isLocal)
        nextClientID += 1
        clients[client.id] = client
        connection.stateUpdateHandler = { [weak self, weak client] state in
            guard let self, let client else { return }
            switch state {
            case .failed, .cancelled: self.drop(client)
            default: break
            }
        }
        connection.start(queue: queue)
        receive(from: client)

        // A client that never authenticates is not kept around.
        queue.asyncAfter(deadline: .now() + 10) { [weak self, weak client] in
            guard let self, let client, !client.authenticated else { return }
            self.close(client)
        }
    }

    private func receive(from client: Client) {
        client.connection.receiveMessage { [weak self, weak client] data, context, _, error in
            guard let self, let client else { return }
            if error != nil {
                self.drop(client)
                return
            }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            switch metadata?.opcode {
            case .text:
                if let data, let message = MessageCoding.decode(ClientMessage.self, from: data) {
                    self.handle(message, from: client)
                } else {
                    self.send(.error("malformed message"), to: client)
                }
            case .binary:
                if let data, let frame = DataFrame(decoding: data) { self.handle(frame, from: client) }
            case .close:
                self.drop(client)
                return
            default:
                break
            }
            if self.clients[client.id] != nil { self.receive(from: client) }
        }
    }

    private func close(_ client: Client) {
        client.connection.cancel()
        drop(client)
    }

    private func drop(_ client: Client) {
        guard clients.removeValue(forKey: client.id) != nil else { return }
        client.connection.cancel()
        for id in client.attached {
            guard let session = sessions[id] else { continue }
            if session.arbiter.remove(client.id) { applySize(of: session) }
        }
        client.attached.removeAll()
        if case .device = client.identity { broadcastDevices() }
    }

    private func send(_ message: ServerMessage, to client: Client) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        client.connection.send(content: MessageCoding.encode(message), contentContext: context, completion: .idempotent)
    }

    private func send(_ frame: DataFrame, to client: Client) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "binary", metadata: [metadata])
        client.connection.send(content: frame.encoded(), contentContext: context, completion: .idempotent)
    }

    private func broadcastSessions() {
        let list = sessions.values.map(\.info).sorted { $0.id < $1.id }
        for client in clients.values where client.authenticated {
            send(.sessions(list), to: client)
        }
    }

    // MARK: Messages

    private func handle(_ message: ClientMessage, from client: Client) {
        if case .hello(let token, _) = message {
            guard let identity = registry.authenticate(token: token, isLocal: client.isLocal) else {
                refuse(client, "invalid token")
                return
            }
            admit(client, as: identity)
            return
        }
        if case .pair(let code, let device) = message {
            guard !client.authenticated, let paired = registry.redeem(code: code, deviceName: device) else {
                refuse(client, "invalid pairing code")
                return
            }
            // The token is sent once, here. Only its hash is kept.
            send(.paired(device: paired.device.id, token: paired.token), to: client)
            admit(client, as: .device(id: paired.device.id))
            return
        }
        guard client.authenticated else {
            close(client)
            return
        }

        switch message {
        case .hello, .pair:
            break
        case .createPairingCode:
            guard client.isAdmin else { return send(.error("not allowed"), to: client) }
            let created = registry.createCode()
            send(.pairingCode(code: created.code, expiresAt: created.expiresAt), to: client)
        case .cancelPairingCode:
            guard client.isAdmin else { return send(.error("not allowed"), to: client) }
            registry.cancelCode()
        case .listDevices:
            guard client.isAdmin else { return send(.error("not allowed"), to: client) }
            send(.devices(deviceList()), to: client)
        case .revokeDevice(let id):
            guard client.isAdmin else { return send(.error("not allowed"), to: client) }
            guard registry.revoke(id) else { return }
            for other in clients.values where other.identity == .device(id: id) { close(other) }
            broadcastDevices()
        case .list:
            send(.sessions(sessions.values.map(\.info).sorted { $0.id < $1.id }), to: client)
        case .agents(let refresh):
            requestAgents(for: client, refresh: refresh)
        case .create(let request):
            create(request, for: client)
        case .attach(let id, let size):
            guard let session = sessions[id] else {
                send(.error("no such session"), to: client)
                return
            }
            attach(client, to: session, size: size)
        case .detach(let id):
            client.attached.remove(id)
            if let session = sessions[id], session.arbiter.remove(client.id) { applySize(of: session) }
        case .resize(let id, let size):
            guard let session = sessions[id], client.attached.contains(id) else { return }
            if session.arbiter.update(client.id, size: size) { applySize(of: session) }
        case .takeControl(let id, let size):
            guard let session = sessions[id], client.attached.contains(id) else { return }
            let changed = session.arbiter.takeControl(client.id, size: size)
            if changed { applySize(of: session) } else { announceSize(of: session) }
        case .kill(let id):
            guard let session = sessions[id] else { return }
            session.process.hangUp()
            queue.asyncAfter(deadline: .now() + 3) { [weak session] in session?.process.forceKill() }
        case .addFolder(let path):
            let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: standardized, isDirectory: &isDirectory), isDirectory.boolValue else {
                send(.error("not a folder: \(path)"), to: client)
                return
            }
            guard !folders.contains(standardized) else { return }
            folders.append(standardized)
            foldersChanged()
        case .removeFolder(let path):
            guard folders.contains(path) else { return }
            folders.removeAll { $0 == path }
            foldersChanged()
        case .diff(let path):
            work(for: client, { GitDiff.snapshot(directory: path) }) { server, client, snapshot in
                server.diffCache[path] = (snapshot, Date())
                server.send(.diff(path: path, snapshot: snapshot.withoutPatches), to: client)
            }
        case .diffFile(let path, let file, let staged):
            if let cached = diffCache[path], Date().timeIntervalSince(cached.at) < 20 {
                send(.diffFile(path: path, file: cached.snapshot.files.first { $0.path == file && $0.isStaged == staged }), to: client)
                return
            }
            work(for: client, { GitDiff.snapshot(directory: path) }) { server, client, snapshot in
                server.diffCache[path] = (snapshot, Date())
                server.send(.diffFile(path: path, file: snapshot.files.first { $0.path == file && $0.isStaged == staged }), to: client)
            }
        case .accountUsage(let refresh):
            // Asking again is allowed, but not in a tight loop.
            if refresh { refreshAccountUsage(olderThan: 15) }
            send(.accountUsage(accountUsageList()), to: client)
        case .files(let path):
            work(for: client, { FileBrowser.list(path) }) { server, client, entries in
                server.send(.files(path: path, entries: entries), to: client)
            }
        case .readFile(let path):
            work(for: client, { () -> (FileContent, Data?) in
                let content = FileBrowser.read(path)
                guard content == .image else { return (content, nil) }
                // The client cannot read the Mac's disk, so the picture travels.
                if let data = FileBrowser.imageData(path) { return (.image, data) }
                let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
                return (.tooLarge(bytes: size), nil)
            }) { server, client, result in
                server.send(.file(path: path, content: result.0, data: result.1), to: client)
            }
        case .writeFile(let path, let text):
            files(for: client, in: nil, { try FileBrowser.write(text, to: path); return .fileSaved(path: path) })
        case .createFile(let directory, let name, let isDirectory):
            files(for: client, in: directory) {
                let path = isDirectory ? try FileBrowser.createFolder(named: name, in: directory) : try FileBrowser.createFile(named: name, in: directory)
                return .fileCreated(path: path, isDirectory: isDirectory)
            }
        case .renameFile(let path, let name):
            files(for: client, in: (path as NSString).deletingLastPathComponent) { try FileBrowser.rename(path, to: name); return nil }
        case .trashFile(let path):
            files(for: client, in: (path as NSString).deletingLastPathComponent) { try FileBrowser.trash(path); return nil }
        case .gitStage(let path, let files):
            git(for: client, in: path) { GitActions.stage(files, in: path) }
        case .gitUnstage(let path, let files):
            git(for: client, in: path) { GitActions.unstage(files, in: path) }
        case .gitCommit(let path, let message):
            git(for: client, in: path) { GitActions.commit(message: message, in: path) }
        case .history(let path):
            let home = configuration.home
            work(for: client, {
                path.map { AgentHistory.conversations(in: $0, home: home) } ?? AgentHistory.allConversations(home: home)
            }) { server, client, conversations in
                server.send(.history(path: path, conversations: conversations), to: client)
            }
        case .resume(let agent, let sessionID, let cwd, let size):
            guard AgentDetector.known.contains(where: { $0.id == agent }), AgentHistory.isSafeIdentifier(sessionID) else {
                send(.error("cannot resume that conversation"), to: client)
                return
            }
            let conversation = Conversation(agent: agent, sessionID: sessionID, title: "", updatedAt: Date(), cwd: cwd)
            // A resumed session's conversation is known from the start.
            create(CreateRequest(command: conversation.resumeCommand, cwd: cwd, title: Handoff.name(of: agent), size: size), for: client, conversationID: sessionID)
        case .handoffPlan(let agent):
            guard AgentDetector.known.contains(where: { $0.id == agent }) else {
                send(.error("cannot hand off from that agent"), to: client)
                return
            }
            // Plans nobody used are dropped after an hour.
            handoffPlans = handoffPlans.filter { Date().timeIntervalSince($0.value.at) < 3600 }
            let plan = Handoff.plan(for: Conversation(agent: agent, sessionID: "", title: "", updatedAt: Date(), cwd: ""))
            let id = UUID().uuidString
            handoffPlans[id] = (plan, Date())
            send(.handoffPlan(id: id, prompt: plan.prompt), to: client)
        case .handoff(let agent, let sessionID, let cwd, let target, let planID, let prompt, let note, let size):
            let home = configuration.home
            // Only a plan this host made is honored, so a client names a
            // plan and never a path to write to.
            let plan = planID.flatMap { handoffPlans.removeValue(forKey: $0) }?.plan
            work(for: client, { () -> Result<(Handoff.Prepared, String), Error> in
                // Looked up again here: the conversation's files are on this
                // machine, and what the client holds is only a description.
                let found = AgentHistory.conversations(in: cwd, home: home).first { $0.agent == agent && $0.sessionID == sessionID }
                    ?? AgentHistory.allConversations(home: home).first { $0.agent == agent && $0.sessionID == sessionID }
                guard let found else { return .failure(HandoffRequestError.notFound) }
                return Result { (try Handoff.prepare(found, to: target, plan: plan, prompt: prompt, note: note), found.cwd) }
            }) { server, client, result in
                switch result {
                case .success(let (prepared, directory)):
                    server.create(CreateRequest(command: prepared.command, cwd: directory, title: Handoff.name(of: target), size: size), for: client)
                case .failure(let error):
                    server.send(.error("\(error)"), to: client)
                }
            }
        case .listDirectory(let path):
            let home = configuration.home
            work(for: client, { Self.listing(of: path ?? home, home: home) }) { server, client, listing in
                if let listing {
                    server.send(.directory(listing), to: client)
                } else {
                    server.send(.error("cannot open that folder"), to: client)
                }
            }
        }
    }

    /// Runs a git change, then answers with the folder's changes as they are
    /// now, so the client's list is right whether it worked or not.
    private func git(for client: Client, in path: String, _ action: @escaping () -> String?) {
        work(for: client, { () -> (String?, DiffSnapshot) in
            let problem = action()
            return (problem, GitDiff.snapshot(directory: path))
        }) { server, client, result in
            server.diffCache[path] = (result.1, Date())
            if let problem = result.0 { server.send(.error(problem), to: client) }
            server.send(.diff(path: path, snapshot: result.1.withoutPatches), to: client)
        }
    }

    /// Runs a change to the files, answers with what it returns or with the
    /// problem, then with the folder's listing as it is now.
    private func files(for client: Client, in directory: String?, _ action: @escaping () throws -> ServerMessage?) {
        work(for: client, { () -> (ServerMessage?, [FileEntry]?) in
            var answer: ServerMessage?
            do { answer = try action() } catch { answer = .error("\(error)") }
            return (answer, directory.map { FileBrowser.list($0) })
        }) { server, client, result in
            if let answer = result.0 { server.send(answer, to: client) }
            if let directory, let entries = result.1 { server.send(.files(path: directory, entries: entries), to: client) }
        }
    }

    private enum HandoffRequestError: Error, CustomStringConvertible {
        case notFound
        var description: String { "That conversation is no longer on this Mac." }
    }

    /// Runs `job` off the server queue and hands its result back on it, if
    /// the client that asked is still connected.
    private func work<T>(for client: Client, _ job: @escaping () -> T, then: @escaping (HostServer, Client, T) -> Void) {
        let id = client.id
        workQueue.async { [weak self] in
            let result = job()
            self?.queue.async {
                guard let self, let client = self.clients[id] else { return }
                then(self, client, result)
            }
        }
    }

    /// The folders inside `path`, hidden ones left out.
    static func listing(of path: String, home: String) -> DirectoryListing? {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return nil }
        let folders = entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .map(\.lastPathComponent)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let parent = url.path == "/" ? nil : url.deletingLastPathComponent().path
        let standardHome = URL(fileURLWithPath: home).standardizedFileURL.path
        return DirectoryListing(path: url.path, parent: parent, folders: folders, isHome: url.path == standardHome)
    }

    /// Looks up what each agent session is about and tells the clients when
    /// a session's name changed. Reads the agents' files, so off this queue.
    /// Asks the services of the agents that have a session, where the last
    /// answer is older than `age`.
    private func refreshAccountUsage(olderThan age: TimeInterval) {
        guard let fetch = configuration.fetchAccountUsage else { return }
        let now = Date()
        for agent in Set(sessions.values.compactMap(\.info.agent)) where !accountAsking.contains(agent) {
            if let asked = accountAsked[agent], now.timeIntervalSince(asked) < age { continue }
            accountAsking.insert(agent)
            accountAsked[agent] = now
            workQueue.async { [weak self] in
                let answer = fetch(agent)
                self?.queue.async {
                    guard let self else { return }
                    self.accountAsking.remove(agent)
                    guard var answer else { return }
                    // An answer that failed keeps the figures already known,
                    // with their age, and says what went wrong.
                    if answer.problem != nil, answer.groups.isEmpty, let known = self.accountUsage[agent], !known.groups.isEmpty {
                        var kept = known
                        kept.problem = answer.problem
                        answer = kept
                    }
                    guard self.accountUsage[agent] != answer else { return }
                    self.accountUsage[agent] = answer
                    let message = ServerMessage.accountUsage(self.accountUsageList())
                    for client in self.clients.values where client.identity != nil { self.send(message, to: client) }
                }
            }
        }
    }

    private func accountUsageList() -> [AccountUsage] {
        accountUsage.values.sorted { $0.agent < $1.agent }
    }

    private func usageFile(for id: SessionID) -> URL? {
        configuration.usageDirectory?.appendingPathComponent("session-\(id).json")
    }

    private func refreshSummaries() {
        refreshAccountUsage(olderThan: Self.accountInterval)
        guard !summarizing else { return }
        let running = sessions.values.compactMap { session -> SessionSummaries.Running? in
            guard let agent = session.info.agent else { return nil }
            return SessionSummaries.Running(
                id: session.info.id, agent: agent, cwd: session.info.cwd,
                createdAt: session.info.createdAt, conversationID: session.info.conversationID
            )
        }
        guard !running.isEmpty else { return }
        summarizing = true
        let home = configuration.home
        var reports: [SessionID: URL] = [:]
        for session in running where session.agent == "claude" { reports[session.id] = usageFile(for: session.id) }
        workQueue.async { [weak self] in
            var conversations: [Conversation] = []
            for folder in Set(running.map(\.cwd)) {
                conversations += AgentHistory.conversations(in: folder, home: home)
            }
            let matches = SessionSummaries.assign(running, conversations: conversations)
            var usage: [SessionID: SessionUsage] = [:]
            for (id, conversation) in matches {
                if let file = conversation.source { usage[id] = AgentUsage.read(agent: conversation.agent, file: file) }
            }
            // What Claude Code reported itself says more: its limits, and
            // how large its context is.
            for (id, file) in reports {
                if let data = try? Data(contentsOf: file), let reported = StatusLineRelay.usage(from: data) { usage[id] = reported }
            }
            // Copilot CLI keeps a file of a session before there is a
            // conversation to match it by.
            for session in running where session.agent == "copilot" && usage[session.id] == nil {
                if let file = AgentUsage.copilotSessionFile(cwd: session.cwd, startedAfter: session.createdAt, home: home) {
                    usage[session.id] = AgentUsage.read(agent: "copilot", file: file)
                }
            }
            // Every agent's session names a model: the one its settings
            // name, until the session itself records which it uses.
            var configured: [String: String?] = [:]
            for session in running where usage[session.id]?.model == nil {
                let model = configured[session.agent] ?? AgentUsage.configuredModel(agent: session.agent, home: home)
                configured[session.agent] = .some(model)
                guard let model else { continue }
                var known = usage[session.id] ?? SessionUsage()
                known.model = model
                usage[session.id] = known
            }
            self?.queue.async {
                guard let self else { return }
                self.summarizing = false
                var changed = false
                for (id, used) in usage where matches[id] == nil {
                    // Usage can be known before the conversation is. What
                    // was read then is not lost to a later read with less.
                    guard let session = self.sessions[id] else { continue }
                    var used = used
                    if let known = session.info.usage {
                        used.contextTokens = used.contextTokens ?? known.contextTokens
                        used.contextWindow = used.contextWindow ?? known.contextWindow
                    }
                    guard session.info.usage != used else { continue }
                    session.info.usage = used
                    changed = true
                }
                for (id, conversation) in matches {
                    guard let session = self.sessions[id] else { continue }
                    if session.info.summary != conversation.title || session.info.conversationID != conversation.sessionID {
                        session.info.summary = conversation.title
                        session.info.conversationID = conversation.sessionID
                        changed = true
                    }
                    // A read that found nothing keeps what was known.
                    if let used = usage[id], session.info.usage != used {
                        session.info.usage = used
                        changed = true
                    }
                }
                if changed { self.broadcastSessions() }
            }
        }
    }

    /// Tells the client why, then closes once the message had time to arrive.
    private func refuse(_ client: Client, _ reason: String) {
        send(.error(reason), to: client)
        queue.asyncAfter(deadline: .now() + 0.2) { [weak self, weak client] in
            if let self, let client { self.close(client) }
        }
    }

    private func admit(_ client: Client, as identity: DeviceRegistry.Identity) {
        client.identity = identity
        send(.welcome(version: agenttermProtocolVersion, host: Host.current().localizedName ?? "Mac"), to: client)
        send(.sessions(sessions.values.map(\.info).sorted { $0.id < $1.id }), to: client)
        if !accountUsage.isEmpty { send(.accountUsage(accountUsageList()), to: client) }
        send(.folders(folders), to: client)
        if client.isAdmin {
            send(.devices(deviceList()), to: client)
        } else {
            broadcastDevices()
        }
    }

    private func deviceList() -> [DeviceInfo] {
        let connected = Set(clients.values.compactMap { client -> String? in
            if case .device(let id) = client.identity { return id }
            return nil
        })
        return registry.devices(connected: connected)
    }

    /// Paired devices are the Mac's business only.
    private func broadcastDevices() {
        let list = deviceList()
        for client in clients.values where client.isAdmin {
            send(.devices(list), to: client)
        }
    }

    private func foldersChanged() {
        if let file = configuration.foldersFile, let data = try? JSONEncoder().encode(folders) {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
        for client in clients.values where client.authenticated {
            send(.folders(folders), to: client)
        }
    }

    private func handle(_ frame: DataFrame, from client: Client) {
        guard client.authenticated, frame.kind == .input,
              client.attached.contains(frame.session), let session = sessions[frame.session]
        else { return }
        if TerminalReply.isReply(frame.payload) {
            // An emulator answering the program's question, not a person
            // typing. Only the answer of the client in use is passed on, and
            // it does not move the session to that client.
            if session.arbiter.driver == client.id { session.process.write(frame.payload) }
            return
        }
        // Typing takes control of the session's size.
        if session.arbiter.activity(client.id) { applySize(of: session) }
        session.process.write(frame.payload)
    }

    private func requestAgents(for client: Client, refresh: Bool) {
        if let agents, !refresh {
            send(.agents(agents), to: client)
            return
        }
        agentWaiters.append(client.id)
        guard !detecting else { return }
        detecting = true
        let detect = configuration.detectAgents
        detectionQueue.async { [weak self] in
            let found = detect()
            self?.queue.async {
                guard let self else { return }
                self.agents = found
                self.detecting = false
                for id in self.agentWaiters {
                    if let waiter = self.clients[id] { self.send(.agents(found), to: waiter) }
                }
                self.agentWaiters.removeAll()
            }
        }
    }

    // MARK: Sessions

    private func create(_ request: CreateRequest, for client: Client, conversationID: String? = nil) {
        var cwd = request.cwd ?? HostEnvironment.homeDirectory
        var isDirectory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory) || !isDirectory.boolValue {
            cwd = HostEnvironment.homeDirectory
        }
        let size = request.size.clamped
        let id = nextSessionID
        var command = request.command
        // Claude Code reports its usage through its status line.
        if SessionSummaries.agent(forCommand: command) == "claude", let tool = configuration.statusLineTool, let file = usageFile(for: id) {
            try? FileManager.default.removeItem(at: file)
            command = (command ?? "") + StatusLineRelay.launchArguments(tool: tool, file: file.path)
        }
        let process: PTYProcess
        do {
            process = try PTYProcess(
                executable: HostEnvironment.shell,
                arguments: HostEnvironment.shellArguments(command: command),
                environment: HostEnvironment.sessionEnvironment(),
                cwd: cwd,
                size: size,
                queue: queue
            )
        } catch {
            send(.error("\(error)"), to: client)
            return
        }

        nextSessionID += 1
        let fallbackTitle = request.command?.split(separator: " ").first.map(String.init)
            ?? (HostEnvironment.shell as NSString).lastPathComponent
        let info = SessionInfo(
            id: id, title: request.title ?? fallbackTitle, cwd: cwd, size: size, createdAt: Date(),
            agent: SessionSummaries.agent(forCommand: request.command), conversationID: conversationID
        )
        let session = Session(info: info, process: process)
        sessions[id] = session

        process.onOutput = { [weak self, weak session] data in
            guard let self, let session else { return }
            self.record(data, in: session)
        }
        process.onExit = { [weak self] status in
            self?.sessionExited(id, status: status)
        }

        attach(client, to: session, size: size)
        broadcastSessions()
        // An agent that was not in use until now: ask its service right away.
        refreshAccountUsage(olderThan: Self.accountInterval)
    }

    private func attach(_ client: Client, to session: Session, size: TermSize) {
        client.attached.insert(session.info.id)
        // Watching is not using: this only sets the size if nobody else is attached.
        let changed = session.arbiter.update(client.id, size: size)
        if changed {
            session.info.size = session.arbiter.currentSize
            session.process.resize(session.info.size)
        }
        send(.attached(session.info), to: client)
        if !session.scrollback.isEmpty {
            send(DataFrame(kind: .output, session: session.info.id, payload: session.scrollback), to: client)
        }
        announceSize(of: session)
    }

    private func record(_ data: Data, in session: Session) {
        session.scrollback.append(data)
        let excess = session.scrollback.count - configuration.scrollbackLimit
        if excess > 0 {
            session.scrollback = Data(session.scrollback.dropFirst(excess))
        }
        let frame = DataFrame(kind: .output, session: session.info.id, payload: data)
        for id in session.arbiter.clients {
            if let client = clients[id] { send(frame, to: client) }
        }
    }

    /// Resizes the PTY to the arbiter's size and tells every attached client.
    private func applySize(of session: Session) {
        session.info.size = session.arbiter.currentSize
        session.process.resize(session.info.size)
        announceSize(of: session)
    }

    private func announceSize(of session: Session) {
        for id in session.arbiter.clients {
            guard let client = clients[id] else { continue }
            send(.resized(session: session.info.id, size: session.info.size, driver: session.arbiter.driver == id), to: client)
        }
    }

    private func sessionExited(_ id: SessionID, status: Int32) {
        guard let session = sessions.removeValue(forKey: id) else { return }
        if let file = usageFile(for: id) { try? FileManager.default.removeItem(at: file) }
        for clientID in session.arbiter.clients {
            guard let client = clients[clientID] else { continue }
            client.attached.remove(id)
            send(.exited(session: id, status: status), to: client)
        }
        broadcastSessions()
    }
}
#endif
