import AgenttyProtocol
import AgenttyTerminal
import SwiftUI

/// A folder's git changes and the conversations agents had in it: what the
/// Mac shows in its side panel.
struct FolderScreen: View {
    @EnvironmentObject private var model: PhoneModel
    let folder: String
    @AppStorage("folderTab") private var tab = "git"

    var body: some View {
        VStack(spacing: 0) {
            Picker("Show", selection: $tab) {
                Text("Git").tag("git")
                Text("History").tag("history")
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            if tab == "history" {
                HistoryList(folder: folder)
            } else {
                ChangesList(folder: folder)
            }
        }
        .background(Palette.canvas.ignoresSafeArea())
        .navigationTitle((folder as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: Git

private struct ChangesList: View {
    @EnvironmentObject private var model: PhoneModel
    let folder: String

    var body: some View {
        Group {
            if let diff = model.diffs[folder] {
                if !diff.isRepository {
                    Placeholder(text: "This folder is not a git repository.")
                } else if diff.files.isEmpty {
                    Placeholder(text: "No uncommitted changes.")
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            HStack(spacing: 8) {
                                if let branch = diff.branch {
                                    Label(branch, systemImage: "arrow.triangle.branch")
                                        .font(.footnote.weight(.medium))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                DiffCount(added: diff.files.reduce(0) { $0 + $1.added }, deleted: diff.files.reduce(0) { $0 + $1.deleted })
                            }
                            .padding(.horizontal, 6)
                            .padding(.bottom, 10)
                            VStack(spacing: 0) {
                                ForEach(diff.files) { file in
                                    NavigationLink(value: Route.file(folder: folder, file: file.path)) {
                                        FileRow(file: file)
                                    }
                                    .buttonStyle(.plain)
                                    if file.id != diff.files.last?.id {
                                        Palette.hairline.frame(height: 1).padding(.leading, 38)
                                    }
                                }
                            }
                            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.panel))
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 24)
                    }
                    .refreshable { model.loadDiff(folder) }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { model.loadDiff(folder) }
    }
}

private struct FileRow: View {
    let file: FileDiff

    var body: some View {
        HStack(spacing: 10) {
            Text(file.isUntracked ? "U" : "M")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(file.isUntracked ? Palette.added : Color.orange)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text((file.path as NSString).lastPathComponent)
                    .font(.body)
                    .lineLimit(1)
                let directory = (file.path as NSString).deletingLastPathComponent
                if !directory.isEmpty {
                    Text(directory)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: 8)
            DiffCount(added: file.added, deleted: file.deleted)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }
}

private struct DiffCount: View {
    let added: Int
    let deleted: Int

    var body: some View {
        HStack(spacing: 6) {
            Text("+\(added)").foregroundStyle(Palette.added)
            Text("−\(deleted)").foregroundStyle(Palette.danger)
        }
        .font(.system(size: 12, weight: .medium, design: .monospaced))
    }
}

/// One file's diff. Long lines scroll sideways.
struct PatchScreen: View {
    @EnvironmentObject private var model: PhoneModel
    let folder: String
    let file: String

    private var key: String { PhoneModel.patchKey(folder: folder, file: file) }

    var body: some View {
        Group {
            if let loaded = model.patches[key] {
                if let diff = loaded {
                    let lines = diff.patch.split(separator: "\n", omittingEmptySubsequences: false).prefix(4000)
                        .map { $0.replacingOccurrences(of: "\t", with: "    ") }
                    ScrollView([.vertical, .horizontal]) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(lines.enumerated()), id: \.offset) { line in
                                Text(line.element.isEmpty ? " " : line.element)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(foreground(line.element))
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 1)
                                    .frame(minWidth: UIScreen.main.bounds.width, alignment: .leading)
                                    .background(background(line.element))
                            }
                        }
                        .padding(.vertical, 8)
                    }
                } else {
                    Placeholder(text: "This file no longer has changes.")
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Palette.canvas.ignoresSafeArea())
        .navigationTitle((file as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { model.loadPatch(folder: folder, file: file) }
    }

    private func foreground(_ line: String) -> Color {
        if line.hasPrefix("@@") { return Color(red: 0.55, green: 0.67, blue: 0.98) }
        if line.hasPrefix("+") { return Palette.added }
        if line.hasPrefix("-") { return Palette.danger }
        return Color.white.opacity(0.75)
    }

    private func background(_ line: String) -> Color {
        if line.hasPrefix("@@") { return Color.white.opacity(0.04) }
        if line.hasPrefix("+") { return Palette.added.opacity(0.10) }
        if line.hasPrefix("-") { return Palette.danger.opacity(0.10) }
        return .clear
    }
}

// MARK: History

/// Conversations of one folder, or of the whole Mac when `folder` is nil,
/// one section per agent.
struct HistoryList: View {
    @EnvironmentObject private var model: PhoneModel
    let folder: String?
    @AppStorage("historyShowsAll") private var storedShowsAll = false
    @State private var selected: Conversation?

    /// With no folder there is only "everything" to show.
    private var showsAll: Bool { folder == nil || storedShowsAll }
    private var key: String { showsAll ? "" : (folder ?? "") }

    private var sections: [(id: String, name: String, conversations: [Conversation])] {
        let all = model.histories[key] ?? []
        return model.agents.compactMap { agent in
            let own = all.filter { $0.agent == agent.id }
            return own.isEmpty ? nil : (agent.id, agent.name, own)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if folder != nil {
                HStack(spacing: 10) {
                    Picker("Scope", selection: $storedShowsAll) {
                        Text("This Folder").tag(false)
                        Text("All").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    if let count = model.histories[key]?.count {
                        Text(count == 1 ? "1 conversation" : "\(count) conversations")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            }
            if let history = model.histories[key] {
                if history.isEmpty {
                    Placeholder(text: showsAll ? "No agent has a conversation on this Mac yet." : "No agent has a conversation in this folder yet.")
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            ForEach(sections, id: \.id) { section in
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack(spacing: 7) {
                                        Image(systemName: AgentStyle.symbol(for: section.id))
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(AgentStyle.accent(for: section.id))
                                        Text(section.name).font(.subheadline.weight(.semibold))
                                    }
                                    .padding(.horizontal, 6)
                                    VStack(spacing: 0) {
                                        ForEach(section.conversations) { conversation in
                                            Button { selected = conversation } label: {
                                                ConversationRow(conversation: conversation, showsFolder: showsAll)
                                            }
                                            .buttonStyle(.plain)
                                            if conversation.id != section.conversations.last?.id {
                                                Palette.hairline.frame(height: 1).padding(.leading, 14)
                                            }
                                        }
                                    }
                                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.panel))
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 24)
                    }
                    .refreshable { load() }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear(perform: load)
        .onChange(of: storedShowsAll) { _, _ in load() }
        .sheet(item: $selected) { conversation in
            ConversationSheet(conversation: conversation)
                .environmentObject(model)
                .preferredColorScheme(.dark)
        }
    }

    private func load() {
        model.loadHistory(showsAll ? nil : folder)
    }
}

private struct ConversationRow: View {
    let conversation: Conversation
    let showsFolder: Bool

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(conversation.title)
                    .font(.body)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 5) {
                    Text(relativeTime(conversation.updatedAt))
                    if showsFolder {
                        Text("·")
                        Image(systemName: "folder").font(.system(size: 10))
                        Text((conversation.cwd as NSString).lastPathComponent).lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }
}

private func relativeTime(_ date: Date) -> String {
    if date.timeIntervalSinceNow > -60 { return "now" }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: date, relativeTo: Date())
}

/// What can be done with a past conversation: continue it in its own agent,
/// or hand its work to another one.
private struct ConversationSheet: View {
    @EnvironmentObject private var model: PhoneModel
    @Environment(\.dismiss) private var dismiss
    let conversation: Conversation
    @AppStorage("handoffTarget") private var rememberedTarget = ""
    @State private var targetID = ""
    @State private var note = ""
    /// The prompt the receiving agent starts with, as the user left it.
    @State private var prompt = ""

    private var promptIsEdited: Bool { model.handoffPlan.map { prompt != $0.prompt } ?? false }
    private var targets: [AgentInfo] { model.handoffTargets(from: conversation.agent) }
    private var target: AgentInfo? { targets.first { $0.id == targetID } ?? targets.first }
    private var sourceName: String { model.agents.first { $0.id == conversation.agent }?.name ?? conversation.agent }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 7) {
                            Circle().fill(AgentStyle.accent(for: conversation.agent)).frame(width: 8, height: 8)
                            Text(sourceName).font(.subheadline.weight(.semibold))
                            Text("· \(relativeTime(conversation.updatedAt))").font(.subheadline).foregroundStyle(.secondary)
                        }
                        Text(conversation.title).font(.title3.weight(.semibold))
                        Label((conversation.cwd as NSString).abbreviatingWithTildeInPath, systemImage: "folder")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }

                    Button {
                        model.resume(conversation)
                        dismiss()
                    } label: {
                        Label("Resume in \(sourceName)", systemImage: "play.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AgentStyle.accent(for: conversation.agent))

                    if !targets.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Hand off to another agent")
                                .font(.headline)
                            Text("It gets the conversation so far and the state of the working tree, and continues in a new session. For when \(sourceName) is out of quota.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(targets) { agent in
                                        let selected = agent.id == target?.id
                                        Button { targetID = agent.id } label: {
                                            HStack(spacing: 6) {
                                                Image(systemName: AgentStyle.symbol(for: agent.id))
                                                    .font(.system(size: 12, weight: .semibold))
                                                    .foregroundStyle(AgentStyle.accent(for: agent.id))
                                                Text(agent.name).font(.system(size: 14, weight: .medium))
                                            }
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 8)
                                            .background(Capsule().fill(selected ? AgentStyle.accent(for: agent.id).opacity(0.2) : Palette.raised))
                                            .overlay(Capsule().strokeBorder(selected ? AgentStyle.accent(for: agent.id).opacity(0.8) : Palette.hairline))
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityAddTraits(selected ? .isSelected : [])
                                    }
                                }
                            }
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("Prompt \(target?.name ?? "the agent") starts with")
                                        .font(.footnote.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    if promptIsEdited {
                                        Button("Reset") { prompt = model.handoffPlan?.prompt ?? "" }
                                            .font(.footnote.weight(.semibold))
                                    }
                                }
                                if model.handoffPlan == nil {
                                    ProgressView()
                                        .frame(maxWidth: .infinity, minHeight: 60)
                                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.raised))
                                } else {
                                    TextField("Prompt", text: $prompt, axis: .vertical)
                                        .lineLimit(2...10)
                                        .font(.callout)
                                        .padding(12)
                                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.raised))
                                        .accessibilityIdentifier("handoff-prompt")
                                }
                                Text("It can be edited. Keep the line that names the handoff file.")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Your instructions (optional)")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                TextField("What to focus on, what to leave alone", text: $note, axis: .vertical)
                                    .lineLimit(3...8)
                                    .padding(12)
                                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.raised))
                                Text("Added after the prompt.")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            Button {
                                guard let target else { return }
                                rememberedTarget = target.id
                                model.handoff(conversation, to: target, prompt: prompt, note: note)
                                dismiss()
                            } label: {
                                Label("Hand Off to \(target?.name ?? "Agent")", systemImage: "arrowshape.turn.up.right.fill")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 6)
                            }
                            .buttonStyle(.bordered)
                            .disabled(target == nil || model.handoffPlan == nil)
                        }
                    }
                }
                .padding(20)
            }
            .background(Palette.canvas.ignoresSafeArea())
            .navigationTitle("Conversation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .onAppear {
                targetID = targets.contains { $0.id == rememberedTarget } ? rememberedTarget : (targets.first?.id ?? "")
                if !targets.isEmpty { model.requestHandoffPlan(for: conversation) }
            }
            .onChange(of: model.handoffPlan) { _, plan in
                if let plan { prompt = plan.prompt }
            }
        }
    }
}

struct Placeholder: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
