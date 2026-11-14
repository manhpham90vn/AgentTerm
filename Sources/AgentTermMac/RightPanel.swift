import AgentTermHost
import AgentTermProtocol
import AgentTermTerminal
import Combine
import SwiftUI

/// The right side of the window: the folder's git changes, the history of
/// conversations each agent had in it, or its files.
struct RightPanel: View {
    @AppStorage("rightPanelTab") private var tab = "git"

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                PanelTab(title: "Git", symbol: "arrow.triangle.branch", selected: tab != "history" && tab != "files") { tab = "git" }
                PanelTab(title: "History", symbol: "clock.arrow.circlepath", selected: tab == "history") { tab = "history" }
                PanelTab(title: "Files", symbol: "folder", selected: tab == "files") { tab = "files" }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            Theme.hairline.frame(height: 1)
            WorktreeBar()
            if tab == "history" {
                HistoryView(ofFolder: true)
            } else if tab == "files" {
                FilesView()
            } else {
                DiffView()
            }
        }
        .background(Theme.panel)
    }
}

private struct PanelTab: View {
    let title: String
    let symbol: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold))
                Text(title).font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(selected ? .primary : .secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? Color.white.opacity(0.11) : (hovering ? Color.white.opacity(0.05) : .clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("panel-" + title.lowercased())
    }
}
