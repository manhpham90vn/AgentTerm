import AgentTermProtocol
import XCTest

/// The Git tab of the Mac app: changes, staging, the commit message, commit, push.
final class GitTests: MacUITestCase {
    func testStagingWritingTheMessageCommittingAndPushing() throws {
        app.press(.button("Git"))
        // GIT-1: what changed, by file.
        app.wait(for: .button("Stage notes.txt"))
        XCTAssertTrue(app.exists(.button("Stage new.txt")))
        XCTAssertTrue(app.exists(.button("Stage guide.md")), "a new file in a new folder is not listed")

        // GIT-2: one file, then the rest, then one back.
        app.press(.button("Stage notes.txt"))
        app.wait(for: .button("Unstage notes.txt"))
        XCTAssertEqual(git("diff", "--cached", "--name-only", in: project), "notes.txt")
        app.press(.button("Stage all"))
        app.wait(for: .button("Unstage new.txt"))
        app.press(.button("Unstage new.txt"))
        app.wait(for: .button("Stage new.txt"))
        XCTAssertEqual(Set(git("diff", "--cached", "--name-only", in: project).split(separator: "\n").map(String.init)), ["notes.txt", "docs/guide.md"])

        // GIT-10: an agent writes the message into the field, and commits nothing.
        app.press(.containing("Write the commit message with"))
        wait("the message the stand-in wrote", timeout: 30) { self.app.value(of: .text("Commit message")) == "feat: written by the stand-in claude" }
        XCTAssertEqual(git("log", "--oneline", in: project).split(separator: "\n").count, 1, "writing the message committed")

        // GIT-3: the message can be changed, and Commit commits what is staged.
        app.write("docs: a guide, and a second line", into: .text("Commit message"), confirm: true)
        app.press(.containing("Commit 2 Files"))
        wait("the commit") { self.git("log", "-1", "--format=%s", in: self.project) == "docs: a guide, and a second line" }
        // What was committed leaves the list, what was not stays, and the field is empty again.
        app.waitGone(.button("Unstage notes.txt"))
        XCTAssertTrue(app.exists(.button("Stage new.txt")))
        wait("the field to be emptied") { (self.app.value(of: .text("Commit message")) ?? "").isEmpty }

        // GIT-7: one commit to push, and the remote has it afterwards.
        app.press(.containing("Push"))
        wait("the push to reach the remote", timeout: 20) { self.git("log", "-1", "--format=%s", "main", in: self.remote) == "docs: a guide, and a second line" }
    }

    /// GIT-22 (#39): a change is discarded from its row, and all of them
    /// from the list's header, each after being asked; a new file goes to
    /// the Trash.
    func testDiscardingAChangeAndAllOfThem() throws {
        let trash = home.appendingPathComponent(".Trash-of-the-tests")
        app.press(.button("Git"))
        app.wait(for: .button("Stage notes.txt"))

        // Asked first, and Cancel leaves everything as it was.
        app.press(.button("Discard changes to notes.txt"))
        app.wait(for: .containing("Discard the changes to notes.txt?"))
        shot("asked")
        app.press(.button("Cancel"))
        app.waitGone(.containing("Discard the changes to notes.txt?"))
        XCTAssertTrue(git("status", "--porcelain", in: project).contains("notes.txt"))

        app.press(.button("Discard changes to notes.txt"))
        app.press(.button("Discard Changes"))
        app.waitGone(.button("Stage notes.txt"))
        XCTAssertFalse(git("status", "--porcelain", in: project).contains("notes.txt"), "back to what was committed")
        XCTAssertTrue(app.exists(.button("Stage new.txt")), "the others are left")

        // Every change: the new files are in the Trash, not gone.
        app.press(.button("Discard all"))
        app.wait(for: .containing("Discard all 2 changes?"))
        app.press(.button("Discard All"))
        app.wait(for: .containing("No uncommitted changes."))
        XCTAssertEqual(git("status", "--porcelain", in: project), "")
        XCTAssertEqual(try String(contentsOf: trash.appendingPathComponent("new.txt"), encoding: .utf8), "a file that is new\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: trash.appendingPathComponent("docs/guide.md").path), "its folder went whole")
    }

    /// GIT-28 (#35): the header's branch opens the branches; one is made
    /// and checked out, the first is switched back to, and the new one is
    /// deleted after being asked.
    func testMakingSwitchingAndDeletingABranch() throws {
        app.press(.button("Git"))
        app.wait(for: .id("branch-menu"))
        XCTAssertEqual(git("branch", "--show-current", in: project), "main")

        app.press(.id("branch-menu"))
        app.wait(for: .id("branch-main"))
        shot("branches")
        app.press(.id("new-branch"))
        app.write("feature/ui", into: .id("new-branch-name"))
        app.press(.id("new-branch-create"))
        wait("the new branch to be checked out") { self.git("branch", "--show-current", in: self.project) == "feature/ui" }
        app.wait(for: .containing("Branch feature/ui"))
        // The changes that were not committed came along: nothing is lost.
        XCTAssertTrue(app.exists(.button("Stage notes.txt")))

        app.press(.id("branch-menu"))
        app.press(.id("branch-main"))
        wait("main to be checked out again") { self.git("branch", "--show-current", in: self.project) == "main" }

        // Everything on the new branch is on main: asked once.
        app.press(.id("branch-menu"))
        app.wait(for: .id("branch-feature/ui"))
        app.perform("Delete", on: .id("branch-feature/ui"))
        app.wait(for: .containing("Delete the branch “feature/ui”?"))
        app.press(.button("Delete Branch"))
        wait("the branch to be deleted") { !self.git("branch", "--list", "feature/ui", in: self.project).contains("feature/ui") }
        app.waitGone(.id("branch-feature/ui"))
    }

    /// GIT-34 (#37): Fetch says what the remote has; a forced push is asked
    /// about with the commits it would overwrite, and then overwrites them.
    func testFetchingAndForcingAPush() throws {
        // Someone else pushes a commit.
        let theirs = root.appendingPathComponent("theirs")
        git("clone", "-q", remote.path, theirs.path, in: root)
        git("config", "user.name", "Other", in: theirs)
        git("config", "user.email", "other@example.com", in: theirs)
        git("config", "commit.gpgsign", "false", in: theirs)
        try write("theirs\n", to: "theirs.txt", in: theirs)
        git("add", ".", in: theirs)
        git("commit", "-q", "-m", "theirs: a file", in: theirs)
        git("push", "-q", "origin", "HEAD:main", in: theirs)

        app.press(.button("Git"))
        app.wait(for: .button("Fetch"))
        app.press(.button("Fetch"))
        // One commit to pull, known without pulling it.
        app.wait(for: .button("Pull, 1"), timeout: 20)
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent("theirs.txt").path), "fetching changed the files")

        // A commit of this side's, so that there is something to force.
        git("commit", "-q", "--allow-empty", "-m", "mine", in: project)
        app.press(.id("sync-more"))
        app.press(.button("Force Push…"), menus: true)
        app.wait(for: .containing("Force push “main” to origin/main?"), timeout: 20)
        app.wait(for: .containing("theirs: a file"))
        shot("asked")
        app.press(.button("Force Push"))
        wait("the remote to be overwritten", timeout: 20) { self.git("log", "-1", "--format=%s", "main", in: self.remote) == "mine" }
        XCTAssertFalse(git("log", "--format=%s", "main", in: remote).contains("theirs: a file"))
    }

    func testARefusedCommitSaysWhatGitSaid() throws {
        // A hook that refuses every commit, as a project's own checks may.
        let hook = project.appendingPathComponent(".git/hooks/pre-commit")
        try "#!/bin/sh\necho 'the checks of this project failed' >&2\nexit 1\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        app.press(.button("Git"))
        app.press(.button("Stage notes.txt"))
        app.wait(for: .button("Unstage notes.txt"))
        app.write("fix: will be refused", into: .text("Commit message"), confirm: true)
        app.press(.containing("Commit 1 File"))
        // GIT-3: git's own words, and nothing lost.
        app.wait(for: .containing("the checks of this project failed"))
        XCTAssertEqual(git("log", "--oneline", in: project).split(separator: "\n").count, 1)
        XCTAssertEqual(app.value(of: .text("Commit message")), "fix: will be refused", "a refused commit lost its message")
    }

    func testAChangeOpensItsDiffInOnePanelAndInTwo() throws {
        app.press(.button("Git"))
        app.wait(for: .button("Stage notes.txt"))
        // GIT-4: picking a change shows its diff as a tab in the middle.
        app.press(.id("change-notes.txt"))
        app.wait(for: .containing("+second line"))
        // In two panels the line is on the side of what the file is now, without its mark.
        app.press(.button("Show side by side"))
        app.wait(for: .id("split-diff"))
        app.wait(for: .text("second line"))
        app.press(.button("Show in one panel"))
        app.wait(for: .containing("+second line"))
    }

    func testChangesMadeOnAnotherDeviceShowHere() throws {
        let phone = try device()
        app.press(.button("Git"))
        app.wait(for: .button("Stage notes.txt"))
        // GIT-12: staged and committed from the phone, gone from the Mac's list.
        phone.send(.gitStage(path: project.path, files: []))
        app.wait(for: .button("Unstage notes.txt"), timeout: 15)
        phone.send(.gitCommit(path: project.path, message: "feat: from the phone"))
        app.wait(for: .containing("No uncommitted changes"), timeout: 15)
        XCTAssertEqual(git("log", "-1", "--format=%s", in: project), "feat: from the phone")
    }
}
