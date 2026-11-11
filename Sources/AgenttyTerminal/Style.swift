import SwiftUI

#if os(macOS)
import AppKit
public typealias PlatformColor = NSColor
public typealias PlatformFont = NSFont
#else
import UIKit
public typealias PlatformColor = UIColor
public typealias PlatformFont = UIFont
#endif

/// Colors and fonts of the terminal itself, shared by every platform.
public enum TerminalStyle {
    public static let background = PlatformColor(red: 0.075, green: 0.078, blue: 0.098, alpha: 1)
    public static let foreground = PlatformColor(red: 0.86, green: 0.87, blue: 0.90, alpha: 1)

    public static func font(size: CGFloat) -> PlatformFont {
        .monospacedSystemFont(ofSize: size, weight: .regular)
    }
}

/// How each agent is shown: one accent color and one symbol.
public enum AgentStyle {
    public static func accent(for agent: String) -> Color {
        switch agent {
        case "claude": return Color(red: 0.87, green: 0.53, blue: 0.36)
        case "codex": return Color(red: 0.40, green: 0.78, blue: 0.72)
        case "agy": return Color(red: 0.45, green: 0.62, blue: 0.98)
        case "copilot": return Color(red: 0.72, green: 0.56, blue: 0.96)
        default: return Color.white.opacity(0.55)
        }
    }

    public static func symbol(for agent: String) -> String {
        switch agent {
        case "claude": return "sparkle"
        case "codex": return "chevron.left.forwardslash.chevron.right"
        case "agy": return "arrow.up.forward.circle"
        case "copilot": return "airplane"
        default: return "terminal"
        }
    }
}
