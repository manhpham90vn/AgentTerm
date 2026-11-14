import AgentTermProtocol
import XCTest

/// What the Mac app and another device share through the host: the folders,
/// the sessions, and the settings that are the host's.
final class SharedSettingsTests: MacUITestCase {
    private func openSettings(_ pane: String) {
        app.menu(["AgentTermMacUITest", "Settings…"])
        app.press(.id("settings-\(pane.lowercased())"))
    }

    /// SCHED-13: a schedule being made is dropped when Schedules is left,
    /// and not shown again when it is opened.
    func testASchedulesBeingMadeIsNotShownAgainAfterSchedulesIsLeft() throws {
        app.press(.id("place-schedules"))
        app.press(.id("new-schedule"))
        // The editor's Save, as the + is named "New Schedule" too.
        app.wait(for: .button("Save"))
        app.press(.id("place-sessions"))
        app.waitGone(.button("Save"))
        app.press(.id("place-schedules"))
        app.wait(for: .text("Choose a schedule"))
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertFalse(app.exists(.button("Save")), "the editor came back")
    }

    /// TEL-3 (#48): at its first launch a build that reports shows what it
    /// may send, a switch for each kind, both on; answered with one turned
    /// off, Settings says the same, and the screen does not come again.
    func testTheFirstLaunchScreenAsksOnceWithBothSwitchesOn() throws {
        // As a build with a reporting service starts, with nothing behind
        // it, and its answer kept in preferences of this test's own.
        appEnvironment["AGENTTERM_REPORTING_PREVIEW"] = "agentterm-ui-test-\(UUID().uuidString)"
        try relaunchApp()
        app.wait(for: .id("reporting-choices"), timeout: 15)
        app.wait(for: .text("What AgentTerm May Send to Its Developer"))
        wait("both switches on") { self.app.first(.id("reporting-crash"))?.value == "1" && self.app.first(.id("reporting-usage"))?.value == "1" }
        shot("tel-3-screen")
        app.press(.id("reporting-usage"))
        wait("usage statistics off") { self.app.first(.id("reporting-usage"))?.value == "0" }
        app.press(.id("reporting-continue"))
        app.waitGone(.id("reporting-choices"))

        openSettings("Privacy")
        app.wait(for: .id("privacy-crash"))
        XCTAssertEqual(app.first(.id("privacy-crash"))?.value, "1")
        XCTAssertEqual(app.first(.id("privacy-usage"))?.value, "0")

        // Answered: not asked again.
        try relaunchApp()
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        XCTAssertFalse(app.exists(.id("reporting-choices")))
    }

    /// SET-1: Settings opens on General each time, not on the pane it was left on.
    func testSettingsOpensOnGeneral() throws {
        openSettings("Privacy")
        app.wait(for: .containing("Send crash reports"))
        app.press(.id("place-sessions"))
        app.waitGone(.containing("Send crash reports"))
        app.menu(["AgentTermMacUITest", "Settings…"])
        app.wait(for: .id("menu-bar"))
        XCTAssertFalse(app.exists(.containing("Send crash reports")))
    }

    /// SCHED-14: Schedules lists a run going on, which opens its session; the
    /// schedules, by when they run next; and the runs that are over.
    func testSchedulesShowsWhatRunsWhatIsScheduledAndWhatRan() throws {
        let phone = try device()
        let later = Schedule(
            id: "later", name: "Every morning", agent: "claude", folder: project.path, prompt: "review", when: .daily(hour: 9, minute: 0),
            warningAccepted: true)
        let soon = Schedule(
            id: "soon", name: "Soon", agent: "claude", folder: project.path, prompt: "check the build", when: .once(Date().addingTimeInterval(2)),
            warningAccepted: true)
        phone.send(.saveSchedule(later))
        phone.send(.saveSchedule(soon))
        app.press(.id("place-schedules"))
        app.wait(for: .id("schedule-later"))
        app.wait(for: .id("schedule-soon"))
        app.wait(for: .text("No run is going on."))

        // Its time comes, at the host's next look: its run is going on.
        wait("the run's session", timeout: 45) { phone.sessions.contains { $0.schedule == "Soon" } }
        app.wait(for: .containing("· running"), timeout: 10)
        shot("sched-14-running")
        app.press(.containing("· running"))
        app.wait(for: .text("project, folder"))
        let run = try XCTUnwrap(phone.sessions.first { $0.schedule == "Soon" })
        XCTAssertTrue(app.exists(.id("session-\(run.id)")))

        // Over, it is among the past runs; a schedule picked is shown to change.
        phone.send(.kill(session: run.id))
        wait("the run to end") { !phone.sessions.contains { $0.id == run.id } }
        app.press(.id("place-schedules"))
        // A run that is over says how it ended, and how long it took (#47).
        app.wait(for: .containing("· Its session was ended, after"), timeout: 10)
        XCTAssertFalse(app.exists(.containing("· running")))
        app.press(.id("schedule-later"))
        app.wait(for: .text("Edit Schedule"))
        XCTAssertFalse(app.exists(.text("Runs")), "this schedule has not run")
        shot("sched-14-past")
    }

    /// SCHED-29 (#47): a schedule is run now from the list; its run is
    /// stopped there and then says how it ended; what it printed is shown;
    /// the schedule is duplicated, turned off; every schedule is paused and
    /// let go again.
    func testAScheduleIsRunNowStoppedShownDuplicatedAndPaused() throws {
        let phone = try device()
        phone.send(
            .saveSchedule(
                Schedule(
                    id: "now", name: "On demand", agent: "claude", folder: project.path, prompt: "say hello", when: .daily(hour: 9, minute: 0),
                    warningAccepted: true)))
        app.press(.id("place-schedules"))
        app.wait(for: .id("schedule-now"), timeout: 15)
        app.perform("Run Now", on: .id("schedule-now"))
        wait("the run's session", timeout: 20) { phone.sessions.contains { $0.schedule == "On demand" } }
        let run = try XCTUnwrap(phone.sessions.first { $0.schedule == "On demand" })
        app.wait(for: .containing("· running"), timeout: 10)
        // Its agent has started, and said so.
        phone.send(.attach(session: run.id, size: .default))
        wait("the agent at work") { phone.text(run.id).contains("stand-in claude started") }

        app.perform("Stop", on: .containing("· running"))
        wait("the run to end", timeout: 15) { !phone.sessions.contains { $0.id == run.id } }
        app.wait(for: .containing("· Stopped by you, after"), timeout: 15)

        // What it printed was kept.
        app.press(.id("schedule-now"))
        app.wait(for: .text("Edit Schedule"))
        app.wait(for: .text("Runs"))
        app.press(.button("Show the run's output"))
        app.wait(for: .containing("stand-in claude started"), timeout: 10)
        shot("sched-29-output")
        app.press(.button("Close"))

        // A copy, turned off.
        app.perform("Duplicate", on: .id("schedule-now"))
        app.wait(for: .containing("On demand copy"), timeout: 10)
        app.wait(for: .containing("Off ·"))

        // Paused, every one; and let go again.
        app.press(.id("schedules-pause"))
        app.wait(for: .id("schedules-paused"), timeout: 10)
        app.wait(for: .containing("Paused ·"))
        shot("sched-29-paused")
        app.press(.id("schedules-pause"))
        app.waitGone(.id("schedules-paused"), timeout: 10)
        app.wait(for: .containing("Next "))
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
        // SYS-3: Fahrenheit chosen on the phone shows in the Mac's line of figures.
        var display = phone.display ?? DisplaySettings()
        display.temperatureUnit = SystemStats.fahrenheit
        phone.send(.setDisplaySettings(display))
        wait("the Mac's temperature in Fahrenheit", timeout: 15) { self.app.first(.id("system-temperature"))?.label.contains("°F") ?? false }
        // GIT-6: two panels chosen on the phone is what Settings > Git shows here.
        display.diffLayout = "split"
        phone.send(.setDisplaySettings(display))
        openSettings("Git")
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
        // And the Write button names that agent, in Sessions' side panel.
        app.press(.id("place-sessions"))
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
