import AgentTermHost
import AgentTermProtocol
import AgentTermTerminal
import SwiftUI

struct DiffView: View {
    @EnvironmentObject private var model: AppModel
    /// "list" shows every file in one flat list, "tree" groups them by folder.
    @AppStorage("diffViewMode") private var viewMode = "list"
    @State private var collapsedFolders: Set<String> = []
    /// What the tab lists: "changes", what is not committed yet, or
    /// "commits", the history (#36).
    @AppStorage("gitPane") private var pane = "changes"

    private var isTree: Bool { viewMode == "tree" }

    /// The change whose diff is open in the middle pane.
    private var selectedFile: FileDiff? { model.diffTabFileInList }

    var body: some View {
        VStack(spacing: 0) {
            header
            Theme.hairline.frame(height: 1)
            if let diff = model.diff, diff.canPush || diff.canPull {
                // Above the changes and not among them: a commit that was
                // just made leaves no changes, and is what there is to push.
                SyncBar(diff: diff)
                Theme.hairline.frame(height: 1)
            }
            if model.diff?.isRepository == true {
                Picker("Show", selection: $pane) {
                    Text("Changes").tag("changes")
                    Text("Commits").tag("commits")
                    Text("Stashes").tag("stashes")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .accessibilityIdentifier("git-pane")
                Theme.hairline.frame(height: 1)
            }
            if pane == "commits", model.diff?.isRepository == true {
                CommitsList()
            } else if pane == "stashes", model.diff?.isRepository == true {
                StashesList()
            } else {
                content
            }
        }
        .background(Theme.panel)
        .modifier(GitQuestions())
    }

    private var header: some View {
        HStack(spacing: 8) {
            if model.diff?.isRepository == true {
                // The branch that is checked out; pressed, the branches.
                BranchButton(branch: model.diff?.branch)
            } else {
                Text("Changes")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let files = model.diff?.files, !files.isEmpty {
                DiffCount(added: files.reduce(0) { $0 + $1.added }, deleted: files.reduce(0) { $0 + $1.deleted })
            }
            Button {
                model.setDisplay { $0.changesView = isTree ? "list" : "tree" }
            } label: {
                Image(systemName: isTree ? "list.bullet" : "list.bullet.indent")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(isTree ? "Show as a flat list" : "Group by folder")
            .accessibilityLabel(isTree ? "Show as a flat list" : "Group by folder")
            Button {
                model.refreshDiff()
            } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Refresh")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    @ViewBuilder
    private var content: some View {
        if model.panelFolder == nil {
            placeholder("Select a folder to see its changes.")
        } else if let diff = model.diff {
            if !diff.isRepository {
                placeholder("This folder is not a git repository.")
            } else if diff.files.isEmpty && diff.operation != nil {
                // Stopped, with nothing left to resolve or commit.
                VStack(spacing: 0) {
                    ConflictBanner(diff: diff)
                    placeholder("Nothing else is changed.")
                }
            } else if diff.files.isEmpty && !model.isAmending {
                placeholder("No uncommitted changes.")
            } else {
                // The list only: a file that is clicked shows its diff in the middle pane.
                VStack(spacing: 0) {
                    CommitBox(stagedCount: diff.staged.count)
                    Theme.hairline.frame(height: 1)
                    if diff.files.isEmpty {
                        // Amending with nothing staged: its message alone.
                        placeholder("No uncommitted changes: only the commit's message is amended.")
                    } else {
                        fileList(diff)
                    }
                }
            }
        } else {
            LoadingView("Loading the changes…") { model.refreshDiff() }
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

    private func fileList(_ diff: DiffSnapshot) -> some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                let staged = diff.staged
                let unstaged = diff.unstaged
                let conflicts = diff.conflicts
                if diff.operation != nil || !conflicts.isEmpty {
                    // What git is stopped in, above everything else (#42).
                    ConflictBanner(diff: diff)
                        .padding(.bottom, 4)
                    ForEach(conflicts) { file in
                        ConflictRow(file: file, selected: file.id == selectedFile?.id)
                            .onTapGesture { model.openDiff(file) }
                    }
                }
                if !staged.isEmpty {
                    ChangesHeader(title: "Staged", count: staged.count, symbol: "minus", help: "Unstage all") { model.unstage([]) }
                    rows(staged)
                }
                if !unstaged.isEmpty {
                    ChangesHeader(
                        title: "Changes", count: unstaged.count, symbol: "plus", help: "Stage all", second: ("arrow.uturn.backward", "Discard all", { model.requestDiscard([]) })
                    ) { model.stage([]) }
                    .padding(.top, staged.isEmpty ? 0 : 6)
                    rows(unstaged)
                }
            }
            .padding(6)
        }
        // Asked first: what is discarded does not come back (#39).
        .confirmationDialog(
            question?.title ?? "", isPresented: Binding(get: { model.discarding != nil }, set: { if !$0 { model.discarding = nil } }), titleVisibility: .visible
        ) {
            Button(question?.confirm ?? "Discard", role: .destructive) { model.discardConfirmed() }
            Button("Cancel", role: .cancel) { model.discarding = nil }
        } message: {
            Text(question?.message ?? "")
        }
    }

    private var question: DiscardQuestion? { model.discarding.map(DiscardQuestion.init(files:)) }

    /// The files of one of the two lists, flat or grouped by folder.
    @ViewBuilder
    private func rows(_ files: [FileDiff]) -> some View {
        if isTree {
            ForEach(DiffTree.rows(for: files, collapsed: collapsedFolders)) { row in
                switch row.kind {
                case .folder(let expanded):
                    DiffFolderRow(row: row, expanded: expanded)
                        .onTapGesture {
                            if expanded { collapsedFolders.insert(row.id) } else { collapsedFolders.remove(row.id) }
                        }
                case .file(let file):
                    FileRow(file: file, selected: file.id == selectedFile?.id, showsDirectory: false, depth: row.depth)
                        .onTapGesture { model.openDiff(file) }
                }
            }
        } else {
            ForEach(files) { file in
                FileRow(file: file, selected: file.id == selectedFile?.id)
                    .onTapGesture { model.openDiff(file) }
            }
        }
    }
}

/// What git is stopped in the middle of (#42): how many files conflict,
/// which side is which, and Continue once all are resolved, or Abort.
private struct ConflictBanner: View {
    @EnvironmentObject private var model: AppModel
    let diff: DiffSnapshot

    private var words: ConflictWords { ConflictWords(operation: diff.operation, conflicts: diff.conflicts.count) }
    private var busy: Bool { model.panelFolder.flatMap { model.syncing[$0] } != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: diff.conflicts.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(diff.conflicts.isEmpty ? Color.green : Color.yellow)
                    .font(.system(size: 11))
                Text(words.headline).font(.system(size: 12, weight: .semibold))
            }
            Text(words.advice)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if diff.operation != nil {
                HStack(spacing: 6) {
                    Button("Abort…", role: .destructive) { model.confirmingAbort = true }
                        .accessibilityIdentifier("conflicts-abort")
                    Button("Continue") { model.continueOperation() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!diff.conflicts.isEmpty)
                        .help(diff.conflicts.isEmpty ? "Finish it with what was resolved" : "Resolve every file that conflicts first")
                        .accessibilityIdentifier("conflicts-continue")
                    Spacer(minLength: 0)
                }
                .controlSize(.small)
                .disabled(busy)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.yellow.opacity(0.10)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("conflicts")
        .confirmationDialog(words.abortTitle, isPresented: $model.confirmingAbort, titleVisibility: .visible) {
            Button("Abort", role: .destructive) { model.abortOperationConfirmed() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(words.abortMessage)
        }
    }
}

/// A file that conflicts: how, and the ways to resolve it. Pressed, it
/// shows the file as it is, with what each side has.
private struct ConflictRow: View {
    @EnvironmentObject private var model: AppModel
    let file: FileDiff
    let selected: Bool
    @State private var hovering = false

    private var name: String { (file.path as NSString).lastPathComponent }
    private func ours() { model.resolve(file, as: .ours) }
    private func theirs() { model.resolve(file, as: .theirs) }
    private func edit() { model.edit(conflict: file) }
    private func edited() { model.resolve(file, as: .edited) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(file.marker)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.yellow)
                    .frame(width: 12)
                Text(name).font(.system(size: 12)).lineLimit(1)
                Text(file.conflictWords ?? "")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(name), conflicts: \(file.conflictWords ?? "")")
            .accessibilityIdentifier("conflict-" + file.path)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { model.openDiff(file) }
            HStack(spacing: 5) {
                Button("Take Ours", action: ours).accessibilityLabel("Take ours for \(name)")
                Button("Take Theirs", action: theirs).accessibilityLabel("Take theirs for \(name)")
                Button("Edit", action: edit)
                    .help("Open the file in the editor, with its markers, to put it right by hand")
                    .accessibilityLabel("Edit \(name)")
                Button("Mark Resolved", action: edited)
                    .help("The file is as it should be: its markers are gone")
                    .accessibilityLabel("Mark \(name) resolved")
            }
            .controlSize(.mini)
            .padding(.leading, 18)
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selected ? Color.white.opacity(0.11) : (hovering ? Color.white.opacity(0.05) : .clear))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(file.path)
    }
}

/// What is asked before git does something that is not undone by a click:
/// a commit that reverts or picks another (#36), and a forced push (#37).
private struct GitQuestions: ViewModifier {
    @EnvironmentObject private var model: AppModel

    private func question(_ pending: AppModel.PendingCommitAction) -> CommitActionQuestion {
        CommitActionQuestion(pending.action, commit: pending.commit, onto: model.diff?.branch)
    }

    private var askingCommit: Binding<Bool> {
        Binding(get: { model.pendingCommitAction != nil }, set: { if !$0 { model.pendingCommitAction = nil } })
    }

    private var askingRewrite: Binding<Bool> {
        Binding(get: { model.pendingRewrite != nil }, set: { if !$0 { model.pendingRewrite = nil } })
    }

    private func question(_ pending: AppModel.PendingRewrite) -> RewriteCommitQuestion {
        RewriteCommitQuestion(pending.action, last: pending.last, again: pending.again)
    }

    private var askingDrop: Binding<Bool> {
        Binding(get: { model.droppingStash != nil }, set: { if !$0 { model.droppingStash = nil } })
    }

    private var askingForce: Binding<Bool> {
        Binding(get: { model.pendingForcePush != nil }, set: { if !$0 { model.pendingForcePush = nil } })
    }

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                model.pendingCommitAction.map { question($0).title } ?? "", isPresented: askingCommit, titleVisibility: .visible,
                presenting: model.pendingCommitAction
            ) { pending in
                Button(question(pending).confirm) { model.commitActionConfirmed(pending) }
                Button("Cancel", role: .cancel) {}
            } message: { pending in
                Text(question(pending).message)
            }
            .confirmationDialog(
                model.pendingRewrite.map { question($0).title } ?? "", isPresented: askingRewrite, titleVisibility: .visible,
                presenting: model.pendingRewrite
            ) { pending in
                Button(question(pending).confirm, role: pending.last.isPushed ? .destructive : nil) { model.rewriteConfirmed(pending) }
                Button("Cancel", role: .cancel) {}
            } message: { pending in
                Text(question(pending).message)
            }
            .confirmationDialog(
                model.droppingStash.map { DropStashQuestion(stash: $0).title } ?? "", isPresented: askingDrop, titleVisibility: .visible,
                presenting: model.droppingStash
            ) { stash in
                Button(DropStashQuestion(stash: stash).confirm, role: .destructive) { model.dropStashConfirmed() }
                Button("Cancel", role: .cancel) {}
            } message: { stash in
                Text(DropStashQuestion(stash: stash).message)
            }
            .confirmationDialog(
                model.pendingForcePush?.question.title ?? "", isPresented: askingForce, titleVisibility: .visible, presenting: model.pendingForcePush
            ) { push in
                if push.question.isNeeded {
                    Button(push.question.confirm, role: .destructive) { model.forcePushConfirmed(push) }
                } else {
                    Button("Push") { model.push() }
                }
                Button("Cancel", role: .cancel) {}
            } message: { push in
                Text(push.question.message)
            }
    }
}

/// Push and pull for the branch that is checked out, with how far it is
/// from the branch it follows.
private struct SyncBar: View {
    @EnvironmentObject private var model: AppModel
    let diff: DiffSnapshot

    private var busy: String? { model.panelFolder.flatMap { model.syncing[$0] } }

    /// What the last fetch no one asked for said when it failed.
    private var fetchProblem: String? { model.panelFolder.flatMap { model.fetchProblems[$0] } }

    var body: some View {
        HStack(spacing: 6) {
            // Its symbol alone: Pull and Push are what the row is for, and
            // the side panel has no room for three words.
            SyncButton(title: "Fetch", symbol: "arrow.triangle.2.circlepath", count: 0, working: busy == "fetch", symbolOnly: true) { model.fetch() }
                .help("Ask the remotes for what is new, without changing the branch or the files")
            if diff.canPull {
                SyncButton(title: "Pull", symbol: "arrow.down", count: diff.behind ?? 0, working: busy == "pull") { model.pull() }
                    .help(
                        (diff.behind ?? 0) > 0
                            ? "Bring in \(diff.behind ?? 0) \((diff.behind ?? 0) == 1 ? "commit" : "commits") from \(diff.upstream ?? "the remote")"
                            : "Ask \(diff.upstream ?? "the remote") for new commits and bring them in")
            }
            if diff.canPush {
                SyncButton(
                    title: diff.upstream == nil ? "Publish Branch" : "Push", symbol: "arrow.up", count: diff.ahead ?? 0, working: busy == "push"
                ) { model.push() }
                .help(
                    diff.upstream == nil
                        ? "Push this branch to \(diff.pushRemote ?? "the remote") and follow it there"
                        : ((diff.ahead ?? 0) > 0
                            ? "Send \(diff.ahead ?? 0) \((diff.ahead ?? 0) == 1 ? "commit" : "commits") to \(diff.upstream ?? "the remote")"
                            : "Nothing new to send to \(diff.upstream ?? "the remote")"))
            }
            if diff.upstream != nil {
                // The ways that are not the usual one: asked for by name.
                Menu {
                    Button("Pull by Merge") { model.pull(.merge) }
                    Button("Pull by Rebase") { model.pull(.rebase) }
                    Divider()
                    Button("Force Push…") { model.requestForcePush() }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 10, weight: .bold))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Pull by merge or by rebase, or force the push")
                .accessibilityLabel("More ways to pull and push")
                .accessibilityIdentifier("sync-more")
            }
            Spacer(minLength: 4)
            if let fetchProblem {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.yellow)
                    .help("The remotes could not be asked for what is new, so what is ahead and behind may be out of date. Fetch says why.\n\n\(fetchProblem)")
                    .accessibilityLabel("The last automatic fetch failed: \(fetchProblem)")
                    .accessibilityIdentifier("fetch-problem")
            }
            // The first to give way when the panel is narrow.
            Text(diff.upstream ?? "not on a remote yet")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.head)
                .layoutPriority(-1)
        }
        .disabled(busy != nil || model.askingForcePush != nil)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

private struct SyncButton: View {
    let title: String
    let symbol: String
    let count: Int
    let working: Bool
    /// Drawn without its title, which VoiceOver still says.
    var symbolOnly = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if working {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: symbol).font(.system(size: 9.5, weight: .bold))
                }
                if !symbolOnly { Text(title).fixedSize() }
                if count > 0 {
                    Text("\(count)").monospacedDigit().foregroundStyle(.secondary)
                }
            }
        }
        .controlSize(.small)
        .accessibilityLabel(count > 0 ? "\(title), \(count)" : title)
    }
}

/// Where the commit message is written and the commit is made.
private struct CommitBox: View {
    @EnvironmentObject private var model: AppModel
    let stagedCount: Int

    private var message: Binding<String> {
        Binding(
            get: { model.panelFolder.flatMap { model.commitMessages[$0] } ?? "" },
            set: { if let folder = model.panelFolder { model.commitMessages[folder] = $0 } }
        )
    }

    /// The commit being amended, when one is (#41).
    private var amending: LastCommit? { model.panelFolder.flatMap { model.amending[$0] } }

    private var canCommit: Bool {
        // Amending needs nothing staged: the message alone may be what changes.
        (stagedCount > 0 || amending != nil) && !model.isCommitting && !message.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var commitTitle: String {
        if amending != nil { return stagedCount > 0 ? "Amend with \(stagedCount) \(stagedCount == 1 ? "File" : "Files")" : "Amend Message" }
        return stagedCount > 0 ? "Commit \(stagedCount) \(stagedCount == 1 ? "File" : "Files")" : "Commit"
    }

    private var isWriting: Bool { model.panelFolder.map(model.writingCommitMessage.contains) ?? false }

    /// The agent that would write the message: the one chosen in Settings,
    /// or the first one installed.
    private var writer: AgentInfo? {
        model.commitWriter.writer(among: model.agents)
    }

    var body: some View {
        VStack(spacing: 6) {
            if let amending {
                // What the box does now is said above it, with the way out.
                HStack(spacing: 6) {
                    Image(systemName: "pencil.line").font(.system(size: 10, weight: .semibold))
                    Text("Amending \(amending.commit.short): what is staged is added to it")
                        .font(.system(size: 10.5))
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    Button("Cancel") { model.cancelAmend() }
                        .controlSize(.mini)
                        .accessibilityIdentifier("amend-cancel")
                }
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("amending")
            }
            TextField("Commit message", text: message, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .lineLimit(1...5)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.raised))
                .accessibilityLabel("Commit message")
            HStack(spacing: 6) {
                Button {
                    model.commit()
                } label: {
                    HStack(spacing: 6) {
                        if model.isCommitting { ProgressView().controlSize(.mini) }
                        Text(commitTitle)
                    }
                    .frame(maxWidth: .infinity)
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .disabled(!canCommit)
                .help(
                    amending != nil
                        ? "Replace the last commit by one with this message and what is staged"
                        : (stagedCount == 0 ? "Stage the changes to commit first" : "Commit what is staged"))
                if let writer {
                    // While the agent writes, the same button stops it.
                    Button {
                        if isWriting { model.cancelCommitMessage() } else { model.writeCommitMessage() }
                    } label: {
                        HStack(spacing: 4) {
                            if isWriting {
                                ProgressView().controlSize(.mini)
                                Text("Stop")
                            } else {
                                Image(systemName: "sparkles").font(.system(size: 10, weight: .semibold))
                                Text("Write")
                            }
                        }
                    }
                    .controlSize(.small)
                    .disabled(stagedCount == 0 && !isWriting)
                    .help(
                        isWriting
                            ? "Stop \(writer.name)"
                            : (stagedCount == 0
                                ? "Stage the changes first: \(writer.name) writes the message for what is staged"
                                : "Have \(writer.name) write the message for what is staged. Nothing is committed until you commit.")
                    )
                    .accessibilityLabel(isWriting ? "Stop writing the commit message" : "Write the commit message with \(writer.name)")
                }
                if amending == nil {
                    // What is done to the last commit rather than made anew (#41).
                    Menu {
                        Button("Amend Last Commit…") { model.requestAmend() }
                        Button("Undo Last Commit…") { model.requestUndoCommit() }
                    } label: {
                        Image(systemName: "ellipsis").font(.system(size: 10, weight: .bold))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Amend or undo the last commit")
                    .accessibilityLabel("Amend or undo the last commit")
                    .accessibilityIdentifier("commit-more")
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

/// Title of one of the two lists, with a button that moves every file to the other.
private struct ChangesHeader: View {
    let title: String
    let count: Int
    let symbol: String
    let help: String
    /// One more thing to do with all of them, before the first: its
    /// symbol, what it is called, and what it does.
    var second: (symbol: String, help: String, action: () -> Void)?
    let action: () -> Void

    init(title: String, count: Int, symbol: String, help: String, second: (String, String, () -> Void)? = nil, action: @escaping () -> Void) {
        self.title = title
        self.count = count
        self.symbol = symbol
        self.help = help
        self.second = second.map { (symbol: $0.0, help: $0.1, action: $0.2) }
        self.action = action
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
            Spacer()
            if let second {
                Button(action: second.action) {
                    Image(systemName: second.symbol).font(.system(size: 10, weight: .bold)).frame(width: 18, height: 16)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(second.help)
                .accessibilityLabel(second.help)
            }
            Button(action: action) {
                Image(systemName: symbol).font(.system(size: 10, weight: .bold)).frame(width: 18, height: 16)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(help)
            .accessibilityLabel(help)
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .padding(.vertical, 3)
    }
}

/// Width of one level of nesting in the folder tree.
private let treeIndent: CGFloat = 14

private struct DiffFolderRow: View {
    let row: DiffTreeRow
    let expanded: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 12)
            Image(systemName: "folder.fill")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            Text(row.name)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            DiffCount(added: row.added, deleted: row.deleted)
                .opacity(0.75)
        }
        .padding(.leading, 8 + CGFloat(row.depth) * treeIndent)
        .padding(.trailing, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(hovering ? Color.white.opacity(0.05) : .clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(row.id)
        .accessibilityLabel("\(row.name), folder, \(expanded ? "expanded" : "collapsed")")
    }
}

struct DiffCount: View {
    let added: Int
    let deleted: Int

    var body: some View {
        HStack(spacing: 5) {
            Text("+\(added)").foregroundStyle(Theme.added)
            Text("−\(deleted)").foregroundStyle(Theme.removed)
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
    }
}

private struct FileRow: View {
    @EnvironmentObject private var model: AppModel
    let file: FileDiff
    let selected: Bool
    /// The flat list shows where each file lives; the tree already does.
    var showsDirectory = true
    var depth = 0
    @State private var hovering = false

    private var name: String { (file.path as NSString).lastPathComponent }
    private var directory: String { (file.path as NSString).deletingLastPathComponent }

    var body: some View {
        HStack(spacing: 6) {
            // The file itself is one thing to press, which shows its diff.
            // The button after it is another: pressing it must not be
            // taken for pressing the row, with VoiceOver either.
            HStack(spacing: 6) {
                Text(file.marker)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(markerColor)
                    .frame(width: 12)
                Text(name)
                    .font(.system(size: 12))
                    .strikethrough(file.status == .deleted)
                    .lineLimit(1)
                if showsDirectory {
                    Text(directory)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 4)
                DiffCount(added: file.added, deleted: file.deleted)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(name), \(file.isStaged ? "staged" : "not staged"), \(file.added) added, \(file.deleted) removed")
            .accessibilityIdentifier((file.isStaged ? "staged-" : "change-") + file.path)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { model.openDiff(file) }
            if !file.isStaged {
                // Discarding is asked about first. Faint until the row is
                // under the pointer, as the button beside it is: one that
                // is not drawn at all is not there for VoiceOver either.
                Button {
                    model.requestDiscard([file])
                } label: {
                    Image(systemName: file.isUntracked ? "trash" : "arrow.uturn.backward")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 18, height: 16)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .opacity(hovering || selected ? 1 : 0.35)
                .help(file.isUntracked ? "Move to the Trash…" : "Discard Changes…")
                .accessibilityLabel(file.discardLabel)
            }
            Button(action: move) {
                Image(systemName: file.isStaged ? "minus" : "plus")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 18, height: 16)
                    .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.white.opacity(hovering ? 0.10 : 0)))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(hovering || selected ? 1 : 0.35)
            .help(file.isStaged ? "Unstage" : "Stage")
            .accessibilityLabel((file.isStaged ? "Unstage " : "Stage ") + name)
        }
        .padding(.leading, 8 + CGFloat(depth) * treeIndent)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selected ? Color.white.opacity(0.11) : (hovering ? Color.white.opacity(0.05) : .clear))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(file.path)
        .contextMenu {
            Button(file.isStaged ? "Unstage" : "Stage", action: move)
            if !file.isStaged {
                Button(file.isUntracked ? "Move to the Trash…" : "Discard Changes…", role: .destructive) { model.requestDiscard([file]) }
            }
        }
    }

    private func move() {
        if file.isStaged { model.unstage([file]) } else { model.stage([file]) }
    }

    private var markerColor: Color {
        if file.isUntracked || file.status == .added { return Theme.added }
        switch file.status {
        case .deleted: return Theme.removed
        default: return .orange
        }
    }
}

/// A change open in the middle pane: where it is, and its diff.
struct DiffDocumentView: View {
    @EnvironmentObject private var model: AppModel
    let file: FileDiff
    /// "unified" shows the diff in one panel, "split" as before and after
    /// side by side.
    @AppStorage("diffLayout") private var layout = "unified"

    private var isSplit: Bool { layout == "split" }
    /// The parts of the change are being picked (#40).
    @State private var pickingParts = false

    /// Whether the change can be taken apart: one that is not committed,
    /// with a diff to take apart.
    private var hasParts: Bool { model.diffTabLabel == nil && !PatchParts.hunks(of: file.patch).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                // Of a commit, its hash; else which of the two lists it is in.
                Text(model.diffTabLabel ?? (file.conflict != nil ? "CONFLICT" : file.isStaged ? "STAGED" : "CHANGES"))
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Theme.raised))
                Text(file.path)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 6)
                DiffCount(added: file.added, deleted: file.deleted)
                Button {
                    model.setDisplay { $0.diffLayout = isSplit ? "unified" : "split" }
                } label: {
                    Image(systemName: isSplit ? "rectangle" : "rectangle.split.2x1")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(isSplit ? "Show the diff in one panel" : "Show before and after side by side")
                .accessibilityLabel(isSplit ? "Show in one panel" : "Show side by side")
                if model.diffTabCommit == nil, file.conflict == nil {
                    if hasParts {
                        // One hunk, or some lines: the same in either layout.
                        Button(file.isStaged ? "Unstage Parts…" : "Stage Parts…") { pickingParts = true }
                            .controlSize(.small)
                            .help(file.isStaged ? "Unstage one hunk, or some of its lines" : "Stage or discard one hunk, or some of its lines")
                            .accessibilityIdentifier("pick-parts")
                    }
                    Button(file.isStaged ? "Unstage" : "Stage") {
                        if file.isStaged { model.unstage([file]) } else { model.stage([file]) }
                    }
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Theme.panel)
            Theme.hairline.frame(height: 1)
            if file.patch.isEmpty, model.loadingDiffFile {
                // From another Mac the diff comes after the list it was picked in.
                LoadingView("Loading the diff…")
            } else if file.patch.isEmpty {
                Text("Nothing to show for this file: it is empty or not text.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isSplit {
                SplitDiffView(patch: file.patch)
                    .background(Theme.canvas)
                    // By the file alone: a diff that changes under the
                    // reader, as an agent keeps editing, must stay where it
                    // was scrolled to rather than start over at the top.
                    .id(file.id)
            } else {
                PatchView(file: file)
            }
        }
        .background(Theme.canvas)
        .sheet(isPresented: $pickingParts) {
            PartsSheet(file: file) { pickingParts = false }
                .environmentObject(model)
        }
        // Nothing left of the change: nothing left to pick from.
        .onChange(of: model.diffTabFile == nil) { gone in if gone { pickingParts = false } }
    }
}

/// One file's unified diff with added and removed lines tinted.
private struct PatchView: View {
    let file: FileDiff
    private let lines: [String]
    /// Width of the longest line, so the diff scrolls sideways far enough to show it.
    private let contentWidth: CGFloat

    private static let maxLines = 4000
    private static let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
    private static let horizontalPadding: CGFloat = 10

    init(file: FileDiff) {
        self.file = file
        // Tabs have no fixed width in SwiftUI text, which would make the measured width wrong.
        lines = file.patch.split(separator: "\n", omittingEmptySubsequences: false).prefix(Self.maxLines)
            .map { $0.replacingOccurrences(of: "\t", with: "    ") }
        // Measuring every line would be slow on a large diff. The widest is
        // almost always among the longest by character count.
        let candidates = lines.sorted { $0.utf16.count > $1.utf16.count }.prefix(8)
        let widest = candidates.map { ($0 as NSString).size(withAttributes: [.font: Self.font]).width }.max() ?? 0
        contentWidth = ceil(widest) + Self.horizontalPadding * 2 + 8
    }

    var body: some View {
        GeometryReader { viewport in
            // At least as wide as the pane, so line tints reach the right edge.
            let width = max(contentWidth, viewport.size.width)
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { line in
                        Text(line.element.isEmpty ? " " : line.element)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(foreground(Substring(line.element)))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, Self.horizontalPadding)
                            .padding(.vertical, 1)
                            .frame(width: width, alignment: .leading)
                            .background(background(Substring(line.element)))
                    }
                }
                .frame(width: width, alignment: .leading)
                .padding(.vertical, 6)
                .textSelection(.enabled)
                .background(PermanentScrollers())
            }
        }
        .background(Theme.canvas)
        // By the file alone, not by its diff: see `DiffDocumentView`.
        .id(file.id)
    }

    private func foreground(_ line: Substring) -> Color {
        if line.hasPrefix("@@") { return Color(red: 0.55, green: 0.67, blue: 0.98) }
        if line.hasPrefix("+") { return Theme.added }
        if line.hasPrefix("-") { return Theme.removed }
        return Color.white.opacity(0.72)
    }

    private func background(_ line: Substring) -> Color {
        if line.hasPrefix("@@") { return Color.white.opacity(0.04) }
        if line.hasPrefix("+") { return Theme.added.opacity(0.10) }
        if line.hasPrefix("-") { return Theme.removed.opacity(0.10) }
        return .clear
    }
}

/// Makes the enclosing scroll view show its scroll bars all the time.
///
/// With a trackpad macOS hides scroll bars until you scroll, and then nothing
/// tells that a long diff line continues to the right. SwiftUI's
/// `scrollIndicators(.visible)` does not override that, so this reaches the
/// AppKit scroll view behind the SwiftUI one.
private struct PermanentScrollers: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            apply()
        }

        private func apply() {
            guard let scrollView = enclosingScrollView else { return }
            scrollView.scrollerStyle = .legacy
            scrollView.autohidesScrollers = false
            scrollView.hasHorizontalScroller = true
            scrollView.hasVerticalScroller = true
            scrollView.scrollerKnobStyle = .light
        }
    }
}
