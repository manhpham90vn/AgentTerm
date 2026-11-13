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

/// Past conversations, one section per agent: every one on the Mac, each
/// row naming its folder, in History; the folder on show's only, in the side
/// panel, where picking one shows it in History.
struct HistoryView: View {
    @EnvironmentObject private var model: AppModel
    /// The side panel's: the folder on show's only.
    var ofFolder = false
    @State private var collapsedAgents: Set<String> = []
    private let refresh = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    private var sections: [(id: String, name: String, conversations: [Conversation])] {
        let all = list ?? []
        return AgentDetector.known.compactMap { agent in
            let own = all.filter { $0.agent == agent.id }
            return own.isEmpty ? nil : (agent.id, agent.name, own)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(list.map { $0.count == 1 ? "1 conversation" : "\($0.count) conversations" } ?? "Loading…")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button {
                    model.refreshHistory(ofFolder: ofFolder)
                } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Refresh")
            }
            .padding(.horizontal, 14)
            .padding(.top, 2)
            .padding(.bottom, 9)
            Theme.hairline.frame(height: 1)
            content
        }
        .onAppear { model.refreshHistory(ofFolder: ofFolder) }
        .onReceive(refresh) { _ in
            if NSApp.isActive { model.refreshHistory(ofFolder: ofFolder) }
        }
    }

    private var list: [Conversation]? { ofFolder ? model.folderHistory : model.history }

    @ViewBuilder
    private var content: some View {
        if ofFolder && model.panelFolder == nil {
            placeholder("Select a folder to see its conversations.")
        } else if let history = list {
            if history.isEmpty {
                placeholder(ofFolder ? "No agent has a conversation in this folder yet." : "No agent has a conversation on \(model.macName) yet.")
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
                                    ConversationRow(conversation: conversation, showsFolder: !ofFolder, inSheet: ofFolder)
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
    /// The side panel's: picked, it opens in a sheet over Sessions.
    var inSheet = false
    @State private var hovering = false

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private static let hoverFill = Color(red: 0.152, green: 0.156, blue: 0.178)

    private var when: String {
        // "in 0 sec" reads oddly for something that just happened.
        conversation.updatedAt.timeIntervalSinceNow > -60 ? "now" : Self.relative.localizedString(for: conversation.updatedAt, relativeTo: Date())
    }

    private var selected: Bool { !inSheet && model.historySelection?.id == conversation.id }

    private var tip: String {
        showsFolder ? conversation.title + "\n" + (conversation.cwd as NSString).abbreviatingWithTildeInPath : conversation.title
    }

    private var fill: Color { selected ? Color.white.opacity(0.11) : (hovering ? Self.hoverFill : .clear) }

    /// In a new session, which is then what is looked at.
    private func resume() {
        model.resume(conversation)
        model.panelConversation = nil
        model.show(.sessions, toggling: false)
    }

    private func pick() {
        if inSheet {
            model.panelConversation = conversation
        } else {
            model.historySelection = conversation
        }
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
                .fill(fill)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        // Picked at once, it is shown in History's middle, with what can be
        // done with it; a second click resumes it. With two tap gestures the
        // first would wait to know there is no second.
        .simultaneousGesture(TapGesture().onEnded(pick))
        .simultaneousGesture(TapGesture(count: 2).onEnded(resume))
        // Resume, Copy Resume Command and Hand Off are where it opens, in
        // the middle or in a sheet: the row has no menu of its own.
        .help(tip)
        // The row says what it is and offers what the middle does as its actions.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(conversation.title)
        .accessibilityIdentifier("conversation-" + conversation.sessionID)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { pick() }
        .accessibilityAction(named: "Resume") { resume() }
        .accessibilityAction(named: "Hand Off") { model.requestHandoff(conversation) }
    }
}

/// Which of the folder's git worktrees the side panel shows (#33), and what
/// to do with one whose work is finished (#23). Shown when the folder has
/// more than its own.
private struct WorktreeBar: View {
    @EnvironmentObject private var model: AppModel
    @State private var discarding: WorktreeInfo?
    @State private var settingUp = false
    @State private var setup = ""

    private var folder: String? { model.selectedFolder }
    private var list: [WorktreeInfo] { folder.flatMap { model.worktrees[$0] } ?? [] }
    private var shown: WorktreeInfo? { list.first { $0.path == (model.shownWorktree ?? folder) } ?? list.first }

    private func title(_ worktree: WorktreeInfo) -> String {
        if worktree.isMain { return (worktree.path as NSString).lastPathComponent + (worktree.branch.map { " · \($0)" } ?? "") }
        return worktree.branch ?? (worktree.path as NSString).lastPathComponent
    }

    private func detail(_ worktree: WorktreeInfo) -> String {
        if worktree.missing { return "missing: its folder is gone" }
        var parts: [String] = []
        if worktree.ahead > 0 { parts.append("\(worktree.ahead) ahead") }
        if worktree.changed > 0 { parts.append("\(worktree.changed) changed") }
        if !worktree.isAgentTerm && !worktree.isMain { parts.append((worktree.path as NSString).abbreviatingWithTildeInPath) }
        if worktree.inUse { parts.append("in use") }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        if let folder, list.count > 1, let shown {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 10.5)).foregroundStyle(.secondary)
                Menu {
                    ForEach(list) { worktree in
                        Button {
                            model.shownWorktree = worktree.isMain ? nil : worktree.path
                        } label: {
                            let more = detail(worktree)
                            Text(title(worktree) + (more.isEmpty ? "" : " — \(more)"))
                        }
                        .disabled(worktree.missing)
                    }
                    Divider()
                    Button("Setup Command for New Worktrees…") {
                        setup = model.worktreeSetups[folder] ?? ""
                        settingUp = true
                    }
                } label: {
                    Text(title(shown)).font(.system(size: 12, weight: .medium)).lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityIdentifier("worktree-menu")
                Text(detail(shown)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
                if !shown.isMain {
                    Menu("Finish") {
                        Button("Merge into \(list.first?.branch ?? "the folder's branch")") {
                            model.finishWorktree(shown, of: folder, .merge, deleteBranch: shown.isAgentTerm)
                            model.shownWorktree = nil
                        }
                        .disabled(shown.changed > 0 || shown.ahead == 0)
                        Button("Open a Pull Request") { model.finishWorktree(shown, of: folder, .pullRequest, deleteBranch: false) }
                            .disabled(model.diff?.pushRemote == nil && model.diff?.upstream == nil)
                        Divider()
                        Button("Throw Away…", role: .destructive) { discarding = shown }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.03))
            .help("The side panel shows this worktree's changes, history and files")
            .confirmationDialog(
                "Throw away \(discarding.map(title) ?? "this worktree")?", isPresented: Binding(get: { discarding != nil }, set: { if !$0 { discarding = nil } })
            ) {
                Button("Throw Away the Worktree and Its Branch", role: .destructive) {
                    if let discarding { model.finishWorktree(discarding, of: folder, .discard, deleteBranch: true) }
                    model.shownWorktree = nil
                }
                Button("Throw Away the Worktree, Keep the Branch", role: .destructive) {
                    if let discarding { model.finishWorktree(discarding, of: folder, .discard, deleteBranch: false) }
                    model.shownWorktree = nil
                }
            } message: {
                Text(discarding.map { $0.hasUnmergedWork ? "It has work that is not merged: \(detail($0)). It will be lost." : "Its folder is removed." } ?? "")
            }
            .sheet(isPresented: $settingUp) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Setup Command").font(.headline)
                    Text("Run in each new worktree of this folder before its session starts, as in a terminal: `npm install`, `cp ../../../.env .`. Nothing else is copied into a new worktree.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    TextField("None", text: $setup).textFieldStyle(.roundedBorder)
                    HStack {
                        Spacer()
                        Button("Cancel") { settingUp = false }.keyboardShortcut(.cancelAction)
                        Button("Save") {
                            model.setWorktreeSetup(setup, for: folder)
                            settingUp = false
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(20)
                .frame(width: 460)
            }
        }
    }
}
