import AgentTermProtocol
import XCTest

/// SCHED-14: the schedules in three groups, as both apps show them: the runs
/// whose session still runs, the schedules by when they run next, and the
/// runs that are over, newest first.
final class ScheduleOverviewTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testRunsAndSchedulesAreGrouped() {
        let nightly = Schedule(
            id: "nightly", name: "Nightly", agent: "claude", folder: "/p", prompt: "test", when: .daily(hour: 2, minute: 0),
            runs: [
                ScheduleRun(at: now.addingTimeInterval(-86_400), started: true, session: 3, note: "Started"),
                ScheduleRun(at: now.addingTimeInterval(-600), started: true, session: 9, note: "Started"),
            ], nextRun: now.addingTimeInterval(80_000))
        let review = Schedule(
            id: "review", name: "Review", agent: "codex", folder: "/p", prompt: "review", when: .daily(hour: 14, minute: 0),
            runs: [ScheduleRun(at: now.addingTimeInterval(-3_600), started: false, note: "Missed while the Mac was asleep")],
            nextRun: now.addingTimeInterval(3_600))
        let off = Schedule(id: "off", name: "Weekly", agent: "claude", folder: "/p", prompt: "x", when: .limitReset, enabled: false)
        let waiting = Schedule(id: "limit", name: "At the reset", agent: "claude", folder: "/p", prompt: "x", when: .limitReset)

        let overview = ScheduleOverview(schedules: [nightly, off, waiting, review], liveSessions: [9, 42])
        XCTAssertEqual(overview.running.map(\.run.session), [9], "only a run whose session still runs")
        XCTAssertEqual(overview.running.first?.schedule.id, "nightly")
        XCTAssertEqual(
            overview.scheduled.map(\.id), ["review", "nightly", "limit", "off"], "the next to run first, then those with no time, then those turned off")
        XCTAssertEqual(overview.past.map(\.run.note), ["Missed while the Mac was asleep", "Started"], "newest first")
        XCTAssertEqual(overview.past.map(\.schedule.id), ["review", "nightly"])
        XCTAssertEqual(Set(overview.past.map(\.id)).count, 2, "each run has an id of its own")
    }

    func testNothingScheduled() {
        let overview = ScheduleOverview(schedules: [], liveSessions: [1])
        XCTAssertTrue(overview.running.isEmpty && overview.scheduled.isEmpty && overview.past.isEmpty)
    }
}
