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
