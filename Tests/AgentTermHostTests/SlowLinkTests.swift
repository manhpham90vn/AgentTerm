import AgentTermHost
import AgentTermProtocol
import Network
import XCTest

@testable import AgentTermClient

/// A link that is slow is not a link that is dead.
final class SlowLinkTests: XCTestCase {
    /// Stands between a client and the host and lets what the host sends
    /// through a little at a time, as a weak cellular link would.
    private final class SlowProxy {
        private let listener: NWListener
        private let target: UInt16
        private let queue = DispatchQueue(label: "agentterm.test.proxy")
        private var connections: [NWConnection] = []
        /// Bytes let through per step, and the time between steps.
        private let piece: Int
        private let pause: TimeInterval
        /// Set to let nothing more through, as when the link is gone
        /// without either end being told.
        var stalled = false

        init(to target: UInt16, bytesPerSecond: Int) throws {
            self.target = target
            pause = 0.02
            piece = max(1, Int(Double(bytesPerSecond) * pause))
            listener = try NWListener(using: .tcp, on: .any)
            listener.newConnectionHandler = { [weak self] client in self?.accept(client) }
        }

        func start() -> UInt16 {
            let ready = DispatchSemaphore(value: 0)
            listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
            listener.start(queue: queue)
            _ = ready.wait(timeout: .now() + 5)
            return listener.port?.rawValue ?? 0
        }

        func stop() {
            listener.cancel()
            queue.sync { connections.forEach { $0.cancel() } }
        }

        private func accept(_ client: NWConnection) {
            let host = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: target)!, using: .tcp)
            connections += [client, host]
            client.start(queue: queue)
            host.start(queue: queue)
            pump(from: client, to: host, piece: 65536, pause: 0)
            pump(from: host, to: client, piece: piece, pause: pause)
        }

        private func pump(from: NWConnection, to: NWConnection, piece: Int, pause: TimeInterval) {
            from.receive(minimumIncompleteLength: 1, maximumLength: piece) { [weak self] data, _, complete, error in
                guard let self, let data, !data.isEmpty else {
                    if complete || error != nil { to.cancel() }
                    return
                }
                guard !self.stalled else { return }
                to.send(
                    content: data,
                    completion: .contentProcessed { _ in
                        self.queue.asyncAfter(deadline: .now() + pause) { self.pump(from: from, to: to, piece: piece, pause: pause) }
                    })
            }
        }
    }

    private var server: HostServer!
    private var port: UInt16 = 0
    private let token = "test-token-0123456789abcdef0123456789"

    override func setUpWithError() throws {
        server = HostServer(configuration: .init(port: 0, token: token, listenOnTailscale: false, detectAgents: { [] }))
        port = try server.start()
    }

    override func tearDown() {
        server.stop()
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 10, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(condition(), "timed out waiting for: \(what)")
    }

    func testWhatIsSentBeforeTheConnectionIsUpWaitsForTheGreeting() {
        // An app asks for things on a timer, also while it is connecting
        // again. The host closes a client whose first word is not its hello.
        let client = AgentTermConnection(host: "127.0.0.1", port: port, token: token, clientName: "early")
        var state: AgentTermConnection.State = .connecting
        var welcomed = false
        var listed = false
        client.onState = { state = $0 }
        client.onMessage = {
            if case .welcome = $0 { welcomed = true }
            if case .directory = $0 { listed = true }
        }
        client.connect()
        client.send(.listDirectory(path: nil))
        defer { client.close() }
        waitUntil("the answer to what was sent early") {
            if case .closed = state { return true }
            return listed
        }
        XCTAssertTrue(welcomed, "the host closed the connection: \(state)")
        XCTAssertTrue(listed)
    }

    func testAReplayThatArrivesSlowlyDoesNotCloseTheConnection() throws {
        // A session with a few hundred kilobytes behind it.
        let near = AgentTermConnection(host: "127.0.0.1", port: port, token: token, clientName: "near")
        var session: SessionID?
        var produced = 0
        var nearWelcomed = false
        near.onMessage = {
            if case .welcome = $0 { nearWelcomed = true }
            if case .attached(let info) = $0 { session = info.id }
        }
        near.onOutput = { _, data in produced += data.count }
        near.connect()
        defer { near.close() }
        waitUntil("welcome") { nearWelcomed }
        near.send(.create(CreateRequest(command: "head -c 300000 /dev/zero | tr '\\0' 'x'; sleep 60")))
        waitUntil("the output") { produced >= 300_000 }
        let id = try XCTUnwrap(session)

        // Another device attaches over a link that carries at most 100 KB a
        // second, and less on a machine whose timers are slow, so one
        // piece of the replay takes seconds. Its
        // heartbeat is the real one sped up ten times: a host that says
        // nothing for 0.4 s is asked, and has 0.6 s to answer.
        let proxy = try SlowProxy(to: port, bytesPerSecond: 100_000)
        let slowPort = proxy.start()
        defer { proxy.stop() }
        let far = AgentTermConnection(host: "127.0.0.1", port: slowPort, token: token, clientName: "far")
        far.heartbeatInterval = 0.2
        far.quietBeforePing = 0.4
        far.pongTimeout = 0.6
        var state: AgentTermConnection.State = .connecting
        var replayed = false
        var received = 0
        far.onState = { state = $0 }
        far.onMessage = { message in
            if case .welcome = message { far.send(.attach(session: id, size: .default)) }
            if case .replayed = message { replayed = true }
        }
        far.onOutput = { _, data in received += data.count }
        far.connect()
        defer { far.close() }

        waitUntil("the replay, or the connection closing", timeout: 180) {
            if case .closed = state { return true }
            return replayed
        }
        XCTAssertEqual(state, .connected, "a connection that was only slow was closed after \(received) bytes")
        XCTAssertTrue(replayed)
        XCTAssertGreaterThanOrEqual(received, 300_000)
    }

    func testAHostThatStopsAnsweringIsStillNoticed() throws {
        // Nothing at all comes through: this one is dead, and has to go.
        let proxy = try SlowProxy(to: port, bytesPerSecond: 50_000)
        let slowPort = proxy.start()
        defer { proxy.stop() }
        let far = AgentTermConnection(host: "127.0.0.1", port: slowPort, token: token, clientName: "far")
        far.heartbeatInterval = 0.2
        far.quietBeforePing = 0.4
        far.pongTimeout = 0.6
        var state: AgentTermConnection.State = .connecting
        var welcomed = false
        far.onState = { state = $0 }
        far.onMessage = { if case .welcome = $0 { welcomed = true } }
        far.connect()
        defer { far.close() }
        waitUntil("welcome") { welcomed }
        proxy.stalled = true
        waitUntil("the connection given up") { state == .closed(reason: "The connection to the Mac was lost.") }
    }
}
