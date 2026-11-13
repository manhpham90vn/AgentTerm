import AgentTermClient
import AgentTermProtocol
import XCTest

@testable import AgentTermHost

/// What the agent in a session is doing, from what it tells its hooks (#3).
///
/// What each agent tells its hooks was recorded on 2026-11-13 by starting
/// each with hooks that only wrote it down: Claude Code 2.1.323, Copilot
/// CLI 1.0.110, Antigravity 1.5.7. Codex 0.167.2 runs no hook until the
/// user trusts it, so its events are as its documentation describes them.
/// Paths and identifiers are left out of what is kept here.
final class AgentStateTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 1_800_000_000)

    private func change(_ agent: String, _ event: String, _ json: String) -> AgentHooks.Change {
        let input = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
        return AgentHooks.change(agent: agent, event: event, input: input, now: at)
    }

    // MARK: - Each agent, from what it really says

    /// AGENT-1: Claude Code.
    func testClaudeCode() {
        XCTAssertEqual(
            change("claude", "UserPromptSubmit", #"{"hook_event_name":"UserPromptSubmit","prompt":"Run touch probe2.txt","permission_mode":"default"}"#),
            .set(.working(since: at)))
        let ask =
            #"{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which colour do you prefer: red or blue?","header":"Colour","options":[{"label":"Red","description":"Choose red"},{"label":"Blue","description":"Choose blue"}],"multiSelect":false}]}}"#
        let question = AgentState.waitingForAnswer(AgentQuestion(text: "Which colour do you prefer: red or blue?", choices: ["Red", "Blue"]))
        XCTAssertEqual(change("claude", "PreToolUse", ask), .set(question))
        XCTAssertEqual(change("claude", "PermissionRequest", ask.replacingOccurrences(of: "PreToolUse", with: "PermissionRequest")), .set(question))
        XCTAssertEqual(
            change("claude", "PreToolUse", #"{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"touch probe2.txt"}}"#),
            .set(.working(since: at)))
        XCTAssertEqual(
            change(
                "claude", "PermissionRequest",
                #"{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"touch probe2.txt","description":"Create empty file"},"permission_suggestions":[{"type":"setMode","mode":"acceptEdits","destination":"session"}]}"#
            ),
            .set(.waitingForPermission(AgentQuestion(text: "touch probe2.txt"))))
        XCTAssertEqual(
            change("claude", "Notification", #"{"hook_event_name":"Notification","message":"Claude needs your permission","notification_type":"permission_prompt"}"#),
            .keep, "the permission was told already")
        XCTAssertEqual(change("claude", "PostToolUse", #"{"hook_event_name":"PostToolUse","tool_name":"Bash"}"#), .set(.working(since: at)))
        XCTAssertEqual(
            change("claude", "Stop", #"{"hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"You picked red, and I ran touch probe2.txt."}"#),
            .set(.done(said: "You picked red, and I ran touch probe2.txt.")))
    }

    /// AGENT-2: Copilot CLI, which names the event only in the command.
    func testCopilotCLI() {
        XCTAssertEqual(change("copilot", "userPromptSubmitted", #"{"prompt":"Ask me which colour"}"#), .set(.working(since: at)))
        XCTAssertEqual(
            change(
                "copilot", "preToolUse",
                #"{"toolName":"ask_user","toolArgs":{"message":"Which colour do you choose?","requestedSchema":{"properties":{"colour":{"type":"string","title":"Colour","enum":["red","blue"]}}}}}"#
            ),
            .set(.waitingForAnswer(AgentQuestion(text: "Which colour do you choose?", choices: ["red", "blue"]))))
        XCTAssertEqual(change("copilot", "preToolUse", #"{"toolName":"bash","toolArgs":{"command":"touch probe.txt"}}"#), .set(.working(since: at)))
        XCTAssertEqual(
            change("copilot", "permissionRequest", #"{"hookName":"permissionRequest","toolName":"bash","toolInput":{"command":"touch probe.txt"},"permissionSuggestions":[]}"#),
            .set(.waitingForPermission(AgentQuestion(text: "touch probe.txt"))))
        XCTAssertEqual(change("copilot", "postToolUse", #"{"toolName":"bash"}"#), .set(.working(since: at)))
        XCTAssertEqual(change("copilot", "agentStop", #"{"stopReason":"end_turn","stop_hook_active":false}"#), .set(.done(said: nil)))
    }

    /// AGENT-3: Antigravity, which says nothing while it waits for
    /// permission: while a tool runs, its state is not known.
    func testAntigravity() {
        XCTAssertEqual(change("agy", "PreInvocation", #"{"hookEventName":"PreInvocation","invocationNum":0}"#), .set(.working(since: at)))
        XCTAssertEqual(
            change(
                "agy", "PreToolUse",
                #"{"hookEventName":"PreToolUse","toolCall":{"name":"ask_question","args":{"questions":[{"is_multi_select":false,"options":["(Recommended) Red","Blue"],"question":"Which colour do you choose?"}]}}}"#
            ),
            .set(.waitingForAnswer(AgentQuestion(text: "Which colour do you choose?", choices: ["(Recommended) Red", "Blue"]))))
        XCTAssertEqual(
            change("agy", "PreToolUse", #"{"hookEventName":"PreToolUse","toolCall":{"name":"run_command","args":{"CommandLine":"touch probe.txt"}}}"#),
            .set(nil), "running or waiting for permission: not known")
        XCTAssertEqual(change("agy", "PostToolUse", #"{"hookEventName":"PostToolUse","error":""}"#), .set(.working(since: at)))
        XCTAssertEqual(change("agy", "Stop", #"{"hookEventName":"Stop","fullyIdle":false,"terminationReason":"NO_TOOL_CALL"}"#), .keep)
        XCTAssertEqual(change("agy", "Stop", #"{"hookEventName":"Stop","fullyIdle":true,"terminationReason":"NO_TOOL_CALL"}"#), .set(.done(said: nil)))
        XCTAssertEqual(AgentHooks.reply(agent: "agy", event: "PreToolUse"), #"{"decision":"allow"}"#, "leaves the decision to its own rules")
        XCTAssertNil(AgentHooks.reply(agent: "claude", event: "PreToolUse"))
    }

    /// AGENT-4: Codex, as its documentation describes its hooks.
    func testCodex() {
        XCTAssertEqual(change("codex", "UserPromptSubmit", #"{"hook_event_name":"UserPromptSubmit","prompt":"x"}"#), .set(.working(since: at)))
        XCTAssertEqual(
            change(
                "codex", "PermissionRequest",
                #"{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"touch probe.txt","description":"Create the probe file"}}"#),
            .set(.waitingForPermission(AgentQuestion(text: "Create the probe file"))))
        XCTAssertEqual(change("codex", "Stop", #"{"hook_event_name":"Stop","last_assistant_message":"Done."}"#), .set(.done(said: "Done.")))
        XCTAssertEqual(change("codex", "Interrupt", #"{"hook_event_name":"Interrupt"}"#), .set(nil))
    }

    // MARK: - What each agent is given

    /// The command a hook runs is the same for every session, so that
    /// Codex, which trusts a hook by its command, asks once.
    func testEachAgentIsGivenHooksThatAreTheSameForEverySession() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-hooks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".gemini/antigravity-cli"), withIntermediateDirectories: true)
        try #"{"trustedWorkspaces":["/Users/someone/work"],"model":"x"}"#.write(
            to: home.appendingPathComponent(".gemini/antigravity-cli/settings.json"), atomically: true, encoding: .utf8)
        let tool = "/Apps/My App's/agenttermd"
        let hooks = root.appendingPathComponent("hooks")

        func words(_ arguments: String) -> [String] {
            let result = Subprocess.run("/bin/sh", ["-c", "printf '%s\\n' x" + arguments])
            return String(decoding: result?.output ?? Data(), as: UTF8.self).split(separator: "\n").map(String.init).dropFirst().map { $0 }
        }

        // Claude Code: one --settings, with the status line and the hooks.
        let claude = words(try AgentHooks.launchArguments(agent: "claude", tool: tool, usageFile: "/tmp/s 1.json", directory: nil, home: home.path))
        XCTAssertEqual(claude.first, "--settings")
        let settings = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(claude[1].utf8)) as? [String: Any])
        XCTAssertNotNil(settings["statusLine"])
        let stop = try XCTUnwrap(((settings["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])
        XCTAssertEqual(stop.first?["command"] as? String, "'/Apps/My App'\\''s/agenttermd' hook claude Stop")

        // Codex: one -c for each event, as TOML.
        let codex = words(try AgentHooks.launchArguments(agent: "codex", tool: tool, usageFile: nil, directory: nil, home: home.path))
        XCTAssertEqual(codex.filter { $0 == "-c" }.count, AgentHooks.codexEvents.count)
        XCTAssertTrue(codex.contains(#"hooks.Stop=[{hooks=[{type="command",command="'/Apps/My App'\\''s/agenttermd' hook codex Stop"}]}]"#), codex.joined(separator: "\n"))

        // Copilot CLI: a plugin of the host's.
        let copilot = words(try AgentHooks.launchArguments(agent: "copilot", tool: tool, usageFile: nil, directory: hooks, home: home.path))
        XCTAssertEqual(copilot, ["--plugin-dir", hooks.appendingPathComponent("copilot").path])
        let plugin = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: hooks.appendingPathComponent("copilot/hooks.json"))) as? [String: Any])
        XCTAssertEqual(plugin["version"] as? Int, 1)
        XCTAssertNotNil(FileManager.default.contents(atPath: hooks.appendingPathComponent("copilot/plugin.json").path))

        // Antigravity: a folder of the host's, trusted for the session next
        // to the folders the user trusts, whose settings are left as they are.
        let agy = words(try AgentHooks.launchArguments(agent: "agy", tool: tool, usageFile: nil, directory: hooks, home: home.path))
        let folder = hooks.appendingPathComponent("antigravity").path
        XCTAssertEqual(Array(agy.prefix(3)), ["--add-dir", folder, "--settings"])
        let trusted = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(agy[3].utf8)) as? [String: Any])
        XCTAssertEqual(trusted["trustedWorkspaces"] as? [String], ["/Users/someone/work", folder])
        XCTAssertNotNil(FileManager.default.contents(atPath: folder + "/.agents/hooks.json"))
        XCTAssertEqual(
            try String(contentsOf: home.appendingPathComponent(".gemini/antigravity-cli/settings.json"), encoding: .utf8),
            #"{"trustedWorkspaces":["/Users/someone/work"],"model":"x"}"#)

        // Nothing of a session is in any of it.
        for arguments in [claude, codex, copilot] { XCTAssertFalse(arguments.joined().contains("session-"), arguments.joined()) }
    }

    func testWhatMayStopATurn() {
        XCTAssertTrue(AgentHooks.mayStopATurn(Data([0x1b])))
        XCTAssertTrue(AgentHooks.mayStopATurn(Data([0x03])))
        XCTAssertFalse(AgentHooks.mayStopATurn(Data("\u{1b}[A".utf8)), "an arrow key")
        XCTAssertFalse(AgentHooks.mayStopATurn(Data("hello\r".utf8)))
    }
}

/// A host with sessions whose stand-in agents tell their hooks what real
/// ones do, through the real `agenttermd hook`.
final class AgentStateHostTests: XCTestCase {
    private final class Client {
        let connection: AgentTermConnection
        var messages: [ServerMessage] = []

        init(port: UInt16, token: String, name: String) {
            connection = AgentTermConnection(host: "127.0.0.1", port: port, credential: .token(token), clientName: name)
            connection.onMessage = { [weak self] in self?.messages.append($0) }
            connection.connect()
        }

        var sessions: [SessionInfo] { messages.compactMap { if case .sessions(let list) = $0 { return list } else { return nil } }.last ?? [] }
        /// Every state a session was told to be in, in order, one for each change.
        func states(of title: String) -> [AgentState?] {
            var seen: [AgentState?] = []
            for case .sessions(let list) in messages {
                guard let session = list.first(where: { $0.title == title }) else { continue }
                if seen.isEmpty || seen.last! != session.state { seen.append(session.state) }
            }
            return seen
        }
    }

    private var root: URL!
    private var server: HostServer!
    private var port: UInt16 = 0
    private let token = "test-token-0123456789abcdef0123456789"
    private var tool: URL { Bundle(for: AgentStateHostTests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("agenttermd") }

    override func setUpWithError() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: tool.path), "agenttermd is not built next to the tests")
        root = FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-state-\(UUID().uuidString)").standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var configuration = HostServer.Configuration(
            port: 0, token: token, listenOnTailscale: false, detectAgents: { [] }, statusLineTool: tool.path,
            usageDirectory: root.appendingPathComponent("usage"))
        configuration.hooksDirectory = root.appendingPathComponent("hooks")
        configuration.home = root.path
        server = HostServer(configuration: configuration)
        port = try server.start()
    }

    override func tearDown() {
        server?.stop()
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 10, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertTrue(condition(), "timed out waiting for: \(what)")
    }

    /// A stand-in for Claude Code, under its name: it tells its hooks, as
    /// Claude Code does, through the command its settings name, then waits
    /// for a line on its input before each next step.
    private func standIn() throws -> URL {
        let script = root.appendingPathComponent("claude")
        let hook = Handoff.shellQuote(tool.path) + " hook claude"
        try """
            #!/bin/sh
            read line; printf '%s' '{"hook_event_name":"UserPromptSubmit","prompt":"go"}' | \(hook) UserPromptSubmit
            read line; printf '%s' '{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"make test"}}' | \(hook) PermissionRequest
            read line; printf '%s' '{"hook_event_name":"PostToolUse","tool_name":"Bash"}' | \(hook) PostToolUse
            read line; printf '%s' '{"hook_event_name":"Stop","last_assistant_message":"All tests pass."}' | \(hook) Stop
            read line; printf '%s' '{"hook_event_name":"UserPromptSubmit","prompt":"again"}' | \(hook) UserPromptSubmit
            exec sleep 600
            """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    /// AGENT-5, AGENT-6, AGENT-7: each state is told when it begins, once,
    /// to every client; a client that connects later is told the state as
    /// it is; a shell has none; Escape to a working agent makes it not known.
    func testEachStateIsToldWhenItBeginsToEveryClient() throws {
        let script = try standIn()
        let mac = Client(port: port, token: token, name: "mac")
        let phone = Client(port: port, token: token, name: "phone")
        waitUntil("both connected") { !mac.messages.isEmpty && !phone.messages.isEmpty }
        mac.connection.send(.create(CreateRequest(command: script.path, cwd: root.path, title: "agent")))
        mac.connection.send(.create(CreateRequest(command: "exec sleep 600", cwd: root.path, title: "shell")))
        waitUntil("both sessions") { mac.sessions.count == 2 }
        let agent = try XCTUnwrap(mac.sessions.first { $0.title == "agent" })
        XCTAssertNil(agent.state, "not known until the agent says something")
        mac.connection.send(.attach(session: agent.id, size: TermSize(cols: 80, rows: 24)))

        /// One more line for the stand-in, and the state that follows.
        /// Working is compared by name: since when is the host's to say.
        func step(_ expected: AgentState?, _ what: String) {
            mac.connection.sendInput(Data("\n".utf8), to: agent.id)
            waitUntil(what) {
                let state = mac.sessions.first { $0.id == agent.id }?.state
                if case .working = expected { return state?.isWorking == true }
                return state == expected
            }
        }
        step(.working(since: Date()), "working")
        guard case .working(let since)? = mac.sessions.first(where: { $0.id == agent.id })?.state else { return XCTFail("not working") }
        step(.waitingForPermission(AgentQuestion(text: "make test")), "waiting for permission")
        step(.working(since: since), "working again")
        step(.done(said: "All tests pass."), "done")

        // Told once each, and the same on the other device.
        waitUntil("the phone to be told the same") { phone.states(of: "agent").count == mac.states(of: "agent").count }
        XCTAssertEqual(mac.states(of: "agent").map { $0?.name }, [nil, "working", "waiting for permission", "working", "done"])
        XCTAssertEqual(phone.states(of: "agent"), mac.states(of: "agent"))
        // A shell has no state.
        XCTAssertNil(mac.sessions.first { $0.title == "shell" }?.state)
        XCTAssertNil(mac.sessions.first { $0.title == "shell" }?.stateNote)

        // A device that connects later is told the state as it is.
        let later = Client(port: port, token: token, name: "later")
        waitUntil("the later device to be told") { later.sessions.first { $0.id == agent.id }?.state?.name == "done" }

        // Working again, then Escape: it may have stopped the turn.
        step(.working(since: Date()), "working once more")
        mac.connection.sendInput(Data([0x1b]), to: agent.id)
        waitUntil("not known after Escape") { mac.sessions.first { $0.id == agent.id }.map { $0.state == nil } ?? false }
    }

    /// AGENT-8: a Codex session says how to have its state shown, until it
    /// says something; an Antigravity session always says what it cannot.
    func testWhatIsSaidOfAnAgentWhoseStateCannotAllBeKnown() throws {
        let client = Client(port: port, token: token, name: "mac")
        waitUntil("connected") { !client.messages.isEmpty }
        for agent in ["codex", "agy"] {
            let script = root.appendingPathComponent(agent)
            try "#!/bin/sh\nexec sleep 600\n".write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            client.connection.send(.create(CreateRequest(command: script.path, cwd: root.path, title: agent)))
        }
        waitUntil("both sessions") { client.sessions.count == 2 }
        XCTAssertEqual(client.sessions.first { $0.title == "codex" }?.stateNote?.contains("Trust all and continue"), true)
        XCTAssertEqual(client.sessions.first { $0.title == "agy" }?.stateNote?.contains("does not say when it waits for permission"), true)
    }
}
