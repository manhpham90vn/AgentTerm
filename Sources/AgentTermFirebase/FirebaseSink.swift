import AgentTermProtocol
import AgentTermTelemetry
import FirebaseAnalytics
import FirebaseCore
import FirebaseCrashlytics
import Foundation

/// Sends what `Telemetry` lets through to Firebase: events to Analytics,
/// crashes and problems to Crashlytics.
///
/// It exists only in a released build that was given a Firebase config
/// file. A build from source has none and a development build never uses
/// one, so those send nothing.
public final class FirebaseSink: TelemetrySink {
    /// The config file, in the app's bundle when the build was given one.
    public static var bundledConfig: String? {
        Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist")
    }

    /// Starts Firebase and returns the sink, or nil when this build is not
    /// to report anything.
    public static func make(channel: AppChannel = .current, configFile: String? = bundledConfig) -> FirebaseSink? {
        guard channel == .release, let configFile, let options = FirebaseOptions(contentsOfFile: configFile) else { return nil }
        FirebaseApp.configure(options: options)
        guard FirebaseApp.app() != nil else { return nil }
        return FirebaseSink()
    }

    /// Starts reporting, if this build can. Call it once, as the app starts.
    public static func start() {
        Telemetry.shared.start(sink: make())
    }

    private init() {}

    public func setUsageStatistics(enabled: Bool) {
        Analytics.setAnalyticsCollectionEnabled(enabled)
    }

    public func setCrashReports(enabled: Bool) {
        Crashlytics.crashlytics().setCrashlyticsCollectionEnabled(enabled)
    }

    public func record(_ event: TelemetryEvent) {
        Analytics.logEvent(event.name, parameters: event.parameters)
    }

    public func recordProblem(_ kind: TelemetryProblem) {
        let error = NSError(domain: "AgentTerm", code: 1, userInfo: [NSLocalizedDescriptionKey: kind.rawValue])
        Crashlytics.crashlytics().record(error: error)
    }
}
