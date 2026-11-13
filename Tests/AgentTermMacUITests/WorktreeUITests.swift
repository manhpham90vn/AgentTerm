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
        phone.send(.createInWorktree(request: CreateRequest(command: "exec sleep 600", cwd: project.path, title: "in a worktree"), branch: "feature/try"))
        wait("the session", timeout: 20) { phone.sessions.first?.branch == "feature/try" }
        let session = try XCTUnwrap(phone.sessions.first)
        XCTAssertTrue(WorktreePath.belongs(session.cwd, to: project.path), session.cwd)
        // A change of the worktree's own, that the project does not have.
        try "only here\n".write(toFile: session.cwd + "/worktree-only.txt", atomically: true, encoding: .utf8)

        app.wait(for: .containing("feature/try"), timeout: 15)
        app.press(.id("session-\(session.id)"))
        app.wait(for: .id("worktree-menu"), timeout: 15)
        app.wait(for: .containing("worktree-only.txt"), timeout: 15)
        XCTAssertFalse(app.exists(.containing("notes.txt")), "the project's own changes are not the worktree's")
        shot("worktree")
    }
}
