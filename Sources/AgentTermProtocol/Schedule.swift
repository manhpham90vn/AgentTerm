import Foundation

/// An agent started with a prompt in a folder at a set time, or on a
/// repeating schedule, or when an account's limit starts over (#11). The
/// host keeps the schedules and runs them; both apps make and change them.
public struct Schedule: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    /// What its runs' sessions are called.
    public var name: String
    /// The agent's id: "claude", "codex", "agy", "copilot".
    public var agent: String
    public var folder: String
    /// What the agent is started with.
    public var prompt: String
    public var when: ScheduleTime
    public var permissions: SchedulePermissions
    /// Off keeps it without running it.
    public var enabled: Bool
    /// A run that was missed, the Mac asleep or off: run once when it is
    /// next awake (true), or skip it.
    public var catchUp: Bool
    /// The user was shown, and accepted, what a run that asks for nothing
    /// may do on this Mac. A schedule that skips permissions is not saved
    /// without it.
    public var warningAccepted: Bool
    /// Its last runs, newest last. The host keeps them.
    public var runs: [ScheduleRun]
    /// When it runs next, as the host works it out. Nil when it will not.
    public var nextRun: Date?

    public init(
        id: String = UUID().uuidString, name: String, agent: String, folder: String, prompt: String, when: ScheduleTime,
        permissions: SchedulePermissions = .skipAll, enabled: Bool = true, catchUp: Bool = true, warningAccepted: Bool = false,
        runs: [ScheduleRun] = [], nextRun: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.agent = agent
        self.folder = folder
        self.prompt = prompt
        self.when = when
        self.permissions = permissions
        self.enabled = enabled
        self.catchUp = catchUp
        self.warningAccepted = warningAccepted
        self.runs = runs
        self.nextRun = nextRun
    }

    /// How many runs are kept.
    public static let runsKept = 20
}

public enum ScheduleTime: Codable, Equatable, Hashable, Sendable {
    /// Once, at that moment.
    case once(Date)
    /// Every day at that hour and minute, the Mac's own time.
    case daily(hour: Int, minute: Int)
    /// On those weekdays (1 Sunday to 7 Saturday) at that hour and minute.
    case weekly(weekdays: [Int], hour: Int, minute: Int)
    /// A little after the agent's account limit starts over.
    case limitReset

    /// The first moment after `date` it is due, nil for `limitReset`, which
    /// depends on the account, and for a moment that has passed.
    public func next(after date: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .once(let moment):
            return moment > date ? moment : nil
        case .daily(let hour, let minute):
            return calendar.nextDate(after: date, matching: DateComponents(hour: hour, minute: minute), matchingPolicy: .nextTime)
        case .weekly(let weekdays, let hour, let minute):
            return weekdays.compactMap {
                calendar.nextDate(after: date, matching: DateComponents(hour: hour, minute: minute, weekday: $0), matchingPolicy: .nextTime)
            }.min()
        case .limitReset:
            return nil
        }
    }

    /// In words: "Every day at 09:00", "Mon, Wed at 18:30".
    public func label(calendar: Calendar = .current) -> String {
        func time(_ hour: Int, _ minute: Int) -> String { String(format: "%02d:%02d", hour, minute) }
        switch self {
        case .once(let moment): return "Once, \(moment.formatted(date: .abbreviated, time: .shortened))"
        case .daily(let hour, let minute): return "Every day at \(time(hour, minute))"
        case .weekly(let weekdays, let hour, let minute):
            let names = weekdays.sorted().map { calendar.shortWeekdaySymbols[($0 - 1 + 7) % 7] }
            return "\(names.joined(separator: ", ")) at \(time(hour, minute))"
        case .limitReset: return "When the account's limit starts over"
        }
    }
}

/// How the agent of a run handles what it would ask permission for.
public enum SchedulePermissions: String, Codable, CaseIterable, Sendable {
    /// Does what it decides to without asking: runs any command, changes
    /// any file. Nobody is there to answer: the default for a schedule.
    case skipAll
    /// Changes files without asking, asks before running commands.
    case acceptEdits
    /// Asks as in a session started by hand, and waits.
    case ask

    public var label: String {
        switch self {
        case .skipAll: return "Skip all permissions"
        case .acceptEdits: return "Accept edits"
        case .ask: return "Ask"
        }
    }

    /// The modes an agent offers: Codex has no switch for accepting edits.
    public static func offered(by agent: String) -> [SchedulePermissions] {
        agent == "codex" ? [.skipAll, .ask] : allCases
    }

    /// What a run in this mode may do on the Mac, in words, shown before a
    /// schedule is saved with it.
    public static func warning(agent: String, name: String) -> String {
        var text =
            "Each run of this schedule starts \(name) and lets it do whatever it decides to on this Mac without asking you: run any command, change or delete any file your user account can reach, use the network, and spend the account's limits. Nobody will be there to stop it."
        text += " So that nothing waits for you, AgentTerm also trusts the folder for \(name)"
        switch agent {
        case "codex": text += ", and runs AgentTerm's hooks and any other hooks Codex finds without asking you to trust them, those of the project's repository too."
        case "claude": text += ", writing that it is trusted into Claude Code's own settings."
        default: text += "."
        }
        return text
    }
}

/// One time a schedule came due.
public struct ScheduleRun: Codable, Equatable, Sendable {
    public var at: Date
    /// A session was started for it.
    public var started: Bool
    public var session: SessionID?
    /// What came of it, in words: "Started", "Skipped: the run before it is
    /// still going", "Missed while the Mac was asleep".
    public var note: String

    public init(at: Date, started: Bool, session: SessionID? = nil, note: String) {
        self.at = at
        self.started = started
        self.session = session
        self.note = note
    }
}
