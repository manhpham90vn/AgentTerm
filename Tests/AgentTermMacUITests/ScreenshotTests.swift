import AgentTermClient
import AgentTermProtocol
import AppKit
import ApplicationServices
import XCTest

/// Takes the Mac app's pictures for the README and the product page, and
/// leaves the host with the sessions the iPhone's pictures show.
/// `scripts/screenshots.sh` starts the host and the app with a demo project
/// and stand-in agents, runs this, then the iPhone app's own.
final class ScreenshotTests: XCTestCase {
    private var app: MacDriver!
    private let environment = ProcessInfo.processInfo.environment
    private var client: AgentTermConnection!
    private var messages: [ServerMessage] = []

    private var folder: URL { URL(fileURLWithPath: environment["AGENTTERM_SHOTS_OUT"] ?? "") }
    private var project: String { environment["AGENTTERM_SHOTS_PROJECT"] ?? "" }
    private var website: String { environment["AGENTTERM_SHOTS_WEBSITE"] ?? "" }
    private var home: String { environment["AGENTTERM_SHOTS_HOME"] ?? "" }

    override func setUpWithError() throws {
        try XCTSkipUnless(environment["AGENTTERM_SHOTS_PORT"] != nil, "run through scripts/screenshots.sh")
        continueAfterFailure = false
    }

    override func tearDown() {
        client?.close()
    }

    private func wait(_ what: String, timeout: TimeInterval = 20, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        XCTAssertTrue(condition(), "timed out waiting for: \(what)" + (app.map { ". On screen:\n\($0.screen())" } ?? ""))
    }

    private func pause(_ seconds: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

    /// The window's picture, at the size the pages show it.
    private func capture(_ name: String) {
        // In front, so the window is drawn as the one in use.
        NSRunningApplication(processIdentifier: app.pid)?.activate(options: [.activateAllWindows])
        pause(1)
        let file = folder.appendingPathComponent(name)
        app.capture(to: file)
        let resize = Process()
        resize.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
        resize.arguments = ["-z", "1073", "1800", file.path]
        resize.standardOutput = FileHandle.nullDevice
        resize.standardError = FileHandle.nullDevice
        try? resize.run()
        resize.waitUntilExit()
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "no picture of the window: \(name)")
    }

    /// The window at the size the pictures are taken at.
    private func sizeWindow() throws {
        let window = try XCTUnwrap(app.first(.role(kAXWindowRole as String)), "the app has no window")
        var size = CGSize(width: 1400, height: 835)
        let value = try XCTUnwrap(AXValueCreate(.cgSize, &size))
        AXUIElementSetAttributeValue(window.element, kAXSizeAttribute as CFString, value)
        pause(1)
    }

    private var sessions: [SessionInfo] {
        messages.compactMap { message -> [SessionInfo]? in if case .sessions(let list) = message { return list } else { return nil } }.last ?? []
    }

    /// A device of the test's own on the same host, to start sessions and arrange them.
    private func connect() throws {
        let port = try XCTUnwrap(environment["AGENTTERM_SHOTS_PORT"].flatMap { UInt16($0) })
        let token = try String(contentsOfFile: try XCTUnwrap(environment["AGENTTERM_SHOTS_TOKEN"]), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        client = AgentTermConnection(host: "127.0.0.1", port: port, token: token, clientName: "Mac")
        client.onMessage = { [weak self] in self?.messages.append($0) }
        client.connect()
        wait("the host's sessions") { self.messages.contains { if case .sessions = $0 { return true } else { return false } } }
    }

    /// Starts a session and gives it the conversation it is named after.
    @discardableResult
    private func start(_ agent: String?, name: String, in directory: String, about title: String? = nil) throws -> SessionInfo {
        let before = Set(sessions.map(\.id))
        client.send(.create(CreateRequest(command: agent, cwd: directory, title: agent == nil ? nil : name, size: TermSize(cols: 44, rows: 33))))
        wait("the session \(name)") { self.sessions.contains { !before.contains($0.id) } }
        let session = try XCTUnwrap(sessions.first { !before.contains($0.id) })
        // Watching it is not this device's business: the phone sets its size.
        client.send(.detach(session: session.id))
        if let title { try converse(title, in: directory) }
        // Apart, so each conversation is the newest when its session looks for one.
        pause(1.5)
        return session
    }

    /// A conversation Claude Code had in a folder, as it keeps them.
    private func converse(_ title: String, in directory: String) throws {
        let history = URL(fileURLWithPath: home).appendingPathComponent(".claude/projects/" + directory.map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined())
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
        let line = ["type": "user", "cwd": directory, "message": ["role": "user", "content": title]] as [String: Any]
        let data = try JSONSerialization.data(withJSONObject: line) + Data("\n".utf8)
        try data.write(to: history.appendingPathComponent(UUID().uuidString.lowercased() + ".jsonl"))
    }

    /// With the Mac app running: its three pictures.
    func testPart1TheMacsPictures() throws {
        let pid = try XCTUnwrap(environment["AGENTTERM_SHOTS_PID"].flatMap { pid_t($0) })
        try XCTSkipUnless(MacDriver.isAllowed, "allow this terminal under System Settings > Privacy & Security > Accessibility")
        app = MacDriver(pid: pid)
        app.wait(for: .id("mac-switcher"), timeout: 20)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try sizeWindow()
        app.wait(for: .text("my-app, folder"), timeout: 20)
        app.press(.text("my-app, folder"))

        // An agent at work, the folder's changes, and what is left of the limits.
        app.press(.button("Claude Code"), timeout: 20)
        app.wait(for: .id("session-1"), timeout: 20)
        app.wait(for: .containing("Fable 5.2"), timeout: 60)
        app.wait(for: .containing("Parser.swift"), timeout: 20)
        // What the terminal draws cannot be read from here: time for the
        // agent to have drawn its screen for the window's size.
        pause(4)
        capture("mac.png")

        // A change's diff, as a tab next to the session.
        app.press(.id("staged-src/Parser.swift"), timeout: 15)
        pause(2)
        capture("mac-diff.png")

        // A Markdown file with a diagram, as it reads.
        app.press(.button("Files"))
        app.press(.button("README.md"), timeout: 15)
        // The diagram is drawn a moment after the text around it.
        let drawn = Date().addingTimeInterval(30)
        while !app.exists(.containing("Input line")) && Date() < drawn { pause(0.5) }
        XCTAssertTrue(app.exists(.containing("Input line")), "the diagram was not drawn")
        pause(2)
        capture("mac-files.png")

    }

    /// With the Mac app closed, so that no session is at its size: more
    /// sessions for the iPhone to list, in two folders, one pinned and the
    /// others in groups.
    func testPart2TheSessionsForTheiPhone() throws {
        try connect()
        // Without the Mac's part, the session it would have left.
        if environment["AGENTTERM_SHOTS_FIRST"] != nil, sessions.isEmpty { try start("claude", name: "Claude Code", in: project) }
        let first = try XCTUnwrap(sessions.first, "the Mac's part left no session")
        // It was the Mac's size: a phone's, as the others, until the phone opens it.
        let phone = TermSize(cols: 44, rows: 33)
        client.send(.attach(session: first.id, size: phone))
        client.send(.takeControl(session: first.id, size: phone))
        wait("the first session at a phone's size") {
            self.messages.contains { if case .resized(first.id, phone, _) = $0 { return true } else { return false } }
        }
        client.send(.detach(session: first.id))
        try converse("Fix the flaky parser tests", in: project)
        pause(1.5)
        let codex = try start("codex", name: "Codex", in: project)
        let upload = try start("claude", name: "Claude Code", in: project, about: "Add retry to the upload client")
        let copilot = try start("copilot", name: "Copilot CLI", in: project)
        try start("agy", name: "Antigravity", in: website)
        try start(nil, name: "zsh", in: website)

        // The host keeps the arrangement its clients give it: this one
        // lists every session, as an app does for the tabs it shows.
        var layout = messages.compactMap { message -> TabLayout? in if case .tabLayout(let layout) = message { return layout } else { return nil } }.last ?? TabLayout()
        layout.sync(with: sessions.map(\.layoutID))
        layout.setPinned(first.layoutID, true)
        let api = try XCTUnwrap(layout.newGroup(with: codex.layoutID, name: "api"))
        layout.add(upload.layoutID, toGroup: api)
        layout.setColor("blue", of: api)
        let docs = try XCTUnwrap(layout.newGroup(with: copilot.layoutID, name: "docs"))
        layout.setColor("green", of: docs)
        client.send(.setTabLayout(layout))
        // The sessions are named after their conversations a little later.
        wait("the sessions to be named", timeout: 60) {
            Set(self.sessions.compactMap(\.summary)).isSuperset(of: ["Fix the flaky parser tests", "Add retry to the upload client"])
        }
    }
}
