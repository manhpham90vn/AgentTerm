import Foundation

/// What AgentTerm may report about how it is used. The list is closed, and
/// every value an event carries is one of a fixed set of words: there is no
/// way to put a folder, a file name, a prompt or anything a terminal showed
/// into an event, because no event takes free text.
public enum TelemetryEvent: Equatable, Sendable {
    /// The app was opened.
    case appOpen
    /// A session was started.
    case sessionStart(agent: Agent)
    /// A phone was paired with a Mac.
    case devicePaired
    /// A conversation was handed to another agent.
    case handoff(from: Agent, to: Agent, otherFolder: Bool)
    /// The host and the app were of different versions.
    case versionMismatch(hostIsOlder: Bool)

    public enum Agent: String, Sendable, CaseIterable {
        case claude, codex, agy, copilot, shell

        /// The agent an id names; anything that is not a known agent is a shell.
        public init(id: String?) {
            self = id.flatMap(Agent.init(rawValue:)) ?? .shell
        }
    }

    public var name: String {
        switch self {
        case .appOpen: return "app_open"
        case .sessionStart: return "session_start"
        case .devicePaired: return "device_paired"
        case .handoff: return "handoff"
        case .versionMismatch: return "version_mismatch"
        }
    }

    public var parameters: [String: String] {
        switch self {
        case .appOpen, .devicePaired: return [:]
        case .sessionStart(let agent): return ["agent": agent.rawValue]
        case .handoff(let from, let to, let otherFolder):
            return ["from": from.rawValue, "to": to.rawValue, "other_folder": otherFolder ? "yes" : "no"]
        case .versionMismatch(let hostIsOlder): return ["host": hostIsOlder ? "older" : "newer"]
        }
    }
}

/// What the user has allowed. Usage statistics are on until switched off;
/// crash reports are off until the user has said yes.
public struct TelemetrySettings: Equatable, Sendable {
    public var usageStatistics: Bool
    /// Nil until the user has been asked.
    public var crashReports: Bool?

    public init(usageStatistics: Bool = true, crashReports: Bool? = nil) {
        self.usageStatistics = usageStatistics
        self.crashReports = crashReports
    }

    static let usageKey = "telemetry.usageStatistics"
    static let crashKey = "telemetry.crashReports"

    public static func load(from defaults: UserDefaults = .standard) -> TelemetrySettings {
        TelemetrySettings(
            usageStatistics: defaults.object(forKey: usageKey) as? Bool ?? true,
            crashReports: defaults.object(forKey: crashKey) as? Bool
        )
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(usageStatistics, forKey: Self.usageKey)
        if let crashReports { defaults.set(crashReports, forKey: Self.crashKey) } else { defaults.removeObject(forKey: Self.crashKey) }
    }
}

/// Where events and crash reports go. The apps plug in the service; without
/// one, as in a build from source or a development build, nothing is sent.
public protocol TelemetrySink: AnyObject {
    func setUsageStatistics(enabled: Bool)
    func setCrashReports(enabled: Bool)
    func record(_ event: TelemetryEvent)
    /// Something went wrong that is worth knowing about but did not end the
    /// app: the host died, for one. `detail` is one of a fixed set of words.
    func recordProblem(_ kind: TelemetryProblem)
}

/// Problems reported next to crashes. Like events, a closed list.
public enum TelemetryProblem: String, Sendable {
    case hostExitedUnexpectedly = "host_exited_unexpectedly"
}

/// The one place the apps report through. It holds the user's choices and
/// passes on only what they allow.
public final class Telemetry: @unchecked Sendable {
    public static let shared = Telemetry()

    private let lock = NSLock()
    private var sink: TelemetrySink?
    private var defaults: UserDefaults = .standard
    private var current = TelemetrySettings()

    public init() {}

    /// Starts reporting through `sink` with the choices saved in `defaults`.
    public func start(sink: TelemetrySink?, defaults: UserDefaults = .standard) {
        lock.lock()
        self.sink = sink
        self.defaults = defaults
        current = TelemetrySettings.load(from: defaults)
        let settings = current
        lock.unlock()
        apply(settings, to: sink)
    }

    /// The variable that has a build without a reporting service show the
    /// first-launch screen all the same (#48), to be looked at and tested:
    /// its value names the preferences the answer is kept in, which are
    /// not the app's own. Nothing is sent: there is no service to send to.
    public static let previewVariable = "AGENTTERM_REPORTING_PREVIEW"

    /// Stands in for a service, and sends nothing.
    private final class NothingSent: TelemetrySink {
        func setUsageStatistics(enabled: Bool) {}
        func setCrashReports(enabled: Bool) {}
        func record(_ event: TelemetryEvent) {}
        func recordProblem(_ kind: TelemetryProblem) {}
    }

    /// Starts as a build with a service would, with nothing behind it and
    /// preferences of its own. False when the variable is not set.
    public func startPreview(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        guard let suite = environment[Self.previewVariable], !suite.isEmpty, let defaults = UserDefaults(suiteName: suite) else { return false }
        start(sink: NothingSent(), defaults: defaults)
        return true
    }

    /// True when a service is plugged in: only then is there anything to ask
    /// the user about.
    public var isAvailable: Bool {
        lock.lock()
        defer { lock.unlock() }
        return sink != nil
    }

    public var settings: TelemetrySettings {
        get {
            lock.lock()
            defer { lock.unlock() }
            return current
        }
        set {
            lock.lock()
            current = newValue
            newValue.save(to: defaults)
            let sink = sink
            lock.unlock()
            apply(newValue, to: sink)
        }
    }

    /// True when the user has not answered the first-launch screen yet
    /// (#48) and there is a service to send anything to. Until it is
    /// answered nothing is sent, of either kind: what is saved for crash
    /// reports is what says it was answered.
    public var shouldAskAboutCrashReports: Bool { isAvailable && settings.crashReports == nil }

    public func record(_ event: TelemetryEvent) {
        lock.lock()
        let sink = current.usageStatistics && current.crashReports != nil ? sink : nil
        lock.unlock()
        sink?.record(event)
    }

    public func recordProblem(_ kind: TelemetryProblem) {
        lock.lock()
        let sink = current.crashReports == true ? sink : nil
        lock.unlock()
        sink?.recordProblem(kind)
    }

    private func apply(_ settings: TelemetrySettings, to sink: TelemetrySink?) {
        // Not before the first-launch screen was answered, on as its switch may be.
        sink?.setUsageStatistics(enabled: settings.usageStatistics && settings.crashReports != nil)
        sink?.setCrashReports(enabled: settings.crashReports == true)
    }
}
