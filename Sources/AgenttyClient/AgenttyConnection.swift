import AgenttyProtocol
import Foundation

/// A WebSocket connection to an Agentty host. Works on macOS and iOS.
///
/// Callbacks are delivered on the main queue.
public final class AgenttyConnection: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
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
    private var session: URLSession!
    private var task: URLSessionWebSocketTask!
    private var closed = false

    public init(host: String, port: UInt16, token: String, clientName: String) {
        self.token = token
        self.clientName = clientName
        super.init()
        var components = URLComponents()
        components.scheme = "ws"
        components.host = host
        components.port = Int(port)
        components.path = "/"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        task = session.webSocketTask(with: components.url!)
        task.maximumMessageSize = 4 * 1024 * 1024
    }

    public func connect() {
        deliver { self.onState?(.connecting) }
        task.resume()
        send(.hello(token: token, client: clientName))
        receive()
    }

    public func send(_ message: ClientMessage) {
        guard let text = String(data: MessageCoding.encode(message), encoding: .utf8) else { return }
        task.send(.string(text)) { _ in }
    }

    public func sendInput(_ data: Data, to session: SessionID) {
        task.send(.data(DataFrame(kind: .input, session: session, payload: data).encoded())) { _ in }
    }

    public func close() {
        finish(reason: nil)
    }

    private func receive() {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.finish(reason: error.localizedDescription)
            case .success(.string(let text)):
                if let message = MessageCoding.decode(ServerMessage.self, from: Data(text.utf8)) {
                    self.deliver { self.onMessage?(message) }
                }
                self.receive()
            case .success(.data(let data)):
                if let frame = DataFrame(decoding: data), frame.kind == .output {
                    self.deliver { self.onOutput?(frame.session, frame.payload) }
                }
                self.receive()
            case .success:
                self.receive()
            }
        }
    }

    private func finish(reason: String?) {
        deliver {
            guard !self.closed else { return }
            self.closed = true
            self.task.cancel(with: .goingAway, reason: nil)
            self.session.invalidateAndCancel()
            self.onState?(.closed(reason: reason))
        }
    }

    private func deliver(_ block: @escaping () -> Void) {
        DispatchQueue.main.async(execute: block)
    }

    // MARK: URLSessionWebSocketDelegate

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        deliver { if !self.closed { self.onState?(.connected) } }
    }

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        finish(reason: nil)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish(reason: error?.localizedDescription)
    }
}
