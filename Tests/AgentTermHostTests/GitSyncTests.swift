import AgentTermProtocol
import XCTest

@testable import AgentTermHost

/// Push and pull against a remote that is a bare repository on disk.
final class GitSyncTests: XCTestCase {
    private var root: URL!
    private var remote: URL { root.appendingPathComponent("remote.git") }
    private var mine: URL { root.appendingPathComponent("mine") }
    private var theirs: URL { root.appendingPathComponent("theirs") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-gitsync-\(UUID().uuidString)").standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        run("init", "-q", "--bare", "-b", "main", remote.path, in: root)
        for clone in [mine, theirs] {
            run("clone", "-q", remote.path, clone.path, in: root)
            // An identity of the test's own, and no signing, whatever the machine is set up with.
            run("config", "user.name", "Test", in: clone)
            run("config", "user.email", "test@example.com", in: clone)
            run("config", "commit.gpgsign", "false", in: clone)
            run("config", "pull.rebase", "false", in: clone)
            run("checkout", "-q", "-B", "main", in: clone)
        }
        try commit("a.txt", "one\n", "init", in: mine)
        run("push", "-q", "-u", "origin", "main", in: mine)
        run("pull", "-q", "origin", "main", in: theirs)
        run("branch", "--set-upstream-to=origin/main", in: theirs)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func run(_ arguments: String..., in directory: URL) -> String {
        let result = Subprocess.run("/usr/bin/git", ["-C", directory.path] + arguments, timeout: 30, mergeErrors: true)
        return String(decoding: result?.output ?? Data(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func commit(_ name: String, _ text: String, _ message: String, in clone: URL) throws {
        try text.write(to: clone.appendingPathComponent(name), atomically: true, encoding: .utf8)
        run("add", ".", in: clone)
        run("commit", "-q", "-m", message, in: clone)
    }

    private func snapshot(_ clone: URL) -> DiffSnapshot { GitDiff.snapshot(directory: clone.path) }

    func testTheChangesSayHowFarTheBranchIsFromItsUpstream() throws {
        XCTAssertEqual(snapshot(mine).upstream, "origin/main")
        XCTAssertEqual(snapshot(mine).ahead, 0)
        XCTAssertEqual(snapshot(mine).behind, 0)
        XCTAssertNil(snapshot(mine).pushRemote)
        XCTAssertTrue(snapshot(mine).canPush && snapshot(mine).canPull)

        try commit("a.txt", "one\ntwo\n", "second", in: mine)
        try commit("a.txt", "one\ntwo\nthree\n", "third", in: mine)
        XCTAssertEqual(snapshot(mine).ahead, 2)

        // What the remote has is only known once it was asked.
        try commit("b.txt", "theirs\n", "theirs", in: theirs)
        run("push", "-q", in: theirs)
        XCTAssertEqual(snapshot(mine).behind, 0)
        run("fetch", "-q", in: mine)
        XCTAssertEqual(snapshot(mine).ahead, 2)
        XCTAssertEqual(snapshot(mine).behind, 1)
    }

    func testPushSendsTheCommitsAndPullBringsThemIn() throws {
        try commit("a.txt", "one\ntwo\n", "second", in: mine)
        XCTAssertNil(GitActions.push(in: mine.path))
        XCTAssertEqual(snapshot(mine).ahead, 0)
        XCTAssertEqual(run("log", "-1", "--format=%s", "main", in: remote), "second")

        XCTAssertNil(GitActions.pull(in: theirs.path))
        XCTAssertEqual(run("log", "-1", "--format=%s", in: theirs), "second")
        XCTAssertEqual(snapshot(theirs).behind, 0)
    }

    func testABranchWithoutAnUpstreamIsPushedWithOneSet() throws {
        run("checkout", "-q", "-b", "feature/tên-mới", in: mine)
        try commit("c.txt", "new\n", "on a branch", in: mine)
        let before = snapshot(mine)
        XCTAssertNil(before.upstream)
        XCTAssertEqual(before.pushRemote, "origin", "the changes say where a first push would go")
        XCTAssertTrue(before.canPush)
        XCTAssertFalse(before.canPull)
        XCTAssertEqual(GitActions.pull(in: mine.path)?.contains("Push it first"), true)

        XCTAssertNil(GitActions.push(in: mine.path))
        let after = snapshot(mine)
        XCTAssertEqual(after.upstream, "origin/feature/tên-mới")
        XCTAssertNil(after.pushRemote)
        XCTAssertEqual(run("log", "-1", "--format=%s", "feature/tên-mới", in: remote), "on a branch")
    }

    func testARefusedPushSaysWhatGitSaid() throws {
        try commit("b.txt", "theirs\n", "theirs", in: theirs)
        run("push", "-q", in: theirs)
        try commit("a.txt", "one\nmine\n", "mine", in: mine)
        let problem = try XCTUnwrap(GitActions.push(in: mine.path))
        XCTAssertTrue(problem.contains("rejected") || problem.contains("fetch first"), problem)
    }

    /// GIT-30 (#37): a fetch asks the remote for what is new and changes
    /// neither the branch nor the files; a repository without a remote
    /// says so.
    func testAFetchSaysWhatTheRemoteHasWithoutChangingAnything() throws {
        try commit("b.txt", "theirs\n", "theirs", in: theirs)
        run("push", "-q", in: theirs)
        try "mine, not committed\n".write(to: mine.appendingPathComponent("c.txt"), atomically: true, encoding: .utf8)
        let head = run("rev-parse", "HEAD", in: mine)
        XCTAssertEqual(snapshot(mine).behind, 0)

        XCTAssertNil(GitActions.fetch(in: mine.path))
        XCTAssertEqual(snapshot(mine).behind, 1, "what the remote has is known")
        XCTAssertEqual(run("rev-parse", "HEAD", in: mine), head, "the branch is where it was")
        XCTAssertEqual(try String(contentsOf: mine.appendingPathComponent("c.txt"), encoding: .utf8), "mine, not committed\n")

        // A branch that is gone from the remote is forgotten here too.
        run("push", "-q", "origin", "main:spare", in: theirs)
        XCTAssertNil(GitActions.fetch(in: mine.path))
        XCTAssertTrue(GitActions.branches(in: mine.path).contains { $0.name == "origin/spare" })
        run("push", "-q", "origin", "--delete", "spare", in: theirs)
        XCTAssertNil(GitActions.fetch(in: mine.path))
        XCTAssertFalse(GitActions.branches(in: mine.path).contains { $0.name == "origin/spare" })

        let alone = root.appendingPathComponent("alone")
        run("init", "-q", "-b", "main", alone.path, in: root)
        XCTAssertEqual(GitActions.fetch(in: alone.path), "This repository has no remote to fetch from.")
    }

    /// GIT-31 (#37): a pull brings the upstream in by a merge or by a
    /// rebase when one is asked for, whatever the repository is set up to.
    func testAPullByMergeOrByRebase() throws {
        try commit("b.txt", "theirs\n", "theirs", in: theirs)
        run("push", "-q", in: theirs)
        try commit("c.txt", "mine\n", "mine", in: mine)
        // Set up to merge: asked to rebase, mine comes after theirs, with no merge.
        XCTAssertNil(GitActions.pull(in: mine.path, mode: .rebase))
        XCTAssertEqual(run("log", "--format=%s", "-3", in: mine), "mine\ntheirs\ninit")
        XCTAssertEqual(run("rev-list", "--merges", "--count", "HEAD", in: mine), "0")

        try commit("d.txt", "theirs again\n", "theirs again", in: theirs)
        run("push", "-q", "--force", in: theirs)
        try commit("e.txt", "mine again\n", "mine again", in: mine)
        run("config", "pull.rebase", "true", in: mine)
        // Set up to rebase: asked to merge, there is a merge commit.
        XCTAssertNil(GitActions.pull(in: mine.path, mode: .merge))
        XCTAssertEqual(run("rev-list", "--merges", "--count", "HEAD", in: mine), "1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: mine.appendingPathComponent("d.txt").path))
    }

    /// GIT-32 (#37): a push the remote refuses says why and what to do; a
    /// forced push is told what it would overwrite, as of now, and then
    /// overwrites it.
    func testAForcedPushSaysWhatItOverwrites() throws {
        try commit("b.txt", "theirs\n", "theirs: a line", in: theirs)
        try commit("b.txt", "theirs\nmore\n", "theirs: one more", in: theirs)
        run("push", "-q", in: theirs)
        try commit("a.txt", "one\nmine\n", "mine", in: mine)

        let refused = try XCTUnwrap(GitActions.push(in: mine.path))
        XCTAssertTrue(refused.hasPrefix("The remote has commits this branch does not have, so the push was refused. Pull first, or force the push"), refused)
        XCTAssertEqual(run("log", "-1", "--format=%s", "main", in: remote), "theirs: one more", "nothing was overwritten")

        // The remote is asked, so what is told is what is there now.
        let loses = try XCTUnwrap(GitActions.forcePushLoses(in: mine.path))
        XCTAssertEqual(loses.upstream, "origin/main")
        XCTAssertEqual(loses.commits.map { String($0.split(separator: " ", maxSplits: 1).last ?? "") }, ["theirs: one more", "theirs: a line"])

        XCTAssertNil(GitActions.push(in: mine.path, force: true))
        XCTAssertEqual(run("log", "--format=%s", "main", in: remote), "mine\ninit")
        XCTAssertEqual(GitActions.forcePushLoses(in: mine.path)?.commits, [], "nothing left to overwrite")

        // A branch that follows none has nothing to be told about.
        run("checkout", "-q", "-b", "alone", in: mine)
        XCTAssertNil(GitActions.forcePushLoses(in: mine.path))
    }

    func testAPullThatConflictsIsUndone() throws {
        try commit("a.txt", "theirs\n", "theirs", in: theirs)
        run("push", "-q", in: theirs)
        try commit("a.txt", "mine\n", "mine", in: mine)
        let head = run("rev-parse", "HEAD", in: mine)

        let problem = try XCTUnwrap(GitActions.pull(in: mine.path))
        XCTAssertTrue(problem.contains("was undone"), problem)
        XCTAssertEqual(run("rev-parse", "HEAD", in: mine), head)
        XCTAssertFalse(FileManager.default.fileExists(atPath: mine.appendingPathComponent(".git/MERGE_HEAD").path))
        XCTAssertEqual(try String(contentsOf: mine.appendingPathComponent("a.txt"), encoding: .utf8), "mine\n")
        XCTAssertEqual(snapshot(mine).files, [], "nothing is left half merged")
    }

    func testAPullThatConflictsWhileRebasingIsUndoneToo() throws {
        run("config", "pull.rebase", "true", in: mine)
        try commit("a.txt", "theirs\n", "theirs", in: theirs)
        run("push", "-q", in: theirs)
        try commit("a.txt", "mine\n", "mine", in: mine)
        let head = run("rev-parse", "HEAD", in: mine)

        let problem = try XCTUnwrap(GitActions.pull(in: mine.path))
        XCTAssertTrue(problem.contains("was undone"), problem)
        XCTAssertEqual(run("rev-parse", "HEAD", in: mine), head)
        XCTAssertEqual(run("branch", "--show-current", in: mine), "main")
    }

    func testAMergeTheUserLeftUnfinishedIsNotTouched() throws {
        run("checkout", "-q", "-b", "side", in: mine)
        try commit("a.txt", "side\n", "side", in: mine)
        run("checkout", "-q", "main", in: mine)
        try commit("a.txt", "main\n", "main", in: mine)
        run("merge", "side", in: mine)
        XCTAssertTrue(FileManager.default.fileExists(atPath: mine.appendingPathComponent(".git/MERGE_HEAD").path))

        let problem = try XCTUnwrap(GitActions.pull(in: mine.path))
        XCTAssertFalse(problem.contains("was undone"), problem)
        XCTAssertTrue(FileManager.default.fileExists(atPath: mine.appendingPathComponent(".git/MERGE_HEAD").path), "their merge is still under way")
    }

    func testARepositoryWithoutARemoteCannotBePushed() throws {
        let alone = root.appendingPathComponent("alone")
        try FileManager.default.createDirectory(at: alone, withIntermediateDirectories: true)
        run("init", "-q", "-b", "main", in: alone)
        let snapshot = snapshot(alone)
        XCTAssertNil(snapshot.pushRemote)
        XCTAssertFalse(snapshot.canPush)
        XCTAssertEqual(GitActions.push(in: alone.path), "This repository has no remote to push to.")
    }

    func testGitIsToldNeverToAskForAPassword() {
        let environment = GitActions.actionEnvironment
        XCTAssertEqual(environment["GIT_TERMINAL_PROMPT"], "0")
        XCTAssertNil(environment["GIT_ASKPASS"])
        XCTAssertNil(environment["SSH_ASKPASS"])
        XCTAssertEqual(environment["SSH_ASKPASS_REQUIRE"], "never")
    }

    func testReadingTheCountsGitGives() {
        XCTAssertEqual(GitDiff.count("ahead", in: "ahead 2, behind 13"), 2)
        XCTAssertEqual(GitDiff.count("behind", in: "ahead 2, behind 13"), 13)
        XCTAssertEqual(GitDiff.count("behind", in: "ahead 2"), 0)
        XCTAssertEqual(GitDiff.count("ahead", in: ""), 0)
    }
}
