import AgentTermProtocol
import AgentTermTerminal
import SwiftUI

/// How this Mac is doing, in one line under the toolbar's launch buttons:
/// processor, memory, network speed, temperature, battery and uptime.
struct SystemStatsLine: View {
    @ObservedObject var store: SystemStatsStore
    /// Celsius or Fahrenheit, as chosen in Settings > General.
    @AppStorage(SystemStats.temperatureUnitKey) private var temperatureUnit = SystemStats.celsius

    private static let amber = Color(red: 0.95, green: 0.72, blue: 0.35)
    private static let red = Color(red: 0.96, green: 0.45, blue: 0.47)

    /// Calm until most is used, then amber, then red.
    private func color(forUsed percent: Double) -> Color {
        percent >= 90 ? Self.red : (percent >= 75 ? Self.amber : .primary.opacity(0.9))
    }

    var body: some View {
        if let stats = store.stats {
            // The clock only moves the uptime along; the rest comes from the host.
            TimelineView(.periodic(from: .now, by: 30)) { timeline in
                // In a narrow pane the names go and the symbols say it.
                ViewThatFits(in: .horizontal) {
                    row(stats, labels: true, now: timeline.date)
                    row(stats, labels: false, now: timeline.date)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(Theme.panel)
                .overlay(alignment: .bottom) { Theme.hairline.frame(height: 1) }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("system-stats")
        }
    }

    private func row(_ stats: SystemStats, labels: Bool, now: Date) -> some View {
        HStack(spacing: labels ? 18 : 12) {
            figure("cpu", "CPU", "\(Int(stats.cpuPercent.rounded()))%", color(forUsed: stats.cpuPercent), labels: labels, id: "system-cpu")
            figure("memorychip", "RAM", "\(Int(stats.memoryPercent.rounded()))%", color(forUsed: stats.memoryPercent), labels: labels, id: "system-memory")
                .help("\(stats.memoryText) in use")
            figure("arrow.down", "Down", SystemStats.speed(stats.downBytesPerSecond), .primary.opacity(0.9), labels: labels, id: "system-down")
            figure("arrow.up", "Up", SystemStats.speed(stats.upBytesPerSecond), .primary.opacity(0.9), labels: labels, id: "system-up")
            figure("thermometer.medium", "Temp", stats.temperatureText(unit: temperatureUnit), stats.isHot ? Self.red : .primary.opacity(0.9), labels: labels, id: "system-temperature")
            if let percent = stats.batteryPercent {
                figure(
                    stats.isCharging ? "battery.100percent.bolt" : "battery.75percent", stats.isCharging ? "Charging" : "Battery", "\(percent)%",
                    percent <= 10 && !stats.isOnPower ? Self.red : (percent <= 20 && !stats.isOnPower ? Self.amber : .primary.opacity(0.9)),
                    labels: labels, id: "system-battery")
            } else {
                figure("powerplug", "Power", "Plugged in", .primary.opacity(0.9), labels: labels, id: "system-battery")
            }
            figure("clock", "Uptime", SystemStats.uptime(since: stats.bootedAt, now: now), .primary.opacity(0.9), labels: labels, id: "system-uptime")
        }
    }

    private func figure(_ symbol: String, _ label: String, _ value: String, _ color: Color, labels: Bool, id: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            if labels {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 11.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(color)
        }
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) \(value)")
        .accessibilityIdentifier(id)
    }
}
