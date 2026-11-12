import Combine
import Foundation

/// The user's choices about reporting, for a settings screen to show and change.
public final class TelemetryPreferences: ObservableObject {
    private let telemetry: Telemetry

    /// False in a build that has no reporting service: a build from source,
    /// or a development build. Nothing is sent then, whatever the switches say.
    @Published public private(set) var isAvailable: Bool
    /// True until the user has answered the question about crash reports.
    @Published public var needsAsking: Bool

    @Published public var usageStatistics: Bool {
        didSet { if usageStatistics != oldValue { telemetry.settings.usageStatistics = usageStatistics } }
    }

    @Published public var crashReports: Bool {
        didSet {
            guard crashReports != oldValue else { return }
            telemetry.settings.crashReports = crashReports
            needsAsking = false
        }
    }

    public init(telemetry: Telemetry = .shared) {
        self.telemetry = telemetry
        let settings = telemetry.settings
        isAvailable = telemetry.isAvailable
        needsAsking = telemetry.shouldAskAboutCrashReports
        usageStatistics = settings.usageStatistics
        crashReports = settings.crashReports == true
    }

    /// The answer to the question asked once, at the first launch.
    public func answer(sendCrashReports: Bool) {
        telemetry.settings.crashReports = sendCrashReports
        if crashReports != sendCrashReports { crashReports = sendCrashReports }
        needsAsking = false
    }

    /// What the question and the settings say about each kind of report.
    public enum Wording {
        public static let question = "Send crash reports?"
        public static let questionDetail =
            "When AgentTerm crashes, a report can be sent to its developer through Google's Firebase: where in the app it happened, the app's version and your device's model and system. Never what your terminals show, your prompts, file names or folders."
        public static let usageDetail =
            "Counts of what is used: the app being opened and for how long, a session being started and with which agent, pairing, handoff. No text you type or see, no file or folder names. Sent through Google's Firebase."
        public static let unavailable =
            "This build has no reporting service, so it sends nothing, whatever these switches say. That is the case for a build from source and for AgentTerm Dev."
    }
}
