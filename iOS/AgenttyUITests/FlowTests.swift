import XCTest

/// Walks through the app against a real host: pair, start a session, type in
/// it, go back. Run it with scripts/test-ios.sh, which starts the host and
/// passes its pairing link in.
final class FlowTests: XCTestCase {
    private let environment = ProcessInfo.processInfo.environment

    /// Saves a screenshot next to the test results when a folder was given.
    private func capture(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = environment["AGENTTY_SHOT_DIR"] {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
    }

    func testPairStartSessionAndType() throws {
        let link = try XCTUnwrap(environment["AGENTTY_PAIR_URL"], "run this test through scripts/test-ios.sh")
        let launchButton = environment["AGENTTY_LAUNCH"] ?? "Start Shell"
        let app = XCUIApplication()
        app.launch()

        // Pair by opening the link, as tapping an agentty:// link would: the
        // simulator has no camera to scan with.
        let enterLink = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Enter a pairing link'")).firstMatch
        XCTAssertTrue(enterLink.waitForExistence(timeout: 10))
        capture("1-pair")
        app.open(try XCTUnwrap(URL(string: link)))

        // Connected: the Mac's folders and launch buttons show up.
        let start = app.buttons[launchButton].firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 15), "not connected to the host")
        capture("2-sessions")
        start.tap()

        // The terminal opens with the key bar and the compose field.
        let compose = app.descendants(matching: .any)["compose"].firstMatch
        XCTAssertTrue(compose.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["key-Escape"].exists)
        XCTAssertTrue(app.buttons["key-Shift Tab"].exists)
        sleep(2)
        capture("3-terminal")

        // Text written in the compose field, Vietnamese included, is sent as typed.
        // When the Mac takes the session, the phone shows the Mac's larger
        // terminal scaled down, and can take the session back. Only checked
        // when the test is told that something will play the Mac.
        if environment["AGENTTY_EXPECT_MAC_TAKEOVER"] != nil {
            let fit = app.buttons["Fit This Screen"]
            XCTAssertTrue(fit.waitForExistence(timeout: 30), "the Mac did not take the session")
            sleep(1)
            capture("3b-mac-in-control")
            fit.tap()
            let gone = NSPredicate(format: "exists == false")
            wait(for: [expectation(for: gone, evaluatedWith: fit)], timeout: 10)
            sleep(1)
            capture("3c-taken-back")
        }

        compose.tap()
        compose.typeText("echo Xin chào tiếng Việt: ờ ữ ẩ đ")
        capture("4-composing")
        app.buttons["Send"].tap()
        sleep(1)

        compose.typeText("stty size")
        app.buttons["Send"].tap()
        sleep(2)
        print("AGENTTY keyboard visible: \(app.keyboards.firstMatch.exists)")
        capture("5-sent")

        // Keys from the key bar reach the program: Up recalls the last
        // command, and Send with nothing written is Return.
        app.buttons["key-Up"].tap()
        app.buttons["Send"].tap()
        sleep(1)
        capture("6-key-bar")

        // The whole grid is on screen, also after the text size changes: a
        // marker written on the last row has to sit right above the key
        // bar. Full screen programs keep their status line there.
        for _ in 0..<3 {
            app.buttons["session-menu"].tap()
            app.buttons["Larger Text"].tap()
        }
        sleep(1)
        // A short command, so the compose field stays one line tall and the
        // terminal keeps its height while the command runs.
        compose.tap()
        compose.typeText("clear; tput cup 99 0; printf LAST-$(tput lines)")
        app.buttons["Send"].tap()
        sleep(2)
        capture("6b-bottom-row")

        // Back in the list the session is there to return to.
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons[launchButton].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["First Mac"].waitForExistence(timeout: 5))
        let session = app.staticTexts["zsh"].firstMatch
        XCTAssertTrue(session.waitForExistence(timeout: 5))
        capture("7-session-listed")

        // The folder's git changes and its history, as in the Mac's side
        // panel. The script that runs this test sets up the project.
        if environment["AGENTTY_TEST_PROJECT"] != nil {
            app.buttons["folder-details"].firstMatch.tap()
            // The app remembers the tab last used, so pick it rather than assume it.
            XCTAssertTrue(app.buttons["Git"].waitForExistence(timeout: 10))
            app.buttons["Git"].tap()
            XCTAssertTrue(app.staticTexts["notes.txt"].waitForExistence(timeout: 10), "the changed file is not listed")
            capture("7a-changes")
            // The files can be grouped by folder, and the choice sticks.
            let group = app.buttons["Group by folder"]
            if group.exists {
                group.tap()
                XCTAssertTrue(app.buttons["Show as a flat list"].waitForExistence(timeout: 5))
                XCTAssertTrue(app.staticTexts["notes.txt"].exists)
                capture("7a2-changes-tree")
                app.buttons["Show as a flat list"].tap()
            }
            app.staticTexts["notes.txt"].tap()
            XCTAssertTrue(app.staticTexts["+second line"].waitForExistence(timeout: 10), "the diff is not shown")
            capture("7b-diff")
            app.navigationBars.buttons.firstMatch.tap()

            app.buttons["History"].tap()
            let conversation = app.staticTexts["write tests for the parser"]
            XCTAssertTrue(conversation.waitForExistence(timeout: 10), "the conversation is not listed")
            capture("7c-history")
            conversation.tap()
            XCTAssertTrue(app.buttons["Resume in Claude Code"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["Copy Resume Command"].exists)
            // The prompt the receiving agent would start with is shown.
            let prompt = app.descendants(matching: .any)["handoff-prompt"].firstMatch
            XCTAssertTrue(prompt.waitForExistence(timeout: 10), "the handoff prompt is not shown")
            XCTAssertTrue((prompt.value as? String)?.contains("You are taking over a task from Claude Code") == true, "\(String(describing: prompt.value))")
            capture("7d-conversation")
            app.buttons["Close"].tap()
            app.navigationBars.buttons.firstMatch.tap()

            // Any folder on the Mac can be picked to start in.
            app.buttons["Open Another Folder…"].tap()
            XCTAssertTrue(app.buttons["Projects"].waitForExistence(timeout: 10), "the home folder is not listed")
            capture("7e-browse-home")
            app.buttons["Projects"].tap()
            XCTAssertTrue(app.buttons["demo"].waitForExistence(timeout: 10))
            app.buttons["demo"].tap()
            let startHere = app.buttons["Start Shell here"]
            XCTAssertTrue(startHere.waitForExistence(timeout: 10))
            XCTAssertTrue(app.staticTexts["Start in demo"].waitForExistence(timeout: 5))
            capture("7f-browse-demo")
            startHere.tap()
            XCTAssertTrue(compose.waitForExistence(timeout: 10), "no terminal opened for the picked folder")
            compose.tap()
            compose.typeText("pwd")
            app.buttons["Send"].tap()
            sleep(2)
            capture("7g-started-in-picked-folder")
            app.navigationBars.buttons.firstMatch.tap()
            XCTAssertTrue(app.staticTexts["demo"].waitForExistence(timeout: 5), "the session's folder is not listed")
        }

        // A second Mac can be paired. It becomes the one on screen, with
        // nothing of the first Mac's sessions.
        guard let second = environment["AGENTTY_SECOND_PAIR_URL"] else { return }
        app.open(try XCTUnwrap(URL(string: second)))
        XCTAssertTrue(app.staticTexts["Second Mac"].waitForExistence(timeout: 15), "the second Mac did not pair")
        XCTAssertTrue(app.buttons[launchButton].firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["zsh"].exists, "the first Mac's session must not show under the second")
        capture("8-second-mac")

        // The menu lists both, and switching goes back to the first Mac and
        // its session, which kept running.
        app.buttons["mac-menu"].tap()
        XCTAssertTrue(app.buttons["Second Mac"].waitForExistence(timeout: 5))
        capture("9-mac-menu")
        app.buttons["First Mac"].tap()
        XCTAssertTrue(app.staticTexts["First Mac"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["zsh"].firstMatch.waitForExistence(timeout: 10), "the first Mac's session is back")
        capture("10-back-on-first")
    }
}
