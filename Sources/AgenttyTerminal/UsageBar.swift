import AgenttyProtocol
import SwiftUI

/// Colors and words the usage line and the usage sheet share.
enum UsageStyle {
    /// Calm until most is used, then amber, then red.
    static func color(forUsed percent: Double) -> Color {
        if percent >= 90 { return Color(red: 0.96, green: 0.45, blue: 0.47) }
        if percent >= 70 { return Color(red: 0.95, green: 0.72, blue: 0.35) }
        return .primary.opacity(0.85)
    }

    /// "in 2h 10m" for today, "Fri 14:05" further out.
    static func shortReset(_ date: Date, now: Date = Date()) -> String {
        let seconds = Int(date.timeIntervalSince(now))
        if seconds <= 0 { return "now" }
        if seconds < 3600 { return "in \(max(1, seconds / 60))m" }
        if seconds < 24 * 3600 { return "in \(seconds / 3600)h \((seconds % 3600) / 60)m" }
        return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    /// "Resets 6:50 PM" today, "Resets Nov 14 at 4:00 AM" further out.
    static func longReset(_ date: Date, now: Date = Date()) -> String {
        if date <= now { return "Resetting now" }
        if Calendar.current.isDate(date, inSameDayAs: now) { return "Resets \(date.formatted(date: .omitted, time: .shortened))" }
        return "Resets \(date.formatted(.dateTime.month(.abbreviated).day())) at \(date.formatted(date: .omitted, time: .shortened))"
    }
}

/// A thin bar showing how much of something is used.
struct UsageMeter: View {
    let usedFraction: Double
    let color: Color
    var width: CGFloat? = 36
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { area in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule().fill(color).frame(width: max(2, area.size.width * min(1, max(0, usedFraction))))
            }
        }
        .frame(width: width, height: height)
        .accessibilityHidden(true)
    }
}

/// One line under an agent's terminal: the model, how full its context is,
/// and what is left of the account's limits. Clicking it shows all of it.
public struct UsageBar: View {
    let agent: String
    let name: String
    let usage: SessionUsage?
    let account: AccountUsage?
    /// Smaller, for a phone.
    let compact: Bool
    let action: (() -> Void)?

    public init(agent: String, name: String, usage: SessionUsage?, account: AccountUsage? = nil, compact: Bool = false, action: (() -> Void)? = nil) {
        self.agent = agent
        self.name = name
        self.usage = usage
        self.account = account
        self.compact = compact
        self.action = action
    }

    private var size: CGFloat { compact ? 11 : 11.5 }

    /// The account's own limits when its service was asked; what the session
    /// recorded otherwise.
    private var accountLimits: [AccountLimit] { account?.groups.first?.limits ?? [] }

    public var body: some View {
        HStack(spacing: 0) {
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
                    if let tokens = usage?.contextTokens, let usage {
                        context(tokens, usage)
                    }
                    if let account, !accountLimits.isEmpty {
                        ForEach(accountLimits) { limit in
                            self.limit(title: limit.shortTitle, text: account.percentText(limit), used: limit.usedPercent, resets: limit.resetsAt, fillsWithLeft: account.showsRemaining)
                        }
                        let more = account.limits.count - accountLimits.count
                        if more > 0 { Text("+\(more) more").font(.system(size: size)).foregroundStyle(.secondary) }
                    } else if let usage, !usage.limits.isEmpty {
                        ForEach(Array(usage.limits.enumerated()), id: \.offset) { _, limit in
                            self.limit(title: limit.label, text: "\(Int(max(0, 100 - limit.usedPercent).rounded()))% left", used: limit.usedPercent, resets: limit.resetsAt, fillsWithLeft: true)
                        }
                    } else if let problem = account?.problem {
                        Text(problem).font(.system(size: size)).foregroundStyle(.secondary)
                    } else if usage == nil {
                        Text("No usage yet").font(.system(size: size)).foregroundStyle(.secondary)
                    }
                    if let spent = usage?.premiumRequests, account == nil {
                        item("Premium requests", spent == spent.rounded() ? "\(Int(spent))" : String(format: "%.1f", spent))
                    }
                }
                .lineLimit(1)
                .padding(.leading, compact ? 12 : 14)
                .padding(.trailing, 8)
                .padding(.vertical, compact ? 5 : 6)
            }
            if action != nil {
                Image(systemName: "chevron.up")
                    .font(.system(size: size - 2.5, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, compact ? 10 : 12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { action?() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(action == nil ? [] : .isButton)
        .accessibilityHint(action == nil ? "" : "Shows the account's usage")
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
                item("Context", "\(Int((fraction * 100).rounded()))%", color: UsageStyle.color(forUsed: fraction * 100))
                UsageMeter(usedFraction: fraction, color: UsageStyle.color(forUsed: fraction * 100))
                Text("\(SessionUsage.short(tokens)) / \(SessionUsage.short(window))")
                    .font(.system(size: size))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        } else {
            item("Context", "\(SessionUsage.short(tokens)) tokens")
        }
    }

    /// The bar fills with what the words beside it count: what is left, or what is used.
    private func limit(title: String, text: String, used: Double, resets: Date?, fillsWithLeft: Bool) -> some View {
        HStack(spacing: 6) {
            item(title, text, color: UsageStyle.color(forUsed: used))
            UsageMeter(usedFraction: (fillsWithLeft ? 100 - used : used) / 100, color: UsageStyle.color(forUsed: used))
            if let resets, !compact {
                Text("resets \(UsageStyle.shortReset(resets))")
                    .font(.system(size: size))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Everything known about an agent's usage: the session's context, and the
/// account's limits the way the agent's own usage screen lists them.
public struct UsageDetails: View {
    let agent: String
    let name: String
    let usage: SessionUsage?
    let account: AccountUsage?
    let refresh: () -> Void
    @State private var now = Date()

    public init(agent: String, name: String, usage: SessionUsage?, account: AccountUsage?, refresh: @escaping () -> Void) {
        self.agent = agent
        self.name = name
        self.usage = usage
        self.account = account
        self.refresh = refresh
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: AgentStyle.symbol(for: agent))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AgentStyle.accent(for: agent))
                Text(name).font(.headline)
                if let plan = account?.plan {
                    Text(plan)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                }
                Spacer()
                Button(action: refresh) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Ask again")
                    .accessibilityLabel("Refresh usage")
            }

            if let usage, usage.model != nil || usage.contextTokens != nil {
                section("This session") {
                    if let model = usage.model { fact("Model", model) }
                    if let tokens = usage.contextTokens {
                        if let fraction = usage.contextFraction, let window = usage.contextWindow {
                            row(title: "Context", text: "\(Int((fraction * 100).rounded()))% used", used: fraction * 100,
                                caption: "\(SessionUsage.short(tokens)) of \(SessionUsage.short(window)) tokens")
                        } else {
                            fact("Context", "\(SessionUsage.short(tokens)) tokens")
                        }
                    }
                }
            }

            if let account {
                ForEach(Array(account.groups.enumerated()), id: \.offset) { index, group in
                    section(group.title ?? (index == 0 ? "Account limits" : "More limits")) {
                        if let note = group.note {
                            Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(group.limits) { limit in
                            row(title: limit.title, text: account.percentText(limit), used: limit.usedPercent, fillsWithLeft: account.showsRemaining,
                                caption: [limit.detail, limit.resetsAt.map { UsageStyle.longReset($0, now: now) }].compactMap { $0 }.joined(separator: " · "))
                        }
                    }
                }
                if !account.notes.isEmpty {
                    section("Account") {
                        ForEach(Array(account.notes.enumerated()), id: \.offset) { _, note in fact(note.label, note.value) }
                    }
                }
                if let problem = account.problem {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(Color(red: 0.95, green: 0.72, blue: 0.35))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("From \(Self.service(for: agent)), \(account.fetchedAt.formatted(.relative(presentation: .named))).")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else if let usage, !usage.limits.isEmpty {
                section("Account limits") {
                    ForEach(Array(usage.limits.enumerated()), id: \.offset) { _, limit in
                        row(title: limit.label + " limit", text: "\(Int(max(0, 100 - limit.usedPercent).rounded()))% left", used: limit.usedPercent, fillsWithLeft: true,
                            caption: limit.resetsAt.map { UsageStyle.longReset($0, now: now) } ?? "")
                    }
                }
            } else {
                Text("The account's limits are not known yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            now = Date()
            refresh()
        }
        .accessibilityIdentifier("usage-details")
    }

    private static func service(for agent: String) -> String {
        switch agent {
        case "claude": return "Anthropic"
        case "codex": return "ChatGPT"
        case "copilot": return "GitHub"
        case "agy": return "Google"
        default: return "the service"
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).multilineTextAlignment(.trailing)
        }
        .font(.callout)
    }

    private func row(title: String, text: String, used: Double, fillsWithLeft: Bool = false, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.callout)
                Spacer(minLength: 12)
                Text(text)
                    .font(.callout.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(UsageStyle.color(forUsed: used))
            }
            UsageMeter(usedFraction: (fillsWithLeft ? 100 - used : used) / 100, color: used >= 70 ? UsageStyle.color(forUsed: used) : Color(red: 0.45, green: 0.62, blue: 0.98), width: nil, height: 6)
            if !caption.isEmpty {
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
