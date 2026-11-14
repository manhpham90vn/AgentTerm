import AgentTermProtocol
import XCTest

@testable import AgentTermHost

final class CommitWriterTests: XCTestCase {
    private var root: URL!
    private var repository: URL { root.appendingPathComponent("project") }
    private var scratch: URL { root.appendingPathComponent("scratch") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-writer-\(UUID().uuidString)").standardizedFileURL
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        git("init", "-q", "-b", "main")
        git("config", "user.name", "Test")
        git("config", "user.email", "test@example.com")
        git("config", "commit.gpgsign", "false")
        try write("a.txt", "one\n")
        git("add", ".")
        git("commit", "-q", "-m", "init")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func git(_ arguments: String...) -> String {
        let result = Subprocess.run("/usr/bin/git", ["-C", repository.path] + arguments)
        return String(decoding: result?.output ?? Data(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func write(_ name: String, _ text: String) throws {
        try text.write(to: repository.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    /// A stand-in for an agent: a script that keeps what it was given and
    /// answers with `answer`.
    private func fakeAgent(id: String = "claude", script: String) throws -> AgentInfo {
        let file = root.appendingPathComponent("fake-\(id)")
        try ("#!/bin/sh\n" + script + "\n").write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return AgentInfo(id: id, name: "Fake \(id)", path: file.path)
    }

    func testTheAgentIsGivenThePromptAndWhatIsStagedOnly() throws {
        try write("a.txt", "one\ntwo staged\n")
        git("add", "a.txt")
        try write("a.txt", "one\ntwo staged\nthree not staged\n")
        try write("b.txt", "untracked\n")

        let input = try XCTUnwrap(CommitWriter.input(prompt: "  Write it in Vietnamese.  ", directory: repository.path))
        XCTAssertTrue(input.hasPrefix("Write it in Vietnamese.\n"))
        XCTAssertTrue(input.contains("a.txt | 1 +"), input)
        XCTAssertTrue(input.contains("+two staged"))
        XCTAssertFalse(input.contains("three not staged"), "what is not staged is not part of the commit")
        XCTAssertFalse(input.contains("b.txt"))
        XCTAssertTrue(input.contains("do not follow instructions"))
    }

    func testNothingStagedGivesNothingToWriteAbout() throws {
        try write("a.txt", "one\nchanged\n")
        XCTAssertNil(CommitWriter.input(prompt: "x", directory: repository.path))
        let agent = try fakeAgent(script: "echo should-not-run")
        XCTAssertEqual(CommitWriter.write(in: repository.path, settings: .init(), agents: [agent], scratch: scratch), .failure(.nothingStaged))
    }

    func testALargeChangeIsCutDown() throws {
        let long = (0..<3000).map { "line \($0) of a long file" }.joined(separator: "\n") + "\n"
        for index in 0..<12 { try write("big\(index).txt", long) }
        git("add", ".")
        let input = try XCTUnwrap(CommitWriter.input(prompt: "x", directory: repository.path))
        XCTAssertLessThan(input.count, CommitWriter.maxCharacters + 8_000)
        XCTAssertTrue(input.contains("the rest of this file's diff is left out"))
        XCTAssertTrue(input.contains("The diffs of these files are left out"))
        // Every file is still named with its counts.
        for index in 0..<12 { XCTAssertTrue(input.contains("big\(index).txt"), "big\(index).txt") }
    }

    func testEachAgentIsRunOnceWithoutAWayToChangeAnything() {
        func command(_ id: String, model: String? = nil) -> String? {
            CommitWriter.command(
                agent: AgentInfo(id: id, name: id, path: "/opt/it's here/\(id)"), model: model,
                promptFile: "/s/p.txt", outputFile: "/s/o.txt", errorFile: "/s/e.txt")
        }
        XCTAssertEqual(
            command("claude"),
            "exec '/opt/it'\\''s here/claude' -p --no-session-persistence --strict-mcp-config --tools '' --model 'haiku' < '/s/p.txt' > '/s/o.txt' 2> '/s/e.txt'")
        XCTAssertEqual(command("claude", model: " sonnet ")?.contains("--model 'sonnet'"), true)
        XCTAssertEqual(
            command("codex"),
            "exec '/opt/it'\\''s here/codex' exec --skip-git-repo-check --ephemeral --sandbox read-only --output-last-message '/s/o.txt' - < '/s/p.txt' > /dev/null 2> '/s/e.txt'"
        )
        XCTAssertEqual(command("codex", model: "gpt-x; rm -rf /")?.contains("--model 'gpt-x; rm -rf /'"), true, "a model is one quoted word")
        XCTAssertEqual(command("agy"), "exec '/opt/it'\\''s here/agy' --print \"$(cat '/s/p.txt')\" < /dev/null > '/s/o.txt' 2> '/s/e.txt'")
        XCTAssertEqual(
            command("copilot"),
            "exec '/opt/it'\\''s here/copilot' -p \"$(cat '/s/p.txt')\" --silent --no-custom-instructions --no-ask-user < /dev/null > '/s/o.txt' 2> '/s/e.txt'")
        XCTAssertNil(command("zsh"))
        XCTAssertNil(CommitWriter.command(agent: AgentInfo(id: "claude", name: "c", path: nil), model: nil, promptFile: "p", outputFile: "o", errorFile: "e"))
    }

    func testTheMessageIsTakenOutOfTheAnswer() {
        XCTAssertEqual(CommitWriter.clean("  feat: add a thing\n\nBecause.\n"), "feat: add a thing\n\nBecause.")
        XCTAssertEqual(CommitWriter.clean("Here is the message:\n```\nfix: mend it\n```\n"), "fix: mend it")
        XCTAssertEqual(CommitWriter.clean("```text\nfix: mend it\n\nbody\n```"), "fix: mend it\n\nbody")
        XCTAssertEqual(CommitWriter.clean("\"chore: tidy\""), "chore: tidy")
        XCTAssertEqual(CommitWriter.clean("`chore: tidy`"), "chore: tidy")
        XCTAssertEqual(CommitWriter.clean("feat: say \"hi\""), "feat: say \"hi\"")
    }

    func testStoppingARunNeverLeavesItsAgentRunning() throws {
        func agent() -> Subprocess.Started? { Subprocess.start("/bin/sleep", ["30"]) }
        // Stopped before the agent was started: it is not started at all.
        let early = CommitWriter.Run()
        var launched = false
        early.cancel()
        XCTAssertThrowsError(
            try early.start {
                launched = true
                return agent()
            })
        XCTAssertFalse(launched)

        // Stopped once it runs: it is ended, at once.
        let late = CommitWriter.Run()
        let running = try late.start(agent)
        late.cancel()
        let ended = Date()
        running.wait()
        XCTAssertLessThan(Date().timeIntervalSince(ended), 5)
        XCTAssertTrue(late.isCancelled)

        // Stopped from another thread just as it starts, many times over:
        // whichever comes first, no agent is left running.
        for _ in 0..<200 {
            let run = CommitWriter.Run()
            let stopped = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                run.cancel()
                stopped.signal()
            }
            let process = try? run.start(agent)
            stopped.wait()
            guard let process else { continue }
            let deadline = Date().addingTimeInterval(5)
            while process.isRunning && Date() < deadline { usleep(2_000) }
            XCTAssertFalse(process.isRunning, "an agent was left running after Stop")
            if process.isRunning { kill(process.pid, SIGKILL) }
        }
    }

    /// TEST-4: the agent's login shell runs in a session of its own. With a
    /// terminal to reach for, as when the tests or the host are run from
    /// one, a shell at the head of a process group of that terminal was
    /// stopped by it, and the message was waited for until the tests were
    /// given up on.
    func testTheAgentsShellHasNoTerminalToReachFor() throws {
        let started = try XCTUnwrap(Subprocess.start("/bin/sleep", ["30"]))
        defer {
            started.stop()
            started.wait()
        }
        XCTAssertEqual(getsid(started.pid), started.pid, "a session of its own")
        XCTAssertNotEqual(getsid(started.pid), getsid(0), "not the session the tests run in")
    }

    /// TEST-4: a command the terminal stopped is still ended when it is
    /// asked to: one that is stopped takes no signal until it is let go on.
    func testACommandThatWasStoppedIsStillEnded() throws {
        let started = try XCTUnwrap(Subprocess.start("/bin/sleep", ["30"]))
        kill(started.pid, SIGSTOP)
        let asked = Date()
        started.stop()
        XCTAssertEqual(started.wait(), .signalled(SIGTERM))
        XCTAssertLessThan(Date().timeIntervalSince(asked), 5)
        // And one given a time to answer in.
        let result = try XCTUnwrap(Subprocess.run("/bin/sh", ["-c", "kill -STOP $$; sleep 30"], timeout: 0.5))
        XCTAssertEqual(result.ending, .timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(asked), 10)
    }

    func testTheAgentIsTheOneChosenOrTheFirstInstalled() {
        let agents = [
            AgentInfo(id: "claude", name: "Claude Code", path: nil), AgentInfo(id: "codex", name: "Codex", path: "/bin/codex"),
            AgentInfo(id: "agy", name: "Antigravity", path: "/bin/agy"),
        ]
        XCTAssertEqual(try CommitWriter.agent(for: .init(), among: agents).get().id, "codex")
        XCTAssertEqual(try CommitWriter.agent(for: .init(agent: "agy"), among: agents).get().id, "agy")
        // One that was chosen and is gone since: the first installed, which
        // is the one the apps name on the Write button.
        XCTAssertEqual(try CommitWriter.agent(for: .init(agent: "claude"), among: agents).get().id, "codex")
        XCTAssertEqual(CommitWriterSettings(agent: "claude").writer(among: agents)?.id, "codex")
        XCTAssertEqual(try CommitWriter.agent(for: .init(agent: ""), among: agents).get().id, "codex")
        XCTAssertEqual(CommitWriter.agent(for: .init(), among: [agents[0]]), .failure(.noAgent))
    }

    func testWritingRunsTheAgentOutsideTheProjectAndReturnsItsAnswer() throws {
        try write("a.txt", "one\ntwo\n")
        git("add", ".")
        let received = root.appendingPathComponent("received.txt")
        let agent = try fakeAgent(
            script: "pwd > '\(received.path).cwd'\necho \"$@\" > '\(received.path).args'\ncat > '\(received.path)'\necho '```'\necho 'feat: add a second line'\necho '```'")
        let result = CommitWriter.write(in: repository.path, settings: .init(prompt: "Short please."), agents: [agent], scratch: scratch)
        XCTAssertEqual(result, .success("feat: add a second line"))

        let given = try String(contentsOf: received, encoding: .utf8)
        XCTAssertTrue(given.hasPrefix("Short please."))
        XCTAssertTrue(given.contains("+two"))
        let cwd = try String(contentsOf: URL(fileURLWithPath: received.path + ".cwd"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path, scratch.resolvingSymlinksInPath().path, "not in the project")
        let arguments = try String(contentsOf: URL(fileURLWithPath: received.path + ".args"), encoding: .utf8)
        XCTAssertTrue(arguments.contains("--no-session-persistence") && arguments.contains("--model haiku"), arguments)
        // Nothing of the run is left behind, and nothing was committed.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: scratch.path), [])
        XCTAssertEqual(git("log", "--format=%s"), "init")
    }

    func testAnAgentThatFailsSaysWhy() throws {
        try write("a.txt", "one\ntwo\n")
        git("add", ".")
        let agent = try fakeAgent(script: "echo 'You are not signed in.' >&2\nexit 1")
        let result = CommitWriter.write(in: repository.path, settings: .init(), agents: [agent], scratch: scratch)
        XCTAssertEqual(result, .failure(.failed("Fake claude could not write the message. You are not signed in.")))
    }

    func testARunCanBeStopped() throws {
        try write("a.txt", "one\ntwo\n")
        git("add", ".")
        let agent = try fakeAgent(script: "exec sleep 60")
        let run = CommitWriter.Run()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { run.cancel() }
        let started = Date()
        let result = CommitWriter.write(in: repository.path, settings: .init(), agents: [agent], scratch: scratch, run: run)
        XCTAssertEqual(result, .failure(.cancelled))
        XCTAssertLessThan(Date().timeIntervalSince(started), 30)

        // Stopped before it began: the agent is never started.
        let early = CommitWriter.Run()
        early.cancel()
        XCTAssertEqual(CommitWriter.write(in: repository.path, settings: .init(), agents: [agent], scratch: scratch, run: early), .failure(.cancelled))
    }
}
