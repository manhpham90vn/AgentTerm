import Foundation

/// A part of AgentTerm that stopped without being asked to: the host itself
/// today, and later the status line relay, the keep-awake hold or the
/// program of a session. The host tells every client of one with `failures`,
/// also a client that connects later, until the user has seen it on one of
/// them (`dismissFailure`).
///
/// A stop that was asked for (Restart Host, replacing another copy's host,
/// SIGTERM, logging out) is not a failure and is never reported.
public struct PartFailure: Codable, Equatable, Identifiable, Sendable {
    /// Which part stopped. Text rather than a closed list, so that a client
    /// still reads a failure of a part that was added after it was built.
    public struct Part: RawRepresentable, Codable, Hashable, Sendable {
        public var rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }

        /// The host, `agenttermd`, which holds every session.
        public static let host = Part(rawValue: "host")
        /// The program of a session (`name`), killed or crashed rather than
        /// ended. It is not started again: its session ends with it.
        public static let session = Part(rawValue: "session")
        /// The hold that keeps the Mac awake: macOS would not give it.
        public static let keepAwake = Part(rawValue: "keepAwake")
        /// What Claude Code tells its status line, which the host reads for
        /// the usage of a session (`name`): it could not be saved.
        public static let statusLine = Part(rawValue: "statusLine")
        /// A run of a schedule (`name`) that did not start, or was stopped
        /// (#47): `reason` says which and why.
        public static let schedule = Part(rawValue: "schedule")
    }

    /// Names this report, for `dismissFailure`.
    public var id: String
    public var part: Part
    /// Which one, for a part there are several of: the session, for a
    /// session's program. Nil for the host.
    public var name: String?
    /// When it stopped, as near as is known.
    public var at: Date
    /// The sessions that ended with it, as they were named then.
    public var ended: [EndedSession]
    /// Whether it was started again by itself.
    public var restarted: Bool
    /// It stopped too often in a short time (three times in sixty seconds),
    /// and is not started again by itself until the user asks.
    public var broken: Bool
    /// Why it stopped, or why starting it again failed, in words for the
    /// user. Nil when that is not known.
    public var reason: String?

    public init(
        id: String = UUID().uuidString, part: Part, name: String? = nil, at: Date, ended: [EndedSession] = [], restarted: Bool, broken: Bool = false,
        reason: String? = nil
    ) {
        self.id = id
        self.part = part
        self.name = name
        self.at = at
        self.ended = ended
        self.restarted = restarted
        self.broken = broken
        self.reason = reason
    }
}

/// A session that ended because a part it needed stopped.
public struct EndedSession: Codable, Equatable, Hashable, Sendable {
    /// What it was called in the lists: its summary, else its title.
    public var name: String
    /// The folder it ran in.
    public var cwd: String
    /// The agent it ran, nil for a shell or any other program.
    public var agent: String?

    public init(name: String, cwd: String, agent: String? = nil) {
        self.name = name
        self.cwd = cwd
        self.agent = agent
    }

    public init(_ session: SessionInfo) {
        self.init(name: session.displayName, cwd: session.cwd, agent: session.agent)
    }
}

// MARK: In words

extension PartFailure {
    /// What stopped and what became of it, in one sentence, the same on the
    /// Mac and on the iPhone. `mac` names the Mac the host is on when it is
    /// not the one the app runs on.
    public func headline(on mac: String? = nil, now: Date = Date()) -> String {
        let when = Self.when(at, now: now)
        let onMac = mac.map { " on \($0)" } ?? ""
        let named = name.map { "“\($0)”" } ?? "a session"
        let what: String
        switch part {
        case .host:
            what = mac.map { "The host on \($0)" } ?? "The AgentTerm host"
        case .session:
            return "The program of \(named)\(onMac) stopped unexpectedly \(when)."
        case .keepAwake:
            return "The Mac\(onMac) could not be kept awake \(when)" + (restarted ? ", and is kept awake again." : ".")
        case .statusLine:
            return "The usage of \(named)\(onMac) could not be saved \(when)."
        case .schedule:
            return "A run of the schedule \(named)\(onMac) did not go as planned \(when)."
        default:
            // A part this build does not know yet.
            what = "A part of AgentTerm (\(part.rawValue)\(name.map { ", \($0)" } ?? ""))\(mac.map { " on \($0)" } ?? "")"
        }
        let outcome =
            broken
            ? "and keeps stopping, so it is not started again by itself."
            : restarted ? "and was started again." : "and could not be started again."
        return "\(what) stopped unexpectedly \(when) \(outcome)"
    }

    /// What ended with it, and why it stopped when that is known.
    public var details: String {
        var parts: [String] = []
        switch part {
        case .keepAwake, .statusLine, .schedule:
            // Nothing ends with these: what they are for stops.
            break
        case .session:
            parts.append("Its session ended.")
        default:
            switch ended.count {
            case 0: parts.append("No session was running in it.")
            case 1: parts.append("Its session ended: \(ended[0].name).")
            default: parts.append("Its \(ended.count) sessions ended: \(ended.map(\.name).joined(separator: ", ")).")
            }
        }
        if let reason, !reason.isEmpty { parts.append(reason) }
        return parts.joined(separator: " ")
    }

    /// "at 14:02" today, "on 12 Nov at 14:02" before.
    static func when(_ date: Date, now: Date) -> String {
        let time = DateFormatter()
        time.dateStyle = .none
        time.timeStyle = .short
        guard !Calendar.current.isDate(date, inSameDayAs: now) else { return "at \(time.string(from: date))" }
        let day = DateFormatter()
        day.setLocalizedDateFormatFromTemplate("dMMM")
        return "on \(day.string(from: date)) at \(time.string(from: date))"
    }
}
