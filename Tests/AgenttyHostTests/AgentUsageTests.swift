@testable import AgenttyHost
import AgenttyProtocol
import XCTest

final class AgentUsageTests: XCTestCase {
    private func parse(_ agent: String, _ lines: [String]) -> SessionUsage? {
        AgentUsage.parse(agent: agent, data: Data(lines.joined(separator: "\n").utf8))
    }

    func testClaudeTakesTheNewestReplyOfTheMainConversation() {
        let usage = parse("claude", [
            #"cut off line","usage":{"input_tokens":999}}"#,
            #"{"type":"assistant","message":{"model":"claude-a","usage":{"input_tokens":10,"cache_read_input_tokens":1000,"cache_creation_input_tokens":5,"output_tokens":7}}}"#,
            #"{"type":"assistant","message":{"model":"claude-b","usage":{"input_tokens":4,"cache_read_input_tokens":236021,"cache_creation_input_tokens":39,"output_tokens":1953}}}"#,
            #"{"type":"assistant","isSidechain":true,"message":{"model":"claude-sub","usage":{"input_tokens":50,"output_tokens":1}}}"#,
            #"{"type":"assistant","message":{"model":"<synthetic>","usage":{"input_tokens":0,"output_tokens":0}}}"#,
            #"{"type":"user","message":{"role":"user","content":"what is my usage"}}"#,
        ])
        XCTAssertEqual(usage, SessionUsage(model: "claude-b", contextTokens: 236_064))
        XCTAssertNil(usage?.contextFraction, "Claude Code does not record the window")
    }

    func testCodexReadsContextAndLimits() {
        let usage = parse("codex", [
            #"{"type":"turn_context","payload":{"model":"gpt-x"}}"#,
            #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":51762},"last_token_usage":{"total_tokens":17639},"model_context_window":475000},"rate_limits":{"primary":{"used_percent":12.0,"window_minutes":300,"resets_at":1794396857},"secondary":{"used_percent":97.0,"window_minutes":10080,"resets_at":1794388909}}}}"#,
            #"{"type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"primary":{"used_percent":13.0,"window_minutes":300,"resets_at":1794396857},"secondary":{"used_percent":97.5,"window_minutes":10080,"resets_at":1794388909}}}}"#,
        ])
        XCTAssertEqual(usage?.model, "gpt-x")
        XCTAssertEqual(usage?.contextTokens, 17639, "the last request, not the running total")
        XCTAssertEqual(usage?.contextWindow, 475_000)
        XCTAssertEqual(usage?.limits, [
            UsageLimit(windowMinutes: 300, usedPercent: 13, resetsAt: Date(timeIntervalSince1970: 1_794_396_857)),
            UsageLimit(windowMinutes: 10080, usedPercent: 97.5, resetsAt: Date(timeIntervalSince1970: 1_794_388_909)),
        ], "the newest limits, also from an event without token counts")
        XCTAssertEqual(usage?.limits.map(\.label), ["5h", "Week"])
    }

    func testCopilotReadsTheLastRequestAndPremiumRequests() {
        let usage = parse("copilot", [
            #"{"type":"session.usage_record","data":{"usage":{"model":"gpt-a","modelDisplayName":"GPT A","inputTokens":100,"maxPromptTokens":272000}}}"#,
            #"{"type":"session.usage_record","data":{"usage":{"model":"gpt-b","modelDisplayName":"GPT B","inputTokens":20196,"maxPromptTokens":272000}}}"#,
            #"{"type":"session.usage_checkpoint","data":{"totalPremiumRequests":3}}"#,
        ])
        XCTAssertEqual(usage, SessionUsage(model: "GPT B", contextTokens: 20196, contextWindow: 272_000, premiumRequests: 3))
        XCTAssertEqual(usage?.contextFraction ?? 0, 20196.0 / 272_000, accuracy: 0.0001)
    }

    func testAntigravityReadsTheLastStep() {
        let usage = parse("agy", [
            #"{"step_index":1,"input_tokens":9336,"cache_read_tokens":0,"output_tokens":13}"#,
            #"{"step_index":2,"input_tokens":12000,"cache_read_tokens":500,"output_tokens":20}"#,
        ])
        XCTAssertEqual(usage, SessionUsage(contextTokens: 12500))
    }

    func testNothingRecordedIsNil() {
        XCTAssertNil(parse("claude", [#"{"type":"user","message":{"content":"hi"}}"#]))
        XCTAssertNil(parse("codex", []))
        XCTAssertNil(parse("zsh", [#"{"input_tokens":5}"#]))
        XCTAssertNil(parse("copilot", ["not json at all"]))
    }

    func testShortTokenCounts() {
        XCTAssertEqual([850, 1500, 17639, 236_064, 1_250_000].map(SessionUsage.short), ["850", "1.5K", "18K", "236K", "1.2M"])
    }
}

final class StatusLineRelayTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("agentty-statusline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("home/.claude"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("project/.claude"), withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private var home: String { root.appendingPathComponent("home").path }
    private var project: String { root.appendingPathComponent("project").path }
    private var file: String { root.appendingPathComponent("usage/session-1.json").path }

    private func input(_ extra: String = "") -> Data {
        Data(#"{"model":{"id":"claude-x","display_name":"Claude X"},"workspace":{"project_dir":"\#(project)"},"context_window":{"context_window_size":200000,"used_percentage":8,"current_usage":{"input_tokens":8500,"output_tokens":1200,"cache_creation_input_tokens":5000,"cache_read_input_tokens":2000}}\#(extra)}"#.utf8)
    }

    func testReadsContextAndLimits() {
        let limits = #","rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":1738425600},"seven_day":{"used_percentage":41.2,"resets_at":1738857600}}"#
        XCTAssertEqual(StatusLineRelay.usage(from: input(limits)), SessionUsage(
            model: "Claude X", contextTokens: 15500, contextWindow: 200_000,
            limits: [
                UsageLimit(windowMinutes: 300, usedPercent: 23.5, resetsAt: Date(timeIntervalSince1970: 1_738_425_600)),
                UsageLimit(windowMinutes: 10080, usedPercent: 41.2, resetsAt: Date(timeIntervalSince1970: 1_738_857_600)),
            ]
        ))
        // No subscription, or before the first reply: no limits, and that is fine.
        XCTAssertEqual(StatusLineRelay.usage(from: input())?.limits, [])
        XCTAssertNil(StatusLineRelay.usage(from: Data("not json".utf8)))
    }

    func testSavesTheInputAndPrintsNothingWithoutAUserStatusLine() throws {
        let output = StatusLineRelay.run(input: input(), file: file, home: home, environment: [:])
        XCTAssertEqual(output, Data())
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: file)), input())
    }

    func testRunsTheUsersOwnStatusLineWithTheSameInput() throws {
        try #"{"statusLine":{"type":"command","command":"/usr/bin/sed -n 's/.*display_name\":\"\\([^\"]*\\)\".*/[\\1] mine/p'"}}"#
            .write(toFile: home + "/.claude/settings.json", atomically: true, encoding: .utf8)
        let output = StatusLineRelay.run(input: input(), file: file, home: home, environment: [:])
        XCTAssertEqual(String(decoding: output, as: UTF8.self), "[Claude X] mine")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file))
    }

    func testTheProjectsStatusLineComesFirstAndOursIsNeverRunAgain() throws {
        try #"{"statusLine":{"type":"command","command":"echo user"}}"#.write(toFile: home + "/.claude/settings.json", atomically: true, encoding: .utf8)
        XCTAssertEqual(StatusLineRelay.userCommand(project: project, home: home, environment: [:]), "echo user")
        try #"{"statusLine":{"type":"command","command":"echo project"}}"#.write(toFile: project + "/.claude/settings.json", atomically: true, encoding: .utf8)
        XCTAssertEqual(StatusLineRelay.userCommand(project: project, home: home, environment: [:]), "echo project")
        try #"{"statusLine":{"type":"command","command":"'/Apps/agenttyd' statusline '/tmp/x.json'"}}"#.write(toFile: project + "/.claude/settings.json", atomically: true, encoding: .utf8)
        XCTAssertEqual(StatusLineRelay.userCommand(project: project, home: home, environment: [:]), "echo user")
        // A configuration folder of the user's choosing is honored.
        let other = root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try #"{"statusLine":{"type":"command","command":"echo other"}}"#.write(toFile: other.path + "/settings.json", atomically: true, encoding: .utf8)
        XCTAssertEqual(StatusLineRelay.userCommand(project: nil, home: home, environment: ["CLAUDE_CONFIG_DIR": other.path]), "echo other")
    }

    func testLaunchArgumentsSurviveTheShell() throws {
        let arguments = StatusLineRelay.launchArguments(tool: "/Apps/My App's/agenttyd", file: "/tmp/a b/session-1.json")
        // What the shell hands the program after its own unquoting.
        let result = Subprocess.run("/bin/sh", ["-c", "printf '%s\\n' x" + arguments])
        let lines = String(decoding: result?.output ?? Data(), as: UTF8.self).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.prefix(2), ["x", "--settings"])
        let settings = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lines[2].utf8)) as? [String: [String: String]])
        XCTAssertEqual(settings["statusLine"]?["type"], "command")
        // And the status line command, once the shell has unquoted that too.
        let command = try XCTUnwrap(settings["statusLine"]?["command"])
        let inner = Subprocess.run("/bin/sh", ["-c", "printf '%s\\n' " + command])
        XCTAssertEqual(String(decoding: inner?.output ?? Data(), as: UTF8.self), "/Apps/My App's/agenttyd\nstatusline\n/tmp/a b/session-1.json\n")
    }
}
