import AgentTermProtocol
import Darwin
import XCTest

@testable import AgentTermHost

/// The host started at login, as launchd runs it. These load a launch agent
/// of the test's own into the user's launchd: a label no app uses, a
/// property list in the test's folder (never `~/Library/LaunchAgents`), a
/// state folder, a home and a port of the test's own. What they load they
/// unload.
final class LaunchdHostTests: XCTestCase {
    private var root: URL!
    private var state: URL!
    private var port: UInt16 = 0
    private var item: LoginItem!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-launchd-\(UUID().uuidString.prefix(8))").standardizedFileURL
        state = root.appendingPathComponent("state")
        let home = root.appendingPathComponent("home")
        for folder in [state!, home] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        port = try Self.freePort()
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: executable.path), "agenttermd is not built next to the tests")
        let label = "com.example.agentterm-test.\(UUID().uuidString.prefix(8).lowercased())"
        // Never a label of the apps, whose jobs are the user's.
        precondition(!label.hasPrefix(AppChannel.releaseBundleIdentifier))
        item = LoginItem(
            label: label, file: root.appendingPathComponent("LaunchAgents/\(label).plist"), executable: executable.path,
            arguments: ["--port", String(port), "--local-only", "--no-account-usage", "--home", home.path, "--agents", root.appendingPathComponent("agents").path],
            log: root.appendingPathComponent("host.log"), environment: ["AGENTTERM_STATE_DIR": state.path])
    }

    override func tearDown() {
        if let item {
            item.unload()
            // A host spawned by a test rather than by launchd: only one on
            // this test's own port, with this test's own state folder.
            if let listener = DaemonLauncher.listener(onPort: port), listener.path.hasSuffix("/agenttermd") { kill(listener.pid, SIGTERM) }
        }
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private var executable: URL { Bundle(for: LaunchdHostTests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("agenttermd") }

    private static func freePort() throws -> UInt16 {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        defer { close(socket) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(socket, $0, length) == 0 && getsockname(socket, $0, &length) == 0 }
        }
        guard bound else { throw XCTSkip("no free port") }
        return UInt16(bigEndian: address.sin_port)
    }

    /// The host that listens on the test's port, if one does.
    private var host: pid_t? { DaemonLauncher.listener(onPort: port)?.pid }

    @discardableResult
    private func waitFor<T>(_ what: String, timeout: TimeInterval, _ value: () -> T?) -> T? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let found = value() { return found }
            usleep(200_000)
        }
        XCTFail("timed out waiting for: \(what)")
        return nil
    }

    /// LOGIN-6: with the app closed, launchd watches the host it started at
    /// login: one that is killed is started again; one that is stopped as
    /// asked (SIGTERM: logging out, Restart Host) is not.
    func testLaunchdStartsAKilledHostAgainButNotOneThatWasStopped() throws {
        try item.turnOn()
        try item.load()
        let first = try XCTUnwrap(waitFor("launchd to start the host", timeout: 15) { host })
        XCTAssertEqual(item.jobState()?.pid, first, "the host is launchd's")

        kill(first, SIGKILL)
        // launchd waits ten seconds from the last start before it starts a
        // job again (its throttle).
        let second = try XCTUnwrap(waitFor("launchd to start the killed host again", timeout: 25) { host.flatMap { $0 == first ? nil : $0 } })
        XCTAssertEqual(item.jobState()?.lastExitStatus, SIGKILL, "launchd says how the last one ended")

        kill(second, SIGTERM)
        waitFor("the host to stop", timeout: 10) { host == nil ? true : nil }
        // Longer than launchd's throttle: it would have started it by now.
        Thread.sleep(forTimeInterval: 12)
        XCTAssertNil(host, "a host that was stopped as asked is not started again")
        XCTAssertEqual(item.jobState()?.pid, nil)
        XCTAssertEqual(item.jobState()?.lastExitStatus, 0)
    }

    private func startHost() -> (start: DaemonLauncher.Start, lastExit: Int32?) {
        var environment = ProcessInfo.processInfo.environment
        environment["AGENTTERM_STATE_DIR"] = state.path
        let result = DaemonLauncher.startHost(
            executable: item.executable, arguments: item.arguments, loginItem: item, environment: environment, log: item.log)
        if case .spawned(let pid) = result.start { DaemonLauncher.watch(pid) { _ in } }
        return result
    }

    /// LOGIN-7: while Start at Login is on, the app starts the host through
    /// launchd, so there is one owner; a host launchd is waiting to start
    /// again (its ten-second throttle) is started at once; with the switch
    /// off, the app starts its own and launchd is left with nothing to start.
    func testTheAppStartsTheHostThroughLaunchdWhileStartAtLoginIsOn() throws {
        try item.turnOn()
        XCTAssertEqual(startHost().start, .launchd)
        let first = try XCTUnwrap(waitFor("launchd to start the host", timeout: 15) { host })
        XCTAssertEqual(item.jobState()?.pid, first, "the host is launchd's")
        XCTAssertEqual(startHost().start, .running, "a host that runs is not started twice")
        XCTAssertEqual(host, first)

        // Killed within ten seconds of its start: launchd would wait.
        kill(first, SIGKILL)
        waitFor("the host to be gone", timeout: 5) { host == first ? nil : true }
        let restartedAt = Date()
        let again = startHost()
        XCTAssertEqual(again.lastExit, SIGKILL, "how the last one ended, for the app to say")
        let second = try XCTUnwrap(waitFor("the host to be started again", timeout: 15) { host.flatMap { $0 == first ? nil : $0 } })
        XCTAssertLessThan(Date().timeIntervalSince(restartedAt), 5, "not held back by launchd's throttle")
        XCTAssertEqual(item.jobState()?.pid, second)

        // Start at Login turned off while launchd runs the host: it runs on.
        try item.turnOff()
        XCTAssertEqual(item.jobState()?.pid, second)
        // Once it stops, the app starts its own, and launchd has no job left
        // to start a second one with.
        kill(second, SIGTERM)
        waitFor("the host to stop", timeout: 10) { host == nil ? true : nil }
        guard case .spawned(let pid) = startHost().start else { return XCTFail("the app starts its own host") }
        XCTAssertNil(item.jobState(), "launchd no longer has the job")
        XCTAssertEqual(waitFor("the app's host", timeout: 15) { host }, pid)
    }
}
