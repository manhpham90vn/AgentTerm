import AgenttyProtocol
import Foundation
import Network

/// A WebSocket connection to an Agentty host. Works on macOS and iOS.
///
/// Built on Network.framework rather than URLSession: the host speaks plain
/// `ws://` inside loopback or a Tailscale tunnel, which App Transport Security
/// would refuse for URLSession on iOS.
///
/// Callbacks are delivered on the main queue.
public final class AgenttyConnection: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case connecting
        case connected
        case closed(reason: String?)
    }

    public var onState: ((State) -> Void)?
    public var onMessage: ((ServerMessage) -> Void)?
    public var onOutput: ((SessionID, Data) -> Void)?

    private let token: String
    private let clientName: String
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "agentty.client")
    /// Touched on the main queue only.
    private var closed = false

    public init(host: String, port: UInt16, token: String, clientName: String) {
        self.token = token
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
                self.send(.hello(token: self.token, client: self.clientName))
                self.deliver { if !self.closed { self.onState?(.connected) } }
                self.receive()
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
