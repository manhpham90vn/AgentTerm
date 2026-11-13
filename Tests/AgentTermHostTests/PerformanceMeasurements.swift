import AgentTermClient
import AgentTermProtocol
import XCTest

@testable import AgentTermHost

/// The figures of `docs/PERFORMANCE.md` (#21): heavy cases made in a folder
/// of the test's own, each timed or weighed, and printed as
/// `MEASURE <case>: <figure>`. Not a check: nothing here fails on a figure.
/// Run by `scripts/measure.sh`; skipped otherwise, being slow.
final class PerformanceMeasurements: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["AGENTTERM_MEASURE"] != nil, "run by scripts/measure.sh")
        root = FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-measure-\(UUID().uuidString)").standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func report(_ name: String, _ figure: String) {
        print("MEASURE \(name): \(figure)")
    }

    /// The shortest of `tries` runs, in milliseconds: a busy moment makes a
    /// run longer, never shorter.
    private func time(_ tries: Int = 3, _ work: () -> Void) -> Double {
        var best = Double.infinity
        for _ in 0..<tries {
            let started = Date()
            work()
            best = min(best, Date().timeIntervalSince(started) * 1000)
        }
        return best
    }

    private func ms(_ value: Double) -> String { String(format: "%.0f ms", value) }

    @discardableResult
    private func git(_ arguments: String..., in directory: URL) -> String {
        let result = Subprocess.run("/usr/bin/git", ["-C", directory.path, "-c", "commit.gpgsign=false"] + arguments, timeout: 600, mergeErrors: true)
        return String(decoding: result?.output ?? Data(), as: UTF8.self)
    }

    private func repository(_ name: String) -> URL {
        let directory = root.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        git("init", "-q", "-b", "main", in: directory)
        git("config", "user.name", "M", in: directory)
        git("config", "user.email", "m@example.com", in: directory)
        return directory
    }

    private func writeFiles(_ count: Int, in directory: URL, perFolder: Int = 500, text: (Int) -> String) {
        for index in 0..<count {
            let folder = directory.appendingPathComponent("d\(index / perFolder)")
            if index % perFolder == 0 { try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
            FileManager.default.createFile(atPath: folder.appendingPathComponent("f\(index).txt").path, contents: Data(text(index).utf8))
        }
    }

    // MARK: Git

    /// A repository of 50,000 files: the changes listed with none changed,
    /// and with ten; what a refresh of the side panel costs every 3 seconds.
    func testALargeRepository() {
        let repo = repository("large")
        writeFiles(50_000, in: repo) { "file \($0)\n" }
        git("add", "-A", in: repo)
        git("commit", "-q", "-m", "init", in: repo)
        report("large repository, 50,000 files, nothing changed: changes listed in", ms(time { _ = GitDiff.snapshot(directory: repo.path) }))
        for index in 0..<10 { try? "changed\n".write(to: repo.appendingPathComponent("d\(index)/f\(index * 500).txt"), atomically: true, encoding: .utf8) }
        report("large repository, 10 files changed: changes listed in", ms(time { _ = GitDiff.snapshot(directory: repo.path) }))
        let cpuBefore = clock()
        let wall = time(1) { for _ in 0..<5 { _ = GitDiff.snapshot(directory: repo.path) } }
        report(
            "large repository, side panel open: one refresh every 3 s costs",
            String(
                format: "%.0f ms each, %.1f%% of a core at that rate (this process only: git's own work is not counted)", wall / 5,
                Double(clock() - cpuBefore) / Double(CLOCKS_PER_SEC) * 1000 / 5 / 3000 * 100))
    }

    /// Thousands of changed or untracked files.
    func testManyChanges() {
        let repo = repository("many")
        try? "x\n".write(to: repo.appendingPathComponent("seed.txt"), atomically: true, encoding: .utf8)
        git("add", "-A", in: repo)
        git("commit", "-q", "-m", "init", in: repo)
        writeFiles(5_000, in: repo) { "new \($0)\n" }
        var snapshot: DiffSnapshot?
        let listed = time { snapshot = GitDiff.snapshot(directory: repo.path) }
        let bytes = snapshot.map { MessageCoding.encode($0).count } ?? 0
        report("many changes, 5,000 untracked files: listed in", "\(ms(listed)), \(snapshot?.unstaged.count ?? 0) files, \(bytes / 1024) KB as sent with every diff")
    }

    /// One file with 20,000 changed lines; a minified file with one line of
    /// a megabyte; a binary file.
    func testLargeDiffs() {
        let repo = repository("diffs")
        let lines = (0..<20_000).map { "line \($0) of the original text\n" }.joined()
        try? lines.write(to: repo.appendingPathComponent("big.txt"), atomically: true, encoding: .utf8)
        try? String(repeating: "a", count: 1_000_000).write(to: repo.appendingPathComponent("min.js"), atomically: true, encoding: .utf8)
        FileManager.default.createFile(atPath: repo.appendingPathComponent("blob.bin").path, contents: Data((0..<2_000_000).map { UInt8($0 % 251) }))
        git("add", "-A", in: repo)
        git("commit", "-q", "-m", "init", in: repo)
        try? lines.replacingOccurrences(of: "original", with: "changed").write(to: repo.appendingPathComponent("big.txt"), atomically: true, encoding: .utf8)
        try? String(repeating: "b", count: 1_000_000).write(to: repo.appendingPathComponent("min.js"), atomically: true, encoding: .utf8)
        FileManager.default.createFile(atPath: repo.appendingPathComponent("blob.bin").path, contents: Data((0..<2_000_000).map { UInt8($0 % 241) }))
        var snapshot: DiffSnapshot?
        let listed = time { snapshot = GitDiff.snapshot(directory: repo.path) }
        let files = snapshot?.unstaged ?? []
        let patch = files.map(\.patch.count).reduce(0, +)
        report("large diffs, 20,000 changed lines + a 1 MB line + a binary: worked out in", "\(ms(listed)), \(patch / 1024) KB of patch text")
        let split = time { for file in files { _ = SplitDiff.rows(for: file.patch) } }
        report("large diffs: laid out in two panels in", ms(split))
    }

    // MARK: Files

    func testALargeFileAndALargeFolder() {
        let file = root.appendingPathComponent("big.log")
        try? String(repeating: "a line of a log of five megabytes\n", count: 150_000).write(to: file, atomically: true, encoding: .utf8)
        report("a text file of 5 MB: read in", ms(time { _ = FileBrowser.read(file.path) }))
        let folder = root.appendingPathComponent("wide")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for index in 0..<20_000 { FileManager.default.createFile(atPath: folder.appendingPathComponent("entry-\(index)").path, contents: nil) }
        var entries: [FileEntry] = []
        let listed = time { entries = FileBrowser.list(folder.path) }
        report("a folder of 20,000 entries: listed in", "\(ms(listed)), \(MessageCoding.encode(entries).count / 1024) KB as sent")
    }

    // MARK: Sessions

    func testALongSession() {
        let mirror = ScreenMirror(size: TermSize(cols: 120, rows: 40), scrollback: 10_000)
        var piece = ""
        for number in 1...200 { piece += "\u{1b}[3\(number % 8)m\(number)\u{1b}[0m " + String(repeating: "word ", count: 18) + "\r\n" }
        let data = Data(piece.utf8)
        let fed = time(1) { for _ in 0..<60 { mirror.feed(data) } }
        report("a session writing fast: 12,000 lines (1.2 MB) fed to the host's screen in", ms(fed))
        var written = Data()
        let writing = time {
            mirror.feed(Data())
            written = mirror.snapshot()
        }
        report("attaching to a session with 10,000 lines: its screen written out in", "\(ms(writing)), \(written.count / 1024) KB sent, on the queue all the host's work goes through")
    }

    // MARK: History

    func testALongHistory() throws {
        let home = root.appendingPathComponent("home")
        let project = root.appendingPathComponent("project")
        let folder = home.appendingPathComponent(".claude/projects/" + AgentHistory.claudeProjectName(for: project.path))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for index in 0..<400 {
            var lines: [String] = []
            for turn in 0..<40 {
                lines.append(#"{"type":"user","cwd":"\#(project.path)","message":{"role":"user","content":"Question \#(turn) of conversation \#(index)"}}"#)
                lines.append(#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"\#(String(repeating: "answer ", count: 60))"}]}}"#)
            }
            try lines.joined(separator: "\n").write(to: folder.appendingPathComponent("\(UUID().uuidString).jsonl"), atomically: true, encoding: .utf8)
        }
        var found: [Conversation] = []
        let listed = time { found = AgentHistory.conversations(in: project.path, home: home.path) }
        report("a long history, 400 conversations of 80 lines: listed in", "\(ms(listed)), \(found.count) listed")
    }

    // MARK: Memory

    private func resident(_ pid: Int32) -> Int {
        let result = Subprocess.run("/bin/ps", ["-o", "rss=", "-p", String(pid)], timeout: 5)
        return Int(String(decoding: result?.output ?? Data(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    /// The real host, on a state folder and port of its own: its memory at
    /// rest, with sessions, and once a hundred were opened and ended.
    func testTheHostsMemory() throws {
        let tool = Bundle(for: PerformanceMeasurements.self).bundleURL.deletingLastPathComponent().appendingPathComponent("agenttermd")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: tool.path))
        let state = root.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        let token = "measure-token-0123456789abcdef0123456789"
        try token.write(to: state.appendingPathComponent("token"), atomically: true, encoding: .utf8)
        let port = UInt16.random(in: 47_000..<48_000)
        let host = Process()
        host.executableURL = tool
        host.arguments = ["--port", String(port), "--local-only", "--no-account-usage", "--home", root.path, "--agents", root.path]
        var environment = ProcessInfo.processInfo.environment
        environment["AGENTTERM_STATE_DIR"] = state.path
        environment["HOME"] = root.path
        environment["ZDOTDIR"] = root.path
        environment["CFFIXED_USER_HOME"] = root.path
        host.environment = environment
        host.standardOutput = FileHandle.nullDevice
        host.standardError = FileHandle.nullDevice
        try host.run()
        defer { host.terminate() }
        Thread.sleep(forTimeInterval: 2)
        let client = AgentTermConnection(host: "127.0.0.1", port: port, credential: .token(token), clientName: "measure")
        var sessions: [SessionInfo] = []
        client.onMessage = { if case .sessions(let list) = $0 { sessions = list } }
        client.connect()
        func spin(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
        spin(1)
        let atRest = resident(host.processIdentifier)
        report("the host at rest, no session", "\(atRest / 1024) MB resident")

        for _ in 0..<20 { client.send(.create(CreateRequest(command: "exec sleep 600", cwd: root.path))) }
        let deadline = Date().addingTimeInterval(20)
        while sessions.count < 20 && Date() < deadline { spin(0.1) }
        spin(2)
        let withSessions = resident(host.processIdentifier)
        report("the host with 20 idle sessions", "\(withSessions / 1024) MB resident, \(max(0, withSessions - atRest) / 20) KB each")

        for session in sessions { client.send(.kill(session: session.id)) }
        while !sessions.isEmpty && Date() < deadline.addingTimeInterval(20) { spin(0.1) }
        for round in 0..<4 {
            for _ in 0..<20 { client.send(.create(CreateRequest(command: "exec sleep 600", cwd: root.path))) }
            let started = Date()
            while sessions.count < 20 && Date().timeIntervalSince(started) < 20 { spin(0.1) }
            for session in sessions { client.send(.kill(session: session.id)) }
            while !sessions.isEmpty && Date().timeIntervalSince(started) < 40 { spin(0.1) }
            _ = round
        }
        spin(3)
        let after = resident(host.processIdentifier)
        report(
            "the host after 100 sessions opened and ended",
            "\(after / 1024) MB resident, \(String(format: "%+.0f", Double(after - atRest) / Double(max(atRest, 1)) * 100))% from at rest")
    }
}
