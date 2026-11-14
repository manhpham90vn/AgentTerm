import AgentTermClient
import AgentTermHost
import AgentTermProtocol
import Network
import XCTest

/// Drives a real server over a real WebSocket on the loopback interface.
final class EndToEndTests: XCTestCase {
    private final class TestClient {
        let connection: AgentTermConnection
        var messages: [ServerMessage] = []
        var output: [SessionID: Data] = [:]
        var state: AgentTermConnection.State = .connecting

        convenience init(port: UInt16, token: String, name: String) {
            self.init(port: port, credential: .token(token), name: name)
        }

        init(port: UInt16, credential: AgentTermConnection.Credential, name: String) {
            connection = AgentTermConnection(host: "127.0.0.1", port: port, credential: credential, clientName: name)
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
        server = HostServer(
            configuration: .init(
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

        // The phone disconnects: the session keeps its size (SIZE-8), and
        // the Mac gets its own back when it types.
        phone.connection.close()
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        XCTAssertEqual(mac.lastResize?.size, landscape, "the phone's size is kept")
        XCTAssertEqual(mac.lastResize?.driver, false)
        mac.type("stty size\n", in: id)
        waitUntil("mac restored once it types") { mac.lastResize?.driver == true && mac.lastResize?.size == widerMac }
        mac.connection.send(.kill(session: id))
    }

    /// HIST-6: a client that attaches with `history` is sent the screen and
    /// that many lines above it, and told how many the host keeps; it
    /// attaches again with more as it scrolls up.
    func testAPhoneIsSentOnlySoMuchHistoryAndMoreWhenItAsks() {
        let mac = connect("mac")
        let size = TermSize(cols: 40, rows: 10)
        mac.connection.send(.create(CreateRequest(command: "seq 1 2000; exec sleep 600", cwd: NSTemporaryDirectory(), title: "long", size: size)))
        waitUntil("the session") { mac.attached != nil }
        let id = mac.attached!.id
        waitUntil("its output") { mac.text(id).contains("2000") }

        let phone = connect("phone")
        func above() -> Int? { phone.messages.compactMap { if case .replaying(id, _, let above) = $0 { return above } else { return nil } }.last ?? nil }
        func replays() -> Int { phone.messages.filter { $0 == .replayed(session: id) }.count }
        phone.connection.send(.attach(session: id, size: size, history: 100))
        waitUntil("the first replay") { replays() == 1 }
        XCTAssertGreaterThanOrEqual(above() ?? 0, 1990, "the host keeps all of it")
        let first = phone.text(id)
        XCTAssertTrue(first.contains("1950"))
        XCTAssertFalse(first.contains("\r\n1800\r\n"), "more than a hundred lines above the screen were sent")

        phone.connection.send(.attach(session: id, size: size, history: 600))
        waitUntil("the second replay") { replays() == 2 }
        XCTAssertTrue(phone.text(id).contains("\r\n1500\r\n"), "the lines asked for next")
        mac.connection.send(.kill(session: id))
    }

    /// PERF-7: a long session's screen is written out on the session's own
    /// queue, not on the one every session's output goes through; what the
    /// session writes meanwhile reaches the client after the screen.
    func testWhatASessionWritesWhileItsScreenIsWrittenOutFollowsIt() {
        let mac = connect("mac")
        let size = TermSize(cols: 120, rows: 40)
        mac.connection.send(.create(CreateRequest(command: "seq 1 15000; exec cat", cwd: NSTemporaryDirectory(), title: "long", size: size)))
        waitUntil("the session") { mac.attached != nil }
        let id = mac.attached!.id
        waitUntil("its output", timeout: 20) { mac.text(id).contains("15000") }

        let phone = connect("phone")
        phone.connection.send(.attach(session: id, size: size))
        // Written right away, while the screen is being written out.
        mac.type("written meanwhile\r", in: id)
        waitUntil("the screen and what came after it", timeout: 20) { phone.text(id).contains("written meanwhile") }
        let text = phone.text(id)
        let screen = try? XCTUnwrap(text.range(of: "15000", options: .backwards))
        let after = try? XCTUnwrap(text.range(of: "written meanwhile"))
        if let screen, let after { XCTAssertLessThan(screen.lowerBound, after.lowerBound, "what the session wrote came before its screen") }
        // Where the phone's terminal is counts all of it, as the host does.
        let from = phone.messages.compactMap { if case .replaying(id, let from, _) = $0 { return from } else { return nil } }.last
        XCTAssertNotNil(from)
        mac.connection.send(.kill(session: id))
    }

    func testAnEmulatorAnsweringDoesNotTakeTheSessionAway() {
        // `cat -v` shows what reaches the program, with ESC as "^[".
        let phone = connect("phone")
        let phoneSize = TermSize(cols: 48, rows: 30)
        phone.connection.send(.create(CreateRequest(command: "stty -echo; exec cat -v", size: phoneSize)))
        waitUntil("attached") { phone.attached != nil }
        let id = phone.attached!.id
        let mac = connect("mac")
        mac.connection.send(.attach(session: id, size: TermSize(cols: 120, rows: 40)))
        waitUntil("mac watches") { mac.lastResize?.driver == false && mac.lastResize?.size == phoneSize }

        // The Mac's emulator answers a cursor position query. It is not the
        // client in use, so its answer is dropped and the size stays.
        mac.connection.sendInput(Data("\u{1b}[40;120R".utf8), to: id)
        // The phone's emulator answers too, and its answer goes through.
        phone.connection.sendInput(Data("\u{1b}[30;48R".utf8), to: id)
        phone.type("\n", in: id)
        waitUntil("the phone's answer arrived") { phone.text(id).contains("^[[30;48R") }
        XCTAssertFalse(phone.text(id).contains("40;120R"), "the watching emulator's answer must not reach the program")
        XCTAssertEqual(mac.lastResize?.driver, false)
        XCTAssertEqual(phone.lastResize?.size, phoneSize)

        // A real key on the Mac still takes over.
        mac.type("x\n", in: id)
        waitUntil("mac drives") { mac.lastResize?.driver == true }
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
        // The end of the replay is marked, and the replay comes before the
        // mark: a client tells by it which output not to answer.
        waitUntil("replay marked") { second.messages.contains(.replayed(session: id)) }
        XCTAssertTrue(second.text(id).contains("marker-42"), "the replay had not arrived when it was marked as over")
        // The one that started the session is told too, with nothing to replay.
        XCTAssertTrue(first.messages.contains(.replayed(session: id)))
        second.connection.send(.kill(session: id))
    }

    func testAScreenWithManyLinesAboveItArrivesWholeInPieces() throws {
        // A client that attaches is sent the screen and the lines above it,
        // of which the host keeps the 10,000 newest.
        let host = HostServer(configuration: .init(port: 0, token: token, listenOnTailscale: false))
        let hostPort = try host.start()
        defer { host.stop() }
        let first = TestClient(port: hostPort, token: token, name: "first")
        waitUntil("welcome") { first.welcomed }
        // 20,000 numbered lines of 60 characters: twice what is kept.
        first.connection.send(.create(CreateRequest(command: "seq -f 'line-%06g-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx' 1 20000; echo the-end; exec cat")))
        waitUntil("attached") { first.attached != nil }
        let id = try XCTUnwrap(first.attached?.id)
        waitUntil("all written", timeout: 30) { first.text(id).contains("the-end") }

        let late = TestClient(port: hostPort, token: token, name: "late")
        waitUntil("welcome") { late.welcomed }
        var pieces = 0
        late.connection.onOutput = { [weak late] session, data in
            pieces += 1
            late?.output[session, default: Data()].append(data)
        }
        late.connection.send(.attach(session: id, size: .default))
        waitUntil("replay marked", timeout: 30) { late.messages.contains(.replayed(session: id)) }
        let replay = late.text(id)
        XCTAssertGreaterThan(pieces, 1, "more than one message's worth came in one piece")
        XCTAssertGreaterThanOrEqual(replay.utf8.count, 500_000, "most of what is kept was not replayed")
        XCTAssertTrue(replay.contains("the-end"), "the newest output is not in it")
        XCTAssertFalse(replay.contains("line-000001-"), "the oldest output should have been dropped")
        // No line is lost or torn where two pieces meet.
        let numbers = replay.components(separatedBy: "line-").dropFirst().compactMap { Int($0.prefix(6)) }
        XCTAssertEqual(numbers.last, 20000)
        XCTAssertGreaterThanOrEqual(numbers.count, 9_900)
        XCTAssertEqual(numbers, Array((numbers.first ?? 0)...20000))
        first.connection.send(.kill(session: id))
    }

    func testAClientThatComesBackIsSentOnlyWhatItMissed() throws {
        let first = connect("first")
        first.connection.send(.create(CreateRequest(command: "cat", cwd: "/tmp")))
        waitUntil("attached") { first.attached != nil }
        let id = first.attached!.id
        first.type("before-the-drop\n", in: id)
        waitUntil("echoed") { first.text(id).contains("before-the-drop\r\nbefore-the-drop") }

        func start(_ client: TestClient) -> Int? {
            client.messages.compactMap { if case .replaying(id, let from, _) = $0 { return from } else { return nil } }.last
        }
        // A phone opens the session: its screen, and where that ends up in
        // the session's output, which is where the session is now.
        let phone = connect("phone")
        phone.connection.send(.attach(session: id, size: .default))
        waitUntil("replayed") { phone.messages.contains(.replayed(session: id)) }
        let from = try XCTUnwrap(start(phone))
        let began = try XCTUnwrap(start(first), "the one that started the session was not told where its output starts")
        let seen = phone.output[id]?.count ?? 0
        XCTAssertTrue(phone.text(id).contains("before-the-drop"))
        XCTAssertEqual(from + seen, began + (first.output[id]?.count ?? 0), "the end of the screen is not where the session is")
        // Its connection goes, and the session writes on meanwhile.
        phone.connection.close()
        waitUntil("gone") { phone.isClosed }
        first.type("while-it-was-away\n", in: id)
        waitUntil("echoed") { first.text(id).contains("while-it-was-away\r\nwhile-it-was-away") }

        // Back, saying how far its terminal is: only what came since.
        let back = connect("phone")
        back.connection.send(.attach(session: id, size: .default, have: from + seen))
        waitUntil("replayed") { back.messages.contains(.replayed(session: id)) }
        XCTAssertEqual(start(back), from + seen)
        XCTAssertEqual(back.text(id), "while-it-was-away\r\nwhile-it-was-away\r\n")

        // A place that is not one of this session's, as after the host was
        // restarted: the screen again, and the client is told so.
        let now = began + (first.output[id]?.count ?? 0)
        for place in [began - 1, now + 1_000_000, 0] {
            let lost = connect("lost")
            lost.connection.send(.attach(session: id, size: .default, have: place))
            waitUntil("replayed") { lost.messages.contains(.replayed(session: id)) }
            XCTAssertNotEqual(start(lost), place)
            XCTAssertEqual((start(lost) ?? 0) + (lost.output[id]?.count ?? 0), now)
            XCTAssertTrue(lost.text(id).contains("before-the-drop"))
            XCTAssertTrue(lost.text(id).contains("while-it-was-away"))
            lost.connection.close()
        }
        first.connection.send(.kill(session: id))
    }

    func testAConnectionThatWentDeadIsNoticedAndALiveOneIsKept() throws {
        // A host that takes the connection and then says nothing more, not
        // even an answer to a ping: what a phone has after its network changed.
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = false
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        let silent = try NWListener(using: parameters, on: .any)
        var held: [NWConnection] = []
        silent.newConnectionHandler = { connection in
            held.append(connection)
            connection.start(queue: .main)
        }
        silent.start(queue: .main)
        defer {
            silent.cancel()
            held.forEach { $0.cancel() }
        }
        waitUntil("listening") { (silent.port?.rawValue ?? 0) != 0 }

        let dead = TestClient(port: try XCTUnwrap(silent.port?.rawValue), token: token, name: "dead")
        let alive = connect("alive")
        waitUntil("connected to the silent host") { dead.state == .connected }
        let started = Date()
        waitUntil("given up on", timeout: 25) { dead.isClosed }
        XCTAssertEqual(dead.state, .closed(reason: "The connection to the Mac was lost."))
        XCTAssertGreaterThan(Date().timeIntervalSince(started), 5, "a quiet host is asked before it is given up on")
        // The real host, which answers, was asked the same and is still there.
        XCTAssertFalse(alive.isClosed)
        alive.connection.check()
        alive.connection.send(.list)
        let before = alive.messages.count
        waitUntil("still answering") { alive.messages.count > before }
    }

    func testAgentListReportsWhatIsInstalled() {
        let client = connect()
        client.connection.send(.agents(refresh: false))
        waitUntil("agents") { client.messages.contains { if case .agents = $0 { return true } else { return false } } }
        guard case .agents(let agents)? = client.messages.last(where: { if case .agents = $0 { return true } else { return false } }) else { return XCTFail() }
        XCTAssertEqual(agents.filter(\.isInstalled).map(\.id), ["claude"])
    }

    func testFolderListIsSharedBetweenClients() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-folder-\(UUID().uuidString)")
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

    func testTheArrangementOfTabsIsSharedAndSaved() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-tabs-\(UUID().uuidString)/folders.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        func layouts(_ client: TestClient) -> [TabLayout] {
            client.messages.compactMap { if case .tabLayout(let layout) = $0 { return layout } else { return nil } }
        }
        var layout = TabLayout()
        layout.sync(with: ["s:1:10", "s:2:20", "f:/a.md"])
        layout.setPinned("s:2:20", true)
        layout.newGroup(with: "s:1:10", name: "api")
        do {
            let host = HostServer(configuration: .init(port: 0, token: token, listenOnTailscale: false, foldersFile: file))
            let hostPort = try host.start()
            defer { host.stop() }
            let mac = TestClient(port: hostPort, token: token, name: "mac")
            let phone = TestClient(port: hostPort, token: token, name: "phone")
            waitUntil("both get the empty arrangement") { layouts(mac) == [TabLayout()] && layouts(phone) == [TabLayout()] }
            mac.connection.send(.setTabLayout(layout))
            waitUntil("the phone gets the Mac's") { layouts(phone).last == layout }
            XCTAssertEqual(layouts(mac).count, 1, "it is not sent back to the one who set it")
        }
        // The host was stopped and started again.
        let again = HostServer(configuration: .init(port: 0, token: token, listenOnTailscale: false, foldersFile: file))
        let againPort = try again.start()
        defer { again.stop() }
        let late = TestClient(port: againPort, token: token, name: "late")
        waitUntil("kept") { layouts(late).last == layout }
    }

    func testTheMacIsKeptAwakeOnlyWhileASessionRunsAndTheSettingIsOn() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-awake-\(UUID().uuidString)/folders.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        func awake(_ client: TestClient) -> Bool? {
            client.messages.compactMap { if case .keepAwake(let on) = $0 { return on } else { return nil } }.last
        }
        do {
            let host = HostServer(configuration: .init(port: 0, token: token, listenOnTailscale: false, foldersFile: file))
            let hostPort = try host.start()
            defer { host.stop() }
            let mac = TestClient(port: hostPort, token: token, name: "mac")
            let phone = TestClient(port: hostPort, token: token, name: "phone")
            waitUntil("off to begin with") { awake(mac) == false && awake(phone) == false }
            // Switched on from the phone: the Mac's window hears of it, but
            // with no session there is nothing to stay awake for.
            phone.connection.send(.setKeepAwake(true))
            waitUntil("both know") { awake(mac) == true && awake(phone) == true }
            XCTAssertFalse(host.isKeepingAwake)
            mac.connection.send(.create(CreateRequest(command: "sleep 30", cwd: nil, title: nil, size: .default)))
            waitUntil("awake with a session") { host.isKeepingAwake }
            let id = try XCTUnwrap(mac.attached?.id)
            mac.connection.send(.kill(session: id))
            waitUntil("asleep again without one") { !host.isKeepingAwake }
        }
        // The setting is kept across a restart of the host.
        let again = HostServer(configuration: .init(port: 0, token: token, listenOnTailscale: false, foldersFile: file))
        let againPort = try again.start()
        defer { again.stop() }
        let late = TestClient(port: againPort, token: token, name: "late")
        waitUntil("kept") { awake(late) == true }
    }

    func testFoldersCanBePutInAnotherOrder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-order-\(UUID().uuidString)").standardizedFileURL
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ["a", "b", "c"].map { root.appendingPathComponent($0).path }
        for path in paths { try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true) }
        func folders(_ client: TestClient) -> [String]? {
            client.messages.compactMap { if case .folders(let list) = $0 { return list } else { return nil } }.last
        }
        let mac = connect("mac")
        let phone = connect("phone")
        for path in paths { mac.connection.send(.addFolder(path: path)) }
        waitUntil("listed") { folders(phone) == paths }
        // Dropped before another, by either client; everyone sees the order.
        phone.connection.send(.moveFolder(path: paths[2], before: paths[0]))
        waitUntil("c first") { folders(mac) == [paths[2], paths[0], paths[1]] }
        mac.connection.send(.moveFolder(path: paths[2], before: nil))
        waitUntil("c last again") { folders(phone) == paths }
        // Nothing happens for a folder that is not listed, or one moved before itself.
        mac.connection.send(.moveFolder(path: root.path, before: paths[0]))
        mac.connection.send(.moveFolder(path: paths[0], before: paths[0]))
        mac.connection.send(.moveFolder(path: paths[0], before: paths[1]))
        mac.connection.send(.moveFolder(path: paths[1], before: paths[0]))
        waitUntil("b first") { folders(phone) == [paths[1], paths[0], paths[2]] }
    }

    func testFolderListIsSavedToDisk() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-folders-\(UUID().uuidString).json")
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

    // MARK: Changes, history and folders for a remote client

    private func git(_ arguments: String..., in directory: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path, "-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false"] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    func testAClientCanReadAFoldersChanges() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-e2e-git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        git("init", "-q", "-b", "main", in: directory)
        try "one\n".write(to: directory.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        git("add", ".", in: directory)
        git("commit", "-q", "-m", "init", in: directory)
        try "one\ntwo\n".write(to: directory.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "mới\n".write(to: directory.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)

        let phone = connect("phone")
        phone.connection.send(.diff(path: directory.path))
        var snapshot: DiffSnapshot?
        waitUntil("changes") {
            snapshot = phone.messages.compactMap { if case .diff(directory.path, let s) = $0 { return s } else { return nil } }.last
            return snapshot != nil
        }
        XCTAssertEqual(snapshot?.branch, "main")
        XCTAssertEqual(snapshot?.files.map(\.path), ["a.txt", "b.txt"])
        XCTAssertEqual(snapshot?.files.map(\.added), [1, 1])
        XCTAssertEqual(snapshot?.files.map(\.patch), ["", ""], "the list does not carry the diffs")

        phone.connection.send(.diffFile(path: directory.path, file: "b.txt", staged: false))
        phone.connection.send(.diffFile(path: directory.path, file: "gone.txt", staged: false))
        var files: [FileDiff?] = []
        waitUntil("one file") {
            files = phone.messages.compactMap { if case .diffFile(directory.path, let f) = $0 { return .some(f) } else { return nil } }
            return files.count == 2
        }
        XCTAssertEqual(files[0]?.patch.contains("+mới"), true)
        XCTAssertTrue(files[0]?.isUntracked == true)
        XCTAssertNil(files[1])

        phone.connection.send(.diff(path: "/"))
        waitUntil("not a repository") { phone.messages.contains(.diff(path: "/", snapshot: .notARepository)) }
    }

    func testBrowsingAndEditingFilesFromAClient() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-e2e-files-\(UUID().uuidString)").standardizedFileURL
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("src"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try "xin chào\n".write(to: directory.appendingPathComponent("ghi chú.md"), atomically: true, encoding: .utf8)
        try Data([0x89, 0x50, 0x4e, 0x47, 0, 1, 2]).write(to: directory.appendingPathComponent("a.png"))
        let root = directory.path

        let phone = connect("phone")
        /// The newest listing of a folder the phone was sent.
        func names(in folder: String) -> [String]? {
            phone.messages.compactMap { message -> [String]? in
                if case .files(folder, let entries) = message { return entries.map { $0.name + ($0.isDirectory ? "/" : "") } }
                return nil
            }.last
        }
        func content(of path: String) -> (FileContent, Data?)? {
            phone.messages.compactMap { message -> (FileContent, Data?)? in
                if case .file(path, let content, let data) = message { return (content, data) }
                return nil
            }.last
        }

        phone.connection.send(.files(path: root))
        waitUntil("listing") { names(in: root) == ["src/", "a.png", "ghi chú.md"] }

        phone.connection.send(.readFile(path: root + "/ghi chú.md"))
        waitUntil("text") { content(of: root + "/ghi chú.md")?.0 == .text("xin chào\n") }
        phone.connection.send(.readFile(path: root + "/a.png"))
        waitUntil("image") { content(of: root + "/a.png")?.1 == Data([0x89, 0x50, 0x4e, 0x47, 0, 1, 2]) }

        phone.connection.send(.writeFile(path: root + "/ghi chú.md", text: "đã sửa\n"))
        waitUntil("saved") { phone.messages.contains(.fileSaved(path: root + "/ghi chú.md")) }
        XCTAssertEqual(try String(contentsOfFile: root + "/ghi chú.md", encoding: .utf8), "đã sửa\n")

        phone.connection.send(.createFile(directory: root + "/src", name: "main.swift", isDirectory: false))
        waitUntil("created") { phone.messages.contains(.fileCreated(path: root + "/src/main.swift", isDirectory: false)) }
        waitUntil("listed") { names(in: root + "/src") == ["main.swift"] }
        phone.connection.send(.createFile(directory: root, name: "docs", isDirectory: true))
        waitUntil("folder") { names(in: root) == ["docs/", "src/", "a.png", "ghi chú.md"] }

        phone.connection.send(.renameFile(path: root + "/src/main.swift", name: "app.swift"))
        waitUntil("renamed") { names(in: root + "/src") == ["app.swift"] }

        // A name that is taken is refused and nothing is overwritten.
        phone.connection.send(.createFile(directory: root, name: "ghi chú.md", isDirectory: false))
        waitUntil("refused") {
            phone.messages.contains { if case .error(let text) = $0 { return text.contains("already exists") } else { return false } }
        }
        XCTAssertEqual(try String(contentsOfFile: root + "/ghi chú.md", encoding: .utf8), "đã sửa\n")
        // Nor can a name reach out of the folder.
        phone.connection.send(.createFile(directory: root, name: "../escape.txt", isDirectory: false))
        waitUntil("refused again") {
            phone.messages.contains { if case .error(let text) = $0 { return text.contains("cannot be used as a name") } else { return false } }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.deletingLastPathComponent().appendingPathComponent("escape.txt").path))
    }

    /// GIT-63 (#44): what a device does inside a submodule is answered
    /// with the submodule's changes, and the folder around it, asked
    /// again, says what is changed in it now, not what it kept from before.
    func testWhatIsDoneInASubmoduleShowsInTheFolderAroundIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-e2e-sub-\(UUID().uuidString)").standardizedFileURL
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("library")
        let directory = root.appendingPathComponent("project")
        for repository in [library, directory] {
            try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
            git("init", "-q", "-b", "main", in: repository)
            for (key, value) in [("user.name", "Test"), ("user.email", "test@example.com"), ("commit.gpgsign", "false")] { git("config", key, value, in: repository) }
        }
        try "one\n".write(to: library.appendingPathComponent("l.txt"), atomically: true, encoding: .utf8)
        git("add", ".", in: library)
        git("commit", "-q", "-m", "library", in: library)
        git("-c", "protocol.file.allow=always", "submodule", "add", "-q", library.path, "lib", in: directory)
        let inside = directory.appendingPathComponent("lib")
        for (key, value) in [("user.name", "Test"), ("user.email", "test@example.com"), ("commit.gpgsign", "false")] { git("config", key, value, in: inside) }
        git("commit", "-q", "-m", "project", in: directory)
        try "one\ntwo\n".write(to: inside.appendingPathComponent("l.txt"), atomically: true, encoding: .utf8)

        let phone = connect("phone")
        /// What the newest list of the folder's changes says: its own
        /// files, then each submodule's.
        func latest(_ path: String) -> [String]? {
            phone.messages.compactMap { message -> [String]? in
                guard case .diff(path, let snapshot) = message else { return nil }
                func named(_ files: [FileDiff], _ place: String) -> [String] { files.map { ($0.isStaged ? "staged " : "") + $0.marker + " " + place + $0.path } }
                return named(snapshot.files, "") + snapshot.submodules.flatMap { named($0.changes.files, $0.path + ": ") }
            }.last
        }
        phone.connection.send(.diff(path: directory.path))
        waitUntil("the folder's changes") { latest(directory.path) == ["M lib: l.txt"] }

        // Staged in the submodule; the folder says so when asked right after.
        phone.connection.send(.gitStage(path: inside.path, files: ["l.txt"]))
        waitUntil("staged in the submodule") { latest(inside.path) == ["staged M l.txt"] }
        phone.connection.send(.diff(path: directory.path))
        waitUntil("the folder says it is staged there") { latest(directory.path) == ["staged M lib: l.txt"] }

        // Committed there: the folder shows the submodule's commit as its own change.
        phone.connection.send(.gitCommit(path: inside.path, message: "library: two"))
        waitUntil("committed in the submodule") { latest(inside.path) == [] }
        phone.connection.send(.diff(path: directory.path))
        waitUntil("the commit moved") { latest(directory.path) == ["M lib"] }
        phone.connection.send(.gitStage(path: directory.path, files: ["lib"]))
        waitUntil("staged in the folder") { latest(directory.path) == ["staged M lib"] }
    }

    func testStagingAndCommittingFromAClient() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-e2e-commit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        git("init", "-q", "-b", "main", in: directory)
        git("config", "user.name", "Test", in: directory)
        git("config", "user.email", "test@example.com", in: directory)
        git("config", "commit.gpgsign", "false", in: directory)
        try "one\n".write(to: directory.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        git("add", ".", in: directory)
        git("commit", "-q", "-m", "init", in: directory)
        try "one\ntwo\n".write(to: directory.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "mới\n".write(to: directory.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)

        let phone = connect("phone")
        /// The newest list of changes the phone was sent.
        func latest() -> [String]? {
            phone.messages.compactMap { message -> [String]? in
                if case .diff(directory.path, let snapshot) = message { return snapshot.files.map { ($0.isStaged ? "staged " : "") + $0.marker + " " + $0.path } }
                return nil
            }.last
        }

        phone.connection.send(.gitStage(path: directory.path, files: ["a.txt"]))
        waitUntil("staged") { latest() == ["staged M a.txt", "U b.txt"] }

        // The staged part of the file is its own diff.
        phone.connection.send(.diffFile(path: directory.path, file: "a.txt", staged: true))
        waitUntil("staged diff") {
            phone.messages.contains { if case .diffFile(directory.path, let file?) = $0 { return file.isStaged && file.patch.contains("+two") } else { return false } }
        }

        phone.connection.send(.gitUnstage(path: directory.path, files: []))
        waitUntil("unstaged") { latest() == ["M a.txt", "U b.txt"] }

        // Nothing staged: git refuses, the phone is told why, nothing is committed.
        phone.connection.send(.gitCommit(path: directory.path, message: "nothing yet"))
        waitUntil("refused") {
            phone.messages.contains { if case .error(let text) = $0 { return text.lowercased().contains("no changes added") || text.lowercased().contains("nothing") } else { return false } }
        }

        phone.connection.send(.gitStage(path: directory.path, files: []))
        waitUntil("all staged") { latest() == ["staged M a.txt", "staged A b.txt"] }
        phone.connection.send(.gitCommit(path: directory.path, message: "feat: thêm dòng"))
        waitUntil("committed") { latest() == [] }

        let log = Process()
        let pipe = Pipe()
        log.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        log.arguments = ["-C", directory.path, "log", "--format=%s"]
        log.standardOutput = pipe
        try log.run()
        log.waitUntilExit()
        XCTAssertEqual(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), "feat: thêm dòng\ninit\n")
    }

    /// GIT-20 (#39): a device discards changes through the host: one file,
    /// then every change; what git does not track goes to the Trash, and
    /// the device is sent the list as it is then.
    func testAClientDiscardsChanges() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-e2e-discard-\(UUID().uuidString)").standardizedFileURL
        let trash = directory.appendingPathComponent(".trash-of-the-test")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        setenv(FileBrowser.trashVariable, trash.path, 1)
        defer {
            unsetenv(FileBrowser.trashVariable)
            try? FileManager.default.removeItem(at: directory)
        }
        git("init", "-q", "-b", "main", in: directory)
        git("config", "user.name", "Test", in: directory)
        git("config", "user.email", "test@example.com", in: directory)
        git("config", "commit.gpgsign", "false", in: directory)
        try ".trash-of-the-test\n".write(to: directory.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try "one\n".write(to: directory.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "one\n".write(to: directory.appendingPathComponent("c.txt"), atomically: true, encoding: .utf8)
        git("add", ".", in: directory)
        git("commit", "-q", "-m", "init", in: directory)
        try "one\ntwo\n".write(to: directory.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "changed\n".write(to: directory.appendingPathComponent("c.txt"), atomically: true, encoding: .utf8)
        try "mới\n".write(to: directory.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)

        let phone = connect("phone")
        func latest() -> [String]? {
            phone.messages.compactMap { message -> [String]? in
                if case .diff(directory.path, let snapshot) = message { return snapshot.files.map { $0.marker + " " + $0.path } }
                return nil
            }.last
        }
        phone.connection.send(.diff(path: directory.path))
        waitUntil("the changes") { latest() == ["M a.txt", "M c.txt", "U b.txt"] }

        phone.connection.send(.gitDiscard(path: directory.path, files: ["a.txt"]))
        waitUntil("one discarded") { latest() == ["M c.txt", "U b.txt"] }
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("a.txt"), encoding: .utf8), "one\n")

        phone.connection.send(.gitDiscard(path: directory.path, files: []))
        waitUntil("all discarded") { latest() == [] }
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("c.txt"), encoding: .utf8), "one\n")
        XCTAssertEqual(try String(contentsOf: trash.appendingPathComponent("b.txt"), encoding: .utf8), "mới\n", "in the Trash, not gone")

        // Nothing left: said, and the list is sent all the same.
        phone.connection.send(.gitDiscard(path: directory.path, files: []))
        waitUntil("told there is nothing") {
            phone.messages.contains { if case .error(let text) = $0 { return text == "There is no change to discard." } else { return false } }
        }
    }

    /// GIT-26 (#35): a device lists the branches, makes one, switches, is
    /// refused a switch that would lose a change, and deletes a branch;
    /// each change is answered with the branches and the folder's changes.
    func testAClientWorksWithBranches() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-e2e-branches-\(UUID().uuidString)").standardizedFileURL
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        git("init", "-q", "-b", "main", in: directory)
        git("config", "user.name", "Test", in: directory)
        git("config", "user.email", "test@example.com", in: directory)
        git("config", "commit.gpgsign", "false", in: directory)
        try "one\n".write(to: directory.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        git("add", ".", in: directory)
        git("commit", "-q", "-m", "init", in: directory)

        let phone = connect("phone")
        func branches() -> [String]? {
            phone.messages.compactMap { message -> [String]? in
                if case .gitBranches(directory.path, let list) = message { return list.map { ($0.isCurrent ? "* " : "") + $0.name } }
                return nil
            }.last
        }
        func branch() -> String? {
            phone.messages.compactMap { message -> String? in
                if case .diff(directory.path, let snapshot) = message { return snapshot.branch } else { return nil }
            }.last
        }
        phone.connection.send(.gitBranches(path: directory.path))
        waitUntil("the branches") { branches() == ["* main"] }

        phone.connection.send(.gitCreateBranch(path: directory.path, name: "feature/x", from: nil, checkout: true))
        waitUntil("made and checked out") { branches() == ["* feature/x", "main"] && branch() == "feature/x" }
        try "one\non the feature\n".write(to: directory.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        git("commit", "-q", "-am", "feat: on the feature", in: directory)

        phone.connection.send(.gitSwitch(path: directory.path, branch: "main"))
        waitUntil("switched") { branch() == "main" }

        // A change that the switch would lose: refused, in words.
        try "mine\n".write(to: directory.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        phone.connection.send(.gitSwitch(path: directory.path, branch: "feature/x"))
        waitUntil("refused") {
            phone.messages.contains { if case .error(let text) = $0 { return text.hasPrefix("Switching to feature/x would lose changes") } else { return false } }
        }
        XCTAssertEqual(branch(), "main")
        git("checkout", "-q", "--", "a.txt", in: directory)

        // Not merged: kept unless forced.
        phone.connection.send(.gitDeleteBranch(path: directory.path, name: "feature/x", force: false))
        waitUntil("kept") {
            phone.messages.contains { if case .error(let text) = $0 { return text.contains("not fully merged") } else { return false } }
        }
        phone.connection.send(.gitRenameBranch(path: directory.path, from: "feature/x", to: "feature/y"))
        waitUntil("renamed") { branches() == ["* main", "feature/y"] }
        phone.connection.send(.gitDeleteBranch(path: directory.path, name: "feature/y", force: true))
        waitUntil("deleted") { branches() == ["* main"] }
    }

    /// GIT-40 (#36): a device reads the history a page at a time, what a
    /// commit changed, and reverts one; a commit that is not there is said
    /// to be so.
    func testAClientReadsTheHistoryAndRevertsACommit() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-e2e-history-\(UUID().uuidString)").standardizedFileURL
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        git("init", "-q", "-b", "main", in: directory)
        git("config", "user.name", "Test", in: directory)
        git("config", "user.email", "test@example.com", in: directory)
        git("config", "commit.gpgsign", "false", in: directory)
        for number in 1...3 {
            try String(repeating: "line\n", count: number).write(to: directory.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
            git("add", ".", in: directory)
            git("commit", "-q", "-m", "change \(number)", in: directory)
        }

        let phone = connect("phone")
        func pages() -> [(skip: Int, subjects: [String], more: Bool)] {
            phone.messages.compactMap { message in
                if case .gitLog(directory.path, nil, let skip, let commits, let more) = message { return (skip, commits.map(\.subject), more) }
                return nil
            }
        }
        phone.connection.send(.gitLog(path: directory.path, branch: nil, skip: 0, limit: 2))
        waitUntil("the first page") { pages().count == 1 }
        XCTAssertEqual(pages()[0].subjects, ["change 3", "change 2"])
        XCTAssertTrue(pages()[0].more)
        phone.connection.send(.gitLog(path: directory.path, branch: nil, skip: 2, limit: 2))
        waitUntil("the second page") { pages().count == 2 }
        XCTAssertEqual(pages()[1].subjects, ["change 1"])
        XCTAssertFalse(pages()[1].more)

        let newest = try XCTUnwrap(
            phone.messages.compactMap { message -> CommitInfo? in
                if case .gitLog(_, _, 0, let commits, _) = message { return commits.first } else { return nil }
            }.first)
        phone.connection.send(.gitShow(path: directory.path, hash: newest.hash))
        waitUntil("what it changed") {
            phone.messages.contains {
                if case .gitShow(_, newest.hash, let details?) = $0 { return details.files.map(\.path) == ["a.txt"] && details.files[0].patch.contains("+line") }
                return false
            }
        }
        phone.connection.send(.gitShow(path: directory.path, hash: "0000000"))
        waitUntil("none such") { phone.messages.contains { if case .gitShow(_, "0000000", nil) = $0 { return true } else { return false } } }

        phone.connection.send(.gitRevert(path: directory.path, hash: newest.hash))
        waitUntil("reverted") { phone.messages.contains { if case .gitSynced(directory.path) = $0 { return true } else { return false } } }
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("a.txt"), encoding: .utf8), "line\nline\n")
    }

    func testAClientCanBrowseFolders() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-e2e-dirs-\(UUID().uuidString)").standardizedFileURL
        for name in ["beta", "Alpha", "alpha 2", ".hidden"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try "x".write(to: root.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let phone = connect("phone")
        phone.connection.send(.listDirectory(path: root.path))
        var listing: DirectoryListing?
        waitUntil("listing") {
            listing = phone.messages.compactMap { if case .directory(let l) = $0 { return l } else { return nil } }.last
            return listing != nil
        }
        XCTAssertEqual(listing?.path, root.path)
        XCTAssertEqual(listing?.folders, ["Alpha", "alpha 2", "beta"], "folders only, hidden ones left out, sorted")
        XCTAssertEqual(listing?.parent, root.deletingLastPathComponent().path)
        XCTAssertEqual(listing?.isHome, false)

        phone.connection.send(.listDirectory(path: "/nonexistent/place"))
        waitUntil("refused") { phone.messages.contains(.error("cannot open that folder")) }

        // A session can then be started in any folder that was found.
        phone.connection.send(.create(CreateRequest(command: "pwd -P", cwd: root.appendingPathComponent("alpha 2").path)))
        waitUntil("attached") { phone.attached != nil }
        waitUntil("ran there") { phone.text(phone.attached!.id).contains("/alpha 2") }
    }

    func testAClientCanReadHistoryAndOnlyResumeRealConversations() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-e2e-home-\(UUID().uuidString)")
        let project = "/Users/me/Dev/app"
        let folder = home.appendingPathComponent(".claude/projects/-Users-me-Dev-app")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try #"{"type":"user","cwd":"/Users/me/Dev/app","message":{"role":"user","content":"viết test"}}"#
            .write(to: folder.appendingPathComponent("c-1.jsonl"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: home) }
        let withHome = HostServer(configuration: .init(port: 0, token: token, listenOnTailscale: false, home: home.path))
        let homePort = try withHome.start()
        defer { withHome.stop() }

        let phone = TestClient(port: homePort, token: token, name: "phone")
        waitUntil("welcome") { phone.welcomed }
        phone.connection.send(.history(path: project))
        phone.connection.send(.history(path: nil))
        phone.connection.send(.history(path: "/Users/me/Dev/other"))
        func history(_ path: String?) -> [Conversation]? {
            phone.messages.compactMap { if case .history(path, let c) = $0 { return c } else { return nil } }.last
        }
        waitUntil("history") { history(project) != nil && history(nil) != nil && history("/Users/me/Dev/other") != nil }
        XCTAssertEqual(history(project)?.map(\.title), ["viết test"])
        XCTAssertEqual(history(project)?.first?.resumeCommand, "claude --resume c-1")
        XCTAssertEqual(history(nil)?.map(\.sessionID), ["c-1"])
        XCTAssertEqual(history("/Users/me/Dev/other"), [])

        // Ids that could break out of the command line, and agents the host
        // does not know, are refused before anything is started.
        phone.connection.send(.resume(agent: "claude", sessionID: "x; touch /tmp/pwned", cwd: "/tmp", size: .default))
        phone.connection.send(.resume(agent: "vim", sessionID: "c-1", cwd: "/tmp", size: .default))
        waitUntil("refused twice") { phone.messages.filter { $0 == .error("cannot resume that conversation") }.count == 2 }
        // The prompt can be asked for first, to show it.
        phone.connection.send(.handoffPlan(agent: "claude"))
        phone.connection.send(.handoffPlan(agent: "vim"))
        var plan: (id: String, prompt: String)?
        waitUntil("plan") {
            plan = phone.messages.compactMap { if case .handoffPlan(let id, let prompt) = $0 { return (id, prompt) } else { return nil } }.last
            return plan != nil && phone.messages.contains(.error("cannot hand off from that agent"))
        }
        XCTAssertTrue(plan!.prompt.hasPrefix("You are taking over a task from Claude Code in this folder. Read .agentterm/handoffs/"))
        XCTAssertTrue(plan!.prompt.contains("-from-claude.md first"))

        phone.connection.send(.handoff(agent: "claude", sessionID: "no-such", cwd: project, target: "codex", plan: plan!.id, prompt: nil, note: "", size: .default, folder: nil))
        waitUntil("unknown conversation") { phone.messages.contains(.error("That conversation is no longer on this Mac.")) }
        XCTAssertEqual(withHome.sessionCount, 0)
    }

    // MARK: 0.4.0: push and pull, commit messages, resources, keep awake options, SSH hosts

    private func state(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-\(name)-\(UUID().uuidString)").standardizedFileURL
    }

    func testPushingAndPullingFromAClient() throws {
        let root = state("e2e-sync")
        defer { try? FileManager.default.removeItem(at: root) }
        let remote = root.appendingPathComponent("remote.git"), mine = root.appendingPathComponent("mine"), theirs = root.appendingPathComponent("theirs")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        git("init", "-q", "--bare", "-b", "main", remote.path, in: root)
        for clone in [mine, theirs] {
            git("clone", "-q", remote.path, clone.path, in: root)
            git("config", "user.name", "Test", in: clone)
            git("config", "user.email", "test@example.com", in: clone)
            git("config", "commit.gpgsign", "false", in: clone)
            git("config", "pull.rebase", "false", in: clone)
            git("checkout", "-q", "-B", "main", in: clone)
        }
        try "one\n".write(to: mine.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        git("add", ".", in: mine)
        git("commit", "-q", "-m", "init", in: mine)
        git("push", "-q", "-u", "origin", "main", in: mine)
        git("checkout", "-q", "-b", "work", in: mine)
        try "work\n".write(to: mine.appendingPathComponent("w.txt"), atomically: true, encoding: .utf8)
        git("add", ".", in: mine)
        git("commit", "-q", "-m", "work", in: mine)

        let phone = connect("phone")
        func latest(_ folder: URL) -> DiffSnapshot? {
            phone.messages.compactMap { if case .diff(folder.path, let snapshot) = $0 { return snapshot } else { return nil } }.last
        }
        // The first push of a branch: the changes say where it would go.
        phone.connection.send(.diff(path: mine.path))
        waitUntil("no upstream yet") { latest(mine)?.pushRemote == "origin" && latest(mine)?.upstream == nil }
        phone.connection.send(.gitPush(path: mine.path))
        waitUntil("pushed, and following") { latest(mine)?.upstream == "origin/work" && latest(mine)?.ahead == 0 && latest(mine)?.pushRemote == nil }

        // The other clone had nothing; pulling brings the first commit in.
        phone.connection.send(.gitPull(path: theirs.path))
        waitUntil("pulled") { FileManager.default.fileExists(atPath: theirs.appendingPathComponent("a.txt").path) && latest(theirs)?.behind == 0 }

        // A push git refuses is answered with git's words, then the changes.
        try "two\n".write(to: theirs.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        git("add", ".", in: theirs)
        git("commit", "-q", "-m", "theirs", in: theirs)
        git("push", "-q", in: theirs)
        git("checkout", "-q", "main", in: mine)
        try "mine\n".write(to: mine.appendingPathComponent("c.txt"), atomically: true, encoding: .utf8)
        git("add", ".", in: mine)
        git("commit", "-q", "-m", "mine", in: mine)
        phone.connection.send(.gitPush(path: mine.path))
        waitUntil("refused") {
            phone.messages.contains { if case .error(let text) = $0 { return text.contains("rejected") || text.contains("fetch first") } else { return false } }
        }
        waitUntil("still ahead") { latest(mine)?.upstream == "origin/main" && latest(mine)?.ahead == 1 }
    }

    /// SIZE-8 and NOTE-7: a phone that was used keeps the session at its
    /// size when it goes, and no one is at the Mac, its app in front
    /// notwithstanding, until the Mac app is used; typing in the session
    /// on the Mac takes the size back.
    func testAPhoneThatWasUsedKeepsTheSessionAndTheMacUntilTheMacIsUsed() throws {
        var configuration = HostServer.Configuration(port: 0, token: token, listenOnTailscale: false, detectAgents: { [] })
        configuration.refreshInterval = 0.3
        // Someone is at the keyboard all along.
        configuration.idleSeconds = { 1 }
        let host = HostServer(configuration: configuration)
        let hostPort = try host.start()
        defer { host.stop() }
        func inUse(_ client: TestClient) -> Bool? { client.messages.compactMap { if case .macInUse(let on) = $0 { return on } else { return nil } }.last }

        let mac = TestClient(port: hostPort, token: token, name: "mac")
        waitUntil("the Mac app") { mac.welcomed }
        mac.connection.send(.appInFront(true))
        mac.connection.send(.createPairingCode)
        waitUntil("a code") { mac.pairingCode != nil }
        let phone = TestClient(port: hostPort, credential: .pairingCode(mac.pairingCode!), name: "iPhone")
        waitUntil("paired") { phone.pairedToken != nil && phone.welcomed }
        waitUntil("someone at the Mac") { inUse(mac) == true }

        let macSize = TermSize(cols: 120, rows: 40), phoneSize = TermSize(cols: 48, rows: 30)
        mac.connection.send(.create(CreateRequest(command: "exec sleep 600", cwd: NSTemporaryDirectory(), title: "work", size: macSize)))
        waitUntil("the session") { mac.attached != nil }
        let id = try XCTUnwrap(mac.attached?.id)
        phone.connection.send(.attach(session: id, size: phoneSize))
        phone.connection.send(.takeControl(session: id, size: phoneSize))
        waitUntil("the phone's size") { mac.lastResize?.size == phoneSize && mac.lastResize?.driver == false }
        waitUntil("no one at the Mac, its app in front notwithstanding") { inUse(mac) == false }

        // The phone goes: the session stays at its size, and no one is at the Mac.
        phone.connection.close()
        waitUntil("the phone gone") { phone.isClosed }
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        XCTAssertEqual(mac.lastResize?.size, phoneSize)
        XCTAssertEqual(mac.lastResize?.driver, false)
        XCTAssertEqual(inUse(mac), false)

        // The Mac app used: someone is at the Mac; the session keeps the phone's size.
        mac.connection.send(.used)
        waitUntil("someone at the Mac again") { inUse(mac) == true }
        XCTAssertEqual(mac.lastResize?.size, phoneSize)
        // Typing in the session there takes it back.
        mac.type("x", in: id)
        waitUntil("the Mac's size") { mac.lastResize?.size == macSize && mac.lastResize?.driver == true }
    }

    func testStartingAtLoginIsSwitchedFromAnyClient() throws {
        let root = state("e2e-login")
        defer { try? FileManager.default.removeItem(at: root) }
        let item = LoginItem(
            label: "com.example.host", file: root.appendingPathComponent("LaunchAgents/com.example.host.plist"), executable: "/bin/agenttermd",
            arguments: ["--port", "1"], log: root.appendingPathComponent("host.log"))
        // A host that cannot be started at login says nothing about it.
        let plain = connect("plain")
        XCTAssertFalse(plain.messages.contains { if case .startAtLogin = $0 { return true } else { return false } })

        var configuration = HostServer.Configuration(port: 0, token: token, listenOnTailscale: false, detectAgents: { [] })
        configuration.loginItem = item
        configuration.refreshInterval = 0.3
        let host = HostServer(configuration: configuration)
        let hostPort = try host.start()
        defer { host.stop() }
        func latest(_ client: TestClient) -> Bool? {
            client.messages.compactMap { if case .startAtLogin(let on) = $0 { return on } else { return nil } }.last
        }
        let mac = TestClient(port: hostPort, token: token, name: "mac")
        let phone = TestClient(port: hostPort, token: token, name: "phone")
        waitUntil("told it is off") { latest(mac) == false && latest(phone) == false }
        phone.connection.send(.setStartAtLogin(true))
        waitUntil("on, for both") { latest(mac) == true && latest(phone) == true }
        XCTAssertTrue(item.isOn)
        mac.connection.send(.setStartAtLogin(false))
        waitUntil("off, for both") { latest(mac) == false && latest(phone) == false }
        XCTAssertFalse(item.isOn)

        // SET-3: turned on or off outside AgentTerm, as by removing the
        // launch agent, both are told without asking.
        phone.connection.send(.setStartAtLogin(true))
        waitUntil("on again") { latest(mac) == true && latest(phone) == true }
        try FileManager.default.removeItem(at: item.file)
        waitUntil("told it is off, from outside") { latest(mac) == false && latest(phone) == false }
    }

    func testTheEndOfAPushIsSaidApartFromTheChanges() throws {
        let root = state("e2e-synced")
        defer { try? FileManager.default.removeItem(at: root) }
        let remote = root.appendingPathComponent("remote.git"), mine = root.appendingPathComponent("mine")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        git("init", "-q", "--bare", "-b", "main", remote.path, in: root)
        git("clone", "-q", remote.path, mine.path, in: root)
        git("config", "user.name", "Test", in: mine)
        git("config", "user.email", "test@example.com", in: mine)
        git("config", "commit.gpgsign", "false", in: mine)
        git("checkout", "-q", "-B", "main", in: mine)
        try "one\n".write(to: mine.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        git("add", ".", in: mine)
        git("commit", "-q", "-m", "init", in: mine)
        // A push that takes a while, as one over a network does.
        let hook = mine.appendingPathComponent(".git/hooks/pre-push")
        try "#!/bin/sh\nsleep 3\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)

        let phone = connect("phone")
        func count(_ match: (ServerMessage) -> Bool) -> Int { phone.messages.filter(match).count }
        let isDiff: (ServerMessage) -> Bool = { if case .diff(mine.path, _) = $0 { return true } else { return false } }
        phone.connection.send(.gitPush(path: mine.path))
        // The phone looks at the folder again while git is still pushing.
        // That answer comes first, and is not the end of the push.
        phone.connection.send(.diff(path: mine.path))
        waitUntil("the changes asked for meanwhile") { count(isDiff) == 1 }
        XCTAssertFalse(phone.messages.contains(.gitSynced(path: mine.path)), "the push was said to be over while git was still at it")
        waitUntil("the end of the push") { phone.messages.contains(.gitSynced(path: mine.path)) }
        XCTAssertEqual(count(isDiff), 2)
        XCTAssertEqual(phone.messages.last, .gitSynced(path: mine.path))
        // A stage or a commit ends with its changes, as before.
        phone.connection.send(.gitStage(path: mine.path, files: ["a.txt"]))
        waitUntil("the changes after staging") { count(isDiff) == 3 }
        XCTAssertEqual(count { $0 == .gitSynced(path: mine.path) }, 1)
    }

    func testAnAgentWritesTheCommitMessageAndTheSettingsAreSharedAndSaved() throws {
        let root = state("e2e-writer")
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        git("init", "-q", "-b", "main", in: project)
        try "one\n".write(to: project.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        git("add", ".", in: project)

        // Stand-ins for two agents: one answers, one never does.
        let received = root.appendingPathComponent("received.txt")
        func fake(_ name: String, _ script: String) throws -> String {
            let file = root.appendingPathComponent(name)
            try ("#!/bin/sh\n" + script + "\n").write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
            return file.path
        }
        let quick = try fake("fake-claude", "cat > '\(received.path)'\necho 'feat: add a file'")
        let slow = try fake("fake-codex", "exec sleep 60")
        let file = root.appendingPathComponent("state/folders.json")
        let configuration = HostServer.Configuration(
            port: 0, token: token, listenOnTailscale: false,
            detectAgents: { [AgentInfo(id: "claude", name: "Claude Code", path: quick), AgentInfo(id: "codex", name: "Codex", path: slow)] },
            foldersFile: file)
        func settings(_ client: TestClient) -> CommitWriterSettings? {
            client.messages.compactMap { if case .commitWriter(let settings) = $0 { return settings } else { return nil } }.last
        }
        func answers(_ client: TestClient) -> [String?] {
            client.messages.compactMap { if case .commitMessage(project.path, let message) = $0 { return .some(message) } else { return nil } }
        }
        do {
            let host = HostServer(configuration: configuration)
            let hostPort = try host.start()
            defer { host.stop() }
            let mac = TestClient(port: hostPort, token: token, name: "mac")
            let phone = TestClient(port: hostPort, token: token, name: "phone")
            waitUntil("defaults") { settings(mac) == CommitWriterSettings() && settings(phone) == CommitWriterSettings() }

            phone.connection.send(.writeCommitMessage(path: project.path))
            waitUntil("written", timeout: 30) { answers(phone) == ["feat: add a file"] }
            XCTAssertEqual(answers(mac), [], "only the one who asked is answered")
            XCTAssertTrue(try String(contentsOf: received, encoding: .utf8).hasPrefix("Write a git commit message"))

            // Changed on the Mac: the phone hears of it. An agent the host
            // does not know, and blank fields, are not kept.
            mac.connection.send(.setCommitWriter(CommitWriterSettings(agent: "codex", model: "  ", prompt: "Viết bằng tiếng Việt.")))
            let wanted = CommitWriterSettings(agent: "codex", model: nil, prompt: "Viết bằng tiếng Việt.")
            waitUntil("shared") { settings(phone) == wanted }

            // The agent that never answers is stopped on request, without an error.
            phone.connection.send(.writeCommitMessage(path: project.path))
            RunLoop.main.run(until: Date().addingTimeInterval(1.5))
            phone.connection.send(.cancelCommitMessage(path: project.path))
            waitUntil("stopped", timeout: 30) { answers(phone) == ["feat: add a file", nil] }
            XCTAssertFalse(phone.messages.contains { if case .error = $0 { return true } else { return false } })

            // Nothing staged: said in words, and answered with no message.
            git("commit", "-q", "-m", "init", in: project)
            mac.connection.send(.setCommitWriter(CommitWriterSettings(agent: "nonsense")))
            waitUntil("unknown agent dropped") { settings(phone) == CommitWriterSettings() }
            phone.connection.send(.writeCommitMessage(path: project.path))
            waitUntil("nothing staged", timeout: 30) {
                phone.messages.contains { if case .error(let text) = $0 { return text.contains("Stage the changes") } else { return false } }
                    && answers(phone).count == 3
            }
            mac.connection.send(.setCommitWriter(wanted))
            waitUntil("set again") { settings(phone) == wanted }

            // SET-2: asked for what the host keeps already once it is
            // tidied, the asker is told what the host keeps, rather than
            // left with its untidy copy.
            func told(_ client: TestClient) -> Int { client.messages.filter { if case .commitWriter = $0 { return true } else { return false } }.count }
            let before = told(mac)
            mac.connection.send(.setCommitWriter(CommitWriterSettings(agent: "codex", model: "  ", prompt: "Viết bằng tiếng Việt.")))
            waitUntil("the asker told") { told(mac) > before }
            XCTAssertEqual(settings(mac), wanted)
        }
        let again = HostServer(configuration: configuration)
        let againPort = try again.start()
        defer { again.stop() }
        let late = TestClient(port: againPort, token: token, name: "late")
        waitUntil("kept") { settings(late) == CommitWriterSettings(agent: "codex", model: nil, prompt: "Viết bằng tiếng Việt.") }
    }

    func testEveryClientIsToldHowTheMacIsDoing() throws {
        var configuration = HostServer.Configuration(port: 0, token: token, listenOnTailscale: false)
        configuration.refreshInterval = 0.4
        let host = HostServer(configuration: configuration)
        let hostPort = try host.start()
        defer { host.stop() }
        let phone = TestClient(port: hostPort, token: token, name: "phone")
        func stats(_ client: TestClient) -> [SystemStats] {
            client.messages.compactMap { if case .systemStats(let stats) = $0 { return stats } else { return nil } }
        }
        // No session is needed: it is the Mac that is measured.
        waitUntil("measured") { (stats(phone).last?.memoryTotal ?? 0) > 0 }
        XCTAssertLessThanOrEqual(stats(phone).last?.cpuPercent ?? 101, 100)
        // A client that connects later is told at once what is known.
        let late = TestClient(port: hostPort, token: token, name: "mac")
        waitUntil("told on connecting") { !stats(late).isEmpty }
    }

    func testHowThingsAreShownIsTheSameOnEveryDevice() throws {
        let file = state("display").appendingPathComponent("folders.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let configuration = HostServer.Configuration(port: 0, token: token, listenOnTailscale: false, foldersFile: file)
        func display(_ client: TestClient) -> [DisplaySettings?] {
            client.messages.compactMap { if case .displaySettings(let settings) = $0 { return .some(settings) } else { return nil } }
        }
        let fahrenheit = DisplaySettings(temperatureUnit: SystemStats.fahrenheit, diffLayout: "split", changesView: "tree")
        do {
            let host = HostServer(configuration: configuration)
            let hostPort = try host.start()
            defer { host.stop() }
            // A host that keeps none yet says so, and takes the first client's.
            let mac = TestClient(port: hostPort, token: token, name: "mac")
            waitUntil("none yet") { display(mac) == [nil] }
            mac.connection.send(.setDisplaySettings(DisplaySettings()))
            let phone = TestClient(port: hostPort, token: token, name: "phone")
            waitUntil("the phone gets the Mac's") { display(phone) == [DisplaySettings()] }
            // Changed on the phone: the Mac follows. The sender is not told again.
            phone.connection.send(.setDisplaySettings(fahrenheit))
            waitUntil("the Mac follows") { display(mac).last == .some(fahrenheit) }
            XCTAssertEqual(display(phone).count, 1)
            // And the other way round. A value nobody knows is not kept.
            mac.connection.send(.setDisplaySettings(DisplaySettings(temperatureUnit: "kelvin", diffLayout: "split", changesView: "list")))
            waitUntil("the phone follows") {
                display(phone).last == .some(DisplaySettings(temperatureUnit: SystemStats.celsius, diffLayout: "split", changesView: "list"))
            }
            mac.connection.send(.setDisplaySettings(fahrenheit))
            waitUntil("set again") { display(phone).last == .some(fahrenheit) }
        }
        let again = HostServer(configuration: configuration)
        let againPort = try again.start()
        defer { again.stop() }
        let late = TestClient(port: againPort, token: token, name: "late")
        waitUntil("kept") { display(late) == [fahrenheit] }
    }

    func testKeepAwakeOptionsAreSharedSavedAndFollowed() throws {
        let file = state("awake-options").appendingPathComponent("folders.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        var onPower = false
        var configuration = HostServer.Configuration(port: 0, token: token, listenOnTailscale: false, foldersFile: file)
        configuration.isOnPower = { onPower }
        configuration.refreshInterval = 0.3
        func options(_ client: TestClient) -> KeepAwakeOptions? {
            client.messages.compactMap { if case .keepAwakeOptions(let options) = $0 { return options } else { return nil } }.last
        }
        func awake(_ client: TestClient) -> Bool? {
            client.messages.compactMap { if case .keepAwake(let on) = $0 { return on } else { return nil } }.last
        }
        do {
            let host = HostServer(configuration: configuration)
            let hostPort = try host.start()
            defer { host.stop() }
            let mac = TestClient(port: hostPort, token: token, name: "mac")
            let phone = TestClient(port: hostPort, token: token, name: "phone")
            waitUntil("defaults") { options(mac) == KeepAwakeOptions() && options(phone) == KeepAwakeOptions() }
            mac.connection.send(.create(CreateRequest(command: "sleep 60", cwd: nil, title: nil, size: .default)))
            waitUntil("a session") { mac.attached != nil }

            // Only on power, and the Mac is on battery: no hold.
            phone.connection.send(.setKeepAwakeOptions(KeepAwakeOptions(display: true, onlyOnPower: true, until: Date.distantFuture)))
            waitUntil("shared, and when it ends is the host's to say") { options(mac) == KeepAwakeOptions(display: true, onlyOnPower: true) }
            mac.connection.send(.setKeepAwake(true))
            waitUntil("on") { awake(phone) == true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            XCTAssertFalse(host.isKeepingAwake, "on battery")
            // Plugged in: noticed by itself, and the display is kept on too.
            onPower = true
            waitUntil("held on power") { host.isKeepingAwake && host.isKeepingDisplayAwake }
            mac.connection.send(.setKeepAwakeOptions(KeepAwakeOptions(display: false, onlyOnPower: true)))
            waitUntil("the display may sleep again") { host.isKeepingAwake && !host.isKeepingDisplayAwake }

            // A length given while it is on counts from now.
            let before = Date()
            phone.connection.send(.setKeepAwakeOptions(KeepAwakeOptions(onlyOnPower: false, minutes: 60)))
            waitUntil("timed") { options(mac)?.until != nil }
            let until = try XCTUnwrap(options(mac)?.until)
            XCTAssertEqual(until.timeIntervalSince(before), 3600, accuracy: 30)
            // Switched off: the time goes with it. Switched on: it starts over.
            mac.connection.send(.setKeepAwake(false))
            waitUntil("off") { awake(phone) == false && options(phone)?.until == nil && !host.isKeepingAwake }
            XCTAssertEqual(options(phone)?.minutes, 60)
            mac.connection.send(.setKeepAwake(true))
            waitUntil("on for an hour") { awake(phone) == true && options(phone)?.until != nil && host.isKeepingAwake }
        }
        // Kept across a restart, the time it ends included.
        do {
            let again = HostServer(configuration: configuration)
            let againPort = try again.start()
            defer { again.stop() }
            let late = TestClient(port: againPort, token: token, name: "late")
            waitUntil("kept") { awake(late) == true && options(late)?.minutes == 60 && options(late)?.until != nil }
        }
        // A hold whose time is up lets go by itself and says so.
        let settings = file.deletingLastPathComponent().appendingPathComponent("settings.json")
        let soon = Date().addingTimeInterval(2).timeIntervalSince1970
        try #"{"keepAwake":true,"keepAwakeOptions":{"display":false,"onlyOnPower":false,"minutes":60,"until":\#(soon)}}"#
            .write(to: settings, atomically: true, encoding: .utf8)
        let timed = HostServer(configuration: configuration)
        let timedPort = try timed.start()
        defer { timed.stop() }
        let watcher = TestClient(port: timedPort, token: token, name: "watcher")
        waitUntil("on") { awake(watcher) == true }
        watcher.connection.send(.create(CreateRequest(command: "sleep 60", cwd: nil, title: nil, size: .default)))
        waitUntil("held") { timed.isKeepingAwake }
        waitUntil("time is up") { awake(watcher) == false && !timed.isKeepingAwake && options(watcher)?.until == nil }
    }

    func testSettingsOfAnEarlierVersionStillRead() throws {
        let file = state("awake-old").appendingPathComponent("folders.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"keepAwake":true}"#.write(to: file.deletingLastPathComponent().appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        let host = HostServer(configuration: .init(port: 0, token: token, listenOnTailscale: false, foldersFile: file))
        let hostPort = try host.start()
        defer { host.stop() }
        let client = TestClient(port: hostPort, token: token, name: "mac")
        waitUntil("on, with no options set") {
            client.messages.contains(.keepAwake(true)) && client.messages.contains(.keepAwakeOptions(KeepAwakeOptions()))
        }
    }

    func testSSHHostsAreListedAndOnlyThoseCanBeOpened() throws {
        let home = state("e2e-ssh")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
        try "Host build\n  HostName 127.0.0.1\n  IdentityFile ~/.ssh/secret-key\nHost *.internal\nHost web-1\n"
            .write(to: home.appendingPathComponent(".ssh/config"), atomically: true, encoding: .utf8)
        var configuration = HostServer.Configuration(port: 0, token: token, listenOnTailscale: false)
        configuration.sshHome = home.path
        let host = HostServer(configuration: configuration)
        let hostPort = try host.start()
        defer { host.stop() }
        let phone = TestClient(port: hostPort, token: token, name: "phone")
        waitUntil("welcome") { phone.welcomed }

        phone.connection.send(.sshHosts)
        waitUntil("only the names") { phone.messages.contains(.sshHosts(["build", "web-1"])) }

        for name in ["elsewhere", "-oProxyCommand=touch${IFS}/tmp/pwned", "build; id"] {
            phone.connection.send(.connectSSH(host: name, size: .default))
        }
        waitUntil("refused") {
            phone.messages.filter { if case .error(let text) = $0 { return text.contains("is not a host in this Mac's SSH configuration") } else { return false } }.count == 3
        }
        XCTAssertEqual(host.sessionCount, 0)

        phone.connection.send(.connectSSH(host: "web-1", size: TermSize(cols: 60, rows: 20)))
        waitUntil("a session of its own") { phone.attached != nil }
        XCTAssertEqual(phone.attached?.title, "web-1")
        XCTAssertNil(phone.attached?.agent)
        phone.connection.send(.kill(session: try XCTUnwrap(phone.attached?.id)))
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
