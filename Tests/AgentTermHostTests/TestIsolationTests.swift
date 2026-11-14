import XCTest

@testable import AgentTermHost

/// What the host's tests start reads nothing of the person running them.
final class TestIsolationTests: XCTestCase {
    /// Sets a variable for the test, as the person's own shell may have it,
    /// and puts back what was there.
    private func with(_ name: String, _ value: String, _ body: () throws -> Void) rethrows {
        let before = ProcessInfo.processInfo.environment[name]
        setenv(name, value, 1)
        defer { if let before { setenv(name, before, 1) } else { unsetenv(name) } }
        try body()
    }

    /// TEST-2: under the tests, a session's shell and a command run through
    /// the login shell read their startup files from the tests' own empty
    /// folder, also when the person running the tests has ZDOTDIR set.
    func testTheShellsReadNoneOfTheStartupFilesOfThePersonRunningTheTests() {
        let theirs = "/Users/someone/.config/zsh"
        with("ZDOTDIR", theirs) {
            let session = HostEnvironment.sessionEnvironment()["ZDOTDIR"]
            XCTAssertNotNil(session)
            XCTAssertNotEqual(session, theirs, "a session's shell")
            let command = HostEnvironment.loginShellCommandEnvironment?["ZDOTDIR"]
            XCTAssertNotNil(command)
            XCTAssertNotEqual(command, theirs, "a command run through the login shell")
        }
    }
}
