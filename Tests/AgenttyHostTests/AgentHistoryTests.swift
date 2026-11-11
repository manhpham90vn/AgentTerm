@testable import AgenttyHost
import XCTest

final class AgentHistoryTests: XCTestCase {
    private var home: URL!
    private let project = "/Users/me/Dev/my.app"

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("agentty-history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: home)
    }

    private func write(_ path: String, _ lines: [String], modified: Date? = nil) throws {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
    }

    private func history(_ directory: String? = nil, includeSubfolders: Bool = false) -> [Conversation] {
        AgentHistory.conversations(in: directory ?? project, includeSubfolders: includeSubfolders, home: home.path)
    }

    func testClaudeProjectFolderName() {
        XCTAssertEqual(AgentHistory.claudeProjectName(for: "/Users/manh/Project/apps"), "-Users-manh-Project-apps")
        XCTAssertEqual(AgentHistory.claudeProjectName(for: "/Users/me/Dev/my.app_v2"), "-Users-me-Dev-my-app-v2")
    }

    func testClaudeUsesTheNewestTitleAndFallsBackToTheFirstPrompt() throws {
        let folder = ".claude/projects/-Users-me-Dev-my-app"
        try write("\(folder)/aaaa-1111.jsonl", [
            #"{"type":"user","message":{"role":"user","content":"sửa lỗi đăng nhập"},"sessionId":"aaaa-1111"}"#,
            #"{"type":"ai-title","aiTitle":"Old title","sessionId":"aaaa-1111"}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"ok"}]}}"#,
            #"{"type":"ai-title","aiTitle":"Fix the login bug","sessionId":"aaaa-1111"}"#,
        ], modified: Date(timeIntervalSince1970: 2_000))
        try write("\(folder)/bbbb-2222.jsonl", [
            #"{"type":"user","isMeta":true,"message":{"role":"user","content":"Caveat: ignore"}}"#,
            #"{"type":"user","message":{"role":"user","content":"<command-name>/clear</command-name>"}}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"viết   test\ncho API"}]}}"#,
        ], modified: Date(timeIntervalSince1970: 3_000))
        try write("\(folder)/agent-cccc.jsonl", [#"{"type":"user","message":{"role":"user","content":"sub agent work"}}"#])
        try write("\(folder)/dddd-4444.jsonl", [#"{"type":"mode","mode":"default"}"#])

        let found = history()
        XCTAssertEqual(found.map(\.sessionID), ["bbbb-2222", "aaaa-1111"], "newest first, empty and sub-agent files left out")
        XCTAssertEqual(found[0].title, "viết test cho API")
        XCTAssertEqual(found[1].title, "Fix the login bug")
        XCTAssertEqual(found[1].resumeCommand, "claude --resume aaaa-1111")
        XCTAssertEqual(found[1].cwd, project)
    }

    func testClaudeIncludesSubfoldersButNotLookalikeSiblings() throws {
        // "/Users/me/Dev/my.app/web" and "/Users/me/Dev/my.app-web" share a project folder prefix.
        try write(".claude/projects/-Users-me-Dev-my-app-web/sub-1.jsonl", [
            #"{"type":"user","cwd":"/Users/me/Dev/my.app/web","message":{"role":"user","content":"style the header"}}"#,
        ])
        try write(".claude/projects/-Users-me-Dev-my-app-tools/sib-1.jsonl", [
            #"{"type":"user","cwd":"/Users/me/Dev/my.app-tools","message":{"role":"user","content":"unrelated project"}}"#,
        ])
        XCTAssertTrue(history().isEmpty, "a folder lists only its own conversations")
        let found = history(includeSubfolders: true)
        XCTAssertEqual(found.map(\.sessionID), ["sub-1"])
        XCTAssertEqual(found[0].cwd, "/Users/me/Dev/my.app/web")
    }

    func testCodexMatchesByDirectoryAndTakesThePromptFromHistory() throws {
        let meta = { (id: String, cwd: String) in #"{"type":"session_meta","payload":{"id":"\#(id)","cwd":"\#(cwd)","base_instructions":"…"}}"# }
        try write(".codex/sessions/2026/11/10/rollout-2026-11-10T01-00-00-id-one.jsonl", [meta("id-one", project)])
        try write(".codex/sessions/2026/11/11/rollout-2026-11-11T01-00-00-id-two.jsonl", [
            meta("id-two", project + "/packages/web"),
            #"{"type":"event_msg","payload":{"type":"user_message","message":"add dark mode"}}"#,
        ])
        try write(".codex/sessions/2026/11/11/rollout-2026-11-11T02-00-00-id-three.jsonl", [meta("id-three", "/Users/me/Dev/other")])
        try write(".codex/history.jsonl", [
            #"{"session_id":"id-one","ts":1,"text":"refactor the parser"}"#,
            #"{"session_id":"id-one","ts":2,"text":"a later prompt"}"#,
            #"{"session_id":"id-three","ts":3,"text":"not this project"}"#,
        ])
        XCTAssertEqual(history().map(\.sessionID), ["id-one"], "the subfolder's conversation is not the project's")
        XCTAssertEqual(history(project + "/packages/web").map(\.sessionID), ["id-two"])
        let found = history(includeSubfolders: true).filter { $0.agent == "codex" }
        XCTAssertEqual(Set(found.map(\.sessionID)), ["id-one", "id-two"])
        XCTAssertEqual(found.first { $0.sessionID == "id-one" }?.title, "refactor the parser")
        let nested = try XCTUnwrap(found.first { $0.sessionID == "id-two" })
        XCTAssertEqual(nested.title, "add dark mode")
        XCTAssertEqual(nested.cwd, project + "/packages/web")
        XCTAssertEqual(nested.resumeCommand, "codex resume id-two")
    }

    func testAntigravityReadsTheMetadataCache() throws {
        try write(".gemini/antigravity-cli/cache/conversation_metadata.json", ["""
        {"conversations":{
          "conv-1":{"is_internal":false,"last_modified_time":"2026-11-10T17:00:22.474318735+07:00",
            "summary":{"Title":"Plan the release","Preview":"p","UpdatedAt":"2026-11-10T17:00:22.474318735+07:00","WorkspaceURIs":["file:///Users/me/Dev/my.app"]}},
          "conv-2":{"is_internal":true,"summary":{"Title":"internal","UpdatedAt":"2026-11-10T17:00:22Z","WorkspaceURIs":["file:///Users/me/Dev/my.app"]}},
          "conv-3":{"is_internal":false,"summary":{"Title":"elsewhere","UpdatedAt":"2026-11-10T17:00:22Z","WorkspaceURIs":["file:///Users/me/Dev/other"]}}
        }}
        """])
        let found = history()
        XCTAssertEqual(found.map(\.id), ["agy:conv-1"])
        XCTAssertEqual(found[0].title, "Plan the release")
        XCTAssertEqual(found[0].resumeCommand, "agy --conversation conv-1")
        XCTAssertEqual(found[0].updatedAt.timeIntervalSince1970, 1_794_304_822.474, accuracy: 0.01)
        XCTAssertNil(found[0].source, "no transcript file was written for it")

        try write(".gemini/antigravity-cli/brain/conv-1/.system_generated/logs/transcript.jsonl", ["{}"])
        XCTAssertTrue(history()[0].source?.hasSuffix("/brain/conv-1/.system_generated/logs/transcript.jsonl") == true)
        try write(".gemini/antigravity-cli/brain/conv-1/.system_generated/logs/transcript_full.jsonl", ["{}"])
        XCTAssertTrue(history()[0].source?.hasSuffix("/transcript_full.jsonl") == true, "the untruncated file is preferred")
    }

    func testCopilotReadsWorkspaceFiles() throws {
        try write(".copilot/session-state/sess-1/workspace.yaml", [
            "id: sess-1", "cwd: /Users/me/Dev/my.app", "name: Hello Session", "user_named: false", "updated_at: 2026-11-11T04:32:36.549Z",
        ])
        try write(".copilot/session-state/sess-2/workspace.yaml", ["id: sess-2", "cwd: /Users/me/Dev/my.app", "updated_at: 2026-11-11T05:00:00.000Z"])
        try write(".copilot/session-state/sess-2/events.jsonl", [
            #"{"type":"session.start","data":{}}"#,
            #"{"type":"user.message","data":{"content":"explain this repo"}}"#,
        ])
        try write(".copilot/session-state/sess-3/workspace.yaml", ["id: sess-3", "cwd: /tmp", "name: Other"])
        let found = history()
        XCTAssertEqual(found.map(\.sessionID), ["sess-2", "sess-1"])
        XCTAssertEqual(found[0].title, "explain this repo")
        XCTAssertEqual(found[1].title, "Hello Session")
        XCTAssertEqual(found[1].resumeCommand, "copilot --resume=sess-1")
    }

    func testIdentifiersThatCouldBreakOutOfTheCommandAreDropped() throws {
        XCTAssertTrue(AgentHistory.isSafeIdentifier("01a1c6c2-d410-7bf3-bd53-0710a01e7ab0"))
        for bad in ["", "a b", "x;rm -rf ~", "$(id)", "a`b`", "-rf", "a/b", "é"] {
            XCTAssertFalse(AgentHistory.isSafeIdentifier(bad), bad)
        }
        try write(".copilot/session-state/evil/workspace.yaml", ["id: x; touch /tmp/pwned", "cwd: /Users/me/Dev/my.app", "name: Evil"])
        XCTAssertTrue(history().isEmpty)
    }

    func testEveryAgentIsScopedToTheExactFolder() throws {
        let sub = project + "/packages/web"
        try write(".gemini/antigravity-cli/cache/conversation_metadata.json", ["""
        {"conversations":{
          "here":{"summary":{"Title":"here","UpdatedAt":"2026-11-10T17:00:22Z","WorkspaceURIs":["file:///Users/me/Dev/my.app"]}},
          "below":{"summary":{"Title":"below","UpdatedAt":"2026-11-10T17:00:23Z","WorkspaceURIs":["file:///Users/me/Dev/my.app/packages/web"]}}
        }}
        """])
        try write(".copilot/session-state/c-here/workspace.yaml", ["id: c-here", "cwd: \(project)", "name: here", "updated_at: 2026-11-11T04:00:00.000Z"])
        try write(".copilot/session-state/c-below/workspace.yaml", ["id: c-below", "cwd: \(sub)", "name: below", "updated_at: 2026-11-11T05:00:00.000Z"])
        XCTAssertEqual(Set(history().map(\.sessionID)), ["here", "c-here"])
        XCTAssertEqual(Set(history(sub).map(\.sessionID)), ["below", "c-below"])
        XCTAssertEqual(history(includeSubfolders: true).count, 4)
    }

    func testAllConversationsCoversEveryFolder() throws {
        try write(".claude/projects/-Users-me-Dev-my-app/c-1.jsonl", [
            #"{"type":"user","cwd":"/Users/me/Dev/my.app","message":{"role":"user","content":"in the project"}}"#,
        ], modified: Date(timeIntervalSince1970: 5_000))
        try write(".claude/projects/-Users-me-other/c-2.jsonl", [
            #"{"type":"user","cwd":"/Users/me/other","message":{"role":"user","content":"somewhere else"}}"#,
        ], modified: Date(timeIntervalSince1970: 6_000))
        try write(".claude/projects/-Users-me-nocwd/c-3.jsonl", [
            #"{"type":"user","message":{"role":"user","content":"folder unknown"}}"#,
        ])
        try write(".codex/sessions/2026/11/11/rollout-2026-11-11T01-00-00-x-1.jsonl", [
            #"{"type":"session_meta","payload":{"id":"x-1","cwd":"/tmp/scratch"}}"#,
        ], modified: Date(timeIntervalSince1970: 7_000))
        try write(".codex/history.jsonl", [#"{"session_id":"x-1","ts":1,"text":"quick experiment"}"#])
        try write(".copilot/session-state/p-1/workspace.yaml", ["id: p-1", "cwd: /Users/me/third", "name: third", "updated_at: 1970-01-01T00:16:40.000Z"])

        let all = AgentHistory.allConversations(home: home.path)
        XCTAssertEqual(all.map(\.sessionID), ["x-1", "c-2", "c-1", "p-1"], "newest first; a session with no recorded folder is left out")
        XCTAssertEqual(all.map(\.cwd), ["/tmp/scratch", "/Users/me/other", "/Users/me/Dev/my.app", "/Users/me/third"])
        XCTAssertEqual(AgentHistory.allConversations(home: home.path, limit: 2).count, 2)
        XCTAssertEqual(history().map(\.sessionID), ["c-1"], "the folder view is unaffected")
    }

    func testNothingInstalledMeansNoHistory() {
        XCTAssertTrue(AgentHistory.allConversations(home: home.path).isEmpty)
        XCTAssertTrue(history().isEmpty)
        XCTAssertTrue(history("/nonexistent/place").isEmpty)
    }

    func testDatesWithAnyFractionParse() {
        XCTAssertNotNil(AgentHistory.parseDate("2026-11-11T04:32:36Z"))
        XCTAssertNotNil(AgentHistory.parseDate("2026-11-11T04:32:36.5Z"))
        XCTAssertNotNil(AgentHistory.parseDate("2026-11-10T17:00:22.474318735+07:00"))
        XCTAssertNil(AgentHistory.parseDate("yesterday"))
    }
}
