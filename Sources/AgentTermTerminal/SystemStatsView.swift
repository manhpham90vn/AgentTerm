import AgentTermProtocol
import SwiftUI

/// How the Mac itself is doing, in two rows of small cells: processor,
/// memory, heat and battery, then network speed, uptime and memory in
/// gigabytes. On the iPhone, above its sessions; the Mac has the same
/// figures in a line under its launch buttons.
public struct SystemStatsView: View {
    let stats: SystemStats
    /// Larger, for a phone.
    let large: Bool
    /// Celsius or Fahrenheit, as chosen in the app's settings.
    @AppStorage(SystemStats.temperatureUnitKey) private var temperatureUnit = SystemStats.celsius

    public init(stats: SystemStats, large: Bool = false) {
        self.stats = stats
        self.large = large
    }

    private static let amber = Color(red: 0.95, green: 0.72, blue: 0.35)
    private static let red = Color(red: 0.96, green: 0.45, blue: 0.47)

    /// Calm until most is used, then amber, then red.
    private func color(forUsed percent: Double) -> Color {
        percent >= 90 ? Self.red : (percent >= 75 ? Self.amber : .primary.opacity(0.9))
    }

    private var batterySymbol: String {
        guard let percent = stats.batteryPercent else { return "powerplug" }
        if stats.isCharging { return "battery.100percent.bolt" }
        switch percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    public var body: some View {
        // The clock only moves the uptime along; the rest comes from the host.
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            Grid(alignment: .leading, horizontalSpacing: large ? 10 : 8, verticalSpacing: large ? 10 : 7) {
                GridRow {
                    cell("cpu", "CPU", "\(Int(stats.cpuPercent.rounded()))%", color(forUsed: stats.cpuPercent), id: "system-cpu")
                    cell("memorychip", "RAM", "\(Int(stats.memoryPercent.rounded()))%", color(forUsed: stats.memoryPercent), id: "system-memory")
                    cell(
                        "thermometer.medium", "Temp", stats.temperatureText(unit: temperatureUnit), stats.isHot ? Self.red : .primary.opacity(0.9),
                        id: "system-temperature")
                    if let percent = stats.batteryPercent {
                        cell(
                            batterySymbol, stats.isCharging ? "Charging" : "Battery", "\(percent)%",
                            percent <= 10 && !stats.isOnPower ? Self.red : (percent <= 20 && !stats.isOnPower ? Self.amber : .primary.opacity(0.9)),
                            id: "system-battery")
                    } else {
                        cell("powerplug", "Power", "Plugged", .primary.opacity(0.9), id: "system-battery")
                    }
                }
                GridRow {
                    cell("arrow.down", "Down", SystemStats.speed(stats.downBytesPerSecond), .primary.opacity(0.9), id: "system-down")
                    cell("arrow.up", "Up", SystemStats.speed(stats.upBytesPerSecond), .primary.opacity(0.9), id: "system-up")
                    cell("clock", "Uptime", SystemStats.uptime(since: stats.bootedAt, now: timeline.date), .primary.opacity(0.9), id: "system-uptime")
                    cell("internaldrive", "Memory", stats.memoryShortText, .primary.opacity(0.9), id: "system-memory-used")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("system-stats")
    }

    private func cell(_ symbol: String, _ label: String, _ value: String, _ color: Color, id: String) -> some View {
        HStack(spacing: large ? 7 : 5) {
            Image(systemName: symbol)
                .font(.system(size: large ? 12 : 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: large ? 16 : 13)
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: large ? 11 : 9.5))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: large ? 13.5 : 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(color)
            }
            .lineLimit(1)
            // Four to a row on a phone: a long figure shrinks rather than
            // pushing its neighbours out.
            .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) \(value)")
        .accessibilityIdentifier(id)
    }
}

/// Holds how the Mac is doing, apart from the app's main model: the
/// figures arrive every few seconds, and only the view that shows them
/// should be drawn again for it. Published on the main model, every list
/// would be rebuilt each time, which cuts a drag in a list short.
@MainActor
public final class SystemStatsStore: ObservableObject {
    @Published public var stats: SystemStats?

    public init() {}
}

/// The figures of a store, or nothing until the host has sent some.
public struct SystemStatsPanel<Frame: View>: View {
    @ObservedObject private var store: SystemStatsStore
    private let large: Bool
    private let frame: (SystemStatsView) -> Frame

    /// `frame` puts the figures in whatever surrounds them: padding, a card.
    public init(store: SystemStatsStore, large: Bool = false, @ViewBuilder frame: @escaping (SystemStatsView) -> Frame) {
        self.store = store
        self.large = large
        self.frame = frame
    }

    public var body: some View {
        if let stats = store.stats { frame(SystemStatsView(stats: stats, large: large)) }
    }
}
