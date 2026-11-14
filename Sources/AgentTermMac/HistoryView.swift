import AgentTermHost
import AgentTermProtocol
import AgentTermTerminal
import Combine
import SwiftUI

/// Past conversations: every one on the Mac, each row naming its folder,
/// in History; the folder on show's only, in the side panel, where picking
/// one shows it in a sheet. Searched, filtered and grouped (#46).
struct HistoryView: View {
    @EnvironmentObject private var model: AppModel
    /// The side panel's: the folder on show's only.
    var ofFolder = false

    var body: some View {
        HistoryList(store: model.historyStore, ofFolder: ofFolder)
    }
}

private struct HistoryList: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var store: HistoryStore
    let ofFolder: Bool
    @State private var collapsed: Set<String> = []
    @State private var pickingDay = false
    @State private var day = Date()
    private let refresh = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    private var scope: HistoryStore.Scope { store[ofFolder: ofFolder] }
    private var filter: Binding<HistoryFilter> {
        Binding(get: { store[ofFolder: ofFolder].filter }, set: { store[ofFolder: ofFolder].filter = $0 })
    }
    private var listed: [Conversation]? { ofFolder ? model.folderHistory : model.history }
    /// The first page and the older ones asked for since.
    private var conversations: [Conversation] {
        let first = listed ?? []
        let known = Set(first.map(\.id))
        return first + scope.older.filter { !known.contains($0.id) }
    }
    private var agentNames: [(id: String, name: String)] { AgentDetector.known.map { ($0.id, $0.name) } }
    private var groups: [HistoryFilter.Group] {
        scope.filter.groups(conversations, pinned: store.pinned, hidden: store.hidden, agentNames: agentNames)
    }
    /// What a search found, as far as the filter lets it through.
    private var hits: [HistoryHit]? {
        scope.hits?.filter { scope.filter.allows($0.conversation, hidden: store.hidden) }.sorted { $0.conversation.updatedAt > $1.conversation.updatedAt }
    }
    /// The first page is full: there may be older ones.
    private var mayHaveOlder: Bool { (listed?.count ?? 0) >= (ofFolder ? 200 : 300) && scope.more }

    private var summary: String {
        guard listed != nil else { return "Loading…" }
        if let hits { return scope.isSearching ? "Searching… \(hits.count) found" : (hits.count == 1 ? "1 found" : "\(hits.count) found") }
        let count = groups.reduce(0) { $0 + $1.conversations.count }
        let words = count == 1 ? "1 conversation" : "\(count) conversations"
        return scope.filter.isActive ? words + ", filtered" : words
    }

    var body: some View {
        VStack(spacing: 0) {
            searchRow
            summaryRow
            Theme.hairline.frame(height: 1)
            content
        }
        .onAppear { model.refreshHistory(ofFolder: ofFolder) }
        .onReceive(refresh) { _ in
            if NSApp.isActive { model.refreshHistory(ofFolder: ofFolder) }
        }
        .onChange(of: scope.query) { _, _ in store.search(ofFolder: ofFolder, path: model.panelFolder) }
        .popover(isPresented: $pickingDay, arrowEdge: .bottom) { dayPicker }
    }

    private var dayPicker: some View {
        VStack(spacing: 8) {
            DatePicker("Day", selection: $day, in: ...Date(), displayedComponents: .date).datePickerStyle(.graphical).labelsHidden()
            Button("Show This Day") {
                filter.wrappedValue.when = .day(day)
                pickingDay = false
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }

    private var searchRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 10.5)).foregroundStyle(.secondary)
            TextField("Search titles and what was said", text: Binding(get: { scope.query }, set: { store[ofFolder: ofFolder].query = $0 }))
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .accessibilityIdentifier(ofFolder ? "history-search-folder" : "history-search")
            if !scope.query.isEmpty {
                Button {
                    store[ofFolder: ofFolder].query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 10.5))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Clear Search")
            }
            filterMenu
            Button {
                model.refreshHistory(ofFolder: ofFolder)
            } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Refresh")
        }
        .padding(.horizontal, 12)
        // Under the list's title at the window's left, under the tabs in
        // the side panel, which have no title between.
        .padding(.top, ofFolder ? 8 : 2)
        .padding(.bottom, 6)
    }

    private var summaryRow: some View {
        HStack {
            Text(summary).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                .accessibilityIdentifier(ofFolder ? "history-summary-folder" : "history-summary")
            Spacer(minLength: 0)
            if scope.filter.isActive {
                Button("Clear Filters") {
                    filter.wrappedValue.agent = nil
                    filter.wrappedValue.folder = nil
                    filter.wrappedValue.when = .any
                }
                .buttonStyle(.plain)
                .font(.system(size: 10.5))
                .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 7)
    }

    /// How the list is grouped, and which conversations it shows.
    private var filterMenu: some View {
        Menu {
            Picker("Group", selection: filter.grouping) {
                ForEach(HistoryFilter.Grouping.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
            Picker("Agent", selection: filter.agent) {
                Text("All Agents").tag(String?.none)
                ForEach(AgentDetector.known, id: \.id) { Text($0.name).tag(String?.some($0.id)) }
            }
            if !ofFolder {
                Picker("Folder", selection: filter.folder) {
                    Text("All Folders").tag(String?.none)
                    ForEach(model.folders) { Text($0.name).tag(String?.some($0.path)) }
                }
            }
            Menu("When: \(scope.filter.when.title)") {
                Button("Any Time") { filter.wrappedValue.when = .any }
                Button("Today") { filter.wrappedValue.when = .today }
                Button("This Week") { filter.wrappedValue.when = .thisWeek }
                Button("On a Day…") { pickingDay = true }
            }
            Divider()
            Toggle("Show Hidden", isOn: filter.showsHidden)
        } label: {
            Image(systemName: scope.filter.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                .font(.system(size: 12))
                .foregroundStyle(scope.filter.isActive ? Color.accentColor : Color.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Group and filter the conversations")
        .accessibilityLabel("Group and Filter")
        .accessibilityIdentifier(ofFolder ? "history-filter-folder" : "history-filter")
    }

    @ViewBuilder
    private var content: some View {
        if ofFolder && model.panelFolder == nil {
            placeholder("Select a folder to see its conversations.")
        } else if listed == nil {
            LoadingView("Loading the history…")
        } else if let hits {
            if hits.isEmpty {
                placeholder(scope.isSearching ? "Searching…" : "No conversation holds “\(scope.query)”.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(hits) { hit in
                            ConversationRow(conversation: hit.conversation, store: store, showsFolder: !ofFolder, inSheet: ofFolder, showsAgent: true, hit: hit)
                        }
                    }
                    .padding(6)
                }
            }
        } else if groups.isEmpty {
            placeholder(
                scope.filter.isActive || !store.hidden.isEmpty && !conversations.isEmpty
                    ? "No conversation passes the filter."
                    : ofFolder ? "No agent has a conversation in this folder yet." : "No agent has a conversation on \(model.macName) yet.")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(groups) { group in
                        let expanded = !collapsed.contains(group.id)
                        GroupHeader(group: group, expanded: expanded)
                            .onTapGesture {
                                if expanded { collapsed.insert(group.id) } else { collapsed.remove(group.id) }
                            }
                        if expanded {
                            ForEach(group.conversations) { conversation in
                                ConversationRow(
                                    conversation: conversation, store: store, showsFolder: !ofFolder, inSheet: ofFolder,
                                    showsAgent: !group.id.hasPrefix("agent:"))
                            }
                        }
                    }
                    if mayHaveOlder {
                        Button("Show Older Conversations") { store.loadOlder(ofFolder: ofFolder, path: model.panelFolder, shown: listed ?? []) }
                            .buttonStyle(.plain)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Color.accentColor)
                            .padding(.leading, 27)
                            .padding(.vertical, 8)
                            .accessibilityIdentifier("history-older")
                    }
                }
                .padding(6)
            }
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

/// A group's title: an agent with its mark, a day, or the pinned ones.
private struct GroupHeader: View {
    let group: HistoryFilter.Group
    let expanded: Bool

    private var agent: String? { group.id.hasPrefix("agent:") ? String(group.id.dropFirst("agent:".count)) : nil }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 12)
            if let agent {
                Image(systemName: Theme.symbol(for: agent)).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.accent(for: agent))
            } else {
                Image(systemName: group.id == "pinned" ? "pin.fill" : "calendar").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            }
            Text(group.title).font(.system(size: 12, weight: .semibold))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.top, 9)
        .padding(.bottom, 5)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(group.title), \(group.conversations.count) conversations, \(expanded ? "expanded" : "collapsed")")
        .accessibilityAddTraits(.isButton)
    }
}

private struct ConversationRow: View {
    @EnvironmentObject private var model: AppModel
    let conversation: Conversation
    @ObservedObject var store: HistoryStore
    /// In the list of everything, each row says which folder it ran in.
    var showsFolder = false
    /// The side panel's: picked, it opens in a sheet over Sessions.
    var inSheet = false
    /// Where the rows are not under their agent, each says whose it is.
    var showsAgent = false
    /// What a search found in it.
    var hit: HistoryHit?
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
    private var isPinned: Bool { store.pinned.contains(conversation.id) }
    private var isHidden: Bool { store.hidden.contains(conversation.id) }

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

    @ViewBuilder private var menu: some View {
        Button("Resume", action: resume)
        Button("Hand Off…") { model.requestHandoff(conversation) }
        Divider()
        Button(isPinned ? "Unpin" : "Pin") { store.pin(conversation, !isPinned) }
        Button(isHidden ? "Show Again" : "Hide") { store.hide(conversation, !isHidden) }
        Divider()
        Button("Delete…", role: .destructive) { store.deleting = conversation }
    }

    private var spoken: String {
        conversation.title + (isPinned ? ", pinned" : "") + (isHidden ? ", hidden" : "") + (hit?.snippet.map { ", " + $0 } ?? "")
    }

    private var agentName: String { AgentDetector.known.first { $0.id == conversation.agent }?.name ?? conversation.agent }

    /// Whose it is, when, and where: the small line under the title.
    private var facts: some View {
        HStack(spacing: 5) {
            if showsAgent {
                Circle().fill(Theme.accent(for: conversation.agent)).frame(width: 6, height: 6)
                Text(agentName).lineLimit(1)
                Text("·")
            }
            Text(when)
            if let hit, hit.count > 1 { Text("· \(hit.count) places") }
            if isHidden { Text("· hidden") }
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

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if isPinned { Image(systemName: "pin.fill").font(.system(size: 8.5)).foregroundStyle(.orange) }
                    Text(conversation.title)
                        .font(.system(size: 12))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(isHidden ? .secondary : .primary)
                }
                if let snippet = hit?.snippet {
                    Text(snippet).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                facts
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
        .contextMenu { menu }
        .help(tip)
        // The row says what it is and offers what the middle does as its actions.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
        .accessibilityIdentifier("conversation-" + conversation.sessionID)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { pick() }
        .accessibilityAction(named: "Resume") { resume() }
        .accessibilityAction(named: "Hand Off") { model.requestHandoff(conversation) }
        .accessibilityAction(named: isPinned ? "Unpin" : "Pin") { store.pin(conversation, !isPinned) }
        .accessibilityAction(named: isHidden ? "Show Again" : "Hide") { store.hide(conversation, !isHidden) }
        .accessibilityAction(named: "Delete") { store.deleting = conversation }
    }
}

/// The two questions before a conversation is deleted (#46), over the
/// whole window: asked from a row's menu or from the conversation itself.
struct DeleteConversationQuestions: ViewModifier {
    @ObservedObject var store: HistoryStore

    private func question(_ conversation: Conversation?, again: Bool) -> DeleteConversationQuestion? {
        conversation.map { DeleteConversationQuestion($0, agentName: AgentDetector.known.first { $0.id == conversation?.agent }?.name ?? $0.agent, again: again) }
    }

    func body(content: Content) -> some View {
        let first = question(store.deleting, again: false)
        let second = question(store.deletingAgain, again: true)
        content
            .confirmationDialog(first?.title ?? "", isPresented: Binding(get: { store.deleting != nil }, set: { if !$0 { store.deleting = nil } }), titleVisibility: .visible) {
                Button(first?.confirm ?? "Delete…", role: .destructive) { store.firstQuestionConfirmed() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(first?.message ?? "")
            }
            .confirmationDialog(
                second?.title ?? "", isPresented: Binding(get: { store.deletingAgain != nil }, set: { if !$0 { store.deletingAgain = nil } }), titleVisibility: .visible
            ) {
                Button(second?.confirm ?? "Delete", role: .destructive) { store.deleteConfirmed() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(second?.message ?? "")
            }
    }
}
