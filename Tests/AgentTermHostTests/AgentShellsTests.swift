import AgentTermClient
import AgentTermProtocol
import XCTest

@testable import AgentTermHost

/// An agent opens shells the user sees, through AgentTerm's MCP server (#10).
final class AgentShellsMCPTests: XCTestCase {
    private func call(_ server: AgentShellsMCP, _ method: String, _ params: [String: Any] = [:], id: Int = 1) -> [String: Any] {
        let line = String(decoding: try! JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method, "params": params]), as: UTF8.self)
        let reply = server.handle(line) ?? ""
        return (try? JSONSerialization.jsonObject(with: Data(reply.utf8))) as? [String: Any] ?? [:]
    }

    private func tool(_ server: AgentShellsMCP, _ name: String, _ arguments: [String: Any] = [:]) -> (text: String, failed: Bool) {
        let result = call(server, "tools/call", ["name": name, "arguments": arguments])["result"] as? [String: Any] ?? [:]
        let text = (result["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        return (text, result["isError"] as? Bool ?? true)
    }

    /// MCP-1: outside a session of AgentTerm, no tools.
    func testOutsideASessionOfAgentTermThereAreNoTools() {
        let server = AgentShellsMCP(ask: nil, version: "test")
        let initialized = call(server, "initialize", ["protocolVersion": "2025-06-18"])["result"] as? [String: Any]
        XCTAssertEqual(initialized?["protocolVersion"] as? String, "2025-06-18")
        XCTAssertNil(server.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#), "a notification is not answered")
        XCTAssertEqual(((call(server, "tools/list")["result"] as? [String: Any])?["tools"] as? [Any])?.count, 0)
        XCTAssertTrue(tool(server, "open_shell").failed)
        XCTAssertNotNil(call(server, "no/such")["error"])
    }

    /// MCP-2: each tool asks the host for what it does, and says what came of it.
    func testEachToolAsksTheHost() {
        var asked: [AgentShellRequest] = []
        let shell = SessionInfo(id: 7, title: "ssh", cwd: "/p", size: .default, createdAt: Date())
        let server = AgentShellsMCP(
            ask: { request in
                asked.append(request)
                switch request {
                case .open: return .opened(shell)
                case .list: return .shells([shell])
                case .read: return .screen("$ ls\nREADME.md")
                case .send: return .done
                case .close(let session): return session == 7 ? .done : .refused("not yours")
                }
            }, version: "test")
        XCTAssertEqual(((call(server, "tools/list")["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.count, 6)
        XCTAssertEqual(tool(server, "open_shell", ["command": "ssh build-server", "title": "build"]).text, "Opened shell 7, “ssh”, in /p.")
        XCTAssertEqual(tool(server, "list_shells").text, "7: ssh")
        XCTAssertEqual(tool(server, "read_screen", ["session": 7, "lines_above": 20]).text, "$ ls\nREADME.md")
        XCTAssertFalse(tool(server, "send_input", ["session": 7, "text": "ls", "keys": ["Return"]]).failed)
        XCTAssertTrue(tool(server, "close_shell", ["session": 8]).failed)
        XCTAssertTrue(tool(server, "read_screen").failed, "a shell's number is needed")
        XCTAssertEqual(
            asked,
            [
                .open(command: "ssh build-server", title: "build"), .list, .read(session: 7, linesAbove: 20),
                .send(session: 7, text: "ls", keys: ["Return"]), .close(session: 8),
            ])
    }

    /// MCP-3: wait returns once a text appears, or once the screen is still.
    func testWaitingForTheScreen() {
        var screens = ["$ make", "$ make\nbuilding", "$ make\nbuilding\ndone"]
        let server = AgentShellsMCP(
            ask: { _ in .screen(screens.count > 1 ? screens.removeFirst() : screens[0]) }, version: "test")
        server.pollInterval = 0.01
        let found = tool(server, "wait", ["session": 1, "until_text": "done", "timeout_seconds": 5])
        XCTAssertTrue(found.text.hasPrefix("“done” is on the screen"), found.text)
        let still = tool(server, "wait", ["session": 1, "quiet_seconds": 0.05, "timeout_seconds": 5])
        XCTAssertTrue(still.text.hasPrefix("The screen has been still"), still.text)
        let late = tool(server, "wait", ["session": 1, "until_text": "never", "timeout_seconds": 0.1])
        XCTAssertTrue(late.text.hasPrefix("Still waiting after"), late.text)
    }

    func testKeysByName() {
        XCTAssertEqual(TerminalKeys.bytes(for: "Return"), "\r")
        XCTAssertEqual(TerminalKeys.bytes(for: "Control C"), "\u{03}")
        XCTAssertEqual(TerminalKeys.bytes(for: "ctrl-d"), "\u{04}")
        XCTAssertEqual(TerminalKeys.bytes(for: "Up"), "\u{1b}[A")
        XCTAssertNil(TerminalKeys.bytes(for: "Hyper"))
    }
}

/// MCP-4: the server is installed in each agent's configuration with the
/// agent's own command, once, and removed when turned off.
final class AgentShellsInstallTests: XCTestCase {
    func testInstalledOnceInEachAgentAndRemovedWhenTurnedOff() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-mcp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var ran: [[String]] = []
        let agents = [
            AgentInfo(id: "claude", name: "Claude Code", path: "/a/claude"), AgentInfo(id: "codex", name: "Codex", path: "/a/codex"),
            AgentInfo(id: "agy", name: "Antigravity", path: nil),
        ]
        func install(_ tool: String) -> AgentShellsInstall {
            AgentShellsInstall(directory: root, tool: tool) {
                ran.append($0); return true
            }
        }
        let first = install("/Apps/AgentTerm.app/agenttermd")
        XCTAssertTrue(first.isOn, "on by default")
        first.ensure(agents: agents)
        XCTAssertEqual(
            ran,
            [
                ["/a/claude", "mcp", "add", "--scope", "user", "agentterm", "--", "/Apps/AgentTerm.app/agenttermd", "mcp"],
                ["/a/codex", "mcp", "add", "agentterm", "--", "/Apps/AgentTerm.app/agenttermd", "mcp"],
            ], "an agent that is not installed is not asked")
        ran = []
        first.ensure(agents: agents)
        XCTAssertEqual(ran, [], "installed already")

        // The app moved: the server it names is replaced.
        install("/Elsewhere/agenttermd").ensure(agents: [agents[1]])
        XCTAssertEqual(ran, [["/a/codex", "mcp", "remove", "agentterm"], ["/a/codex", "mcp", "add", "agentterm", "--", "/Elsewhere/agenttermd", "mcp"]])

        // Off: removed from both, and not installed again until turned on.
        ran = []
        let moved = install("/Elsewhere/agenttermd")
        moved.set(on: false, agents: agents)
        XCTAssertEqual(ran, [["/a/claude", "mcp", "remove", "--scope", "user", "agentterm"], ["/a/codex", "mcp", "remove", "agentterm"]])
        XCTAssertFalse(moved.isOn)
        ran = []
        moved.ensure(agents: agents)
        XCTAssertEqual(ran, [])
        moved.set(on: true, agents: agents)
        XCTAssertEqual(ran.count, 2)
    }
}

/// MCP-5 to MCP-8: stand-in agents start the real `agenttermd mcp`, as real
/// agents do, and the test speaks MCP to it through a pipe.
final class AgentShellsHostTests: XCTestCase {
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

    /// An agent's MCP server, reached through its pipes.
    private final class Agent {
        let input: FileHandle
        let output: URL
        private var next = 0

        init(input: FileHandle, output: URL) {
            self.input = input
            self.output = output
        }

        /// Calls a tool and waits for its answer.
        func tool(_ name: String, _ arguments: [String: Any] = [:], in test: AgentShellsHostTests) -> (text: String, failed: Bool) {
            next += 1
            let id = next
            let request: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": "tools/call", "params": ["name": name, "arguments": arguments]]
            do {
                try input.write(contentsOf: try JSONSerialization.data(withJSONObject: request) + Data("\n".utf8))
            } catch {
                let said = (try? String(contentsOfFile: output.path + ".err", encoding: .utf8)) ?? ""
                XCTFail("the MCP server is gone: \(error); it said: \(said)")
                return ("", true)
            }
            var answer: [String: Any]?
            test.waitUntil("the answer to \(name)", timeout: 40) {
                let text = (try? String(contentsOf: self.output, encoding: .utf8)) ?? ""
                answer = text.split(separator: "\n").compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
                    .first { ($0["id"] as? Int) == id }
                return answer != nil
            }
            let result = answer?["result"] as? [String: Any] ?? [:]
            return ((result["content"] as? [[String: Any]])?.first?["text"] as? String ?? "", result["isError"] as? Bool ?? true)
        }
    }

    private var root: URL!
    private var server: HostServer!
    private var port: UInt16 = 0
    private let token = "test-token-0123456789abcdef0123456789"
    private var tool: URL { Bundle(for: AgentShellsHostTests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("agenttermd") }
    private var stateBefore: String?

    override func setUpWithError() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: tool.path), "agenttermd is not built next to the tests")
        // A pipe whose reader is gone fails the write rather than the tests.
        signal(SIGPIPE, SIG_IGN)
        root = FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-shells-\(UUID().uuidString)").standardizedFileURL
        let state = root.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        // The MCP server signs in with the Mac's own token, which it reads
        // from the state folder: the test's, never the user's.
        try token.write(to: state.appendingPathComponent("token"), atomically: true, encoding: .utf8)
        stateBefore = ProcessInfo.processInfo.environment["AGENTTERM_STATE_DIR"]
        setenv("AGENTTERM_STATE_DIR", state.path, 1)
        server = HostServer(configuration: .init(port: 0, token: token, listenOnTailscale: false, detectAgents: { [] }))
        port = try server.start()
    }

    override func tearDown() {
        server?.stop()
        if let stateBefore { setenv("AGENTTERM_STATE_DIR", stateBefore, 1) } else { unsetenv("AGENTTERM_STATE_DIR") }
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func waitUntil(_ what: String, timeout: TimeInterval = 10, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertTrue(condition(), "timed out waiting for: \(what)")
    }

    /// Starts a stand-in agent under `name`, which starts its MCP server as
    /// a real agent does, with its session's environment.
    private func startAgent(_ name: String, title: String, client: Client) throws -> (Agent, SessionID) {
        let folder = root.appendingPathComponent(title)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let pipe = folder.appendingPathComponent("in"), output = folder.appendingPathComponent("out")
        let script = folder.appendingPathComponent(name)
        try """
        #!/bin/sh
        mkfifo '\(pipe.path)'
        exec 3<>'\(pipe.path)'
        '\(tool.path)' mcp <&3 > '\(output.path)' 2> '\(output.path).err' &
        exec sleep 600
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let before = Set(client.sessions.map(\.id))
        client.connection.send(.create(CreateRequest(command: script.path, cwd: folder.path, title: title)))
        waitUntil("the agent's session") { client.sessions.contains { !before.contains($0.id) } }
        waitUntil("its MCP server") { FileManager.default.fileExists(atPath: output.path) }
        let id = try XCTUnwrap(client.sessions.first { !before.contains($0.id) }?.id)
        return (Agent(input: try FileHandle(forWritingTo: pipe), output: output), id)
    }

    func testAnAgentOpensAShellTheUserSeesAndReachesOnlyItsOwn() throws {
        let mac = Client(port: port, token: token)
        waitUntil("connected") { !mac.messages.isEmpty }
        let (first, firstID) = try startAgent("claude", title: "first", client: mac)
        let (second, _) = try startAgent("codex", title: "second", client: mac)
        mac.connection.send(.create(CreateRequest(command: "exec sleep 600", cwd: root.path, title: "mine")))
        waitUntil("the user's session") { mac.sessions.contains { $0.title == "mine" } }
        let mine = try XCTUnwrap(mac.sessions.first { $0.title == "mine" }?.id)

        // MCP-5: it opens a shell, in its folder, marked as its own.
        let opened = first.tool("open_shell", ["command": "cat", "title": "echo"], in: self)
        XCTAssertFalse(opened.failed, opened.text)
        waitUntil("the shell to be listed") { mac.sessions.contains { $0.title == "echo" } }
        let shell = try XCTUnwrap(mac.sessions.first { $0.title == "echo" })
        XCTAssertEqual(shell.openedBy, firstID)
        XCTAssertEqual(shell.cwd, root.appendingPathComponent("first").path)
        XCTAssertEqual(first.tool("list_shells", in: self).text, "\(shell.id): echo")

        // What it types reaches the program; the screen it reads shows it.
        XCTAssertFalse(first.tool("send_input", ["session": shell.id, "text": "hello", "keys": ["Return"]], in: self).failed)
        let waited = first.tool("wait", ["session": shell.id, "until_text": "hello", "timeout_seconds": 10], in: self)
        XCTAssertTrue(waited.text.hasPrefix("“hello” is on the screen"), waited.text)
        XCTAssertTrue(first.tool("read_screen", ["session": shell.id], in: self).text.contains("hello"))

        // MCP-6: never the user's session or another agent's shell.
        XCTAssertTrue(first.tool("read_screen", ["session": mine], in: self).failed)
        XCTAssertTrue(first.tool("send_input", ["session": mine, "text": "rm -rf ~"], in: self).failed)
        XCTAssertTrue(second.tool("read_screen", ["session": shell.id], in: self).failed)
        XCTAssertTrue(second.tool("close_shell", ["session": shell.id], in: self).failed)
        XCTAssertEqual(second.tool("list_shells", in: self).text, "You have no shells open.")

        // MCP-7: starting an agent is refused.
        let agent = first.tool("open_shell", ["command": "claude --resume x"], in: self)
        XCTAssertTrue(agent.failed)
        XCTAssertTrue(agent.text.contains("Starting an agent is not allowed"), agent.text)

        // MCP-8: when the agent's session ends, its shells stay, the user's.
        mac.connection.send(.kill(session: firstID))
        waitUntil("the agent's session to end") { !mac.sessions.contains { $0.id == firstID } }
        XCTAssertTrue(mac.sessions.contains { $0.id == shell.id }, "its shell stays")
        // Its MCP server ended with it, as an agent's does.

        // Closed by the agent that opened it.
        let (third, _) = try startAgent("copilot", title: "third", client: mac)
        let other = third.tool("open_shell", in: self)
        XCTAssertFalse(other.failed, other.text)
        let otherID = try XCTUnwrap(mac.sessions.first { $0.openedBy != nil && $0.id != shell.id }?.id)
        XCTAssertFalse(third.tool("close_shell", ["session": otherID], in: self).failed)
        waitUntil("the shell to be closed", timeout: 15) { !mac.sessions.contains { $0.id == otherID } }
    }
}

/// PERF-2: a folder whose list is larger than a message could hold arrives
/// whole, in pieces.
final class LargeMessageTests: XCTestCase {
    func testAFolderOfManyEntriesIsListedWhole() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-wide-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let long = String(repeating: "n", count: 150)
        for index in 0..<25_000 { FileManager.default.createFile(atPath: root.appendingPathComponent("\(long)-\(index)").path, contents: nil) }
        let token = "test-token-0123456789abcdef0123456789"
        let server = HostServer(configuration: .init(port: 0, token: token, listenOnTailscale: false, detectAgents: { [] }))
        let port = try server.start()
        defer { server.stop() }
        let connection = AgentTermConnection(host: "127.0.0.1", port: port, credential: .token(token), clientName: "phone")
        var listed: [FileEntry]?
        connection.onMessage = { if case .files(_, let entries) = $0 { listed = entries } }
        connection.connect()
        connection.send(.files(path: root.path))
        let deadline = Date().addingTimeInterval(30)
        while listed == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertGreaterThan(MessageCoding.encode(ServerMessage.files(path: root.path, entries: listed ?? [])).count, 4 * 1024 * 1024, "larger than one message may be")
        XCTAssertEqual(listed?.count, 25_000)
    }
}
