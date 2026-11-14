import XCTest

@testable import AgentTermHost

/// The short helper commands every git action and look at the changes runs.
final class SubprocessTests: XCTestCase {
    /// What it printed and how it ended, standard error only when asked.
    func testItsOutputAndHowItEnded() throws {
        let result = try XCTUnwrap(Subprocess.run("/bin/sh", ["-c", "echo out; echo err >&2; exit 3"]))
        XCTAssertEqual(result.status, 3)
        XCTAssertEqual(String(decoding: result.output, as: UTF8.self), "out\n")
        let merged = try XCTUnwrap(Subprocess.run("/bin/sh", ["-c", "echo out; echo err >&2"], mergeErrors: true))
        XCTAssertEqual(merged.status, 0)
        XCTAssertEqual(String(decoding: merged.output, as: UTF8.self), "out\nerr\n")
    }

    /// One that takes too long is stopped, and said to have been: not to
    /// have exited, nor to have been killed by something else (#52).
    func testOneThatTakesTooLongIsStopped() throws {
        let started = Date()
        let result = try XCTUnwrap(Subprocess.run("/bin/sleep", ["30"], timeout: 0.3))
        XCTAssertEqual(result.ending, .timedOut)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    /// #52: a command that exits with the number of a signal is not one
    /// that the signal killed, and neither is one stopped at its timeout.
    func testAnExitStatusIsNotASignal() throws {
        let exited = try XCTUnwrap(Subprocess.run("/bin/sh", ["-c", "exit 15"]))
        XCTAssertEqual(exited.ending, .exited(15))
        XCTAssertEqual(exited.status, 15)

        let killed = try XCTUnwrap(Subprocess.run("/bin/sh", ["-c", "kill -TERM $$"]))
        XCTAssertEqual(killed.ending, .signalled(SIGTERM))
        XCTAssertNotEqual(killed.status, exited.status, "killed by SIGTERM is not exit 15")
        XCTAssertNotEqual(killed.status, 0)

        let nine = try XCTUnwrap(Subprocess.run("/bin/sh", ["-c", "exit 9"]))
        let killedHard = try XCTUnwrap(Subprocess.run("/bin/sh", ["-c", "kill -KILL $$"]))
        XCTAssertEqual(nine.ending, .exited(9))
        XCTAssertEqual(killedHard.ending, .signalled(SIGKILL))
        XCTAssertNotEqual(nine.status, killedHard.status)

        // A check for one exit status is not met by a signal of that number:
        // `git check-ignore` answers 1, and SIGHUP is 1.
        let hungUp = try XCTUnwrap(Subprocess.run("/bin/sh", ["-c", "kill -HUP $$"]))
        XCTAssertEqual(hungUp.ending, .signalled(SIGHUP))
        XCTAssertNotEqual(hungUp.status, 1)
    }
}
