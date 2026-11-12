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
        if let directory = environment["AGENTTERM_SHOT_DIR"] {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
    }

    func testPairStartSessionAndType() throws {
        let link = try XCTUnwrap(environment["AGENTTERM_PAIR_URL"], "run this test through scripts/test-ios.sh")
        let launchButton = environment["AGENTTERM_LAUNCH"] ?? "Start Shell"
        let app = XCUIApplication()
        app.launch()

        // Pair by opening the link, as tapping an agentterm:// link would: the
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
        if environment["AGENTTERM_EXPECT_MAC_TAKEOVER"] != nil {
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
        print("AGENTTERM keyboard visible: \(app.keyboards.firstMatch.exists)")
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
        if environment["AGENTTERM_TEST_PROJECT"] != nil {
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

            // Stage the file, take it back, stage it again and commit it.
            let commit = app.buttons["commit"]
            XCTAssertTrue(commit.waitForExistence(timeout: 5))
            XCTAssertFalse(commit.isEnabled, "nothing is staged yet")
            app.buttons["Stage notes.txt"].tap()
            XCTAssertTrue(app.buttons["Unstage notes.txt"].waitForExistence(timeout: 10), "the file was not staged")
            XCTAssertTrue(app.staticTexts["STAGED"].exists)
            capture("7b2-staged")
            app.buttons["Unstage All"].tap()
            XCTAssertTrue(app.buttons["Stage notes.txt"].waitForExistence(timeout: 10), "the file was not unstaged")
            app.buttons["Stage All"].tap()
            XCTAssertTrue(app.buttons["Unstage notes.txt"].waitForExistence(timeout: 10))
            XCTAssertFalse(commit.isEnabled, "there is no message yet")
            let message = app.textFields["commit-message"].exists ? app.textFields["commit-message"] : app.textViews["commit-message"]
            message.tap()
            message.typeText("test: add a second line")
            XCTAssertTrue(commit.isEnabled)
            capture("7b3-ready-to-commit")
            commit.tap()
            XCTAssertTrue(app.staticTexts["No uncommitted changes."].waitForExistence(timeout: 15), "the commit was not made")
            capture("7b4-committed")

            // The folder's files: open one, edit it, save it, make a new one.
            app.buttons["Files"].tap()
            XCTAssertTrue(app.staticTexts["notes.txt"].waitForExistence(timeout: 10), "the file is not listed")
            capture("7b5-files")
            app.staticTexts["notes.txt"].tap()
            let editor = app.textViews["code-editor"]
            XCTAssertTrue(editor.waitForExistence(timeout: 10), "the editor did not open")
            XCTAssertTrue((editor.value as? String)?.contains("second line") == true, "the file's text is not shown")
            editor.tap()
            editor.typeText("edited ")
            XCTAssertTrue(app.buttons["Save"].waitForExistence(timeout: 5))
            capture("7b6-editing")
            app.buttons["Save"].tap()
            let saved = NSPredicate(format: "exists == false")
            expectation(for: saved, evaluatedWith: app.buttons["Save"])
            waitForExpectations(timeout: 10)
            app.navigationBars.buttons.firstMatch.tap()

            app.buttons["New File"].tap()
            let name = app.alerts.textFields.firstMatch
            XCTAssertTrue(name.waitForExistence(timeout: 5))
            name.typeText("plan.md")
            app.alerts.buttons["Create"].tap()
            XCTAssertTrue(app.navigationBars["plan.md"].waitForExistence(timeout: 10), "the new file did not open")
            capture("7b7-new-file")
            app.navigationBars.buttons.firstMatch.tap()
            XCTAssertTrue(app.staticTexts["plan.md"].waitForExistence(timeout: 10))
            // The edit is a change git sees.
            app.buttons["Git"].tap()
            XCTAssertTrue(app.buttons["Stage notes.txt"].waitForExistence(timeout: 10), "the saved edit is not a change")

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
            // The agent can be sent on in another folder: a repository
            // inside the conversation's folder is offered, and any folder
            // on the Mac can be picked.
            app.buttons["choose-folder"].tap()
            XCTAssertTrue(app.buttons["web"].waitForExistence(timeout: 10), "the folder picker does not open at the conversation's folder")
            capture("7d2-choose-folder")
            app.buttons["web"].tap()
            let pick = app.buttons["pick-folder"]
            XCTAssertTrue(pick.waitForExistence(timeout: 10))
            XCTAssertEqual(pick.label, "Continue in web")
            pick.tap()
            XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'project/web'")).firstMatch.waitForExistence(timeout: 5), "the picked folder is not the one chosen")
            capture("7d3-folder-chosen")
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

        // Something that needs the user's attention shows up over whatever
        // screen is in front. Handing off a session that has no saved
        // conversation yet says so, right there in the terminal, not only
        // after going back. Needs an agent, so it runs where one is installed.
        let startAgent = app.buttons["Start Claude Code"].firstMatch
        if startAgent.exists {
            startAgent.tap()
            XCTAssertTrue(compose.waitForExistence(timeout: 15), "no terminal opened for the agent")
            app.buttons["session-menu"].tap()
            let handOff = app.buttons["Hand Off…"]
            XCTAssertTrue(handOff.waitForExistence(timeout: 5), "an agent's session offers no handoff")
            handOff.tap()
            let alert = app.alerts.firstMatch
            XCTAssertTrue(alert.waitForExistence(timeout: 10), "nothing happened after choosing Hand Off")
            XCTAssertTrue(alert.staticTexts.containing(NSPredicate(format: "label CONTAINS 'no conversation to hand off'")).firstMatch.exists)
            capture("7h-handoff-nothing-yet")
            alert.buttons["OK"].tap()
            app.buttons["session-menu"].tap()
            app.buttons["End Session"].tap()
            app.buttons["End Session"].firstMatch.tap()
            XCTAssertTrue(app.buttons[launchButton].firstMatch.waitForExistence(timeout: 10), "ending the session did not return to the list")
        }

        // A second Mac can be paired. It becomes the one on screen, with
        // nothing of the first Mac's sessions.
        guard let second = environment["AGENTTERM_SECOND_PAIR_URL"] else { return }
        app.open(try XCTUnwrap(URL(string: second)))
        XCTAssertTrue(app.staticTexts["Second Mac"].waitForExistence(timeout: 15), "the second Mac did not pair")
        XCTAssertTrue(app.buttons[launchButton].firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["zsh"].exists, "the first Mac's session must not show under the second")
        // The second Mac's host says it is of an older release: the phone says so.
        let versionCard = app.descendants(matching: .any)["version-card"].firstMatch
        XCTAssertTrue(versionCard.waitForExistence(timeout: 5), "a Mac of another version is not pointed out")
        XCTAssertTrue(versionCard.label.contains("Second Mac is an older version"), versionCard.label)
        capture("8-second-mac")

        // The menu lists both, and switching goes back to the first Mac and
        // its session, which kept running.
        app.buttons["mac-menu"].tap()
        XCTAssertTrue(app.buttons["Second Mac"].waitForExistence(timeout: 5))
        capture("9-mac-menu")
        app.buttons["First Mac"].tap()
        XCTAssertTrue(app.staticTexts["First Mac"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["zsh"].firstMatch.waitForExistence(timeout: 10), "the first Mac's session is back")
        XCTAssertFalse(versionCard.exists, "the warning about the second Mac's version is still shown on the first")
        capture("10-back-on-first")

        // Sessions can be arranged: grouped, pinned, dragged. Three in the
        // project now, under one more in another folder.
        guard environment["AGENTTERM_TEST_PROJECT"] != nil else { return }
        for _ in 0..<2 {
            app.buttons[launchButton].firstMatch.tap()
            XCTAssertTrue(compose.waitForExistence(timeout: 10))
            app.navigationBars.buttons.firstMatch.tap()
            XCTAssertTrue(app.buttons[launchButton].firstMatch.waitForExistence(timeout: 10))
        }
        let rows = app.staticTexts.matching(identifier: "zsh")
        XCTAssertEqual(rows.count, 4)
        let group = app.buttons["session-group"].firstMatch
        func groupSays(_ text: String) -> Bool {
            let wanted = NSPredicate(format: "label CONTAINS %@", text)
            return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: wanted, object: group)], timeout: 6) == .completed
        }
        rows.element(boundBy: 0).press(forDuration: 1.2)
        app.buttons["Add to New Group"].tap()
        XCTAssertTrue(group.waitForExistence(timeout: 5), "no group was made")
        XCTAssertTrue(groupSays("1 sessions"), group.label)
        // Dropped on the group's label, a session joins it. Dropped on a
        // session of the group, it joins too.
        rows.element(boundBy: 2).press(forDuration: 0.7, thenDragTo: group, withVelocity: .slow, thenHoldForDuration: 0.6)
        XCTAssertTrue(groupSays("2 sessions"), "dropping on the label did not add the session: \(group.label)")
        rows.element(boundBy: 2).press(forDuration: 0.7, thenDragTo: rows.element(boundBy: 0), withVelocity: .slow, thenHoldForDuration: 0.6)
        XCTAssertTrue(groupSays("3 sessions"), "dropping on a grouped session did not add the session: \(group.label)")
        capture("11-grouped")
        // A pinned session leaves its group and goes first.
        rows.element(boundBy: 1).press(forDuration: 1.2)
        app.buttons["Pin"].tap()
        XCTAssertTrue(groupSays("2 sessions"), "pinning did not take the session out of the group: \(group.label)")
        // The group is renamed, recolored and folded away.
        group.press(forDuration: 1.2)
        app.buttons["Rename Group…"].tap()
        let name = app.alerts.textFields.firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.typeText(" api")
        app.alerts.buttons["Rename"].tap()
        XCTAssertTrue(groupSays("Group 1 api"), group.label)
        group.press(forDuration: 1.2)
        app.buttons["Color"].tap()
        XCTAssertTrue(app.buttons["Orange"].waitForExistence(timeout: 5), "the colors are not offered")
        capture("12-colors")
        app.buttons["Orange"].tap()
        capture("13-arranged")
        group.tap()
        XCTAssertTrue(groupSays("collapsed"), group.label)
        XCTAssertEqual(rows.count, 2, "a collapsed group still shows its sessions")
        capture("14-collapsed")

        // The Mac keeps the arrangement: it is there again after looking at
        // another Mac, which has none of it.
        app.buttons["mac-menu"].tap()
        app.buttons["Second Mac"].tap()
        XCTAssertTrue(app.staticTexts["Second Mac"].waitForExistence(timeout: 10))
        XCTAssertFalse(group.exists, "the first Mac's group must not show under the second")
        app.buttons["mac-menu"].tap()
        app.buttons["First Mac"].tap()
        XCTAssertTrue(group.waitForExistence(timeout: 10), "the arrangement did not come back from the Mac")
        XCTAssertTrue(groupSays("Group 1 api, 2 sessions, collapsed"), group.label)

        // Listed folders can be put in another order, from the menu of a
        // folder's name and by dragging one onto another. A second folder
        // is listed first.
        app.buttons["Open Another Folder…"].tap()
        let add = app.buttons["Add to Folders"]
        XCTAssertTrue(add.waitForExistence(timeout: 10), "the folder being looked at cannot be added to the list")
        add.tap()
        app.buttons["Cancel"].tap()
        let names = app.staticTexts.matching(identifier: "folder-name")
        func order() -> [String] { (0..<names.count).map { names.element(boundBy: $0).label } }
        func orderBecomes(_ wanted: [String]) -> Bool {
            let deadline = Date().addingTimeInterval(8)
            while Date() < deadline { if order() == wanted { return true }; usleep(300_000) }
            return false
        }
        // The project, the folder just added, then the unlisted one a session runs in.
        XCTAssertTrue(orderBecomes(["project", "home", "demo"]), "\(order())")
        names.element(boundBy: 0).press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["Move Down"].waitForExistence(timeout: 5), "a folder's name has no menu")
        capture("15-folder-menu")
        app.buttons["Move Down"].tap()
        XCTAssertTrue(orderBecomes(["home", "project", "demo"]), "Move Down did not move the folder: \(order())")
        names.element(boundBy: 1).press(forDuration: 0.7, thenDragTo: names.element(boundBy: 0), withVelocity: .slow, thenHoldForDuration: 0.6)
        XCTAssertTrue(orderBecomes(["project", "home", "demo"]), "dragging a folder onto another did not move it: \(order())")
        capture("16-folders-reordered")
    }
}
