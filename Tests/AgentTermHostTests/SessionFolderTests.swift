import AgentTermClient
import AgentTermProtocol
import XCTest

@testable import AgentTermHost

/// SES-26: a session whose folder is not there, or that names none, starts
/// in the host's home folder: under the tests, the test's own, never the
/// home folder of the person running them.
final class SessionFolderTests: XCTestCase {
    private final class Client {
        let connection: AgentTermConnection
        var messages: [ServerMessage] = []

        init(port: UInt16, token: String) {
            connection = AgentTermConnection(host: "127.0.0.1", port: port, credential: .token(token), clientName: "mac")
            connection.onMessage = { [weak self] in self?.messages.append($0) }
            connection.connect()
        }

        var sessions: [SessionInfo] { messages.compactMap { if case .sessions(let list) = $0 { return list } else { return nil } }.last ?? [] }
    }

    private var root: URL!
    private var server: HostServer!

    override func tearDown() {
        server?.stop()
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 10, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertTrue(condition(), "timed out waiting for: \(what)")
    }

    func testASessionWithNoFolderStartsInTheHostsHome() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-home-\(UUID().uuidString)").standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let token = "test-token-0123456789abcdef0123456789"
        var configuration = HostServer.Configuration(port: 0, token: token, listenOnTailscale: false, detectAgents: { [] })
        configuration.home = root.path
        server = HostServer(configuration: configuration)
        let client = Client(port: try server.start(), token: token)
        waitUntil("connected") { !client.messages.isEmpty }

        client.connection.send(.create(CreateRequest(command: "exec sleep 600", cwd: root.appendingPathComponent("gone").path, title: "gone")))
        client.connection.send(.create(CreateRequest(command: "exec sleep 600", title: "none")))
        waitUntil("both sessions") { client.sessions.count == 2 }
        XCTAssertEqual(client.sessions.map(\.cwd), [root.path, root.path])
    }
}
