import AgentTermProtocol
import XCTest

@testable import AgentTermHost

/// Reading, searching and deleting the agents' conversations (#46). The
/// files are written here the way each agent wrote them on 2026-11-14.
final class AgentTranscriptTests: XCTestCase {
    private var home: URL!
    private var trash: URL!
    private let project = "/Users/me/Dev/my.app"

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-transcript-\(UUID().uuidString)").standardizedFileURL
        trash = home.appendingPathComponent("trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        // What is deleted here goes to a folder of the test's, not the user's Trash.
        setenv(FileBrowser.trashVariable, trash.path, 1)
    }

    override func tearDown() {
        unsetenv(FileBrowser.trashVariable)
        try? FileManager.default.removeItem(at: home)
    }

    private func write(_ path: String, _ lines: [String]) throws {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func claude(_ id: String, _ lines: [String]) throws -> Conversation {
        try write(".claude/projects/-Users-me-Dev-my-app/\(id).jsonl", lines)
        return try XCTUnwrap(AgentHistory.conversations(in: project, home: home.path).first { $0.sessionID == id })
    }

    private let claudeLines = [
        #"{"type":"user","timestamp":"2026-11-14T08:00:00.000Z","gitBranch":"main","message":{"role":"user","content":"fix the login bug"},"sessionId":"s1"}"#,
        #"{"type":"assistant","timestamp":"2026-11-14T08:00:05.000Z","gitBranch":"main","message":{"id":"m1","model":"claude-fable-5","role":"assistant","content":[{"type":"text","text":"I will look at the login code."}],"usage":{"input_tokens":100,"cache_read_input_tokens":900,"cache_creation_input_tokens":0,"output_tokens":20}}}"#,
        // The same message's next line: its usage is written again and is counted once.
        #"{"type":"assistant","timestamp":"2026-11-14T08:00:06.000Z","gitBranch":"feature/login","message":{"id":"m1","model":"claude-fable-5","role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"swift test --filter Login\nsecond line","description":"Run"}}],"usage":{"input_tokens":100,"cache_read_input_tokens":900,"cache_creation_input_tokens":0,"output_tokens":20}}}"#,
        #"{"type":"user","timestamp":"2026-11-14T08:00:08.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}"#,
        #"{"type":"assistant","timestamp":"2026-11-14T08:01:00.000Z","message":{"id":"m2","model":"claude-fable-5","role":"assistant","content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/Users/me/Dev/my.app/Login.swift","old_string":"a","new_string":"b"}},{"type":"tool_use","name":"Write","input":{"file_path":"/Users/me/Dev/my.app/Login.swift","content":"x"}},{"type":"text","text":"The Password check was wrong; fixed."}],"usage":{"input_tokens":50,"output_tokens":30}}}"#,
        // What another agent of its own said, and what the app asked for itself, are not the conversation.
        #"{"type":"assistant","isSidechain":true,"timestamp":"2026-11-14T08:01:30.000Z","message":{"id":"m3","role":"assistant","content":[{"type":"text","text":"a subagent's words"}]}}"#,
        #"{"type":"api-request-blob","message":{"role":"assistant","content":[{"type":"text","text":"not a line of the conversation"}]}}"#,
        #"{"type":"ai-title","aiTitle":"Fix the login bug","sessionId":"s1"}"#,
        #"{"type":"assistant","timestamp":"2026-11-14T10:05:00.000Z","message":{"id":"m4","model":"claude-fable-5","role":"assistant","content":[{"type":"text","text":"Done."}],"usage":{"input_tokens":1,"output_tokens":1}}}"#,
    ]

    /// HIST-10: a Claude Code conversation read as a transcript: what was
    /// asked and answered, each tool with what it ran on, and what the
    /// file tells: how long, the model, tokens, the branch, the files written.
    func testAClaudeConversationIsReadAsATranscript() throws {
        let details = AgentHistory.details(of: try claude("s1", claudeLines))
        XCTAssertEqual(
            details.entries.map { "\($0.kind.rawValue)\($0.tool.map { "(" + $0 + ")" } ?? ""): \($0.text)" },
            [
                "user: fix the login bug", "agent: I will look at the login code.", "tool(Bash): swift test --filter Login",
                "tool(Edit): /Users/me/Dev/my.app/Login.swift", "tool(Write): /Users/me/Dev/my.app/Login.swift", "agent: The Password check was wrong; fixed.",
                "agent: Done.",
            ])
        XCTAssertEqual(details.entries.map(\.id), Array(0..<7))
        XCTAssertEqual(details.omitted, 0)
        XCTAssertEqual(details.model, "claude-fable-5")
        XCTAssertEqual(details.inputTokens, 1000 + 50 + 1)
        XCTAssertEqual(details.outputTokens, 20 + 30 + 1)
        XCTAssertEqual(details.branch, "feature/login", "the branch it was on last")
        XCTAssertEqual(details.files, ["/Users/me/Dev/my.app/Login.swift"], "a file written twice is one file")
        XCTAssertEqual(details.tools, 3)
        XCTAssertEqual(details.duration, 2 * 3600 + 5 * 60)
        XCTAssertNil(details.cost)
        XCTAssertEqual(
            details.facts.map { "\($0.name): \($0.value)" },
            ["Ran for: 2 h 5 min", "Model: claude-fable-5", "Tokens: 1k in, 51 out", "Branch: feature/login", "Tools run: 3", "Files changed: 1"])
        let document = details.markdown(agentName: "Claude Code")
        XCTAssertTrue(document.hasPrefix("# Fix the login bug\n"))
        XCTAssertTrue(document.contains("## You\n\nfix the login bug"))
        XCTAssertTrue(document.contains("> **Bash** `swift test --filter Login`"))
        XCTAssertTrue(document.contains("- `/Users/me/Dev/my.app/Login.swift`"))
    }

    /// HIST-11: a long conversation is given by its end, and says how much
    /// is left out; one long entry is cut.
    func testALongConversationIsGivenByItsEnd() throws {
        var lines = [#"{"type":"user","message":{"role":"user","content":"count"},"sessionId":"s2"}"#]
        for index in 0..<(AgentHistory.maxEntries + 50) {
            lines.append(#"{"type":"assistant","message":{"id":"m\#(index)","role":"assistant","content":[{"type":"text","text":"line \#(index)"}]}}"#)
        }
        lines.append(#"{"type":"assistant","message":{"id":"long","role":"assistant","content":[{"type":"text","text":"\#(String(repeating: "x", count: AgentHistory.maxEntryLength + 500))"}]}}"#)
        let details = AgentHistory.details(of: try claude("s2", lines))
        XCTAssertEqual(details.entries.count, AgentHistory.maxEntries)
        XCTAssertEqual(details.omitted, 52)
        XCTAssertEqual(details.entries.first?.id, 52)
        XCTAssertEqual(details.entries.first?.text, "line 51")
        XCTAssertEqual(details.entries.last?.text.count, AgentHistory.maxEntryLength + 1)
        XCTAssertNil(details.inputTokens, "what the file does not say is not known")
        XCTAssertNil(details.model)
    }

    /// HIST-12: Codex, Copilot and Antigravity conversations read the same
    /// way, each with what its own record tells; what one does not tell
    /// is nil, not nothing.
    func testTheOtherAgentsConversationsAreRead() throws {
        try write(
            ".codex/sessions/2026/11/14/rollout-1.jsonl",
            [
                #"{"timestamp":"2026-11-14T09:00:00.000Z","type":"session_meta","payload":{"id":"c1","cwd":"/Users/me/Dev/my.app"}}"#,
                #"{"timestamp":"2026-11-14T09:00:01.000Z","type":"turn_context","payload":{"model":"gpt-5.5-codex","cwd":"/Users/me/Dev/my.app"}}"#,
                #"{"timestamp":"2026-11-14T09:00:02.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>cwd</environment_context>"}]}}"#,
                #"{"timestamp":"2026-11-14T09:00:03.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"add a test"}]}}"#,
                #"{"timestamp":"2026-11-14T09:00:04.000Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"ls Tests\ncat x","call_id":"1","status":"completed"}}"#,
                #"{"timestamp":"2026-11-14T09:00:05.000Z","type":"response_item","payload":{"type":"function_call","name":"wait","arguments":"{\"cell_id\":\"1\",\"yield_time_ms\":10}","call_id":"2"}}"#,
                #"{"timestamp":"2026-11-14T09:00:06.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Added the test."}]}}"#,
                #"{"timestamp":"2026-11-14T09:00:07.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":4000,"output_tokens":300}}}}"#,
                #"{"timestamp":"2026-11-14T09:00:40.000Z","type":"event_msg","payload":{"type":"user_message","message":"add a test"}}"#,
            ])
        try write(
            ".copilot/session-state/p1/workspace.yaml", ["id: p1", "cwd: /Users/me/Dev/my.app", "name: Tidy the README", "updated_at: 2026-11-14T09:30:00.000Z"])
        try write(
            ".copilot/session-state/p1/events.jsonl",
            [
                #"{"type":"session.model_change","timestamp":"2026-11-14T09:10:00.000Z","data":{"newModel":"gpt-5.5"}}"#,
                #"{"type":"user.message","timestamp":"2026-11-14T09:10:01.000Z","data":{"content":"tidy the README"}}"#,
                #"{"type":"tool.execution_start","timestamp":"2026-11-14T09:10:02.000Z","data":{"toolName":"bash","arguments":{"command":"cat README.md","description":"Read"}}}"#,
                #"{"type":"assistant.message","timestamp":"2026-11-14T09:10:03.000Z","data":{"content":"Tidied.","model":"gpt-5.5"}}"#,
                #"{"type":"session.usage_record","timestamp":"2026-11-14T09:10:04.000Z","data":{"usage":{"inputTokens":700,"outputTokens":70,"cost":1.0}}}"#,
            ])
        let listed = AgentHistory.conversations(in: project, home: home.path)
        let codex = AgentHistory.details(of: try XCTUnwrap(listed.first { $0.agent == "codex" }))
        XCTAssertEqual(
            codex.entries.map { "\($0.kind.rawValue)\($0.tool.map { "(" + $0 + ")" } ?? ""): \($0.text)" }, ["user: add a test", "tool(exec): ls Tests", "tool(wait): ", "agent: Added the test."])
        XCTAssertEqual(codex.model, "gpt-5.5-codex")
        XCTAssertEqual(codex.inputTokens, 4000)
        XCTAssertEqual(codex.outputTokens, 300)
        XCTAssertNil(codex.files, "Codex runs commands: its record does not say which files they wrote")
        XCTAssertEqual(codex.duration, 40)
        XCTAssertTrue(codex.facts.contains { $0.name == "Files changed" && $0.value == "not recorded by this agent" })

        var copilot = AgentHistory.details(of: try XCTUnwrap(listed.first { $0.agent == "copilot" }))
        XCTAssertEqual(copilot.entries.map(\.text), ["tidy the README", "cat README.md", "Tidied."])
        XCTAssertEqual(copilot.model, "gpt-5.5")
        XCTAssertEqual(copilot.inputTokens, 700)
        XCTAssertNil(copilot.cost, "its cost is in a unit of its own, not money")
        XCTAssertNil(copilot.files, "not said until the session ended")
        // Ended: Copilot then says which files it changed.
        try write(
            ".copilot/session-state/p1/events.jsonl",
            [
                #"{"type":"user.message","timestamp":"2026-11-14T09:10:01.000Z","data":{"content":"tidy the README"}}"#,
                #"{"type":"session.shutdown","timestamp":"2026-11-14T09:20:00.000Z","data":{"codeChanges":{"filesModified":["README.md"],"linesAdded":2,"linesRemoved":1}}}"#,
            ])
        copilot = AgentHistory.details(of: try XCTUnwrap(AgentHistory.conversations(in: project, home: home.path).first { $0.agent == "copilot" }))
        XCTAssertEqual(copilot.files, ["README.md"])
    }

    /// HIST-13: searching finds a conversation by its title and by what
    /// was said in it, whatever the case, with a piece of the text around
    /// the words and how often they are there; not by what a tool
    /// printed, nor by the names of the file's own fields.
    func testConversationsAreSearchedByTitleAndByWhatWasSaid() throws {
        _ = try claude("s1", claudeLines)
        _ = try claude(
            "s3",
            [
                #"{"type":"user","message":{"role":"user","content":"rename the Password field"},"sessionId":"s3"}"#,
                #"{"type":"assistant","message":{"id":"a","role":"assistant","content":[{"type":"text","text":"Renamed it: \"secret\" is its name now."}]}}"#,
                #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t","content":"login printed by a tool"}]}}"#,
            ])
        let all = AgentHistory.conversations(in: project, home: home.path)
        func search(_ query: String) -> [String] {
            var hits: [String] = []
            AgentHistory.search(query, in: all, isCancelled: { false }) { hits.append("\($0.conversation.sessionID) \($0.count) \($0.snippet ?? "-")") }
            return hits.sorted()
        }
        XCTAssertEqual(search("LOGIN"), ["s1 2 fix the login bug"], "in the title and in two things said; not what a tool printed in s3")
        XCTAssertEqual(search("password"), ["s1 1 The Password check was wrong; fixed.", "s3 1 rename the Password field"])
        // A quote is written another way in the file: found all the same.
        XCTAssertEqual(search("\"secret\" is"), ["s3 1 Renamed it: \"secret\" is its name now."])
        XCTAssertEqual(search("tool_use"), [], "a field of the file is not something said")
        XCTAssertEqual(search("  "), [])
        var seen = 0
        AgentHistory.search("login", in: all, isCancelled: { true }) { _ in seen += 1 }
        XCTAssertEqual(seen, 0, "stopped")

        XCTAssertTrue(AgentHistory.holds(Data("The LOGIN code".utf8), "login"))
        XCTAssertFalse(AgentHistory.holds(Data("logi".utf8), "login"))
        XCTAssertEqual(AgentHistory.snippet(of: String(repeating: "a", count: 200) + " needle\nnext " + String(repeating: "b", count: 200), around: 201, length: 6).count, 60 + 6 + 100 + 2)
    }

    /// HIST-14: deleting a conversation moves its agent's record to the
    /// Trash, so it is no longer listed; only a file an agent keeps
    /// conversations in is ever touched; Antigravity's is refused with
    /// what to do instead.
    func testAConversationIsDeletedToTheTrash() throws {
        let conversation = try claude("s1", claudeLines)
        let file = try XCTUnwrap(conversation.source)
        XCTAssertNil(AgentHistory.delete(conversation, home: home.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: trash.path), ["s1.jsonl"])
        XCTAssertEqual(AgentHistory.conversations(in: project, home: home.path).map(\.sessionID), [])
        XCTAssertEqual(AgentHistory.delete(conversation, home: home.path), "Its file is gone already.")

        // Whatever a client names as the file: nothing outside the agents' folders.
        try write("notes.jsonl", ["mine"])
        var forged = conversation
        forged.source = home.appendingPathComponent("notes.jsonl").path
        XCTAssertEqual(AgentHistory.delete(forged, home: home.path), "That is not a conversation of Claude Code.")
        forged.source = home.appendingPathComponent(".claude/projects/../../notes.jsonl").path
        XCTAssertEqual(AgentHistory.delete(forged, home: home.path), "That is not a conversation of Claude Code.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent("notes.jsonl").path))

        // Copilot's is its folder.
        try write(".copilot/session-state/p1/workspace.yaml", ["id: p1", "cwd: /Users/me/Dev/my.app", "name: Tidy", "updated_at: 2026-11-14T09:30:00.000Z"])
        try write(".copilot/session-state/p1/events.jsonl", [#"{"type":"user.message","data":{"content":"tidy"}}"#])
        let copilot = try XCTUnwrap(AgentHistory.conversations(in: project, home: home.path).first)
        XCTAssertNil(AgentHistory.delete(copilot, home: home.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".copilot/session-state/p1").path))

        let antigravity = Conversation(agent: "agy", sessionID: "g1", title: "t", updatedAt: Date(), cwd: project, source: home.appendingPathComponent(".gemini/x.jsonl").path)
        XCTAssertTrue(try XCTUnwrap(AgentHistory.delete(antigravity, home: home.path)).hasPrefix("Antigravity keeps its list"))
    }
}
