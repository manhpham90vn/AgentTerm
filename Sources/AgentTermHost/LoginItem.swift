#if os(macOS)
import AgentTermProtocol
import Foundation

/// Has the host started when the user logs in, so the Mac can be reached
/// from the iPhone after a restart without the app being opened first.
///
/// It is a launch agent: a property list in `~/Library/LaunchAgents` that
/// names the host's program. launchd reads that folder at login and starts
/// what it finds, and starts it again should it crash or be killed
/// (`KeepAlive`), not when it was stopped as asked. While it is on, the app
/// starts the host through launchd too (`DaemonLauncher.startHost`), so the
/// host has one owner. Nothing is loaded when the switch is turned on,
/// because the host that turns it on is already running: launchd takes it
/// over the next time the host is started.
public struct LoginItem: Equatable, Sendable {
    public var label: String
    /// The property list launchd reads.
    public var file: URL
    public var executable: String
    public var arguments: [String]
    public var log: URL
    /// Set in the host's environment by launchd. Empty for the real login
    /// item; a test gives its host a state folder of its own this way.
    public var environment: [String: String]

    public init(label: String, file: URL, executable: String, arguments: [String], log: URL, environment: [String: String] = [:]) {
        self.label = label
        self.file = file
        self.executable = executable
        self.arguments = arguments
        self.log = log
        self.environment = environment
    }

    /// The login item of the host that is running, started again the way
    /// this one was. Nil for a host that keeps its files somewhere of its
    /// own, a test or a trial run, which has no business at login.
    public static func forThisHost(environment: [String: String] = ProcessInfo.processInfo.environment) -> LoginItem? {
        guard let executable = Bundle.main.executablePath else { return nil }
        return forHost(executable: executable, arguments: Array(CommandLine.arguments.dropFirst()), environment: environment)
    }

    /// The login item of the host the app starts, `executable` with
    /// `arguments`: what the host writes when it is turned on. Nil for an
    /// app that keeps its files somewhere of its own, a test or a trial run.
    public static func forHost(executable: String, arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment) -> LoginItem? {
        guard (environment["AGENTTERM_STATE_DIR"] ?? "").isEmpty else { return nil }
        let label = AppChannel.current.bundleIdentifier + ".host"
        let agents = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("LaunchAgents", isDirectory: true)
        return LoginItem(
            label: label, file: agents.appendingPathComponent(label + ".plist"),
            executable: URL(fileURLWithPath: executable).resolvingSymlinksInPath().path,
            arguments: arguments, log: DaemonLauncher.logFile)
    }

    public var isOn: Bool { FileManager.default.fileExists(atPath: file.path) }

    /// What launchd is told.
    var propertyList: [String: Any] {
        var list: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable] + arguments,
            "RunAtLoad": true,
            // Started again when it crashed or was killed, not when it was
            // stopped as asked: such a host exits with status 0.
            "KeepAlive": ["SuccessfulExit": false],
            // It serves what the user is doing: not to be held back as background work.
            "ProcessType": "Interactive",
            "StandardOutPath": log.path,
            "StandardErrorPath": log.path,
        ]
        if !environment.isEmpty { list["EnvironmentVariables"] = environment }
        return list
    }

    public func turnOn() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: propertyList, format: .xml, options: 0)
        try data.write(to: file, options: .atomic)
    }

    public func turnOff() throws {
        guard isOn else { return }
        try FileManager.default.removeItem(at: file)
    }

    /// True for a host that is part of an app, not a build run by hand.
    var isInsideAnApp: Bool { executable.contains(".app/Contents/MacOS/") }

    /// The app may have been moved since the switch was turned on: launchd
    /// would then start a host that is no longer there, so the host of the
    /// app that is running is put in its place.
    ///
    /// Not every host that starts may do that. One started by hand in
    /// another way is the same program, and leaves the login item as the
    /// user set it. A build that is not part of an app, run to try
    /// something, is not what the user asked to have at login.
    ///
    /// Only names are compared: what the property list says is never used
    /// as a path to look at.
    ///
    /// One written for this same host by an earlier version, without
    /// `KeepAlive` for one, is written again as this version writes it.
    public func refresh() {
        guard isOn, isInsideAnApp, let current = NSDictionary(contentsOf: file) as? [String: Any] else { return }
        let program = current["ProgramArguments"] as? [String]
        if program?.first == executable {
            guard program == [executable] + arguments, !NSDictionary(dictionary: current).isEqual(to: propertyList) else { return }
        }
        try? turnOn()
    }
}

// MARK: launchd

extension LoginItem {
    /// What launchd knows of the job, when it has it loaded.
    public struct JobState: Equatable, Sendable {
        /// The host launchd runs for it now, if any.
        public var pid: pid_t?
        /// How the last host it ran ended, as `waitpid` says it: 0 when it
        /// exited cleanly or has not ended yet.
        public var lastExitStatus: Int32

        public init(pid: pid_t?, lastExitStatus: Int32) {
            self.pid = pid
            self.lastExitStatus = lastExitStatus
        }
    }

    /// The user's own launchd: the one that reads `~/Library/LaunchAgents` at login.
    static var domain: String { "gui/\(getuid())" }

    /// What launchd knows of the job, nil when it does not have it loaded.
    public func jobState() -> JobState? {
        guard let result = Subprocess.run("/bin/launchctl", ["list", label], timeout: 5), result.status == 0 else { return nil }
        let text = String(decoding: result.output, as: UTF8.self)
        return JobState(pid: Self.number("PID", in: text).map { pid_t($0) }, lastExitStatus: Self.number("LastExitStatus", in: text) ?? 0)
    }

    /// `"Key" = 123;` in what `launchctl list <label>` prints.
    static func number(_ key: String, in text: String) -> Int32? {
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, parts[0] == "\"\(key)\"" else { continue }
            return Int32(parts[1].trimmingCharacters(in: CharacterSet(charactersIn: ";")))
        }
        return nil
    }

    /// Has launchd load the job from its property list, which starts the
    /// host (`RunAtLoad`) at once.
    public func load() throws {
        guard let result = Subprocess.run("/bin/launchctl", ["bootstrap", Self.domain, file.path], timeout: 10, mergeErrors: true) else {
            throw LaunchdError(text: "launchctl could not be run")
        }
        guard result.status == 0 else {
            let said = String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw LaunchdError(text: said.isEmpty ? "launchctl bootstrap failed with status \(result.status)" : said)
        }
    }

    /// Has launchd forget the job until it is loaded again, at the next
    /// login or by `load()`. A host it runs is stopped as asked (SIGTERM).
    public func unload() {
        _ = Subprocess.run("/bin/launchctl", ["bootout", "\(Self.domain)/\(label)"], timeout: 10)
    }
}

public struct LaunchdError: Error, LocalizedError, Equatable {
    public var text: String
    public var errorDescription: String? { text }
}
#endif
