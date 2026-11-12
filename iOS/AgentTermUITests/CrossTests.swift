import XCTest

/// The iPhone app's half of the test that runs it together with the Mac
/// app on one host. `scripts/test-both.sh` starts the host and both apps:
/// the Mac app has already done its part when this runs, and looks at what
/// this did afterwards.
final class CrossTests: XCTestCase {
    private let environment = ProcessInfo.processInfo.environment

    private func capture(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = environment["AGENTTERM_SHOT_DIR"] {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: directory).appendingPathComponent("phone-\(name).png"))
        }
    }

    func testWithTheMacApp() throws {
        // Only with the Mac app running beside it: on its own, as part of
        // the iPhone app's test, there is nothing of the Mac's to find.
        try XCTSkipUnless(environment["AGENTTERM_WITH_MAC"] != nil, "run this test through scripts/test-both.sh")
        let link = try XCTUnwrap(environment["AGENTTERM_PAIR_URL"])
        let app = XCUIApplication()
        app.launch()
        let enterLink = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Enter a pairing link'")).firstMatch
        XCTAssertTrue(enterLink.waitForExistence(timeout: 10))
        app.open(try XCTUnwrap(URL(string: link)))

        // SES-6, NAME-3: the session the Mac app started is listed, under the same name.
        let macSession = app.staticTexts["zsh"].firstMatch
        XCTAssertTrue(macSession.waitForExistence(timeout: 20), "the session started on the Mac is not listed")
        _ = app.descendants(matching: .any)["system-cpu"].firstMatch.waitForExistence(timeout: 10)
        capture("1-sessions")

        // AWAKE-2: switched on on the Mac, it is on here; an option switched on here is for the Mac to show.
        app.tabBars.buttons["Settings"].tap()
        let keepAwake = app.switches["keep-awake"]
        XCTAssertTrue(keepAwake.waitForExistence(timeout: 10))
        XCTAssertEqual(keepAwake.value as? String, "1", "Keep Mac Awake was switched on on the Mac and is off here")
        let display = app.switches["Keep the display on too"]
        XCTAssertTrue(display.waitForExistence(timeout: 5))
        display.switches.firstMatch.exists ? display.switches.firstMatch.tap() : display.tap()
        capture("2-settings")
        app.tabBars.buttons["Sessions"].tap()

        // GIT-6: the Mac grouped the changes by folder, so they are grouped here.
        app.buttons["folder-details"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Git"].waitForExistence(timeout: 10))
        app.buttons["Git"].tap()
        XCTAssertTrue(app.buttons["Show as a flat list"].waitForExistence(timeout: 10), "the Mac's choice of a tree did not reach the phone")
        capture("3-changes")
        // Back to a flat list, for the Mac to follow.
        app.buttons["Show as a flat list"].tap()
        XCTAssertTrue(app.buttons["Group by folder"].waitForExistence(timeout: 5))

        // GIT-12: everything staged and committed here, for the Mac's list to lose.
        app.buttons["Stage All"].tap()
        XCTAssertTrue(app.buttons["Unstage notes.txt"].waitForExistence(timeout: 10))
        let message = app.textFields["commit-message"].exists ? app.textFields["commit-message"] : app.textViews["commit-message"]
        message.tap()
        message.typeText("test: from the phone")
        app.buttons["commit"].tap()
        XCTAssertTrue(app.staticTexts["No uncommitted changes."].waitForExistence(timeout: 15), "the commit was not made")
        capture("4-committed")
        app.navigationBars.buttons.firstMatch.tap()

        // A session of the phone's own, for the Mac to list.
        let start = app.buttons[environment["AGENTTERM_LAUNCH"] ?? "Start Shell"].firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()
        let compose = app.descendants(matching: .any)["compose"].firstMatch
        XCTAssertTrue(compose.waitForExistence(timeout: 15))
        app.navigationBars.buttons.firstMatch.tap()

        // SES-6: the Mac's session opens here and takes what is typed.
        XCTAssertTrue(macSession.waitForExistence(timeout: 10))
        macSession.tap()
        XCTAssertTrue(compose.waitForExistence(timeout: 15))
        compose.tap()
        compose.typeText("echo typed-on-the-phone")
        app.buttons["Send"].tap()
        sleep(2)
        capture("5-in-the-macs-session")
    }
}
