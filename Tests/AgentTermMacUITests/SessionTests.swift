import AgentTermProtocol
import XCTest

/// Starting sessions from the Mac app, and what it shows of the Mac.
final class SessionTests: MacUITestCase {
    func testTheWindowShowsTheFolderTheAgentsAndTheMac() throws {
        // WIN-1: the folder of the host's list.
        app.wait(for: .text("project, folder"))
        // LAUNCH-1: a button for each agent that is installed, and none for the others.
        app.wait(for: .button("Claude Code"))
        XCTAssertTrue(app.exists(.button("Codex")))
        XCTAssertTrue(app.exists(.button("Shell")))
        XCTAssertFalse(app.exists(.button("Antigravity")), "an agent that is not installed has a launch button")
        XCTAssertFalse(app.exists(.button("Copilot CLI")))
        // SYS-2: how the Mac is doing.
        for figure in ["system-cpu", "system-memory", "system-down", "system-up", "system-temperature", "system-battery", "system-uptime"] {
            app.wait(for: .id(figure), timeout: 15)
        }
        XCTAssertTrue(app.first(.id("system-cpu"))?.label.hasPrefix("CPU ") ?? false)
    }

    /// TEST-1: the host and the app a test starts, and the login shells they
    /// start in turn, use the test's home folder, so no startup file of
    /// the person running the tests is read.
    func testTheShellsOfATestUseTheTestsHome() throws {
        let phone = try device()
        let seen = root.appendingPathComponent("seen-home")
        // Started by the app's host, through the login shell, as every session is.
        phone.send(.create(CreateRequest(command: "printf '%s' \"$HOME\" > '\(seen.path)'; sleep 600", cwd: project.path, title: "home")))
        wait("the session to write its home") { FileManager.default.fileExists(atPath: seen.path) }
        XCTAssertEqual(try String(contentsOf: seen, encoding: .utf8), home.path)
    }

    /// AGENT-9: what an agent says it is doing shows next to its session,
    /// in the folder list and on its tab, and its folder says it waits.
    func testTheStateOfAnAgentShowsWithItsSession() throws {
        let phone = try device()
        // A stand-in for Claude Code, under its name: it tells its hooks, as
        // Claude Code does, that it waits for permission to run a command.
        let folder = root.appendingPathComponent("stand-in")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let script = folder.appendingPathComponent("claude")
        let event = #"{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"make test"}}"#
        try "#!/bin/sh\nprintf '%s' '\(event)' | '\(hostExecutable.path)' hook claude PermissionRequest\nexec sleep 600\n"
            .write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        phone.send(.create(CreateRequest(command: script.path, cwd: project.path, title: "review")))
        wait("the host to know it waits") { phone.sessions.first?.state?.isWaiting == true }
        let id = try XCTUnwrap(phone.sessions.first?.id)

        app.wait(for: .containing("review, session, waiting for permission"), timeout: 15)
        app.wait(for: .containing("project, folder, a session waits"))
        app.press(.id("session-\(id)"))
        app.wait(for: .containing("review, waiting for permission"))
        shot("waiting")
    }

    /// NOTE-4: an agent of a session that is not in front that comes to
    /// wait is told in a banner, which opens it.
    func testAnAgentThatWaitsInAnotherSessionIsToldInABanner() throws {
        let phone = try device()
        app.press(.button("Shell"))
        wait("the shell to start") { phone.sessions.count == 1 }
        let shell = try XCTUnwrap(phone.sessions.first?.id)
        // A stand-in for Claude Code that asks permission a moment after it starts.
        let folder = root.appendingPathComponent("stand-in")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let script = folder.appendingPathComponent("claude")
        let event = #"{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"make deploy"}}"#
        try "#!/bin/sh\nsleep 2\nprintf '%s' '\(event)' | '\(hostExecutable.path)' hook claude PermissionRequest\nexec sleep 600\n"
            .write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        phone.send(.create(CreateRequest(command: script.path, cwd: project.path, title: "deploy")))
        wait("the agent's session") { phone.sessions.count == 2 }
        let agent = try XCTUnwrap(phone.sessions.first { $0.id != shell }?.id)
        // The shell is the one in front, and the window on History: the
        // banner shows over every place, and Open goes to Sessions.
        app.press(.id("session-\(shell)"))
        app.press(.id("place-history"))
        app.wait(for: .text("HISTORY"))

        // Named after the conversation the stand-in folder's history gives it.
        app.wait(for: .containing("needs permission"), timeout: 15)
        app.wait(for: .containing("make deploy"))
        shot("notice")
        app.press(.button("Open"))
        app.waitGone(.containing("needs permission"))
        app.wait(for: .text("FOLDERS"))
        app.wait(for: .id("session-\(agent)"))
    }

    /// A shell in front and a stand-in agent in another session that comes
    /// to ask for permission, with the banner that says so on screen.
    private func aBannerForAnAgentBehindAShell(
        _ phone: Device, hook: String = "PermissionRequest",
        event: String = #"{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"make deploy"}}"#, says: String = "needs permission"
    ) throws -> (shell: SessionID, agent: SessionID) {
        app.press(.button("Shell"))
        wait("the shell to start") { phone.sessions.count == 1 }
        let shell = try XCTUnwrap(phone.sessions.first?.id)
        let folder = root.appendingPathComponent("stand-in")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let script = folder.appendingPathComponent("claude")
        try "#!/bin/sh\nsleep 2\nprintf '%s' '\(event)' | '\(hostExecutable.path)' hook claude \(hook)\nexec sleep 600\n"
            .write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        phone.send(.create(CreateRequest(command: script.path, cwd: project.path, title: "deploy")))
        wait("the agent's session") { phone.sessions.count == 2 }
        let agent = try XCTUnwrap(phone.sessions.first { $0.id != shell }?.id)
        app.press(.id("session-\(shell)"))
        app.wait(for: .containing(says), timeout: 15)
        return (shell, agent)
    }

    /// NOTE-13 (#62): a banner tells the end of what an agent said, and
    /// opens out to all of it.
    func testABannerOpensOutToAllOfWhatTheAgentSaid() throws {
        let phone = try device()
        let said = "The beginning of it all. " + String(repeating: "Then one more thing was done and checked. ", count: 30) + "And that is the end of it."
        _ = try aBannerForAnAgentBehindAShell(
            phone, hook: "Stop", event: #"{"hook_event_name":"Stop","last_assistant_message":"\#(said)"}"#, says: "is done")
        app.wait(for: .containing("And that is the end of it."))
        XCTAssertNil(app.first(.containing("The beginning of it all.")), "the end of it, until it is opened out")
        shot("short")
        app.press(.id("agent-notice-more"))
        app.wait(for: .containing("The beginning of it all."))
        shot("all")
        app.press(.id("agent-notice-more"))
        app.waitGone(.containing("The beginning of it all."))
    }

    /// Whether the app is the one in front of every other.
    private var appIsInFront: Bool { NSRunningApplication(processIdentifier: app.pid)?.isActive == true }

    /// Through accessibility, as the rest is done: macOS does not let a
    /// program that is not in front itself put another one there.
    private func bringAppToFront() {
        if !appIsInFront {
            NSRunningApplication(processIdentifier: app.pid)?.activate(options: [.activateAllWindows])
            AXUIElementSetAttributeValue(AXUIElementCreateApplication(app.pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        }
        wait("the app in front") { appIsInFront }
    }

    /// NOTE-9 (#60): a banner hides by itself once its session is the one
    /// in front, however the user got there, and does not come back; the
    /// other devices are told that it was seen.
    func testABannerHidesWhenItsSessionIsOpenedFromTheList() throws {
        let phone = try device()
        let (shell, agent) = try aBannerForAnAgentBehindAShell(phone)
        bringAppToFront()

        // Not the banner's Open: the session's own row.
        app.press(.id("session-\(agent)"))
        app.waitGone(.containing("needs permission"))
        shot("gone")
        wait("the phone to be told that it was seen") {
            phone.last { if case .noticeSeen(let session, _) = $0 { return session } else { return nil } } == agent
        }
        // Leaving the session does not bring it back: it was seen.
        app.press(.id("session-\(shell)"))
        Thread.sleep(forTimeInterval: 1)
        app.waitGone(.containing("needs permission"))
    }

    /// NOTE-11 (#60): a session chosen in a window that is behind another
    /// app's is not before the user's eyes: its banner stays until the app
    /// is used again.
    func testABannerStaysWhileTheAppIsBehindAnother() throws {
        let phone = try device()
        let (_, agent) = try aBannerForAnAgentBehindAShell(phone)
        // Finder in front, as when the user works in another app.
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.activate(options: [])
        let deadline = Date().addingTimeInterval(5)
        while appIsInFront && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        try XCTSkipIf(appIsInFront, "the app could not be put behind another: macOS did not let the tests bring Finder to the front")

        app.press(.id("session-\(agent)"))
        Thread.sleep(forTimeInterval: 1)
        app.wait(for: .containing("needs permission"))
        XCTAssertNil(phone.last { if case .noticeSeen(let session, _) = $0 { return session } else { return nil } }, "not seen yet")

        bringAppToFront()
        app.waitGone(.containing("needs permission"))
    }

    func testStartingSessionsAndFindingThemAgainAfterReopeningTheApp() throws {
        let phone = try device()
        // SES-2: a shell from the launch buttons.
        app.press(.button("Shell"))
        wait("the shell to start") { phone.sessions.count == 1 }
        let shell = phone.sessions[0]
        XCTAssertEqual(shell.cwd, project.path, "the session did not start in the selected folder")
        // SES-3: an agent, named after it.
        app.press(.button("Claude Code"))
        wait("the agent to start") { phone.sessions.count == 2 }
        let agent = try XCTUnwrap(phone.sessions.first { $0.id != shell.id })
        XCTAssertEqual(agent.title, "Claude Code")
        // TAB-1: each is a tab.
        app.wait(for: .containing("Claude Code"))

        // SES-6: what the program writes reaches another device too.
        phone.send(.attach(session: agent.id, size: .default))
        wait("the agent's first words on the other device") { phone.text(agent.id).contains("stand-in claude started") }

        // SES-12: what is typed and not sent is still there after the app
        // was closed. Typed from the other device: the app only has to show it.
        phone.send(.attach(session: shell.id, size: .default))
        phone.connection.sendInput(Data("echo not-sent-yet".utf8), to: shell.id)
        wait("the typing echoed") { phone.text(shell.id).contains("not-sent-yet") }

        // SES-4: the sessions outlive the app.
        try relaunchApp()
        wait("both sessions after reopening") { self.app.all(.containing("Claude Code")).count >= 1 && phone.sessions.count == 2 }
        XCTAssertEqual(phone.sessions.map(\.id).sorted(), [shell.id, agent.id].sorted())
        // And what was typed is what a device that opens the session now is shown.
        let later = try device("later")
        later.send(.attach(session: shell.id, size: .default))
        wait("what was typed, replayed") { later.text(shell.id).contains("not-sent-yet") }
    }

    func testASessionAnotherDeviceIsUsingIsShownAtThatDevicesSize() throws {
        let phone = try device()
        app.press(.button("Shell"))
        wait("the shell") { phone.sessions.count == 1 }
        let id = phone.sessions[0].id
        // Only shown on the phone, the session keeps the Mac's size.
        phone.send(.attach(session: id, size: TermSize(cols: 40, rows: 20)))
        wait("the Mac's size, told to the phone") { (phone.size(of: id)?.cols ?? 0) > 40 }
        XCTAssertFalse(app.exists(.button("Use This Window's Size")))
        // SIZE-4: used on the phone, it has the phone's size, and the Mac says so and offers to take it back.
        phone.send(.takeControl(session: id, size: TermSize(cols: 40, rows: 20)))
        wait("the phone's size") { phone.size(of: id) == TermSize(cols: 40, rows: 20) }
        app.wait(for: .button("Use This Window's Size"), timeout: 15)
        app.wait(for: .containing("Another device is using this session"))
        app.wait(for: .containing("40 × 20"))
        app.press(.button("Use This Window's Size"))
        app.waitGone(.button("Use This Window's Size"), timeout: 15)
        wait("the Mac's size again") { (phone.size(of: id)?.cols ?? 0) > 40 }
    }

    func testTheSSHMenuListsTheHostsOfTheConfiguration() throws {
        // LAUNCH-2: the hosts, without the patterns.
        app.press(.button("SSH"))
        app.wait(for: .button("build-server"), menus: true)
        XCTAssertFalse(app.nodes(menus: true).contains { $0.title.contains("internal") }, "a pattern is offered as a host")
    }
}
