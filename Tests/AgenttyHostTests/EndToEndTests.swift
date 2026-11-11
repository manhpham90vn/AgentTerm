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

        convenience init(port: UInt16, token: String, name: String) {
            self.init(port: port, credential: .token(token), name: name)
        }

        init(port: UInt16, credential: AgenttyConnection.Credential, name: String) {
            connection = AgenttyConnection(host: "127.0.0.1", port: port, credential: credential, clientName: name)
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

        var pairingCode: String? {
            messages.compactMap { if case .pairingCode(let code, _) = $0 { return code } else { return nil } }.last
        }

        var devices: [DeviceInfo]? {
            messages.compactMap { if case .devices(let list) = $0 { return list } else { return nil } }.last
        }

        var pairedToken: String? {
            messages.compactMap { if case .paired(_, let token) = $0 { return token } else { return nil } }.last
        }

        var welcomed: Bool { messages.contains { if case .welcome = $0 { return true } else { return false } } }
        var isClosed: Bool { if case .closed = state { return true } else { return false } }

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

        // The phone only watches at first: the Mac keeps its size.
        let phone = connect("phone")
        phone.connection.send(.attach(session: id, size: phoneSize))
        waitUntil("phone is told the size") { phone.lastResize?.driver == false && phone.lastResize?.size == macSize }
        XCTAssertEqual(mac.lastResize?.size, macSize)

        // The user opens the session on the phone: the PTY shrinks to the
        // phone and the Mac is told so.
        phone.connection.send(.takeControl(session: id, size: phoneSize))
        waitUntil("phone drives") { phone.lastResize?.driver == true && phone.lastResize?.size == phoneSize }
        waitUntil("mac follows") { mac.lastResize?.driver == false && mac.lastResize?.size == phoneSize }
        phone.type("stty size\n", in: id)
        waitUntil("pty has phone size") { phone.text(id).contains("30 48") }
        XCTAssertTrue(mac.text(id).contains("30 48"), "both clients see the same output")

        // The Mac window is resized while the phone is in use: nothing changes for the phone.
        let widerMac = TermSize(cols: 140, rows: 44)
        mac.connection.send(.resize(session: id, size: widerMac))
        phone.type("stty size\n", in: id)
        waitUntil("still the phone's size") { phone.text(id).components(separatedBy: "30 48").count >= 3 }
        XCTAssertEqual(phone.lastResize?.size, phoneSize)

        // Typing on the Mac takes control back, at the size it last reported.
        mac.type("stty size\n", in: id)
        waitUntil("mac drives again") { mac.lastResize?.driver == true && mac.lastResize?.size == widerMac }
        waitUntil("pty has mac size") { mac.text(id).contains("44 140") }
        waitUntil("phone follows") { phone.lastResize?.driver == false && phone.lastResize?.size == widerMac }

        // The phone rotates while the Mac is in use: the Mac is not disturbed.
        let landscape = TermSize(cols: 100, rows: 18)
        phone.connection.send(.resize(session: id, size: landscape))
        mac.type("stty size\n", in: id)
        waitUntil("still the mac's size") { mac.text(id).components(separatedBy: "44 140").count >= 3 }

        // Typing on the phone takes control at its rotated size.
        phone.type("stty size\n", in: id)
        waitUntil("phone drives after typing") { mac.lastResize?.size == landscape && mac.lastResize?.driver == false }

        // The phone disconnects: the Mac gets its size back.
        phone.connection.close()
        waitUntil("mac restored") { mac.lastResize?.driver == true && mac.lastResize?.size == widerMac }
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

    func testAPhonePairsWithACodeThenUsesItsOwnToken() {
        let mac = connect("mac")
        waitUntil("no devices yet") { mac.devices == [] }
        mac.connection.send(.createPairingCode)
        waitUntil("code") { mac.pairingCode != nil }
        let code = mac.pairingCode!

        // The phone trades the code for a token and is let in.
        let phone = TestClient(port: port, credential: .pairingCode(code), name: "iPhone của Mạnh")
        waitUntil("paired") { phone.pairedToken != nil && phone.welcomed }
        let token = phone.pairedToken!
        XCTAssertNotEqual(token, code)
        waitUntil("the Mac sees the device") { mac.devices?.map(\.name) == ["iPhone của Mạnh"] && mac.devices?.first?.isConnected == true }

        // The code does not work a second time.
        let late = TestClient(port: port, credential: .pairingCode(code), name: "someone else")
        waitUntil("refused") { late.messages.contains(.error("invalid pairing code")) && late.isClosed }
        XCTAssertNil(late.pairedToken)
        XCTAssertEqual(mac.devices?.count, 1)

        // Later the phone connects with its token, and can use sessions.
        phone.connection.close()
        waitUntil("the Mac sees it leave") { mac.devices?.first?.isConnected == false }
        let again = TestClient(port: port, token: token, name: "iPhone của Mạnh")
        waitUntil("welcome") { again.welcomed }
        again.connection.send(.create(CreateRequest(command: "echo from-phone-$((1+1))")))
        waitUntil("attached") { again.attached != nil }
        waitUntil("output") { again.text(again.attached!.id).contains("from-phone-2") }
        XCTAssertNil(again.devices, "the device list is not shown to devices")
    }

    func testOnlyTheMacMayPairAndRevoke() {
        let mac = connect("mac")
        mac.connection.send(.createPairingCode)
        waitUntil("code") { mac.pairingCode != nil }
        let phone = TestClient(port: port, credential: .pairingCode(mac.pairingCode!), name: "phone")
        waitUntil("paired") { phone.welcomed }
        waitUntil("listed") { mac.devices?.count == 1 }
        let id = mac.devices![0].id

        // A paired device cannot hand out access or remove devices.
        for message in [ClientMessage.createPairingCode, .cancelPairingCode, .listDevices, .revokeDevice(id: id)] {
            phone.connection.send(message)
        }
        waitUntil("refused four times") { phone.messages.filter { $0 == .error("not allowed") }.count == 4 }
        XCTAssertNil(phone.pairingCode)
        XCTAssertEqual(mac.devices?.count, 1)

        // The Mac revokes it: the connection drops and the token is dead.
        let token = phone.pairedToken!
        mac.connection.send(.revokeDevice(id: id))
        waitUntil("phone disconnected") { phone.isClosed }
        waitUntil("list emptied") { mac.devices == [] }
        let revoked = TestClient(port: port, token: token, name: "phone")
        waitUntil("token refused") { revoked.messages.contains(.error("invalid token")) && revoked.isClosed }
    }

    func testACancelledCodeDoesNotPair() {
        let mac = connect("mac")
        mac.connection.send(.createPairingCode)
        waitUntil("code") { mac.pairingCode != nil }
        mac.connection.send(.cancelPairingCode)
        mac.connection.send(.listDevices)
        waitUntil("cancel processed") { mac.messages.filter { if case .devices = $0 { return true } else { return false } }.count >= 2 }
        let phone = TestClient(port: port, credential: .pairingCode(mac.pairingCode!), name: "phone")
        waitUntil("refused") { phone.messages.contains(.error("invalid pairing code")) && phone.isClosed }
        XCTAssertEqual(mac.devices, [])
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
