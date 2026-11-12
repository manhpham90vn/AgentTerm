import AgentTermHost
import AgentTermProtocol
import AgentTermTerminal
import Combine
import SwiftUI

/// The right side of the window: the folder's git changes, or the history of
/// conversations each agent had in it.
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
            if tab == "history" {
                HistoryView()
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
                // Same idea as the Git tab by default: the selected folder.
                // "All" is the one place that lists every conversation.
                Picker("Scope", selection: $model.historyShowsAll) {
                    Text("This Folder").tag(false)
                    Text("All").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                .help("Show this folder's conversations, or every conversation on \(model.macName)")
                Text(model.history.map { $0.count == 1 ? "1 conversation" : "\($0.count) conversations" } ?? "Loading…")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                Spacer()
                Button {
                    model.refreshHistory()
                } label: {
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
        if model.selectedFolder == nil && !model.historyShowsAll {
            placeholder("Select a folder to see its conversations, or switch to All.")
        } else if let history = model.history {
            if history.isEmpty {
                placeholder(
                    model.historyShowsAll
                        ? "No agent has a conversation on \(model.macName) yet."
                        : "No agent has a conversation in this folder yet.\nSwitch to All to see the ones from other folders.")
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
                                    ConversationRow(conversation: conversation, showsFolder: model.historyShowsAll)
                                }
                            }
                        }
                    }
                    .padding(6)
                }
            }
        } else {
            LoadingView("Loading the history…")
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
    /// In the list of everything, each row says which folder it ran in.
    var showsFolder = false
    @State private var hovering = false

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    /// The row's hover color as an opaque color, to put behind the actions.
    private static let hoverFill = Color(red: 0.152, green: 0.156, blue: 0.178)

    private var actions: some View {
        HStack(spacing: 10) {
            if !targets.isEmpty {
                Button {
                    model.requestHandoff(conversation)
                } label: {
                    Label("Hand Off", systemImage: "arrowshape.turn.up.right.fill")
                        .font(.system(size: 10.5, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Give this work to another agent")
            }
            Button {
                model.resume(conversation)
            } label: {
                Label("Resume", systemImage: "play.fill")
                    .font(.system(size: 10.5, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent(for: conversation.agent))
            .help("Continue this conversation in a new session")
        }
        .padding(.leading, 30)
        .padding(.trailing, 8)
        .padding(.vertical, 5)
        .background(
            // Fades in from the left so the title does not end at a hard
            // edge, and is solid before the first icon so no text shows through it.
            LinearGradient(
                stops: [.init(color: Self.hoverFill.opacity(0), location: 0), .init(color: Self.hoverFill, location: 0.14)],
                startPoint: .leading, endPoint: .trailing)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var targets: [AgentInfo] { model.handoffTargets(from: conversation.agent) }

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
                HStack(spacing: 5) {
                    Text(when)
                    if showsFolder {
                        Text("·")
                        Image(systemName: "folder").font(.system(size: 9))
                        Text((conversation.cwd as NSString).lastPathComponent)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 27)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(hovering ? Self.hoverFill : .clear)
        )
        // The actions float over the end of the title instead of taking
        // room in the row, so showing them never squeezes the time and
        // folder line out of view.
        .overlay(alignment: .topTrailing) {
            if hovering { actions }
        }
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
        .help(showsFolder ? "\(conversation.title)\n\((conversation.cwd as NSString).abbreviatingWithTildeInPath)" : conversation.title)
        // The row's buttons only show under the pointer. Without one, the
        // row says what it is and offers what they do as its actions.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(conversation.title)
        .accessibilityIdentifier("conversation-" + conversation.sessionID)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Resume") { model.resume(conversation) }
        .accessibilityAction(named: "Hand Off") { model.requestHandoff(conversation) }
    }
}
