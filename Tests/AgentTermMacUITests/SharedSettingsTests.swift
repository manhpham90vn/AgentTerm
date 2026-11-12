import AgentTermProtocol
import XCTest

/// What the Mac app and another device share through the host: the folders,
/// the sessions, and the settings that are the host's.
final class SharedSettingsTests: MacUITestCase {
    private func openSettings(_ pane: String) {
        app.menu(["AgentTermMacUITest", "Settings…"])
        app.press(.button(pane))
    }

    func testKeepAwakeIsTheSameOnBothDevices() throws {
        let phone = try device()
        openSettings("General")
        let toggle = MacDriver.Query.id("keep-awake")
        app.wait(for: toggle)
        XCTAssertEqual(phone.keepAwake, false)
        // AWAKE-2: switched on here, the phone is told.
        app.press(toggle)
        wait("the phone to hear it is on") { phone.keepAwake == true }
        // Switched off on the phone, it is off here.
        phone.send(.setKeepAwake(false))
        wait("the switch to go off here") { self.app.first(toggle)?.value == "0" }
    }

    func testTheUnitOfTheTemperatureAndTheDiffLayoutAreShared() throws {
        let phone = try device()
        openSettings("General")
        // SYS-3: Fahrenheit chosen on the phone shows in the Mac's line of figures.
        var display = phone.display ?? DisplaySettings()
        display.temperatureUnit = SystemStats.fahrenheit
        phone.send(.setDisplaySettings(display))
        wait("the Mac's temperature in Fahrenheit", timeout: 15) { self.app.first(.id("system-temperature"))?.label.contains("°F") ?? false }
        // GIT-6: two panels chosen on the phone is what Settings > Git shows here.
        display.diffLayout = "split"
        phone.send(.setDisplaySettings(display))
        app.press(.button("Git"), menus: false)
        wait("the Mac to show two panels as the choice", timeout: 15) { self.app.exists(.containing("Two panels")) }
    }

    func testCommitMessageSettingsAreShared() throws {
        let phone = try device()
        // GIT-11: what the phone sets is what Settings > Git shows.
        phone.send(.setCommitWriter(CommitWriterSettings(agent: "codex", model: "a-model", prompt: "Viết bằng tiếng Việt.")))
        openSettings("Git")
        wait("the agent the phone chose") { self.app.all(.role(kAXPopUpButtonRole as String)).contains { $0.label == "Agent" && $0.value == "Codex" } }
        wait("the model the phone named") { self.app.all(.role(kAXTextFieldRole as String)).contains { $0.label == "Model" && $0.value == "a-model" } }
        wait("the prompt the phone wrote") { self.app.all(.role(kAXTextAreaRole as String)).contains { $0.value == "Viết bằng tiếng Việt." } }
        // And the Write button names that agent.
        app.wait(for: .containing("Write the commit message with Codex"))
    }

    func testFoldersAndSessionsOfAnotherDeviceShowHere() throws {
        let phone = try device()
        // WIN-1: a folder the phone adds is in the Mac's list.
        let demo = home.appendingPathComponent("Projects/demo").path
        phone.send(.addFolder(path: demo))
        app.wait(for: .text("demo, folder"), timeout: 15)
        // SES-6, NAME-3: a session the phone starts shows here, under its folder.
        phone.send(.create(CreateRequest(command: "codex", cwd: demo, title: "Codex", size: .default)))
        app.wait(for: .containing("Codex"), timeout: 15)
        wait("the session listed") { phone.sessions.count == 1 }
        // SES-10: ended on the phone, it is gone here.
        phone.send(.kill(session: phone.sessions[0].id))
        wait("the session to end") { phone.sessions.isEmpty }
        // WIN-1: removed on the phone, the folder is gone here.
        phone.send(.removeFolder(path: demo))
        app.waitGone(.text("demo, folder"), timeout: 15)
    }
}
