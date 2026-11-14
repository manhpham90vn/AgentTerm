import AgentTermProtocol
import SwiftUI

/// The folder's git worktrees as chips (#34, #43), as on the Mac: the
/// folder's own branch first, each worktree after it with what is changed
/// in it. A touch makes the folder's Git, History and Files about that one.
/// "+" makes a new one; "⋯" is what to do with the one shown once its work
/// is done, and the folder's setup command.
struct WorktreeChips: View {
    @EnvironmentObject private var model: PhoneModel
    /// The folder the worktrees are of: the repository's own.
    let project: String
    let list: [WorktreeInfo]
    /// The worktree on show; nil for the folder itself.
    @Binding var picked: String?
    /// The folder whose changes are on show, for what a pull request needs.
    let shownPath: String

    @State private var discarding: WorktreeInfo?
    @State private var settingUp = false
    @State private var adding = false
    @State private var setup = ""

    private var shown: WorktreeInfo? { list.first { $0.path == shownPath } ?? list.first }

    private func finish(_ worktree: WorktreeInfo, _ how: WorktreeFinish, deleteBranch: Bool) {
        model.finishWorktree(worktree, of: project, how, deleteBranch: deleteBranch)
        if how != .pullRequest { picked = project }
    }

    var body: some View {
        if let shown {
            HStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(list) { worktree in chip(worktree, selected: worktree.path == shown.path) }
                    }
                }
                Button {
                    adding = true
                } label: {
                    Image(systemName: "plus").font(.system(size: 15, weight: .semibold)).frame(width: 30, height: 30)
                }
                .accessibilityLabel("New Worktree")
                .accessibilityIdentifier("worktree-add")
                Menu {
                    if !shown.isMain {
                        Button(WorktreeWords.merge(into: list.first)) { finish(shown, .merge, deleteBranch: shown.isAgentTerm) }
                            .disabled(shown.changed > 0 || shown.ahead == 0)
                        Button(WorktreeWords.pullRequest) { finish(shown, .pullRequest, deleteBranch: false) }
                            .disabled(model.diffs[shownPath]?.pushRemote == nil && model.diffs[shownPath]?.upstream == nil)
                        Button("Throw Away…", role: .destructive) { discarding = shown }
                        Divider()
                    }
                    Button("Setup Command for New Worktrees…") {
                        setup = model.worktreeSetups[project] ?? ""
                        settingUp = true
                    }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 15, weight: .semibold)).frame(width: 30, height: 30)
                }
                .accessibilityLabel("Worktree Actions")
                .accessibilityIdentifier("worktree-more")
            }
            .disabled(model.status != .connected)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .confirmationDialog(
                discarding.map(WorktreeWords.discardTitle) ?? "", isPresented: Binding(get: { discarding != nil }, set: { if !$0 { discarding = nil } }),
                titleVisibility: .visible
            ) {
                Button(WorktreeWords.discardWithBranch, role: .destructive) { if let discarding { finish(discarding, .discard, deleteBranch: true) } }
                Button(WorktreeWords.discardKeepingBranch, role: .destructive) { if let discarding { finish(discarding, .discard, deleteBranch: false) } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(discarding.map(WorktreeWords.discardMessage) ?? "")
            }
            .alert(WorktreeWords.setupTitle, isPresented: $settingUp) {
                TextField("None", text: $setup)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Save") { model.setWorktreeSetup(setup, for: project) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(WorktreeWords.setupAdvice.replacingOccurrences(of: "`", with: ""))
            }
            .sheet(isPresented: $adding) {
                NewWorktreeSheet(project: project, main: list.first, start: nil)
            }
        }
    }

    private func chip(_ worktree: WorktreeInfo, selected: Bool) -> some View {
        Button {
            picked = worktree.path
        } label: {
            HStack(spacing: 5) {
                Image(systemName: worktree.isMain ? "folder" : "arrow.triangle.branch").font(.system(size: 11))
                Text(worktree.chipTitle).font(.subheadline.weight(selected ? .semibold : .regular)).lineLimit(1)
                if !worktree.chipCounts.isEmpty {
                    Text(worktree.chipCounts).font(.caption.monospaced()).foregroundStyle(worktree.missing ? Color.red : Color.orange)
                }
                if worktree.inUse { Circle().fill(Color.green).frame(width: 6, height: 6) }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            .background(Capsule().fill(selected ? Palette.tint.opacity(0.22) : Color.primary.opacity(0.07)))
        }
        .buttonStyle(.plain)
        .disabled(worktree.missing)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(worktree.chipTitle), \(worktree.chipHelp)")
        .accessibilityIdentifier("worktree-chip-" + worktree.chipTitle)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A new branch in a new worktree: its name, suggested and editable, the
/// branch it starts from, and what is started there.
struct NewWorktreeSheet: View {
    @EnvironmentObject private var model: PhoneModel
    @Environment(\.dismiss) private var dismiss
    let project: String
    /// The folder's own worktree, when its worktrees are known.
    let main: WorktreeInfo?
    /// What is started there, when the sheet was opened for one: an agent,
    /// or a shell.
    let start: AgentInfo?
    var shell = false

    @State private var name = ""
    /// The name is the user's own once typed in, and no longer follows what is started.
    @State private var named = false
    @State private var from = ""
    /// The agent's id, or empty for a shell.
    @State private var starting = ""

    private var agent: AgentInfo? { model.installedAgents.first { $0.id == starting } }
    private var branches: [BranchInfo] { model.branches[project] ?? [] }
    private var current: String? { main?.branch ?? branches.first { $0.isCurrent }?.name }
    private var suggested: String { WorktreePath.branchName(agent: agent?.id ?? "shell", taken: Set(branches.filter { !$0.isRemote }.map(\.name))) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(
                        "Branch",
                        text: Binding(
                            get: { named ? name : suggested },
                            set: {
                                name = $0; named = true
                            })
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("worktree-branch")
                    Picker("From", selection: $from) {
                        Text(current.map { "\($0) (this folder)" } ?? "This folder's commit").tag("")
                        ForEach(branches.filter { $0.name != current || $0.isRemote }) { branch in Text(branch.name).tag(branch.name) }
                    }
                    .accessibilityIdentifier("worktree-from")
                    Picker("Start", selection: $starting) {
                        ForEach(model.installedAgents) { agent in Text(agent.name).tag(agent.id) }
                        Text("Shell").tag("")
                    }
                    .accessibilityIdentifier("worktree-start")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(WorktreeWords.newAdvice)
                        Text(WorktreeWords.setupSaid(model.worktreeSetups[project]))
                        if model.diffs[project]?.files.isEmpty == false {
                            Label(WorktreeWords.uncommitted, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        }
                    }
                }
            }
            .navigationTitle(WorktreeWords.newTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        let branch = (named ? name : suggested).trimmingCharacters(in: .whitespaces)
                        model.launchInWorktree(agent, in: project, branch: branch.isEmpty ? nil : branch, from: from.isEmpty ? nil : from)
                        dismiss()
                    }
                    .disabled(model.status != .connected)
                    .accessibilityIdentifier("worktree-create")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear {
            starting = shell ? "" : start?.id ?? model.installedAgents.first?.id ?? ""
            model.loadBranches(project)
        }
    }
}
