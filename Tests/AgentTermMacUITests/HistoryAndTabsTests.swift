import AgentTermProtocol
import XCTest

/// History, resuming and handing off, and the strip of tabs.
final class HistoryAndTabsTests: MacUITestCase {
    func testAConversationIsListedResumedAndHandedOff() throws {
        let phone = try device()
        app.press(.id("panel-history"))
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
        wait("the receiving agent told about the file") { self.agentStarts().contains { $0.hasPrefix("codex: ") && $0.contains(".agentterm/handoffs/") } }
        let handoffs = (try? FileManager.default.contentsOfDirectory(atPath: project.appendingPathComponent(".agentterm/handoffs").path)) ?? []
        XCTAssertEqual(handoffs.count, 1, "no handoff file was written in the project")
        XCTAssertFalse(git("status", "--short", in: project).contains(".agentterm"), "the handoff file shows up as a change")
    }

    /// HIST-19 (#46): the folder's conversations are searched by what was
    /// said, one is read as a transcript and pinned, and one is deleted
    /// after being asked about twice, its file going to the Trash.
    func testHistoryIsSearchedReadPinnedAndDeleted() throws {
        let history = home.appendingPathComponent(".claude/projects/" + project.path.map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined())
        try [
            #"{"type":"user","timestamp":"2026-11-14T08:00:00.000Z","cwd":"\#(project.path)","message":{"role":"user","content":"rename the token"}}"#,
            #"{"type":"assistant","timestamp":"2026-11-14T08:20:00.000Z","message":{"id":"m1","model":"claude-fable-5","role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"swift test"}},{"type":"text","text":"The tokenizer is renamed."}],"usage":{"input_tokens":1200,"output_tokens":40}}}"#,
        ].joined(separator: "\n").appending("\n").write(to: history.appendingPathComponent("c-2.jsonl"), atomically: true, encoding: .utf8)

        app.press(.id("panel-history"))
        app.wait(for: .id("conversation-c-2"), timeout: 20)
        app.wait(for: .text("2 conversations"))

        // Searched by what was said in it: its title does not hold the word.
        app.write("tokenizer", into: .id("history-search-folder"))
        app.wait(for: .text("1 found"), timeout: 15)
        app.wait(for: .containing("The tokenizer is renamed."))
        XCTAssertFalse(app.exists(.id("conversation-c-1")))
        shot("search")
        app.write("", into: .id("history-search-folder"))
        app.wait(for: .id("conversation-c-1"))

        // Read: what was asked, run and answered, and what the file tells.
        app.press(.id("conversation-c-2"))
        app.wait(for: .text("You: rename the token"), timeout: 15)
        app.wait(for: .text("Bash: swift test"))
        app.wait(for: .text("Claude Code: The tokenizer is renamed."))
        app.wait(for: .text("20 min"))
        app.wait(for: .text("claude-fable-5"))
        shot("transcript")
        app.press(.id("conversation-pin"))
        app.wait(for: .button("Unpin"))
        app.press(.button("Close"))
        app.wait(for: .containing("Pinned, 1 conversations"))

        // Deleted: asked twice, and its file goes to the Trash.
        app.perform("Delete", on: .id("conversation-c-1"))
        app.wait(for: .containing("Delete this conversation?"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: history.appendingPathComponent("c-1.jsonl").path))
        app.press(.button("Delete…"))
        app.wait(for: .containing("Delete it for good from Claude Code?"), timeout: 10)
        app.press(.button("Delete Conversation"))
        app.waitGone(.id("conversation-c-1"), timeout: 15)
        XCTAssertFalse(FileManager.default.fileExists(atPath: history.appendingPathComponent("c-1.jsonl").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent(".Trash-of-the-tests").path), ["c-1.jsonl"])
        app.wait(for: .id("conversation-c-2"))
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

    /// WIN-4: the bar of places shows History and Settings at the left, and
    /// Settings in the middle over the terminal, which is there again after.
    func testTheBarOfPlaces() throws {
        let phone = try device()
        // A conversation in another folder: History lists it, the side panel not.
        let demo = home.appendingPathComponent("Projects/demo").path
        let other = home.appendingPathComponent(".claude/projects/" + demo.map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined())
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try #"{"type":"user","cwd":"\#(demo)","message":{"role":"user","content":"tidy the demo"}}"#.appending("\n").write(
            to: other.appendingPathComponent("c-3.jsonl"), atomically: true, encoding: .utf8)
        app.press(.button("Shell"))
        wait("the shell") { phone.sessions.count == 1 }
        app.wait(for: .id("session-\(phone.sessions[0].id)"))
        app.wait(for: .text("project, folder"))

        app.press(.id("place-history"))
        app.wait(for: .text("HISTORY"))
        app.wait(for: .id("conversation-c-1"), timeout: 15)
        app.wait(for: .id("conversation-c-3"))
        XCTAssertFalse(app.exists(.text("project, folder")), "the folders are still listed")
        XCTAssertFalse(app.exists(.id("system-cpu")))
        // Every conversation, each naming its folder: there is no switch to one folder's.
        XCTAssertFalse(app.exists(.button("This Folder")))
        // The side panel is not there: it has nothing to do with History.
        XCTAssertFalse(app.exists(.id("panel-git")), "the side panel shows in History")
        XCTAssertFalse(app.exists(.button("Side Panel")), "its button shows in History")
        // HIST-4: the middle asks for a conversation, not the folder's launch screen.
        app.wait(for: .text("Choose a conversation"))
        app.press(.id("conversation-c-1"))
        app.wait(for: .button("Resume in Claude Code"))
        app.wait(for: .button("Copy Resume Command"))
        // What was said in it is what shows first (#46); handing it off is beside it.
        app.wait(for: .text("You: write tests for the parser"), timeout: 15)
        app.press(.button("Hand Off"))
        app.wait(for: .text("Hand Off to Another Agent"))
        app.wait(for: .button("Codex"))
        shot("win-4-history")

        app.press(.id("place-settings"))
        app.wait(for: .text("SETTINGS"))
        XCTAssertFalse(app.exists(.id("panel-git")), "the side panel shows in Settings")
        XCTAssertFalse(app.exists(.button("Side Panel")), "its button shows in Settings")
        for pane in ["General", "Git", "Permissions", "Privacy"] { app.wait(for: .button(pane)) }
        app.wait(for: .id("menu-bar"))
        XCTAssertFalse(app.exists(.id("conversation-c-1")))
        // The line of figures is Sessions' only.
        XCTAssertFalse(app.exists(.id("system-cpu")))
        shot("win-4-settings")
        app.press(.button("Privacy"))
        app.wait(for: .containing("Send crash reports"))
        app.press(.id("place-schedules"))
        app.wait(for: .text("SCHEDULES"))
        XCTAssertFalse(app.exists(.id("panel-git")), "the side panel shows in Schedules")
        app.wait(for: .text("Choose a schedule"))
        shot("win-4-schedules")

        // WIN-5: an agent started from the header while Settings is shown
        // is shown in Sessions.
        app.press(.button("Shell"))
        wait("the second shell") { phone.sessions.count == 2 }
        app.wait(for: .text("FOLDERS"))
        app.wait(for: .id("panel-git"))
        app.press(.id("place-settings"))
        app.wait(for: .text("SETTINGS"))
        app.press(.id("place-sessions"))
        app.wait(for: .text("project, folder"))
        app.wait(for: .id("session-\(phone.sessions[0].id)"))
        app.wait(for: .id("system-cpu"))
        app.wait(for: .id("panel-git"))
        app.wait(for: .button("Side Panel"))
        app.waitGone(.containing("Send crash reports"))

        // HIST-5: the side panel's History, the folder's conversations only;
        // one picked there is shown in History.
        app.press(.id("panel-history"))
        app.wait(for: .id("conversation-c-1"), timeout: 15)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertFalse(app.exists(.id("conversation-c-3")), "another folder's conversation")
        app.press(.id("conversation-c-1"))
        app.wait(for: .button("Resume in Claude Code"))
        app.wait(for: .button("Close"))
        shot("hist-5-sheet")
        // Over Sessions, which stays.
        XCTAssertTrue(app.exists(.text("FOLDERS")))
        XCTAssertFalse(app.exists(.text("HISTORY")))
        app.press(.button("Close"))
        app.waitGone(.button("Resume in Claude Code"))
        app.wait(for: .text("project, folder"))
    }

    /// SIZE-7: a session started on the Mac starts at the size its pane has,
    /// not one a little larger that it is made smaller to once it is shown:
    /// the first prompt is drawn for the width the terminal has.
    func testASessionStartsAtTheSizeOfItsPane() throws {
        let phone = try device()
        // As a person would, once the window has settled: the line of the
        // Mac's figures comes a moment after the app connects, and takes
        // its height from the terminal.
        app.wait(for: .id("system-cpu"), timeout: 15)
        app.press(.button("Shell"))
        wait("the shell") { phone.sessions.count == 1 }
        let id = phone.sessions[0].id
        let started = try XCTUnwrap(
            phone.messages.lazy.compactMap { message -> TermSize? in
                guard case .sessions(let list) = message else { return nil }
                return list.first { $0.id == id }?.size
            }.first)
        // Shown, and laid out, the pane says the size it fits. The phone
        // only watches, and is told the size.
        phone.send(.attach(session: id, size: .default))
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        let shown = try XCTUnwrap(phone.size(of: id))
        XCTAssertEqual(started, shown, "started at \(started.cols) × \(started.rows), shown at \(shown.cols) × \(shown.rows)")
    }

    func testTheWindowsPanesAndTheTextSize() throws {
        // WIN-3: the folder list and the side panel hide and show.
        app.wait(for: .text("project, folder"))
        app.press(.id("place-sessions"))
        app.waitGone(.text("project, folder"))
        // Which Mac the window is about stays in the header.
        XCTAssertTrue(app.exists(.id("mac-switcher")))
        app.press(.id("place-sessions"))
        app.wait(for: .text("project, folder"))
        app.wait(for: .button("Git"))
        app.press(.button("Side Panel"))
        app.waitGone(.button("Files"))
        app.press(.button("Side Panel"))
        app.wait(for: .button("Files"))

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
