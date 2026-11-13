#if os(macOS)
import Darwin
import Foundation

/// Starts `agenttermd` detached from the app, so sessions outlive the window.
public enum DaemonLauncher {
    public static var logFile: URL { HostEnvironment.supportDirectory.appendingPathComponent("agenttermd.log") }

    /// The daemon binary that ships next to the running executable.
    public static var bundledExecutable: String? {
        guard let directory = Bundle.main.executableURL?.deletingLastPathComponent() else { return nil }
        let path = directory.appendingPathComponent("agenttermd").path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    /// The program that listens on a local TCP port, if there is one.
    public static func listener(onPort port: UInt16) -> (pid: pid_t, path: String)? {
        guard let result = Subprocess.run("/usr/sbin/lsof", ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"], timeout: 5),
            let pid = String(decoding: result.output, as: UTF8.self).split(whereSeparator: \.isNewline).first.flatMap({ pid_t($0) })
        else { return nil }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return (pid, String(cString: buffer))
    }

    /// Whether a host found running is the one that ships with this app. A
    /// host left running by another copy of the app, an older version for
    /// one, answers on the same port and would be used without a word.
    public static func isBundled(_ path: String) -> Bool {
        guard let own = bundledExecutable else { return true }
        return URL(fileURLWithPath: own).resolvingSymlinksInPath().path == URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    /// Asks a host to stop. Its sessions end with it.
    public static func stop(_ pid: pid_t) {
        kill(pid, SIGTERM)
    }

    /// How `startHost` started the host.
    public enum Start: Equatable, Sendable {
        /// launchd runs it already: it started it again after it died.
        case running
        /// launchd was asked to start it.
        case launchd
        /// The app started it itself.
        case spawned(pid_t)
        /// It could not be started, and why.
        case failed(String)
    }

    /// Starts this Mac's host, with one owner only. While Start at Login
    /// is on, launchd is asked to start it, which also starts it again
    /// should it crash; else the app starts it itself. A job launchd still
    /// has loaded from before Start at Login was turned off is unloaded
    /// first, so that launchd does not start a second host next to the
    /// app's.
    ///
    /// launchd waits ten seconds from a job's last start before it starts
    /// it again: a job that is waiting is loaded afresh, which starts it at
    /// once. Also returns how the last host launchd ran ended, when it did
    /// not end cleanly.
    public static func startHost(
        executable: String, arguments: [String], loginItem item: LoginItem?, environment: [String: String] = ProcessInfo.processInfo.environment,
        log: URL? = nil
    ) -> (start: Start, lastExit: Int32?) {
        let job = item?.jobState()
        let lastExit = job.flatMap { $0.lastExitStatus != 0 ? $0.lastExitStatus : nil }
        if job?.pid != nil { return (.running, lastExit) }
        if let item, item.isOn {
            // launchd starts what the file says: the host of the app that
            // is here now (LOGIN-4), not a build run by hand (LOGIN-5).
            item.refresh()
            if job != nil { item.unload() }
            if (try? item.load()) != nil { return (.launchd, lastExit) }
            // launchd would not have it: the app starts it, so it runs.
        } else if job != nil {
            item?.unload()
        }
        guard let pid = launch(executable: executable, arguments: arguments, environment: environment, log: log ?? logFile) else {
            return (.failed("\(executable) could not be run."), lastExit)
        }
        return (.spawned(pid), lastExit)
    }

    /// Spawns the daemon in its own session with output going to the log
    /// file. Returns its process, or nil when it could not be run.
    @discardableResult
    public static func launch(
        executable: String, arguments: [String] = [], environment: [String: String] = ProcessInfo.processInfo.environment, log: URL = logFile
    ) -> pid_t? {
        try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, log.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        posix_spawn_file_actions_adddup2(&actions, STDOUT_FILENO, STDERR_FILENO)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))

        let argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        return posix_spawn(&pid, executable, &actions, &attributes, argv, envp) == 0 ? pid : nil
    }

    /// Waits for a host this app started to end, and hands over how it
    /// ended (as `waitpid` says it) on the main queue. Waiting also takes
    /// the ended process off the system's books.
    public static func watch(_ pid: pid_t, onExit: @escaping @Sendable (Int32) -> Void) {
        Thread.detachNewThread {
            var status: Int32 = 0
            var result: pid_t
            repeat { result = waitpid(pid, &status, 0) } while result == -1 && errno == EINTR
            guard result == pid else { return }
            DispatchQueue.main.async { onExit(status) }
        }
    }

    /// How a host ended, in words that finish "The last time, …": from the
    /// status `waitpid` gave, and for one that exited on its own, what it
    /// last wrote to its log about why.
    public static func describe(exitStatus status: Int32, log: URL? = nil) -> String {
        let signal = status & 0x7f
        if signal == 0 {
            let code = (status >> 8) & 0xff
            let said = lastProblem(in: log ?? logFile)
            return "it exited with status \(code)" + (said.map { ": \($0)" } ?? "")
        }
        let names: [Int32: String] = [
            SIGKILL: "SIGKILL", SIGSEGV: "SIGSEGV", SIGBUS: "SIGBUS", SIGILL: "SIGILL", SIGABRT: "SIGABRT", SIGTRAP: "SIGTRAP", SIGFPE: "SIGFPE",
            SIGHUP: "SIGHUP", SIGINT: "SIGINT", SIGTERM: "SIGTERM", SIGQUIT: "SIGQUIT",
        ]
        let name = names[signal] ?? "signal \(signal)"
        switch signal {
        case SIGKILL: return "it was killed (\(name)), by macOS or by another program"
        case SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGTRAP, SIGFPE: return "it crashed (\(name))"
        default: return "it was stopped by \(name)"
        }
    }

    /// The last line of a host's log that says what went wrong: the host
    /// writes "agenttermd: <problem>" before it gives up.
    static func lastProblem(in log: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: log) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 4096 ? size - 4096 : 0)
        let text = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
        guard let line = text.split(whereSeparator: \.isNewline).last(where: { $0.hasPrefix("agenttermd: ") }) else { return nil }
        return String(line.dropFirst("agenttermd: ".count))
    }
}
#endif
