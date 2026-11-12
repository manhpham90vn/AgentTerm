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

    func testUsageIsOnAndCrashReportsAreOffUntilTheUserSaysYes() {
        let telemetry = Telemetry()
        let sink = Recorder()
        telemetry.start(sink: sink, defaults: defaults)
        XCTAssertEqual(sink.usage, true)
        XCTAssertEqual(sink.crashes, false, "not before the user has been asked")
        XCTAssertTrue(telemetry.shouldAskAboutCrashReports)

        telemetry.record(.sessionStart(agent: .claude))
        telemetry.recordProblem(.hostExitedUnexpectedly)
        XCTAssertEqual(sink.events, [.sessionStart(agent: .claude)])
        XCTAssertEqual(sink.problems, [], "a problem is a crash report, and those are not allowed yet")

        telemetry.settings.crashReports = true
        XCTAssertEqual(sink.crashes, true)
        XCTAssertFalse(telemetry.shouldAskAboutCrashReports)
        telemetry.recordProblem(.hostExitedUnexpectedly)
        XCTAssertEqual(sink.problems, [.hostExitedUnexpectedly])
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
