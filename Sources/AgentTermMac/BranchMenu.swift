import AgentTermProtocol
import SwiftUI

/// The checked out branch in the Git tab's header (#35). Pressed, it lists
/// the repository's branches, to switch to one, make one, rename or delete
/// one.
struct BranchButton: View {
    @EnvironmentObject private var model: AppModel
    /// Nil for a detached HEAD.
    let branch: String?
    @State private var showing = false

    var body: some View {
        Button {
            showing = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.branch")
                Text(branch ?? "detached HEAD").lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Branches: switch, make, rename, delete")
        .accessibilityLabel("Branch \(branch ?? "detached HEAD")")
        .accessibilityIdentifier("branch-menu")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            BranchList { showing = false }
                .environmentObject(model)
        }
    }
}

/// The branches, the repository's own first, with a field that narrows
/// them down and makes a new one of what was typed.
private struct BranchList: View {
    @EnvironmentObject private var model: AppModel
    let close: () -> Void
    @State private var filter = ""
    /// Making a branch: its name, what it starts from, and whether it is
    /// checked out at once.
    @State private var making = false
    @State private var newName = ""
    @State private var from = ""
    @State private var checkout = true
    @State private var renaming: BranchInfo?
    @State private var renamed = ""

    private var current: BranchInfo? { model.branches.first(where: \.isCurrent) }

    private func shown(remote: Bool) -> [BranchInfo] {
        let wanted = filter.trimmingCharacters(in: .whitespaces).lowercased()
        return model.branches.filter { $0.isRemote == remote && (wanted.isEmpty || $0.name.lowercased().contains(wanted)) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if making {
                form
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
                    TextField("Find a branch", text: $filter)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .accessibilityIdentifier("branch-filter")
                    Button {
                        newName = filter.trimmingCharacters(in: .whitespaces)
                        from = current?.name ?? ""
                        making = true
                    } label: {
                        Label("New Branch…", systemImage: "plus").font(.system(size: 11, weight: .medium))
                    }
                    .controlSize(.small)
                    .accessibilityIdentifier("new-branch")
                }
                .padding(10)
                Theme.hairline.frame(height: 1)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        section("Branches", shown(remote: false))
                        section("Remote Branches", shown(remote: true))
                        if model.branches.isEmpty {
                            Text("Reading the branches…").font(.system(size: 11)).foregroundStyle(.secondary).padding(12)
                        }
                    }
                    .padding(6)
                }
            }
        }
        .frame(width: 340, height: making ? nil : 380)
        .onAppear { model.loadBranches() }
        .alert("Rename “\(renaming?.name ?? "")”", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renamed)
            Button("Rename") {
                if let renaming { model.renameBranch(renaming, to: renamed) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        // Asked first, and twice for a branch with commits of its own.
        .confirmationDialog(
            question?.title ?? "", isPresented: Binding(get: { model.deletingBranch != nil }, set: { if !$0 { model.deletingBranch = nil } }),
            titleVisibility: .visible
        ) {
            Button(question?.confirm ?? "Delete", role: .destructive) { model.deleteBranchConfirmed() }
            Button("Cancel", role: .cancel) { model.deletingBranch = nil }
        } message: {
            Text(question?.message ?? "")
        }
    }

    private var question: DeleteBranchQuestion? {
        model.deletingBranch.map { DeleteBranchQuestion(branch: $0.branch, into: current?.name, again: $0.again) }
    }

    @ViewBuilder
    private func section(_ title: String, _ list: [BranchInfo]) -> some View {
        if !list.isEmpty {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.top, 6)
                .padding(.bottom, 2)
            ForEach(list) { branch in
                BranchRow(branch: branch) {
                    model.switchBranch(branch)
                    close()
                } newFromHere: {
                    newName = ""
                    from = branch.name
                    making = true
                } rename: {
                    renamed = branch.name
                    renaming = branch
                }
            }
        }
    }

    /// A new branch: its name, what it starts from, whether to switch to it.
    private var form: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New Branch").font(.system(size: 12, weight: .semibold))
            TextField("Name", text: $newName)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .accessibilityIdentifier("new-branch-name")
                .onSubmit(make)
            Picker("From", selection: $from) {
                ForEach(model.branches) { branch in
                    Text(branch.name).tag(branch.name)
                }
            }
            .font(.system(size: 12))
            .accessibilityIdentifier("new-branch-from")
            Toggle("Switch to it", isOn: $checkout)
                .font(.system(size: 12))
                .accessibilityIdentifier("new-branch-switch")
            HStack {
                Spacer()
                Button("Cancel") { making = false }
                Button("Create Branch", action: make)
                    .keyboardShortcut(.defaultAction)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("new-branch-create")
            }
        }
        .padding(14)
    }

    private func make() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        model.createBranch(named: name, from: from.isEmpty ? nil : from, checkout: checkout)
        making = false
        if checkout { close() }
    }
}

/// One branch: its name, how far it is from the branch it follows, and
/// when it was last committed to. Pressed, it is checked out.
private struct BranchRow: View {
    @EnvironmentObject private var model: AppModel
    let branch: BranchInfo
    let switchTo: () -> Void
    let newFromHere: () -> Void
    let rename: () -> Void
    @State private var hovering = false

    /// Why it cannot be switched to, when it cannot.
    private var held: String? {
        if branch.isCurrent { return "Checked out here" }
        if let worktree = branch.worktree { return "Checked out in the worktree at " + (worktree as NSString).abbreviatingWithTildeInPath }
        return nil
    }

    private var detail: String {
        var parts: [String] = []
        if !branch.tracking.isEmpty { parts.append(branch.tracking) }
        if branch.worktree != nil { parts.append("in a worktree") }
        if let date = branch.committedAt { parts.append(Self.ago.localizedString(for: date, relativeTo: Date())) }
        return parts.joined(separator: " · ")
    }

    private static let ago: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private var label: String {
        branch.name + (branch.isCurrent ? ", checked out" : "") + (detail.isEmpty ? "" : ", " + detail)
    }

    private var tip: String {
        if let held { return held }
        return branch.subject.isEmpty ? "Switch to \(branch.name)" : "Switch to \(branch.name): \(branch.subject)"
    }

    private var canDelete: Bool { !branch.isRemote && !branch.isCurrent && branch.worktree == nil }

    private func pressed() {
        if held == nil { switchTo() }
    }

    private func delete() {
        if canDelete { model.requestDeleteBranch(branch) }
    }

    private var row: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .bold))
                .opacity(branch.isCurrent ? 1 : 0)
                .frame(width: 12)
            Text(branch.name)
                .font(.system(size: 12, weight: branch.isCurrent ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            Text(detail)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering && held == nil ? Color.white.opacity(0.07) : .clear))
        .contentShape(Rectangle())
    }

    var body: some View {
        row
            .onHover { hovering = $0 }
            .onTapGesture(perform: pressed)
            .help(tip)
            .contextMenu {
                Button("Switch to “\(branch.name)”", action: switchTo).disabled(held != nil)
                Button("New Branch from “\(branch.name)”…", action: newFromHere)
                if !branch.isRemote {
                    Button("Rename…", action: rename)
                    Button("Delete…", role: .destructive, action: delete).disabled(!canDelete)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityIdentifier("branch-" + branch.id)
            .accessibilityAddTraits(branch.isCurrent ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction(.default, pressed)
            .accessibilityAction(named: "New Branch from Here", newFromHere)
            .accessibilityAction(named: "Rename", rename)
            .accessibilityAction(named: "Delete", delete)
    }
}
