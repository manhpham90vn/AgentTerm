import AgentTermTerminal
import AppKit
import SwiftUI

enum Theme {
    static let canvas = Color(nsColor: TerminalStyle.background)
    static let panel = Color(red: 0.098, green: 0.102, blue: 0.125)
    /// The bar of places at the window's left edge, a shade under the panels.
    static let activityBar = Color(red: 0.075, green: 0.078, blue: 0.098)
    static let raised = Color.white.opacity(0.06)
    static let hairline = Color.white.opacity(0.08)
    static let added = Color(red: 0.36, green: 0.80, blue: 0.52)
    static let removed = Color(red: 0.96, green: 0.45, blue: 0.47)

    static func accent(for agent: String) -> Color { AgentStyle.accent(for: agent) }
    static func symbol(for agent: String) -> String { AgentStyle.symbol(for: agent) }
}
