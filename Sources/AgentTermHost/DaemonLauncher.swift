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

    /// Spawns the daemon in its own session with output going to the log file.
    @discardableResult
    public static func launch(executable: String, arguments: [String] = []) -> Bool {
        try? FileManager.default.createDirectory(at: HostEnvironment.supportDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, logFile.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        posix_spawn_file_actions_adddup2(&actions, STDOUT_FILENO, STDERR_FILENO)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))

        let argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        return posix_spawn(&pid, executable, &actions, &attributes, argv, envp) == 0
    }
}
#endif
