import AppKit
import SwiftUI

enum Theme {
    static let terminalBackground = NSColor(srgbRed: 0.075, green: 0.078, blue: 0.098, alpha: 1)
    static let terminalForeground = NSColor(srgbRed: 0.86, green: 0.87, blue: 0.90, alpha: 1)
    static let terminalFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    static let canvas = Color(nsColor: terminalBackground)
    static let panel = Color(red: 0.098, green: 0.102, blue: 0.125)
    static let raised = Color.white.opacity(0.06)
    static let hairline = Color.white.opacity(0.08)
    static let added = Color(red: 0.36, green: 0.80, blue: 0.52)
    static let removed = Color(red: 0.96, green: 0.45, blue: 0.47)

    /// Accent used for an agent's dot and launch button.
    static func accent(for agent: String) -> Color {
        switch agent {
        case "claude": return Color(red: 0.87, green: 0.53, blue: 0.36)
        case "codex": return Color(red: 0.40, green: 0.78, blue: 0.72)
        case "agy": return Color(red: 0.45, green: 0.62, blue: 0.98)
        case "copilot": return Color(red: 0.72, green: 0.56, blue: 0.96)
        default: return Color.white.opacity(0.55)
        }
    }

    static func symbol(for agent: String) -> String {
        switch agent {
        case "claude": return "sparkle"
        case "codex": return "chevron.left.forwardslash.chevron.right"
        case "agy": return "arrow.up.forward.circle"
        case "copilot": return "airplane"
        default: return "terminal"
        }
    }
}
