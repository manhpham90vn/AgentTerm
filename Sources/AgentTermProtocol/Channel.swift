import Foundation

/// Which build of AgentTerm this is.
///
/// A released build (the one from the GitHub release or TestFlight) and a
/// build made on a developer's own machine live side by side: each has its
/// own name, bundle identifier, data folder, port and pairing link scheme,
/// so trying a change never touches the installed app's sessions or
/// paired devices.
///
/// The channel is read from the bundle the code runs in. Only a bundle with
/// the released identifier is the release; everything else, a bare
/// `swift run` and the test runner included, is a development build.
public enum AppChannel: String, Sendable {
    case release
    case dev

    public static let releaseBundleIdentifier = "com.manhpham.agentterm"

    public static let current: AppChannel = Bundle.main.bundleIdentifier == releaseBundleIdentifier ? .release : .dev

    public var bundleIdentifier: String { self == .release ? Self.releaseBundleIdentifier : Self.releaseBundleIdentifier + ".dev" }

    /// "AgentTerm", or "AgentTerm Dev". Also the name of the data folder.
    public var appName: String { self == .release ? "AgentTerm" : "AgentTerm Dev" }

    /// The port the host listens on unless told otherwise.
    public var defaultPort: UInt16 { self == .release ? 7717 : 7718 }

    /// Scheme of the pairing link this build shows and opens.
    public var linkScheme: String { self == .release ? "agentterm" : "agentterm-dev" }

    public static let linkSchemes: Set<String> = [AppChannel.release.linkScheme, AppChannel.dev.linkScheme]
}

/// The version of the app that is running, as its bundle states it. Every
/// build takes it from the `VERSION` file at the root of the repository.
public enum AppVersion {
    /// "0.2.0", or "dev" for a program run outside an app bundle.
    public static var current: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev"
    }

    /// "AgentTerm 0.2.0".
    public static var label: String { "\(AppChannel.current.appName) \(current)" }
}
