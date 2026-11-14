import Combine
import Foundation

/// The user's choices about reporting, for a settings screen to show and change.
public final class TelemetryPreferences: ObservableObject {
    private let telemetry: Telemetry

    /// False in a build that has no reporting service: a build from source,
    /// or a development build. Nothing is sent then, whatever the switches say.
    @Published public private(set) var isAvailable: Bool
    /// True until the user has answered the first-launch screen.
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

    /// What the first-launch screen's two switches say while it is shown
    /// (#48): both on, until the user turns one off. Nothing is sent, and
    /// nothing is saved, before the screen is answered.
    @Published public var offersCrashReports = true
    @Published public var offersUsageStatistics = true

    /// The first-launch screen is answered: what its two switches say is
    /// saved, and sending starts for what is on.
    public func answer() {
        telemetry.settings = TelemetrySettings(usageStatistics: offersUsageStatistics, crashReports: offersCrashReports)
        usageStatistics = offersUsageStatistics
        crashReports = offersCrashReports
        needsAsking = false
    }

    /// What the question and the settings say about each kind of report.
    public enum Wording {
        /// The first-launch screen (#48): the app's own, with a switch for
        /// each kind of report, both on, and one button.
        public static let screenTitle = "What AgentTerm May Send to Its Developer"
        public static let screenIntro =
            "Two kinds of reports help make AgentTerm better. Each has a switch: leave on what you agree to, turn off what you do not, then continue. Nothing is sent before you do. Your terminals, prompts and files are never part of either."
        public static let crashTitle = "Send crash reports"
        public static let usageTitle = "Share usage statistics"
        public static let screenFooter = "You can change both at any time in the app's Settings, under Privacy."
        public static let screenButton = "Continue"
        public static let questionDetail =
            "When AgentTerm crashes, a report can be sent to its developer through Google's Firebase: where in the app it happened, the app's version and your device's model and system. Never what your terminals show, your prompts, file names or folders."
        public static let usageDetail =
            "Counts of what is used: the app being opened and for how long, a session being started and with which agent, pairing, handoff. No text you type or see, no file or folder names. Sent through Google's Firebase."
        public static let unavailable =
            "This build has no reporting service, so it sends nothing, whatever these switches say. That is the case for a build from source and for AgentTerm Dev."
    }
}
