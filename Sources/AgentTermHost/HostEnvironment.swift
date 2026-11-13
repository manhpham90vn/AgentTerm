#if os(macOS)
import AgentTermProtocol
import Darwin
import Foundation

/// Where the host keeps its files and how it starts user programs.
public enum HostEnvironment {
    /// Token, folder list and log live here. `AGENTTERM_STATE_DIR` moves them,
    /// which keeps test runs away from the real pairing.
    public static var supportDirectory: URL {
        if let custom = ProcessInfo.processInfo.environment["AGENTTERM_STATE_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        // A development build keeps its files apart from the released app's.
        let directory = base.appendingPathComponent(AppChannel.current.appName, isDirectory: true)
        // The app was called Agentty before. What it kept, the paired
        // devices above all, moves over the first time the released app
        // runs under the new name.
        let former = base.appendingPathComponent("Agentty", isDirectory: true)
        if AppChannel.current == .release, !FileManager.default.fileExists(atPath: directory.path), FileManager.default.fileExists(atPath: former.path) {
            try? FileManager.default.moveItem(at: former, to: directory)
        }
        return directory
    }

    public static var tokenFile: URL { supportDirectory.appendingPathComponent("token") }

    public static var devicesFile: URL { supportDirectory.appendingPathComponent("devices.json") }

    public static var foldersFile: URL { supportDirectory.appendingPathComponent("folders.json") }

    /// What Claude Code sessions report about their usage, one file each.
    public static var usageDirectory: URL { supportDirectory.appendingPathComponent("usage", isDirectory: true) }

    /// Where an agent that writes a commit message runs: a folder of the
    /// host's own, so the run leaves nothing in the project.
    public static var commitWriterDirectory: URL { supportDirectory.appendingPathComponent("commit-writer", isDirectory: true) }

    public static var homeDirectory: String { NSHomeDirectory() }

    /// The user's login shell.
    public static var shell: String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let path = String(cString: shell)
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        if let shell = ProcessInfo.processInfo.environment["SHELL"],
            FileManager.default.isExecutableFile(atPath: shell)
        {
            return shell
        }
        return "/bin/zsh"
    }

    /// Environment for programs running inside a session.
    public static func sessionEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        // When the host was itself started from inside an agent's terminal,
        // that agent's variables would make a new agent think it is nested.
        // Only the markers are removed, not settings the user may have made.
        for key in ["CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_CHILD_SESSION"] {
            env[key] = nil
        }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "AgentTerm"
        env["SHELL"] = shell
        env["HOME"] = homeDirectory
        // A UTF-8 locale is required for Vietnamese and other non-ASCII input
        // to round-trip. GUI-launched processes often have no locale at all.
        let hasUTF8 = ["LC_ALL", "LC_CTYPE", "LANG"].contains { env[$0]?.uppercased().contains("UTF-8") == true }
        if !hasUTF8 {
            env["LANG"] = "en_US.UTF-8"
            env["LC_CTYPE"] = "en_US.UTF-8"
        }
        return env
    }

    /// Arguments that start `command` through the login shell, or a plain
    /// login shell when `command` is nil. Going through the shell gives the
    /// program the same PATH the user has in a regular terminal.
    public static func shellArguments(command: String?) -> [String] {
        let name = (shell as NSString).lastPathComponent
        guard let command, !command.isEmpty else { return ["-" + name] }
        return [name, "-l", "-i", "-c", command]
    }

    /// Returns the Mac's own token, creating it on first use. It lets apps on
    /// this Mac talk to the host and is never given to another device. The
    /// file is readable by the user only.
    public static func loadOrCreateToken() throws -> String {
        let fm = FileManager.default
        if let data = fm.contents(atPath: tokenFile.path),
            let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
            token.count >= 32
        {
            return token
        }
        try fm.createDirectory(at: supportDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let token = DeviceRegistry.randomToken()
        guard fm.createFile(atPath: tokenFile.path, contents: Data(token.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return token
    }
}

/// Runs a short helper command and returns its standard output.
enum Subprocess {
    /// - Parameter mergeErrors: also capture what the command writes to standard error.
    ///
    /// Started with `posix_spawn` and waited for with `waitpid`: Foundation's
    /// `Process` took some 70 ms to start a command and to see it end, which
    /// a git action or a look at the changes runs several of (#21).
    static func run(
        _ executable: String, _ arguments: [String], cwd: String? = nil, timeout: TimeInterval = 10, mergeErrors: Bool = false,
        environment: [String: String]? = nil
    ) -> (status: Int32, output: Data)? {
        var pipe: [Int32] = [0, 0]
        guard Darwin.pipe(&pipe) == 0 else { return nil }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, pipe[1], STDOUT_FILENO)
        if mergeErrors {
            posix_spawn_file_actions_adddup2(&actions, pipe[1], STDERR_FILENO)
        } else {
            posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
        }
        if let cwd { posix_spawn_file_actions_addchdir_np(&actions, cwd) }
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Nothing of this process's but the three is passed on.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))

        let argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = (environment ?? ProcessInfo.processInfo.environment).map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
        close(pipe[1])
        guard spawned == 0 else {
            close(pipe[0])
            return nil
        }

        // Stopped when it takes too long; never once it was waited for, when
        // its number may be another program's.
        let lock = NSLock()
        var ended = false
        let timer = DispatchWorkItem {
            lock.lock()
            defer { lock.unlock() }
            if !ended { kill(pid, SIGTERM) }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        // Read before waiting so a full pipe cannot stall the child.
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(pipe[0], &buffer, buffer.count)
            if count > 0 {
                output.append(buffer, count: count)
            } else if count < 0 && errno == EINTR {
                continue
            } else {
                break
            }
        }
        close(pipe[0])
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        lock.lock()
        ended = true
        lock.unlock()
        timer.cancel()
        let signal = status & 0x7f
        return (signal == 0 ? (status >> 8) & 0xff : signal, output)
    }
}
#endif
