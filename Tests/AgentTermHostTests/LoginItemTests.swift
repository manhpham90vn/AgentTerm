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
        // The app starts the host again when it stops; launchd must not, or there would be two.
        XCTAssertNil(written["KeepAlive"])
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

    /// A program that is there, standing in for a host's.
    private func program(_ name: String) throws -> String {
        let file = folder.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return file.path
    }

    /// LOGIN-4.
    func testAnAppThatMovedIsStartedFromWhereItIsNow() throws {
        // Where the app was when the switch was turned on: nothing is there now.
        try item(executable: folder.appendingPathComponent("Old/agenttermd").path).turnOn()
        let moved = item(executable: try program("New/agenttermd"))
        moved.refresh()
        let written = try XCTUnwrap(NSDictionary(contentsOf: moved.file) as? [String: Any])
        XCTAssertEqual((written["ProgramArguments"] as? [String])?.first, moved.executable)
        // One that is off stays off.
        try moved.turnOff()
        moved.refresh()
        XCTAssertFalse(moved.isOn)
    }

    /// LOGIN-5.
    func testAnotherHostThatIsRunDoesNotTakeTheLoginItem() throws {
        let installed = item(executable: try program("Installed/agenttermd"))
        try installed.turnOn()
        // Another copy, and the same one started by hand in another way.
        item(executable: try program("Build/agenttermd")).refresh()
        item(executable: installed.executable, arguments: ["--port", "7800", "--local-only"]).refresh()
        let written = try XCTUnwrap(NSDictionary(contentsOf: installed.file) as? [String: Any])
        XCTAssertEqual(written["ProgramArguments"] as? [String], [installed.executable, "--port", "7717"])
    }

    func testAHostWithFilesOfItsOwnHasNoLoginItem() {
        XCTAssertNil(LoginItem.forThisHost(environment: ["AGENTTERM_STATE_DIR": "/tmp/somewhere"]))
    }
}
