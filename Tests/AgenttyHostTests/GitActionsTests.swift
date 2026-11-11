@testable import AgenttyHost
import AgenttyProtocol
import XCTest

final class GitActionsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("agentty-gitactions-\(UUID().uuidString)").standardizedFileURL
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
}
