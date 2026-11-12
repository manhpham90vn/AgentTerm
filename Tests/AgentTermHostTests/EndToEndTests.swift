import AgentTermClient
import AgentTermHost
import AgentTermProtocol
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

        // The phone disconnects: the Mac gets its size back.
        phone.connection.close()
        waitUntil("mac restored") { mac.lastResize?.driver == true && mac.lastResize?.size == widerMac }
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
