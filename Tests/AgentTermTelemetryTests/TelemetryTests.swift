import AgentTermTelemetry
import XCTest

final class TelemetryTests: XCTestCase {
    private final class Recorder: TelemetrySink {
        var usage: Bool?
        var crashes: Bool?
        var events: [TelemetryEvent] = []
        var problems: [TelemetryProblem] = []

        func setUsageStatistics(enabled: Bool) { usage = enabled }
        func setCrashReports(enabled: Bool) { crashes = enabled }
        func record(_ event: TelemetryEvent) { events.append(event) }
        func recordProblem(_ kind: TelemetryProblem) { problems.append(kind) }
    }

    private var defaults: UserDefaults!
    private var suite = ""

    override func setUp() {
        suite = "agentterm-telemetry-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    /// TEL-1 (#48): nothing is sent, of either kind, before the user has
    /// answered the first-launch screen; then what its two switches say.
    func testNothingIsSentUntilTheFirstLaunchScreenIsAnswered() {
        let telemetry = Telemetry()
        let sink = Recorder()
        telemetry.start(sink: sink, defaults: defaults)
        XCTAssertEqual(sink.usage, false, "not before the user has been asked")
        XCTAssertEqual(sink.crashes, false, "not before the user has been asked")
        XCTAssertTrue(telemetry.shouldAskAboutCrashReports)

        telemetry.record(.sessionStart(agent: .claude))
        telemetry.recordProblem(.hostExitedUnexpectedly)
        XCTAssertEqual(sink.events, [], "usage statistics wait for the answer too")
        XCTAssertEqual(sink.problems, [])

        // Answered as the screen comes: both on.
        let preferences = TelemetryPreferences(telemetry: telemetry)
        XCTAssertTrue(preferences.needsAsking)
        XCTAssertTrue(preferences.offersCrashReports && preferences.offersUsageStatistics, "both switches start on")
        preferences.answer()
        XCTAssertFalse(preferences.needsAsking)
        XCTAssertEqual(telemetry.settings, TelemetrySettings(usageStatistics: true, crashReports: true))
        XCTAssertEqual(sink.usage, true)
        XCTAssertEqual(sink.crashes, true)
        XCTAssertFalse(telemetry.shouldAskAboutCrashReports)
        telemetry.record(.sessionStart(agent: .claude))
        telemetry.recordProblem(.hostExitedUnexpectedly)
        XCTAssertEqual(sink.events, [.sessionStart(agent: .claude)])
        XCTAssertEqual(sink.problems, [.hostExitedUnexpectedly])
    }

    /// TEL-2 (#48): the screen answered with a switch off keeps that kind
    /// off, and is not shown again at the next launch.
    func testTheFirstLaunchScreenAnsweredWithSwitchesOff() {
        let telemetry = Telemetry()
        let sink = Recorder()
        telemetry.start(sink: sink, defaults: defaults)
        let preferences = TelemetryPreferences(telemetry: telemetry)
        preferences.offersUsageStatistics = false
        XCTAssertEqual(sink.usage, false, "a switch of the screen sends nothing by itself")
        XCTAssertTrue(preferences.needsAsking, "nor does it answer the screen")
        preferences.answer()
        XCTAssertEqual(telemetry.settings, TelemetrySettings(usageStatistics: false, crashReports: true))
        XCTAssertEqual(sink.usage, false)
        XCTAssertEqual(sink.crashes, true)
        telemetry.record(.appOpen)
        XCTAssertEqual(sink.events, [])

        let later = Telemetry()
        later.start(sink: Recorder(), defaults: defaults)
        let again = TelemetryPreferences(telemetry: later)
        XCTAssertFalse(again.needsAsking)
        XCTAssertFalse(again.usageStatistics)
        XCTAssertTrue(again.crashReports)

        // Both off: answered all the same.
        let other = UserDefaults(suiteName: suite + "-other")!
        defer { other.removePersistentDomain(forName: suite + "-other") }
        let none = Telemetry()
        none.start(sink: Recorder(), defaults: other)
        let refusing = TelemetryPreferences(telemetry: none)
        refusing.offersCrashReports = false
        refusing.offersUsageStatistics = false
        refusing.answer()
        XCTAssertEqual(none.settings, TelemetrySettings(usageStatistics: false, crashReports: false))
        XCTAssertFalse(none.shouldAskAboutCrashReports)
    }

    func testSwitchedOffNothingIsRecordedAndTheChoiceIsKept() {
        let telemetry = Telemetry()
        let sink = Recorder()
        telemetry.start(sink: sink, defaults: defaults)
        telemetry.settings = TelemetrySettings(usageStatistics: false, crashReports: false)
        XCTAssertEqual(sink.usage, false)
        telemetry.record(.appOpen)
        telemetry.recordProblem(.hostExitedUnexpectedly)
        XCTAssertEqual(sink.events, [])
        XCTAssertEqual(sink.problems, [])

        // Another launch reads the same choices, and does not ask again.
        let later = Telemetry()
        let laterSink = Recorder()
        later.start(sink: laterSink, defaults: defaults)
        XCTAssertEqual(later.settings, TelemetrySettings(usageStatistics: false, crashReports: false))
        XCTAssertEqual(laterSink.usage, false)
        XCTAssertFalse(later.shouldAskAboutCrashReports)
    }

    func testWithNoServiceThereIsNothingToAskOrSend() {
        let telemetry = Telemetry()
        telemetry.start(sink: nil, defaults: defaults)
        XCTAssertFalse(telemetry.isAvailable)
        XCTAssertFalse(telemetry.shouldAskAboutCrashReports)
        telemetry.record(.appOpen)
    }

    func testEventsCarryOnlyWordsFromAFixedSet() {
        XCTAssertEqual(TelemetryEvent.Agent(id: "codex"), .codex)
        XCTAssertEqual(TelemetryEvent.Agent(id: nil), .shell)
        XCTAssertEqual(TelemetryEvent.Agent(id: "/Users/me/secret-project/run.sh"), .shell, "an unknown command says nothing about itself")
        let all: [TelemetryEvent] = [
            .appOpen, .devicePaired, .sessionStart(agent: .agy), .versionMismatch(hostIsOlder: true),
            .handoff(from: .claude, to: .copilot, otherFolder: true),
        ]
        let allowed = Set(TelemetryEvent.Agent.allCases.map(\.rawValue) + ["yes", "no", "older", "newer"])
        for event in all {
            XCTAssertTrue(event.name.allSatisfy { $0.isLowercase || $0 == "_" }, event.name)
            for value in event.parameters.values { XCTAssertTrue(allowed.contains(value), "\(event.name): \(value)") }
        }
        XCTAssertEqual(TelemetryEvent.handoff(from: .claude, to: .codex, otherFolder: false).parameters, ["from": "claude", "to": "codex", "other_folder": "no"])
    }
}
