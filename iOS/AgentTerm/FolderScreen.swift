import AgentTermProtocol
import AgentTermTerminal
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
        .toolbar(.hidden, for: .tabBar)
        .keyboardDismissButton()
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
    /// The changes the user is asked about before they are discarded (#39).
    @State private var discarding: [FileDiff]?

    private var isTree: Bool { viewMode == "tree" }
    private var question: DiscardQuestion? { discarding.map(DiscardQuestion.init(files:)) }

    /// Discards what was asked about. Every change is asked for as such,
    /// so that one made since is not left out.
    private func discardConfirmed() {
        guard let asked = discarding else { return }
        discarding = nil
        let all = asked.count > 1 && asked.count == (model.diffs[folder]?.unstaged.count ?? -1)
        model.discard(all ? [] : asked.map(\.path), in: folder)
    }

    var body: some View {
        Group {
            if let diff = model.diffs[folder] {
                if !diff.isRepository {
                    Placeholder(text: "This folder is not a git repository.")
                } else if diff.files.isEmpty {
                    // Nothing to commit, but a commit that was just made is
                    // what there is to push, and the branch can be another.
                    ScrollView {
                        VStack(spacing: 0) {
                            BranchButton(folder: folder, branch: diff.branch)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 6)
                                .padding(.bottom, 10)
                            if diff.canPush || diff.canPull { SyncBar(folder: folder, diff: diff) }
                            Text("No uncommitted changes.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .padding(.top, 48)
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 24)
                    }
                    .refreshable { model.loadDiff(folder) }
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            HStack(spacing: 8) {
                                BranchButton(folder: folder, branch: diff.branch)
                                Spacer()
                                DiffCount(added: diff.files.reduce(0) { $0 + $1.added }, deleted: diff.files.reduce(0) { $0 + $1.deleted })
                                Button {
                                    model.setDisplay { $0.changesView = isTree ? "list" : "tree" }
                                } label: {
                                    Image(systemName: isTree ? "list.bullet" : "list.bullet.indent")
                                        .font(.system(size: 15, weight: .semibold))
                                        .padding(.leading, 6)
                                }
                                .accessibilityLabel(isTree ? "Show as a flat list" : "Group by folder")
                            }
                            .padding(.horizontal, 6)
                            .padding(.bottom, 10)
                            if diff.canPush || diff.canPull {
                                SyncBar(folder: folder, diff: diff)
                                    .padding(.bottom, 12)
                            }
                            CommitBox(folder: folder, stagedCount: diff.staged.count)
                                .padding(.bottom, 14)
                            if !diff.staged.isEmpty {
                                SectionHeader(title: "Staged", count: diff.staged.count, action: "Unstage All") { model.unstage([], in: folder) }
                                rows(diff.staged)
                            }
                            if !diff.unstaged.isEmpty {
                                SectionHeader(
                                    title: "Changes", count: diff.unstaged.count, action: "Stage All", second: ("Discard All…", { discarding = diff.unstaged })
                                ) { model.stage([], in: folder) }
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
                LoadingView("Loading the changes…") { model.loadDiff(folder) }
            }
        }
        .onAppear { model.loadDiff(folder) }
        // Asked first: what is discarded does not come back (#39).
        .confirmationDialog(
            question?.title ?? "", isPresented: Binding(get: { discarding != nil }, set: { if !$0 { discarding = nil } }), titleVisibility: .visible
        ) {
            Button(question?.confirm ?? "Discard", role: .destructive) { discardConfirmed() }
            Button("Cancel", role: .cancel) { discarding = nil }
        } message: {
            Text(question?.message ?? "")
        }
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
            .contextMenu {
                Button(file.isStaged ? "Unstage" : "Stage") {
                    if file.isStaged { model.unstage([file.path], in: folder) } else { model.stage([file.path], in: folder) }
                }
                if !file.isStaged {
                    // Asked about first: what is discarded does not come back.
                    Button(role: .destructive) {
                        discarding = [file]
                    } label: {
                        Label(file.isUntracked ? "Move to the Trash…" : "Discard Changes…", systemImage: file.isUntracked ? "trash" : "arrow.uturn.backward")
                    }
                    .accessibilityLabel(file.discardLabel)
                }
            }
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

/// Push and pull for the branch that is checked out, with how far it is
/// from the branch it follows. git runs on the Mac.
private struct SyncBar: View {
    @EnvironmentObject private var model: PhoneModel
    let folder: String
    let diff: DiffSnapshot
    @State private var confirmingFirstPush = false

    private var busy: String? { model.syncing[folder] }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                button("Fetch", symbol: "arrow.triangle.2.circlepath", count: 0, working: busy == "fetch") { model.fetch(in: folder) }
                    .accessibilityIdentifier("git-fetch")
                if diff.canPull {
                    button("Pull", symbol: "arrow.down", count: diff.behind ?? 0, working: busy == "pull") { model.pull(in: folder) }
                        .accessibilityIdentifier("git-pull")
                }
                if diff.canPush {
                    button(diff.upstream == nil ? "Publish Branch" : "Push", symbol: "arrow.up", count: diff.ahead ?? 0, working: busy == "push") {
                        // A first push gives the branch an upstream: said first.
                        if diff.upstream == nil { confirmingFirstPush = true } else { model.push(in: folder) }
                    }
                    .accessibilityIdentifier("git-push")
                }
                if diff.upstream != nil {
                    // The ways that are not the usual one: asked for by name.
                    Menu {
                        Button("Pull by Merge") { model.pull(in: folder, mode: "merge") }
                        Button("Pull by Rebase") { model.pull(in: folder, mode: "rebase") }
                        Divider()
                        Button("Force Push…", role: .destructive) { model.requestForcePush(in: folder) }
                    } label: {
                        Image(systemName: "ellipsis.circle").font(.system(size: 20)).frame(width: 36, height: 36)
                    }
                    .accessibilityLabel("More ways to pull and push")
                    .accessibilityIdentifier("git-more")
                }
            }
            .disabled(busy != nil || model.askingForcePush != nil || model.status != .connected)
            Text(diff.upstream.map { "Follows \($0)" } ?? "Not on a remote yet")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.head)
                .padding(.horizontal, 6)
            if let problem = model.fetchProblems[folder] {
                // A fetch no one asked for failed: said here, not in an alert.
                Label("The Mac could not ask the remote for what is new: \(problem)", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .padding(.horizontal, 6)
                    .accessibilityIdentifier("fetch-problem")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // The remotes are asked every few minutes while this is on screen.
        .task(id: folder) {
            while !Task.isCancelled {
                model.fetchIfDue(folder)
                try? await Task.sleep(nanoseconds: 20_000_000_000)
            }
        }
        // A forced push is asked about first, saying what it overwrites.
        .confirmationDialog(
            model.pendingForcePush?.question.title ?? "",
            isPresented: Binding(get: { model.pendingForcePush?.folder == folder }, set: { if !$0 { model.pendingForcePush = nil } }),
            titleVisibility: .visible, presenting: model.pendingForcePush
        ) { push in
            if push.question.isNeeded {
                Button(push.question.confirm, role: .destructive) { model.forcePushConfirmed(push) }
            } else {
                Button("Push") { model.push(in: folder) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { push in
            Text(push.question.message)
        }
        .confirmationDialog(
            "Push “\(diff.branch ?? "")” to \(diff.pushRemote ?? "the remote")?", isPresented: $confirmingFirstPush, titleVisibility: .visible
        ) {
            Button("Push") { model.push(in: folder) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "The branch does not follow a branch on a remote yet. It is pushed as \(diff.pushRemote ?? "origin")/\(diff.branch ?? ""), which it follows from then on."
            )
        }
    }

    private func button(_ title: String, symbol: String, count: Int, working: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if working {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: symbol).font(.system(size: 13, weight: .bold))
                }
                Text(title).font(.subheadline.weight(.semibold))
                if count > 0 {
                    Text("\(count)").font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 3)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(count > 0 ? "\(title), \(count)" : title)
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

    private var isWriting: Bool { model.writingCommitMessage.contains(folder) }

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                TextField("Commit message", text: message, axis: .vertical)
                    .lineLimit(1...5)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.panel))
                    .accessibilityIdentifier("commit-message")
                if let writer = model.commitWriterAgent {
                    // An agent on the Mac writes the message for what is
                    // staged. While it does, the same button stops it.
                    Button {
                        if isWriting { model.cancelCommitMessage(in: folder) } else { model.writeCommitMessage(in: folder) }
                    } label: {
                        Group {
                            if isWriting {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "sparkles").font(.system(size: 16, weight: .semibold))
                            }
                        }
                        .frame(width: 42, height: 42)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.panel))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(stagedCount > 0 ? Palette.tint : Color.secondary)
                    .disabled((stagedCount == 0 && !isWriting) || model.status != .connected)
                    .accessibilityLabel(isWriting ? "Stop writing the commit message" : "Write the commit message with \(writer.name)")
                    .accessibilityIdentifier("write-commit-message")
                }
            }
            Button {
                model.commit(in: folder)
            } label: {
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
    /// One more thing to do with all of them, before the first.
    var second: (title: String, perform: () -> Void)?
    let perform: () -> Void

    init(title: String, count: Int, action: String, second: (String, () -> Void)? = nil, perform: @escaping () -> Void) {
        self.title = title
        self.count = count
        self.action = action
        self.second = second.map { (title: $0.0, perform: $0.1) }
        self.perform = perform
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
            Spacer()
            if let second {
                Button(second.title, role: .destructive, action: second.perform)
                    .font(.footnote.weight(.medium))
                    .padding(.trailing, 10)
            }
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
    /// "unified" shows the diff in one panel, "split" as before and after
    /// side by side, which reads best with the phone on its side.
    @AppStorage("diffLayout") private var layout = "unified"

    private var isSplit: Bool { layout == "split" }

    var body: some View {
        Group {
            if let loaded = model.patches[key] {
                if let diff = loaded {
                    if isSplit {
                        SplitDiffView(patch: diff.patch, fontSize: 11)
                    } else {
                        PatchLines(patch: diff.patch)
                    }
                } else {
                    Placeholder(text: "This file no longer has changes.")
                }
            } else {
                LoadingView("Loading the diff…")
            }
        }
        .background(Palette.canvas.ignoresSafeArea())
        .navigationTitle((file as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    model.setDisplay { $0.diffLayout = isSplit ? "unified" : "split" }
                } label: {
                    Image(systemName: isSplit ? "rectangle" : "rectangle.split.2x1")
                }
                .accessibilityLabel(isSplit ? "Show in one panel" : "Show side by side")
                .accessibilityIdentifier("diff-layout")
            }
        }
        .onAppear { model.loadPatch(folder: folder, file: file, staged: staged) }
    }
}

/// The lines of a diff, scrolling both ways.
private struct PatchLines: View {
    private let lines: [String]
    /// Width of the longest line. A lazy stack inside a view that scrolls
    /// both ways has no width of its own, and without one it does not scroll.
    private let contentWidth: CGFloat

    private static let font = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private static let horizontalPadding: CGFloat = 10

    init(patch: String) {
        // Tabs have no fixed width in SwiftUI text, which would make the measured width wrong.
        lines = patch.split(separator: "\n", omittingEmptySubsequences: false).prefix(4000)
            .map { $0.replacingOccurrences(of: "\t", with: "    ") }
        // Measuring every line would be slow on a large diff. The widest is
        // almost always among the longest by character count.
        let candidates = lines.sorted { $0.utf16.count > $1.utf16.count }.prefix(8)
        let widest = candidates.map { ($0 as NSString).size(withAttributes: [.font: Self.font]).width }.max() ?? 0
        contentWidth = ceil(widest) + Self.horizontalPadding * 2 + 8
    }

    var body: some View {
        GeometryReader { viewport in
            // At least as wide as the screen, so line tints reach the right edge.
            let width = max(contentWidth, viewport.size.width)
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { line in
                        Text(line.element.isEmpty ? " " : line.element)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(foreground(line.element))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, Self.horizontalPadding)
                            .padding(.vertical, 1)
                            .frame(width: width, alignment: .leading)
                            .background(background(line.element))
                    }
                }
                .frame(width: width, alignment: .leading)
                .padding(.vertical, 8)
            }
            .accessibilityIdentifier("patch")
        }
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

/// Conversations of one folder only, or of the whole Mac when `folder` is
/// nil (the History tab), one section per agent: as on the Mac, a folder's
/// history has no switch to everything, the History tab has that.
struct HistoryList: View {
    @EnvironmentObject private var model: PhoneModel
    let folder: String?
    @State private var selected: Conversation?
    @State private var collapsedAgents: Set<String> = []

    private var showsAll: Bool { folder == nil }
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
                                                Button {
                                                    selected = conversation
                                                } label: {
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
                LoadingView("Loading the history…") { load() }
            }
        }
        .onAppear(perform: load)
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
    /// Where the receiving agent starts. Empty means the conversation's folder.
    @State private var folder = ""

    private var destination: String { folder.isEmpty ? conversation.cwd : folder }
    /// The conversation's own folder, the repositories inside it (an agent
    /// started in a folder of projects usually worked in one of them), the
    /// other listed folders, and one picked by hand.
    private var folderChoices: [String] {
        let nested = (model.fileListings[conversation.cwd] ?? []).filter { $0.isRepository == true }.map(\.path)
        var paths = [conversation.cwd]
        for path in nested + model.folders + [chosen].compactMap({ $0 }) where !paths.contains(path) { paths.append(path) }
        return paths
    }

    /// A folder picked with "Choose…".
    @State private var chosen: String?
    @State private var choosingFolder = false

    private func label(for path: String) -> String {
        if path == conversation.cwd { return (path as NSString).lastPathComponent + " (same)" }
        if path.hasPrefix(conversation.cwd + "/") { return (conversation.cwd as NSString).lastPathComponent + "/" + path.dropFirst(conversation.cwd.count + 1) }
        return (path as NSString).lastPathComponent
    }
    private var targets: [AgentInfo] { model.handoffTargets(from: conversation.agent, sameFolder: destination == conversation.cwd) }
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
                            Group {
                                HStack {
                                    Text("Continue in").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                    Spacer(minLength: 4)
                                    Button("Choose…") { choosingFolder = true }
                                        .font(.subheadline)
                                        .accessibilityIdentifier("choose-folder")
                                    Picker("Folder", selection: $folder) {
                                        ForEach(folderChoices, id: \.self) { path in
                                            Text(label(for: path)).tag(path == conversation.cwd ? "" : path)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    // On one line: a folder's name is not broken in two.
                                    .fixedSize()
                                }
                            }
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(targets) { agent in
                                        let selected = agent.id == target?.id
                                        Button {
                                            targetID = agent.id
                                        } label: {
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
                                model.handoff(conversation, to: target, prompt: prompt, note: note, in: folder.isEmpty ? nil : folder)
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
            .toolbar(.hidden, for: .tabBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .sheet(isPresented: $choosingFolder) {
                BrowseSheet(start: destination, pickTitle: "Continue in") { path in
                    chosen = path == conversation.cwd ? nil : path
                    folder = path == conversation.cwd ? "" : path
                }
                .environmentObject(model)
                .preferredColorScheme(.dark)
            }
            .onAppear {
                targetID = targets.contains { $0.id == rememberedTarget } ? rememberedTarget : (targets.first?.id ?? "")
                // The repositories inside the conversation's folder, to continue in one.
                model.loadFiles(conversation.cwd)
                if !targets.isEmpty { model.requestHandoffPlan(for: conversation) }
            }
            .onChange(of: model.handoffPlan) { _, plan in
                if let plan { prompt = plan.prompt }
            }
        }
    }
}

/// The checked out branch (#35). Touched, it lists the repository's
/// branches, to switch to one or make one; renaming and deleting are on
/// the Mac.
struct BranchButton: View {
    let folder: String
    /// Nil for a detached HEAD.
    let branch: String?
    @State private var showing = false

    var body: some View {
        Button {
            showing = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.branch")
                Text(branch ?? "detached HEAD").lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Branch \(branch ?? "detached HEAD")")
        .accessibilityIdentifier("branch-menu")
        .sheet(isPresented: $showing) {
            BranchesSheet(folder: folder)
        }
    }
}

/// The branches of a folder on the Mac: touch one to check it out, or make
/// a new one.
private struct BranchesSheet: View {
    @EnvironmentObject private var model: PhoneModel
    @Environment(\.dismiss) private var dismiss
    let folder: String
    @State private var filter = ""
    @State private var making = false
    @State private var newName = ""
    @State private var from = ""
    @State private var checkout = true

    private var all: [BranchInfo] { model.branches[folder] ?? [] }

    private func shown(remote: Bool) -> [BranchInfo] {
        let wanted = filter.trimmingCharacters(in: .whitespaces).lowercased()
        return all.filter { $0.isRemote == remote && (wanted.isEmpty || $0.name.lowercased().contains(wanted)) }
    }

    var body: some View {
        NavigationStack {
            List {
                if making {
                    Section("New Branch") {
                        TextField("Name", text: $newName)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("new-branch-name")
                        Picker("From", selection: $from) {
                            ForEach(all) { branch in Text(branch.name).tag(branch.name) }
                        }
                        Toggle("Switch to it", isOn: $checkout)
                        Button("Create Branch") {
                            model.createBranch(named: newName.trimmingCharacters(in: .whitespaces), from: from.isEmpty ? nil : from, checkout: checkout, in: folder)
                            making = false
                            if checkout { dismiss() }
                        }
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("new-branch-create")
                    }
                }
                section("Branches", shown(remote: false))
                section("Remote Branches", shown(remote: true))
                if all.isEmpty { Text("Reading the branches…").foregroundStyle(.secondary) }
            }
            .searchable(text: $filter, prompt: "Find a branch")
            .navigationTitle("Branches")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        from = all.first(where: \.isCurrent)?.name ?? ""
                        making.toggle()
                    } label: {
                        Label("New Branch", systemImage: "plus")
                    }
                    .accessibilityIdentifier("new-branch")
                }
            }
        }
        .onAppear { model.loadBranches(folder) }
    }

    @ViewBuilder
    private func section(_ title: String, _ list: [BranchInfo]) -> some View {
        if !list.isEmpty {
            Section(title) {
                ForEach(list) { branch in
                    Button {
                        model.switchBranch(branch, in: folder)
                        dismiss()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark").font(.footnote.weight(.bold)).opacity(branch.isCurrent ? 1 : 0)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(branch.name).font(.body.weight(branch.isCurrent ? .semibold : .regular)).lineLimit(1).truncationMode(.middle)
                                let detail = [branch.tracking, branch.worktree == nil ? "" : "in a worktree", branch.subject].filter { !$0.isEmpty }.joined(separator: " · ")
                                if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                            }
                        }
                    }
                    .foregroundStyle(.primary)
                    // The one that is checked out, and one another worktree holds, stay where they are.
                    .disabled(branch.isCurrent || branch.worktree != nil)
                    .accessibilityIdentifier("branch-" + branch.id)
                }
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
