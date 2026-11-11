import AgenttyHost
import AgenttyProtocol
import Combine
import SwiftUI

/// The right side of the window: the folder's git changes, or the history of
/// conversations each agent had in it.
struct RightPanel: View {
    @AppStorage("rightPanelTab") private var tab = "git"

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                PanelTab(title: "Git", symbol: "arrow.triangle.branch", selected: tab != "history") { tab = "git" }
                PanelTab(title: "History", symbol: "clock.arrow.circlepath", selected: tab == "history") { tab = "history" }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            Theme.hairline.frame(height: 1)
            if tab == "history" {
                HistoryView()
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
    }
}

/// Past conversations of the selected folder, one section per agent.
struct HistoryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var collapsedAgents: Set<String> = []
    private let refresh = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    private var sections: [(id: String, name: String, conversations: [Conversation])] {
        let all = model.history ?? []
        return AgentDetector.known.compactMap { agent in
            let own = all.filter { $0.agent == agent.id }
            return own.isEmpty ? nil : (agent.id, agent.name, own)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(model.history.map { $0.count == 1 ? "1 conversation" : "\($0.count) conversations" } ?? "Loading…")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button { model.refreshHistory() } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Refresh")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            Theme.hairline.frame(height: 1)
            content
        }
        .onAppear { model.refreshHistory() }
        .onReceive(refresh) { _ in
            if NSApp.isActive { model.refreshHistory() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.selectedFolder == nil {
            placeholder("Select a folder to see its conversations.")
        } else if let history = model.history {
            if history.isEmpty {
                placeholder("No agent has a conversation in this folder yet.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(sections, id: \.id) { section in
                            let expanded = !collapsedAgents.contains(section.id)
                            AgentHeader(id: section.id, name: section.name, count: section.conversations.count, expanded: expanded)
                                .onTapGesture {
                                    if expanded { collapsedAgents.insert(section.id) } else { collapsedAgents.remove(section.id) }
                                }
                            if expanded {
                                ForEach(section.conversations) { conversation in
                                    ConversationRow(conversation: conversation)
                                }
                            }
                        }
                    }
                    .padding(6)
                }
            }
        } else {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct AgentHeader: View {
    let id: String
    let name: String
    let count: Int
    let expanded: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 12)
            Image(systemName: Theme.symbol(for: id))
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Theme.accent(for: id))
            Text(name)
                .font(.system(size: 12, weight: .semibold))
            Text("\(count)")
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.top, 9)
        .padding(.bottom, 5)
        .contentShape(Rectangle())
        .accessibilityLabel("\(name), \(count) conversations, \(expanded ? "expanded" : "collapsed")")
    }
}

private struct ConversationRow: View {
    @EnvironmentObject private var model: AppModel
    let conversation: Conversation
    @State private var hovering = false

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private var targets: [AgentInfo] { model.handoffTargets(from: conversation.agent) }

    @ViewBuilder
    private var handoffItems: some View {
        ForEach(targets) { target in
            Button(target.name) { model.handoff(conversation, to: target) }
        }
    }

    private var when: String {
        // "in 0 sec" reads oddly for something that just happened.
        conversation.updatedAt.timeIntervalSinceNow > -60 ? "now" : Self.relative.localizedString(for: conversation.updatedAt, relativeTo: Date())
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(conversation.title)
                    .font(.system(size: 12))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(when)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if hovering {
                if !targets.isEmpty {
                    Menu {
                        handoffItems
                    } label: {
                        Label("Hand Off", systemImage: "arrowshape.turn.up.right.fill")
                            .font(.system(size: 10.5, weight: .semibold))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .foregroundStyle(.secondary)
                    .help("Give this work to another agent")
                }
                Button { model.resume(conversation) } label: {
                    Label("Resume", systemImage: "play.fill")
                        .font(.system(size: 10.5, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent(for: conversation.agent))
                .help("Continue this conversation in a new session")
            }
        }
        .padding(.leading, 27)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(hovering ? Color.white.opacity(0.06) : .clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { model.resume(conversation) }
        // Resume and Hand Off have their own buttons on the row, so the menu
        // only holds what has no button.
        .contextMenu {
            Button("Copy Resume Command") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(conversation.resumeCommand, forType: .string)
            }
        }
        .help(conversation.title)
    }
}
