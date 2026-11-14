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

    /// Searching a repository of 50,000 files (#45): its files listed and
    /// ranked for a name, and how long until the first lines that hold a
    /// word are given, and until all of them are.
    func testSearchingALargeRepository() {
        let repo = repository("search")
        writeFiles(50_000, in: repo) { "file \($0)\nsome text of file \($0)\n" + ($0 % 1000 == 0 ? "the needle is here\n" : "") }
        git("add", "-A", in: repo)
        git("commit", "-q", "-m", "init", in: repo)
        var files: [String] = []
        report("search, 50,000 files: the files listed in", ms(time { files = FileSearch.files(in: repo.path) }))
        report("search, 50,000 files: a name ranked among them in", ms(time { _ = FileSearch.rank(files, query: "f4999") }))
        var first = Double.infinity
        let all = time {
            let started = Date()
            var seen = false
            _ = FileSearch.text("needle", in: repo.path, caseSensitive: false, isCancelled: { false }) { _ in
                if !seen { first = min(first, Date().timeIntervalSince(started) * 1000) }
                seen = true
            }
        }
        report("search, 50,000 files: a word in 50 of them, the first lines given in", ms(first))
        report("search, 50,000 files: a word in 50 of them, all lines given in", ms(all))
        report(
            "search, 50,000 files: a word in every file, stopped at 2,000 lines in", ms(time { _ = FileSearch.text("some text", in: repo.path, caseSensitive: false, isCancelled: { false }) { _ in } })
        )
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

    /// PERF-7: how long another client waits for an answer while a session
    /// of 10,000 lines is attached to: the queue every session's output and
    /// every request go through is not held up by its screen being written.
    func testTheHostAnswersWhileALongScreenIsWrittenOut() throws {
        let token = "measure-token-0123456789abcdef0123"
        let server = HostServer(configuration: .init(port: 0, token: token, listenOnTailscale: false, detectAgents: { [] }))
        let port = try server.start()
        defer { server.stop() }
        var messages: [ServerMessage] = [], output = 0
        let mac = AgentTermConnection(host: "127.0.0.1", port: port, credential: .token(token), clientName: "mac")
        mac.onMessage = { messages.append($0) }
        mac.onOutput = { _, data in output += data.count }
        mac.connect()
        let size = TermSize(cols: 120, rows: 40)
        mac.send(.create(CreateRequest(command: "seq -f 'line %g of a long session, to be scrolled back through' 1 12000; exec sleep 600", cwd: NSTemporaryDirectory(), title: "long", size: size)))
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(30)
            while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
        }
        wait { output > 600_000 }
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        guard let id = messages.compactMap({ if case .attached(let info) = $0 { return info.id } else { return nil } }).first else { return XCTFail("no session") }

        var asked: [ServerMessage] = []
        let other = AgentTermConnection(host: "127.0.0.1", port: port, credential: .token(token), clientName: "other")
        other.onMessage = { asked.append($0) }
        other.connect()
        wait { asked.contains { if case .welcome = $0 { return true } else { return false } } }
        func answers() -> Int { asked.filter { if case .commitWriter = $0 { return true } else { return false } }.count }
        let before = answers()
        let phone = AgentTermConnection(host: "127.0.0.1", port: port, credential: .token(token), clientName: "phone")
        phone.connect()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        phone.send(.attach(session: id, size: size))
        let start = Date()
        // Answered on the host's queue, as soon as it gets to it.
        other.send(.setCommitWriter(CommitWriterSettings()))
        wait { answers() > before }
        report("another client answered while a session of 10,000 lines is attached to, in", ms(Date().timeIntervalSince(start) * 1000))
    }

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
        report("attaching to a session with 10,000 lines: its screen written out in", "\(ms(writing)), \(written.count / 1024) KB sent")
        // Of which only taking the rows is done on the queue the sessions use.
        mirror.feed(Data())
        var capture: ScreenMirror.Capture?
        let taking = time { capture = mirror.capture() }
        report("  of which taken on the sessions' queue", ms(taking))
        report("  and written out on a queue of its own", ms(time { _ = capture?.written() }))
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

    /// What the process holds, in KB, as vmmap says: its own dirty pages,
    /// not the libraries it shares with every other process.
    private func footprint(_ pid: Int32) -> Int {
        let map = String(decoding: Subprocess.run("/usr/bin/vmmap", ["-summary", String(pid)], timeout: 60)?.output ?? Data(), as: UTF8.self)
        guard let line = map.split(separator: "\n").first(where: { $0.hasPrefix("Physical footprint:") }) else { return 0 }
        let figure = line.split(separator: " ").last.map(String.init) ?? ""
        let number = Double(figure.dropLast()) ?? 0
        return Int(figure.hasSuffix("M") ? number * 1024 : number)
    }

    /// What the process has allocated and not freed, in bytes, as `heap`
    /// counts it: what it uses, without the free pages the allocator keeps.
    private func allocated(_ pid: Int32) -> Int {
        let heap = String(decoding: Subprocess.run("/usr/bin/heap", [String(pid)], timeout: 60)?.output ?? Data(), as: UTF8.self)
        // "All zones: 3742 nodes (479088 bytes)"
        guard let line = heap.split(separator: "\n").first(where: { $0.hasPrefix("All zones:") && $0.contains("bytes)") }),
            let open = line.lastIndex(of: "("), let number = Int(line[line.index(after: open)...].split(separator: " ").first ?? "")
        else { return 0 }
        return number
    }

    private func resident(_ pid: Int32) -> Int {
        let result = Subprocess.run("/bin/ps", ["-o", "rss=", "-p", String(pid)], timeout: 5)
        return Int(String(decoding: result?.output ?? Data(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    /// The real host, on a state folder and port of its own: its memory at
    /// rest, with sessions, and once two hundred were opened and ended. What
    /// it holds after the first twenty is the allocator keeping their pages;
    /// it must not grow with more (PERF-8).
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
        let footprintAtRest = footprint(host.processIdentifier)
        report("the host at rest, no session", "\(atRest / 1024) MB resident, \(footprintAtRest / 1024) MB its own")

        for _ in 0..<20 { client.send(.create(CreateRequest(command: "exec sleep 600", cwd: root.path))) }
        let deadline = Date().addingTimeInterval(20)
        while sessions.count < 20 && Date() < deadline { spin(0.1) }
        spin(2)
        let withSessions = resident(host.processIdentifier)
        report("the host with 20 idle sessions", "\(withSessions / 1024) MB resident, \(max(0, withSessions - atRest) / 20) KB each")

        for session in sessions { client.send(.kill(session: session.id)) }
        while !sessions.isEmpty && Date() < deadline.addingTimeInterval(20) { spin(0.1) }
        spin(3)
        // What twenty at once leave held: the allocator keeps the pages.
        let footprintAfterFirst = footprint(host.processIdentifier)
        let allocatedAfterFirst = allocated(host.processIdentifier)
        report("  once the first 20 ended", "\(allocatedAfterFirst / 1024) KB allocated, \(footprintAfterFirst / 1024) MB its own with the pages kept")
        for round in 0..<9 {
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
            "the host after 200 sessions opened and ended",
            "\(after / 1024) MB resident, \(String(format: "%+.0f", Double(after - atRest) / Double(max(atRest, 1)) * 100))% from at rest")
        let footprintAfter = footprint(host.processIdentifier)
        let allocatedAfter = allocated(host.processIdentifier)
        // PERF-8: what it uses does not grow with the sessions.
        report(
            "  allocated after all 200",
            "\(allocatedAfter / 1024) KB, \(String(format: "%+.0f", Double(allocatedAfter - allocatedAfterFirst) / Double(max(allocatedAfterFirst, 1)) * 100))% from after the first 20 (threshold +15%)"
        )
        report(
            "  its own memory after all 200, with the pages kept",
            "\(footprintAfter / 1024) MB, \(String(format: "%+.0f", Double(footprintAfter - footprintAtRest) / Double(max(footprintAtRest, 1)) * 100))% from at rest, "
                + "\(String(format: "%+.0f", Double(footprintAfter - footprintAfterFirst) / Double(max(footprintAfterFirst, 1)) * 100))% from after the first 20")
        // A leak, or pages the allocator keeps for later? `leaks` says what
        // nothing points at any more; the footprint is what the process
        // holds, kept pages included.
        let pid = String(host.processIdentifier)
        let leaks = String(decoding: Subprocess.run("/usr/bin/leaks", [pid], timeout: 60)?.output ?? Data(), as: UTF8.self)
        if let line = leaks.split(separator: "\n").first(where: { $0.contains("leaks for") }) {
            report("  leaks", line.trimmingCharacters(in: .whitespaces))
        }
        let map = String(decoding: Subprocess.run("/usr/bin/vmmap", ["-summary", pid], timeout: 60)?.output ?? Data(), as: UTF8.self)
        for line in map.split(separator: "\n")
        where line.hasPrefix("Physical footprint") || line.contains("MALLOC") || line.contains("Zone")
            || line.hasPrefix("REGION TYPE") || line.contains("TOTAL")
        {
            report("  vmmap", line.trimmingCharacters(in: .whitespaces))
        }
    }
}
