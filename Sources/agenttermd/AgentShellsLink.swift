import AgentTermClient
import AgentTermHost
import AgentTermProtocol
import Foundation

/// The line from an agent's MCP server (`agenttermd mcp`) to the host its
/// session belongs to: it sends what the agent's tools ask and waits for the
/// host's answer.
///
/// A host that cannot be reached, or that refuses the server, is said to the
/// agent at once and with the reason (#58), rather than after a wait that
/// says nothing: an agent that is only told "did not answer" tries again,
/// and runs its commands out of the user's sight meanwhile. Each call on a
/// line that is down tries the host once more, so a host that was started
/// again is found by the next call, and one that is still gone answers in
/// no time.
final class AgentShellsLink {
    private let port: UInt16
    private let key: String
    private let token: String
    /// How long the host has to answer one request.
    private let patience: TimeInterval

    private let lock = NSLock()
    private var connection: AgentTermConnection?
    /// Why the line is down, in words for the agent; nil while it is up or
    /// being set up.
    private var down: String?
    /// What the host said before it took the server in, if it refused it.
    private var refusal: String?
    /// The protocol the host speaks, once it has taken the server in.
    private var hostVersion: Int?
    private var answers: [Int: AgentShellResult] = [:]
    private var waiting: [Int: DispatchSemaphore] = [:]
    private var next = 0

    init(port: UInt16, key: String, token: String, patience: TimeInterval = 15) {
        self.port = port
        self.key = key
        self.token = token
        self.patience = patience
    }

    /// Signs in before anything is asked, so that a host that refuses the
    /// server knows, and warns the user, before the agent needs a shell.
    func start() {
        lock.lock()
        if connection == nil { _ = connect() }
        lock.unlock()
    }

    /// Asks the host and waits for its answer, or for the line to go down.
    func ask(_ request: AgentShellRequest) -> AgentShellResult {
        lock.lock()
        let connection = self.connection ?? connect()
        next += 1
        let id = next
        let semaphore = DispatchSemaphore(value: 0)
        waiting[id] = semaphore
        lock.unlock()
        let key = self.key
        DispatchQueue.main.async { connection.send(.agentShell(id: id, key: key, request: request)) }
        let answered = semaphore.wait(timeout: .now() + patience) == .success
        lock.lock()
        defer { lock.unlock() }
        waiting[id] = nil
        if let answer = answers.removeValue(forKey: id) { return answer }
        if let down { return .refused(down) }
        // Up, as far as is known, and silent.
        var why = answered ? "AgentTerm's host gave no answer." : "AgentTerm's host did not answer within \(Int(patience)) seconds."
        if let hostVersion, hostVersion != agenttermProtocolVersion {
            why += " It speaks protocol \(hostVersion) and this server protocol \(agenttermProtocolVersion): restart the host from AgentTerm's Settings."
        }
        return .refused(why)
    }

    /// Starts a connection. Called with the lock held.
    private func connect() -> AgentTermConnection {
        let connection = AgentTermConnection(host: "127.0.0.1", port: port, credential: .token(token), clientName: HostServer.agentShellsClient)
        self.connection = connection
        down = nil
        refusal = nil
        hostVersion = nil
        connection.onMessage = { [weak self, weak connection] message in
            guard let self, let connection else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            guard self.connection === connection else { return }
            switch message {
            case .welcome(let version, _):
                self.hostVersion = version
            case .error(let said) where self.hostVersion == nil:
                self.refusal = said
            case .agentShellResult(let id, let result):
                self.answers[id] = result
                self.waiting.removeValue(forKey: id)?.signal()
            default:
                break
            }
        }
        connection.onState = { [weak self, weak connection] state in
            guard let self, let connection, case .closed(let reason) = state else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            guard self.connection === connection else { return }
            self.connection = nil
            self.down = Self.words(port: self.port, refusal: self.refusal, welcomed: self.hostVersion != nil, reason: reason)
            // Whoever waits is told now, not when its time is up.
            for semaphore in self.waiting.values { semaphore.signal() }
            self.waiting = [:]
        }
        DispatchQueue.main.async { connection.connect() }
        return connection
    }

    /// Why the line is down, and what to do about it, for the agent.
    static func words(port: UInt16, refusal: String?, welcomed: Bool, reason: String?) -> String {
        let because = reason.map { " (\($0))" } ?? ""
        if let refusal {
            guard refusal == "invalid token" else { return "AgentTerm's host refused this server: \(refusal)." }
            return
                "AgentTerm's host refused this server's sign-in: its token is not that host's. The session was started by another copy of AgentTerm, or the host was set up again since. Tell the user, who is warned of it in AgentTerm too; a new session of the agent puts it right."
        }
        if welcomed {
            return "The connection to AgentTerm's host was lost\(because): the host stopped or was started again. Try again in a moment."
        }
        return "AgentTerm's host is not running on port \(port)\(because). Tell the user to open AgentTerm, which starts it; then try again."
    }
}
