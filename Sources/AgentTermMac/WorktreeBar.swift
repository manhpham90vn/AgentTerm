import AgentTermProtocol
import SwiftUI

/// The folder's git worktrees as chips (#43): the folder's own branch
/// first, each worktree after it with what is changed in it. A click makes
/// the side panel about that one, the first goes back to the folder. "+"
/// makes a new one; "⋯" is what to do with the one shown once its work is
/// done (#23), and the folder's setup command.
struct WorktreeBar: View {
    @EnvironmentObject private var model: AppModel
    @State private var discarding: WorktreeInfo?
    @State private var settingUp = false
    @State private var adding = false
    @State private var setup = ""

    private var folder: String? { model.selectedFolder }
    private var list: [WorktreeInfo] { folder.flatMap { model.worktrees[$0] } ?? [] }
    private var shown: WorktreeInfo? { list.first { $0.path == (model.shownWorktree ?? folder) } ?? list.first }

    var body: some View {
        // A folder that is no repository has no worktrees, its own included.
        if let folder, let shown, !list.isEmpty {
            HStack(spacing: 6) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(list) { worktree in
                            WorktreeChip(worktree: worktree, selected: worktree.path == shown.path) {
                                model.shownWorktree = worktree.isMain ? nil : worktree.path
                            }
                        }
                    }
                }
                Button {
                    adding = true
                } label: {
                    Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .help("A new branch in a new worktree, with an agent or a shell started there")
                .accessibilityLabel("New Worktree")
                .accessibilityIdentifier("worktree-add")
                .disabled(model.status != .connected)
                Menu {
                    if !shown.isMain {
                        Button(WorktreeWords.merge(into: list.first)) {
                            model.finishWorktree(shown, of: folder, .merge, deleteBranch: shown.isAgentTerm)
                            model.shownWorktree = nil
                        }
                        .disabled(shown.changed > 0 || shown.ahead == 0)
                        Button(WorktreeWords.pullRequest) { model.finishWorktree(shown, of: folder, .pullRequest, deleteBranch: false) }
                            .disabled(model.diff?.pushRemote == nil && model.diff?.upstream == nil)
                        Button("Throw Away…", role: .destructive) { discarding = shown }
                        Divider()
                    }
                    Button("Setup Command for New Worktrees…") {
                        setup = model.worktreeSetups[folder] ?? ""
                        settingUp = true
                    }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 11, weight: .semibold))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(shown.isMain ? "The setup command of new worktrees" : "Merge \(shown.chipTitle), open a pull request for it, or throw it away")
                .accessibilityLabel("Worktree Actions")
                .accessibilityIdentifier("worktree-more")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.03))
            .confirmationDialog(
                discarding.map(WorktreeWords.discardTitle) ?? "", isPresented: Binding(get: { discarding != nil }, set: { if !$0 { discarding = nil } }),
                titleVisibility: .visible
            ) {
                Button(WorktreeWords.discardWithBranch, role: .destructive) {
                    if let discarding { model.finishWorktree(discarding, of: folder, .discard, deleteBranch: true) }
                    model.shownWorktree = nil
                }
                Button(WorktreeWords.discardKeepingBranch, role: .destructive) {
                    if let discarding { model.finishWorktree(discarding, of: folder, .discard, deleteBranch: false) }
                    model.shownWorktree = nil
                }
            } message: {
                Text(discarding.map(WorktreeWords.discardMessage) ?? "")
            }
            .sheet(isPresented: $settingUp) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(WorktreeWords.setupTitle).font(.headline)
                    Text(.init(WorktreeWords.setupAdvice))
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    TextField("None", text: $setup).textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("worktree-setup")
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
            .sheet(isPresented: $adding) {
                NewWorktreeSheet(folder: folder, main: list.first) { adding = false }
            }
        }
    }
}

/// One worktree of the bar: its branch, and what is changed in it.
private struct WorktreeChip: View {
    let worktree: WorktreeInfo
    let selected: Bool
    let pick: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: pick) {
            HStack(spacing: 4) {
                Image(systemName: worktree.isMain ? "folder" : "arrow.triangle.branch").font(.system(size: 9.5))
                Text(worktree.chipTitle).font(.system(size: 11.5, weight: selected ? .semibold : .regular)).lineLimit(1)
                if !worktree.chipCounts.isEmpty {
                    Text(worktree.chipCounts).font(.system(size: 10, design: .monospaced)).foregroundStyle(worktree.missing ? Color.red : Color.orange)
                }
                if worktree.inUse { Circle().fill(Color.green).frame(width: 5, height: 5) }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(selected ? .primary : .secondary)
            .background(Capsule().fill(Color.white.opacity(selected ? 0.14 : hovering ? 0.07 : 0.04)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(worktree.missing)
        .onHover { hovering = $0 }
        .help(worktree.chipHelp + "\n" + (worktree.path as NSString).abbreviatingWithTildeInPath)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(worktree.chipTitle), \(worktree.chipHelp)")
        .accessibilityIdentifier("worktree-chip-" + worktree.chipTitle)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { pick() }
    }
}

/// A new branch in a new worktree: its name, suggested and editable, the
/// branch it starts from, and what is started there.
private struct NewWorktreeSheet: View {
    @EnvironmentObject private var model: AppModel
    let folder: String
    let main: WorktreeInfo?
    let close: () -> Void

    @State private var name = ""
    /// The name is the user's own once typed in, and no longer follows what is started.
    @State private var named = false
    @State private var from = ""
    /// The agent's id, or empty for a shell.
    @State private var start = ""

    private var agent: AgentInfo? { model.installedAgents.first { $0.id == start } }
    private var locals: [BranchInfo] { model.branches.filter { !$0.isRemote } }
    private var suggested: String { WorktreePath.branchName(agent: agent?.id ?? "shell", taken: Set(locals.map(\.name))) }
    private var uncommitted: Bool { model.shownWorktree == nil && model.diff?.files.isEmpty == false }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(WorktreeWords.newTitle).font(.headline)
            Text(WorktreeWords.newAdvice).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                TextField(
                    "Branch",
                    text: Binding(
                        get: { named ? name : suggested },
                        set: {
                            name = $0; named = true
                        })
                )
                .accessibilityIdentifier("worktree-branch")
                Picker("From", selection: $from) {
                    Text(main?.branch.map { "\($0) (this folder)" } ?? "This folder's commit").tag("")
                    ForEach(model.branches.filter { $0.name != main?.branch || $0.isRemote }) { branch in
                        Text(branch.name).tag(branch.name)
                    }
                }
                .accessibilityIdentifier("worktree-from")
                Picker("Start", selection: $start) {
                    ForEach(model.installedAgents) { agent in Text(agent.name).tag(agent.id) }
                    Text("Shell").tag("")
                }
                .accessibilityIdentifier("worktree-start")
            }
            Text(WorktreeWords.setupSaid(model.worktreeSetups[folder])).font(.system(size: 11)).foregroundStyle(.secondary)
            if uncommitted {
                Label(WorktreeWords.uncommitted, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button("Create") {
                    let branch = (named ? name : suggested).trimmingCharacters(in: .whitespaces)
                    model.launchInWorktree(agent, branch: branch.isEmpty ? nil : branch, from: from.isEmpty ? nil : from, confirmed: true)
                    close()
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("worktree-create")
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            start = model.installedAgents.first?.id ?? ""
            model.loadBranches()
        }
    }
}
