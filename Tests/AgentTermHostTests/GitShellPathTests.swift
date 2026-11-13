import Network
import XCTest

@testable import AgentTermHost

/// What git starts by name while the host runs it: a credential helper, a
/// hook's tools. The host's own PATH does not name the folders the user's
/// shell adds, so these are found through the shell's PATH (issue #29).
///
/// The user's shell is stood in for by a script that prints a PATH with a
/// folder of the test's own in it, and the remote that asks for a sign-in by
/// a listener that answers every request with 401.
final class GitShellPathTests: XCTestCase {
    private var root: URL!
    private var repository: URL { root.appendingPathComponent("repository") }
    private var tools: URL { root.appendingPathComponent("tools") }
    private var shell: URL { root.appendingPathComponent("shell") }
    private var helperRan: URL { root.appendingPathComponent("helper-ran") }
    private var remote: SignInServer!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-gitpath-\(UUID().uuidString)").standardizedFileURL
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        git("init", "-q", "-b", "main")
        // An identity of the test's own, and no signing, whatever the machine is set up with.
        git("config", "user.name", "Test")
        git("config", "user.email", "test@example.com")
        git("config", "commit.gpgsign", "false")
        // An empty helper forgets the ones the machine is set up with, the
        // keychain's too: the test must not reach the user's own sign-ins.
        git("config", "--add", "credential.helper", "")
        try "one\n".write(to: repository.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        git("add", ".")
        git("commit", "-q", "-m", "init")

        remote = try SignInServer()
        git("remote", "add", "origin", "http://127.0.0.1:\(remote.port)/project.git")
        try useShell(path: "\(tools.path):/usr/bin:/bin")
    }

    override func tearDown() {
        GitActions.shellPath = .shared
        remote?.stop()
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func git(_ arguments: String...) -> String {
        let result = Subprocess.run("/usr/bin/git", ["-C", repository.path] + arguments, timeout: 30, mergeErrors: true)
        return String(decoding: result?.output ?? Data(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func script(_ text: String, at url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// Stands a script in for the user's shell: whatever it is asked, it
    /// prints `path` the way the host asks for it, after a line of the kind
    /// a startup file may print.
    private func useShell(path: String) throws {
        try script("#!/bin/sh\necho 'Welcome back'\nprintf 'AGENTTERM_PATH:%s\\n' '\(path)'\n", at: shell)
        let shellPath = shell.path
        GitActions.shellPath = LoginShellPath(shell: { shellPath })
    }

    /// A program named `name`, in the folder only the shell's PATH names.
    private func tool(_ name: String, _ body: String) throws {
        try script("#!/bin/sh\n\(body)\n", at: tools.appendingPathComponent(name))
    }

    private func hook(_ name: String, _ body: String) throws {
        try script("#!/bin/sh\n\(body)\n", at: repository.appendingPathComponent(".git/hooks/\(name)"))
    }

    // MARK: - The credential helper

    func testPushFindsACredentialHelperOnlyTheShellsPathNames() throws {
        // GIT-14
        try tool("agentterm-test-helper", "echo ran >> '\(helperRan.path)'\necho username=someone\necho password=wrong")
        git("config", "--add", "credential.helper", "!agentterm-test-helper")

        let problem = try XCTUnwrap(GitActions.push(in: repository.path), "the stand-in remote takes no sign-in")
        XCTAssertTrue(FileManager.default.fileExists(atPath: helperRan.path), "git did not find the helper: \(problem)")
        XCTAssertFalse(problem.contains("not found"), problem)
        XCTAssertFalse(problem.contains("could not read Username"), problem)
    }

    func testPullFindsItToo() throws {
        // GIT-14
        try tool("agentterm-test-helper", "echo ran >> '\(helperRan.path)'\necho username=someone\necho password=wrong")
        git("config", "--add", "credential.helper", "!agentterm-test-helper")
        // A branch that follows one on the remote, without the remote having been asked.
        git("config", "branch.main.remote", "origin")
        git("config", "branch.main.merge", "refs/heads/main")
        git("update-ref", "refs/remotes/origin/main", "HEAD")

        let problem = try XCTUnwrap(GitActions.pull(in: repository.path), "the stand-in remote takes no sign-in")
        XCTAssertTrue(FileManager.default.fileExists(atPath: helperRan.path), "git did not find the helper: \(problem)")
    }

    func testAHelperThatDoesNotExistIsNamed() throws {
        // GIT-16
        git("config", "--add", "credential.helper", "!agentterm-no-such-helper auth")

        let problem = try XCTUnwrap(GitActions.push(in: repository.path))
        let first = problem.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        XCTAssertTrue(first.contains("git could not sign in to 127.0.0.1"), problem)
        XCTAssertTrue(first.contains("agentterm-no-such-helper") && first.contains("was not found"), problem)
        XCTAssertTrue(problem.contains("could not read Username"), "git's own words follow: \(problem)")
    }

    func testAHelperGitKnowsByNameThatDoesNotExistIsNamedToo() throws {
        // GIT-16
        git("config", "--add", "credential.helper", "agentterm-nowhere")

        let problem = try XCTUnwrap(GitActions.push(in: repository.path))
        let first = problem.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        XCTAssertTrue(first.contains("git could not sign in to 127.0.0.1"), problem)
        XCTAssertTrue(first.contains("agentterm-nowhere") && first.contains("was not found"), problem)
    }

    func testASignInThatIsRefusedIsNotCalledAMissingHelper() throws {
        // GIT-16
        try tool("agentterm-test-helper", "echo username=someone\necho password=wrong")
        git("config", "--add", "credential.helper", "!agentterm-test-helper")

        let problem = try XCTUnwrap(GitActions.push(in: repository.path))
        XCTAssertFalse(problem.contains("was not found"), problem)
        XCTAssertTrue(problem.contains("Authentication failed"), problem)
    }

    // MARK: - Hooks

    func testCommitRunsAHookWhoseToolOnlyTheShellsPathNames() throws {
        // GIT-15
        try tool("agentterm-test-lint", "exit 0")
        try hook("pre-commit", "agentterm-test-lint")
        try "one\ntwo\n".write(to: repository.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        git("add", ".")

        XCTAssertNil(GitActions.commit(message: "second", in: repository.path))
        XCTAssertEqual(git("log", "-1", "--format=%s"), "second")
    }

    // MARK: - Asking the shell

    func testTheShellIsAskedAgainWhenAToolWasNotFound() throws {
        // GIT-17
        // What the shell said when it was first asked: before the tool was installed.
        try useShell(path: "/usr/bin:/bin")
        XCTAssertEqual(GitActions.shellPath.value(), "/usr/bin:/bin")
        try tool("agentterm-test-lint", "exit 0")
        try hook("pre-commit", "agentterm-test-lint")
        try "one\ntwo\n".write(to: repository.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        git("add", ".")
        // The shell's own file now names the folder; the host still holds the old answer.
        try script("#!/bin/sh\nprintf 'AGENTTERM_PATH:%s\\n' '\(tools.path):/usr/bin:/bin'\n", at: shell)

        XCTAssertNil(GitActions.commit(message: "second", in: repository.path))
        XCTAssertEqual(git("log", "-1", "--format=%s"), "second")
    }

    func testAnActionIsNotRunAgainWhenTheShellSaysTheSame() throws {
        // GIT-17
        let ran = root.appendingPathComponent("hook-ran")
        try hook("pre-commit", "echo x >> '\(ran.path)'\nagentterm-test-nowhere")
        try "one\ntwo\n".write(to: repository.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        git("add", ".")

        let problem = try XCTUnwrap(GitActions.commit(message: "second", in: repository.path))
        XCTAssertTrue(problem.contains("command not found"), problem)
        XCTAssertEqual(try String(contentsOf: ran, encoding: .utf8), "x\n", "the shell's PATH did not change, so the commit is not tried again")
    }

    func testReadingWhatGitSaysOfMissingHelpers() {
        // GIT-16
        // What git printed in issue #29, a helper of each kind.
        let said = """
            gh auth git-credential get: gh: command not found
            git: 'credential-wincred' is not a git command. See 'git --help'.
            fatal: could not read Username for 'https://github.com': terminal prompts disabled
            """
        XCTAssertEqual(GitActions.missingHelpers(in: said), ["gh", "wincred"])
        let first = GitActions.explainingSignIn(said).split(whereSeparator: \.isNewline).first.map(String.init)
        XCTAssertEqual(first, "git could not sign in to github.com: its credential helpers `gh` and `wincred` were not found.")
        // A hook's tool that is missing is not a credential helper.
        XCTAssertEqual(GitActions.missingHelpers(in: ".git/hooks/pre-push: line 2: lint: command not found"), [])
        // Nor is a missing helper the reason when git was given a sign-in that was refused.
        let refused = "gh auth git-credential get: gh: command not found\nfatal: Authentication failed for 'https://github.com/a/b.git/'"
        XCTAssertEqual(GitActions.explainingSignIn(refused), refused)
    }

    func testTheShellIsAskedOnce() throws {
        // GIT-18
        let counter = root.appendingPathComponent("asked")
        try script("#!/bin/sh\necho x >> '\(counter.path)'\nprintf 'AGENTTERM_PATH:%s\\n' '/usr/bin:/bin'\n", at: shell)
        let path = LoginShellPath(shell: { [shell] in shell.path })
        XCTAssertEqual(path.value(), "/usr/bin:/bin")
        XCTAssertEqual(path.value(), "/usr/bin:/bin")
        XCTAssertEqual(try String(contentsOf: counter, encoding: .utf8), "x\n")
        XCTAssertFalse(path.refresh(), "the same answer is not a change")
    }

    func testAShellThatSaysNothingLeavesThePathAsItIs() throws {
        // GIT-18
        try script("#!/bin/sh\nexit 1\n", at: shell)
        let path = LoginShellPath(shell: { [shell] in shell.path })
        XCTAssertNil(path.value())
        GitActions.shellPath = path
        XCTAssertEqual(GitActions.remoteEnvironment["PATH"], ProcessInfo.processInfo.environment["PATH"])
    }

    func testReadingWhatTheShellPrints() {
        // GIT-18
        XCTAssertEqual(LoginShellPath.parse("AGENTTERM_PATH:/opt/homebrew/bin:/usr/bin\n"), "/opt/homebrew/bin:/usr/bin")
        XCTAssertEqual(LoginShellPath.parse("Last login: today\nAGENTTERM_PATH:/a:/b\n"), "/a:/b")
        XCTAssertEqual(LoginShellPath.parse("AGENTTERM_PATH:/has a space/bin:/usr/bin\n"), "/has a space/bin:/usr/bin")
        XCTAssertNil(LoginShellPath.parse("AGENTTERM_PATH:\n"))
        XCTAssertNil(LoginShellPath.parse("nothing of the kind\n"))
    }

    func testGitIsGivenTheShellsPath() {
        // GIT-18
        XCTAssertEqual(GitActions.remoteEnvironment["PATH"], "\(tools.path):/usr/bin:/bin")
        XCTAssertEqual(GitActions.remoteEnvironment["GIT_TERMINAL_PROMPT"], "0", "and still never asks for a password")
    }
}

/// A remote that wants a sign-in and takes none: every request is answered
/// with 401, which is when git turns to its credential helper.
private final class SignInServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "agentterm.tests.signin")
    let port: UInt16

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled: ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [queue] connection in
            connection.start(queue: queue)
            Self.answer(connection, received: Data())
        }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        guard let port = listener.port?.rawValue else { throw CocoaError(.featureUnsupported) }
        self.port = port
    }

    func stop() { listener.cancel() }

    private static func answer(_ connection: NWConnection, received: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            var received = received
            if let data { received.append(data) }
            // The requests git makes before it has signed in carry no body.
            guard received.range(of: Data("\r\n\r\n".utf8)) != nil else {
                if isComplete || error != nil { connection.cancel() } else { answer(connection, received: received) }
                return
            }
            let response = "HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Basic realm=\"test\"\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
