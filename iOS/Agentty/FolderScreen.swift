import AgenttyProtocol
import AgenttyTerminal
import SwiftUI

/// A folder's git changes, the conversations agents had in it and its
/// files: what the Mac shows in its side panel.
struct FolderScreen: View {
    @EnvironmentObject private var model: PhoneModel
    let folder: String
    @AppStorage("folderTab") private var tab = "git"

    var body: some View {
        VStack(spacing: 0) {
            Picker("Show", selection: $tab) {
                Text("Git").tag("git")
                Text("History").tag("history")
                Text("Files").tag("files")
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            if tab == "history" {
                HistoryList(folder: folder)
            } else if tab == "files" {
                FilesList(folder: folder)
            } else {
                ChangesList(folder: folder)
            }
        }
        .background(Palette.canvas.ignoresSafeArea())
        .navigationTitle((folder as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if model.folders.contains(folder) {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(role: .destructive) {
                            model.removeFolder(folder)
                            if !model.path.isEmpty { model.path.removeLast() }
                        } label: {
                            Label("Remove from List", systemImage: "minus.circle")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
    }
}

// MARK: Git

private struct ChangesList: View {
    @EnvironmentObject private var model: PhoneModel
    let folder: String
    /// "list" shows every file in one flat list, "tree" groups them by folder.
    @AppStorage("diffViewMode") private var viewMode = "list"
    @State private var collapsedFolders: Set<String> = []

    private var isTree: Bool { viewMode == "tree" }

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
                                Button { viewMode = isTree ? "list" : "tree" } label: {
                                    Image(systemName: isTree ? "list.bullet" : "list.bullet.indent")
                                        .font(.system(size: 15, weight: .semibold))
                                        .padding(.leading, 6)
                                }
                                .accessibilityLabel(isTree ? "Show as a flat list" : "Group by folder")
                            }
                            .padding(.horizontal, 6)
                            .padding(.bottom, 10)
                            CommitBox(folder: folder, stagedCount: diff.staged.count)
                                .padding(.bottom, 14)
                            if !diff.staged.isEmpty {
                                SectionHeader(title: "Staged", count: diff.staged.count, action: "Unstage All") { model.unstage([], in: folder) }
                                rows(diff.staged)
                            }
                            if !diff.unstaged.isEmpty {
                                SectionHeader(title: "Changes", count: diff.unstaged.count, action: "Stage All") { model.stage([], in: folder) }
                                    .padding(.top, diff.staged.isEmpty ? 0 : 16)
                                rows(diff.unstaged)
                            }
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

    /// The files of one of the two lists, flat or grouped by folder.
    private func rows(_ files: [FileDiff]) -> some View {
        VStack(spacing: 0) {
            if isTree {
                let rows = DiffTree.rows(for: files, collapsed: collapsedFolders)
                ForEach(rows) { row in
                    switch row.kind {
                    case .folder(let expanded):
                        Button {
                            if expanded { collapsedFolders.insert(row.id) } else { collapsedFolders.remove(row.id) }
                        } label: {
                            TreeFolderRow(row: row, expanded: expanded)
                        }
                        .buttonStyle(.plain)
                    case .file(let file):
                        fileRow(file, showsDirectory: false, depth: row.depth)
                    }
                    if row.id != rows.last?.id {
                        Palette.hairline.frame(height: 1).padding(.leading, 38 + CGFloat(row.depth) * treeIndent)
                    }
                }
            } else {
                ForEach(files) { file in
                    fileRow(file, showsDirectory: true, depth: 0)
                    if file.id != files.last?.id {
                        Palette.hairline.frame(height: 1).padding(.leading, 38)
                    }
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.panel))
    }

    /// A file: tapping it shows its diff, the button at its end stages or unstages it.
    private func fileRow(_ file: FileDiff, showsDirectory: Bool, depth: Int) -> some View {
        HStack(spacing: 0) {
            NavigationLink(value: Route.file(folder: folder, file: file.path, staged: file.isStaged)) {
                FileRow(file: file, showsDirectory: showsDirectory, depth: depth)
            }
            .buttonStyle(.plain)
            Button {
                if file.isStaged { model.unstage([file.path], in: folder) } else { model.stage([file.path], in: folder) }
            } label: {
                Image(systemName: file.isStaged ? "minus.circle" : "plus.circle")
                    .font(.system(size: 20))
                    .foregroundStyle(file.isStaged ? Color.secondary : Palette.tint)
                    .frame(width: 46, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel((file.isStaged ? "Unstage " : "Stage ") + (file.path as NSString).lastPathComponent)
        }
    }
}

/// Where the commit message is written and the commit is made.
private struct CommitBox: View {
    @EnvironmentObject private var model: PhoneModel
    let folder: String
    let stagedCount: Int

    private var message: Binding<String> {
        Binding(get: { model.commitDrafts[folder] ?? "" }, set: { model.commitDrafts[folder] = $0 })
    }

    private var isCommitting: Bool { model.committing == folder }

    private var canCommit: Bool {
        stagedCount > 0 && model.committing == nil && !message.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 8) {
            TextField("Commit message", text: message, axis: .vertical)
                .lineLimit(1...5)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.panel))
                .accessibilityIdentifier("commit-message")
            Button { model.commit(in: folder) } label: {
                HStack(spacing: 8) {
                    if isCommitting { ProgressView().controlSize(.small) }
                    Text(stagedCount > 0 ? "Commit \(stagedCount) \(stagedCount == 1 ? "File" : "Files")" : "Stage Changes to Commit")
                        .font(.body.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canCommit)
            .accessibilityIdentifier("commit")
        }
    }
}

/// Title of one of the two lists, with a button that moves every file to the other.
private struct SectionHeader: View {
    let title: String
    let count: Int
    let action: String
    let perform: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
            Spacer()
            Button(action, action: perform)
                .font(.footnote.weight(.medium))
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 8)
    }
}

/// Width of one level of nesting in the folder tree.
private let treeIndent: CGFloat = 16

private struct TreeFolderRow: View {
    let row: DiffTreeRow
    let expanded: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Image(systemName: "folder.fill")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Text(row.name)
                .font(.body.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            DiffCount(added: row.added, deleted: row.deleted).opacity(0.75)
        }
        .padding(.leading, 12 + CGFloat(row.depth) * treeIndent)
        .padding(.trailing, 12)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .accessibilityLabel("\(row.name), folder, \(expanded ? "expanded" : "collapsed")")
    }
}

private struct FileRow: View {
    let file: FileDiff
    /// The flat list shows where each file lives; the tree already does.
    var showsDirectory = true
    var depth = 0

    var body: some View {
        HStack(spacing: 10) {
            Text(file.marker)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(file.isUntracked || file.status == .added ? Palette.added : (file.status == .deleted ? Palette.danger : Color.orange))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text((file.path as NSString).lastPathComponent)
                    .font(.body)
                    .lineLimit(1)
                let directory = (file.path as NSString).deletingLastPathComponent
                if showsDirectory, !directory.isEmpty {
                    Text(directory)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: 8)
            DiffCount(added: file.added, deleted: file.deleted)
        }
        .padding(.leading, 12 + CGFloat(depth) * treeIndent)
        .padding(.trailing, 2)
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
    /// The staged part of the file, or what is only in the working tree.
    let staged: Bool

    private var key: String { PhoneModel.patchKey(folder: folder, file: file, staged: staged) }

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
        .onAppear { model.loadPatch(folder: folder, file: file, staged: staged) }
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
    @State private var collapsedAgents: Set<String> = []

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
                                let expanded = !collapsedAgents.contains(section.id)
                                VStack(alignment: .leading, spacing: 8) {
                                    Button {
                                        if expanded { collapsedAgents.insert(section.id) } else { collapsedAgents.remove(section.id) }
                                    } label: {
                                        HStack(spacing: 7) {
                                            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                                                .font(.system(size: 10, weight: .bold))
                                                .foregroundStyle(.secondary)
                                            Image(systemName: AgentStyle.symbol(for: section.id))
                                                .font(.system(size: 12, weight: .semibold))
                                                .foregroundStyle(AgentStyle.accent(for: section.id))
                                            Text(section.name).font(.subheadline.weight(.semibold))
                                            Spacer(minLength: 0)
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .padding(.horizontal, 6)
                                    .accessibilityLabel("\(section.name), \(expanded ? "expanded" : "collapsed")")
                                    if expanded {
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
struct ConversationSheet: View {
    @EnvironmentObject private var model: PhoneModel
    @Environment(\.dismiss) private var dismiss
    let conversation: Conversation
    /// False when the conversation belongs to a session that is running:
    /// there is nothing to resume, only to hand off.
    var showsResume = true
    @State private var copied = false
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

                    if showsResume {
                        VStack(spacing: 10) {
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
                            Button {
                                UIPasteboard.general.string = conversation.resumeCommand
                                copied = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                            } label: {
                                Label(copied ? "Copied" : "Copy Resume Command", systemImage: copied ? "checkmark" : "doc.on.doc")
                                    .font(.footnote.weight(.medium))
                            }
                        }
                    }

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
            .navigationTitle(showsResume ? "Conversation" : "Hand Off")
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
