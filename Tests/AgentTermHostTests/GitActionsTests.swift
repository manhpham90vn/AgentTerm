import AgentTermProtocol
import XCTest

@testable import AgentTermHost

final class GitActionsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-gitactions-\(UUID().uuidString)").standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        git("init", "-q", "-b", "main")
        // An identity of the test's own, and no signing, whatever the machine is set up with.
        git("config", "user.name", "Test")
        git("config", "user.email", "test@example.com")
        git("config", "commit.gpgsign", "false")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func git(_ arguments: String...) -> String {
        let result = Subprocess.run("/usr/bin/git", ["-C", root.path] + arguments)
        return String(decoding: result?.output ?? Data(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func write(_ name: String, _ text: String) throws {
        try text.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func entries(_ files: [FileDiff]) -> [String] { files.map { "\($0.marker) \($0.path)" } }
    private var snapshot: DiffSnapshot { GitDiff.snapshot(directory: root.path) }

    /// GIT-53 (#40): a hunk of a file's change, or lines of one, is staged,
    /// unstaged and discarded, and the rest of the change is left as it was.
    func testStagingUnstagingAndDiscardingPartsOfAFile() throws {
        try write("a.txt", (1...10).map { "line \($0)\n" }.joined())
        git("add", ".")
        git("commit", "-q", "-m", "init")
        // Line 2 changed, a line put in after 5, line 8 taken out: one hunk.
        try write("a.txt", "line 1\nLINE TWO\nline 3\nline 4\nline 5\nnew line\nline 6\nline 7\nline 9\nline 10\n")
        func changes(staged: Bool) -> [String] {
            (staged ? snapshot.staged : snapshot.unstaged).first { $0.path == "a.txt" }.map { file in
                file.patch.split(separator: "\n").map(String.init).filter { $0.hasPrefix("+") || $0.hasPrefix("-") }
            } ?? []
        }
        XCTAssertEqual(changes(staged: false), ["-line 2", "+LINE TWO", "+new line", "-line 8"])

        // The change to line 2 alone is staged; the other two stay.
        var hunk = try XCTUnwrap(PatchParts.hunks(of: try XCTUnwrap(snapshot.unstaged.first).patch).first)
        let two = Set(hunk.changed.filter { hunk.lines[$0].lowercased().contains("two") || hunk.lines[$0] == "-line 2" })
        XCTAssertNil(GitActions.applyPart(try XCTUnwrap(PatchParts.patch(path: "a.txt", hunk: hunk, picked: two, use: .stage)), use: .stage, file: "a.txt", in: root.path))
        XCTAssertEqual(changes(staged: true), ["-line 2", "+LINE TWO"])
        XCTAssertEqual(changes(staged: false), ["+new line", "-line 8"])

        // Of what is left, the line that was put in is discarded: it goes from the file.
        hunk = try XCTUnwrap(PatchParts.hunks(of: try XCTUnwrap(snapshot.unstaged.first).patch).first { $0.lines.contains("+new line") })
        let put = Set(hunk.changed.filter { hunk.lines[$0] == "+new line" })
        XCTAssertNil(GitActions.applyPart(try XCTUnwrap(PatchParts.patch(path: "a.txt", hunk: hunk, picked: put, use: .discard)), use: .discard, file: "a.txt", in: root.path))
        XCTAssertFalse(try String(contentsOf: root.appendingPathComponent("a.txt"), encoding: .utf8).contains("new line"))
        XCTAssertEqual(changes(staged: false), ["-line 8"])
        XCTAssertEqual(changes(staged: true), ["-line 2", "+LINE TWO"], "what is staged is as it was")

        // The staged hunk is unstaged whole: it is among the changes again.
        hunk = try XCTUnwrap(PatchParts.hunks(of: try XCTUnwrap(snapshot.staged.first).patch).first)
        XCTAssertNil(GitActions.applyPart(try XCTUnwrap(PatchParts.patch(path: "a.txt", hunk: hunk, use: .unstage)), use: .unstage, file: "a.txt", in: root.path))
        XCTAssertEqual(snapshot.staged, [])
        XCTAssertEqual(changes(staged: false), ["-line 2", "+LINE TWO", "-line 8"])

        // A part of a diff the file has moved on from is refused in words,
        // and the file is left as it is.
        hunk = try XCTUnwrap(PatchParts.hunks(of: try XCTUnwrap(snapshot.unstaged.first).patch).first)
        let stale = try XCTUnwrap(PatchParts.patch(path: "a.txt", hunk: hunk, use: .discard))
        try write("a.txt", "something else entirely\n")
        let refused = try XCTUnwrap(GitActions.applyPart(stale, use: .discard, file: "a.txt", in: root.path))
        XCTAssertTrue(refused.hasPrefix("That part no longer fits the file"), refused)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("a.txt"), encoding: .utf8), "something else entirely\n")
    }

    /// GIT-53: a part of a file git does not track yet, and of one that
    /// does not end with a newline.
    func testPartsOfANewFileAndOfOneWithoutAFinalNewline() throws {
        try write("e.txt", "a\nb")
        git("add", ".")
        git("commit", "-q", "-m", "init")
        try write("n.txt", "first\nsecond\n")
        var hunk = try XCTUnwrap(PatchParts.hunks(of: try XCTUnwrap(snapshot.unstaged.first { $0.path == "n.txt" }).patch).first)
        XCTAssertEqual(hunk.changed.count, 2)
        let patch = try XCTUnwrap(PatchParts.patch(path: "n.txt", hunk: hunk, picked: [hunk.changed[0]], use: .stage))
        XCTAssertNil(GitActions.applyPart(patch, use: .stage, file: "n.txt", in: root.path))
        XCTAssertEqual(git("show", ":n.txt"), "first", "its first line is staged")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("n.txt"), encoding: .utf8), "first\nsecond\n")

        try write("e.txt", "a\nB")
        hunk = try XCTUnwrap(PatchParts.hunks(of: try XCTUnwrap(snapshot.unstaged.first { $0.path == "e.txt" }).patch).first)
        XCTAssertNil(GitActions.applyPart(try XCTUnwrap(PatchParts.patch(path: "e.txt", hunk: hunk, use: .stage)), use: .stage, file: "e.txt", in: root.path))
        XCTAssertEqual(git("show", ":e.txt"), "a\nB")
    }

    /// GIT-49 (#41): the last commit is amended, its message and what is
    /// staged now; and undone, with what it changed left staged.
    func testAmendingAndUndoingTheLastCommit() throws {
        XCTAssertNil(GitActions.lastCommit(in: root.path), "no commit yet")
        XCTAssertEqual(GitActions.amend(message: "x", in: root.path), "There is no commit to amend yet.")
        XCTAssertEqual(GitActions.undoLastCommit(in: root.path), "There is no commit to undo yet.")

        try write("a.txt", "one\n")
        git("add", ".")
        git("commit", "-q", "-m", "init")
        try write("a.txt", "one\ntwo\n")
        git("commit", "-q", "-am", "add two\n\nWith a body.")
        let before = try XCTUnwrap(GitActions.lastCommit(in: root.path))
        XCTAssertEqual(before.commit.subject, "add two")
        XCTAssertEqual(before.message, "add two\n\nWith a body.")
        XCTAssertFalse(before.isPushed)

        // Its message alone.
        XCTAssertNil(GitActions.amend(message: "feat: add a second line", in: root.path))
        XCTAssertEqual(git("log", "-1", "--format=%B"), "feat: add a second line")
        XCTAssertEqual(git("rev-list", "--count", "HEAD"), "2", "amended, not added to")
        // What is staged now goes into it; no message keeps the one it has.
        try write("b.txt", "forgotten\n")
        git("add", "b.txt")
        XCTAssertNil(GitActions.amend(message: "  ", in: root.path))
        XCTAssertEqual(git("log", "-1", "--format=%s"), "feat: add a second line")
        XCTAssertEqual(git("show", "--name-only", "--format=", "HEAD"), "a.txt\nb.txt")
        XCTAssertEqual(git("rev-list", "--count", "HEAD"), "2")

        // Undone: the branch is at the commit before, and its change is staged.
        try write("c.txt", "not staged\n")
        XCTAssertNil(GitActions.undoLastCommit(in: root.path))
        XCTAssertEqual(git("log", "-1", "--format=%s"), "init")
        XCTAssertEqual(entries(snapshot.staged), ["M a.txt", "A b.txt"])
        XCTAssertEqual(entries(snapshot.unstaged), ["U c.txt"], "what was not committed is as it was")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("a.txt"), encoding: .utf8), "one\ntwo\n")

        // The first commit too: the branch has no commit again, and its file is staged.
        git("reset", "-q", "--hard")
        XCTAssertNil(GitActions.undoLastCommit(in: root.path))
        XCTAssertNil(GitActions.lastCommit(in: root.path))
        XCTAssertTrue(entries(snapshot.staged).contains("A a.txt"))
    }

    /// GIT-49: a commit a remote has already is said to be pushed.
    func testACommitThatIsPushedIsSaidToBe() throws {
        let remote = FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-gitactions-remote-\(UUID().uuidString).git")
        defer { try? FileManager.default.removeItem(at: remote) }
        _ = Subprocess.run("/usr/bin/git", ["init", "-q", "--bare", "-b", "main", remote.path])
        try write("a.txt", "one\n")
        git("add", ".")
        git("commit", "-q", "-m", "init")
        git("remote", "add", "origin", remote.path)
        git("push", "-q", "-u", "origin", "main")
        XCTAssertEqual(GitActions.lastCommit(in: root.path)?.isPushed, true)
        try write("a.txt", "one\ntwo\n")
        git("commit", "-q", "-am", "not pushed")
        XCTAssertEqual(GitActions.lastCommit(in: root.path)?.isPushed, false)
    }

    /// GIT-44 (#38): changes are put aside under a name, with new files
    /// when asked; the stash lists them, newest first, and says what each
    /// holds.
    func testStashingChangesAndWhatAStashHolds() throws {
        try write("a.txt", "one\n")
        git("add", ".")
        git("commit", "-q", "-m", "init")
        XCTAssertEqual(GitActions.stash(message: "nothing", untracked: true, in: root.path), "There is no change to stash.")
        XCTAssertEqual(GitActions.stashes(in: root.path), [])

        try write("new.txt", "mine\n")
        XCTAssertEqual(
            GitActions.stash(message: "", untracked: false, in: root.path), "Only new files have changed: stash them too, or there is nothing to stash.")
        try write("a.txt", "one\ntwo\n")
        // Without the new files: they stay where they are.
        XCTAssertNil(GitActions.stash(message: "  half of the login ", untracked: false, in: root.path))
        XCTAssertEqual(entries(snapshot.unstaged), ["U new.txt"])
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("a.txt"), encoding: .utf8), "one\n")

        try write("a.txt", "one\nthree\n")
        git("add", "a.txt")
        // With them, and with what is staged: the folder is as committed. No name: git's own.
        XCTAssertNil(GitActions.stash(message: "", untracked: true, in: root.path))
        XCTAssertEqual(snapshot.files, [])

        let list = GitActions.stashes(in: root.path)
        XCTAssertEqual(list.map(\.ref), ["stash@{0}", "stash@{1}"])
        XCTAssertEqual(list[1].message, "half of the login")
        XCTAssertEqual(list[1].branch, "main")
        XCTAssertTrue(list[0].message.hasPrefix("Changes on "), list[0].message)
        XCTAssertTrue(list[0].message.hasSuffix("init"), list[0].message)
        XCTAssertEqual(list[0].hash.count, 40)

        let older = try XCTUnwrap(GitActions.stashFiles(list[1].hash, in: root.path))
        XCTAssertEqual(older.map { "\($0.marker) \($0.path)" }, ["M a.txt"])
        XCTAssertTrue(older[0].patch.contains("+two"))
        let newer = try XCTUnwrap(GitActions.stashFiles(list[0].hash, in: root.path))
        XCTAssertEqual(Set(newer.map(\.path)), ["a.txt", "new.txt"], "the new file is part of it")
        XCTAssertTrue(newer.first { $0.path == "new.txt" }?.patch.contains("+mine") == true)
        XCTAssertNil(GitActions.stashFiles("0000000000000000000000000000000000000000", in: root.path))
    }

    /// GIT-45 (#38): a stash is applied and kept, popped and gone, and
    /// dropped; one that conflicts says so and is kept; a stash is named by
    /// its commit, so another being dropped does not make it another.
    func testApplyingPoppingAndDroppingAStash() throws {
        try write("a.txt", "one\n")
        git("add", ".")
        git("commit", "-q", "-m", "init")
        try write("a.txt", "one\nfirst\n")
        XCTAssertNil(GitActions.stash(message: "first", untracked: false, in: root.path))
        try write("b.txt", "second\n")
        XCTAssertNil(GitActions.stash(message: "second", untracked: true, in: root.path))
        var list = GitActions.stashes(in: root.path)
        XCTAssertEqual(list.map(\.message), ["second", "first"])
        let first = list[1], second = list[0]

        // Applied: its change is back, and it is still in the stash.
        XCTAssertNil(GitActions.applyStash(first.hash, pop: false, in: root.path))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("a.txt"), encoding: .utf8), "one\nfirst\n")
        XCTAssertEqual(GitActions.stashes(in: root.path).count, 2)

        // Applied again onto another change to the same line: it conflicts, says so, and is kept.
        git("checkout", "-q", "--", "a.txt")
        try write("a.txt", "one\nsomething else\n")
        git("commit", "-q", "-am", "something else")
        let conflict = try XCTUnwrap(GitActions.applyStash(first.hash, pop: true, in: root.path))
        XCTAssertTrue(conflict.hasPrefix("The stash conflicts with what is in the folder now."), conflict)
        XCTAssertEqual(GitActions.stashes(in: root.path).count, 2, "a pop that conflicts keeps the stash")
        git("checkout", "-q", "HEAD", "--", "a.txt")

        // The newer one is dropped: the older is the same stash, at another place.
        XCTAssertNil(GitActions.dropStash(second.hash, in: root.path))
        list = GitActions.stashes(in: root.path)
        XCTAssertEqual(list.map(\.hash), [first.hash])
        XCTAssertEqual(list[0].ref, "stash@{0}")
        XCTAssertEqual(GitActions.dropStash(second.hash, in: root.path), "That stash is no longer there.")
        XCTAssertEqual(GitActions.applyStash(second.hash, pop: false, in: root.path), "That stash is no longer there.")

        // Popped onto a folder it fits: back, and gone from the stash.
        git("reset", "-q", "--hard", "HEAD~1")
        XCTAssertNil(GitActions.applyStash(first.hash, pop: true, in: root.path))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("a.txt"), encoding: .utf8), "one\nfirst\n")
        XCTAssertEqual(GitActions.stashes(in: root.path), [])
    }

    /// GIT-37 (#36): the commits of a branch, newest first and a page at a
    /// time, with their parents and what points at them; and what one of
    /// them changed.
    func testTheHistoryOfABranchAndWhatACommitChanged() throws {
        try write("a.txt", "one\n")
        git("add", ".")
        git("commit", "-q", "-m", "init")
        for number in 1...5 {
            try write("a.txt", "one\n" + String(repeating: "more\n", count: number))
            git("commit", "-q", "-am", "change \(number)")
        }
        git("tag", "v1")
        git("switch", "-q", "-c", "side", "HEAD~2")
        try write("b.txt", "side\n")
        git("add", ".")
        git("commit", "-q", "-m", "on the side\n\nWith a body\nof two lines.")
        git("switch", "-q", "main")
        git("merge", "-q", "--no-ff", "--no-edit", "side")

        // Commits made in the same second are in no order git promises:
        // they are looked up by what they say.
        let all = GitActions.log(in: root.path, limit: 50).commits
        XCTAssertEqual(all.first?.subject, "Merge branch 'side'", "the newest first")
        XCTAssertEqual(all.last?.subject, "init")
        XCTAssertEqual(Set(all.map(\.subject)), ["Merge branch 'side'", "on the side", "change 5", "change 4", "change 3", "change 2", "change 1", "init"])
        func commit(_ subject: String) throws -> CommitInfo { try XCTUnwrap(all.first { $0.subject == subject }) }
        let merge = try commit("Merge branch 'side'")
        XCTAssertTrue(merge.isMerge)
        XCTAssertEqual(merge.parents, [try commit("change 5").hash, try commit("on the side").hash])
        XCTAssertEqual(merge.refs, ["main"])
        XCTAssertEqual(try commit("on the side").refs, ["side"])
        XCTAssertEqual(try commit("change 5").refs, ["tag: v1"])
        XCTAssertEqual(try commit("on the side").author, "Test")
        XCTAssertEqual(try commit("on the side").parents, [try commit("change 3").hash])
        XCTAssertEqual(merge.short.count, 7)

        // A page at a time: the same commits, in the same order, and whether there are more.
        let first = GitActions.log(in: root.path, limit: 3)
        XCTAssertEqual(first.commits, Array(all.prefix(3)))
        XCTAssertTrue(first.more)
        let rest = GitActions.log(in: root.path, skip: 3, limit: 50)
        XCTAssertEqual(rest.commits, Array(all.dropFirst(3)))
        XCTAssertFalse(rest.more)
        // Another branch's, by name.
        XCTAssertEqual(GitActions.log(in: root.path, branch: "side", limit: 2).commits.map(\.subject), ["on the side", "change 3"])
        XCTAssertEqual(GitActions.log(in: root.path, branch: "no-such", limit: 2).commits, [])

        // What a commit changed, with the rest of its message.
        let side = try XCTUnwrap(GitActions.show(try commit("on the side").hash, in: root.path))
        XCTAssertEqual(side.commit, try commit("on the side"))
        XCTAssertEqual(side.body, "With a body\nof two lines.")
        XCTAssertEqual(side.files.map { "\($0.marker) \($0.path)" }, ["A b.txt"])
        XCTAssertTrue(side.files[0].patch.contains("+side"))
        XCTAssertFalse(side.diffsLeftOut)
        // A merge: what it brought in, against its first parent.
        let brought = try XCTUnwrap(GitActions.show(merge.hash, in: root.path))
        XCTAssertEqual(brought.files.map(\.path), ["b.txt"])
        XCTAssertNil(GitActions.show("0000000000000000000000000000000000000000", in: root.path))
    }

    /// GIT-38 (#36): a commit is reverted, and one of another branch is
    /// picked onto this one; one that conflicts is left to be resolved; a
    /// merge is said to be for a terminal.
    func testRevertingAndCherryPickingACommit() throws {
        try write("a.txt", "one\n")
        git("add", ".")
        git("commit", "-q", "-m", "init")
        try write("a.txt", "one\ntwo\n")
        git("commit", "-q", "-am", "add two")
        let addTwo = git("rev-parse", "HEAD")

        XCTAssertNil(GitActions.revert(addTwo, in: root.path))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("a.txt"), encoding: .utf8), "one\n")
        XCTAssertTrue(git("log", "-1", "--format=%s").hasPrefix("Revert \"add two\""))

        git("switch", "-q", "-c", "side")
        try write("c.txt", "from the side\n")
        git("add", ".")
        git("commit", "-q", "-m", "a file on the side")
        let onSide = git("rev-parse", "HEAD")
        try write("a.txt", "side's line\n")
        git("commit", "-q", "-am", "side rewrites a")
        let rewrites = git("rev-parse", "HEAD")
        git("switch", "-q", "main")

        XCTAssertNil(GitActions.cherryPick(onSide, in: root.path))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("c.txt"), encoding: .utf8), "from the side\n")
        XCTAssertEqual(git("log", "-1", "--format=%s"), "a file on the side")

        // One that conflicts is left to be resolved (#42): said so, and aborted here.
        try write("a.txt", "main's line\n")
        git("commit", "-q", "-am", "main rewrites a")
        let head = git("rev-parse", "HEAD")
        let stopped = try XCTUnwrap(GitActions.cherryPick(rewrites, in: root.path))
        XCTAssertTrue(stopped.hasPrefix("Picking \(rewrites.prefix(7)) stopped on conflicts."), stopped)
        XCTAssertEqual(snapshot.operation, .cherryPick)
        XCTAssertEqual(snapshot.conflicts.map(\.path), ["a.txt"])
        XCTAssertNil(GitActions.abortOperation(in: root.path))
        XCTAssertEqual(git("rev-parse", "HEAD"), head)
        XCTAssertEqual(git("status", "--porcelain"), "")
        // Picked again, resolved by taking the commit's side, and continued.
        _ = GitActions.cherryPick(rewrites, in: root.path)
        XCTAssertNil(GitActions.resolve("a.txt", as: .theirs, in: root.path))
        XCTAssertNil(GitActions.continueOperation(in: root.path))
        XCTAssertEqual(git("log", "-1", "--format=%s"), "side rewrites a")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("a.txt"), encoding: .utf8), "side's line\n")
        git("reset", "-q", "--hard", head)
        // So is a revert: the line "add two" added is no longer what is there.
        let undone = try XCTUnwrap(GitActions.revert(addTwo, in: root.path))
        XCTAssertTrue(undone.hasPrefix("Reverting \(addTwo.prefix(7)) stopped on conflicts."), undone)
        XCTAssertEqual(snapshot.operation, .revert)
        XCTAssertNil(GitActions.abortOperation(in: root.path))
        XCTAssertEqual(git("rev-parse", "HEAD"), head)
        XCTAssertEqual(git("status", "--porcelain"), "")

        // A merge needs to be told which side to keep.
        git("merge", "-q", "--no-ff", "--no-edit", "-X", "ours", "side")
        let merge = git("rev-parse", "HEAD")
        XCTAssertTrue(try XCTUnwrap(GitActions.revert(merge, in: root.path)).contains("is a merge of 2 lines of history"))
        XCTAssertEqual(GitActions.revert("0000000000000000000000000000000000000000", in: root.path), "There is no commit 0000000000000000000000000000000000000000 here.")
    }

    /// GIT-24 (#35): the branches of a repository, its own and a remote's,
    /// with which is checked out, what each follows and how far it is.
    func testTheBranchesOfARepository() throws {
        let remote = FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-gitactions-remote-\(UUID().uuidString).git")
        defer { try? FileManager.default.removeItem(at: remote) }
        _ = Subprocess.run("/usr/bin/git", ["init", "-q", "--bare", "-b", "main", remote.path])
        try write("a.txt", "one\n")
        git("add", ".")
        git("commit", "-q", "-m", "init")
        git("remote", "add", "origin", remote.path)
        git("push", "-q", "-u", "origin", "main")
        git("switch", "-q", "-c", "feature/login")
        try write("a.txt", "one\ntwo\n")
        git("commit", "-q", "-am", "feat: a second line\twith a tab")
        git("push", "-q", "-u", "origin", "feature/login")
        try write("a.txt", "one\ntwo\nthree\n")
        git("commit", "-q", "-am", "feat: a third line")
        git("branch", "merged-already", "main")
        git("switch", "-q", "main")

        let all = GitActions.branches(in: root.path)
        XCTAssertEqual(
            all.map(\.id),
            ["main", "feature/login", "merged-already", "remote:origin/feature/login", "remote:origin/main"].sorted { a, b in
                // Its own first, the checked out one before the rest; then the remote's.
                let order = ["main", "feature/login", "merged-already", "remote:origin/feature/login", "remote:origin/main"]
                return order.firstIndex(of: a)! < order.firstIndex(of: b)!
            })
        let main = try XCTUnwrap(all.first { $0.id == "main" })
        XCTAssertTrue(main.isCurrent)
        XCTAssertEqual(main.upstream, "origin/main")
        XCTAssertEqual(main.tracking, "")
        let feature = try XCTUnwrap(all.first { $0.id == "feature/login" })
        XCTAssertFalse(feature.isCurrent)
        XCTAssertEqual(feature.upstream, "origin/feature/login")
        XCTAssertEqual(feature.ahead, 1)
        XCTAssertEqual(feature.tracking, "1 ahead")
        XCTAssertEqual(feature.subject, "feat: a third line")
        XCTAssertFalse(feature.isMerged, "it has commits main has not")
        XCTAssertTrue(try XCTUnwrap(all.first { $0.id == "merged-already" }).isMerged)
        let theirs = try XCTUnwrap(all.first { $0.id == "remote:origin/feature/login" })
        XCTAssertTrue(theirs.isRemote)
        XCTAssertEqual(theirs.localName, "feature/login")
        XCTAssertEqual(theirs.subject, "feat: a second line\twith a tab")
        XCTAssertEqual(GitActions.branches(in: FileManager.default.temporaryDirectory.path), [], "not a repository")
    }

    /// GIT-25 (#35): a branch is checked out, made, renamed and deleted; a
    /// switch that would lose changes is refused in words; a branch with
    /// commits of its own is deleted only when forced.
    func testSwitchingMakingRenamingAndDeletingABranch() throws {
        try write("a.txt", "one\n")
        git("add", ".")
        git("commit", "-q", "-m", "init")

        // Made from the checked out commit, and checked out or not.
        XCTAssertNil(GitActions.createBranch(" feature/x ", from: nil, checkout: true, in: root.path))
        XCTAssertEqual(git("branch", "--show-current"), "feature/x")
        try write("a.txt", "one\non the feature\n")
        git("commit", "-q", "-am", "feat: on the feature")
        XCTAssertNil(GitActions.createBranch("from-main", from: "main", checkout: false, in: root.path))
        XCTAssertEqual(git("branch", "--show-current"), "feature/x")
        XCTAssertEqual(git("rev-parse", "from-main"), git("rev-parse", "main"))
        XCTAssertEqual(GitActions.createBranch("  ", from: nil, checkout: false, in: root.path), "Give the branch a name.")
        XCTAssertTrue(GitActions.createBranch("has space", from: nil, checkout: false, in: root.path)?.contains("cannot be the name of a branch") == true)
        XCTAssertNotNil(GitActions.createBranch("main", from: nil, checkout: false, in: root.path), "a name that is taken is refused by git")

        // Switching that would lose a change is refused, and nothing is lost.
        XCTAssertNil(GitActions.switchTo("main", in: root.path))
        XCTAssertEqual(git("branch", "--show-current"), "main")
        try write("a.txt", "one\nmine, not committed\n")
        let refused = try XCTUnwrap(GitActions.switchTo("feature/x", in: root.path))
        XCTAssertTrue(refused.hasPrefix("Switching to feature/x would lose changes that are not committed."), refused)
        XCTAssertEqual(git("branch", "--show-current"), "main")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("a.txt"), encoding: .utf8), "one\nmine, not committed\n")
        git("checkout", "-q", "--", "a.txt")
        XCTAssertNotNil(GitActions.switchTo("no-such-branch", in: root.path))

        // Renamed.
        XCTAssertNil(GitActions.renameBranch("from-main", to: "spare", in: root.path))
        XCTAssertTrue(GitActions.branches(in: root.path).contains { $0.name == "spare" })
        XCTAssertFalse(GitActions.branches(in: root.path).contains { $0.name == "from-main" })
        XCTAssertNotNil(GitActions.renameBranch("spare", to: "bad name", in: root.path))

        // A merged branch is deleted; one with commits of its own only when forced.
        XCTAssertNil(GitActions.deleteBranch("spare", force: false, in: root.path))
        let kept = try XCTUnwrap(GitActions.deleteBranch("feature/x", force: false, in: root.path))
        XCTAssertTrue(kept.contains("not fully merged"), kept)
        XCTAssertTrue(GitActions.branches(in: root.path).contains { $0.name == "feature/x" })
        XCTAssertNil(GitActions.deleteBranch("feature/x", force: true, in: root.path))
        XCTAssertEqual(GitActions.branches(in: root.path).map(\.name), ["main"])
        XCTAssertNotNil(GitActions.deleteBranch("main", force: true, in: root.path), "the checked out branch is not deleted")
    }

    /// GIT-25: a remote's branch is checked out as one of the repository's
    /// own that follows it, made the first time and used from then on.
    func testSwitchingToARemotesBranch() throws {
        let remote = FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-gitactions-remote-\(UUID().uuidString).git")
        defer { try? FileManager.default.removeItem(at: remote) }
        _ = Subprocess.run("/usr/bin/git", ["init", "-q", "--bare", "-b", "main", remote.path])
        try write("a.txt", "one\n")
        git("add", ".")
        git("commit", "-q", "-m", "init")
        git("remote", "add", "origin", remote.path)
        git("push", "-q", "-u", "origin", "main")
        git("push", "-q", "origin", "main:review")
        git("fetch", "-q", "origin")
        XCTAssertFalse(GitActions.branches(in: root.path).contains { !$0.isRemote && $0.name == "review" })

        XCTAssertNil(GitActions.switchTo("origin/review", in: root.path))
        XCTAssertEqual(git("branch", "--show-current"), "review")
        XCTAssertEqual(GitActions.branches(in: root.path).first { $0.name == "review" }?.upstream, "origin/review")
        XCTAssertNil(GitActions.switchTo("main", in: root.path))
        XCTAssertNil(GitActions.switchTo("origin/review", in: root.path), "the branch that is there is used")
        XCTAssertEqual(git("branch", "--show-current"), "review")
    }

    /// GIT-20 (#39): discarding takes back what is not staged, and moves a
    /// file git does not track to the Trash; what is staged stays.
    func testDiscardingChangesThatAreNotStaged() throws {
        let trash = FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-trash-\(UUID().uuidString)")
        setenv(FileBrowser.trashVariable, trash.path, 1)
        defer {
            unsetenv(FileBrowser.trashVariable)
            try? FileManager.default.removeItem(at: trash)
        }
        try write("a.txt", "one\n")
        try write("b.txt", "one\n")
        try write("gone.txt", "kept\n")
        git("add", ".")
        git("commit", "-q", "-m", "init")
        try write("a.txt", "one\nstaged\n")
        git("add", "a.txt")
        try write("a.txt", "one\nstaged\nnot staged\n")
        try write("b.txt", "changed\n")
        try FileManager.default.removeItem(at: root.appendingPathComponent("gone.txt"))
        try write("new file.txt", "mine\n")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("made/deep"), withIntermediateDirectories: true)
        try write("made/deep/x.txt", "x\n")
        XCTAssertEqual(entries(snapshot.unstaged), ["M a.txt", "M b.txt", "D gone.txt", "U made/deep/x.txt", "U new file.txt"])

        // One file git tracks: back to what is staged of it, not further.
        XCTAssertNil(GitActions.discard(["a.txt"], in: root.path))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("a.txt"), encoding: .utf8), "one\nstaged\n")
        XCTAssertEqual(entries(snapshot.staged), ["M a.txt"], "what is staged stays")
        // One git does not track: to the Trash, where it still is.
        XCTAssertNil(GitActions.discard(["new file.txt"], in: root.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("new file.txt").path))
        XCTAssertEqual(try String(contentsOf: trash.appendingPathComponent("new file.txt"), encoding: .utf8), "mine\n")
        XCTAssertEqual(entries(snapshot.unstaged), ["M b.txt", "D gone.txt", "U made/deep/x.txt"])

        // Every change: the changed file, the deleted one, and the new folder whole.
        XCTAssertNil(GitActions.discard([], in: root.path))
        XCTAssertEqual(entries(snapshot.unstaged), [])
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("b.txt"), encoding: .utf8), "one\n")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("gone.txt"), encoding: .utf8), "kept\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("made").path), "no empty folder is left behind")
        XCTAssertEqual(try String(contentsOf: trash.appendingPathComponent("made/deep/x.txt"), encoding: .utf8), "x\n")
        XCTAssertEqual(entries(snapshot.staged), ["M a.txt"])

        // Nothing left to discard is said, not done silently.
        XCTAssertEqual(GitActions.discard([], in: root.path), "There is no change to discard.")
        XCTAssertEqual(GitActions.discard(["b.txt"], in: root.path), "There is no change to discard.")
    }

    /// GIT-20: a name that is a pattern to git is taken as the file it names.
    func testDiscardingTakesANameAsItIs() throws {
        try write("*.txt", "star\n")
        try write("a.txt", "one\n")
        git("add", ".")
        git("commit", "-q", "-m", "init")
        try write("*.txt", "star changed\n")
        try write("a.txt", "a changed\n")
        XCTAssertNil(GitActions.discard(["*.txt"], in: root.path))
        XCTAssertEqual(entries(snapshot.unstaged), ["M a.txt"], "only the file of that name")
    }

    func testStageUnstageAndCommit() throws {
        try write("a.txt", "one\n")
        try write("b.txt", "one\n")
        git("add", ".")
        git("commit", "-q", "-m", "init")
        try write("a.txt", "one\ntwo\n")
        try write("b.txt", "one\n2\n")
        try write("tên mới.txt", "mới\n")
        XCTAssertEqual(entries(snapshot.staged), [])
        XCTAssertEqual(entries(snapshot.unstaged), ["M a.txt", "M b.txt", "U tên mới.txt"])

        XCTAssertNil(GitActions.stage(["a.txt", "tên mới.txt"], in: root.path))
        XCTAssertEqual(entries(snapshot.staged), ["M a.txt", "A tên mới.txt"])
        XCTAssertEqual(entries(snapshot.unstaged), ["M b.txt"])
        XCTAssertTrue(snapshot.staged[1].patch.contains("+mới"))

        XCTAssertNil(GitActions.unstage(["tên mới.txt"], in: root.path))
        XCTAssertEqual(entries(snapshot.staged), ["M a.txt"])
        XCTAssertEqual(entries(snapshot.unstaged), ["M b.txt", "U tên mới.txt"])

        XCTAssertNil(GitActions.commit(message: "  feat: add a second line \n", in: root.path))
        XCTAssertEqual(git("log", "-1", "--format=%s"), "feat: add a second line")
        XCTAssertEqual(git("show", "--stat", "--format=", "HEAD").contains("a.txt"), true)
        XCTAssertEqual(entries(snapshot.staged), [])
        XCTAssertEqual(entries(snapshot.unstaged), ["M b.txt", "U tên mới.txt"], "what was not staged is still there")
    }

    func testAFileChangedAfterStagingShowsInBothLists() throws {
        try write("a.txt", "one\n")
        git("add", ".")
        git("commit", "-q", "-m", "init")
        try write("a.txt", "one\ntwo\n")
        XCTAssertNil(GitActions.stage(["a.txt"], in: root.path))
        try write("a.txt", "one\ntwo\nthree\n")
        let files = snapshot.files
        XCTAssertEqual(files.map(\.id), ["staged:a.txt", "a.txt"])
        XCTAssertTrue(files[0].patch.contains("+two") && !files[0].patch.contains("+three"))
        XCTAssertTrue(files[1].patch.contains("+three"))
    }

    func testStageAllIncludesNewAndDeletedFiles() throws {
        try write("keep.txt", "x\n")
        try write("gone.txt", "x\n")
        git("add", ".")
        git("commit", "-q", "-m", "init")
        try FileManager.default.removeItem(at: root.appendingPathComponent("gone.txt"))
        try write("new.txt", "x\n")
        XCTAssertEqual(entries(snapshot.unstaged), ["D gone.txt", "U new.txt"])
        XCTAssertNil(GitActions.stage([], in: root.path))
        XCTAssertEqual(entries(snapshot.staged), ["D gone.txt", "A new.txt"])
        XCTAssertEqual(entries(snapshot.unstaged), [])
        XCTAssertNil(GitActions.unstage([], in: root.path))
        XCTAssertEqual(entries(snapshot.staged), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("gone.txt").path), "unstaging leaves the working tree alone")
    }

    func testBeforeTheFirstCommit() throws {
        try write("first.txt", "x\n")
        XCTAssertEqual(entries(snapshot.unstaged), ["U first.txt"])
        XCTAssertNil(GitActions.stage(["first.txt"], in: root.path))
        XCTAssertEqual(entries(snapshot.staged), ["A first.txt"])
        XCTAssertNil(GitActions.unstage(["first.txt"], in: root.path))
        XCTAssertEqual(entries(snapshot.unstaged), ["U first.txt"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("first.txt").path))
        XCTAssertNil(GitActions.stage([], in: root.path))
        XCTAssertNil(GitActions.commit(message: "first", in: root.path))
        XCTAssertEqual(git("rev-list", "--count", "HEAD"), "1")
    }

    func testProblemsAreReportedInGitsWords() throws {
        try write("a.txt", "one\n")
        git("add", ".")
        git("commit", "-q", "-m", "init")
        XCTAssertEqual(GitActions.commit(message: "   ", in: root.path), "Write a commit message first.")
        let nothing = try XCTUnwrap(GitActions.commit(message: "empty", in: root.path))
        XCTAssertTrue(nothing.lowercased().contains("nothing"), nothing)
        let missing = try XCTUnwrap(GitActions.stage(["no-such-file.txt"], in: root.path))
        XCTAssertTrue(missing.contains("no-such-file.txt"), missing)
        XCTAssertNotNil(GitActions.stage([], in: "/nonexistent/place"))
        XCTAssertEqual(git("rev-list", "--count", "HEAD"), "1")
    }

    func testFileNamesAreNotTakenAsPatterns() throws {
        try write("a.txt", "one\n")
        try write("b.txt", "one\n")
        try write("*.txt", "one\n")
        XCTAssertNil(GitActions.stage(["*.txt"], in: root.path))
        XCTAssertEqual(entries(snapshot.staged), ["A *.txt"], "only the file with that very name")
    }

    func testAFailingHookStopsTheCommitAndSaysWhy() throws {
        try write("a.txt", "one\n")
        let hook = root.appendingPathComponent(".git/hooks/pre-commit")
        try "#!/bin/sh\necho 'lint failed: fix it first' >&2\nexit 1\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        XCTAssertNil(GitActions.stage([], in: root.path))
        let problem = try XCTUnwrap(GitActions.commit(message: "try", in: root.path))
        XCTAssertTrue(problem.contains("lint failed"), problem)
        XCTAssertEqual(entries(snapshot.staged), ["A a.txt"], "still staged")
    }

    // GIT-3c
    func testAHookIsNeverLeftWaitingForAPassword() throws {
        try write("a.txt", "one\n")
        let seen = root.appendingPathComponent("seen")
        let hook = root.appendingPathComponent(".git/hooks/pre-commit")
        let body = "#!/bin/sh\nprintf '%s|%s|%s|%s\\n' \"$GIT_TERMINAL_PROMPT\" \"${GIT_ASKPASS-unset}\" \"$SSH_ASKPASS_REQUIRE\" \"$GIT_EDITOR\" > '\(seen.path)'\n"
        try body.write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        XCTAssertNil(GitActions.stage([], in: root.path))

        XCTAssertNil(GitActions.commit(message: "feat: the message as written", in: root.path))
        // git itself gives a hook `GIT_EDITOR=:` when the message is not edited,
        // whatever editor the host sets.
        XCTAssertEqual(try String(contentsOf: seen, encoding: .utf8), "0|unset|never|:\n")
        // No editor is opened for a message that is given, so `true` as the editor changes nothing.
        XCTAssertEqual(git("log", "-1", "--format=%B"), "feat: the message as written")
    }
}
