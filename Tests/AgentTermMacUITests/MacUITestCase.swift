import AgentTermClient
import AgentTermProtocol
import Foundation
import XCTest

/// A Mac app and a host of their own, in folders of their own, for one test.
///
/// Nothing here is the user's: the host keeps its state in a scratch
/// folder, listens on a port of its own, reads history and the SSH
/// configuration from a scratch home, and finds stand-in agents, small
/// scripts, instead of the installed ones.
///
/// These tests press the app's buttons through accessibility, which macOS
/// only lets a trusted process do, so they are skipped unless asked for:
/// `scripts/test-mac.sh` sets `AGENTTERM_MAC_UI`.
class MacUITestCase: XCTestCase {
    private(set) var root: URL!
    private(set) var project: URL!
    private(set) var remote: URL!
    private(set) var home: URL!
    private(set) var state: URL!
    private(set) var port: UInt16 = 0
    private(set) var app: MacDriver!
    private var host: Process?
    private var others: [Process] = []
    private var clients: [AgentTermConnection] = []

    /// A port nothing else in a run uses.
    private static var nextPort: UInt16 = UInt16(ProcessInfo.processInfo.environment["AGENTTERM_MAC_UI_PORT"] ?? "") ?? 7840

    private static let appName = "AgentTermMacUITest"

    /// Throws away what the app under test remembered, so each test starts
    /// from the app as it is when first opened.
    private func forgetPreferences() {
        let defaults = Process()
        defaults.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        defaults.arguments = ["delete", Self.appName]
        defaults.standardOutput = FileHandle.nullDevice
        defaults.standardError = FileHandle.nullDevice
        try? defaults.run()
        defaults.waitUntilExit()
    }

    var products: URL { Bundle(for: MacUITestCase.self).bundleURL.deletingLastPathComponent() }

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["AGENTTERM_MAC_UI"] != nil, "run through scripts/test-mac.sh")
        try XCTSkipUnless(MacDriver.isAllowed, "allow this terminal under System Settings > Privacy & Security > Accessibility")
        continueAfterFailure = false
        // As the host names it: it reads history by the folder's name, and
        // would not find it under the name with its symbolic links resolved.
        root = FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-mac-ui-\(UUID().uuidString.prefix(8))").standardizedFileURL
        project = root.appendingPathComponent("project")
        remote = root.appendingPathComponent("remote.git")
        home = root.appendingPathComponent("home")
        state = root.appendingPathComponent("state")
        try makeFixtures()
        port = Self.nextPort
        Self.nextPort += 1
        host = try startHost(state: state, home: home, port: port)
        forgetPreferences()
        try beforeTheAppStarts()
        app = try launchApp()
    }

    override func tearDown() {
        let environment = ProcessInfo.processInfo.environment
        let wanted = (testRun?.failureCount ?? 0) > 0 || environment["AGENTTERM_SHOT_ALWAYS"] != nil
        if wanted, let folder = environment["AGENTTERM_SHOT_DIR"], let app {
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            app.capture(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name.filter { $0.isLetter || $0.isNumber }).png"))
        }
        clients.forEach { $0.close() }
        clients = []
        app?.quit()
        // A host the app started by itself is not a child of this test.
        stopWhateverListens(on: port)
        for process in [host].compactMap({ $0 }) + others where process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        if let root { try? FileManager.default.removeItem(at: root) }
        if app != nil { forgetPreferences() }
    }

    /// Stops the program that listens on a port: a host the app started.
    func stopWhateverListens(on port: UInt16) {
        guard port != 0 else { return }
        let find = Process()
        find.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        find.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"]
        let pipe = Pipe()
        find.standardOutput = pipe
        find.standardError = FileHandle.nullDevice
        try? find.run()
        let found = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        find.waitUntilExit()
        for pid in found.split(whereSeparator: \.isNewline).compactMap({ pid_t($0) }) where pid != ProcessInfo.processInfo.processIdentifier { kill(pid, SIGTERM) }
    }

    /// The host's program. A test of what the app makes of a host that is
    /// not its own gives another.
    var hostExecutable: URL { products.appendingPathComponent("agenttermd") }

    /// The port the app is told to connect to. A test that puts something
    /// between the app and the host gives that thing's port.
    var appPort: UInt16 { port }

    /// Called with the host running and the app not started yet.
    func beforeTheAppStarts() throws {}

    // MARK: What the host has to show

    @discardableResult
    func git(_ arguments: String..., in directory: URL) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func write(_ text: String, to path: String, in directory: URL? = nil) throws {
        let url = (directory ?? project).appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func read(_ path: String, in directory: URL? = nil) -> String {
        (try? String(contentsOf: (directory ?? project).appendingPathComponent(path), encoding: .utf8)) ?? ""
    }

    /// A project with a remote, a committed file and changes not yet
    /// committed; a home with an SSH configuration, a conversation an agent
    /// had in the project and folders to browse; and the stand-in agents.
    func makeFixtures() throws {
        let manager = FileManager.default
        for folder in [project!, home!, state!] { try manager.createDirectory(at: folder, withIntermediateDirectories: true) }
        try makeRepository(project, remote: remote)
        try write("first line\nsecond line\n", to: "notes.txt")
        try write("# Guide\n\nSome words.\n", to: "docs/guide.md")
        try write("a file that is new\n", to: "new.txt")

        try manager.createDirectory(at: home.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
        try "Host build-server\n  HostName 127.0.0.1\nHost *.internal\n".write(
            to: home.appendingPathComponent(".ssh/config"), atomically: true, encoding: .utf8)
        try manager.createDirectory(at: home.appendingPathComponent("Projects/demo"), withIntermediateDirectories: true)
        let history = home.appendingPathComponent(".claude/projects/" + project.path.map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined())
        try manager.createDirectory(at: history, withIntermediateDirectories: true)
        try #"{"type":"user","cwd":"\#(project.path)","message":{"role":"user","content":"write tests for the parser"}}"#.appending("\n").write(
            to: history.appendingPathComponent("c-1.jsonl"), atomically: true, encoding: .utf8)

        try makeAgents(root.appendingPathComponent("agents"))
        try JSONEncoder().encode([project.path]).write(to: state.appendingPathComponent("folders.json"))
    }

    func makeRepository(_ directory: URL, remote: URL?) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        git("init", "-q", "-b", "main", in: directory)
        git("config", "user.name", "Test", in: directory)
        git("config", "user.email", "test@example.com", in: directory)
        git("config", "commit.gpgsign", "false", in: directory)
        try write("first line\n", to: "notes.txt", in: directory)
        git("add", ".", in: directory)
        git("commit", "-q", "-m", "init", in: directory)
        if let remote {
            git("init", "-q", "--bare", "-b", "main", remote.path, in: directory)
            git("remote", "add", "origin", remote.path, in: directory)
            git("push", "-q", "-u", "origin", "main", in: directory)
        }
    }

    /// Small programs under the agents' names. Asked for one answer (`-p`,
    /// `exec`), they give a commit message; started in a terminal, they say
    /// so and then repeat what they are told, as `cat` does.
    func makeAgents(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in ["claude", "codex"] {
            let script = """
                #!/bin/sh
                case " $* " in
                  *" -p "*) cat > /dev/null; echo "feat: written by the stand-in \(name)"; exit 0 ;;
                esac
                echo "stand-in \(name) started: $*"
                exec cat
                """
            let file = directory.appendingPathComponent(name)
            try script.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
    }

    // MARK: The host and the app

    @discardableResult
    func startHost(state: URL, home: URL, port: UInt16, extra: [String] = []) throws -> Process {
        let process = Process()
        process.executableURL = hostExecutable
        process.arguments =
            ["--port", String(port), "--local-only", "--no-account-usage", "--home", home.path, "--agents", root.appendingPathComponent("agents").path] + extra
        var environment = ProcessInfo.processInfo.environment
        environment["AGENTTERM_STATE_DIR"] = state.path
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        if host != nil { others.append(process) }
        let token = state.appendingPathComponent("token")
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: token.path) && Date() < deadline { usleep(50_000) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: token.path), "the host did not start")
        // The token is written a moment before the port is open.
        usleep(400_000)
        return process
    }

    /// Starts the app on the test's host. Its preferences are its own too:
    /// with a home of its own it reads and writes none of the real app's.
    func launchApp() throws -> MacDriver {
        var environment = ProcessInfo.processInfo.environment
        environment["AGENTTERM_STATE_DIR"] = state.path
        environment["AGENTTERM_PORT"] = String(appPort)
        // The home the host was given: on its own Mac the app reads
        // history from the home folder itself, not through the host.
        environment["CFFIXED_USER_HOME"] = home.path
        // Under a name of its own, the app keeps its preferences apart from
        // those of an AgentTerm someone runs from this build folder: macOS
        // files the preferences of a program without a bundle under its name.
        let executable = products.appendingPathComponent(Self.appName)
        if !FileManager.default.fileExists(atPath: executable.path) {
            try FileManager.default.createSymbolicLink(at: executable, withDestinationURL: products.appendingPathComponent("AgentTermMac"))
        }
        let driver = try MacDriver(executable: executable, environment: environment)
        driver.wait(for: .id("mac-switcher"), timeout: 20)
        return driver
    }

    /// Quits the app and opens it again, on the same host.
    func relaunchApp(whileClosed: () -> Void = {}) throws {
        app.quit()
        whileClosed()
        app = try launchApp()
    }

    /// A link that pairs one device with a host, as its pairing window shows.
    func pairingLink(state: URL, port: UInt16, name: String) -> String {
        let process = Process()
        process.executableURL = products.appendingPathComponent("agenttermd")
        process.arguments = ["pairing-link", "--port", String(port), "--host", "127.0.0.1", "--name", name]
        var environment = ProcessInfo.processInfo.environment
        environment["AGENTTERM_STATE_DIR"] = state.path
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Another device on the same host, a phone say, to see what the Mac
    /// app did and to do things the Mac app has to show.
    final class Device {
        let connection: AgentTermConnection
        private(set) var messages: [ServerMessage] = []
        private(set) var output: [SessionID: Data] = [:]

        init(port: UInt16, token: String, name: String) {
            connection = AgentTermConnection(host: "127.0.0.1", port: port, token: token, clientName: name)
            connection.onMessage = { [weak self] in self?.messages.append($0) }
            connection.onOutput = { [weak self] id, data in self?.output[id, default: Data()].append(data) }
            connection.connect()
        }

        func last<Value>(_ pick: (ServerMessage) -> Value?) -> Value? { messages.compactMap(pick).last }
        var sessions: [SessionInfo] { last { if case .sessions(let list) = $0 { return list } else { return nil } } ?? [] }
        var folders: [String] { last { if case .folders(let list) = $0 { return list } else { return nil } } ?? [] }
        var tabLayout: TabLayout? { last { if case .tabLayout(let layout) = $0 { return layout } else { return nil } } }
        var keepAwake: Bool? { last { if case .keepAwake(let on) = $0 { return on } else { return nil } } }
        var display: DisplaySettings? { last { if case .displaySettings(let settings) = $0 { return settings } else { return nil } } ?? nil }
        var commitWriter: CommitWriterSettings? { last { if case .commitWriter(let settings) = $0 { return settings } else { return nil } } }
        /// The size a session has now, as told to a device that is attached to it.
        func size(of session: SessionID) -> TermSize? {
            last { if case .resized(session, let size, _) = $0 { return size } else { return nil } }
        }
        func text(_ session: SessionID) -> String { String(decoding: output[session] ?? Data(), as: UTF8.self) }
        func send(_ message: ClientMessage) { connection.send(message) }
    }

    func device(_ name: String = "iPhone", state: URL? = nil, port: UInt16? = nil) throws -> Device {
        let token = try String(contentsOf: (state ?? self.state).appendingPathComponent("token"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let device = Device(port: port ?? self.port, token: token, name: name)
        clients.append(device.connection)
        wait("the device to be welcomed") { device.messages.contains { if case .welcome = $0 { return true } else { return false } } }
        return device
    }

    /// Waits for something to hold, with the run loop turning: answers
    /// from the host arrive on it.
    func wait(_ what: String, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        XCTAssertTrue(condition(), "timed out waiting for: \(what)" + (app.map { ". On screen:\n\($0.screen())" } ?? ""), file: file, line: line)
    }
}
