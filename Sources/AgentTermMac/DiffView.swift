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
            } else if diff.files.isEmpty && diff.submodules.isEmpty && diff.operation != nil {
                // Stopped, with nothing left to resolve or commit.
                VStack(spacing: 0) {
                    ConflictBanner(diff: diff)
                    placeholder("Nothing else is changed.")
                }
            } else if diff.files.isEmpty && diff.submodules.isEmpty && !model.isAmending {
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
                submodules(diff)
            }
            .padding(6)
        }
        .sheet(item: $model.committingSubmodule) { SubmoduleCommitSheet(submodule: $0) }
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
    private func rows(_ files: [FileDiff], in submodule: String? = nil) -> some View {
        if isTree {
            ForEach(DiffTree.rows(for: files, collapsed: collapsedFolders)) { row in
                switch row.kind {
                case .folder(let expanded):
                    DiffFolderRow(row: row, expanded: expanded)
                        .onTapGesture {
                            if expanded { collapsedFolders.insert(row.id) } else { collapsedFolders.remove(row.id) }
                        }
                case .file(let file):
                    FileRow(file: file, selected: model.isInDiffTab(file, in: submodule), showsDirectory: false, depth: row.depth, submodule: submodule)
                        .onTapGesture { model.openDiff(file, in: submodule) }
                }
            }
        } else {
            ForEach(files) { file in
                FileRow(file: file, selected: model.isInDiffTab(file, in: submodule), submodule: submodule)
                    .onTapGesture { model.openDiff(file, in: submodule) }
            }
        }
    }

    /// The submodules with changes inside them (#44), each a list of its
    /// own under the folder's: what is staged there and what is not, with
    /// the same actions, done in the submodule.
    @ViewBuilder
    private func submodules(_ diff: DiffSnapshot) -> some View {
        ForEach(diff.submodules) { submodule in
            SubmoduleHeader(submodule: submodule).padding(.top, 8)
            let staged = submodule.changes.staged
            let unstaged = submodule.changes.unstaged
            if !staged.isEmpty {
                ChangesHeader(title: "Staged", count: staged.count, symbol: "minus", help: "Unstage all in \(submodule.path)") {
                    model.unstage([], in: submodule.path)
                }
                rows(staged, in: submodule.path)
            }
            if !unstaged.isEmpty {
                ChangesHeader(
                    title: "Changes", count: unstaged.count, symbol: "plus", help: "Stage all in \(submodule.path)",
                    second: ("arrow.uturn.backward", "Discard all in \(submodule.path)", { model.requestDiscard([], in: submodule.path) })
                ) { model.stage([], in: submodule.path) }
                rows(unstaged, in: submodule.path)
            }
        }
    }
}

/// A submodule with changes inside it (#44): where it is, the branch
/// checked out there, and committing what is staged in it.
private struct SubmoduleHeader: View {
    @EnvironmentObject private var model: AppModel
    let submodule: SubmoduleChanges

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "shippingbox").font(.system(size: 10.5)).foregroundStyle(.secondary)
            Text(submodule.path).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.head)
            Text(submodule.branchWords)
                .font(.system(size: 10.5))
                .foregroundStyle(submodule.changes.branch == nil ? Color.orange : Color.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Button("Commit…") {
                model.submoduleMessage = ""
                model.committingSubmodule = submodule
            }
            .controlSize(.mini)
            .disabled(submodule.changes.staged.isEmpty)
            .help(submodule.changes.staged.isEmpty ? "Stage something in the submodule first" : "Commit what is staged in the submodule")
            .accessibilityLabel("Commit in \(submodule.path)")
            .accessibilityIdentifier("submodule-commit-" + submodule.path)
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.04)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("submodule-" + submodule.path)
        .help("A submodule: its changes are staged, committed and discarded in it")
    }
}

/// The message of a commit made inside a submodule.
struct SubmoduleCommitSheet: View {
    @EnvironmentObject private var model: AppModel
    let submodule: SubmoduleChanges

    private var count: Int { submodule.changes.staged.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Commit in \(submodule.path)").font(.headline)
            Text("\(count) staged \(count == 1 ? "file" : "files"), on \(submodule.branchWords). \(SubmoduleChanges.commitAdvice)")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let warning = submodule.detachedWarning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            TextField("Commit message", text: $model.submoduleMessage, axis: .vertical)
                .lineLimit(2...6)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("submodule-message")
            HStack {
                Spacer()
                Button("Cancel") { model.committingSubmodule = nil }.keyboardShortcut(.cancelAction)
                Button("Commit") { model.commitSubmodule() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.submoduleMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("submodule-commit")
            }
        }
        .padding(20)
        .frame(width: 460)
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
    /// The submodule the file is changed in (#44), where it is staged and discarded.
    var submodule: String?
    @State private var hovering = false

    private var name: String { (file.path as NSString).lastPathComponent }
    /// Where the file is; for a submodule whose commit moved, from which
    /// commit to which.
    private var directory: String { file.submoduleWords ?? (file.path as NSString).deletingLastPathComponent }
    /// Told apart from the folder's own for assistive tools and tests.
    private var place: String { submodule.map { $0 + "/" } ?? "" }

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
                if showsDirectory || file.isSubmodule {
                    Text(directory)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(file.isSubmodule ? .tail : .head)
                }
                Spacer(minLength: 4)
                // A submodule's commit has no lines to count.
                if !file.isSubmodule { DiffCount(added: file.added, deleted: file.deleted) }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                file.submoduleWords.map { "\(name), \($0), \(file.isStaged ? "staged" : "not staged")" }
                    ?? "\(name), \(file.isStaged ? "staged" : "not staged"), \(file.added) added, \(file.deleted) removed"
            )
            .accessibilityIdentifier((file.isStaged ? "staged-" : "change-") + place + file.path)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { model.openDiff(file, in: submodule) }
            if !file.isStaged {
                // Discarding is asked about first. Faint until the row is
                // under the pointer, as the button beside it is: one that
                // is not drawn at all is not there for VoiceOver either.
                Button {
                    model.requestDiscard([file], in: submodule)
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
            .accessibilityLabel((file.isStaged ? "Unstage " : "Stage ") + place + name)
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
                Button(file.isUntracked ? "Move to the Trash…" : "Discard Changes…", role: .destructive) { model.requestDiscard([file], in: submodule) }
            }
        }
    }

    private func move() {
        if file.isStaged { model.unstage([file], in: submodule) } else { model.stage([file], in: submodule) }
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
    /// A submodule's commit is taken whole: it has no lines to pick.
    private var hasParts: Bool { model.diffTabLabel == nil && !file.isSubmodule && !PatchParts.hunks(of: file.patch).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                // Of a commit, its hash; else which of the two lists it is in.
                Text(model.diffTabLabel ?? (file.conflict != nil ? "CONFLICT" : file.isStaged ? "STAGED" : "CHANGES") + (model.diffTabSubmodule.map { " IN " + $0.uppercased() } ?? ""))
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
                        model.toggleStageOfDiffTab()
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

/// A file's diff in one panel: every line in its color, lines put in and
/// taken out tinted across the pane's whole width.
///
/// One text view rather than a row for each line (#21): scrolling a diff of
/// 20,000 lines held the window up for 60 to 90 ms at each step when every
/// line was a view of its own, and only its first 4,000 lines were shown.
/// A text view lays out only what is on show, and what is selected can run
/// over as many lines as wanted.
private struct PatchView: NSViewRepresentable {
    let file: FileDiff

    private static let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage()
        let layout = LineTints()
        layout.allowsNonContiguousLayout = true
        storage.addLayoutManager(layout)
        // Lines are not wrapped: a diff reads line for line.
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        container.lineFragmentPadding = 10
        layout.addTextContainer(container)

        let text = NSTextView(frame: .zero, textContainer: container)
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.drawsBackground = true
        text.backgroundColor = NSColor(Theme.canvas)
        text.textContainerInset = NSSize(width: 0, height: 6)
        text.minSize = .zero
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = true
        text.setAccessibilityIdentifier("patch")

        let scroll = NSScrollView()
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        // Shown whenever there is something to scroll to, not only while
        // scrolling: with a trackpad macOS hides them otherwise, and then
        // nothing tells that a long line goes on to the right. Not shown
        // when everything fits.
        scroll.scrollerStyle = .legacy
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor(Theme.canvas)
        context.coordinator.text = text
        // As wide as the pane at least, so that the tints reach its right
        // edge, and wider only when a line is: kept so as the pane changes.
        scroll.contentView.postsFrameChangedNotifications = true
        context.coordinator.watching = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: scroll.contentView, queue: .main
        ) { [weak coordinator = context.coordinator] _ in coordinator?.fit() }
        show(in: context.coordinator)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        show(in: context.coordinator)
    }

    /// Puts the diff into the view when it is another than the one shown.
    /// Colored off the main thread: twenty thousand lines take a moment.
    private func show(in coordinator: Coordinator) {
        guard coordinator.patch != file.patch || coordinator.file != file.id else { return }
        let sameFile = coordinator.file == file.id
        coordinator.patch = file.patch
        coordinator.file = file.id
        let patch = file.patch
        DispatchQueue.global(qos: .userInitiated).async {
            let colored = Self.colored(patch)
            DispatchQueue.main.async {
                guard coordinator.patch == patch, let text = coordinator.text, let scroll = text.enclosingScrollView else { return }
                guard sameFile, let storage = text.textStorage, storage.length > 0, let layout = text.layoutManager, let container = text.textContainer else {
                    text.textStorage?.setAttributedString(colored)
                    coordinator.fit()
                    text.scroll(.zero)
                    coordinator.layOutTheRest()
                    return
                }
                // The same file with its diff changed stays where it was
                // scrolled to (GIT-13): only what differs is put in, so that
                // what is on show above it is not laid out anew.
                let old = storage.string as NSString, new = colored.string as NSString
                let most = min(old.length, new.length)
                var same = 0
                while same < most, old.character(at: same) == new.character(at: same) { same += 1 }
                var tail = 0
                while tail < most - same, old.character(at: old.length - 1 - tail) == new.character(at: new.length - 1 - tail) { tail += 1 }
                // The line at the top of the pane, to be there again after.
                let place = scroll.contentView.bounds.origin
                let inset = text.textContainerOrigin
                let top = layout.characterIndex(
                    for: NSPoint(x: 0, y: place.y - inset.y), in: container, fractionOfDistanceBetweenInsertionPoints: nil)
                let offset = place.y - (layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: min(top, storage.length - 1)), effectiveRange: nil).minY + inset.y)
                storage.beginEditing()
                storage.replaceCharacters(
                    in: NSRange(location: same, length: old.length - same - tail),
                    with: colored.attributedSubstring(from: NSRange(location: same, length: new.length - same - tail)))
                storage.endEditing()
                // Where that line is now: it moved by what was put in or
                // taken out above it.
                var now = top
                if top >= old.length - tail { now = top + (new.length - old.length) }
                now = max(0, min(now, storage.length - 1))
                // Laid out whole, so that where each line is is known and not guessed.
                layout.ensureLayout(for: container)
                coordinator.fit()
                let line = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: now), effectiveRange: nil)
                scroll.contentView.scroll(to: NSPoint(x: place.x, y: max(line.minY + inset.y + offset, 0)))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
    }

    final class Coordinator {
        weak var text: NSTextView?
        var patch: String?
        var file: String?
        var watching: NSObjectProtocol?

        deinit {
            if let watching { NotificationCenter.default.removeObserver(watching) }
        }

        /// The text view no smaller than the pane, and as large as its
        /// text needs beyond that.
        func fit() {
            guard let text, let scroll = text.enclosingScrollView else { return }
            text.minSize = scroll.contentSize
            text.sizeToFit()
        }

        /// Counts the texts put in: a layout begun for an earlier one stops.
        private var laying = 0

        /// Lays out what is below the pane a piece at a time, between
        /// which the window answers: the top shows at once, and how long
        /// the whole is, which the scroll bar says, is exact a moment
        /// later rather than guessed.
        func layOutTheRest() {
            laying += 1
            piece(from: 0, of: laying)
        }

        private func piece(from start: Int, of generation: Int) {
            guard generation == laying, let text, let layout = text.layoutManager, let storage = text.textStorage else { return }
            let length = min(10_000, storage.length - start)
            guard length > 0 else {
                fit()
                return
            }
            layout.ensureLayout(forCharacterRange: NSRange(location: start, length: length))
            DispatchQueue.main.async { [weak self] in self?.piece(from: start + length, of: generation) }
        }
    }

    /// The diff as text with each line's color, and its tint for the
    /// layout to draw across the pane.
    static func colored(_ patch: String) -> NSAttributedString {
        // Tabs as four blanks, as before: a diff's lines start with a mark,
        // which would put every tab stop one off.
        let text = patch.replacingOccurrences(of: "\t", with: "    ")
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        let result = NSMutableAttributedString(
            string: text, attributes: [.font: font, .foregroundColor: NSColor.white.withAlphaComponent(0.72), .paragraphStyle: paragraph])
        let hunk = NSColor(red: 0.55, green: 0.67, blue: 0.98, alpha: 1)
        let added = NSColor(Theme.added), removed = NSColor(Theme.removed)
        let whole = text as NSString
        var start = 0
        result.beginEditing()
        while start < whole.length {
            let line = whole.lineRange(for: NSRange(location: start, length: 0))
            let first = whole.character(at: line.location)
            if first == 0x40, line.length > 1, whole.character(at: line.location + 1) == 0x40 {
                result.addAttributes([.foregroundColor: hunk, LineTints.tint: NSColor.white.withAlphaComponent(0.04)], range: line)
            } else if first == 0x2B {
                result.addAttributes([.foregroundColor: added, LineTints.tint: added.withAlphaComponent(0.10)], range: line)
            } else if first == 0x2D {
                result.addAttributes([.foregroundColor: removed, LineTints.tint: removed.withAlphaComponent(0.10)], range: line)
            }
            start = NSMaxRange(line)
        }
        result.endEditing()
        return result
    }

    /// Draws a line's tint from the pane's left edge to its right, behind
    /// the text: the background of text alone ends where the line does.
    final class LineTints: NSLayoutManager {
        static let tint = NSAttributedString.Key("agentterm.lineTint")

        override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
            super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
            guard let storage = textStorage, let view = firstTextView else { return }
            let width = max(view.bounds.width, view.enclosingScrollView?.contentView.bounds.width ?? 0)
            enumerateLineFragments(forGlyphRange: glyphsToShow) { rect, _, _, glyphs, _ in
                let index = self.characterIndexForGlyph(at: glyphs.location)
                guard index < storage.length, let color = storage.attribute(Self.tint, at: index, effectiveRange: nil) as? NSColor else { return }
                color.setFill()
                NSRect(x: 0, y: rect.minY + origin.y, width: width, height: rect.height).fill(using: .sourceOver)
            }
        }
    }
}
