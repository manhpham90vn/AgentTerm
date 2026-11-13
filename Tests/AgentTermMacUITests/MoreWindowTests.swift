import AgentTermProtocol
import XCTest

/// The rest of the Mac window: sessions outside the listed folders, closing
/// many tabs, handing off a running session, the Settings panes and pairing.
final class MoreWindowTests: MacUITestCase {
    func testASessionOutsideTheListedFoldersIsUnderOther() throws {
        let phone = try device()
        // WIN-2: started in a folder that is not on the list.
        phone.send(.create(CreateRequest(command: nil, cwd: home.appendingPathComponent("Projects/demo").path, title: "elsewhere", size: .default)))
        wait("the session") { phone.sessions.count == 1 }
        app.wait(for: .text("OTHER"), timeout: 15)
        app.wait(for: .id("session-\(phone.sessions[0].id)"))
    }

    func testClosingTheOtherTabsAsksAndSparesAPinnedOne() throws {
        let phone = try device()
        app.menu(["File", "New Shell"])
        app.menu(["File", "New Claude Code"])
        app.menu(["File", "New Codex"])
        wait("three sessions") { phone.sessions.count == 3 }
        let shell = try XCTUnwrap(phone.sessions.first { $0.title != "Claude Code" && $0.title != "Codex" })
        let claude = try XCTUnwrap(phone.sessions.first { $0.title == "Claude Code" })
        let codex = try XCTUnwrap(phone.sessions.first { $0.title == "Codex" })
        app.press(.id("session-\(shell.id)"))
        app.menu(["Tab", "Pin Tab"])
        wait("the pin") { phone.tabLayout?.pinned.contains(shell.layoutID) ?? false }
        // TAB-4: every tab but Claude Code's. It asks, since a session would end, and nothing ends before the answer.
        app.perform("Close Other Tabs", on: .id("tab-\(claude.id)"))
        app.wait(for: .button("End Sessions and Close"))
        XCTAssertEqual(phone.sessions.count, 3, "sessions ended before the question was answered")
        app.press(.button("End Sessions and Close"))
        // The one kept and the pinned one stay; the third is ended.
        wait("the other session to end") { !phone.sessions.contains { $0.id == codex.id } }
        XCTAssertEqual(Set(phone.sessions.map(\.id)), [shell.id, claude.id], "a pinned tab was closed with the others")
    }

    func testARunningSessionIsHandedOffToAnotherFolder() throws {
        let phone = try device()
        let demo = home.appendingPathComponent("Projects/demo").path
        phone.send(.addFolder(path: demo))
        app.wait(for: .text("demo, folder"), timeout: 15)
        app.press(.id("folder-" + project.path))
        app.press(.button("Claude Code"))
        wait("the agent's session") { phone.sessions.count == 1 }
        let session = phone.sessions[0]
        // The agent saves its conversation once it has been told something:
        // a conversation that began after the session did is the session's.
        let history = home.appendingPathComponent(".claude/projects/" + project.path.map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined())
        try #"{"type":"user","cwd":"\#(project.path)","message":{"role":"user","content":"carry this on elsewhere"}}"#.appending("\n").write(
            to: history.appendingPathComponent("c-2.jsonl"), atomically: true, encoding: .utf8)
        // HAND-6: handed off from the session itself.
        app.perform("Hand Off", on: .id("tab-\(session.id)"))
        app.wait(for: .text("Hand Off"), timeout: 15)
        wait("the prompt in the sheet") { self.app.all(.role(kAXTextAreaRole as String)).contains { $0.value.contains(".agentterm/handoffs/") } }
        // HAND-5: to continue in another folder of the list.
        app.press(.button("Folder"))
        app.press(.containing("Projects/demo"), menus: true)
        app.press(.button("Hand Off"))
        wait("the receiving agent's session, in the other folder", timeout: 15) { phone.sessions.contains { $0.id != session.id && $0.cwd == demo } }
        let handoffs = (try? FileManager.default.contentsOfDirectory(atPath: demo + "/.agentterm/handoffs")) ?? []
        XCTAssertEqual(handoffs.count, 1, "the handoff file was not written in the folder the work moved to")
    }

    func testSettingsListThePermissionsAgentsNeed() throws {
        // PERM-1.
        app.menu(["AgentTermMacUITest", "Settings…"])
        app.press(.id("settings-permissions"))
        for permission in ["Accessibility", "Screen & System Audio Recording", "Automation", "Full Disk Access", "Microphone", "Camera"] {
            // Each says what it is, whether it is allowed, and what it is for.
            app.wait(for: .containing(permission + ", "))
        }
    }

    func testThePairingWindowShowsACodeOrWhatIsMissing() throws {
        // PAIR-4: a code when Tailscale is ready on this Mac, else what is missing.
        app.press(.button("Pair Device"))
        app.wait(for: .text("Pair a Device"))
        wait("a code, or what Tailscale is missing", timeout: 20) {
            self.app.exists(.containing("This code works once")) || self.app.exists(.containing("Tailscale"))
        }
    }
}

/// With no SSH configuration there is nothing for an SSH menu to hold.
final class NoSSHConfigurationTests: MacUITestCase {
    override func makeFixtures() throws {
        try super.makeFixtures()
        try FileManager.default.removeItem(at: home.appendingPathComponent(".ssh/config"))
    }

    func testThereIsNoSSHMenu() throws {
        // LAUNCH-4.
        app.wait(for: .button("Shell"))
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        XCTAssertFalse(app.exists(.button("SSH")), "an SSH menu with no host to offer")
    }
}
