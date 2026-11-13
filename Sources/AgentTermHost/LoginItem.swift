#if os(macOS)
import AgentTermProtocol
import Foundation

/// Has the host started when the user logs in, so the Mac can be reached
/// from the iPhone after a restart without the app being opened first.
///
/// It is a launch agent: a property list in `~/Library/LaunchAgents` that
/// names the host's program. launchd reads that folder at login and starts
/// what it finds. Nothing is loaded when the switch is turned on, because
/// the host that turns it on is already running; and nothing restarts the
/// host when it stops, because the app does that, with its own copy.
public struct LoginItem: Equatable, Sendable {
    public var label: String
    /// The property list launchd reads.
    public var file: URL
    public var executable: String
    public var arguments: [String]
    public var log: URL

    public init(label: String, file: URL, executable: String, arguments: [String], log: URL) {
        self.label = label
        self.file = file
        self.executable = executable
        self.arguments = arguments
        self.log = log
    }

    /// The login item of the host that is running, started again the way
    /// this one was. Nil for a host that keeps its files somewhere of its
    /// own, a test or a trial run, which has no business at login.
    public static func forThisHost(environment: [String: String] = ProcessInfo.processInfo.environment) -> LoginItem? {
        guard (environment["AGENTTERM_STATE_DIR"] ?? "").isEmpty, let executable = Bundle.main.executablePath else { return nil }
        let label = AppChannel.current.bundleIdentifier + ".host"
        let agents = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("LaunchAgents", isDirectory: true)
        return LoginItem(
            label: label, file: agents.appendingPathComponent(label + ".plist"),
            executable: URL(fileURLWithPath: executable).resolvingSymlinksInPath().path,
            arguments: Array(CommandLine.arguments.dropFirst()), log: DaemonLauncher.logFile)
    }

    public var isOn: Bool { FileManager.default.fileExists(atPath: file.path) }

    /// What launchd is told.
    var propertyList: [String: Any] {
        [
            "Label": label,
            "ProgramArguments": [executable] + arguments,
            "RunAtLoad": true,
            // It serves what the user is doing: not to be held back as background work.
            "ProcessType": "Interactive",
            "StandardOutPath": log.path,
            "StandardErrorPath": log.path,
        ]
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

    /// The app may have been moved since the switch was turned on: launchd
    /// would then start a host that is no longer there. Only then is this
    /// host put in its place. One that is still there is left alone: this
    /// may be another copy of the app, or a host started by hand in some
    /// other way, and neither is what the user asked to have at login.
    public func refresh() {
        guard isOn, let current = NSDictionary(contentsOf: file) as? [String: Any] else { return }
        if let program = (current["ProgramArguments"] as? [String])?.first, FileManager.default.isExecutableFile(atPath: program) { return }
        try? turnOn()
    }
}
#endif
