import AgentTermProtocol
import XCTest

/// History, resuming and handing off, and the strip of tabs.
final class HistoryAndTabsTests: MacUITestCase {
    func testAConversationIsListedResumedAndHandedOff() throws {
        let phone = try device()
        app.press(.button("History"))
        // HIST-2: the conversation the agent had in this folder.
        app.wait(for: .id("conversation-c-1"), timeout: 15)
        app.wait(for: .text("1 conversation"))

        // HIST-3: resumed, in a new session of its agent, with its own command.
        app.perform("Resume", on: .id("conversation-c-1"))
        wait("the resumed session") { phone.sessions.count == 1 }
        let resumed = phone.sessions[0]
        phone.send(.attach(session: resumed.id, size: .default))
        wait("the agent started with the conversation") { phone.text(resumed.id).contains("stand-in claude started") && phone.text(resumed.id).contains("c-1") }

        // HAND-3: the sheet names the other agent and shows the prompt it starts with.
        app.perform("Hand Off", on: .id("conversation-c-1"))
        app.wait(for: .text("Hand Off"), timeout: 10)
        wait("the prompt in the sheet") { self.app.all(.role(kAXTextAreaRole as String)).contains { $0.value.contains(".agentterm/handoffs/") } }
        app.wait(for: .button("Codex"))
        // HAND-4: handing off starts that agent, told to read the handoff file, which is in the project and not in git.
        app.press(.button("Hand Off"))
        wait("the receiving agent's session") { phone.sessions.count == 2 }
        let receiving = try XCTUnwrap(phone.sessions.first { $0.id != resumed.id })
        XCTAssertEqual(receiving.title, "Codex")
        phone.send(.attach(session: receiving.id, size: .default))
        wait("the receiving agent told about the file") { phone.text(receiving.id).contains(".agentterm/handoffs/") }
        let handoffs = (try? FileManager.default.contentsOfDirectory(atPath: project.appendingPathComponent(".agentterm/handoffs").path)) ?? []
        XCTAssertEqual(handoffs.count, 1, "no handoff file was written in the project")
        XCTAssertFalse(git("status", "--short", in: project).contains(".agentterm"), "the handoff file shows up as a change")
    }

    func testTabsAreShownPinnedGroupedAndClosed() throws {
        let phone = try device()
        app.menu(["File", "New Shell"])
        app.menu(["File", "New Claude Code"])
        app.menu(["File", "New Codex"])
        wait("three sessions") { phone.sessions.count == 3 }
        // TAB-1: each is a tab, and picking a tab's session from the sidebar shows it.
        let shell = try XCTUnwrap(phone.sessions.first { $0.title != "Claude Code" && $0.title != "Codex" })
        let claude = try XCTUnwrap(phone.sessions.first { $0.title == "Claude Code" })
        app.press(.id("session-\(shell.id)"))
        // TAB-2: the tab in front is pinned, and the host has it so.
        app.menu(["Tab", "Pin Tab"])
        wait("the host to know the pin") { phone.tabLayout?.pinned.contains(shell.layoutID) ?? false }
        // Another one goes into a group of its own.
        app.press(.id("session-\(claude.id)"))
        app.menu(["Tab", "Add Tab to New Group"])
        wait("the host to know the group") { !(phone.tabLayout?.groups.isEmpty ?? true) }
        // TAB-3: the arrangement is there again when the app is opened again.
        let arranged = phone.tabLayout
        try relaunchApp()
        wait("the same arrangement after reopening") { phone.tabLayout == arranged && self.app.exists(.id("session-\(claude.id)")) }

        // SES-10: ending the session in front asks first, then ends it everywhere.
        app.press(.id("session-\(claude.id)"))
        app.menu(["Tab", "End Session"])
        // Nothing ends before the answer.
        app.wait(for: .button("End Session"))
        XCTAssertTrue(phone.sessions.contains { $0.id == claude.id }, "the session ended without asking")
        app.press(.button("End Session"))
        wait("the session to end") { !phone.sessions.contains { $0.id == claude.id } }
        app.waitGone(.id("session-\(claude.id)"))
    }

    func testTheWindowsPanesAndTheTextSize() throws {
        // WIN-3: the folder list and the side panel hide and show.
        app.wait(for: .text("project, folder"))
        app.press(.button("Folders"))
        app.waitGone(.text("project, folder"))
        // Which Mac the window is about stays in the header.
        XCTAssertTrue(app.exists(.id("mac-switcher")))
        app.press(.button("Folders"))
        app.wait(for: .text("project, folder"))
        app.wait(for: .button("Git"))
        app.press(.button("Side Panel"))
        app.waitGone(.button("History"))
        app.press(.button("Side Panel"))
        app.wait(for: .button("History"))

        // SIZE-5: larger text means fewer columns for the session.
        let phone = try device()
        app.press(.button("Shell"))
        wait("the shell") { phone.sessions.count == 1 }
        let id = phone.sessions[0].id
        // The phone only watches: the size stays the Mac's, and the phone is told what it is.
        phone.send(.attach(session: id, size: .default))
        wait("the session's size") { (phone.size(of: id)?.cols ?? 0) > 20 }
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        let before = try XCTUnwrap(phone.size(of: id))
        for _ in 0..<4 { app.menu(["View", "Bigger Text"]) }
        wait("fewer columns after the text grew", timeout: 15) { (phone.size(of: id)?.cols ?? before.cols) < before.cols }
        app.menu(["View", "Actual Size"])
        wait("the columns back", timeout: 15) { phone.size(of: id)?.cols == before.cols }
    }
}
