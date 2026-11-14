import Foundation

// Settings the host keeps, so the Mac and the iPhone show and change the same.

/// How the Mac is kept awake while sessions are running.
public struct KeepAwakeOptions: Codable, Equatable, Sendable {
    /// Keep the display on too, not only the Mac.
    public var display: Bool
    /// Only while the Mac is plugged in.
    public var onlyOnPower: Bool
    /// How long a switch-on lasts, in minutes. Nil: until it is turned off.
    public var minutes: Int?
    /// When the hold that is on now ends. The host sets it.
    public var until: Date?
    /// Only while an agent is working (#7): a shell, an agent that waits or
    /// is done, holds nothing.
    public var onlyWhileWorking: Bool

    public init(display: Bool = false, onlyOnPower: Bool = false, minutes: Int? = nil, until: Date? = nil, onlyWhileWorking: Bool = false) {
        self.display = display
        self.onlyOnPower = onlyOnPower
        self.minutes = minutes
        self.until = until
        self.onlyWhileWorking = onlyWhileWorking
    }

    private enum CodingKeys: String, CodingKey { case display, onlyOnPower, minutes, until, onlyWhileWorking }

    /// Settings saved before an option was added read with it off.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        display = try container.decodeIfPresent(Bool.self, forKey: .display) ?? false
        onlyOnPower = try container.decodeIfPresent(Bool.self, forKey: .onlyOnPower) ?? false
        minutes = try container.decodeIfPresent(Int.self, forKey: .minutes)
        until = try container.decodeIfPresent(Date.self, forKey: .until)
        onlyWhileWorking = try container.decodeIfPresent(Bool.self, forKey: .onlyWhileWorking) ?? false
    }

    /// The lengths offered: until turned off, one hour, two, four, eight.
    public static let durations: [Int?] = [nil, 60, 120, 240, 480]

    /// "Until turned off", "1 hour", "2 hours", "45 minutes".
    public static func label(minutes: Int?) -> String {
        guard let minutes else { return "Until turned off" }
        if minutes % 60 == 0 { return minutes == 60 ? "1 hour" : "\(minutes / 60) hours" }
        return "\(minutes) minutes"
    }
}

/// Which agent writes commit messages, and how it is asked.
public struct CommitWriterSettings: Codable, Equatable, Sendable {
    /// Agent id. Nil: the first one installed.
    public var agent: String?
    /// Model for that agent, as its `--model` takes it. Nil or empty: a
    /// cheap one where AgentTerm knows one, else the agent's own default.
    public var model: String?
    /// What the agent is told, before the staged changes. Nil: the default.
    public var prompt: String?

    public init(agent: String? = nil, model: String? = nil, prompt: String? = nil) {
        self.agent = agent
        self.model = model
        self.prompt = prompt
    }

    /// What the agent is told unless the user wrote something else.
    public static let defaultPrompt = """
        Write a git commit message for the staged changes below.

        - Follow Conventional Commits: a type (feat, fix, docs, refactor, test, chore, ...), an optional scope, then a short summary in the imperative, under 72 characters.
        - Add a body only when the summary cannot say why the change was made. Wrap it at 72 characters.
        - Write in English.
        - Reply with the commit message only: no explanation, no quotes, no code fence.
        """

    /// The agent that writes: the one chosen, or the first one installed
    /// when none is chosen or the chosen one is no longer installed. The
    /// host and both apps ask here, so the button says who will write.
    public func writer(among agents: [AgentInfo]) -> AgentInfo? {
        let installed = agents.filter(\.isInstalled)
        return agent.flatMap { id in installed.first { $0.id == id } } ?? installed.first
    }

    /// The prompt in effect.
    public var effectivePrompt: String {
        let own = prompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return own.isEmpty ? Self.defaultPrompt : own
    }

    /// The model AgentTerm picks for an agent when none is set: a cheap one,
    /// since a commit message is a small job. Nil where no name is known to
    /// stay valid, which leaves the agent on its own default.
    public static func defaultModel(for agent: String) -> String? {
        agent == "claude" ? "haiku" : nil
    }
}

/// How the Mac itself is doing: what a glance at a system monitor tells.
/// The host measures it every few seconds and sends it to every client.
public struct SystemStats: Codable, Equatable, Sendable {
    /// Processor in use across all cores, from 0 to 100.
    public var cpuPercent: Double
    /// Memory in use and installed, in bytes.
    public var memoryUsed: UInt64
    public var memoryTotal: UInt64
    /// Bytes a second coming in and going out, over every network interface.
    public var downBytesPerSecond: UInt64
    public var upBytesPerSecond: UInt64
    /// The hottest processor sensor, in degrees Celsius. Nil on a Mac that
    /// does not report one.
    public var temperature: Double?
    /// How hot macOS itself says the Mac is: "nominal", "fair", "serious"
    /// or "critical".
    public var thermalState: String
    /// Charge from 0 to 100. Nil on a Mac without a battery.
    public var batteryPercent: Int?
    public var isCharging: Bool
    public var isOnPower: Bool
    /// When the Mac was started.
    public var bootedAt: Date

    public init(
        cpuPercent: Double = 0, memoryUsed: UInt64 = 0, memoryTotal: UInt64 = 0, downBytesPerSecond: UInt64 = 0,
        upBytesPerSecond: UInt64 = 0, temperature: Double? = nil, thermalState: String = "nominal", batteryPercent: Int? = nil,
        isCharging: Bool = false, isOnPower: Bool = true, bootedAt: Date = Date()
    ) {
        self.cpuPercent = cpuPercent
        self.memoryUsed = memoryUsed
        self.memoryTotal = memoryTotal
        self.downBytesPerSecond = downBytesPerSecond
        self.upBytesPerSecond = upBytesPerSecond
        self.temperature = temperature
        self.thermalState = thermalState
        self.batteryPercent = batteryPercent
        self.isCharging = isCharging
        self.isOnPower = isOnPower
        self.bootedAt = bootedAt
    }

    /// Share of the memory in use, from 0 to 100.
    public var memoryPercent: Double { memoryTotal > 0 ? Double(memoryUsed) / Double(memoryTotal) * 100 : 0 }

    /// "12.4 / 32 GB".
    public var memoryText: String {
        String(format: "%.1f / %.0f GB", Double(memoryUsed) / 1_073_741_824, Double(memoryTotal) / 1_073_741_824)
    }

    /// The same without the unit said twice, for a narrow place: "12.4/32 GB".
    public var memoryShortText: String {
        String(format: "%.1f/%.0f GB", Double(memoryUsed) / 1_073_741_824, Double(memoryTotal) / 1_073_741_824)
    }

    /// "0 KB/s", "840 KB/s", "12.3 MB/s".
    public static func speed(_ bytesPerSecond: UInt64) -> String {
        let kilobytes = Double(bytesPerSecond) / 1024
        if kilobytes >= 1000 { return String(format: "%.1f MB/s", kilobytes / 1024) }
        return "\(Int(kilobytes.rounded())) KB/s"
    }

    /// The key both apps keep the choice of unit under, and its two values.
    public static let temperatureUnitKey = "temperatureUnit"
    public static let celsius = "celsius"
    public static let fahrenheit = "fahrenheit"

    /// "54°C", or what macOS says when no sensor is read: "Normal", "Warm", "Hot", "Very hot".
    public var temperatureText: String { temperatureText(unit: Self.celsius) }

    /// The same in the unit chosen: "54°C" or "129°F". The host always
    /// measures in Celsius; the unit is how an app shows it.
    public func temperatureText(unit: String) -> String {
        if let temperature {
            return unit == Self.fahrenheit ? "\(Int((temperature * 9 / 5 + 32).rounded()))°F" : "\(Int(temperature.rounded()))°C"
        }
        switch thermalState {
        case "fair": return "Warm"
        case "serious": return "Hot"
        case "critical": return "Very hot"
        default: return "Normal"
        }
    }

    /// True when the Mac is hot enough to slow itself down.
    public var isHot: Bool { thermalState == "serious" || thermalState == "critical" || (temperature ?? 0) >= 95 }

    /// "3d 4h", "5h 12m", "8m".
    public static func uptime(since bootedAt: Date, now: Date = Date()) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(bootedAt)) / 60)
        if minutes >= 1440 { return "\(minutes / 1440)d \(minutes % 1440 / 60)h" }
        if minutes >= 60 { return "\(minutes / 60)h \(minutes % 60)m" }
        return "\(minutes)m"
    }
}

/// How things are shown, chosen once and the same on the Mac and on every
/// phone: the host keeps it and passes a change on. Each app also keeps
/// the values in its own preferences, under the keys named here, which is
/// what its views read.
public struct DisplaySettings: Codable, Equatable, Sendable {
    /// `SystemStats.celsius` or `SystemStats.fahrenheit`.
    public var temperatureUnit: String
    /// "unified" shows a diff in one panel, "split" in two, side by side.
    public var diffLayout: String
    /// "list" shows a folder's changes as a flat list, "tree" grouped by folder.
    public var changesView: String
    /// The remotes of the folder that is shown are asked for what is new
    /// every few minutes, so that how far ahead and behind its branch is
    /// stays true without anyone asking (#37). On unless turned off.
    public var fetchAutomatically: Bool

    public static let diffLayoutKey = "diffLayout"
    public static let changesViewKey = "diffViewMode"
    public static let fetchAutomaticallyKey = "fetchAutomatically"
    /// How long between two fetches no one asked for.
    public static let fetchInterval: TimeInterval = 5 * 60

    public init(
        temperatureUnit: String = SystemStats.celsius, diffLayout: String = "unified", changesView: String = "list", fetchAutomatically: Bool = true
    ) {
        self.temperatureUnit = temperatureUnit
        self.diffLayout = diffLayout
        self.changesView = changesView
        self.fetchAutomatically = fetchAutomatically
    }

    /// A setting a later version adds is not in what an earlier one saved.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        temperatureUnit = try values.decodeIfPresent(String.self, forKey: .temperatureUnit) ?? SystemStats.celsius
        diffLayout = try values.decodeIfPresent(String.self, forKey: .diffLayout) ?? "unified"
        changesView = try values.decodeIfPresent(String.self, forKey: .changesView) ?? "list"
        fetchAutomatically = try values.decodeIfPresent(Bool.self, forKey: .fetchAutomatically) ?? true
    }

    /// Only values the apps know how to show.
    public var checked: DisplaySettings {
        DisplaySettings(
            temperatureUnit: temperatureUnit == SystemStats.fahrenheit ? SystemStats.fahrenheit : SystemStats.celsius,
            diffLayout: diffLayout == "split" ? "split" : "unified", changesView: changesView == "tree" ? "tree" : "list",
            fetchAutomatically: fetchAutomatically)
    }

    /// What an app's own preferences hold.
    public static func stored(in defaults: UserDefaults = .standard) -> DisplaySettings {
        DisplaySettings(
            temperatureUnit: defaults.string(forKey: SystemStats.temperatureUnitKey) ?? SystemStats.celsius,
            diffLayout: defaults.string(forKey: diffLayoutKey) ?? "unified", changesView: defaults.string(forKey: changesViewKey) ?? "list",
            fetchAutomatically: defaults.object(forKey: fetchAutomaticallyKey) as? Bool ?? true
        ).checked
    }

    /// Writes them to an app's own preferences, where its views read them.
    public func store(in defaults: UserDefaults = .standard) {
        defaults.set(temperatureUnit, forKey: SystemStats.temperatureUnitKey)
        defaults.set(diffLayout, forKey: Self.diffLayoutKey)
        defaults.set(changesView, forKey: Self.changesViewKey)
        defaults.set(fetchAutomatically, forKey: Self.fetchAutomaticallyKey)
    }
}
