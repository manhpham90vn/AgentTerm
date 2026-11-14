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

    /// One that takes too long is stopped, and said to have ended of it.
    func testOneThatTakesTooLongIsStopped() throws {
        let started = Date()
        let result = try XCTUnwrap(Subprocess.run("/bin/sleep", ["30"], timeout: 0.3))
        XCTAssertEqual(result.status, SIGTERM)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }
}
