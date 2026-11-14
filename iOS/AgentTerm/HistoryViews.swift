import AgentTermProtocol
import AgentTermTerminal
import SwiftUI

/// A conversation read before it is resumed (#46): what its agent's file
/// tells about it, and what was asked, answered and run in it. As on the Mac.
struct TranscriptScreen: View {
    @EnvironmentObject private var model: PhoneModel
    let conversation: Conversation
    /// Closes the sheet this is in.
    let close: () -> Void
    @State private var copied = false
    @State private var deleting: Conversation?

    private var agentName: String { model.agents.first { $0.id == conversation.agent }?.name ?? conversation.agent }
    private var isPinned: Bool { model.pinnedConversations.contains(conversation.id) }
    private var isHidden: Bool { model.hiddenConversations.contains(conversation.id) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                switch model.conversationDetails[conversation.id] {
                case .none:
                    LoadingView("Reading the conversation…").frame(maxWidth: .infinity).padding(.top, 60)
                case .some(.none):
                    Text("This conversation is no longer among its agent's files.").font(.callout).foregroundStyle(.secondary)
                case .some(.some(let details)):
                    read(details)
                }
            }
            .padding(16)
        }
        .background(Palette.canvas.ignoresSafeArea())
        .navigationTitle("Transcript")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        model.markConversation(conversation, pinned: !isPinned)
                    } label: {
                        Label(isPinned ? "Unpin" : "Pin", systemImage: isPinned ? "pin.slash" : "pin")
                    }
                    Button {
                        model.markConversation(conversation, hidden: !isHidden)
                    } label: {
                        Label(isHidden ? "Show Again in the List" : "Hide from the List", systemImage: isHidden ? "eye" : "eye.slash")
                    }
                    Divider()
                    Button(role: .destructive) {
                        deleting = conversation
                    } label: {
                        Label("Delete…", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("More")
                .accessibilityIdentifier("conversation-more")
            }
        }
        .task(id: conversation.id) { model.readConversation(conversation) }
        .modifier(DeleteConversationAsk(asked: $deleting) { close() })
        .onChange(of: model.exportedTranscript) { _, path in
            // Written out as a file on the Mac: opened as any file.
            guard let path else { return }
            model.exportedTranscript = nil
            close()
            model.path.append(Route.document(path: path))
        }
    }

    @ViewBuilder
    private func read(_ details: ConversationDetails) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(details.facts, id: \.name) { fact in
                HStack(alignment: .firstTextBaseline) {
                    Text(fact.name).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                    Text(fact.value).textSelection(.enabled)
                    Spacer(minLength: 0)
                }
            }
            if let files = details.files, !files.isEmpty {
                DisclosureGroup("\(files.count) \(files.count == 1 ? "file" : "files") changed") {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(files, id: \.self) { Text($0).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.top, 4)
            }
        }
        .font(.footnote)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.panel))
        .accessibilityIdentifier("conversation-facts")
        HStack(spacing: 14) {
            Button {
                UIPasteboard.general.string = details.markdown(agentName: agentName)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
            } label: {
                Label(copied ? "Copied" : "Copy Transcript", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .accessibilityIdentifier("transcript-copy")
            Button {
                model.exportConversation(conversation)
            } label: {
                Label("Open as a File", systemImage: "doc.text")
            }
            .accessibilityIdentifier("transcript-open")
        }
        .font(.footnote.weight(.medium))
        if details.omitted > 0 {
            Text("\(details.omitted) earlier entries are left out: this is the end of a long conversation.").font(.caption).foregroundStyle(.secondary)
        }
        if details.entries.isEmpty {
            Text("Its agent's file holds nothing that was said.").font(.callout).foregroundStyle(.secondary)
        }
        LazyVStack(alignment: .leading, spacing: 10) {
            ForEach(details.entries) { entry in entryView(entry) }
        }
        .accessibilityIdentifier("transcript")
    }

    @ViewBuilder
    private func entryView(_ entry: TranscriptEntry) -> some View {
        switch entry.kind {
        case .tool:
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "wrench.and.screwdriver").font(.caption2).foregroundStyle(.tertiary)
                Text(entry.tool ?? "Tool").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Text(entry.text).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.leading, 10)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(entry.tool ?? "Tool"): \(entry.text)")
        case .user, .agent:
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Circle().fill(entry.kind == .user ? Palette.tint : AgentStyle.accent(for: conversation.agent)).frame(width: 7, height: 7)
                    Text(entry.kind == .user ? "You" : agentName).font(.caption.weight(.semibold))
                    if let at = entry.at { Text(at.formatted(date: .omitted, time: .shortened)).font(.caption2).foregroundStyle(.tertiary) }
                }
                Text(entry.text).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(entry.kind == .user ? 0.09 : 0.04)))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(entry.kind == .user ? "You" : agentName): \(entry.text)")
        }
    }
}

/// The two questions before a conversation is deleted (#46), one after
/// the other, in the same words as on the Mac.
struct DeleteConversationAsk: ViewModifier {
    @EnvironmentObject private var model: PhoneModel
    @Binding var asked: Conversation?
    /// Once it was sent to be deleted.
    var done: () -> Void = {}
    @State private var again: Conversation?

    private func question(_ conversation: Conversation?, again: Bool) -> DeleteConversationQuestion? {
        conversation.map { asked in DeleteConversationQuestion(asked, agentName: model.agents.first { $0.id == asked.agent }?.name ?? asked.agent, again: again) }
    }

    func body(content: Content) -> some View {
        let first = question(asked, again: false)
        let second = question(again, again: true)
        content
            .confirmationDialog(first?.title ?? "", isPresented: Binding(get: { asked != nil }, set: { if !$0 { asked = nil } }), titleVisibility: .visible) {
                Button(first?.confirm ?? "Delete…", role: .destructive) {
                    let conversation = asked
                    // The second question comes once the first has left the screen.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { again = conversation }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(first?.message ?? "")
            }
            .confirmationDialog(second?.title ?? "", isPresented: Binding(get: { again != nil }, set: { if !$0 { again = nil } }), titleVisibility: .visible) {
                Button(second?.confirm ?? "Delete", role: .destructive) {
                    if let again { model.deleteConversation(again) }
                    done()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(second?.message ?? "")
            }
    }
}

/// History's search field and its menu of groups and filters, above the list.
struct HistoryControls: View {
    @EnvironmentObject private var model: PhoneModel
    @Binding var query: String
    @Binding var filter: HistoryFilter
    /// The folder the list is of; nil for every conversation on the Mac.
    let folder: String?
    @State private var pickingDay = false
    @State private var day = Date()

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search titles and what was said", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .accessibilityIdentifier("history-search")
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Clear Search")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.panel))
            Menu {
                Picker("Group", selection: $filter.grouping) {
                    ForEach(HistoryFilter.Grouping.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Agent", selection: $filter.agent) {
                    Text("All Agents").tag(String?.none)
                    ForEach(model.agents) { Text($0.name).tag(String?.some($0.id)) }
                }
                .pickerStyle(.menu)
                if folder == nil {
                    Picker("Folder", selection: $filter.folder) {
                        Text("All Folders").tag(String?.none)
                        ForEach(model.folders, id: \.self) { Text(($0 as NSString).lastPathComponent).tag(String?.some($0)) }
                    }
                    .pickerStyle(.menu)
                }
                Menu("When: \(filter.when.title)") {
                    Button("Any Time") { filter.when = .any }
                    Button("Today") { filter.when = .today }
                    Button("This Week") { filter.when = .thisWeek }
                    Button("On a Day…") { pickingDay = true }
                }
                Toggle("Show Hidden", isOn: $filter.showsHidden)
                if filter.isActive {
                    Button("Clear Filters") {
                        filter.agent = nil
                        filter.folder = nil
                        filter.when = .any
                    }
                }
            } label: {
                Image(systemName: filter.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    .font(.system(size: 22))
            }
            .accessibilityLabel("Group and Filter")
            .accessibilityIdentifier("history-filter")
        }
        .sheet(isPresented: $pickingDay) {
            NavigationStack {
                DatePicker("Day", selection: $day, in: ...Date(), displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .padding()
                    .navigationTitle("Conversations of a Day")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { pickingDay = false } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Show") {
                                filter.when = .day(day)
                                pickingDay = false
                            }
                        }
                    }
            }
            .presentationDetents([.medium])
            .preferredColorScheme(.dark)
        }
    }
}
