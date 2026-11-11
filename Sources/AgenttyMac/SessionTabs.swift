import AgenttyProtocol
import SwiftUI

/// Every running session as a tab above the terminal, to switch between them
/// with one click or Command and a number.
struct SessionTabs: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if !model.sessions.isEmpty {
            HStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(Array(model.sessions.enumerated()), id: \.element.id) { index, session in
                                SessionTab(session: session, number: index + 1)
                                    .id(session.id)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                    }
                    .onChange(of: model.selectedSession) { _, selected in
                        if let selected { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(selected) } }
                    }
                }
                Menu {
                    ForEach(model.installedAgents) { agent in
                        Button("New \(agent.name)") { model.launch(agent) }
                    }
                    Button("New Shell") { model.launch(nil) }
                } label: {
                    Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .help("Start a session in \(model.workingDirectory)")
            }
            .background(Theme.panel)
            .overlay(alignment: .bottom) { Theme.hairline.frame(height: 1) }
        }
    }
}

private struct SessionTab: View {
    @EnvironmentObject private var model: AppModel
    let session: SessionInfo
    /// Place in the strip, counted from 1. The first nine have a shortcut.
    let number: Int
    @State private var hovering = false

    private var selected: Bool { model.selectedSession == session.id }
    private var agentID: String { session.agent ?? "shell" }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: Theme.symbol(for: agentID))
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Theme.accent(for: agentID))
            Text(session.displayName)
                .font(.system(size: 12, weight: selected ? .medium : .regular))
                .foregroundStyle(selected ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 190, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
            if model.foreignSizes[session.id] != nil {
                Image(systemName: "iphone").font(.system(size: 9.5)).foregroundStyle(.secondary)
            }
            // The close button takes the shortcut's place under the pointer,
            // so the tab does not change width.
            ZStack {
                if number <= 9 {
                    Text("⌘\(number)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .opacity(hovering ? 0 : 1)
                }
                Button { model.close(session.id) } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .opacity(hovering ? 1 : 0)
                .help("End this session")
            }
            .frame(minWidth: 22)
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? Color.white.opacity(0.12) : (hovering ? Color.white.opacity(0.05) : .clear))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { model.select(session: session) }
        .help("\(session.summary.map { "\(session.title): \($0)" } ?? session.title)\n\((session.cwd as NSString).abbreviatingWithTildeInPath)")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(session.displayName)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}
