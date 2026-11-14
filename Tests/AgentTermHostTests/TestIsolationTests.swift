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

    /// TEST-3: under the tests, git reads no global configuration of the
    /// person running them (their identity, hooks, signing): not the git
    /// the host runs, nor one run in a session.
    func testGitReadsNoGlobalConfigurationOfThePersonRunningTheTests() throws {
        let result = try XCTUnwrap(Subprocess.run("/usr/bin/git", ["config", "--global", "--list"]))
        // What it read is not printed: it is theirs.
        XCTAssertTrue(result.status != 0 || result.output.isEmpty, "the git the host runs read a global configuration")
        let explicit = try XCTUnwrap(Subprocess.run("/usr/bin/git", ["config", "--global", "--list"], environment: ProcessInfo.processInfo.environment))
        XCTAssertTrue(explicit.status != 0 || explicit.output.isEmpty, "nor with an environment given")
        XCTAssertEqual(HostEnvironment.sessionEnvironment()["GIT_CONFIG_GLOBAL"], "/dev/null", "nor in a session")
    }
}
