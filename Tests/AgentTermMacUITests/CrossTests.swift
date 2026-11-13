import AgentTermClient
import AgentTermProtocol
import XCTest

/// The Mac app's half of the test that runs it together with the iPhone
/// app on one host. `scripts/test-both.sh` starts the host and both apps
/// and runs this in two parts, the iPhone app's own test in between: what
/// one app does, the other has to show.
final class CrossTests: XCTestCase {
    private var app: MacDriver!
    private let environment = ProcessInfo.processInfo.environment
    private var project: URL { URL(fileURLWithPath: environment["AGENTTERM_CROSS_PROJECT"] ?? "") }

    override func setUpWithError() throws {
        try XCTSkipUnless(environment["AGENTTERM_CROSS_PID"] != nil, "run through scripts/test-both.sh")
        let pid = try XCTUnwrap(environment["AGENTTERM_CROSS_PID"].flatMap { pid_t($0) })
        try XCTSkipUnless(MacDriver.isAllowed, "allow this terminal under System Settings > Privacy & Security > Accessibility")
        continueAfterFailure = false
        app = MacDriver(pid: pid)
        app.wait(for: .id("mac-switcher"), timeout: 20)
    }

    override func tearDown() {
        if let run = testRun, run.failureCount > 0, let folder = environment["AGENTTERM_SHOT_DIR"], let app {
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            app.capture(to: URL(fileURLWithPath: folder).appendingPathComponent("mac-\(name.filter { $0.isLetter || $0.isNumber }).png"))
        }
    }

    private func git(_ arguments: String...) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", project.path] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func wait(_ what: String, timeout: TimeInterval = 15, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        XCTAssertTrue(condition(), "timed out waiting for: \(what). On screen:\n\(app.screen())")
    }

    private func openSettings(_ pane: String) {
        app.menu(["AgentTermMacUITest", "Settings…"])
        app.press(.id("settings-\(pane.lowercased())"))
    }

    /// Before the iPhone app runs: what the Mac does, for the phone to find.
    func testPart1WhatTheMacDoesFirst() throws {
        // A session, for the phone to list and to type in.
        app.menu(["File", "New Shell"])
        app.wait(for: .id("session-1"), timeout: 15)
        // The Mac is kept awake, a setting the phone has to show as on.
        openSettings("General")
        app.press(.id("keep-awake"))
        wait("the switch to be on") { self.app.first(.id("keep-awake"))?.value == "1" }
        // The changes grouped by folder, a choice the phone has to follow.
        app.press(.button("Group by folder"))
        app.wait(for: .button("Show as a flat list"))
        // And the changes the phone is going to commit are listed here.
        app.wait(for: .id("change-notes.txt"))
    }

    /// After the iPhone app ran: what it did, shown by the Mac.
    func testPart2WhatThePhoneDidShowsOnTheMac() throws {
        // GIT-12: the phone staged everything and committed; the Mac's list is empty and git has the commit.
        // The Mac reads the changes again by itself only while it is in
        // front, which it is not with the simulator on top: ask for it.
        app.press(.button("Refresh"))
        app.wait(for: .containing("No uncommitted changes"), timeout: 20)
        XCTAssertEqual(git("log", "-1", "--format=%s"), "test: from the phone")
        // GIT-6: the phone went back to a flat list, so the Mac offers the tree again.
        app.wait(for: .button("Group by folder"), timeout: 15)

        // AWAKE-2: the option the phone switched on is on here.
        openSettings("General")
        wait("the display option the phone switched on") { self.app.first(.button("Keep the display on too"))?.value == "1" }
        XCTAssertEqual(app.first(.id("keep-awake"))?.value, "1")

        // SES-6: the session the phone started is listed here too, in Sessions.
        app.press(.id("place-sessions"))
        wait("the phone's own session beside the Mac's") { self.app.exists(.id("session-1")) && self.app.exists(.id("session-2")) }

        // Who is using a session is checked with the Mac app alone
        // (SessionTests): the iPhone app is closed when its test ends, and
        // the session is the Mac's again by the time this runs.
    }
}
