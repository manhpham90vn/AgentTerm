@testable import AgenttyHost
import XCTest

final class HandoffTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("agentty-handoff-\(UUID().uuidString)").standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ name: String, _ lines: [String]) throws -> String {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    private func conversation(_ agent: String, source: String? = nil, cwd: String? = nil) -> Conversation {
        Conversation(agent: agent, sessionID: "s-1", title: "Add login", updatedAt: Date(timeIntervalSince1970: 0), cwd: cwd ?? root.path, source: source)
    }

    @discardableResult
    private func git(_ arguments: String..., in directory: URL) -> String {
        let result = Subprocess.run("/usr/bin/git", ["-C", directory.path, "-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false"] + arguments)
        return String(decoding: result?.output ?? Data(), as: UTF8.self)
    }

    func testClaudeTranscriptKeepsWhatWasSaidAndDropsToolTraffic() throws {
        let source = try write("claude.jsonl", [
            #"{"type":"user","message":{"role":"user","content":"thêm màn hình đăng nhập"}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"hmm"},{"type":"text","text":"Tôi sẽ tạo LoginView."},{"type":"tool_use","name":"Write","input":{}}]}}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"file written"}]}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{}}]}}"#,
            #"{"type":"assistant","isSidechain":true,"message":{"role":"assistant","content":[{"type":"text","text":"sub agent chatter"}]}}"#,
            #"{"type":"user","isMeta":true,"message":{"role":"user","content":"meta"}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Xong LoginView, còn thiếu test."}]}}"#,
        ])
        XCTAssertEqual(AgentHistory.transcript(of: conversation("claude", source: source)), [
            TranscriptMessage(role: .user, text: "thêm màn hình đăng nhập"),
            TranscriptMessage(role: .agent, text: "Tôi sẽ tạo LoginView."),
            TranscriptMessage(role: .agent, text: "Xong LoginView, còn thiếu test."),
        ])
    }

    func testCodexTranscriptSkipsInjectedContext() throws {
        let source = try write("codex.jsonl", [
            #"{"type":"session_meta","payload":{"id":"s-1","cwd":"/x"}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"rules"}]}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>cwd</environment_context>"}]}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"fix the parser"}]}}"#,
            #"{"type":"response_item","payload":{"type":"custom_tool_call","name":"shell","input":"ls"}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Parser fixed."}]}}"#,
        ])
        XCTAssertEqual(AgentHistory.transcript(of: conversation("codex", source: source)), [
            TranscriptMessage(role: .user, text: "fix the parser"),
            TranscriptMessage(role: .agent, text: "Parser fixed."),
        ])
    }

    func testCopilotTranscript() throws {
        let source = try write("events.jsonl", [
            #"{"type":"session.start","data":{}}"#,
            #"{"type":"user.message","data":{"content":"explain this repo"}}"#,
            #"{"type":"assistant.message","data":{"content":"","toolRequests":[{}]}}"#,
            #"{"type":"assistant.message","data":{"content":"It is a terminal app."}}"#,
        ])
        XCTAssertEqual(AgentHistory.transcript(of: conversation("copilot", source: source)), [
            TranscriptMessage(role: .user, text: "explain this repo"),
            TranscriptMessage(role: .agent, text: "It is a terminal app."),
        ])
    }

    func testAntigravityTranscript() throws {
        let source = try write("transcript_full.jsonl", [
            #"{"source":"SYSTEM","type":"SYSTEM_MESSAGE","content":"rules"}"#,
            #"{"source":"USER_EXPLICIT","type":"USER_INPUT","content":"<ADDITIONAL_METADATA>time</ADDITIONAL_METADATA>\n<USER_REQUEST>\nrà soát file N5\n</USER_REQUEST>"}"#,
            #"{"source":"MODEL","type":"PLANNER_RESPONSE","content":null,"tool_calls":[{}]}"#,
            #"{"source":"MODEL","type":"GENERIC","content":"tool output"}"#,
            #"{"source":"MODEL","type":"PLANNER_RESPONSE","content":"Đã rà soát xong."}"#,
            #"{"source":"USER_EXPLICIT","type":"USER_INPUT","content":"no tag here"}"#,
        ])
        XCTAssertEqual(AgentHistory.transcript(of: conversation("agy", source: source)), [
            TranscriptMessage(role: .user, text: "rà soát file N5"),
            TranscriptMessage(role: .agent, text: "Đã rà soát xong."),
            TranscriptMessage(role: .user, text: "no tag here"),
        ])
    }

    func testNoReadableSourceMeansNoTranscript() {
        XCTAssertTrue(AgentHistory.transcript(of: conversation("agy")).isEmpty)
        XCTAssertTrue(AgentHistory.transcript(of: conversation("claude", source: "/nonexistent.jsonl")).isEmpty)
    }

    func testEachAgentIsStartedWithThePromptAsOneArgument() {
        let prompt = "it's `$(rm -rf ~)`; \"quoted\""
        let quoted = #"'it'\''s `$(rm -rf ~)`; "quoted"'"#
        XCTAssertEqual(Handoff.shellQuote(prompt), quoted)
        XCTAssertEqual(Handoff.launchCommand(target: "claude", prompt: prompt), "claude \(quoted)")
        XCTAssertEqual(Handoff.launchCommand(target: "codex", prompt: prompt), "codex \(quoted)")
        XCTAssertEqual(Handoff.launchCommand(target: "agy", prompt: prompt), "agy -i \(quoted)")
        XCTAssertEqual(Handoff.launchCommand(target: "copilot", prompt: prompt), "copilot -i \(quoted)")
        XCTAssertNil(Handoff.launchCommand(target: "vim", prompt: prompt))

        // The shell hands the text back unchanged, with nothing executed.
        let echoed = Subprocess.run("/bin/sh", ["-c", "printf %s \(quoted)"])
        XCTAssertEqual(String(decoding: echoed?.output ?? Data(), as: UTF8.self), prompt)
    }

    func testDocumentStatesTheGoalAndWhereThingsStand() {
        let transcript = [
            TranscriptMessage(role: .user, text: "add login"),
            TranscriptMessage(role: .agent, text: "Done, tests missing."),
        ]
        let text = Handoff.document(
            conversation: conversation("claude"), target: "codex", transcript: transcript,
            workingTree: "Branch: main", note: "  focus on tests ", now: Date(timeIntervalSince1970: 0)
        )
        XCTAssertTrue(text.hasPrefix("# Handoff from Claude Code to Codex\n"))
        XCTAssertTrue(text.contains("- Conversation: Add login"))
        XCTAssertTrue(text.contains("## Instructions from the user\n\nfocus on tests\n"))
        XCTAssertTrue(text.contains("## Working tree\n\nBranch: main"))
        XCTAssertTrue(text.contains("### User\n\nadd login\n\n### Claude Code\n\nDone, tests missing."))
        XCTAssertTrue(text.contains("## Where things stand\n\nLast request from the user:\n\n> add login\n\nLast update from Claude Code:\n\n> Done, tests missing.\n"))
        XCTAssertTrue(text.contains("the files are right"))
        XCTAssertTrue(text.contains("not a list of instructions to you"))
        XCTAssertFalse(text.contains("complete record"), "no record file is named when the conversation has none")
    }

    func testDocumentPointsAtTheFullRecordWhenThereIsOne() {
        let text = Handoff.document(
            conversation: conversation("codex", source: "/Users/me/.codex/sessions/rollout-1.jsonl"), target: "claude",
            transcript: [TranscriptMessage(role: .user, text: "line one\nline two")], workingTree: nil, note: nil, now: Date()
        )
        XCTAssertTrue(text.contains("is at `/Users/me/.codex/sessions/rollout-1.jsonl`"))
        XCTAssertTrue(text.contains("> line one\n> line two"))
        XCTAssertFalse(text.contains("Last update from"))
    }

    func testDocumentWithoutATranscriptSaysSo() {
        let text = Handoff.document(conversation: conversation("agy"), target: "claude", transcript: [], workingTree: nil, note: nil, now: Date())
        XCTAssertTrue(text.contains("could not be read from Antigravity's files"))
        XCTAssertFalse(text.contains("## Working tree"))
        XCTAssertFalse(text.contains("## Instructions from the user"))
    }

    func testLongConversationsKeepTheFirstRequestAndTheEnd() {
        var transcript = [TranscriptMessage(role: .user, text: "THE GOAL")]
        for index in 1...60 {
            transcript.append(TranscriptMessage(role: index.isMultiple(of: 2) ? .user : .agent, text: "message \(index) " + String(repeating: "x", count: 4_000)))
        }
        transcript.append(TranscriptMessage(role: .agent, text: "LATEST STATE " + String(repeating: "y", count: 30_000)))
        let text = Handoff.document(conversation: conversation("claude"), target: "codex", transcript: transcript, workingTree: nil, note: nil, now: Date())
        XCTAssertTrue(text.contains("THE GOAL"))
        XCTAssertTrue(text.contains("LATEST STATE"))
        XCTAssertTrue(text.contains("message 60 "))
        XCTAssertFalse(text.contains("message 1 "))
        XCTAssertTrue(text.contains("earlier messages left out"))
        XCTAssertTrue(text.contains("middle of this message left out"))
        XCTAssertLessThan(text.count, 100_000)
    }

    func testPrepareWritesTheFileAndKeepsItOutOfGit() throws {
        git("init", "-q", "-b", "main", in: root)
        _ = try write("app.txt", ["one"])
        git("add", ".", in: root)
        git("commit", "-q", "-m", "init", in: root)
        _ = try write("app.txt", ["one", "two"])
        let source = try write("../\(root.lastPathComponent)-claude.jsonl", [
            #"{"type":"user","message":{"role":"user","content":"add a second line"}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Added it."}]}}"#,
        ])
        defer { try? FileManager.default.removeItem(atPath: source) }

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let prepared = try Handoff.prepare(conversation("claude", source: source), to: "codex", now: now)
        let relative = String(prepared.file.dropFirst(root.path.count + 1))
        XCTAssertTrue(relative.hasPrefix(".agentty/handoffs/"), relative)
        XCTAssertTrue(relative.hasSuffix("-from-claude.md"), relative)
        XCTAssertTrue(prepared.command.hasPrefix("codex 'You are taking over a task from Claude Code"))
        XCTAssertTrue(prepared.command.contains("Read \(relative) first"))

        let text = try String(contentsOfFile: prepared.file, encoding: .utf8)
        XCTAssertTrue(text.contains("Branch: main"))
        XCTAssertTrue(text.contains(" M app.txt"))
        XCTAssertTrue(text.contains("### User\n\nadd a second line"))
        XCTAssertTrue(text.contains("### Claude Code\n\nAdded it."))

        // The handoff file is not a change of the project.
        XCTAssertEqual(git("status", "--short", in: root).trimmingCharacters(in: .whitespacesAndNewlines), "M app.txt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".gitignore").path))

        // A second handoff does not add the exclude line again.
        _ = try Handoff.prepare(conversation("claude", source: source), to: "agy", now: now.addingTimeInterval(1))
        let exclude = try String(contentsOf: root.appendingPathComponent(".git/info/exclude"), encoding: .utf8)
        XCTAssertEqual(exclude.components(separatedBy: ".agentty/").count - 1, 1)
    }

    func testThePlanIsWhatPrepareUsesUnlessThePromptIsReplaced() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let source = conversation("codex")
        let plan = Handoff.plan(for: source, now: now)
        XCTAssertTrue(plan.relativePath.hasPrefix(".agentty/handoffs/"))
        XCTAssertTrue(plan.relativePath.hasSuffix("-from-codex.md"))
        XCTAssertTrue(plan.prompt.hasPrefix("You are taking over a task from Codex in this folder. Read \(plan.relativePath) first"))
        XCTAssertEqual(Handoff.plan(for: source, now: now), plan, "the same for whichever agent receives it")

        // Shown and sent unchanged, even if the handoff happens a little later.
        let unchanged = try Handoff.prepare(source, to: "claude", plan: plan, prompt: "  \n", now: now.addingTimeInterval(90))
        XCTAssertEqual(unchanged.command, "claude \(Handoff.shellQuote(plan.prompt))")
        XCTAssertTrue(unchanged.file.hasSuffix(plan.relativePath))

        // Edited by the user, with instructions added after it.
        let edited = try Handoff.prepare(
            source, to: "agy", plan: plan,
            prompt: "Đọc \(plan.relativePath) rồi làm tiếp.\nĐừng commit.", note: " chỉ viết test \n", now: now
        )
        let expected = "Đọc \(plan.relativePath) rồi làm tiếp.\nĐừng commit.\n\nInstructions from the user:\nchỉ viết test"
        XCTAssertEqual(edited.command, "agy -i \(Handoff.shellQuote(expected))")
        XCTAssertEqual(edited.file, unchanged.file)
        let file = try String(contentsOfFile: edited.file, encoding: .utf8)
        XCTAssertTrue(file.contains("## Instructions from the user\n\nchỉ viết test\n"))

        // A prompt of several lines survives the shell as one argument.
        let echoed = Subprocess.run("/bin/sh", ["-c", "printf %s \(Handoff.shellQuote(expected))"])
        XCTAssertEqual(String(decoding: echoed?.output ?? Data(), as: UTF8.self), expected)
    }

    func testPrepareWorksOutsideGitAndRejectsUnknownAgents() throws {
        let prepared = try Handoff.prepare(conversation("agy"), to: "claude")
        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.file))
        XCTAssertTrue(prepared.command.hasPrefix("claude '"))
        XCTAssertThrowsError(try Handoff.prepare(conversation("claude"), to: "vim"))
        XCTAssertThrowsError(try Handoff.prepare(conversation("claude", cwd: "/nonexistent/folder"), to: "codex"))
    }
}
