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
