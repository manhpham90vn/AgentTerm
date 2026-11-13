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
        /// The protocol version the host says it speaks. Only tests change
        /// it, to see what a client does with a host of another release.
        public var protocolVersion = agenttermProtocolVersion
        public var listenOnTailscale: Bool
        /// Bytes of recent output kept per session, for a client that comes
        /// back after losing its connection: it is sent what it missed.
        public var scrollbackLimit: Int
        /// Lines above the screen kept per session and sent, with the
        /// screen, to a client that attaches.
        public var screenLines = 10_000
        /// A folder to take the agents' programs from, for tests: a
        /// session's command that starts with an agent's name then runs the
        /// program of that name in here, not the installed one the shell
        /// would find.
        public var agentsDirectory: String?
        /// What starts this host at login, for a host that can be. Nil for
        /// one that cannot: clients then show no switch for it.
        public var loginItem: LoginItem?
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
        /// Where those reports are kept, one file per session, and what the
        /// agents' hooks tell of each session (`AgentHooks`).
        public var usageDirectory: URL?
        /// Where the host keeps what it gives Copilot CLI and Antigravity
        /// for their hooks: a plugin, a folder. Nil gives those two none.
        public var hooksDirectory: URL?
        /// Asks the agents' services what their accounts have left. `nil`
        /// asks nobody, which is what tests want.
        public var fetchAccountUsage: ((String) -> AccountUsage?)?
        /// Whether the Mac is plugged in. Tests say so themselves.
        public var isOnPower: () -> Bool = { PowerSource.isOnPower }
        /// Takes or lets go of the hold that keeps the Mac awake (whether to
        /// hold, whether the display too) and says whether it is held. Nil
        /// for macOS's own; a test stands in one that refuses.
        public var holdAwake: ((_ held: Bool, _ display: Bool) -> Bool)?
        /// Home folder whose SSH configuration names the hosts to offer.
        /// Nil reads the one of `home`.
        public var sshHome: String?
        /// How often sessions are named and measured, in seconds. Tests
        /// shorten it.
        public var refreshInterval: TimeInterval = 6
        /// Where the host notes that it is running (`HostMarker`), so the
        /// host after it can tell that it died, and keeps the reports of
        /// parts that stopped until someone has seen them (`FailureLog`).
        /// Nil does neither.
        public var stateDirectory: URL?

        public init(
            port: UInt16 = agenttermDefaultPort,
            token: String,
            listenOnTailscale: Bool = true,
            scrollbackLimit: Int = 1024 * 1024,
            loginItem: LoginItem? = nil,
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
            self.loginItem = loginItem
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
        /// The hosts before this one died too often within a minute
        /// (`HostMarker.deathsThatBreak`): it is not to run until the user
        /// asks. A host that gets this exits with status 0, so that launchd
        /// does not start it again either.
        case keepsDying(Int)

        public var description: String {
            switch self {
            case .listenerFailed(let reason): return "could not listen: \(reason)"
            case .keepsDying(let count):
                return "the host stopped unexpectedly \(count) times within a minute, so it is not started again until AgentTerm is opened and asked to"
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
        /// The session's screen, which a client that attaches is sent.
        let mirror: ScreenMirror
        /// The last of the raw output, for a client that was here before.
        var scrollback = Data()
        /// Where the end of `scrollback` is in all the session ever wrote.
        /// It starts at a number of its own rather than at nothing: session
        /// numbers start over when the host does, and a client that comes
        /// back with a place in a session of before must not be taken to
        /// have a place in this one.
        var written = Int.random(in: 0..<(1 << 40))
        /// Its program was asked to end (the tab closed, the host stopping):
        /// a signal it then dies of is not reported.
        var endAsked = false
        /// What the status line relay could not save was reported.
        var usageFailureReported = false
        /// The last event its agent's hooks saved, as read.
        var lastEvent: Data?
        /// Its agent was given hooks: its state can be known.
        var hooked = false

        init(info: SessionInfo, process: PTYProcess, screenLines: Int) {
            self.info = info
            self.process = process
            self.mirror = ScreenMirror(size: info.size, scrollback: screenLines)
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
    /// Parts that stopped without being asked to, until the user has seen
    /// them on one of the clients.
    private var failures: [PartFailure] = []
    /// What this host notes about itself in the state folder while it runs.
    private var marker: HostMarker?
    private var markerFile: URL?

    public init(configuration: Configuration) {
        self.configuration = configuration
        registry = DeviceRegistry(localToken: configuration.token, file: configuration.devicesFile)
        if let file = configuration.foldersFile, let data = try? Data(contentsOf: file),
            let saved = try? JSONDecoder().decode([String].self, from: data)
        {
            folders = saved
        }
        if let file = settingsFile, let data = try? Data(contentsOf: file),
            let saved = MessageCoding.decode(Settings.self, from: data)
        {
            keepAwake = saved.keepAwake ?? false
            keepAwakeOptions = saved.keepAwakeOptions ?? KeepAwakeOptions()
            commitWriter = saved.commitWriter ?? CommitWriterSettings()
            displaySettings = saved.display
        }
        if let file = tabLayoutFile, let data = try? Data(contentsOf: file),
            let saved = try? JSONDecoder().decode(TabLayout.self, from: data)
        {
            tabLayout = saved
        }
    }

    /// Whether to keep the Mac awake while sessions run. Kept next to the folders.
    private var keepAwake = false
    private let sleepGuard = SleepGuard()
    private var settingsFile: URL? {
        configuration.foldersFile?.deletingLastPathComponent().appendingPathComponent("settings.json")
    }

    /// The display too, only on power, and for how long.
    private var keepAwakeOptions = KeepAwakeOptions()
    /// Which agent writes commit messages, and how it is asked.
    private var commitWriter = CommitWriterSettings()
    /// How things are shown on every device. Nil until a client has said:
    /// the first one to connect then brings what it had chosen.
    private var displaySettings: DisplaySettings?
    /// The agents writing a commit message now, by folder.
    private var commitRuns: [String: CommitWriter.Run] = [:]
    private let statsQueue = DispatchQueue(label: "agentterm.host.stats", qos: .utility)
    /// Measures the Mac itself. Confined to `statsQueue`.
    private let systemSampler = SystemSampler()
    private var systemTimer: DispatchSourceTimer?
    private var systemStats: SystemStats?
    private var samplingSystem = false

    /// Measures the Mac and tells the clients, while there is one to tell.
    private func refreshSystemStats() {
        guard !samplingSystem, clients.values.contains(where: \.authenticated) else { return }
        samplingSystem = true
        statsQueue.async { [weak self] in
            guard let self else { return }
            let stats = self.systemSampler.sample()
            self.queue.async {
                self.samplingSystem = false
                guard stats != self.systemStats else { return }
                self.systemStats = stats
                for client in self.clients.values where client.authenticated { self.send(.systemStats(stats), to: client) }
            }
        }
    }

    /// What the host keeps in `settings.json`. Every field is optional, so
    /// the file of an earlier version still reads.
    private struct Settings: Codable {
        var keepAwake: Bool?
        var keepAwakeOptions: KeepAwakeOptions?
        var commitWriter: CommitWriterSettings?
        var display: DisplaySettings?
    }

    private func saveSettings() {
        guard let file = settingsFile else { return }
        let settings = Settings(keepAwake: keepAwake, keepAwakeOptions: keepAwakeOptions, commitWriter: commitWriter, display: displaySettings)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? MessageCoding.encode(settings).write(to: file, options: .atomic)
    }

    /// The hold on sleep follows the setting and whether anything runs:
    /// with no session there is nothing to stay awake for. A hold that was
    /// given a time ends when the time is up.
    private func updateSleepGuard() {
        if keepAwake, let until = keepAwakeOptions.until, until <= Date() {
            keepAwake = false
            keepAwakeOptions.until = nil
            saveSettings()
            broadcastKeepAwake()
        }
        let powered = !keepAwakeOptions.onlyOnPower || configuration.isOnPower()
        let wanted = keepAwake && !sessions.isEmpty && powered
        let held =
            configuration.holdAwake.map { $0(wanted, keepAwakeOptions.display) }
            ?? sleepGuard.set(held: wanted, display: keepAwakeOptions.display)
        noteSleepHold(wanted: wanted, held: held)
    }

    /// The report of a hold macOS refused, while it is refused.
    private var refusedHold: String?

    /// A hold that is wanted and refused is reported once; it is asked for
    /// again on every refresh, and the report says so once it is held.
    private func noteSleepHold(wanted: Bool, held: Bool) {
        if wanted && !held {
            guard refusedHold == nil else { return }
            let failure = PartFailure(
                part: .keepAwake, at: Date(), restarted: false,
                reason: "macOS would not hold it, so the Mac may sleep while sessions run. AgentTerm asks again every few seconds.")
            refusedHold = failure.id
            report(failure)
        } else if let id = refusedHold {
            refusedHold = nil
            // Held again: said in the report that is still there. One that
            // is no longer wanted is left as it was.
            guard wanted, let index = failures.firstIndex(where: { $0.id == id }) else { return }
            failures[index].restarted = true
            saveFailures()
            broadcastFailures()
        }
    }

    private func broadcastKeepAwake() {
        for client in clients.values where client.authenticated {
            send(.keepAwake(keepAwake), to: client)
            send(.keepAwakeOptions(keepAwakeOptions), to: client)
        }
    }

    /// Looks again when a timed hold is due to end.
    private func scheduleKeepAwakeEnd() {
        guard keepAwake, let until = keepAwakeOptions.until else { return }
        queue.asyncAfter(deadline: .now() + max(0, until.timeIntervalSinceNow) + 0.05) { [weak self] in self?.updateSleepGuard() }
    }

    /// True while the Mac is being kept awake. For tests.
    public var isKeepingAwake: Bool { queue.sync { sleepGuard.isHeld } }
    /// True while the display is being kept on too. For tests.
    public var isKeepingDisplayAwake: Bool { queue.sync { sleepGuard.holdsDisplay } }

    /// Where an agent runs when it writes a commit message.
    private var commitWriterDirectory: URL {
        configuration.foldersFile?.deletingLastPathComponent().appendingPathComponent("commit-writer", isDirectory: true)
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-commit-writer", isDirectory: true)
    }

    /// How the tabs are arranged, for every client. Kept next to the folders.
    private var tabLayout = TabLayout()
    private var tabLayoutFile: URL? {
        configuration.foldersFile?.deletingLastPathComponent().appendingPathComponent("tabs.json")
    }

    // MARK: Lifecycle

    /// Starts listening on the loopback interface and returns the bound port.
    /// The Tailscale listener is added when the interface is up, now or later.
    @discardableResult
    public func start() throws -> UInt16 {
        let port = try listen(on: "127.0.0.1", port: configuration.port)
        let deaths = queue.sync {
            boundPort = port
            // Only once the port is this host's: a host that cannot listen
            // there leaves the one that can to find out what happened.
            return noteStart()
        }
        if let deaths {
            stop()
            throw StartError.keepsDying(deaths)
        }

        // Names sessions after the conversations their agents are having.
        let summaries = DispatchSource.makeTimerSource(queue: queue)
        summaries.schedule(deadline: .now() + min(3, configuration.refreshInterval), repeating: configuration.refreshInterval)
        summaries.setEventHandler { [weak self] in
            guard let self else { return }
            // Still alive: what the next host takes for the time this one
            // died, should it die.
            if let file = self.markerFile { HostMarker.touch(file) }
            // Power may have been plugged in or pulled since the last look.
            self.updateSleepGuard()
            self.checkStatusLines()
            // In case the folder's watch missed one.
            self.readEvents()
            self.refreshSummaries()
        }
        // The Mac itself is measured more often than its sessions: a
        // network speed or a processor load that is seconds old says little.
        let system = DispatchSource.makeTimerSource(queue: queue)
        system.schedule(deadline: .now() + 0.2, repeating: min(3, configuration.refreshInterval))
        system.setEventHandler { [weak self] in self?.refreshSystemStats() }
        queue.sync {
            summaryTimer = summaries
            watchEvents()
            systemTimer = system
            scheduleKeepAwakeEnd()
        }
        system.resume()
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
            // A stop that was asked for, so it is not a death. Before the
            // clients are let go: an app that sees its connection close
            // looks for the marker to know which of the two it was.
            if let file = markerFile { try? FileManager.default.removeItem(at: file) }
            markerFile = nil
            marker = nil
            tailscaleTimer?.cancel()
            tailscaleTimer = nil
            summaryTimer?.cancel()
            eventsWatch?.cancel()
            eventsWatch = nil
            summaryTimer = nil
            systemTimer?.cancel()
            systemTimer = nil
            listeners.values.forEach { $0.cancel() }
            listeners.removeAll()
            clients.values.forEach { $0.connection.cancel() }
            clients.removeAll()
            sessions.values.forEach {
                $0.endAsked = true
                $0.process.hangUp()
            }
            sessions.removeAll()
            commitRuns.values.forEach { $0.cancel() }
            commitRuns.removeAll()
            sleepGuard.set(held: false)
        }
    }

    public var sessionCount: Int { queue.sync { sessions.count } }

    // MARK: Parts that stopped

    /// Reads what the host before this one left, reports it if it died,
    /// and notes that this one runs. Returns how often the hosts before it
    /// died lately when that is too often for this one to run.
    private func noteStart(now: Date = Date()) -> Int? {
        guard let directory = configuration.stateDirectory else { return nil }
        failures = FailureLog.read(in: directory)
        let file = HostMarker.file(in: directory, port: boundPort)
        var deaths: [Date] = []
        if let found = HostMarker.read(file), !found.marker.isRunning {
            // It left its marker, so it did not stop as asked: it was
            // killed or it crashed, and its sessions ended with it. Whoever
            // started this host started it again.
            deaths = HostMarker.recent(found.marker.deaths + [found.aliveAt], now: now)
            // Broken means three times in sixty seconds, however the host
            // was started again: by the app, or by launchd with the app
            // closed. Then this one does not run.
            let broken = deaths.count >= HostMarker.deathsThatBreak
            failures.append(PartFailure(part: .host, at: found.aliveAt, ended: found.marker.sessions, restarted: !broken, broken: broken))
            failures = Array(failures.suffix(FailureLog.limit))
            FailureLog.write(failures, in: directory)
            if broken {
                // What is reported is kept; the deaths that were counted
                // are not, so the next start, which only the user makes
                // (opening the app, Try Again, logging in), runs.
                try? FileManager.default.removeItem(at: file)
                return deaths.count
            }
        }
        let marker = HostMarker(sessions: endedSessions(), deaths: deaths)
        marker.write(to: file)
        self.marker = marker
        markerFile = file
        // A client that came in while the listener was starting.
        if !failures.isEmpty { broadcastFailures() }
        return nil
    }

    /// The sessions as the marker names them: what would end with this host.
    private func endedSessions() -> [EndedSession] {
        sessions.values.map(\.info).sorted { $0.id < $1.id }.map(EndedSession.init)
    }

    /// Writes the marker again when what would end with the host changed.
    private func updateMarker() {
        guard let file = markerFile, var marker else { return }
        let now = endedSessions()
        guard now != marker.sessions else { return }
        marker.sessions = now
        marker.write(to: file)
        self.marker = marker
    }

    private func broadcastFailures() {
        for client in clients.values where client.authenticated { send(.failures(failures), to: client) }
    }

    /// A part stopped without being asked to: kept until someone has seen
    /// it, and told to every client.
    private func report(_ failure: PartFailure) {
        failures.append(failure)
        failures = Array(failures.suffix(FailureLog.limit))
        saveFailures()
        broadcastFailures()
    }

    private func saveFailures() {
        if let directory = configuration.stateDirectory { FailureLog.write(failures, in: directory) }
    }

    /// Why a session's program ended, when it did not end by itself or as
    /// asked: killed, or crashed. `code` is what the session reports, 128
    /// and the signal for a program a signal ended. A signal the user sends
    /// from the keyboard (Control C) or the host sends to close it is not
    /// such an end.
    static func unexpectedEnd(code: Int32) -> String? {
        guard code > 128 else { return nil }
        switch code - 128 {
        case SIGKILL: return "It was killed (SIGKILL), by macOS or by another program."
        case SIGSEGV: return "It crashed (SIGSEGV)."
        case SIGBUS: return "It crashed (SIGBUS)."
        case SIGILL: return "It crashed (SIGILL)."
        case SIGABRT: return "It crashed (SIGABRT)."
        case SIGTRAP: return "It crashed (SIGTRAP)."
        case SIGFPE: return "It crashed (SIGFPE)."
        default: return nil
        }
    }

    /// Sessions of Claude Code whose usage the status line relay could not
    /// save: reported once each, until it saves again.
    private func checkStatusLines() {
        for session in sessions.values where session.info.agent == "claude" {
            guard let file = usageFile(for: session.info.id) else { continue }
            let problem = StatusLineRelay.failureFile(for: file.path)
            guard let said = FileManager.default.contents(atPath: problem) else {
                session.usageFailureReported = false
                continue
            }
            guard !session.usageFailureReported else { continue }
            session.usageFailureReported = true
            let reason = String(decoding: said, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            report(
                PartFailure(
                    part: .statusLine, name: session.info.displayName, at: Date(), restarted: false,
                    reason: "Its usage band keeps the figures it had." + (reason.isEmpty ? "" : " " + reason)))
        }
    }

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
        updateSleepGuard()
        updateMarker()
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
        case .attach(let id, let size, let have):
            guard let session = sessions[id] else {
                send(.error("no such session"), to: client)
                return
            }
            attach(client, to: session, size: size, have: have)
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
            session.endAsked = true
            session.process.hangUp()
            queue.asyncAfter(deadline: .now() + 3) { [weak session] in session?.process.forceKill() }
        case .setStartAtLogin(let wanted):
            guard let item = configuration.loginItem else { return }
            do {
                if wanted { try item.turnOn() } else { try item.turnOff() }
            } catch {
                send(.error("Could not \(wanted ? "set the host to start" : "stop the host from starting") at login: \(error.localizedDescription)"), to: client)
            }
            // To everyone, and as it is now: also when it could not be changed.
            for other in clients.values where other.authenticated { send(.startAtLogin(item.isOn), to: other) }
        case .setKeepAwake(let wanted):
            guard wanted != keepAwake else { return }
            keepAwake = wanted
            // A switch-on lasts as long as the options say.
            keepAwakeOptions.until = wanted ? keepAwakeOptions.minutes.map { Date().addingTimeInterval(TimeInterval($0) * 60) } : nil
            saveSettings()
            updateSleepGuard()
            scheduleKeepAwakeEnd()
            broadcastKeepAwake()
        case .setKeepAwakeOptions(var options):
            options.minutes = options.minutes.flatMap { $0 > 0 ? min($0, 7 * 24 * 60) : nil }
            // When the hold ends is the host's to say: from now when the
            // length changed, as it was otherwise.
            if !keepAwake {
                options.until = nil
            } else if options.minutes != keepAwakeOptions.minutes {
                options.until = options.minutes.map { Date().addingTimeInterval(TimeInterval($0) * 60) }
            } else {
                options.until = keepAwakeOptions.until
            }
            guard options != keepAwakeOptions else { return }
            keepAwakeOptions = options
            saveSettings()
            updateSleepGuard()
            scheduleKeepAwakeEnd()
            broadcastKeepAwake()
        case .setCommitWriter(var settings):
            // An agent the host does not know cannot be run.
            if let agent = settings.agent, !AgentDetector.known.contains(where: { $0.id == agent }) { settings.agent = nil }
            if settings.model?.trimmingCharacters(in: .whitespaces).isEmpty == true { settings.model = nil }
            if settings.prompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true { settings.prompt = nil }
            guard settings != commitWriter else { return }
            commitWriter = settings
            saveSettings()
            for other in clients.values where other.authenticated { send(.commitWriter(settings), to: other) }
        case .setDisplaySettings(let wanted):
            let settings = wanted.checked
            guard settings != displaySettings else { return }
            displaySettings = settings
            saveSettings()
            // The sender has it already.
            for other in clients.values where other.authenticated && other !== client { send(.displaySettings(settings), to: other) }
        case .writeCommitMessage(let path):
            writeCommitMessage(in: path, for: client)
        case .cancelCommitMessage(let path):
            commitRuns[path]?.cancel()
        case .sshHosts:
            let home = configuration.sshHome ?? configuration.home
            work(for: client, { SSHConfig.hosts(home: home) }) { server, client, hosts in
                server.send(.sshHosts(hosts), to: client)
            }
        case .connectSSH(let host, let size):
            let home = configuration.sshHome ?? configuration.home
            // The name goes on a command line, so only one the Mac's own
            // configuration lists, and plain at that, is taken.
            work(for: client, { SSHConfig.isSafeHost(host) && SSHConfig.hosts(home: home).contains(host) }) { server, client, known in
                guard known else { return server.send(.error("\(host) is not a host in this Mac's SSH configuration."), to: client) }
                server.create(CreateRequest(command: "ssh \(host)", cwd: server.configuration.home, title: host, size: size), for: client)
            }
        case .setTabLayout(let layout):
            guard layout != tabLayout else { return }
            tabLayout = layout
            if let file = tabLayoutFile, let data = try? JSONEncoder().encode(layout) {
                try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: file, options: .atomic)
            }
            // The sender has it already.
            for other in clients.values where other.authenticated && other !== client {
                send(.tabLayout(layout), to: other)
            }
        case .moveFolder(let path, let before):
            guard path != before, let from = folders.firstIndex(of: path) else { return }
            var moved = folders
            moved.remove(at: from)
            moved.insert(path, at: before.flatMap { moved.firstIndex(of: $0) } ?? moved.count)
            guard moved != folders else { return }
            folders = moved
            foldersChanged()
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
            work(
                for: client,
                { () -> (FileContent, Data?) in
                    let content = FileBrowser.read(path)
                    guard content == .image else { return (content, nil) }
                    // The client cannot read the Mac's disk, so the picture travels.
                    if let data = FileBrowser.imageData(path) { return (.image, data) }
                    let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
                    return (.tooLarge(bytes: size), nil)
                }
            ) { server, client, result in
                server.send(.file(path: path, content: result.0, data: result.1), to: client)
            }
        case .writeFile(let path, let text):
            files(
                for: client, in: nil,
                {
                    try FileBrowser.write(text, to: path); return .fileSaved(path: path)
                })
        case .createFile(let directory, let name, let isDirectory):
            files(for: client, in: directory) {
                let path = isDirectory ? try FileBrowser.createFolder(named: name, in: directory) : try FileBrowser.createFile(named: name, in: directory)
                return .fileCreated(path: path, isDirectory: isDirectory)
            }
        case .renameFile(let path, let name):
            files(for: client, in: (path as NSString).deletingLastPathComponent) {
                try FileBrowser.rename(path, to: name); return nil
            }
        case .trashFile(let path):
            files(for: client, in: (path as NSString).deletingLastPathComponent) {
                try FileBrowser.trash(path); return nil
            }
        case .gitStage(let path, let files):
            git(for: client, in: path) { GitActions.stage(files, in: path) }
        case .gitUnstage(let path, let files):
            git(for: client, in: path) { GitActions.unstage(files, in: path) }
        case .gitCommit(let path, let message):
            git(for: client, in: path) { GitActions.commit(message: message, in: path) }
        case .gitPush(let path):
            git(for: client, in: path, sync: true) { GitActions.push(in: path) }
        case .gitPull(let path):
            git(for: client, in: path, sync: true) { GitActions.pull(in: path) }
        case .history(let path):
            let home = configuration.home
            work(
                for: client,
                {
                    path.map { AgentHistory.conversations(in: $0, home: home) } ?? AgentHistory.allConversations(home: home)
                }
            ) { server, client, conversations in
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
        case .handoff(let agent, let sessionID, let cwd, let target, let planID, let prompt, let note, let size, let folder):
            let home = configuration.home
            // Only a plan this host made is honored, so a client names a
            // plan and never a path to write to.
            let plan = planID.flatMap { handoffPlans.removeValue(forKey: $0) }?.plan
            work(
                for: client,
                { () -> Result<(Handoff.Prepared, String), Error> in
                    // Looked up again here: the conversation's files are on this
                    // machine, and what the client holds is only a description.
                    let found =
                        AgentHistory.conversations(in: cwd, home: home).first { $0.agent == agent && $0.sessionID == sessionID }
                        ?? AgentHistory.allConversations(home: home).first { $0.agent == agent && $0.sessionID == sessionID }
                    guard let found else { return .failure(HandoffRequestError.notFound) }
                    return Result {
                        let prepared = try Handoff.prepare(found, to: target, plan: plan, prompt: prompt, note: note, in: folder)
                        return (prepared, prepared.directory)
                    }
                }
            ) { server, client, result in
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
        case .dismissFailure(let id):
            // Seen on one device is seen: it goes from every one.
            guard let index = failures.firstIndex(where: { $0.id == id }) else { return }
            failures.remove(at: index)
            saveFailures()
            broadcastFailures()
        }
    }

    /// Runs a git change, then answers with the folder's changes as they are
    /// now, so the client's list is right whether it worked or not. A push
    /// or a pull (`sync`) takes long enough for other answers about the
    /// folder to come in between, so its end is said in so many words.
    private func git(for client: Client, in path: String, sync: Bool = false, _ action: @escaping () -> String?) {
        work(
            for: client,
            { () -> (String?, DiffSnapshot) in
                let problem = action()
                return (problem, GitDiff.snapshot(directory: path))
            }
        ) { server, client, result in
            server.diffCache[path] = (result.1, Date())
            if let problem = result.0 { server.send(.error(problem), to: client) }
            server.send(.diff(path: path, snapshot: result.1.withoutPatches), to: client)
            if sync { server.send(.gitSynced(path: path), to: client) }
        }
    }

    /// Runs a change to the files, answers with what it returns or with the
    /// problem, then with the folder's listing as it is now.
    private func files(for client: Client, in directory: String?, _ action: @escaping () throws -> ServerMessage?) {
        work(
            for: client,
            { () -> (ServerMessage?, [FileEntry]?) in
                var answer: ServerMessage?
                do { answer = try action() } catch { answer = .error("\(error)") }
                return (answer, directory.map { FileBrowser.list($0) })
            }
        ) { server, client, result in
            if let answer = result.0 { server.send(answer, to: client) }
            if let directory, let entries = result.1 { server.send(.files(path: directory, entries: entries), to: client) }
        }
    }

    /// Has an agent write the commit message for what is staged in a
    /// folder, and answers with it. One run per folder: asking again
    /// replaces the run under way.
    private func writeCommitMessage(in path: String, for client: Client) {
        commitRuns.removeValue(forKey: path)?.cancel()
        let run = CommitWriter.Run()
        commitRuns[path] = run
        let settings = commitWriter
        let known = agents
        let detect = configuration.detectAgents
        let scratch = commitWriterDirectory
        let id = client.id
        workQueue.async { [weak self] in
            let installed = known ?? detect()
            let result = CommitWriter.write(in: path, settings: settings, agents: installed, scratch: scratch, run: run)
            self?.queue.async {
                guard let self else { return }
                if self.agents == nil { self.agents = installed }
                if self.commitRuns[path] === run { self.commitRuns[path] = nil }
                guard let client = self.clients[id] else { return }
                switch result {
                case .success(let message):
                    self.send(.commitMessage(path: path, message: message), to: client)
                case .failure(let failure):
                    // Stopping is what was asked for, not a problem to report.
                    if failure != .cancelled { self.send(.error("\(failure)"), to: client) }
                    self.send(.commitMessage(path: path, message: nil), to: client)
                }
            }
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
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            )
        else { return nil }
        let folders =
            entries
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

    /// What a session's agent's hooks last said (`AgentHooks`).
    private func eventsFile(for id: SessionID) -> URL? {
        configuration.usageDirectory?.appendingPathComponent("session-\(id).events.json")
    }

    /// Watches the folder the hooks write in, so that a state is known when
    /// it begins rather than at the next refresh.
    private var eventsWatch: DispatchSourceFileSystemObject?

    private func watchEvents() {
        guard let directory = configuration.usageDirectory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: queue)
        source.setEventHandler { [weak self] in self?.readEvents() }
        source.setCancelHandler { Darwin.close(descriptor) }
        source.resume()
        eventsWatch = source
    }

    /// Reads what each session's hooks said since the last look, and tells
    /// every client of a state that changed.
    private func readEvents() {
        var changed = false
        for session in sessions.values where session.hooked {
            guard let file = eventsFile(for: session.info.id), let data = FileManager.default.contents(atPath: file.path),
                data != session.lastEvent
            else { continue }
            session.lastEvent = data
            guard let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                let agent = record["agent"] as? String, let event = record["event"] as? String
            else { continue }
            let at = (record["at"] as? Double).map(Date.init(timeIntervalSince1970:)) ?? Date()
            guard case .set(var state) = AgentHooks.change(agent: agent, event: event, input: record["input"] as? [String: Any] ?? [:], now: at)
            else { continue }
            // Still working is working since it began.
            if case .working = state, case .working(let since)? = session.info.state { state = .working(since: since) }
            let note = AgentHooks.note(agent: session.info.agent, beforeAnyEvent: false)
            guard state != session.info.state || note != session.info.stateNote else { continue }
            session.info.state = state
            session.info.stateNote = note
            changed = true
        }
        if changed { broadcastSessions() }
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
        send(.welcome(version: configuration.protocolVersion, host: Host.current().localizedName ?? "Mac"), to: client)
        send(.sessions(sessions.values.map(\.info).sorted { $0.id < $1.id }), to: client)
        // What stopped before this client came, until someone has seen it.
        send(.failures(failures), to: client)
        if !accountUsage.isEmpty { send(.accountUsage(accountUsageList()), to: client) }
        send(.folders(folders), to: client)
        send(.tabLayout(tabLayout), to: client)
        send(.keepAwake(keepAwake), to: client)
        send(.keepAwakeOptions(keepAwakeOptions), to: client)
        send(.commitWriter(commitWriter), to: client)
        if let item = configuration.loginItem { send(.startAtLogin(item.isOn), to: client) }
        // Without any yet, the client is sent none and hands over its own.
        send(.displaySettings(displaySettings), to: client)
        if let systemStats { send(.systemStats(systemStats), to: client) }
        if client.isAdmin {
            send(.devices(deviceList()), to: client)
        } else {
            broadcastDevices()
        }
    }

    private func deviceList() -> [DeviceInfo] {
        let connected = Set(
            clients.values.compactMap { client -> String? in
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
        // It may have stopped the turn, and not every agent says so.
        if session.info.state?.isWorking == true, AgentHooks.mayStopATurn(frame.payload) {
            session.info.state = nil
            broadcastSessions()
        }
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
        var environment = HostEnvironment.sessionEnvironment()
        let agent = SessionSummaries.agent(forCommand: command)
        var hooked = false
        if let agent, let tool = configuration.statusLineTool, let events = eventsFile(for: id) {
            // Claude Code reports its usage through its status line, and
            // every agent what it is doing through its hooks.
            let usage = agent == "claude" ? usageFile(for: id) : nil
            for file in [usage, events].compactMap({ $0 }) { try? FileManager.default.removeItem(at: file) }
            if let more = try? AgentHooks.launchArguments(
                agent: agent, tool: tool, usageFile: usage?.path, directory: configuration.hooksDirectory, home: configuration.home)
            {
                command = (command ?? "") + more
                environment[AgentHooks.eventsVariable] = events.path
                hooked = true
            }
        }
        if let directory = configuration.agentsDirectory, let agent = SessionSummaries.agent(forCommand: command), let text = command,
            text == agent || text.hasPrefix(agent + " ")
        {
            command = Handoff.shellQuote((directory as NSString).appendingPathComponent(agent)) + text.dropFirst(agent.count)
        }
        let process: PTYProcess
        do {
            process = try PTYProcess(
                executable: HostEnvironment.shell,
                arguments: HostEnvironment.shellArguments(command: command),
                environment: environment,
                cwd: cwd,
                size: size,
                queue: queue
            )
        } catch {
            send(.error("\(error)"), to: client)
            return
        }

        nextSessionID += 1
        let fallbackTitle =
            request.command?.split(separator: " ").first.map(String.init)
            ?? (HostEnvironment.shell as NSString).lastPathComponent
        let info = SessionInfo(
            id: id, title: request.title ?? fallbackTitle, cwd: cwd, size: size, createdAt: Date(),
            agent: SessionSummaries.agent(forCommand: request.command),
            // A session started with an agent's own resume command is that
            // conversation's, whoever typed the command.
            conversationID: conversationID ?? SessionSummaries.resumedConversation(inCommand: request.command),
            stateNote: hooked ? AgentHooks.note(agent: agent, beforeAnyEvent: true) : nil
        )
        let session = Session(info: info, process: process, screenLines: configuration.screenLines)
        session.hooked = hooked
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

    private func attach(_ client: Client, to session: Session, size: TermSize, have: Int? = nil) {
        client.attached.insert(session.info.id)
        // Watching is not using: this only sets the size if nobody else is attached.
        let changed = session.arbiter.update(client.id, size: size)
        if changed {
            session.info.size = session.arbiter.currentSize
            session.process.resize(session.info.size)
            session.mirror.resize(session.info.size)
        }
        send(.attached(session.info), to: client)
        let replay: Data
        if let have, have <= session.written, session.written - have <= session.scrollback.count {
            // A client that was here before, a phone after its network
            // changed: its terminal has all up to `have`, so only what came
            // since is sent, not a screen it would only draw again.
            replay = session.scrollback.suffix(session.written - have)
        } else {
            // Anyone else gets the screen as it is now, with the lines
            // above it, written out for the size the session has. To the
            // client it is output like any other, and it counts on from the
            // end of it as it would after the session's own.
            replay = session.mirror.snapshot()
        }
        send(.replaying(session: session.info.id, from: session.written - replay.count), to: client)
        // In pieces: the whole of it may be larger than one message may be.
        var start = replay.startIndex
        while start < replay.endIndex {
            let end = replay.index(start, offsetBy: Self.replayPiece, limitedBy: replay.endIndex) ?? replay.endIndex
            send(DataFrame(kind: .output, session: session.info.id, payload: Data(replay[start..<end])), to: client)
            start = end
        }
        // The replay holds the questions the program once asked its terminal
        // (which terminal are you, where is the cursor). The client must not
        // answer those again: the answers would reach the program as if they
        // were typed. This marks where the replay ends.
        send(.replayed(session: session.info.id), to: client)
        announceSize(of: session)
    }

    /// How much of a replay goes in one message. Well under what a message
    /// may hold, and small enough that live output is not kept waiting.
    private static let replayPiece = 256 * 1024

    private func record(_ data: Data, in session: Session) {
        session.mirror.feed(data)
        session.scrollback.append(data)
        session.written += data.count
        // Cut back to the limit only once it is well past it: cutting
        // copies what is kept, and doing that for every piece of output of
        // a busy program would copy megabytes many times a second.
        let limit = configuration.scrollbackLimit
        if session.scrollback.count > limit + max(limit / 4, 64 * 1024) {
            session.scrollback = Data(session.scrollback.suffix(limit))
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
        session.mirror.resize(session.info.size)
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
        if let file = usageFile(for: id) {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(atPath: StatusLineRelay.failureFile(for: file.path))
        }
        if let file = eventsFile(for: id) { try? FileManager.default.removeItem(at: file) }
        if !session.endAsked, let reason = Self.unexpectedEnd(code: status) {
            report(
                PartFailure(
                    part: .session, name: session.info.displayName, at: Date(), ended: [EndedSession(session.info)], restarted: false,
                    reason: reason))
        }
        for clientID in session.arbiter.clients {
            guard let client = clients[clientID] else { continue }
            client.attached.remove(id)
            send(.exited(session: id, status: status), to: client)
        }
        broadcastSessions()
    }
}
#endif
