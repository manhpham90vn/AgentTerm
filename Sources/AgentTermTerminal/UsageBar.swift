import AgentTermProtocol
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

/// A band under an agent's terminal with the few figures worth a glance:
/// the model, how full the context is, and what the account's main limits
/// have left. Each sits in a cell of its own, a number over a small bar.
/// As many cells are shown as fit; clicking the band shows everything.
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

    /// One figure of the band.
    private struct Cell: Identifiable {
        let id: String
        let label: String
        let value: String
        /// How much of the bar is filled, from 0 to 1.
        let fill: Double
        /// How much is used, which decides the color.
        let used: Double
        /// Said after the bar where there is room: when the limit starts over.
        let note: String?
    }

    private var cells: [Cell] {
        var cells: [Cell] = []
        // Every agent's band has the same cells in the same order. A figure
        // that is not known yet shows as a dash, not as a missing cell.
        if let usage, let tokens = usage.contextTokens {
            if let fraction = usage.contextFraction {
                cells.append(Cell(id: "context", label: "Context", value: "\(Int((fraction * 100).rounded()))%", fill: fraction, used: fraction * 100, note: usage.contextWindow.map { "of \(SessionUsage.short($0))" }))
            } else {
                cells.append(Cell(id: "context", label: "Context", value: SessionUsage.short(tokens), fill: 0, used: 0, note: "tokens"))
            }
        } else {
            cells.append(Cell(id: "context", label: "Context", value: "–", fill: 0, used: 0, note: usage?.contextWindow.map { "of \(SessionUsage.short($0))" }))
        }
        if let account, let limits = account.groups.first?.limits, !limits.isEmpty {
            // The account's own limits, as its service reports them.
            for limit in limits {
                cells.append(Cell(
                    id: limit.id, label: limit.shortTitle, value: account.percentText(limit),
                    fill: (account.showsRemaining ? limit.leftPercent : limit.usedPercent) / 100, used: limit.usedPercent,
                    note: limit.resetsAt.map { UsageStyle.shortReset($0) }
                ))
            }
        } else if let usage {
            // What the session itself recorded, until the service has answered.
            for (index, limit) in usage.limits.enumerated() {
                let left = max(0, 100 - limit.usedPercent)
                cells.append(Cell(id: "recorded-\(index)", label: limit.label, value: "\(Int(left.rounded()))% left", fill: left / 100, used: limit.usedPercent, note: limit.resetsAt.map { UsageStyle.shortReset($0) }))
            }
        }
        return cells
    }

    public var body: some View {
        let cells = cells
        HStack(spacing: 0) {
            // Fewer cells on a narrow screen, rather than cells squeezed
            // until they cannot be read.
            ViewThatFits(in: .horizontal) {
                ForEach(Array(stride(from: cells.count, through: 0, by: -1)), id: \.self) { count in
                    row(Array(cells.prefix(count)), hidden: cells.count - count)
                }
            }
            Spacer(minLength: 0)
            if action != nil {
                Image(systemName: "chevron.up")
                    .font(.system(size: compact ? 9 : 9.5, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, compact ? 10 : 14)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Two lines of a cell and the room around them. On the Mac the
        // second line carries text (about 14 + 5 + 12 points, and 7 above
        // and below); on a phone it is only the 3 point bar (13 + 4 + 3,
        // and 9 above and below, which also keeps it easy to tap).
        .frame(height: compact ? 38 : 46)
        .contentShape(Rectangle())
        .onTapGesture { action?() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(action == nil ? [] : .isButton)
        .accessibilityHint(action == nil ? "" : "Shows the account's usage")
        .accessibilityIdentifier("usage-bar")
    }

    private func row(_ cells: [Cell], hidden: Int) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: AgentStyle.symbol(for: agent))
                    .font(.system(size: compact ? 11 : 11.5, weight: .semibold))
                    .foregroundStyle(AgentStyle.accent(for: agent))
                Text(usage?.model ?? name)
                    .font(.system(size: compact ? 11.5 : 12, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.9))
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.leading, compact ? 12 : 14)
            .padding(.trailing, compact ? 10 : 14)
            ForEach(cells) { cell in
                Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1, height: 24)
                view(for: cell)
            }
            if cells.isEmpty {
                Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1, height: 24)
                Text(account?.problem ?? "No usage yet")
                    .font(.system(size: compact ? 11 : 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, compact ? 10 : 14)
                    .frame(maxWidth: compact ? 220 : 420, alignment: .leading)
            } else if hidden > 0 {
                Text("+\(hidden)")
                    .font(.system(size: compact ? 10.5 : 11, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, compact ? 8 : 12)
                    .fixedSize()
            }
        }
    }

    private func view(for cell: Cell) -> some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 5) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(cell.label)
                    .font(.system(size: compact ? 10 : 10.5))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(cell.value)
                    .font(.system(size: compact ? 11 : 11.5, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(UsageStyle.color(forUsed: cell.used))
            }
            .lineLimit(1)
            .fixedSize()
            HStack(spacing: 6) {
                UsageMeter(usedFraction: cell.fill, color: cell.used >= 70 ? UsageStyle.color(forUsed: cell.used) : Color(red: 0.45, green: 0.62, blue: 0.98), width: nil, height: 3)
                if let note = cell.note, !compact {
                    Text(note)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                }
            }
        }
        .frame(width: compact ? nil : 132, alignment: .leading)
        .fixedSize(horizontal: compact, vertical: false)
        .padding(.horizontal, compact ? 10 : 14)
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
