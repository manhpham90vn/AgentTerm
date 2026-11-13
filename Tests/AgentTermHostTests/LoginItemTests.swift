import XCTest

@testable import AgentTermHost

final class LoginItemTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-login-\(UUID().uuidString)").standardizedFileURL
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    private func item(executable: String = "/Applications/AgentTerm.app/Contents/MacOS/agenttermd", arguments: [String] = ["--port", "7717"]) -> LoginItem {
        LoginItem(
            label: "com.example.host", file: folder.appendingPathComponent("LaunchAgents/com.example.host.plist"), executable: executable,
            arguments: arguments, log: folder.appendingPathComponent("host.log"))
    }

    func testTurningItOnWritesWhatLaunchdStartsAtLogin() throws {
        let item = item()
        XCTAssertFalse(item.isOn)
        try item.turnOn()
        XCTAssertTrue(item.isOn)
        let written = try XCTUnwrap(NSDictionary(contentsOf: item.file) as? [String: Any])
        XCTAssertEqual(written["Label"] as? String, "com.example.host")
        XCTAssertEqual(written["ProgramArguments"] as? [String], ["/Applications/AgentTerm.app/Contents/MacOS/agenttermd", "--port", "7717"])
        XCTAssertEqual(written["RunAtLoad"] as? Bool, true)
        // launchd starts it again when it crashed or was killed, not when it
        // was stopped as asked (status 0). The app starts it through launchd
        // while this is on, so there is one owner.
        XCTAssertEqual(written["KeepAlive"] as? [String: Bool], ["SuccessfulExit": false])
        XCTAssertNil(written["EnvironmentVariables"], "the real login item sets nothing in the host's environment")
        XCTAssertEqual(written["StandardOutPath"] as? String, item.log.path)
        // And it is a property list launchd's own tool accepts.
        let lint = Process()
        lint.executableURL = URL(fileURLWithPath: "/usr/bin/plutil")
        lint.arguments = ["-lint", item.file.path]
        lint.standardOutput = FileHandle.nullDevice
        try lint.run()
        lint.waitUntilExit()
        XCTAssertEqual(lint.terminationStatus, 0)

        try item.turnOff()
        XCTAssertFalse(item.isOn)
        // Off twice is still off.
        XCTAssertNoThrow(try item.turnOff())
    }

    /// LOGIN-4.
    /// LOGIN-9: Start at Login is on by default, the first time a host that
    /// can be started at login runs; once the user turned it off, it stays off.
    func testItIsOnByDefaultUntilTheUserChooses() throws {
        let item = item()
        var configuration = HostServer.Configuration(port: 0, token: "test-token-0123456789abcdef0123456789", listenOnTailscale: false, detectAgents: { [] })
        configuration.foldersFile = folder.appendingPathComponent("state/folders.json")
        configuration.loginItem = item
        var server = HostServer(configuration: configuration)
        _ = try server.start()
        XCTAssertTrue(item.isOn, "on by default")
        server.stop()

        // The user turns it off; the next host leaves it off.
        try item.turnOff()
        let saved = folder.appendingPathComponent("state/settings.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.path))
        server = HostServer(configuration: configuration)
        _ = try server.start()
        XCTAssertFalse(item.isOn, "the user's choice is kept")
        server.stop()
    }

    func testAnAppThatMovedIsStartedFromWhereItIsNow() throws {
        try item().turnOn()
        let moved = item(executable: "/Users/me/Applications/AgentTerm.app/Contents/MacOS/agenttermd")
        moved.refresh()
        let written = try XCTUnwrap(NSDictionary(contentsOf: moved.file) as? [String: Any])
        XCTAssertEqual((written["ProgramArguments"] as? [String])?.first, "/Users/me/Applications/AgentTerm.app/Contents/MacOS/agenttermd")
        // One that is off stays off.
        try moved.turnOff()
        moved.refresh()
        XCTAssertFalse(moved.isOn)
    }

    /// LOGIN-5.
    func testAHostRunByHandDoesNotTakeTheLoginItem() throws {
        let installed = item()
        try installed.turnOn()
        // A build that is not part of an app, and the installed host itself
        // started in another way.
        item(executable: "/Users/me/AgentTerm/.build/debug/agenttermd").refresh()
        item(arguments: ["--port", "7800", "--local-only"]).refresh()
        let written = try XCTUnwrap(NSDictionary(contentsOf: installed.file) as? [String: Any])
        XCTAssertEqual(written["ProgramArguments"] as? [String], [installed.executable, "--port", "7717"])
    }

    func testAHostWithFilesOfItsOwnHasNoLoginItem() {
        XCTAssertNil(LoginItem.forThisHost(environment: ["AGENTTERM_STATE_DIR": "/tmp/somewhere"]))
        XCTAssertNil(LoginItem.forHost(executable: "/Applications/AgentTerm.app/Contents/MacOS/agenttermd", arguments: [], environment: ["AGENTTERM_STATE_DIR": "/tmp/somewhere"]))
    }

    /// LOGIN-8: a launch agent written by 0.5.0, which launchd did not keep
    /// alive, is written again as this version writes it by the host it names.
    func testALaunchAgentOfAnEarlierVersionIsBroughtUpToDate() throws {
        let item = item()
        try FileManager.default.createDirectory(at: item.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var old = item.propertyList
        old["KeepAlive"] = nil
        try PropertyListSerialization.data(fromPropertyList: old, format: .xml, options: 0).write(to: item.file)
        item.refresh()
        let written = try XCTUnwrap(NSDictionary(contentsOf: item.file) as? [String: Any])
        XCTAssertEqual(written["KeepAlive"] as? [String: Bool], ["SuccessfulExit": false])
        // Not by the same host started by hand with other arguments (LOGIN-5).
        try PropertyListSerialization.data(fromPropertyList: old, format: .xml, options: 0).write(to: item.file)
        self.item(arguments: ["--port", "7800", "--local-only"]).refresh()
        XCTAssertNil((NSDictionary(contentsOf: item.file) as? [String: Any])?["KeepAlive"])
    }

    func testWhatLaunchdSaysOfAJobIsRead() {
        let printed = """
            {
            \t"LimitLoadToSessionType" = "Aqua";
            \t"Label" = "com.example.host";
            \t"LastExitStatus" = 9;
            \t"PID" = 4711;
            };
            """
        XCTAssertEqual(LoginItem.number("PID", in: printed), 4711)
        XCTAssertEqual(LoginItem.number("LastExitStatus", in: printed), 9)
        XCTAssertNil(LoginItem.number("Missing", in: printed))
    }
}
