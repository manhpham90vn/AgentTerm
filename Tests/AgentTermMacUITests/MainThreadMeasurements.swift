import AgentTermProtocol
import ApplicationServices
import XCTest

/// PERF-10 (#21): how long the Mac app's main thread is held up while it
/// does its heaviest things, against the threshold of one frame, 16 ms.
/// Printed as `MEASURE main thread, <what>: …`; nothing fails on a figure.
/// Run by `MEASURE=1 scripts/test-mac.sh MainThreadMeasurements`, and
/// skipped otherwise.
///
/// The app notes its own stalls (`MainThreadWatch`). While a step is
/// measured the test asks the app nothing: looking at its window is
/// answered on its main thread, and would be counted.
final class MainThreadMeasurements: MacUITestCase {
    private var notes: URL { root.appendingPathComponent("main-thread.txt") }

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["AGENTTERM_MEASURE_UI"] != nil, "run with MEASURE=1 scripts/test-mac.sh")
        try super.setUpWithError()
    }

    /// The stalls the app noted since a moment: how long each was, in ms.
    private func stalls(since start: Date, until end: Date) -> [Double] {
        let text = (try? String(contentsOf: notes, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap { line -> Double? in
            let parts = line.split(separator: " ")
            guard parts.count == 2, let at = Double(parts[0]), let took = Double(parts[1]) else { return nil }
            // Noticed when it was over.
            return at >= start.timeIntervalSince1970 && at <= end.timeIntervalSince1970 + 0.05 ? took : nil
        }
    }

    /// Does a step, leaves the app alone for a while, and says how its
    /// main thread fared meanwhile.
    private func measured(_ what: String, for seconds: TimeInterval = 3, _ step: () -> Void) {
        Thread.sleep(forTimeInterval: 0.5)
        let start = Date()
        step()
        Thread.sleep(forTimeInterval: seconds)
        let found = stalls(since: start, until: Date())
        let longest = found.max() ?? 0
        print(
            String(
                format: "MEASURE main thread, %@: %@", what,
                found.isEmpty
                    ? "never held up over 16 ms"
                    : String(format: "held up %d times, the longest %.0f ms, %.0f ms in all", found.count, longest, found.reduce(0, +))))
    }

    private func size(of element: AXUIElement) -> CGSize {
        var value: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &value)
        var size = CGSize.zero
        if let value, CFGetTypeID(value) == AXValueGetTypeID() { AXValueGetValue(value as! AXValue, .cgSize, &size) }
        return size
    }

    /// The tallest scroll bar that goes up and down: the middle pane's.
    private func tallestScrollBar() -> AXUIElement? {
        app.nodes().filter { $0.role == kAXScrollBarRole as String }.map(\.element)
            .filter { size(of: $0).height > size(of: $0).width }
            .max { size(of: $0).height < size(of: $1).height }
    }

    /// Scrolls from the top to the bottom in sixty steps over a second.
    private func scroll(_ bar: AXUIElement) {
        for step in 1...60 {
            AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString, NSNumber(value: Double(step) / 60))
            usleep(16_000)
        }
    }

    func testTheMainThreadInTheHeavyCases() throws {
        // A file of 20,000 lines, every one of them changed; a text file
        // of 5 MB; and the app started again so that it notes its stalls.
        try write((1...20_000).map { "line \($0)\n" }.joined(), to: "big.txt")
        git("add", "big.txt", in: project)
        git("commit", "-q", "-m", "a big file", in: project)
        try write((1...20_000).map { "changed \($0), and longer than it was\n" }.joined(), to: "big.txt")
        try write(String(repeating: "A line of a large file, forty-nine letters long.\n", count: 5 * 1024 * 1024 / 50), to: "large.txt")
        appEnvironment["AGENTTERM_MEASURE_MAIN"] = notes.path
        try relaunchApp()
        let phone = try device()
        app.wait(for: .text("project, folder"), timeout: 20)
        Thread.sleep(forTimeInterval: 2)

        measured("at rest, the window open") {}

        // The Git tab, with the big change among the others.
        let git = try XCTUnwrap(app.first(.button("Git")))
        measured("the Git tab shown, 20,000 changed lines among the changes") { AXUIElementPerformAction(git.element, kAXPressAction as CFString) }
        let change = try XCTUnwrap(app.wait(for: .id("change-big.txt"), timeout: 20))
        measured("a diff of 20,000 changed lines opened", for: 6) { AXUIElementPerformAction(change.element, kAXPressAction as CFString) }
        if let bar = tallestScrollBar() {
            measured("that diff scrolled from top to bottom in a second") { self.scroll(bar) }
        } else {
            print("MEASURE main thread, that diff scrolled: not measured, no scroll bar was found")
        }
        if let split = app.first(.button("Show side by side")) {
            measured("the diff laid out in two panels", for: 6) { AXUIElementPerformAction(split.element, kAXPressAction as CFString) }
            if let bar = tallestScrollBar() { measured("the two panels scrolled from top to bottom in a second") { self.scroll(bar) } }
        }

        // A text file of 5 MB: opened anyway, typed into, scrolled.
        let files = try XCTUnwrap(app.first(.button("Files")))
        measured("the Files tab shown") { AXUIElementPerformAction(files.element, kAXPressAction as CFString) }
        let large = try XCTUnwrap(app.wait(for: .button("large.txt"), timeout: 20))
        measured("a text file of 5 MB picked") { AXUIElementPerformAction(large.element, kAXPressAction as CFString) }
        let anyway = try XCTUnwrap(app.wait(for: .id("open-anyway"), timeout: 20))
        measured("the 5 MB file opened in the editor", for: 10) { AXUIElementPerformAction(anyway.element, kAXPressAction as CFString) }
        if let editor = app.first(.role(kAXTextAreaRole as String)) {
            var start = CFRange(location: 0, length: 0)
            if let range = AXValueCreate(.cfRange, &start) { AXUIElementSetAttributeValue(editor.element, kAXSelectedTextRangeAttribute as CFString, range) }
            measured("twenty letters typed into it, one at a time", for: 6) {
                for _ in 0..<20 {
                    AXUIElementSetAttributeValue(editor.element, kAXSelectedTextAttribute as CFString, "x" as CFString)
                    usleep(100_000)
                }
            }
            if let bar = tallestScrollBar() { measured("the 5 MB file scrolled from top to bottom in a second") { self.scroll(bar) } }
        } else {
            print("MEASURE main thread, typing into the 5 MB file: not measured, the editor was not found")
        }

        // A session that writes 12,000 lines at once, on show.
        phone.send(.create(CreateRequest(command: "sh -c 'sleep 4; seq 1 12000; exec cat'", cwd: project.path, title: "writes fast")))
        wait("the session", timeout: 20) { phone.sessions.contains { $0.title == "writes fast" } }
        let session = try XCTUnwrap(phone.sessions.first { $0.title == "writes fast" })
        let row = try XCTUnwrap(app.wait(for: .id("session-\(session.id)"), timeout: 20))
        AXUIElementPerformAction(row.element, kAXPressAction as CFString)
        measured("a session on show writing 12,000 lines at once", for: 8) {}
    }
}
