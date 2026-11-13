import AgentTermClient
import AgentTermProtocol
import XCTest

@testable import AgentTermHost

/// The parts other than the host that stop without being asked to: a
/// session's program, the hold that keeps the Mac awake, the status line
/// relay (#20). Each is reported to every client, as a host that died is.
final class PartFailureTests: XCTestCase {
    private final class Client {
        let connection: AgentTermConnection
        var messages: [ServerMessage] = []

        init(port: UInt16, token: String) {
            connection = AgentTermConnection(host: "127.0.0.1", port: port, credential: .token(token), clientName: "phone")
            connection.onMessage = { [weak self] in self?.messages.append($0) }
            connection.connect()
        }

        var failures: [PartFailure] { messages.compactMap { if case .failures(let list) = $0 { return list } else { return nil } }.last ?? [] }
        var sessions: [SessionInfo] { messages.compactMap { if case .sessions(let list) = $0 { return list } else { return nil } }.last ?? [] }
    }

    private var root: URL!
    private var server: HostServer!
    private var client: Client!
    private let token = "test-token-0123456789abcdef0123456789"
    /// What the stand-in hold on sleep answers.
    private var holdGiven = true
    private let holdLock = NSLock()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-parts-\(UUID().uuidString)").standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // A stand-in for Claude Code: the host takes it for one by its name,
        // and gives it the status line relay. It only waits.
        let claude = root.appendingPathComponent("claude")
        try "#!/bin/sh\nexec sleep 600\n".write(to: claude, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)

        var configuration = HostServer.Configuration(
            port: 0, token: token, listenOnTailscale: false, detectAgents: { [] }, statusLineTool: "/usr/bin/true",
            usageDirectory: root.appendingPathComponent("usage"))
        configuration.refreshInterval = 0.2
        configuration.holdAwake = { [weak self] held, _ in
            guard let self, held else { return true }
            self.holdLock.lock()
            defer { self.holdLock.unlock() }
            return self.holdGiven
        }
        server = HostServer(configuration: configuration)
        let port = try server.start()
        client = Client(port: port, token: token)
        waitUntil("connected") { self.client.messages.contains { if case .welcome = $0 { return true } else { return false } } }
    }

    override func tearDown() {
        server?.stop()
        try? FileManager.default.removeItem(at: root)
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 10, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertTrue(condition(), "timed out waiting for: \(what)")
    }

    /// Starts a session whose program only waits, under a number of its own
    /// so that it can be found and killed, and returns that number.
    private func startWaitingSession(title: String) -> Int {
        let seconds = Int.random(in: 610_000..<690_000)
        let before = client.sessions.count
        client.connection.send(.create(CreateRequest(command: "exec sleep \(seconds)", cwd: root.path, title: title)))
        waitUntil("the session to start") { self.client.sessions.count == before + 1 }
        waitUntil("its program to run") { !self.pids(of: seconds).isEmpty }
        return seconds
    }

    /// The processes running `sleep <seconds>` and nothing else.
    private func pids(of seconds: Int) -> [pid_t] {
        guard let result = Subprocess.run("/usr/bin/pgrep", ["-x", "-f", "sleep \(seconds)"], timeout: 5) else { return [] }
        return String(decoding: result.output, as: UTF8.self).split(whereSeparator: \.isNewline).compactMap { pid_t($0) }
    }

    // MARK: - A session's program

    /// SES-23: a program that is killed is reported; its session ends.
    func testAProgramThatWasKilledIsReported() throws {
        let seconds = startWaitingSession(title: "build")
        for pid in pids(of: seconds) { kill(pid, SIGKILL) }

        waitUntil("the report") { !self.client.failures.isEmpty }
        let failure = try XCTUnwrap(client.failures.first)
        XCTAssertEqual(failure.part, .session)
        XCTAssertEqual(failure.name, "build")
        XCTAssertEqual(failure.ended.map(\.name), ["build"])
        XCTAssertFalse(failure.restarted, "a session's program is not started again")
        XCTAssertEqual(failure.reason?.contains("killed (SIGKILL)"), true, failure.reason ?? "")
        waitUntil("the session to be gone") { self.client.sessions.isEmpty }
    }

    /// SES-24: a program closed from a device, or stopped by Control C, is
    /// not reported, though closing ends with SIGKILL when it will not quit.
    func testAProgramThatWasAskedToEndIsNotReported() throws {
        // One that ignores the hang-up, so that closing has to kill it.
        let stubborn = Int.random(in: 610_000..<690_000)
        client.connection.send(.create(CreateRequest(command: "trap '' HUP; exec sleep \(stubborn)", cwd: root.path, title: "stubborn")))
        waitUntil("its program to run") { !self.pids(of: stubborn).isEmpty }
        let id = try XCTUnwrap(client.sessions.first { $0.title == "stubborn" }?.id)
        client.connection.send(.kill(session: id))
        waitUntil("the closed session to be gone", timeout: 15) { !self.client.sessions.contains { $0.id == id } }

        let interrupted = startWaitingSession(title: "interrupted")
        for pid in pids(of: interrupted) { kill(pid, SIGINT) }
        waitUntil("the interrupted session to be gone") { !self.client.sessions.contains { $0.title == "interrupted" } }

        // Long enough for a report to have come.
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertEqual(client.failures, [])
    }

    func testWhichEndsAreUnexpected() {
        XCTAssertNotNil(HostServer.unexpectedEnd(code: 128 + SIGKILL))
        XCTAssertNotNil(HostServer.unexpectedEnd(code: 128 + SIGSEGV))
        XCTAssertNotNil(HostServer.unexpectedEnd(code: 128 + SIGABRT))
        // Ended by itself, by Control C, by a hang-up, by a request to stop.
        for code in [0, 1, 2, 127, 128 + SIGINT, 128 + SIGHUP, 128 + SIGTERM] {
            XCTAssertNil(HostServer.unexpectedEnd(code: Int32(code)), "\(code)")
        }
    }

    // MARK: - The hold that keeps the Mac awake

    /// AWAKE-4: a hold macOS refuses is reported once, and the report says
    /// so when it is held again.
    func testAHoldThatIsRefusedIsReportedUntilItIsHeld() throws {
        holdLock.lock()
        holdGiven = false
        holdLock.unlock()
        client.connection.send(.setKeepAwake(true))
        _ = startWaitingSession(title: "build")

        waitUntil("the report") { self.client.failures.contains { $0.part == .keepAwake } }
        // Asked for again on every refresh, and still reported once.
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        XCTAssertEqual(client.failures.filter { $0.part == .keepAwake }.count, 1)
        XCTAssertEqual(client.failures.first?.restarted, false)

        holdLock.lock()
        holdGiven = true
        holdLock.unlock()
        waitUntil("the report to say it is held again") { self.client.failures.first { $0.part == .keepAwake }?.restarted == true }
        XCTAssertEqual(client.failures.count, 1)
    }

    // MARK: - The status line relay

    /// USE-5: usage the relay could not save is reported once for the
    /// session, and again only after it saved in between.
    func testUsageTheRelayCouldNotSaveIsReported() throws {
        client.connection.send(.create(CreateRequest(command: root.appendingPathComponent("claude").path, cwd: root.path, title: "review")))
        waitUntil("the session to start") { self.client.sessions.count == 1 }
        let session = try XCTUnwrap(client.sessions.first)
        XCTAssertEqual(session.agent, "claude")
        let usage = root.appendingPathComponent("usage/session-\(session.id).json")
        try FileManager.default.createDirectory(at: usage.deletingLastPathComponent(), withIntermediateDirectories: true)
        // What the relay leaves when it cannot save.
        try "You don’t have permission.".write(toFile: StatusLineRelay.failureFile(for: usage.path), atomically: true, encoding: .utf8)

        waitUntil("the report") { self.client.failures.contains { $0.part == .statusLine } }
        let failure = try XCTUnwrap(client.failures.first)
        XCTAssertEqual(failure.name, "review")
        XCTAssertEqual(failure.reason?.contains("You don’t have permission."), true, failure.reason ?? "")
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        XCTAssertEqual(client.failures.count, 1, "reported once while it stays so")

        // Saved again, then not again: a second report.
        try FileManager.default.removeItem(atPath: StatusLineRelay.failureFile(for: usage.path))
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        try "Disk full.".write(toFile: StatusLineRelay.failureFile(for: usage.path), atomically: true, encoding: .utf8)
        waitUntil("the second report") { self.client.failures.count == 2 }
    }
}
