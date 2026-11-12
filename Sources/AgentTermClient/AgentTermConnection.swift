import AgentTermProtocol
import Foundation
import Network

/// A WebSocket connection to an AgentTerm host. Works on macOS and iOS.
///
/// Built on Network.framework rather than URLSession: the host speaks plain
/// `ws://` inside loopback or a Tailscale tunnel, which App Transport Security
/// would refuse for URLSession on iOS.
///
/// Callbacks are delivered on the main queue.
public final class AgentTermConnection: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case connecting
        case connected
        case closed(reason: String?)
    }

    /// How the connection introduces itself.
    public enum Credential: Equatable, Sendable {
        /// A token the host already knows: a paired device's, or the Mac's own.
        case token(String)
        /// A pairing code, to be traded for a token. The host answers with `paired`.
        case pairingCode(String)
    }

    public var onState: ((State) -> Void)?
    public var onMessage: ((ServerMessage) -> Void)?
    public var onOutput: ((SessionID, Data) -> Void)?

    private let credential: Credential
    private let clientName: String
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "agentterm.client")
    /// Touched on the main queue only.
    private var closed = false

    // A connection that died without a word is the common case on a phone:
    // the network changed, the tunnel dropped, the app was asleep. Nothing
    // says so; what is sent simply goes nowhere, and TCP takes minutes to
    // give up. So the host is asked for a sign of life whenever it has been
    // quiet, and a connection that does not answer is closed here, which is
    // what lets the app connect again. All of this is on `queue`.
    private var heartbeat: DispatchSourceTimer?
    private var lastHeard = DispatchTime.now()
    private var lastTick = DispatchTime.now()
    private var pingSentAt: DispatchTime?
    /// How often the connection is looked at, how long a quiet host is left
    /// alone, and how long it has to answer.
    private static let heartbeatInterval: TimeInterval = 2
    private static let quietBeforePing: TimeInterval = 4
    private static let pongTimeout: TimeInterval = 6

    public convenience init(host: String, port: UInt16, token: String, clientName: String) {
        self.init(host: host, port: port, credential: .token(token), clientName: clientName)
    }

    public init(host: String, port: UInt16, credential: Credential, clientName: String) {
        self.credential = credential
        self.clientName = clientName

        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 8
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 30
        tcp.noDelay = true
        let webSocket = NWProtocolWebSocket.Options()
        webSocket.autoReplyPing = true
        webSocket.maximumMessageSize = 4 * 1024 * 1024
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        // A URL endpoint, not host and port: the WebSocket handshake needs
        // the host header and path that only the URL form provides.
        var components = URLComponents()
        components.scheme = "ws"
        components.host = host
        components.port = Int(port)
        components.path = "/"
        connection = NWConnection(to: .url(components.url ?? URL(string: "ws://127.0.0.1/")!), using: parameters)
    }

    public func connect() {
        deliver { self.onState?(.connecting) }
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                switch self.credential {
                case .token(let token): self.send(.hello(token: token, client: self.clientName))
                case .pairingCode(let code): self.send(.pair(code: code, device: self.clientName))
                }
                self.deliver { if !self.closed { self.onState?(.connected) } }
                self.receive()
                self.startHeartbeat()
            case .waiting(let error), .failed(let error):
                // `.waiting` covers "connection refused" and "no route". The
                // caller decides when to retry, so do not linger here.
                self.finish(reason: error.localizedDescription)
            case .cancelled:
                self.finish(reason: nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    public func send(_ message: ClientMessage) {
        send(MessageCoding.encode(message), opcode: .text)
    }

    public func sendInput(_ data: Data, to session: SessionID) {
        send(DataFrame(kind: .input, session: session, payload: data).encoded(), opcode: .binary)
    }

    public func close() {
        finish(reason: nil)
    }

    /// Asks the host for a sign of life now. For when the app comes back to
    /// the front: the connection it left may no longer be one.
    public func check() {
        queue.async { [weak self] in
            guard let self, self.heartbeat != nil else { return }
            self.pingSentAt = nil
            self.ping()
        }
    }

    private func startHeartbeat() {
        lastHeard = .now()
        lastTick = .now()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.heartbeatInterval, repeating: Self.heartbeatInterval)
        timer.setEventHandler { [weak self] in self?.beat() }
        heartbeat = timer
        timer.resume()
    }

    private func beat() {
        let now = DispatchTime.now()
        let sinceTick = Self.seconds(from: lastTick, to: now)
        lastTick = now
        if sinceTick > Self.heartbeatInterval * 3 {
            // The app was suspended in between. How long the host has been
            // quiet says nothing then: ask afresh and give it its time.
            pingSentAt = nil
            ping()
            return
        }
        if let sent = pingSentAt {
            if Self.seconds(from: sent, to: now) > Self.pongTimeout { finish(reason: "The connection to the Mac was lost.") }
        } else if Self.seconds(from: lastHeard, to: now) > Self.quietBeforePing {
            ping()
        }
    }

    private func ping() {
        pingSentAt = .now()
        let metadata = NWProtocolWebSocket.Metadata(opcode: .ping)
        metadata.setPongHandler(queue) { [weak self] error in
            guard let self, error == nil else { return }
            self.heard()
        }
        let context = NWConnection.ContentContext(identifier: "ping", metadata: [metadata])
        connection.send(content: Data(), contentContext: context, completion: .idempotent)
    }

    /// Anything from the host is a sign of life.
    private func heard() {
        lastHeard = .now()
        pingSentAt = nil
    }

    private static func seconds(from start: DispatchTime, to end: DispatchTime) -> TimeInterval {
        end.uptimeNanoseconds > start.uptimeNanoseconds ? TimeInterval(end.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000 : 0
    }

    private func send(_ data: Data, opcode: NWProtocolWebSocket.Opcode) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: opcode)
        let context = NWConnection.ContentContext(identifier: "message", metadata: [metadata])
        connection.send(content: data, contentContext: context, completion: .idempotent)
    }

    private func receive() {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            if let error {
                self.finish(reason: error.localizedDescription)
                return
            }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            self.heard()
            switch metadata?.opcode {
            case .text:
                if let data, let message = MessageCoding.decode(ServerMessage.self, from: data) {
                    self.deliver { if !self.closed { self.onMessage?(message) } }
                }
            case .binary:
                if let data, let frame = DataFrame(decoding: data), frame.kind == .output {
                    self.deliver { if !self.closed { self.onOutput?(frame.session, frame.payload) } }
                }
            case .close:
                self.finish(reason: nil)
                return
            default:
                // No metadata means the stream ended.
                if data == nil && context == nil {
                    self.finish(reason: nil)
                    return
                }
            }
            self.receive()
        }
    }

    private func finish(reason: String?) {
        queue.async { [weak self] in
            self?.heartbeat?.cancel()
            self?.heartbeat = nil
        }
        deliver {
            guard !self.closed else { return }
            self.closed = true
            self.connection.cancel()
            self.onState?(.closed(reason: reason))
        }
    }

    private func deliver(_ block: @escaping () -> Void) {
        DispatchQueue.main.async(execute: block)
    }
}
