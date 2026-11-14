import AgentTermProtocol
import XCTest

/// A session in a worktree of its own (#23), and the side panel following
/// the worktree shown (#33).
final class WorktreeUITests: MacUITestCase {
    /// WT-7: the session is listed under its project with its branch;
    /// picking it shows its worktree's changes, not the project's.
    func testASessionInAWorktreeIsUnderItsProjectAndThePanelFollowsIt() throws {
        let phone = try device()
        app.wait(for: .text("project, folder"), timeout: 15)
        phone.send(.createInWorktree(request: CreateRequest(command: "exec sleep 600", cwd: project.path, title: "in a worktree"), branch: "feature/try", from: nil))
        wait("the session", timeout: 20) { phone.sessions.first?.branch == "feature/try" }
        let session = try XCTUnwrap(phone.sessions.first)
        XCTAssertTrue(WorktreePath.belongs(session.cwd, to: project.path), session.cwd)
        // A change of the worktree's own, that the project does not have.
        try "only here\n".write(toFile: session.cwd + "/worktree-only.txt", atomically: true, encoding: .utf8)

        app.wait(for: .containing("feature/try"), timeout: 15)
        app.press(.id("session-\(session.id)"))
        app.wait(for: .id("worktree-chip-feature/try"), timeout: 15)
        app.wait(for: .containing("worktree-only.txt"), timeout: 15)
        XCTAssertFalse(app.exists(.containing("notes.txt")), "the project's own changes are not the worktree's")
        shot("worktree")
    }

    /// WT-17 (#43): the bar is there for a folder with no worktree but its
    /// own; "+" suggests a branch named after the agent and starts it in a
    /// new worktree; the chips say what is changed in each, and a click
    /// makes the side panel about that one, the first about the folder again.
    func testAWorktreeIsMadeFromTheBarAndItsChipsSwitchThePanel() throws {
        let phone = try device()
        app.wait(for: .text("project, folder"), timeout: 15)
        app.press(.button("Git"))
        app.wait(for: .id("worktree-chip-main"), timeout: 15)
        app.wait(for: .containing("notes.txt"))

        app.press(.id("worktree-add"))
        app.wait(for: .id("worktree-branch"))
        app.wait("the suggested name") { self.app.value(of: .id("worktree-branch")) == "agentterm/claude-1" }
        shot("new-worktree")
        app.press(.id("worktree-create"))
        wait("the session in its worktree", timeout: 30) { phone.sessions.first?.branch == "agentterm/claude-1" }
        let session = try XCTUnwrap(phone.sessions.first)
        XCTAssertEqual(session.agent, "claude")
        XCTAssertEqual(session.cwd, project.appendingPathComponent(".agentterm/worktrees/agentterm/claude-1").path)

        // It is on show: the worktree has none of the folder's changes.
        app.wait(for: .id("worktree-chip-agentterm/claude-1"), timeout: 15)
        app.waitGone(.containing("notes.txt"), timeout: 15)
        try "only here\n".write(toFile: session.cwd + "/worktree-only.txt", atomically: true, encoding: .utf8)
        app.wait(for: .containing("worktree-only.txt"), timeout: 15)
        app.wait(for: .containing("agentterm/claude-1, A worktree, 1 file changed, a session runs in it"), timeout: 15)
        shot("chips")

        // The first chip goes back to the folder; the other to the worktree.
        app.press(.id("worktree-chip-main"))
        app.wait(for: .containing("notes.txt"), timeout: 15)
        XCTAssertFalse(app.exists(.containing("worktree-only.txt")))
        app.press(.id("worktree-chip-agentterm/claude-1"))
        app.wait(for: .containing("worktree-only.txt"), timeout: 15)
    }
}
