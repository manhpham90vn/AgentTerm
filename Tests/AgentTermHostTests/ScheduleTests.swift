import AgentTermClient
import AgentTermProtocol
import XCTest

@testable import AgentTermHost

/// Starting an agent at a set time (#11).
final class ScheduleTimeTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    /// SCHED-1: when each kind of schedule comes due next.
    func testWhenASchedulesComesDueNext() {
        let monday = date("2026-11-16T08:00:00Z")
        XCTAssertEqual(ScheduleTime.daily(hour: 9, minute: 30).next(after: monday, calendar: calendar), date("2026-11-16T09:30:00Z"))
        XCTAssertEqual(ScheduleTime.daily(hour: 7, minute: 0).next(after: monday, calendar: calendar), date("2026-11-17T07:00:00Z"))
        // Saturday (7) and Sunday (1): the next is Saturday.
        XCTAssertEqual(ScheduleTime.weekly(weekdays: [1, 7], hour: 10, minute: 0).next(after: monday, calendar: calendar), date("2026-11-21T10:00:00Z"))
        XCTAssertEqual(ScheduleTime.once(date("2026-11-16T12:00:00Z")).next(after: monday, calendar: calendar), date("2026-11-16T12:00:00Z"))
        XCTAssertNil(ScheduleTime.once(date("2026-11-15T12:00:00Z")).next(after: monday, calendar: calendar), "a moment that passed")
        XCTAssertNil(ScheduleTime.limitReset.next(after: monday, calendar: calendar))
    }

    /// SCHED-2: each agent is started with its own switch for the mode, and
    /// Codex offers no "accept edits".
    func testEachAgentIsStartedWithItsOwnSwitch() {
        func launch(_ agent: String, _ mode: SchedulePermissions) -> (String, [String: String]) {
            ScheduleRunner.launch(Schedule(name: "n", agent: agent, folder: "/p", prompt: "fix it's tests", when: .limitReset, permissions: mode))
        }
        XCTAssertEqual(launch("claude", .skipAll).0, "claude --permission-mode bypassPermissions 'fix it'\\''s tests'")
        XCTAssertEqual(launch("claude", .acceptEdits).0, "claude --permission-mode acceptEdits 'fix it'\\''s tests'")
        XCTAssertEqual(launch("claude", .ask).0, "claude 'fix it'\\''s tests'")
        XCTAssertEqual(launch("codex", .skipAll).0, "codex --dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust 'fix it'\\''s tests'")
        XCTAssertEqual(launch("copilot", .skipAll).1, ["COPILOT_ALLOW_ALL": "true"])
        XCTAssertEqual(launch("copilot", .acceptEdits).0, "copilot --allow-tool=write -i 'fix it'\\''s tests'")
        XCTAssertEqual(launch("agy", .skipAll).0, "agy --dangerously-skip-permissions -i 'fix it'\\''s tests'")
        XCTAssertEqual(launch("agy", .acceptEdits).0, "agy --mode accept-edits -i 'fix it'\\''s tests'")
        XCTAssertEqual(SchedulePermissions.offered(by: "codex"), [.skipAll, .ask])
        XCTAssertEqual(SchedulePermissions.offered(by: "claude"), [.skipAll, .acceptEdits, .ask])
        XCTAssertTrue(SchedulePermissions.warning(agent: "codex", name: "Codex").contains("hooks"))
    }

    /// SCHED-3: the folder is trusted where the agent keeps that, and the
    /// rest of its settings is left as it was.
    func testTheFolderIsTrustedWhereTheAgentKeepsIt() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-trust-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try #"{"numStartups":3,"projects":{"/other":{"hasTrustDialogAccepted":true,"x":1}}}"#.write(
            to: home.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
        try ScheduleRunner.trustFolder(
            of: Schedule(name: "n", agent: "claude", folder: "/work", prompt: "p", when: .limitReset), home: home.path)
        let claude = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: home.appendingPathComponent(".claude.json"))) as? [String: Any])
        XCTAssertEqual(claude["numStartups"] as? Int, 3)
        let projects = try XCTUnwrap(claude["projects"] as? [String: [String: Any]])
        XCTAssertEqual(projects["/work"]?["hasTrustDialogAccepted"] as? Bool, true)
        XCTAssertEqual(projects["/other"]?["x"] as? Int, 1)

        try ScheduleRunner.trustFolder(
            of: Schedule(name: "n", agent: "copilot", folder: "/work", prompt: "p", when: .limitReset, permissions: .ask), home: home.path)
        let copilot = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: home.appendingPathComponent(".copilot/config.json"))) as? [String: Any])
        XCTAssertEqual(copilot["trustedFolders"] as? [String], ["/work"])
    }
}

/// SCHED-4 to SCHED-9: a host with a clock the test sets, and a stand-in
/// agent that writes down how it was started.
final class SchedulerHostTests: XCTestCase {
    private final class Client {
        let connection: AgentTermConnection
        var messages: [ServerMessage] = []

        init(port: UInt16, token: String) {
            connection = AgentTermConnection(host: "127.0.0.1", port: port, credential: .token(token), clientName: "mac")
            connection.onMessage = { [weak self] in self?.messages.append($0) }
            connection.connect()
        }

        var sessions: [SessionInfo] { messages.compactMap { if case .sessions(let list) = $0 { return list } else { return nil } }.last ?? [] }
        var schedules: [Schedule] { messages.compactMap { if case .schedules(let list) = $0 { return list } else { return nil } }.last ?? [] }
        var errors: [String] { messages.compactMap { if case .error(let text) = $0 { return text } else { return nil } } }
    }

    private var root: URL!
    private var server: HostServer!
    private var client: Client!
    private let token = "test-token-0123456789abcdef0123456789"
    private let lock = NSLock()
    /// A minute before nine, the Mac's own time: when the schedules of these
    /// tests come due.
    private var clock = ScheduleTime.daily(hour: 9, minute: 0).next(after: ISO8601DateFormatter().date(from: "2026-11-16T00:00:00Z")!)!
        .addingTimeInterval(-60)
    private var held = false
    private var project: URL { root.appendingPathComponent("project") }
    private var started: URL { root.appendingPathComponent("started") }

    private func set(_ date: Date) {
        lock.lock()
        clock = date
        lock.unlock()
    }

    private var isHeld: Bool {
        lock.lock()
        defer { lock.unlock() }
        return held
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-sched-\(UUID().uuidString)").standardizedFileURL
        let agents = root.appendingPathComponent("agents")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        // Writes down its arguments, its folder and its permission variable,
        // says it is at work on its prompt as its hooks would save it, then
        // waits. Codex says nothing, as it does while its hooks are not
        // trusted.
        try """
        #!/bin/sh
        printf '%s|%s|%s\\n' "$*" "$PWD" "$COPILOT_ALLOW_ALL" >> '\(started.path)'
        agent=$(basename "$0")
        case "$agent" in
        claude) event=UserPromptSubmit ;;
        copilot) event=userPromptSubmitted ;;
        *) event= ;;
        esac
        if [ -n "$event" ] && [ -n "$AGENTTERM_EVENTS" ]; then
            printf '{"agent":"%s","event":"%s","at":%s,"input":{}}' "$agent" "$event" "$(date +%s)" > "$AGENTTERM_EVENTS"
        fi
        exec sleep 600
        """.write(to: agents.appendingPathComponent("claude"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: agents.appendingPathComponent("claude").path)
        try FileManager.default.copyItem(at: agents.appendingPathComponent("claude"), to: agents.appendingPathComponent("copilot"))
        try FileManager.default.copyItem(at: agents.appendingPathComponent("claude"), to: agents.appendingPathComponent("codex"))

        var configuration = HostServer.Configuration(
            port: 0, token: token, listenOnTailscale: false, detectAgents: { AgentDetector.detect(in: agents.path) },
            // The agents are given hooks; the stand-ins run none of them.
            statusLineTool: "/usr/bin/true", usageDirectory: root.appendingPathComponent("state/usage"))
        configuration.hooksDirectory = root.appendingPathComponent("state/hooks")
        configuration.foldersFile = root.appendingPathComponent("state/folders.json")
        configuration.agentsDirectory = agents.path
        configuration.home = root.path
        configuration.scheduleInterval = 0.1
        configuration.now = { [weak self] in
            guard let self else { return Date() }
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.clock
        }
        configuration.holdAwake = { [weak self] hold, _ in
            self?.lock.lock()
            self?.held = hold
            self?.lock.unlock()
            return true
        }
        configuration.isOnPower = { true }
        // Claude Code's limit starts over at nine, as its service says.
        configuration.fetchAccountUsage = { [weak self] agent in
            guard let self, agent == "claude" else { return nil }
            let limit = AccountLimit(id: "5h", title: "5h limit", shortTitle: "5h", usedPercent: 100, resetsAt: self.reset)
            return AccountUsage(agent: agent, groups: [AccountUsageGroup(limits: [limit])])
        }
        server = HostServer(configuration: configuration)
        let port = try server.start()
        client = Client(port: port, token: token)
        waitUntil("connected") { !self.client.messages.isEmpty }
    }

    /// When Claude Code's limit starts over, as its stand-in service says.
    private var reset: Date { ScheduleTime.daily(hour: 9, minute: 0).next(after: ISO8601DateFormatter().date(from: "2026-11-16T00:00:00Z")!)! }

    override func tearDown() {
        server?.stop()
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 10, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertTrue(condition(), "timed out waiting for: \(what)")
    }

    private func pause(_ seconds: TimeInterval = 0.5) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    private var startedLines: [String] {
        ((try? String(contentsOf: started, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    private func morning(_ agent: String = "claude", catchUp: Bool = true, permissions: SchedulePermissions = .skipAll, accepted: Bool = true) -> Schedule {
        Schedule(
            id: "s-\(agent)", name: "Morning review", agent: agent, folder: project.path, prompt: "Review yesterday's changes",
            when: .daily(hour: 9, minute: 0), permissions: permissions, catchUp: catchUp, warningAccepted: accepted)
    }

    /// SCHED-4: not saved with "skip all permissions" before its warning was
    /// accepted; saved, every client is told, with when it runs next.
    func testASchedulesThatSkipsPermissionsIsSavedOnlyOnceItsWarningWasAccepted() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = .current
        client.connection.send(.saveSchedule(morning(accepted: false)))
        waitUntil("refused") { self.client.errors.contains { $0.contains("warning") } }
        XCTAssertEqual(client.schedules, [])

        client.connection.send(.saveSchedule(morning()))
        waitUntil("saved") { self.client.schedules.count == 1 }
        XCTAssertEqual(client.schedules.first?.nextRun, ScheduleTime.daily(hour: 9, minute: 0).next(after: clock))
        // Codex has no "accept edits".
        var codex = morning("claude", permissions: .acceptEdits)
        codex.agent = "codex"
        codex.id = "codex"
        client.connection.send(.saveSchedule(codex))
        waitUntil("refused for Codex") { self.client.errors.contains { $0.contains("cannot run with") } }
        // Trusted for Claude Code when saved.
        let settings = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent(".claude.json"))) as? [String: Any])
        XCTAssertEqual(((settings["projects"] as? [String: Any])?[project.path] as? [String: Any])?["hasTrustDialogAccepted"] as? Bool, true)
    }

    /// SCHED-5: at its time, a session of its agent starts in its folder,
    /// with its prompt and the switch of its mode, named after it, once.
    func testAScheduleRunsAtItsTimeOnce() throws {
        let nine = ScheduleTime.daily(hour: 9, minute: 0).next(after: clock)!
        client.connection.send(.saveSchedule(morning()))
        waitUntil("saved") { self.client.schedules.count == 1 }
        pause()
        XCTAssertEqual(startedLines, [], "not before its time")

        set(nine.addingTimeInterval(5))
        waitUntil("the run's session") { self.client.sessions.count == 1 }
        let session = try XCTUnwrap(client.sessions.first)
        XCTAssertEqual(session.title, "Morning review")
        XCTAssertEqual(session.schedule, "Morning review")
        XCTAssertEqual(session.schedulePermissions, .skipAll)
        waitUntil("the agent to start") { !self.startedLines.isEmpty }
        let line = try XCTUnwrap(startedLines.first)
        XCTAssertTrue(line.hasPrefix("--permission-mode bypassPermissions Review yesterday's changes"), line)
        let folder = line.split(separator: "|").dropFirst().first.map(String.init) ?? ""
        XCTAssertEqual(URL(fileURLWithPath: folder).resolvingSymlinksInPath().path, project.resolvingSymlinksInPath().path)
        waitUntil("the run to be recorded") { self.client.schedules.first?.runs.map(\.note) == ["Started"] }
        XCTAssertEqual(client.schedules.first?.runs.map(\.note), ["Started"])
        pause()
        XCTAssertEqual(startedLines.count, 1, "once")
    }

    /// SCHED-6: a run whose turn before it is still going is skipped, and said to be.
    func testARunWhoseTurnBeforeIsStillGoingIsSkipped() throws {
        let nine = ScheduleTime.daily(hour: 9, minute: 0).next(after: clock)!
        client.connection.send(.saveSchedule(morning()))
        waitUntil("saved") { self.client.schedules.count == 1 }
        set(nine.addingTimeInterval(5))
        waitUntil("the first run") { self.client.sessions.count == 1 }
        waitUntil("its agent at work") { self.client.sessions.first?.state?.isWorking == true }
        // The next day, the stand-in still working on the first.
        set(nine.addingTimeInterval(24 * 3600 + 5))
        waitUntil("the second to be skipped") { self.client.schedules.first?.runs.last?.note == "Skipped: the run before it is still going" }
        XCTAssertEqual(client.sessions.count, 1)
    }

    /// SCHED-7: runs missed while the Mac slept run once for all of them, or
    /// not at all, as the schedule says; one switched off does not run.
    func testMissedRunsRunOnceOrNotAtAll() throws {
        client.connection.send(.saveSchedule(morning(catchUp: true)))
        var skip = morning("copilot", catchUp: false)
        skip.name = "Skips"
        client.connection.send(.saveSchedule(skip))
        var off = morning("claude")
        off.id = "off"
        off.name = "Off"
        off.enabled = false
        client.connection.send(.saveSchedule(off))
        waitUntil("saved") { self.client.schedules.count == 3 }
        pause()
        // Three days later: three nine o'clocks went by while it slept.
        set(clock.addingTimeInterval(3 * 24 * 3600))
        waitUntil("the one that catches up to run") { self.client.sessions.count == 1 }
        pause()
        XCTAssertEqual(client.sessions.map(\.title), ["Morning review"], "once for all, and not the others")
        let runs = Dictionary(uniqueKeysWithValues: client.schedules.map { ($0.name, $0.runs.map(\.note)) })
        XCTAssertEqual(runs["Morning review"]?.count, 1)
        XCTAssertTrue(runs["Morning review"]?.first?.hasPrefix("Missed at") == true, "\(runs)")
        XCTAssertEqual(runs["Skips"], ["Missed while the Mac was asleep or off"])
        XCTAssertEqual(runs["Off"], [])
    }

    /// SCHED-8: a schedule about to run holds the Mac awake, whatever the
    /// keep-awake switch says.
    func testAScheduleAboutToRunKeepsTheMacAwake() throws {
        client.connection.send(.saveSchedule(morning()))
        waitUntil("held a minute before") { self.isHeld }
        // Long before the next one.
        set(clock.addingTimeInterval(-3 * 3600))
        client.connection.send(.saveSchedule(morning()))
        waitUntil("let go hours before") { !self.isHeld }
    }

    /// SCHED-10: a schedule made after its time today first runs tomorrow,
    /// not at once for the time that passed before it was made.
    func testAScheduleMadeAfterItsTimeDoesNotRunAtOnce() throws {
        pause()
        set(clock.addingTimeInterval(31 * 60))
        client.connection.send(.saveSchedule(morning()))
        waitUntil("saved") { self.client.schedules.count == 1 }
        pause()
        XCTAssertEqual(startedLines, [])
        XCTAssertEqual(client.schedules.first?.runs.count, 0)
    }

    /// SCHED-15: two schedules of one agent for when its limit starts over
    /// both run when it does, each once.
    func testEveryScheduleOfAnAgentRunsWhenItsLimitStartsOver() throws {
        // A session of Claude Code, so that its service is asked.
        client.connection.send(.create(CreateRequest(command: "claude", cwd: project.path, title: "by hand")))
        waitUntil("the account's limits") { self.client.messages.contains { if case .accountUsage(let list) = $0 { return !list.isEmpty } else { return false } } }
        for name in ["First", "Second"] {
            var schedule = morning()
            schedule.id = name
            schedule.name = name
            schedule.when = .limitReset
            client.connection.send(.saveSchedule(schedule))
        }
        waitUntil("both due two minutes after the reset") {
            self.client.schedules.count == 2 && self.client.schedules.allSatisfy { $0.nextRun == self.reset.addingTimeInterval(120) }
        }

        // A minute at a time, so that the Mac is not taken to have slept.
        for seconds in [0.0, 60, 125] {
            set(reset.addingTimeInterval(seconds))
            pause(0.3)
        }
        waitUntil("both runs") { self.client.sessions.filter { $0.schedule != nil }.count == 2 }
        XCTAssertEqual(Set(client.sessions.compactMap(\.schedule)), ["First", "Second"])
        pause()
        XCTAssertEqual(client.schedules.map { $0.runs.map(\.note) }, [["Started"], ["Started"]], "once each")
        XCTAssertEqual(client.schedules.map(\.nextRun), [nil, nil], "nothing more until the service names another reset")
    }

    /// A schedule of Codex, which asks for permission: its stand-in never
    /// says what it is doing.
    private func codex(_ name: String, hour: Int = 9, minute: Int = 0) -> Schedule {
        Schedule(
            id: name, name: name, agent: "codex", folder: project.path, prompt: "Look at the logs", when: .daily(hour: hour, minute: minute),
            permissions: .ask)
    }

    private func runs(of name: String) -> [SessionInfo] { client.sessions.filter { $0.schedule == name } }

    /// SCHED-16: a run whose agent never says what it is doing, and that
    /// has written nothing for an hour, is taken to be done: the next day's
    /// run starts, and it is closed a day after.
    func testARunNotKnownToBeGoingIsTakenForDoneOnceQuietForAnHour() throws {
        let nine = ScheduleTime.daily(hour: 9, minute: 0).next(after: clock)!
        client.connection.send(.saveSchedule(codex("Logs")))
        waitUntil("saved") { self.client.schedules.count == 1 }
        set(nine.addingTimeInterval(5))
        waitUntil("the first run") { self.runs(of: "Logs").count == 1 }
        let first = try XCTUnwrap(runs(of: "Logs").first)
        pause()
        XCTAssertNil(runs(of: "Logs").first?.state, "its agent says nothing")

        // The next day, a minute at a time around nine, so that the Mac is
        // not taken to have slept through it.
        set(nine.addingTimeInterval(24 * 3600 - 30))
        pause(0.3)
        set(nine.addingTimeInterval(24 * 3600 + 5))
        waitUntil("the second run") { self.runs(of: "Logs").count == 2 && self.client.schedules.first?.runs.count == 2 }
        XCTAssertEqual(client.schedules.first?.runs.map(\.note), ["Started", "Started"])

        // A day after it was first seen quiet for an hour, the first is closed.
        set(nine.addingTimeInterval(2 * 24 * 3600 - 29))
        waitUntil("the first run closed") { !self.client.sessions.contains { $0.id == first.id } }
        XCTAssertEqual(runs(of: "Logs").count, 1, "the second is still there")
    }

    /// SCHED-17: two runs whose agents never say what they are doing hold
    /// a third schedule back only until they have written nothing for an hour.
    func testRunsNotKnownToBeGoingHoldOthersBackOnlyForAnHour() throws {
        let nine = ScheduleTime.daily(hour: 9, minute: 0).next(after: clock)!
        client.connection.send(.saveSchedule(codex("A")))
        client.connection.send(.saveSchedule(codex("B")))
        var third = morning()
        third.when = .daily(hour: 9, minute: 30)
        client.connection.send(.saveSchedule(third))
        waitUntil("saved") { self.client.schedules.count == 3 }
        set(nine.addingTimeInterval(5))
        waitUntil("the two runs") { self.runs(of: "A").count == 1 && self.runs(of: "B").count == 1 }

        // Half an hour later: two runs at once already, the third waits.
        set(nine.addingTimeInterval(29 * 60 + 30))
        pause(0.3)
        set(nine.addingTimeInterval(30 * 60 + 5))
        pause()
        XCTAssertEqual(runs(of: third.name), [], "waits while the two may still be going")

        // An hour after they last wrote anything, it runs.
        set(nine.addingTimeInterval(60 * 60 + 10))
        waitUntil("the third run") { self.runs(of: third.name).count == 1 && self.client.schedules.first { $0.name == third.name }?.runs.count == 1 }
        XCTAssertEqual(client.schedules.first { $0.name == third.name }?.runs.map(\.note), ["Started"])
    }

    /// SCHED-18: a run whose folder is gone is not started anywhere else,
    /// and says why.
    func testARunWhoseFolderIsGoneIsNotStarted() throws {
        client.connection.send(.saveSchedule(morning()))
        waitUntil("saved") { self.client.schedules.count == 1 }
        try FileManager.default.removeItem(at: project)
        set(ScheduleTime.daily(hour: 9, minute: 0).next(after: clock)!.addingTimeInterval(5))
        waitUntil("the run to be recorded") { self.client.schedules.first?.runs.count == 1 }
        let run = try XCTUnwrap(client.schedules.first?.runs.first)
        XCTAssertFalse(run.started)
        XCTAssertEqual(run.note, "Not started: its folder \(project.path) is not there")
        pause()
        XCTAssertEqual(client.sessions, [])
        XCTAssertEqual(startedLines, [], "not in the home folder either")
    }

    /// SCHED-9: Copilot CLI asked to skip all is told so through its variable.
    func testCopilotIsToldThroughItsVariable() throws {
        client.connection.send(.saveSchedule(morning("copilot")))
        waitUntil("saved") { self.client.schedules.count == 1 }
        set(ScheduleTime.daily(hour: 9, minute: 0).next(after: clock)!.addingTimeInterval(5))
        waitUntil("the agent to start") { !self.startedLines.isEmpty }
        XCTAssertTrue(startedLines.first?.hasSuffix("|true") == true, startedLines.first ?? "")
    }
}
