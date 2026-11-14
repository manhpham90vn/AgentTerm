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

/// SCHED-20 (#51): the agent writes its settings file too, while it runs.
/// What it writes while a folder is being trusted there is kept.
final class TrustWhileTheAgentWritesTests: XCTestCase {
    override func tearDown() { ScheduleRunner.beforeWriting = nil }

    func testWhatTheAgentWritesMeanwhileIsKept() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-trust-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let file = home.appendingPathComponent(".claude.json")
        try #"{"numStartups":3,"projects":{"/other/place":{"hasTrustDialogAccepted":true}}}"#.write(to: file, atomically: true, encoding: .utf8)
        // Claude Code writes the file between the host's read and its write.
        var written = 0
        ScheduleRunner.beforeWriting = { _ in
            guard written == 0 else { return }
            written += 1
            try? #"{"numStartups":4,"projects":{"/other/place":{"hasTrustDialogAccepted":true,"lastCost":1.5}}}"#.write(to: file, atomically: true, encoding: .utf8)
        }
        try ScheduleRunner.trustFolder(of: Schedule(name: "n", agent: "claude", folder: "/work/here", prompt: "p", when: .limitReset), home: home.path)
        let text = try String(contentsOf: file, encoding: .utf8)
        let claude = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let projects = try XCTUnwrap(claude["projects"] as? [String: [String: Any]])
        XCTAssertEqual(projects["/work/here"]?["hasTrustDialogAccepted"] as? Bool, true, "the folder is trusted")
        XCTAssertEqual(claude["numStartups"] as? Int, 4, "what the agent wrote meanwhile is kept")
        XCTAssertEqual(projects["/other/place"]?["lastCost"] as? Double, 1.5)
        XCTAssertFalse(text.contains(#"\/"#), "slashes as the agent writes them: \(text)")
    }

    /// A file that is written again every time it is looked at is not
    /// overwritten blindly: saving the schedule says so.
    func testAFileThatKeepsChangingIsNotOverwritten() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-trust-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".copilot"), withIntermediateDirectories: true)
        let file = home.appendingPathComponent(".copilot/config.json")
        try #"{"n":0}"#.write(to: file, atomically: true, encoding: .utf8)
        var written = 0
        ScheduleRunner.beforeWriting = { _ in
            written += 1
            try? #"{"n":\#(written)}"#.write(to: file, atomically: true, encoding: .utf8)
        }
        XCTAssertThrowsError(
            try ScheduleRunner.trustFolder(
                of: Schedule(name: "n", agent: "copilot", folder: "/work", prompt: "p", when: .limitReset, permissions: .ask), home: home.path))
        XCTAssertEqual(written, ScheduleRunner.editAttempts)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), #"{"n":\#(written)}"#, "the agent's last word stands")
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
        var failures: [PartFailure] { messages.compactMap { if case .failures(let list) = $0 { return list } else { return nil } }.last ?? [] }
        var paused: Bool? { messages.compactMap { if case .schedulesPaused(let paused) = $0 { return paused } else { return nil } }.last }
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
        # Codex prints nothing either: a run of it is known only by its silence.
        [ "$agent" = claude ] && echo "the stand-in $agent is at work"
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

    /// SCHED-19: a schedule for when the limit starts over learns when that
    /// is with no session of its agent open, as after the host started
    /// again, and runs then.
    func testALimitResetScheduleRunsWithNoSessionOfItsAgentOpen() throws {
        var schedule = morning()
        schedule.when = .limitReset
        client.connection.send(.saveSchedule(schedule))
        waitUntil("its time known") { self.client.schedules.first?.nextRun == self.reset.addingTimeInterval(120) }
        for seconds in [0.0, 60, 125] {
            set(reset.addingTimeInterval(seconds))
            pause(0.3)
        }
        waitUntil("the run") { self.client.sessions.contains { $0.schedule == schedule.name } }
    }

    /// SCHED-9: Copilot CLI asked to skip all is told so through its variable.
    func testCopilotIsToldThroughItsVariable() throws {
        client.connection.send(.saveSchedule(morning("copilot")))
        waitUntil("saved") { self.client.schedules.count == 1 }
        set(ScheduleTime.daily(hour: 9, minute: 0).next(after: clock)!.addingTimeInterval(5))
        waitUntil("the agent to start") { !self.startedLines.isEmpty }
        XCTAssertTrue(startedLines.first?.hasSuffix("|true") == true, startedLines.first ?? "")
    }

    // MARK: Run now, what a run did, and more ways to schedule (#47)

    @discardableResult
    private func git(_ arguments: String..., in directory: URL? = nil) -> String {
        let result = Subprocess.run("/usr/bin/git", ["-C", (directory ?? project).path, "-c", "commit.gpgsign=false"] + arguments, timeout: 30, mergeErrors: true)
        return String(decoding: result?.output ?? Data(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func repository() throws {
        git("init", "-q", "-b", "main")
        git("config", "user.name", "Test")
        git("config", "user.email", "test@example.com")
        try "one\n".write(to: project.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        git("add", ".")
        git("commit", "-q", "-m", "init")
    }

    private var runs: [ScheduleRun] { client.schedules.first?.runs ?? [] }

    /// SCHED-21: a schedule is run now, whatever its time; its run is
    /// stopped, and then says how it ended, how long it took, what it
    /// changed in git, and what it printed, which is kept.
    func testAScheduleIsRunNowStoppedAndSaysWhatItDid() throws {
        try repository()
        // Changed and not committed before the run: not something the run did.
        try "there before\n".write(to: project.appendingPathComponent("before.txt"), atomically: true, encoding: .utf8)
        try "one\nmine, not committed\n".write(to: project.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        client.connection.send(.saveSchedule(morning()))
        waitUntil("saved") { self.client.schedules.count == 1 }
        client.connection.send(.runSchedule(id: "s-claude"))
        waitUntil("the run's session") { self.client.sessions.count == 1 }
        waitUntil("recorded") { self.runs.map(\.note) == ["Run now"] }
        let run = try XCTUnwrap(runs.first)
        XCTAssertNil(run.ended)
        XCTAssertEqual(run.summary, "Run now")
        waitUntil("the agent at work") { !self.startedLines.isEmpty }
        // Running: it is not run beside itself.
        client.connection.send(.runSchedule(id: "s-claude"))
        waitUntil("refused") { self.client.errors.contains { $0.contains("is running: stop that run first") } }

        // What the run did meanwhile, and three minutes on the clock.
        try "made by the run\n".write(to: project.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        pause(0.6)
        try "one\nmine, not committed\ntwo\n".write(to: project.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        git("commit", "-q", "-am", "by the run")
        set(clock.addingTimeInterval(180))
        client.connection.send(.stopScheduleRun(id: "s-claude", at: run.at))
        waitUntil("the session ended") { self.client.sessions.isEmpty }
        waitUntil("how it ended") { self.runs.first?.outcome == "Stopped by you" }
        waitUntil("what it changed") { self.runs.first?.changes != nil }
        let ended = try XCTUnwrap(runs.first)
        XCTAssertEqual(ended.duration, 180)
        XCTAssertEqual(ended.summary, "Stopped by you, after 3 min")
        XCTAssertEqual(ended.changes, "1 commit, 1 file changed, 1 insertion, 1 new file not tracked")
        XCTAssertTrue(ended.hasOutput)
        client.connection.send(.scheduleRunOutput(id: "s-claude", at: run.at))
        waitUntil("what it printed") {
            self.client.messages.contains { if case .scheduleRunOutput("s-claude", run.at, let text?) = $0 { return text.contains("the stand-in claude is at work") } else { return false } }
        }
        // A run nothing was kept of, and one that is no longer going.
        client.connection.send(.scheduleRunOutput(id: "s-claude", at: .distantPast))
        waitUntil("nothing kept") { self.client.messages.contains(.scheduleRunOutput(id: "s-claude", at: .distantPast, text: nil)) }
        client.connection.send(.stopScheduleRun(id: "s-claude", at: run.at))
        waitUntil("not going any more") { self.client.errors.contains("That run is not going on any more.") }
    }

    /// SCHED-22: a run that waits for the one before it starts when that
    /// one has ended, instead of being skipped.
    func testARunWaitsForTheOneBeforeIt() throws {
        var schedule = morning()
        schedule.waitsForPrevious = true
        let nine = ScheduleTime.daily(hour: 9, minute: 0).next(after: clock)!
        client.connection.send(.saveSchedule(schedule))
        waitUntil("saved") { self.client.schedules.count == 1 }
        set(nine.addingTimeInterval(5))
        waitUntil("the first run") { self.client.sessions.count == 1 }
        waitUntil("its agent at work") { self.client.sessions.first?.state?.isWorking == true }
        let first = try XCTUnwrap(client.sessions.first?.id)
        set(nine.addingTimeInterval(24 * 3600 + 5))
        pause(0.6)
        XCTAssertEqual(runs.count, 1, "not skipped, and not started beside the first")
        XCTAssertEqual(client.sessions.count, 1)
        client.connection.send(.kill(session: first))
        waitUntil("the second, once the first ended") { self.client.sessions.first.map { $0.id != first } == true }
        waitUntil("both recorded") { self.runs.count == 2 }
        XCTAssertEqual(runs.first?.outcome, "Its session was ended")
        XCTAssertNil(runs.last?.ended)
    }

    /// SCHED-23: a run that takes longer than its schedule lets it is
    /// stopped, says so, and both apps' banner is told.
    func testARunIsStoppedAfterItsLongestTime() throws {
        var schedule = morning()
        schedule.maxMinutes = 30
        let nine = ScheduleTime.daily(hour: 9, minute: 0).next(after: clock)!
        client.connection.send(.saveSchedule(schedule))
        waitUntil("saved") { self.client.schedules.count == 1 }
        set(nine.addingTimeInterval(5))
        waitUntil("the run") { self.client.sessions.count == 1 }
        set(nine.addingTimeInterval(29 * 60))
        pause(0.6)
        XCTAssertEqual(client.sessions.count, 1, "not before its time is up")
        set(nine.addingTimeInterval(31 * 60))
        waitUntil("stopped") { self.client.sessions.isEmpty }
        waitUntil("said to be") { self.runs.first?.outcome == "Stopped: it ran longer than 30 min" }
        let failure = try XCTUnwrap(client.failures.last)
        XCTAssertEqual(failure.part, .schedule)
        XCTAssertEqual(failure.name, "Morning review")
        XCTAssertEqual(failure.reason, "Stopped: it ran longer than 30 min.")
        XCTAssertTrue(failure.headline().hasPrefix("A run of the schedule “Morning review” did not go as planned"))
        // Saved wrongly: refused in words.
        schedule.maxMinutes = 0
        client.connection.send(.saveSchedule(schedule))
        waitUntil("refused") { self.client.errors.contains("The longest a run may take is at least a minute.") }
    }

    /// SCHED-24: a schedule that runs only when the folder has changes is
    /// skipped when it has none, and says so; one that runs after a pull is
    /// not started when there is nothing to pull from, which the banner says.
    func testARunStartsOnlyWhenThereIsSomethingToDo() throws {
        try repository()
        var schedule = morning()
        schedule.condition = .whenChanged
        let nine = ScheduleTime.daily(hour: 9, minute: 0).next(after: clock)!
        client.connection.send(.saveSchedule(schedule))
        waitUntil("saved") { self.client.schedules.count == 1 }
        set(nine.addingTimeInterval(5))
        waitUntil("skipped") { self.runs.map(\.note) == ["Skipped: nothing is changed in the folder"] }
        XCTAssertEqual(client.sessions.count, 0)
        XCTAssertEqual(client.failures.count, 0, "a run that is skipped as it was told to is no failure")
        // The next day, with a change.
        try "changed\n".write(to: project.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        set(nine.addingTimeInterval(24 * 3600 + 5))
        waitUntil("run") { self.client.sessions.count == 1 }
        waitUntil("recorded") { self.runs.count == 2 && self.runs.last?.started == true }

        // After a pull, in a repository that follows nothing: said, in the list and in the banner.
        client.connection.send(.kill(session: try XCTUnwrap(client.sessions.first?.id)))
        waitUntil("ended") { self.client.sessions.isEmpty }
        schedule.condition = .afterPull
        client.connection.send(.saveSchedule(schedule))
        waitUntil("saved again") { self.client.schedules.first?.condition == .afterPull }
        set(nine.addingTimeInterval(48 * 3600 + 5))
        waitUntil("not started") { self.runs.last?.note.hasPrefix("Not started: the pull failed.") == true }
        XCTAssertEqual(client.sessions.count, 0)
        waitUntil("the banner told") { self.client.failures.last?.part == .schedule }
        XCTAssertEqual(client.failures.last?.name, "Morning review")
    }

    /// SCHED-25: after a pull that brought new commits the run starts;
    /// after one that brought none it is skipped.
    func testARunStartsAfterAPullThatBroughtNewCommits() throws {
        try repository()
        let remote = root.appendingPathComponent("remote.git")
        git("init", "-q", "--bare", "-b", "main", remote.path)
        git("remote", "add", "origin", remote.path)
        git("push", "-q", "-u", "origin", "main")
        var schedule = morning()
        schedule.condition = .afterPull
        let nine = ScheduleTime.daily(hour: 9, minute: 0).next(after: clock)!
        client.connection.send(.saveSchedule(schedule))
        waitUntil("saved") { self.client.schedules.count == 1 }
        set(nine.addingTimeInterval(5))
        waitUntil("skipped") { self.runs.map(\.note) == ["Skipped: the pull brought nothing new"] }

        // Someone else pushes.
        let other = root.appendingPathComponent("other")
        git("clone", "-q", remote.path, other.path)
        git("config", "user.name", "Other", in: other)
        git("config", "user.email", "other@example.com", in: other)
        try "theirs\n".write(to: other.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        git("add", ".", in: other)
        git("commit", "-q", "-m", "theirs", in: other)
        git("push", "-q", in: other)
        set(nine.addingTimeInterval(24 * 3600 + 5))
        waitUntil("run") { self.client.sessions.count == 1 }
        XCTAssertTrue(FileManager.default.fileExists(atPath: project.appendingPathComponent("b.txt").path), "pulled first")
    }

    /// SCHED-26: a schedule whose runs have a worktree of their own starts
    /// its agent there, on a branch named after it, and says where; the
    /// folder itself is left as it is.
    func testARunInAWorktreeOfItsOwn() throws {
        try repository()
        var schedule = morning()
        schedule.inWorktree = true
        client.connection.send(.saveSchedule(schedule))
        waitUntil("saved") { self.client.schedules.count == 1 }
        client.connection.send(.runSchedule(id: "s-claude"))
        waitUntil("the run's session") { self.client.sessions.count == 1 }
        let session = try XCTUnwrap(client.sessions.first)
        XCTAssertTrue(session.cwd.contains("/.agentterm/worktrees/schedule/morning-review-"), session.cwd)
        XCTAssertTrue(WorktreePath.belongs(session.cwd, to: project.path))
        waitUntil("recorded with its worktree") { self.runs.first?.worktree == session.cwd }
        waitUntil("started there") { self.startedLines.first?.contains("/.agentterm/worktrees/schedule/morning-review-") == true }
        XCTAssertTrue(git("branch", "--list", "schedule/*").contains("schedule/morning-review-"))
        XCTAssertEqual(git("status", "--porcelain"), "", "the folder itself is untouched")
        // Kept for review once the run is over.
        client.connection.send(.kill(session: session.id))
        waitUntil("ended") { self.client.sessions.isEmpty }
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.cwd))
    }

    /// SCHED-27: a schedule is duplicated, turned off; all are paused, and
    /// none comes due meanwhile nor is caught up afterwards; what is
    /// changed about a schedule is kept with it.
    func testSchedulesAreDuplicatedPausedAndKeepTheirChanges() throws {
        let nine = ScheduleTime.daily(hour: 9, minute: 0).next(after: clock)!
        client.connection.send(.saveSchedule(morning()))
        waitUntil("saved") { self.client.schedules.count == 1 }
        XCTAssertEqual(client.paused, false)
        XCTAssertEqual(client.schedules.first?.edits, [], "making it is not a change to it")

        client.connection.send(.duplicateSchedule(id: "s-claude"))
        waitUntil("the copy") { self.client.schedules.count == 2 }
        let copy = try XCTUnwrap(client.schedules.last)
        XCTAssertEqual(copy.name, "Morning review copy")
        XCTAssertFalse(copy.enabled)
        XCTAssertNotEqual(copy.id, "s-claude")
        XCTAssertNil(copy.nextRun)

        // Changed: when, and how long it may take.
        var changed = morning()
        changed.when = .every(minutes: 120, from: 9 * 60, until: 18 * 60)
        changed.maxMinutes = 45
        client.connection.send(.saveSchedule(changed))
        waitUntil("its changes kept") { self.client.schedules.first?.edits.count == 1 }
        XCTAssertEqual(client.schedules.first?.edits.first?.what, ["When: Every day at 09:00 → Every 2 hours, 09:00 to 18:00", "A run is now stopped after 45 min"])
        XCTAssertEqual(client.schedules.first?.nextRun, nine)
        changed.when = .every(minutes: 2, from: nil, until: nil)
        client.connection.send(.saveSchedule(changed))
        waitUntil("too often") { self.client.errors.contains("A schedule runs every 5 minutes at the most often.") }

        // Paused: nothing comes due.
        client.connection.send(.pauseSchedules(true))
        waitUntil("paused") { self.client.paused == true && self.client.schedules.first?.nextRun == nil }
        set(nine.addingTimeInterval(5))
        pause(0.6)
        XCTAssertEqual(client.sessions.count, 0)
        XCTAssertEqual(runs, [])
        // Let go again after eleven: the run of nine is not caught up; the next is at eleven.
        set(nine.addingTimeInterval(30 * 60))
        client.connection.send(.pauseSchedules(false))
        waitUntil("running again") { self.client.paused == false && self.client.schedules.first?.nextRun == nine.addingTimeInterval(2 * 3600) }
        pause(0.6)
        XCTAssertEqual(client.sessions.count, 0)
        set(nine.addingTimeInterval(2 * 3600 + 5))
        waitUntil("the run of eleven") { self.client.sessions.count == 1 }
    }
}
