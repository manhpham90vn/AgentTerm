import AgentTermProtocol
import AgentTermTerminal
import SwiftUI

/// A conversation read before it is resumed (#46): what its agent's file
/// tells about it, and what was asked, answered and run in it.
struct ConversationTranscript: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var store: HistoryStore
    let conversation: Conversation
    @State private var copied = false
    @State private var showsFiles = false

    private var agentName: String { model.agents.first { $0.id == conversation.agent }?.name ?? conversation.agent }
    private var isPinned: Bool { store.pinned.contains(conversation.id) }
    private var isHidden: Bool { store.hidden.contains(conversation.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Text("Transcript").font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
                Button(isPinned ? "Unpin" : "Pin") { store.pin(conversation, !isPinned) }
                    .accessibilityIdentifier("conversation-pin")
                Menu {
                    Button(isHidden ? "Show Again in the List" : "Hide from the List") { store.hide(conversation, !isHidden) }
                    Divider()
                    Button("Delete…", role: .destructive) {
                        // Asked over the window, not over the sheet this may be in.
                        model.panelConversation = nil
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { store.deleting = conversation }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("More")
                .accessibilityIdentifier("conversation-more")
            }
            .controlSize(.small)
            switch store.details[conversation.id] {
            case .none:
                LoadingView("Reading the conversation…").frame(height: 80)
            case .some(.none):
                Text("This conversation is no longer among its agent's files.").font(.system(size: 12)).foregroundStyle(.secondary)
            case .some(.some(let details)):
                read(details)
            }
        }
        .task(id: conversation.id) { store.read(conversation) }
    }

    @ViewBuilder
    private func read(_ details: ConversationDetails) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 4) {
            ForEach(details.facts, id: \.name) { fact in
                GridRow {
                    Text(fact.name).foregroundStyle(.secondary)
                    Text(fact.value).textSelection(.enabled)
                }
            }
        }
        .font(.system(size: 12))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("conversation-facts")
        if let files = details.files, !files.isEmpty {
            DisclosureGroup(isExpanded: $showsFiles) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(files, id: \.self) { file in
                        Text(file).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head).textSelection(.enabled)
                    }
                }
                .padding(.top, 4)
            } label: {
                Text("\(files.count) \(files.count == 1 ? "file" : "files") changed").font(.system(size: 12))
            }
        }
        HStack(spacing: 10) {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(details.markdown(agentName: agentName), forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
            } label: {
                Label(copied ? "Copied" : "Copy Transcript", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .accessibilityIdentifier("transcript-copy")
            Button {
                store.export(conversation)
            } label: {
                Label("Open as a File", systemImage: "doc.text")
            }
            .help("Write it out as a Markdown file and open it")
            .accessibilityIdentifier("transcript-open")
        }
        .controlSize(.small)
        if details.omitted > 0 {
            Text("\(details.omitted) earlier entries are left out: this is the end of a long conversation.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        if details.entries.isEmpty {
            Text("Its agent's file holds nothing that was said.").font(.system(size: 12)).foregroundStyle(.secondary)
        }
        LazyVStack(alignment: .leading, spacing: 10) {
            ForEach(details.entries) { entry in
                TranscriptEntryView(entry: entry, agent: conversation.agent, agentName: agentName)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("transcript")
    }
}

/// One thing said or run.
private struct TranscriptEntryView: View {
    let entry: TranscriptEntry
    let agent: String
    let agentName: String

    var body: some View {
        switch entry.kind {
        case .tool:
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "wrench.and.screwdriver").font(.system(size: 9.5)).foregroundStyle(.tertiary)
                Text(entry.tool ?? "Tool").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Text(entry.text).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail).textSelection(.enabled)
            }
            .padding(.leading, 12)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(entry.tool ?? "Tool"): \(entry.text)")
        case .user, .agent:
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Circle().fill(entry.kind == .user ? Color.accentColor : Theme.accent(for: agent)).frame(width: 7, height: 7)
                    Text(entry.kind == .user ? "You" : agentName).font(.system(size: 11.5, weight: .semibold))
                    if let at = entry.at {
                        Text(at.formatted(date: .omitted, time: .shortened)).font(.system(size: 10.5)).foregroundStyle(.tertiary)
                    }
                }
                Text(entry.text)
                    .font(.system(size: 12.5))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 13)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(entry.kind == .user ? 0.07 : 0.03)))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(entry.kind == .user ? "You" : agentName): \(entry.text)")
        }
    }
}
