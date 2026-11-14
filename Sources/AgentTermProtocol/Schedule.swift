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
    /// A run that comes due while the one before it is still going waits
    /// for it to end (true) or is skipped (#47).
    public var waitsForPrevious = false
    /// The longest a run may take, in minutes, after which it is stopped.
    /// Nil for as long as it takes.
    public var maxMinutes: Int?
    /// What has to be so for a run to start.
    public var condition = ScheduleCondition.always
    /// Each run in a new worktree of the folder, on a branch of its own,
    /// which is kept afterwards to be looked at (#23).
    public var inWorktree = false
    /// What was changed about it and when, newest last. The host keeps them.
    public var edits: [ScheduleEdit] = []

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
    /// How many of its changes are kept.
    public static let editsKept = 20

    /// What an earlier build saved, without what was added since, still reads.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        agent = try values.decode(String.self, forKey: .agent)
        folder = try values.decode(String.self, forKey: .folder)
        prompt = try values.decode(String.self, forKey: .prompt)
        when = try values.decode(ScheduleTime.self, forKey: .when)
        permissions = try values.decode(SchedulePermissions.self, forKey: .permissions)
        enabled = try values.decode(Bool.self, forKey: .enabled)
        catchUp = try values.decode(Bool.self, forKey: .catchUp)
        warningAccepted = try values.decode(Bool.self, forKey: .warningAccepted)
        runs = try values.decodeIfPresent([ScheduleRun].self, forKey: .runs) ?? []
        nextRun = try values.decodeIfPresent(Date.self, forKey: .nextRun)
        waitsForPrevious = try values.decodeIfPresent(Bool.self, forKey: .waitsForPrevious) ?? false
        maxMinutes = try values.decodeIfPresent(Int.self, forKey: .maxMinutes)
        condition = try values.decodeIfPresent(ScheduleCondition.self, forKey: .condition) ?? .always
        inWorktree = try values.decodeIfPresent(Bool.self, forKey: .inWorktree) ?? false
        edits = try values.decodeIfPresent([ScheduleEdit].self, forKey: .edits) ?? []
    }

    /// A copy to start another schedule from (#47): a name and an id of
    /// its own, none of the runs and changes, and turned off, so that it
    /// does not run beside the first before it was looked at.
    public func duplicate(named taken: Set<String>) -> Schedule {
        var copy = self
        copy.id = UUID().uuidString
        var name = self.name + " copy"
        var number = 2
        while taken.contains(name) {
            name = "\(self.name) copy \(number)"
            number += 1
        }
        copy.name = name
        copy.runs = []
        copy.edits = []
        copy.nextRun = nil
        copy.enabled = false
        return copy
    }

    /// What differs between this and what it was, a line for each thing,
    /// in words: what its history of changes keeps.
    public func changes(from old: Schedule) -> [String] {
        var said: [String] = []
        if old.name != name { said.append("Renamed from “\(old.name)” to “\(name)”") }
        if old.agent != agent { said.append("Agent: \(old.agent) → \(agent)") }
        if old.folder != folder { said.append("Folder: \((old.folder as NSString).lastPathComponent) → \((folder as NSString).lastPathComponent)") }
        if old.prompt != prompt { said.append("The prompt was changed") }
        if old.when != when { said.append("When: \(old.when.label()) → \(when.label())") }
        if old.permissions != permissions { said.append("Permissions: \(old.permissions.label) → \(permissions.label)") }
        if old.enabled != enabled { said.append(enabled ? "Turned on" : "Turned off") }
        if old.catchUp != catchUp { said.append(catchUp ? "A missed run is now run when the Mac is next awake" : "A missed run is now skipped") }
        if old.waitsForPrevious != waitsForPrevious { said.append(waitsForPrevious ? "A run now waits for the one before it" : "A run is now skipped while the one before it is going") }
        if old.maxMinutes != maxMinutes { said.append(maxMinutes.map { "A run is now stopped after \($0) min" } ?? "A run may now take as long as it takes") }
        if old.condition != condition { said.append("Runs: \(old.condition.label.lowercased()) → \(condition.label.lowercased())") }
        if old.inWorktree != inWorktree { said.append(inWorktree ? "Each run is now in a new worktree" : "Runs are now in the folder itself") }
        return said
    }
}

/// What has to be so for a run of a schedule to start (#47).
public enum ScheduleCondition: String, Codable, CaseIterable, Sendable {
    /// Every time it comes due.
    case always
    /// Only when the folder has changes that are not committed.
    case whenChanged
    /// Only when pulling, which is done first, brought new commits.
    case afterPull

    public var label: String {
        switch self {
        case .always: return "Every time"
        case .whenChanged: return "Only when the folder has changes"
        case .afterPull: return "Only after a pull brought new commits"
        }
    }

    /// What it does, for under the choice.
    public var advice: String {
        switch self {
        case .always: return "A run starts whenever the schedule comes due."
        case .whenChanged: return "When it comes due, the folder is looked at: with nothing changed and not committed, the run is skipped and says so."
        case .afterPull: return "When it comes due, the folder's branch is pulled on the Mac: when that brings no new commit, or fails, the run is skipped and says so."
        }
    }
}

/// One change to a schedule (#47): when, and what, in words.
public struct ScheduleEdit: Codable, Equatable, Sendable {
    public var at: Date
    public var what: [String]

    public init(at: Date, what: [String]) {
        self.at = at
        self.what = what
    }
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
    /// Every so many minutes (#47), all day from midnight, or between two
    /// times of the day given in minutes since midnight: from `from`, then
    /// every `minutes`, as long as that is not after `until`.
    case every(minutes: Int, from: Int?, until: Int?)
    /// At each of these moments.
    case dates([Date])

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
        case .every(let minutes, let from, let until):
            let step = max(minutes, 1)
            let first = min(max(from ?? 0, 0), 24 * 60 - 1)
            let last = min(max(until ?? 24 * 60 - 1, first), 24 * 60 - 1)
            // Today's and then tomorrow's: the day after has one for sure.
            for offset in 0...2 {
                guard let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: date)) else { continue }
                var minute = first
                while minute <= last {
                    if let moment = calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: day), moment > date { return moment }
                    minute += step
                }
            }
            return nil
        case .dates(let moments):
            return moments.filter { $0 > date }.min()
        }
    }

    /// "30 minutes", "2 hours", "90 minutes".
    public static func words(forMinutes minutes: Int) -> String {
        if minutes % 60 == 0 { return minutes == 60 ? "hour" : "\(minutes / 60) hours" }
        return minutes == 1 ? "minute" : "\(minutes) minutes"
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
        case .every(let minutes, let from, let until):
            let often = "Every " + Self.words(forMinutes: minutes)
            guard from != nil || until != nil else { return often }
            let first = from ?? 0, last = until ?? 24 * 60 - 1
            return "\(often), \(time(first / 60, first % 60)) to \(time(last / 60, last % 60))"
        case .dates(let moments):
            guard let first = moments.sorted().first else { return "On no date" }
            let when = first.formatted(date: .abbreviated, time: .shortened)
            return moments.count == 1 ? "On \(when)" : "On \(moments.count) dates, from \(when)"
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
    /// When it was over: its agent done, its session ended, or it was
    /// stopped (#47). Nil while it goes on, and for one that never started.
    public var ended: Date?
    /// How it ended, in words: "Done", "Stopped by you", "Stopped: it ran
    /// longer than 30 min", "Its session ended".
    public var outcome: String?
    /// What it changed in git, in words; nil when its folder is no
    /// repository or nothing can be said.
    public var changes: String?
    /// The worktree it ran in, when it ran in one of its own.
    public var worktree: String?
    /// Whether what it printed was kept, to be asked for.
    public var hasOutput = false

    public init(at: Date, started: Bool, session: SessionID? = nil, note: String) {
        self.at = at
        self.started = started
        self.session = session
        self.note = note
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        at = try values.decode(Date.self, forKey: .at)
        started = try values.decode(Bool.self, forKey: .started)
        session = try values.decodeIfPresent(SessionID.self, forKey: .session)
        note = try values.decode(String.self, forKey: .note)
        ended = try values.decodeIfPresent(Date.self, forKey: .ended)
        outcome = try values.decodeIfPresent(String.self, forKey: .outcome)
        changes = try values.decodeIfPresent(String.self, forKey: .changes)
        worktree = try values.decodeIfPresent(String.self, forKey: .worktree)
        hasOutput = try values.decodeIfPresent(Bool.self, forKey: .hasOutput) ?? false
    }

    /// How long it took, once it is over.
    public var duration: TimeInterval? { ended.map { max($0.timeIntervalSince(at), 0) } }

    /// What is said of it in a list: its note, and once it is over how it
    /// ended and how long it took.
    public var summary: String {
        guard started, let outcome else { return note }
        let took = duration.map { ", after " + ConversationDetails.words(for: $0) } ?? ""
        return outcome + took
    }
}

/// The schedules in three groups, as both apps' Schedules show them: the
/// runs whose session still runs, every schedule by when it runs next, and
/// the runs that are over, newest first.
public struct ScheduleOverview: Sendable {
    /// One run of a schedule.
    public struct Run: Identifiable, Sendable {
        public let schedule: Schedule
        public let run: ScheduleRun
        public init(schedule: Schedule, run: ScheduleRun) {
            self.schedule = schedule
            self.run = run
        }
        public var id: String { Self.id(schedule: schedule.id, at: run.at) }
        /// How a run is named: by its schedule and when it came due.
        public static func id(schedule: String, at: Date) -> String { schedule + "@" + String(at.timeIntervalSince1970) }
    }

    public let running: [Run]
    /// The next to run first, then those with no time to run at (one waiting
    /// for a limit to start over), then those turned off; each by name.
    public let scheduled: [Schedule]
    public let past: [Run]

    /// - Parameter liveSessions: The sessions that still run.
    public init(schedules: [Schedule], liveSessions: Set<SessionID>) {
        let runs = schedules.flatMap { schedule in schedule.runs.map { Run(schedule: schedule, run: $0) } }
            .sorted { $0.run.at > $1.run.at }
        func live(_ run: Run) -> Bool { run.run.started && run.run.session.map(liveSessions.contains) == true }
        running = runs.filter(live)
        past = runs.filter { !live($0) }
        scheduled = schedules.sorted { a, b in
            func rank(_ schedule: Schedule) -> Int { !schedule.enabled ? 2 : schedule.nextRun == nil ? 1 : 0 }
            if rank(a) != rank(b) { return rank(a) < rank(b) }
            if let first = a.nextRun, let second = b.nextRun, first != second { return first < second }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }
}
