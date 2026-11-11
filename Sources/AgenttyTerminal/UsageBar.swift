import AgenttyProtocol
import SwiftUI

/// One line under an agent's terminal: the model, how full its context is,
/// and how much of the account's limits is used, as far as the agent records it.
public struct UsageBar: View {
    let agent: String
    let name: String
    let usage: SessionUsage?
    /// Smaller, for a phone: the agent's name is left out.
    let compact: Bool

    public init(agent: String, name: String, usage: SessionUsage?, compact: Bool = false) {
        self.agent = agent
        self.name = name
        self.usage = usage
        self.compact = compact
    }

    private var size: CGFloat { compact ? 11 : 11.5 }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: compact ? 10 : 14) {
                HStack(spacing: 5) {
                    Image(systemName: AgentStyle.symbol(for: agent))
                        .font(.system(size: size - 1, weight: .semibold))
                        .foregroundStyle(AgentStyle.accent(for: agent))
                    Text(usage?.model ?? name)
                        .font(.system(size: size, weight: .medium))
                        .foregroundStyle(.primary.opacity(0.85))
                }
                if let usage {
                    if let tokens = usage.contextTokens {
                        context(tokens, usage)
                    }
                    ForEach(Array(usage.limits.enumerated()), id: \.offset) { _, limit in
                        self.limit(limit)
                    }
                    if let spent = usage.premiumRequests {
                        item("Premium requests", spent == spent.rounded() ? "\(Int(spent))" : String(format: "%.1f", spent))
                    }
                } else {
                    Text("No usage recorded yet")
                        .font(.system(size: size))
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .padding(.horizontal, compact ? 12 : 14)
            .padding(.vertical, compact ? 5 : 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("usage-bar")
    }

    private func item(_ label: String, _ value: String, color: Color = .primary.opacity(0.85)) -> some View {
        HStack(spacing: 5) {
            Text(label).foregroundStyle(.secondary)
            Text(value).foregroundStyle(color).monospacedDigit()
        }
        .font(.system(size: size))
    }

    @ViewBuilder
    private func context(_ tokens: Int, _ usage: SessionUsage) -> some View {
        if let fraction = usage.contextFraction, let window = usage.contextWindow {
            HStack(spacing: 6) {
                item("Context", "\(Int((fraction * 100).rounded()))%", color: Self.color(for: fraction * 100))
                Meter(fraction: fraction, color: Self.color(for: fraction * 100))
                Text("\(SessionUsage.short(tokens)) / \(SessionUsage.short(window))")
                    .font(.system(size: size))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        } else {
            item("Context", "\(SessionUsage.short(tokens)) tokens")
        }
    }

    /// A limit reads as what is left of it, the way the agents' own status
    /// screens put it, with when it starts over.
    private func limit(_ limit: UsageLimit) -> some View {
        let left = max(0, 100 - limit.usedPercent)
        return HStack(spacing: 6) {
            item("\(limit.label) limit", "\(Int(left.rounded()))% left", color: Self.color(for: limit.usedPercent))
            Meter(fraction: left / 100, color: Self.color(for: limit.usedPercent))
            if let resets = limit.resetsAt, resets > Date() {
                Text("resets \(Self.resetText(resets))")
                    .font(.system(size: size))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// "in 2h 10m" for today, "Fri 14:05" further out.
    static func resetText(_ date: Date, now: Date = Date()) -> String {
        let seconds = Int(date.timeIntervalSince(now))
        if seconds < 3600 { return "in \(max(1, seconds / 60))m" }
        if seconds < 24 * 3600 { return "in \(seconds / 3600)h \((seconds % 3600) / 60)m" }
        return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    /// Calm until most is used, then amber, then red.
    static func color(for percent: Double) -> Color {
        if percent >= 90 { return Color(red: 0.96, green: 0.45, blue: 0.47) }
        if percent >= 70 { return Color(red: 0.95, green: 0.72, blue: 0.35) }
        return .primary.opacity(0.85)
    }

    private struct Meter: View {
        let fraction: Double
        let color: Color

        var body: some View {
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule().fill(color).frame(width: max(2, 36 * min(1, max(0, fraction))))
            }
            .frame(width: 36, height: 4)
            .accessibilityHidden(true)
        }
    }
}
