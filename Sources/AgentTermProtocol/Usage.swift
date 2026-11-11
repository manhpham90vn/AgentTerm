import Foundation

/// How much of a limit the account has used, as the agent reports it.
public struct UsageLimit: Codable, Equatable, Sendable {
    /// Minutes the limit is counted over: 300 for five hours, 10080 for a week.
    public var windowMinutes: Int
    public var usedPercent: Double
    public var resetsAt: Date?

    public init(windowMinutes: Int, usedPercent: Double, resetsAt: Date?) {
        self.windowMinutes = windowMinutes
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }

    /// "5h", "Week", "3d".
    public var label: String {
        switch windowMinutes {
        case 10080: return "Week"
        case let minutes where minutes % 1440 == 0 && minutes > 0: return "\(minutes / 1440)d"
        case let minutes where minutes % 60 == 0 && minutes > 0: return "\(minutes / 60)h"
        default: return "\(windowMinutes)m"
        }
    }
}

/// What an agent session has used, read from the agent's own records of the
/// conversation. Each agent records different things; what one does not
/// record is nil.
public struct SessionUsage: Codable, Equatable, Sendable {
    public var model: String?
    /// Tokens the conversation takes up in the model's context now.
    public var contextTokens: Int?
    /// How many the model can take.
    public var contextWindow: Int?
    public var limits: [UsageLimit]
    /// Premium requests the session has spent (Copilot).
    public var premiumRequests: Double?

    public init(
        model: String? = nil, contextTokens: Int? = nil, contextWindow: Int? = nil,
        limits: [UsageLimit] = [], premiumRequests: Double? = nil
    ) {
        self.model = model
        self.contextTokens = contextTokens
        self.contextWindow = contextWindow
        self.limits = limits
        self.premiumRequests = premiumRequests
    }

    public var isEmpty: Bool { model == nil && contextTokens == nil && limits.isEmpty && premiumRequests == nil }

    /// Share of the context in use, from 0 to 1, when the window is known.
    public var contextFraction: Double? {
        guard let contextTokens, let contextWindow, contextWindow > 0 else { return nil }
        return min(1, Double(contextTokens) / Double(contextWindow))
    }

    /// "236K", "1.2M", "850".
    public static func short(_ tokens: Int) -> String {
        switch tokens {
        case 1_000_000...: return String(format: "%.1fM", Double(tokens) / 1_000_000)
        case 10_000...: return "\(Int((Double(tokens) / 1000).rounded()))K"
        case 1000...: return String(format: "%.1fK", Double(tokens) / 1000)
        default: return "\(tokens)"
        }
    }
}

/// One limit of an agent's account, as the agent's own usage screen lists it.
public struct AccountLimit: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    /// "Current week (all models)", "5h limit".
    public var title: String
    /// The same in a word or two, for a line with little room: "Week", "5h".
    public var shortTitle: String
    public var usedPercent: Double
    public var resetsAt: Date?
    /// Said beside the percentage, such as "1477 of 1500 left".
    public var detail: String?

    public init(id: String, title: String, shortTitle: String, usedPercent: Double, resetsAt: Date? = nil, detail: String? = nil) {
        self.id = id
        self.title = title
        self.shortTitle = shortTitle
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.detail = detail
    }

    public var leftPercent: Double { max(0, 100 - usedPercent) }
}

/// Limits that belong together, such as those of one family of models.
public struct AccountUsageGroup: Codable, Equatable, Sendable {
    public var title: String?
    public var note: String?
    public var limits: [AccountLimit]

    public init(title: String? = nil, note: String? = nil, limits: [AccountLimit]) {
        self.title = title
        self.note = note
        self.limits = limits
    }
}

/// A fact about the account that is not a limit: "Reset credits", "2 available".
public struct AccountUsageNote: Codable, Equatable, Sendable {
    public var label: String
    public var value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

/// What an agent's account has used and has left, as the agent's service
/// reports it: what `/usage` shows in Claude Code and `/status` in Codex.
public struct AccountUsage: Codable, Equatable, Identifiable, Sendable {
    public var agent: String
    /// "Max 5x", "Plus", "Google AI Pro".
    public var plan: String?
    /// Whether the agent itself speaks of what is left ("3% left") rather
    /// than what is used ("55% used"). Shown the way its owner shows it.
    public var showsRemaining: Bool
    public var groups: [AccountUsageGroup]
    public var notes: [AccountUsageNote]
    public var fetchedAt: Date
    /// Why the figures are missing or old, in words for the user.
    public var problem: String?

    public var id: String { agent }

    public init(
        agent: String, plan: String? = nil, showsRemaining: Bool = true, groups: [AccountUsageGroup] = [],
        notes: [AccountUsageNote] = [], fetchedAt: Date = Date(), problem: String? = nil
    ) {
        self.agent = agent
        self.plan = plan
        self.showsRemaining = showsRemaining
        self.groups = groups
        self.notes = notes
        self.fetchedAt = fetchedAt
        self.problem = problem
    }

    public var limits: [AccountLimit] { groups.flatMap(\.limits) }

    /// "55% used" or "45% left", the way the agent says it.
    public func percentText(_ limit: AccountLimit) -> String {
        showsRemaining ? "\(Int(limit.leftPercent.rounded()))% left" : "\(Int(limit.usedPercent.rounded()))% used"
    }
}
