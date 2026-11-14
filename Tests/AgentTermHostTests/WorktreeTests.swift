import AgentTermClient
import AgentTermProtocol
import XCTest

@testable import AgentTermHost

/// A git worktree of its own for each session (#23), and the worktrees of
/// the folder that is open (#33).
final class WorktreeTests: XCTestCase {
    private var root: URL!
    private var project: URL { root.appendingPathComponent("project") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-wt-\(UUID().uuidString)").standardizedFileURL
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        git("init", "-q", "-b", "main")
        git("config", "user.name", "Test")
        git("config", "user.email", "test@example.com")
        git("config", "commit.gpgsign", "false")
        try write("a.txt", "one\n")
        git("add", ".")
        git("commit", "-q", "-m", "init")
    }

    override func tearDown() {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    @discardableResult
    func git(_ arguments: String..., in directory: URL? = nil) -> String {
        let result = Subprocess.run("/usr/bin/git", ["-C", (directory ?? project).path] + arguments, timeout: 30, mergeErrors: true)
        return String(decoding: result?.output ?? Data(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func write(_ name: String, _ text: String, in directory: URL? = nil) throws {
        try text.write(to: (directory ?? project).appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    /// WT-1: a worktree on a branch of its own, cut from the current commit,
    /// inside the project, bringing nothing along, which git does not see.
    func testANewWorktreeIsACleanCheckoutOnABranchOfItsOwn() throws {
        try write("a.txt", "one\nnot committed\n")
        try write(".env", "SECRET=1\n")
        git("config", "core.excludesFile", "/dev/null")
        try "/.env\n".write(to: project.appendingPathComponent(".git/info/exclude"), atomically: true, encoding: .utf8)
        let made = try GitWorktrees.create(in: project.path, agent: "claude", branch: nil)
        XCTAssertEqual(made.branch, "agentterm/claude-1")
        XCTAssertEqual(made.directory, project.appendingPathComponent(".agentterm/worktrees/agentterm/claude-1").path)
        let worktree = URL(fileURLWithPath: made.directory)
        XCTAssertEqual(try String(contentsOf: worktree.appendingPathComponent("a.txt"), encoding: .utf8), "one\n", "uncommitted changes stay")
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree.appendingPathComponent(".env").path), "what git ignores stays")
        XCTAssertEqual(git("rev-parse", "HEAD", in: worktree), git("rev-parse", "HEAD"))
        // git does not see it as a change of the project.
        XCTAssertEqual(git("status", "--porcelain").split(separator: "\n").map(String.init), ["M a.txt"])
        // The next is numbered after it; a name already taken is refused.
        XCTAssertEqual(try GitWorktrees.create(in: project.path, agent: "claude", branch: nil).branch, "agentterm/claude-2")
        XCTAssertThrowsError(try GitWorktrees.create(in: project.path, agent: "claude", branch: "agentterm/claude-1"))
    }

    /// WT-2: two sessions change the same file without touching each other's;
    /// merging brings the changes back and removes the worktree.
    func testTwoWorktreesChangeTheSameFileApartAndMergeBack() throws {
        let first = URL(fileURLWithPath: try GitWorktrees.create(in: project.path, agent: "claude", branch: nil).directory)
        let second = URL(fileURLWithPath: try GitWorktrees.create(in: project.path, agent: "codex", branch: nil).directory)
        try write("a.txt", "one\nfirst\n", in: first)
        try write("a.txt", "one\nsecond\n", in: second)
        XCTAssertEqual(try String(contentsOf: first.appendingPathComponent("a.txt"), encoding: .utf8), "one\nfirst\n")
        XCTAssertEqual(try String(contentsOf: project.appendingPathComponent("a.txt"), encoding: .utf8), "one\n")

        // Unmerged work is listed as such, and is not merged while not committed.
        var list = GitWorktrees.list(folder: project.path)
        XCTAssertEqual(list.map(\.branch), ["main", "agentterm/claude-1", "agentterm/codex-1"])
        XCTAssertEqual(list[1].changed, 1)
        XCTAssertTrue(list[1].hasUnmergedWork && list[1].isAgentTerm && !list[1].isMain)
        XCTAssertThrowsError(try GitWorktrees.finish(folder: project.path, path: first.path, finish: .merge, deleteBranch: true))

        git("commit", "-qam", "first", in: first)
        list = GitWorktrees.list(folder: project.path)
        XCTAssertEqual(list[1].ahead, 1)
        XCTAssertEqual(list[1].changed, 0)
        _ = try GitWorktrees.finish(folder: project.path, path: first.path, finish: .merge, deleteBranch: true)
        XCTAssertEqual(try String(contentsOf: project.appendingPathComponent("a.txt"), encoding: .utf8), "one\nfirst\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path), "removed")
        XCTAssertEqual(git("branch", "--list", "agentterm/claude-1"), "", "its branch too, as asked")

        // Thrown away, with what is in it, only when asked to.
        _ = try GitWorktrees.finish(folder: project.path, path: second.path, finish: .discard, deleteBranch: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
        XCTAssertNotEqual(git("branch", "--list", "agentterm/codex-1"), "", "the branch stays when not asked")
    }

    /// WT-3 (#33): any worktree is listed, one made by hand outside the
    /// folder too, and one whose folder is gone as missing.
    func testEveryWorktreeIsListedTheMissingToo() throws {
        let outside = root.appendingPathComponent("by-hand")
        git("worktree", "add", "-q", "-b", "by-hand", outside.path)
        let gone = root.appendingPathComponent("gone")
        git("worktree", "add", "-q", "-b", "gone", gone.path)
        try FileManager.default.removeItem(at: gone)
        let list = GitWorktrees.list(folder: project.path, inUse: [outside.path + "/sub"])
        // The folder's own as it is written; the others as git gives them.
        XCTAssertEqual(list.first?.path, project.path)
        func plain(_ path: String) -> String { path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : path }
        XCTAssertEqual(list.dropFirst().map { plain($0.path) }, [outside.path, gone.path].map(plain))
        XCTAssertTrue(list[0].isMain)
        XCTAssertFalse(list[1].isAgentTerm)
        XCTAssertTrue(list[1].inUse, "a session runs in a folder inside it")
        XCTAssertTrue(list[2].missing)
        XCTAssertTrue(FileManager.default.fileExists(atPath: project.path), "nothing is removed by listing")
    }

    /// WT-9: what watches a worktree sees its branches change in the
    /// repository's own git folder, as a push or a fetch in a terminal
    /// changes them.
    func testAWorktreesWatchSeesTheRepositorysBranches() throws {
        let worktree = try GitWorktrees.create(in: project.path, agent: "claude", branch: nil).directory
        var changes = 0
        let watch = FolderWatch(paths: FolderWatch.paths(for: worktree), latency: 0.1, queue: .main) { changes += 1 }
        XCTAssertNotNil(watch)
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        changes = 0
        // What a push of its branch writes.
        git("update-ref", "refs/remotes/origin/agentterm/claude-1", "HEAD")
        let deadline = Date().addingTimeInterval(5)
        while changes == 0 && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertGreaterThan(changes, 0, "the push was not seen")
        withExtendedLifetime(watch) {}
    }

    /// WT-10: a worktree made from a folder inside one AgentTerm made goes
    /// next to it, and its session starts in the same folder inside it.
    func testAWorktreeMadeFromInsideAnotherStartsInTheSameFolder() throws {
        try FileManager.default.createDirectory(at: project.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try write("sub/b.txt", "two\n")
        git("add", ".")
        git("commit", "-q", "-m", "sub")
        let first = try GitWorktrees.create(in: project.appendingPathComponent("sub").path, agent: "claude", branch: nil)
        XCTAssertEqual(first.directory, project.appendingPathComponent(".agentterm/worktrees/agentterm/claude-1/sub").path)
        let second = try GitWorktrees.create(in: first.directory, agent: "claude", branch: nil)
        XCTAssertEqual(second.directory, project.appendingPathComponent(".agentterm/worktrees/agentterm/claude-2/sub").path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.directory + "/b.txt"))
        // From the top of one, the top of the next.
        let top = project.appendingPathComponent(".agentterm/worktrees/agentterm/claude-1").path
        XCTAssertEqual(try GitWorktrees.create(in: top, agent: "claude", branch: nil).directory, project.appendingPathComponent(".agentterm/worktrees/agentterm/claude-3").path)
    }

    func testWhereAWorktreesSessionBelongs() {
        XCTAssertEqual(WorktreePath.project(of: "/p/.agentterm/worktrees/agentterm/claude-1"), "/p")
        XCTAssertNil(WorktreePath.project(of: "/p/src"))
        XCTAssertTrue(WorktreePath.belongs("/p/.agentterm/worktrees/x/sub", to: "/p"))
        XCTAssertFalse(WorktreePath.belongs("/q/.agentterm/worktrees/x", to: "/p"))
        XCTAssertEqual(WorktreePath.branchName(agent: "codex", taken: ["agentterm/codex-1"]), "agentterm/codex-2")
    }
}

/// WT-4, WT-5: through the host, with a stand-in agent.
final class WorktreeHostTests: XCTestCase {
    private final class Client {
        let connection: AgentTermConnection
        var messages: [ServerMessage] = []

        init(port: UInt16, token: String) {
            connection = AgentTermConnection(host: "127.0.0.1", port: port, credential: .token(token), clientName: "mac")
            connection.onMessage = { [weak self] in self?.messages.append($0) }
            connection.connect()
        }

        var sessions: [SessionInfo] { messages.compactMap { if case .sessions(let list) = $0 { return list } else { return nil } }.last ?? [] }
        var worktrees: [WorktreeInfo] { messages.compactMap { if case .worktrees(_, let list, _) = $0 { return list } else { return nil } }.last ?? [] }
        var errors: [String] { messages.compactMap { if case .error(let text) = $0 { return text } else { return nil } } }
    }

    private var root: URL!
    private var server: HostServer!
    private var client: Client!
    private let token = "test-token-0123456789abcdef0123456789"
    private var project: URL { root.appendingPathComponent("project") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-wth-\(UUID().uuidString)").standardizedFileURL
        let agents = root.appendingPathComponent("agents")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        for arguments in [["init", "-q", "-b", "main"], ["config", "user.name", "T"], ["config", "user.email", "t@example.com"], ["commit", "-q", "--allow-empty", "-m", "init"]] {
            _ = Subprocess.run("/usr/bin/git", ["-C", project.path, "-c", "commit.gpgsign=false"] + arguments, timeout: 30)
        }
        try "#!/bin/sh\nexec sleep 600\n".write(to: agents.appendingPathComponent("claude"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: agents.appendingPathComponent("claude").path)
        var configuration = HostServer.Configuration(port: 0, token: token, listenOnTailscale: false, detectAgents: { AgentDetector.detect(in: agents.path) })
        configuration.agentsDirectory = agents.path
        configuration.foldersFile = root.appendingPathComponent("state/folders.json")
        server = HostServer(configuration: configuration)
        client = Client(port: try server.start(), token: token)
        waitUntil("connected") { !self.client.messages.isEmpty }
    }

    override func tearDown() {
        server?.stop()
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 15, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertTrue(condition(), "timed out waiting for: \(what)")
    }

    /// WT-4: a session started in a new worktree runs there, with its branch,
    /// after the folder's setup command ran there.
    func testASessionInANewWorktreeRunsThereWithItsBranch() throws {
        client.connection.send(.setWorktreeSetup(folder: project.path, command: "touch set-up"))
        client.connection.send(.createInWorktree(request: CreateRequest(command: "claude", cwd: project.path, title: "Claude Code"), branch: nil))
        waitUntil("the session") { self.client.sessions.count == 1 && self.client.sessions[0].branch != nil }
        let session = try XCTUnwrap(client.sessions.first)
        let path = project.appendingPathComponent(".agentterm/worktrees/agentterm/claude-1").path
        XCTAssertEqual(session.cwd, path)
        XCTAssertEqual(session.branch, "agentterm/claude-1")
        XCTAssertEqual(session.agent, "claude")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path + "/set-up"), "the setup command ran in it")
        XCTAssertTrue(WorktreePath.belongs(session.cwd, to: project.path))
        waitUntil("the worktrees") { self.client.worktrees.count == 2 }
        XCTAssertTrue(client.worktrees[1].inUse)
    }

    /// WT-11: under the tests, the login shell a worktree's setup command
    /// runs in reads none of the startup files of the person running them:
    /// it reads them where a session's shell does (TEST-1).
    func testASetupCommandUnderTheTestsReadsNoneOfTheUsersStartupFiles() throws {
        let expected = try XCTUnwrap(HostEnvironment.sessionEnvironment()["ZDOTDIR"], "a session's shell is kept off them")
        client.connection.send(.setWorktreeSetup(folder: project.path, command: "printf %s \"$ZDOTDIR\" > zdotdir"))
        client.connection.send(.createInWorktree(request: CreateRequest(command: "claude", cwd: project.path), branch: nil))
        waitUntil("the session") { self.client.sessions.count == 1 }
        let path = project.appendingPathComponent(".agentterm/worktrees/agentterm/claude-1/zdotdir").path
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), expected)
    }

    /// WT-5: a worktree a session runs in is not removed; one with unmerged
    /// work is removed only when asked to throw it away.
    func testAWorktreeInUseIsNotRemoved() throws {
        client.connection.send(.createInWorktree(request: CreateRequest(command: "claude", cwd: project.path), branch: "feature/x"))
        waitUntil("the session") { self.client.sessions.count == 1 }
        let path = try XCTUnwrap(client.sessions.first?.cwd)
        client.connection.send(.finishWorktree(folder: project.path, path: path, finish: .discard, deleteBranch: true))
        waitUntil("refused") { self.client.errors.contains { $0.contains("still runs") } }
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        // Ended, then thrown away as asked.
        client.connection.send(.kill(session: try XCTUnwrap(client.sessions.first?.id)))
        waitUntil("ended") { self.client.sessions.isEmpty }
        client.connection.send(.finishWorktree(folder: project.path, path: path, finish: .discard, deleteBranch: true))
        waitUntil("removed") { !FileManager.default.fileExists(atPath: path) }
        waitUntil("told") { self.client.messages.contains { if case .worktreeFinished = $0 { return true } else { return false } } }
    }
}
