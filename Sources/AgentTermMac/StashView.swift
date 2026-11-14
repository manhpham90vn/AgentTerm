import AgentTermProtocol
import SwiftUI

/// The stash of the folder's repository in the Git tab (#38): putting the
/// changes aside under a name, and what was put aside, newest first. A
/// stash that is pressed opens out to its files; a file shows its diff in
/// the middle pane, as a change does.
struct StashesList: View {
    @EnvironmentObject private var model: AppModel
    @State private var naming = false
    @State private var name = ""
    @State private var includeNew = true

    /// Whether there is anything to put aside.
    private var hasChanges: Bool { !(model.diff?.files.isEmpty ?? true) }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var bar: some View {
        HStack(spacing: 6) {
            Button {
                name = ""
                naming = true
            } label: {
                Label("Stash Changes…", systemImage: "tray.and.arrow.down").font(.system(size: 11, weight: .medium))
            }
            .controlSize(.small)
            .disabled(!hasChanges)
            .help(hasChanges ? "Put the changes aside under a name, and have the folder as it was committed" : "There is no change to stash")
            .accessibilityIdentifier("stash-changes")
            .popover(isPresented: $naming, arrowEdge: .bottom) { form }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Stash Changes").font(.system(size: 12, weight: .semibold))
            TextField("A name, to find it again (optional)", text: $name)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .frame(width: 280)
                .accessibilityIdentifier("stash-name")
                .onSubmit(put)
            Toggle("Include new files", isOn: $includeNew)
                .font(.system(size: 12))
                .help("Files git does not track yet are put aside too; off, they stay in the folder")
                .accessibilityIdentifier("stash-untracked")
            HStack {
                Spacer()
                Button("Cancel") { naming = false }
                Button("Stash", action: put)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("stash-confirm")
            }
        }
        .padding(14)
    }

    private func put() {
        model.stash(named: name, untracked: includeNew)
        naming = false
    }

    var body: some View {
        VStack(spacing: 0) {
            bar
            Theme.hairline.frame(height: 1)
            if model.stashes.isEmpty {
                placeholder("Nothing is stashed. Stash Changes puts what is not committed aside, to bring back later.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(model.stashes) { stash in
                            StashRow(stash: stash)
                        }
                    }
                    .padding(6)
                }
            }
        }
        .onAppear { model.loadStashes() }
        .onChange(of: model.panelFolder) { _ in model.loadStashes() }
        .onChange(of: model.diff?.branch) { _ in model.loadStashes() }
    }
}

private struct StashRow: View {
    @EnvironmentObject private var model: AppModel
    let stash: StashInfo
    @State private var hovering = false

    private var opened: Bool { model.openedStash == stash.hash }

    private static let ago: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private var byline: String {
        (stash.branch.map { "on \($0) · " } ?? "") + Self.ago.localizedString(for: stash.date, relativeTo: Date())
    }

    private func toggle() { model.toggle(stash) }
    private func apply() { model.applyStash(stash, pop: false) }
    private func pop() { model.applyStash(stash, pop: true) }
    private func drop() { model.droppingStash = stash }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(stash.message).font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
            Text(byline).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(opened ? Color.white.opacity(0.09) : (hovering ? Color.white.opacity(0.05) : .clear)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: toggle)
        .help(stash.ref + ": " + stash.message)
        .contextMenu {
            Button("Apply", action: apply)
            Button("Pop", action: pop)
            Divider()
            Button("Drop…", role: .destructive, action: drop)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(stash.message + ", " + byline + (opened ? ", opened" : ""))
        .accessibilityIdentifier("stash-" + stash.ref)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, toggle)
        .accessibilityAction(named: "Apply", apply)
        .accessibilityAction(named: "Pop", pop)
        .accessibilityAction(named: "Drop", drop)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button("Apply", action: apply)
                    .help("Bring it back into the folder, and keep it in the stash")
                    .accessibilityIdentifier("stash-apply")
                Button("Pop", action: pop)
                    .help("Bring it back into the folder, and take it out of the stash")
                    .accessibilityIdentifier("stash-pop")
                Button("Drop…", role: .destructive, action: drop)
                    .help("Throw it away")
                    .accessibilityIdentifier("stash-drop")
                Spacer(minLength: 0)
            }
            .controlSize(.small)
            if let files = model.stashFiles[stash.hash] {
                if files.isEmpty { Text("It holds no file.").font(.system(size: 11)).foregroundStyle(.tertiary) }
                ForEach(files) { file in
                    StashFileRow(file: file, stash: stash)
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            summary
            if opened { details }
        }
    }
}

/// One file a stash holds. Pressed, its diff shows in the middle pane.
private struct StashFileRow: View {
    @EnvironmentObject private var model: AppModel
    let file: FileDiff
    let stash: StashInfo
    @State private var hovering = false

    private var name: String { (file.path as NSString).lastPathComponent }
    private var selected: Bool { model.diffTabCommit?.hash == stash.hash && model.diffTabFile?.path == file.path }
    private func open() { model.openDiff(file, of: stash) }

    var body: some View {
        HStack(spacing: 6) {
            Text(file.marker)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(file.status == .added ? Theme.added : (file.status == .deleted ? Theme.removed : .orange))
                .frame(width: 12)
            Text(name).font(.system(size: 11.5)).lineLimit(1)
            Text((file.path as NSString).deletingLastPathComponent)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 4)
            DiffCount(added: file.added, deleted: file.deleted)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(selected ? Color.white.opacity(0.11) : (hovering ? Color.white.opacity(0.05) : .clear)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: open)
        .help(file.path)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), in the stash, \(file.added) added, \(file.deleted) removed")
        .accessibilityIdentifier("stash-file-" + file.path)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, open)
    }
}
