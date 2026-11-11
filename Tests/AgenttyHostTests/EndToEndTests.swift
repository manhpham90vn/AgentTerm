import AgenttyClient
import AgenttyHost
import AgenttyProtocol
import XCTest

/// Drives a real server over a real WebSocket on the loopback interface.
final class EndToEndTests: XCTestCase {
    private final class TestClient {
        let connection: AgenttyConnection
        var messages: [ServerMessage] = []
        var output: [SessionID: Data] = [:]
        var state: AgenttyConnection.State = .connecting

        init(port: UInt16, token: String, name: String) {
            connection = AgenttyConnection(host: "127.0.0.1", port: port, token: token, clientName: name)
            connection.onMessage = { [weak self] in self?.messages.append($0) }
            connection.onOutput = { [weak self] id, data in self?.output[id, default: Data()].append(data) }
            connection.onState = { [weak self] in self?.state = $0 }
            connection.connect()
        }

        func text(_ session: SessionID) -> String { String(decoding: output[session] ?? Data(), as: UTF8.self) }

        var attached: SessionInfo? {
            messages.compactMap { if case .attached(let info) = $0 { return info } else { return nil } }.last
        }

        var lastResize: (size: TermSize, driver: Bool)? {
            messages.compactMap { if case .resized(_, let size, let driver) = $0 { return (size, driver) } else { return nil } }.last
        }

        func type(_ text: String, in session: SessionID) { connection.sendInput(Data(text.utf8), to: session) }
    }

    private var server: HostServer!
    private var port: UInt16 = 0
    private let token = "test-token-0123456789abcdef0123456789"

    override func setUpWithError() throws {
        server = HostServer(configuration: .init(
            port: 0, token: token, listenOnTailscale: false,
            detectAgents: { [AgentInfo(id: "claude", name: "Claude Code", path: "/bin/claude"), AgentInfo(id: "codex", name: "Codex", path: nil)] }
        ))
        port = try server.start()
        XCTAssertNotEqual(port, 0)
    }

    override func tearDown() {
        server.stop()
    }

    /// Spins the main run loop, where client callbacks arrive, until `condition` holds.
    private func waitUntil(_ what: String, timeout: TimeInterval = 10, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(condition(), "timed out waiting for: \(what)")
    }

    private func connect(_ name: String = "test") -> TestClient {
        let client = TestClient(port: port, token: token, name: name)
        waitUntil("welcome") { client.messages.contains { if case .welcome = $0 { return true } else { return false } } }
        return client
    }

    func testWrongTokenIsRejected() {
        let client = TestClient(port: port, token: "wrong", name: "intruder")
        waitUntil("error") { client.messages.contains(.error("invalid token")) }
        waitUntil("closed") { if case .closed = client.state { return true } else { return false } }
        client.connection.send(.create(CreateRequest(command: "echo should-not-run")))
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(server.sessionCount, 0)
    }

    func testCommandOutputAndExit() {
        let client = connect()
        client.connection.send(.create(CreateRequest(command: "echo hello-$((40+2)); exit 3", cwd: "/tmp", title: "demo")))
        waitUntil("attached") { client.attached != nil }
        let id = client.attached!.id
        XCTAssertEqual(client.attached?.title, "demo")
        XCTAssertEqual(client.attached?.cwd, "/tmp")
        waitUntil("output") { client.text(id).contains("hello-42") }
        waitUntil("exit") { client.messages.contains(.exited(session: id, status: 3)) }
        waitUntil("session list emptied") { client.messages.last == .sessions([]) }
    }

    func testInteractiveShellWithVietnameseInput() {
        let client = connect()
        client.connection.send(.create(CreateRequest(command: "cat", size: TermSize(cols: 80, rows: 24))))
        waitUntil("attached") { client.attached != nil }
        let id = client.attached!.id
        client.type("Xin chào, tôi gõ tiếng Việt được\n", in: id)
        // The terminal echoes the line once and `cat` prints it once more.
        waitUntil("echo") { client.text(id).components(separatedBy: "tôi gõ tiếng Việt được").count >= 3 }
        client.connection.send(.kill(session: id))
        waitUntil("exit") { client.messages.contains { if case .exited(id, _) = $0 { return true } else { return false } } }
    }

    func testActiveClientDecidesThePTYSize() {
        let mac = connect("mac")
        let macSize = TermSize(cols: 120, rows: 40)
        let phoneSize = TermSize(cols: 48, rows: 30)
        mac.connection.send(.create(CreateRequest(command: "exec sh", size: macSize)))
        waitUntil("attached") { mac.attached != nil }
        let id = mac.attached!.id
        waitUntil("mac drives") { mac.lastResize?.driver == true && mac.lastResize?.size == macSize }

        // The phone attaches: the PTY shrinks to the phone and the Mac is told so.
        let phone = connect("phone")
        phone.connection.send(.attach(session: id, size: phoneSize))
        waitUntil("phone drives") { phone.lastResize?.driver == true && phone.lastResize?.size == phoneSize }
        waitUntil("mac follows") { mac.lastResize?.driver == false && mac.lastResize?.size == phoneSize }
        phone.type("stty size\n", in: id)
        waitUntil("pty has phone size") { phone.text(id).contains("30 48") }
        XCTAssertTrue(mac.text(id).contains("30 48"), "both clients see the same output")

        // Typing on the Mac takes control back.
        mac.type("stty size\n", in: id)
        waitUntil("mac drives again") { mac.lastResize?.driver == true && mac.lastResize?.size == macSize }
        waitUntil("pty has mac size") { mac.text(id).contains("40 120") }
        waitUntil("phone follows") { phone.lastResize?.driver == false && phone.lastResize?.size == macSize }

        // The phone rotates.
        let landscape = TermSize(cols: 100, rows: 18)
        phone.connection.send(.resize(session: id, size: landscape))
        waitUntil("phone drives after rotating") { mac.lastResize?.size == landscape && mac.lastResize?.driver == false }

        // The phone disconnects: the Mac gets its size back.
        phone.connection.close()
        waitUntil("mac restored") { mac.lastResize?.driver == true && mac.lastResize?.size == macSize }
        mac.connection.send(.kill(session: id))
    }

    func testReattachReplaysRecentOutput() {
        let first = connect()
        first.connection.send(.create(CreateRequest(command: "echo marker-$((6*7)); exec cat")))
        waitUntil("attached") { first.attached != nil }
        let id = first.attached!.id
        waitUntil("output") { first.text(id).contains("marker-42") }
        first.connection.close()

        let second = connect()
        waitUntil("session survives the disconnect") {
            second.messages.contains { if case .sessions(let list) = $0 { return list.map(\.id) == [id] } else { return false } }
        }
        second.connection.send(.attach(session: id, size: .default))
        waitUntil("replay") { second.text(id).contains("marker-42") }
        second.connection.send(.kill(session: id))
    }

    func testAgentListReportsWhatIsInstalled() {
        let client = connect()
        client.connection.send(.agents(refresh: false))
        waitUntil("agents") { client.messages.contains { if case .agents = $0 { return true } else { return false } } }
        guard case .agents(let agents)? = client.messages.last(where: { if case .agents = $0 { return true } else { return false } }) else { return XCTFail() }
        XCTAssertEqual(agents.filter(\.isInstalled).map(\.id), ["claude"])
    }

    func testFolderListIsSharedBetweenClients() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agentty-folder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.standardizedFileURL.path

        func folders(_ client: TestClient) -> [String]? {
            client.messages.compactMap { if case .folders(let list) = $0 { return list } else { return nil } }.last
        }
        let mac = connect("mac")
        let phone = connect("phone")
        waitUntil("initial list") { folders(mac) == [] && folders(phone) == [] }
        mac.connection.send(.addFolder(path: path))
        mac.connection.send(.addFolder(path: path))
        mac.connection.send(.addFolder(path: path + "/missing"))
        waitUntil("phone sees the folder") { folders(phone) == [path] }
        waitUntil("missing folder is refused") { mac.messages.contains { if case .error = $0 { return true } else { return false } } }

        // A later client gets the list on connecting.
        let late = connect("late")
        waitUntil("late client") { folders(late) == [path] }
        phone.connection.send(.removeFolder(path: path))
        waitUntil("removed everywhere") { folders(mac) == [] && folders(late) == [] }
    }

    func testFolderListIsSavedToDisk() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("agentty-folders-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try JSONEncoder().encode(["/tmp"]).write(to: file)
        let saved = HostServer(configuration: .init(port: 0, token: token, listenOnTailscale: false, foldersFile: file))
        let savedPort = try saved.start()
        defer { saved.stop() }
        let client = TestClient(port: savedPort, token: token, name: "test")
        waitUntil("saved list is served") { client.messages.contains(.folders(["/tmp"])) }
        client.connection.send(.addFolder(path: "/usr"))
        waitUntil("written") { (try? JSONDecoder().decode([String].self, from: Data(contentsOf: file))) == ["/tmp", "/usr"] }
    }

    func testInputToASessionTheClientIsNotAttachedToIsIgnored() {
        let owner = connect("owner")
        owner.connection.send(.create(CreateRequest(command: "cat")))
        waitUntil("attached") { owner.attached != nil }
        let id = owner.attached!.id
        let stranger = connect("stranger")
        stranger.type("leak\n", in: id)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertFalse(owner.text(id).contains("leak"))
        owner.connection.send(.kill(session: id))
    }
}
