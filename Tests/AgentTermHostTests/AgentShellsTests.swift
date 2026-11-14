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
        let another = SessionInfo(id: 9, title: "dev", cwd: "/q", size: .default, createdAt: Date())
        let server = AgentShellsMCP(
            ask: { request in
                asked.append(request)
                switch request {
                case .open: return .opened(shell)
                case .list: return .shells([shell, another], own: [7])
                case .read: return .screen("$ ls\nREADME.md")
                case .send: return .done
                case .close(let session): return session == 7 ? .done : .refused("not yours")
                }
            }, version: "test")
        XCTAssertEqual(((call(server, "tools/list")["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.count, 6)
        XCTAssertEqual(tool(server, "open_shell", ["command": "ssh build-server", "title": "build"]).text, "Opened shell 7, “ssh”, in /p.")
        XCTAssertEqual(tool(server, "list_shells").text, "7: ssh, in /p (yours)\n9: dev, in /q (another agent's: read only)")
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

    /// MCP-23 (#64): a `wait` that has not ended does not hold the server:
    /// the same agent reads a screen, types and lists its shells
    /// meanwhile, and waits on another shell too; each request is answered
    /// once, under its own id; a `wait` that is cancelled ends without an
    /// answer.
    func testAWaitDoesNotHoldUpTheOtherCalls() throws {
        let lock = NSLock()
        var asked: [String] = []
        var screens: [SessionID: String] = [1: "$ make", 2: "$ test"]
        let server = AgentShellsMCP(
            ask: { request in
                lock.lock()
                defer { lock.unlock() }
                switch request {
                case .read(let session, _):
                    return .screen(screens[session] ?? "")
                case .send(let session, let text, _):
                    asked.append("send \(session) \(text ?? "")")
                    return .done
                case .list:
                    asked.append("list")
                    return .shells([], own: [])
                default:
                    return .done
                }
            }, version: "test")
        server.pollInterval = 0.01
        var replies: [[String: Any]] = []
        func send(_ id: Any, _ tool: String, _ arguments: [String: Any]) throws {
            let line = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": "tools/call", "params": ["name": tool, "arguments": arguments]])
            server.handle(String(decoding: line, as: UTF8.self)) { reply in
                let object = (try? JSONSerialization.jsonObject(with: Data(reply.utf8))) as? [String: Any] ?? [:]
                lock.lock()
                replies.append(object)
                lock.unlock()
            }
        }
        func answered(_ id: Int) -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return replies.filter { ($0["id"] as? Int) == id }.compactMap { (($0["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String }
        }
        func waitUntil(_ what: String, _ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(5)
            while !condition() && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            XCTAssertTrue(condition(), "timed out waiting for: \(what)")
        }

        // Two waits, each for a text that is not there yet, on two shells.
        try send(1, "wait", ["session": 1, "until_text": "done", "timeout_seconds": 30])
        try send(2, "wait", ["session": 2, "until_text": "passed", "timeout_seconds": 30])
        // Meanwhile the same agent looks, types and lists: answered at once.
        try send(3, "read_screen", ["session": 1])
        try send(4, "send_input", ["session": 1, "text": "q"])
        try send(5, "list_shells", [:])
        waitUntil("the three answered while both waits go on") { answered(3).count == 1 && answered(4).count == 1 && answered(5).count == 1 }
        XCTAssertEqual(answered(3), ["$ make"])
        XCTAssertEqual(answered(1), [], "the first wait has not ended")
        XCTAssertEqual(answered(2), [])
        lock.lock()
        XCTAssertEqual(asked.sorted(), ["list", "send 1 q"])
        // The second shell says what its wait is for; the first does not yet.
        screens[2] = "$ test\npassed"
        lock.unlock()
        waitUntil("the second wait") { answered(2).count == 1 }
        XCTAssertTrue(answered(2)[0].hasPrefix("“passed” is on the screen"), answered(2)[0])
        XCTAssertEqual(answered(1), [])

        // The first is cancelled: it ends, and is not answered, whatever the screen says after.
        server.handle(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":1,"reason":"the user stopped it"}}"#) { _ in XCTFail("a notification is not answered") }
        Thread.sleep(forTimeInterval: 0.1)
        lock.lock()
        screens[1] = "$ make\ndone"
        lock.unlock()
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(answered(1), [], "a cancelled wait is not answered")
        // A wait made after it, for the same text, is: the cancelling was of that request only.
        try send(6, "wait", ["session": 1, "until_text": "done", "timeout_seconds": 30])
        waitUntil("a later wait") { answered(6).count == 1 }
        // Cancelling what is over, or was never asked, does nothing.
        server.handle(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":6}}"#) { _ in XCTFail("a notification is not answered") }
        server.handle(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"none"}}"#) { _ in XCTFail("a notification is not answered") }
        try send(7, "list_shells", [:])
        waitUntil("still answering") { answered(7).count == 1 }
        lock.lock()
        XCTAssertEqual(replies.count, 6, "each request answered once, the cancelled one not at all")
        lock.unlock()

        // What is not a tool call is answered as before, at once.
        var pinged: String?
        server.handle(#"{"jsonrpc":"2.0","id":"p","method":"ping"}"#) { pinged = $0 }
        XCTAssertEqual(pinged, #"{"id":"p","jsonrpc":"2.0","result":{}}"#)
    }

    /// MCP-14: a session's variable names the build whose host it is, and
    /// only that build's server takes it as its own.
    func testAServerTakesOnlyASessionOfItsOwnBuild() {
        let session = AgentShellsMCP.Session(port: 7718, key: "key", useShells: true)
        XCTAssertEqual(session.variable(channel: .dev), "7718 key dev use")
        XCTAssertEqual(AgentShellsMCP.Session(port: 7717, key: "key", useShells: false).variable(channel: .release), "7717 key release")
        XCTAssertEqual(AgentShellsMCP.Session(variable: "7718 key dev use", channel: .dev), session)
        XCTAssertNil(AgentShellsMCP.Session(variable: "7718 key dev use", channel: .release), "the dev build's session is not the released server's")
        XCTAssertNil(AgentShellsMCP.Session(variable: "7717 key release", channel: .dev), "nor the released build's the dev server's")
        XCTAssertEqual(AgentShellsMCP.Session(variable: "7717 key release", channel: .release)?.useShells, false)
        // From a host before the builds had a server each: the released one's.
        XCTAssertEqual(AgentShellsMCP.Session(variable: "7717 key use", channel: .release), AgentShellsMCP.Session(port: 7717, key: "key", useShells: true))
        XCTAssertNil(AgentShellsMCP.Session(variable: "7717 key use", channel: .dev))
        XCTAssertNil(AgentShellsMCP.Session(variable: nil, channel: .dev))
        XCTAssertNil(AgentShellsMCP.Session(variable: "nothing", channel: .dev))
    }

    /// MCP-14: the server and its instructions go by the build's name.
    func testTheServerGoesByItsBuildsName() {
        let server = AgentShellsMCP(ask: { _ in .done }, name: "agentterm-dev", version: "test", useShells: true)
        let initialized = call(server, "initialize")["result"] as? [String: Any]
        XCTAssertEqual((initialized?["serverInfo"] as? [String: Any])?["name"] as? String, "agentterm-dev")
        XCTAssertTrue((initialized?["instructions"] as? String ?? "").contains("the agentterm-dev MCP server"))
        XCTAssertTrue(AgentShellsInstructions.useShells(server: "agentterm").contains("the agentterm MCP server"))
        XCTAssertEqual(AppChannel.release.mcpServerName, "agentterm")
        XCTAssertEqual(AppChannel.dev.mcpServerName, "agentterm-dev")
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
            AgentShellsInstall(directory: root, tool: tool, name: "agentterm") {
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

/// MCP-19: an agent the server cannot be installed in is told to the apps,
/// which warn of it (#58), until it could be.
final class AgentShellsFaultTests: XCTestCase {
    func testAnAgentTheServerCouldNotBeInstalledInIsToldToTheApps() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-fault-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let agents = [AgentInfo(id: "claude", name: "Claude Code", path: "/a/claude"), AgentInfo(id: "codex", name: "Codex", path: "/a/codex")]
        // Codex refuses, until it is put right.
        var codexWorks = false
        let token = "test-token-0123456789abcdef0123456789"
        var configuration = HostServer.Configuration(port: 0, token: token, listenOnTailscale: false, detectAgents: { agents })
        configuration.foldersFile = root.appendingPathComponent("state/folders.json")
        configuration.agentShells = AgentShellsInstall(directory: root.appendingPathComponent("state"), tool: "/usr/bin/true", name: "agentterm") {
            $0.first != "/a/codex" || codexWorks
        }
        let server = HostServer(configuration: configuration)
        let port = try server.start()
        defer { server.stop() }
        let client = AgentTermConnection(host: "127.0.0.1", port: port, credential: .token(token), clientName: "mac")
        var told: [[AgentShellsFault]] = []
        client.onMessage = { if case .agentShellsFaults(let list) = $0 { told.append(list) } }
        client.connect()
        func spin(until condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(15)
            while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        }
        spin { told.last == [AgentShellsFault(cause: .install, agents: ["Codex"])] }
        XCTAssertEqual(told.last, [AgentShellsFault(cause: .install, agents: ["Codex"])])

        // Turned off and on, as the warning says: it is tried again.
        codexWorks = true
        client.send(.setAgentShells(false))
        client.send(.setAgentShells(true))
        spin { told.last == [] }
        XCTAssertEqual(told.last, [])
    }

    /// An agent that refuses the name because it has it already gets this
    /// build's own in its place.
    func testANameTheAgentAlreadyHasIsReplacedByThisBuildsOwn() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-fault-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var ran: [[String]] = []
        var has = true
        let install = AgentShellsInstall(directory: root, tool: "/Apps/AgentTerm.app/agenttermd", name: "agentterm") { arguments in
            ran.append(arguments)
            if arguments.contains("remove") { has = false; return true }
            return !has
        }
        let claude = AgentInfo(id: "claude", name: "Claude Code", path: "/a/claude")
        XCTAssertEqual(install.ensure(agents: [claude]), [])
        let add = ["/a/claude", "mcp", "add", "--scope", "user", "agentterm", "--", "/Apps/AgentTerm.app/agenttermd", "mcp"]
        XCTAssertEqual(ran, [add, ["/a/claude", "mcp", "remove", "--scope", "user", "agentterm"], add])
        ran = []
        XCTAssertEqual(install.ensure(agents: [claude]), [], "recorded: not asked again")
        XCTAssertEqual(ran, [])
        // One that cannot be added at all is said to have failed.
        let never = AgentShellsInstall(directory: root.appendingPathComponent("never"), tool: "/x", name: "agentterm") { _ in false }
        XCTAssertEqual(never.ensure(agents: [claude]), [claude])
    }
}

/// MCP-15: a released build and a development build each install a server
/// under a name of their own, and neither touches the other's (#57).
final class AgentShellsBuildsTests: XCTestCase {
    func testEachBuildInstallsItsOwnServerAndLeavesTheOthers() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-builds-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var ran: [[String]] = []
        let agents = [AgentInfo(id: "claude", name: "Claude Code", path: "/a/claude"), AgentInfo(id: "codex", name: "Codex", path: "/a/codex")]
        let released = AgentShellsInstall(directory: root.appendingPathComponent("AgentTerm"), tool: "/Apps/AgentTerm.app/agenttermd", name: "agentterm") {
            ran.append($0); return true
        }
        // A development build from before, which installed under the name
        // every build shared and recorded it as its own.
        let devState = root.appendingPathComponent("AgentTerm Dev")
        try FileManager.default.createDirectory(at: devState, withIntermediateDirectories: true)
        try #"{"installed":{"claude":"/dist/AgentTerm Dev.app/agenttermd","codex":"/dist/AgentTerm Dev.app/agenttermd"}}"#.write(
            to: devState.appendingPathComponent("agent-shells.json"), atomically: true, encoding: .utf8)
        func dev() -> AgentShellsInstall {
            AgentShellsInstall(directory: devState, tool: "/dist/AgentTerm Dev.app/agenttermd", name: "agentterm-dev") {
                ran.append($0); return true
            }
        }

        released.ensure(agents: agents)
        dev().ensure(agents: agents)
        XCTAssertEqual(
            ran,
            [
                ["/a/claude", "mcp", "add", "--scope", "user", "agentterm", "--", "/Apps/AgentTerm.app/agenttermd", "mcp"],
                ["/a/codex", "mcp", "add", "agentterm", "--", "/Apps/AgentTerm.app/agenttermd", "mcp"],
                ["/a/claude", "mcp", "add", "--scope", "user", "agentterm-dev", "--", "/dist/AgentTerm Dev.app/agenttermd", "mcp"],
                ["/a/codex", "mcp", "add", "agentterm-dev", "--", "/dist/AgentTerm Dev.app/agenttermd", "mcp"],
            ], "each under its own name; the shared name is not removed by the build that used to hold it")

        // Both installed: neither is asked again, whichever ran last.
        ran = []
        released.ensure(agents: agents)
        dev().ensure(agents: agents)
        XCTAssertEqual(ran, [])

        // The development build turned off removes its own only.
        dev().set(on: false, agents: agents)
        XCTAssertEqual(ran, [["/a/claude", "mcp", "remove", "--scope", "user", "agentterm-dev"], ["/a/codex", "mcp", "remove", "agentterm-dev"]])
        ran = []
        released.ensure(agents: agents)
        XCTAssertEqual(ran, [], "the released build's is still there")
    }

    /// Codex is told to pass the session's variable to this build's server.
    func testCodexPassesTheVariableToTheServerOfEachName() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-builds-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let config = root.appendingPathComponent("config.toml")
        try """
        [mcp_servers.agentterm]
        command = "/Apps/AgentTerm.app/agenttermd"
        args = ["mcp"]

        [mcp_servers.agentterm-dev]
        command = "/dist/AgentTerm Dev.app/agenttermd"
        args = ["mcp"]

        """.write(to: config, atomically: true, encoding: .utf8)
        AgentShellsInstall(directory: root.appendingPathComponent("state"), tool: "/dist/AgentTerm Dev.app/agenttermd", name: "agentterm-dev", codexConfig: config) { _ in true }
            .ensure(agents: [AgentInfo(id: "codex", name: "Codex", path: "/a/codex")])
        XCTAssertEqual(
            try String(contentsOf: config, encoding: .utf8),
            """
            [mcp_servers.agentterm]
            command = "/Apps/AgentTerm.app/agenttermd"
            args = ["mcp"]

            [mcp_servers.agentterm-dev]
            env_vars = ["AGENTTERM_MCP"]
            command = "/dist/AgentTerm Dev.app/agenttermd"
            args = ["mcp"]

            """)
    }
}

/// MCP-11: Codex gives an MCP server only the variables it is told to, and
/// without the session's the server offers no tools: it is told to.
final class AgentShellsCodexTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-codex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private var config: URL { root.appendingPathComponent("config.toml") }

    /// What `codex mcp add` writes, with the user's own settings around it.
    private let written = """
        model = "gpt-5.5"

        [mcp_servers.agentterm]
        command = "/Apps/AgentTerm.app/agenttermd"
        args = ["mcp"]

        [projects."/Users/someone/code"]
        trust_level = "trusted"

        """

    private func install(run: @escaping AgentShellsInstall.Run) -> AgentShellsInstall {
        AgentShellsInstall(directory: root.appendingPathComponent("state"), tool: "/Apps/AgentTerm.app/agenttermd", name: "agentterm", codexConfig: config, run: run)
    }

    private let codex = AgentInfo(id: "codex", name: "Codex", path: "/a/codex")

    func testCodexIsToldToGiveTheServerTheSessionsVariable() throws {
        let install = install { _ in
            try? self.written.write(to: self.config, atomically: true, encoding: .utf8)
            return true
        }
        install.ensure(agents: [codex])
        let text = try String(contentsOf: config, encoding: .utf8)
        XCTAssertEqual(
            text,
            """
            model = "gpt-5.5"

            [mcp_servers.agentterm]
            env_vars = ["AGENTTERM_MCP"]
            command = "/Apps/AgentTerm.app/agenttermd"
            args = ["mcp"]

            [projects."/Users/someone/code"]
            trust_level = "trusted"

            """)
        install.ensure(agents: [codex])
        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), text, "told once")
    }

    func testAnInstallWithoutItIsMended() throws {
        // Installed by a host from before: recorded, so not added again.
        var ran = 0
        install { _ in
            ran += 1; try? self.written.write(to: self.config, atomically: true, encoding: .utf8); return true
        }.ensure(agents: [codex])
        try written.write(to: config, atomically: true, encoding: .utf8)
        install { _ in
            ran += 1; return true
        }.ensure(agents: [codex])
        XCTAssertEqual(ran, 1)
        XCTAssertTrue(try String(contentsOf: config, encoding: .utf8).contains("env_vars = [\"AGENTTERM_MCP\"]"))
    }

    func testVariablesTheUserGaveAreKept() throws {
        let own = written.replacingOccurrences(of: "args = [\"mcp\"]", with: "args = [\"mcp\"]\nenv_vars = [\"MY_TOKEN\"]")
        install { _ in
            try? own.write(to: self.config, atomically: true, encoding: .utf8); return true
        }.ensure(agents: [codex])
        let text = try String(contentsOf: config, encoding: .utf8)
        XCTAssertTrue(text.contains("env_vars = [\"AGENTTERM_MCP\", \"MY_TOKEN\"]"), text)
        XCTAssertEqual(text.components(separatedBy: "env_vars").count, 2)
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

        /// Calls a tool and does not wait for its answer: its request's id.
        func begin(_ name: String, _ arguments: [String: Any] = [:]) throws -> Int {
            next += 1
            let request: [String: Any] = ["jsonrpc": "2.0", "id": next, "method": "tools/call", "params": ["name": name, "arguments": arguments]]
            try input.write(contentsOf: try JSONSerialization.data(withJSONObject: request) + Data("\n".utf8))
            return next
        }

        /// Says something that is not answered.
        func notify(_ method: String, _ params: [String: Any]) throws {
            try input.write(contentsOf: try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "method": method, "params": params]) + Data("\n".utf8))
        }

        /// What the server answered a request with, each time it did; the
        /// text of each answer.
        func answers(to id: Int) -> [String] {
            let text = (try? String(contentsOf: output, encoding: .utf8)) ?? ""
            return text.split(separator: "\n").compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
                .filter { ($0["id"] as? Int) == id }
                .map { ((($0["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? "" }
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

    /// Starts the real `agenttermd mcp` with `variable` as its session's,
    /// says `request` to it, and gives its answer and how long it took.
    private func said(to request: [String: Any], variable: String, state: URL? = nil) throws -> (answer: [String: Any], took: TimeInterval) {
        let process = Process()
        process.executableURL = tool
        process.arguments = ["mcp"]
        var environment = ProcessInfo.processInfo.environment
        environment[HostServer.agentShellsVariable] = variable
        if let state { environment["AGENTTERM_STATE_DIR"] = state.path }
        process.environment = environment
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        var line = request
        line["jsonrpc"] = "2.0"
        line["id"] = 1
        let started = Date()
        try process.run()
        defer { process.terminate() }
        try input.fileHandleForWriting.write(contentsOf: try JSONSerialization.data(withJSONObject: line) + Data("\n".utf8))
        // Read off the main thread, which the host under test answers on.
        var read: Data?
        DispatchQueue.global().async {
            let data = output.fileHandleForReading.availableData
            DispatchQueue.main.async { read = data }
        }
        waitUntil("the MCP server's answer", timeout: 40) { read != nil }
        let took = Date().timeIntervalSince(started)
        try input.fileHandleForWriting.close()
        let reply = try JSONSerialization.jsonObject(with: read ?? Data()) as? [String: Any]
        return (try XCTUnwrap(reply?["result"] as? [String: Any]), took)
    }

    private func toolsOffered(variable: String) throws -> Int {
        try XCTUnwrap((try said(to: ["method": "tools/list"], variable: variable).answer["tools"] as? [Any])?.count)
    }

    /// Calls `list_shells` through a server started with `variable`.
    private func listShells(variable: String, state: URL? = nil) throws -> (text: String, failed: Bool, took: TimeInterval) {
        let (result, took) = try said(to: ["method": "tools/call", "params": ["name": "list_shells", "arguments": [:]]], variable: variable, state: state)
        return ((result["content"] as? [[String: Any]])?.first?["text"] as? String ?? "", result["isError"] as? Bool ?? false, took)
    }

    /// MCP-17: an agent whose server cannot reach its host is told at once,
    /// and why, instead of waiting fifteen seconds for one fixed sentence
    /// (#58).
    func testAnAgentIsToldAtOnceThatItsHostIsNotRunning() throws {
        // A port nothing listens on: the host's own, once it has stopped.
        let gone = port
        server.stop()
        server = nil
        let told = try listShells(variable: AgentShellsMCP.Session(port: gone, key: "a-key", useShells: false).variable())
        XCTAssertTrue(told.failed)
        XCTAssertTrue(told.text.hasPrefix("AgentTerm's host is not running on port \(gone)"), told.text)
        XCTAssertLessThan(told.took, 8, "told at once, not after the fifteen seconds a silent host is given")
    }

    /// MCP-18: a server the host refuses says so to its agent, and the host
    /// tells the apps, which warn of it, until a server signs in again.
    func testAServerThatIsRefusedTellsItsAgentAndTheApps() throws {
        let mac = Client(port: port, token: token)
        waitUntil("connected") { !mac.messages.isEmpty }
        func faults() -> [AgentShellsFault]? {
            mac.messages.compactMap { if case .agentShellsFaults(let list) = $0 { return list } else { return nil } }.last
        }
        // Another copy's state folder, with a token of its own.
        let other = root.appendingPathComponent("other-state")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try "another-token-0123456789abcdef0123456789".write(to: other.appendingPathComponent("token"), atomically: true, encoding: .utf8)
        let variable = AgentShellsMCP.Session(port: port, key: "a-key", useShells: false).variable()
        let told = try listShells(variable: variable, state: other)
        XCTAssertTrue(told.failed)
        XCTAssertTrue(told.text.hasPrefix("AgentTerm's host refused this server's sign-in"), told.text)
        XCTAssertLessThan(told.took, 8)
        waitUntil("the apps to be told") { faults() == [AgentShellsFault(cause: .signIn)] }

        // A server with the host's own token: answered, and the warning goes.
        let answered = try listShells(variable: variable)
        XCTAssertEqual(answered.text, "This is not the session of an agent AgentTerm started, or that session has ended.")
        waitUntil("the warning to go") { faults() == [] }
    }

    /// MCP-16: with both builds installed, an agent has two servers of
    /// AgentTerm. The one of the session's own build offers the tools; the
    /// other build's offers none, and does not sign in to a host that is
    /// not its own (#57).
    func testInASessionOnlyItsOwnBuildsServerOffersTools() throws {
        XCTAssertEqual(try toolsOffered(variable: AgentShellsMCP.Session(port: port, key: "a-key", useShells: false).variable()), 6, "its own build's session")
        let other: AppChannel = AppChannel.current == .dev ? .release : .dev
        XCTAssertEqual(
            try toolsOffered(variable: AgentShellsMCP.Session(port: port, key: "a-key", useShells: false).variable(channel: other)), 0,
            "a session of the other build")
    }

    /// MCP-24 (#64): the real server, in an agent's session, with a `wait`
    /// going on in a shell: the agent types into that shell and reads it
    /// meanwhile, answered at once, and what it typed ends the wait; a
    /// second wait is cancelled and never answered.
    func testTheRealServerAnswersWhileAWaitGoesOn() throws {
        let mac = Client(port: port, token: token)
        waitUntil("connected") { !mac.messages.isEmpty }
        let (agent, _) = try startAgent("claude", title: "waiting", client: mac)
        let opened = agent.tool("open_shell", ["command": "cat", "title": "echo"], in: self)
        XCTAssertFalse(opened.failed, opened.text)
        waitUntil("the shell") { mac.sessions.contains { $0.title == "echo" } }
        let shell = try XCTUnwrap(mac.sessions.first { $0.title == "echo" }?.id)

        // Waits for a line nobody has typed yet.
        let waiting = try agent.begin("wait", ["session": shell, "until_text": "finished", "timeout_seconds": 60])
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(agent.answers(to: waiting), [])
        // Meanwhile: read, list, and type, each answered while the wait goes on.
        let started = Date()
        XCTAssertFalse(agent.tool("read_screen", ["session": shell], in: self).failed)
        XCTAssertTrue(agent.tool("list_shells", in: self).text.contains("echo"))
        XCTAssertFalse(agent.tool("send_input", ["session": shell, "text": "finished", "keys": ["Return"]], in: self).failed)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "not held up until the wait's minute is over")
        // What it typed is what the wait was for.
        waitUntil("the wait to end") { agent.answers(to: waiting).count == 1 }
        XCTAssertTrue(agent.answers(to: waiting)[0].hasPrefix("“finished” is on the screen"))

        // A wait that is cancelled ends without an answer; the server goes on answering.
        let dropped = try agent.begin("wait", ["session": shell, "until_text": "never typed", "timeout_seconds": 60])
        Thread.sleep(forTimeInterval: 0.3)
        try agent.notify("notifications/cancelled", ["requestId": dropped, "reason": "stopped"])
        XCTAssertFalse(agent.tool("send_input", ["session": shell, "text": "never typed", "keys": ["Return"]], in: self).failed)
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertEqual(agent.answers(to: dropped), [], "a cancelled wait is not answered, though its text came")
        XCTAssertEqual(agent.answers(to: waiting).count, 1, "answered once")
    }

    func testAnAgentOpensAShellOfItsOwnThatOtherAgentsOnlyRead() throws {
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
        XCTAssertEqual(first.tool("list_shells", in: self).text, "\(shell.id): echo, in \(shell.cwd) (yours)")
        // MCP-12: the agent's server only asks; it is not a device looking
        // at the shell. The Mac that shows it is the one whose size it takes.
        mac.connection.send(.attach(session: shell.id, size: TermSize(cols: 120, rows: 40)))
        waitUntil("the Mac told the size") {
            mac.messages.contains { if case .resized(shell.id, _, _) = $0 { return true } else { return false } }
        }
        let told = mac.messages.compactMap { message -> (TermSize, Bool)? in
            if case .resized(shell.id, let size, let driver) = message { return (size, driver) } else { return nil }
        }.last
        XCTAssertEqual(told?.1, true, "the Mac was told another device uses the shell")
        XCTAssertEqual(told?.0, TermSize(cols: 120, rows: 40))

        // What it types reaches the program; the screen it reads shows it.
        XCTAssertFalse(first.tool("send_input", ["session": shell.id, "text": "hello", "keys": ["Return"]], in: self).failed)
        let waited = first.tool("wait", ["session": shell.id, "until_text": "hello", "timeout_seconds": 10], in: self)
        XCTAssertTrue(waited.text.hasPrefix("“hello” is on the screen"), waited.text)
        XCTAssertTrue(first.tool("read_screen", ["session": shell.id], in: self).text.contains("hello"))

        // MCP-6: never the user's session, nor an agent's own.
        XCTAssertTrue(first.tool("read_screen", ["session": mine], in: self).failed)
        XCTAssertTrue(first.tool("send_input", ["session": mine, "text": "rm -rf ~"], in: self).failed)
        XCTAssertTrue(second.tool("read_screen", ["session": firstID], in: self).failed)
        // MCP-20: a shell is its agent's alone to type into and to close
        // (#61). Another agent sees whose it is, and may read it.
        XCTAssertEqual(second.tool("list_shells", in: self).text, "\(shell.id): echo, in \(shell.cwd) (another agent's: read only)")
        XCTAssertTrue(second.tool("read_screen", ["session": shell.id], in: self).text.contains("hello"))
        let typed = second.tool("send_input", ["session": shell.id, "text": "again", "keys": ["Return"]], in: self)
        XCTAssertTrue(typed.failed)
        XCTAssertTrue(typed.text.contains("opened by another agent") && typed.text.contains("open_shell"), typed.text)
        XCTAssertTrue(second.tool("close_shell", ["session": shell.id], in: self).failed)
        // Nothing of it reached the program, and the shell still runs.
        XCTAssertTrue(second.tool("wait", ["session": shell.id, "quiet_seconds": 0.5, "timeout_seconds": 5], in: self).text.contains("hello"))
        XCTAssertFalse(first.tool("read_screen", ["session": shell.id], in: self).text.contains("again"))
        XCTAssertTrue(mac.sessions.contains { $0.id == shell.id })
        // It opens one of its own instead, which the first only reads.
        XCTAssertFalse(second.tool("open_shell", ["command": "cat", "title": "other"], in: self).failed)
        waitUntil("the second's shell") { mac.sessions.contains { $0.title == "other" } }
        let other = try XCTUnwrap(mac.sessions.first { $0.title == "other" })
        XCTAssertFalse(second.tool("send_input", ["session": other.id, "text": "mine", "keys": ["Return"]], in: self).failed)
        XCTAssertTrue(first.tool("send_input", ["session": other.id, "text": "no"], in: self).failed)
        XCTAssertFalse(second.tool("close_shell", ["session": other.id], in: self).failed)
        waitUntil("the second's shell to be closed", timeout: 15) { !mac.sessions.contains { $0.id == other.id } }

        // MCP-7: starting an agent is refused.
        let agent = first.tool("open_shell", ["command": "claude --resume x"], in: self)
        XCTAssertTrue(agent.failed)
        XCTAssertTrue(agent.text.contains("Starting an agent is not allowed"), agent.text)

        // MCP-8: when the agent's session ends, its shells stay, the user's.
        mac.connection.send(.kill(session: firstID))
        waitUntil("the agent's session to end") { !mac.sessions.contains { $0.id == firstID } }
        XCTAssertTrue(mac.sessions.contains { $0.id == shell.id }, "its shell stays")
        // Its MCP server ended with it, as an agent's does.

        // It is nobody's now: every agent still reads it, none types into
        // it or closes it, and nothing takes it over. The user ends it.
        let (third, _) = try startAgent("copilot", title: "third", client: mac)
        XCTAssertEqual(third.tool("list_shells", in: self).text, "\(shell.id): echo, in \(shell.cwd) (another agent's: read only)")
        XCTAssertTrue(third.tool("read_screen", ["session": shell.id], in: self).text.contains("hello"))
        XCTAssertTrue(third.tool("send_input", ["session": shell.id, "text": "taken"], in: self).failed)
        XCTAssertTrue(second.tool("close_shell", ["session": shell.id], in: self).failed)
        XCTAssertTrue(mac.sessions.contains { $0.id == shell.id })
        XCTAssertEqual(shell.openedByName(among: mac.sessions), "an agent that has ended")
        mac.connection.send(.kill(session: shell.id))
        waitUntil("the shell to be ended by the user", timeout: 15) { !mac.sessions.contains { $0.id == shell.id } }
        XCTAssertEqual(third.tool("list_shells", in: self).text, "No agent has a shell open.")
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

/// MCP-10: the agents are asked to run their commands in shells the user
/// sees, by default, and not once the user turned it off.
final class AgentsUseShellsTests: XCTestCase {
    func testTheAgentsAreAskedToUseTheShellsUntilTurnedOff() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-use-\(UUID().uuidString)").standardizedFileURL
        defer { try? FileManager.default.removeItem(at: root) }
        let agents = root.appendingPathComponent("agents")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        let told = root.appendingPathComponent("told")
        // A stand-in for Claude Code that writes down how it was started.
        try "#!/bin/sh\nprintf '%s|%s\\n' \"$AGENTTERM_MCP\" \"$*\" >> '\(told.path)'\nexec sleep 600\n".write(
            to: agents.appendingPathComponent("claude"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: agents.appendingPathComponent("claude").path)
        let token = "test-token-0123456789abcdef0123456789"
        var configuration = HostServer.Configuration(
            port: 0, token: token, listenOnTailscale: false, detectAgents: { AgentDetector.detect(in: agents.path) }, statusLineTool: "/usr/bin/true",
            usageDirectory: root.appendingPathComponent("usage"))
        configuration.agentsDirectory = agents.path
        configuration.foldersFile = root.appendingPathComponent("state/folders.json")
        configuration.agentShells = AgentShellsInstall(directory: root.appendingPathComponent("state"), tool: "/usr/bin/true") { _ in true }
        let server = HostServer(configuration: configuration)
        let port = try server.start()
        defer { server.stop() }
        let client = AgentTermConnection(host: "127.0.0.1", port: port, credential: .token(token), clientName: "mac")
        var useShells: Bool?
        client.onMessage = { if case .agentsUseShells(let on) = $0 { useShells = on } }
        client.connect()
        func spin(until condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(15)
            while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        }
        func lines() -> [String] { ((try? String(contentsOf: told, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }
        spin { useShells != nil }
        XCTAssertEqual(useShells, true, "on by default")

        client.send(.create(CreateRequest(command: "claude", cwd: root.path)))
        spin { lines().count == 1 }
        let first = try XCTUnwrap(lines().first)
        XCTAssertTrue(first.split(separator: "|").first?.hasSuffix(" use") == true, first)
        XCTAssertTrue(first.contains("--append-system-prompt"), first)

        client.send(.setAgentsUseShells(false))
        spin { useShells == false }
        client.send(.create(CreateRequest(command: "claude", cwd: root.path)))
        spin { lines().count == 2 }
        let second = try XCTUnwrap(lines().last)
        XCTAssertFalse(second.split(separator: "|").first?.hasSuffix(" use") == true, second)
        XCTAssertFalse(second.contains("--append-system-prompt"), second)
    }

    func testTheServerSaysSoInItsInstructions() {
        func instructions(_ server: AgentShellsMCP) -> String {
            let reply = server.handle(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#) ?? ""
            let result = ((try? JSONSerialization.jsonObject(with: Data(reply.utf8))) as? [String: Any])?["result"] as? [String: Any]
            return result?["instructions"] as? String ?? ""
        }
        XCTAssertEqual(instructions(AgentShellsMCP(ask: { _ in .done }, version: "t", useShells: true)), AgentShellsInstructions.useShells)
        XCTAssertFalse(instructions(AgentShellsMCP(ask: { _ in .done }, version: "t", useShells: false)).contains("rather than with your own"))
    }
}
