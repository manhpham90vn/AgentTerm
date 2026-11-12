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

        try item.turnOff()
        XCTAssertFalse(item.isOn)
        // Off twice is still off.
        XCTAssertNoThrow(try item.turnOff())
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

    func testAHostWithFilesOfItsOwnHasNoLoginItem() {
        XCTAssertNil(LoginItem.forThisHost(environment: ["AGENTTERM_STATE_DIR": "/tmp/somewhere"]))
    }
}
