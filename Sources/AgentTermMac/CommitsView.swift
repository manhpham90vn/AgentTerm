import AgentTermProtocol
import SwiftUI

/// The commits of a branch in the Git tab (#36): newest first, with a graph
/// of where branches part and meet. A commit that is pressed opens out to
/// its message and the files it changed; a file shows its diff in the
/// middle pane, as a change does.
struct CommitsList: View {
    @EnvironmentObject private var model: AppModel

    private var current: String? { model.diff?.branch }

    private var chosen: Binding<String> {
        Binding(get: { model.commitsBranch ?? "" }, set: { model.commitsBranch = $0.isEmpty ? nil : $0 })
    }

    private var currentTitle: String {
        if let current { return current + " (checked out)" }
        return "the checked out commit"
    }

    private var others: [BranchInfo] { model.branches.filter { !$0.isCurrent } }

    private var chooser: some View {
        HStack(spacing: 6) {
            Text("Commits of").font(.system(size: 11)).foregroundStyle(.secondary)
            Picker("Commits of", selection: chosen) {
                Text(currentTitle).tag("")
                ForEach(others) { branch in
                    Text(branch.name).tag(branch.name)
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            .accessibilityIdentifier("commits-branch")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var body: some View {
        VStack(spacing: 0) {
            chooser
            Theme.hairline.frame(height: 1)
            if model.commits.isEmpty && model.loadingCommits {
                placeholder("Reading the history…")
            } else if model.commits.isEmpty {
                placeholder("No commits yet.")
            } else {
                list
            }
        }
        .onAppear {
            model.loadBranches()
            model.loadCommits()
        }
        // A commit, a pull, a revert or another branch: the history is another.
        .onChange(of: model.diff?.branch) { _ in model.loadCommits() }
        .onChange(of: model.diff?.ahead) { _ in model.loadCommits() }
        .onChange(of: model.diff?.behind) { _ in model.loadCommits() }
        .onChange(of: model.panelFolder) { _ in model.loadCommits() }
        .onChange(of: model.isCommitting) { committing in if !committing { model.loadCommits() } }
        .onChange(of: model.syncing) { _ in model.loadCommits() }
    }

    private var list: some View {
        let rows = CommitGraphRow.rows(for: model.commits)
        let lanes = min(rows.map(\.width).max() ?? 1, CommitGraph.mostLanes)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(model.commits.enumerated()), id: \.element.hash) { index, commit in
                    // The commit the checked out branch is at can be amended and undone.
                    CommitRow(commit: commit, graph: rows[index], lanes: lanes, onBranch: current, isLast: index == 0 && model.commitsBranch == nil)
                }
                if model.commitsMore {
                    // Coming into view, it asks for the next page.
                    HStack {
                        Spacer()
                        ProgressView().controlSize(.small)
                        Spacer()
                    }
                    .padding(.vertical, 8)
                    .onAppear { model.loadMoreCommits() }
                }
            }
            .padding(.vertical, 4)
        }
    }
}

/// The lines and the dot of one row of the graph.
struct CommitGraph: View {
    let row: CommitGraphRow
    let lanes: Int
    /// Where the dot is, from the top: the middle of the row's first line,
    /// also when the row has opened out below it.
    static let dotY: CGFloat = 15
    static let laneWidth: CGFloat = 12
    /// Lanes past this are drawn in the last: a history that wide is rare,
    /// and the list has to keep room for its words.
    static let mostLanes = 6

    static let colors: [Color] = [.blue, .orange, .green, .purple, .pink, .teal]

    private func x(_ lane: Int) -> CGFloat { (CGFloat(min(lane, Self.mostLanes - 1)) + 0.5) * Self.laneWidth }

    var body: some View {
        Canvas { context, size in
            func line(from: CGPoint, to: CGPoint, lane: Int) {
                var path = Path()
                path.move(to: from)
                if from.x == to.x {
                    path.addLine(to: to)
                } else {
                    // A lane that joins or leaves the commit's: a curve.
                    let middle = (from.y + to.y) / 2
                    path.addCurve(to: to, control1: CGPoint(x: from.x, y: middle), control2: CGPoint(x: to.x, y: middle))
                }
                context.stroke(path, with: .color(Self.colors[lane % Self.colors.count].opacity(0.85)), lineWidth: 1.5)
            }
            for (from, to) in row.incoming { line(from: CGPoint(x: x(from), y: 0), to: CGPoint(x: x(to), y: Self.dotY), lane: from) }
            for (to, from) in row.outgoing { line(from: CGPoint(x: x(from), y: Self.dotY), to: CGPoint(x: x(to), y: size.height), lane: to) }
            let dot = CGRect(x: x(row.lane) - 3.5, y: Self.dotY - 3.5, width: 7, height: 7)
            context.fill(Path(ellipseIn: dot), with: .color(Self.colors[row.lane % Self.colors.count]))
        }
        .frame(width: CGFloat(lanes) * Self.laneWidth)
        .accessibilityHidden(true)
    }
}

private struct CommitRow: View {
    @EnvironmentObject private var model: AppModel
    let commit: CommitInfo
    let graph: CommitGraphRow
    let lanes: Int
    /// The branch that is checked out, which a revert or a pick lands on.
    let onBranch: String?
    /// The commit the checked out branch is at: amended and undone (#41).
    var isLast = false
    @State private var hovering = false

    private var opened: Bool { model.openedCommit == commit.hash }

    private static let ago: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private var byline: String { commit.author + " · " + Self.ago.localizedString(for: commit.date, relativeTo: Date()) }

    private var label: String {
        commit.subject + ", " + byline + (commit.refs.isEmpty ? "" : ", " + commit.refs.joined(separator: ", ")) + (opened ? ", opened" : "")
    }

    private func toggle() { model.toggle(commit) }
    private func copy() { model.copyHash(of: commit) }
    private func revert() { model.pendingCommitAction = .init(action: .revert, commit: commit) }
    private func pick() { model.pendingCommitAction = .init(action: .cherryPick, commit: commit) }
    private func amend() { if isLast { model.requestAmend() } }
    private func undo() { if isLast { model.requestUndoCommit() } }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            CommitGraph(row: graph, lanes: lanes)
            VStack(alignment: .leading, spacing: 0) {
                summary
                if opened { CommitDetailsView(commit: commit) }
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
    }

    // In pieces of their own: as one expression the row took the compiler
    // longer to type-check than the build that CodeQL watches allows.

    /// A branch or a tag that points at the commit.
    private func refChip(_ ref: String) -> some View {
        let shape = RoundedRectangle(cornerRadius: 3, style: .continuous)
        return Text(ref)
            .font(.system(size: 9.5, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(shape.fill(Color.accentColor.opacity(0.22)))
            .fixedSize()
    }

    private var fill: Color {
        if opened { return Color.white.opacity(0.09) }
        return hovering ? Color.white.opacity(0.05) : Color.clear
    }

    private var pickTitle: String {
        let onto = onBranch.map { "“" + $0 + "”" } ?? "the Checked Out Commit"
        return "Cherry-Pick onto " + onto + "…"
    }

    @ViewBuilder private var menu: some View {
        Button("Copy Hash", action: copy)
        if isLast {
            Divider()
            Button("Amend…", action: amend)
            Button("Undo Commit…", action: undo)
        }
        Divider()
        Button("Revert…", action: revert)
        Button(pickTitle, action: pick)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 5) {
                Text(commit.subject)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.tail)
                ForEach(Array(commit.refs.prefix(2)), id: \.self) { ref in refChip(ref) }
            }
            Text(byline)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: CommitGraph.dotY * 2, alignment: .leading)
        .padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(fill))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: toggle)
        .help(commit.short + " " + commit.subject)
        .contextMenu { menu }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityIdentifier("commit-" + commit.short)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, toggle)
        .accessibilityAction(named: "Copy Hash", copy)
        .accessibilityAction(named: "Revert", revert)
        .accessibilityAction(named: "Cherry-Pick", pick)
        .accessibilityAction(named: "Amend", amend)
        .accessibilityAction(named: "Undo Commit", undo)
    }
}

/// A commit opened out: its hash, the rest of its message, and its files.
private struct CommitDetailsView: View {
    @EnvironmentObject private var model: AppModel
    let commit: CommitInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(commit.short)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Button("Copy Hash") { model.copyHash(of: commit) }
                    .controlSize(.mini)
                    .accessibilityIdentifier("copy-hash")
                Spacer(minLength: 0)
            }
            if let details = model.commitDetails[commit.hash] {
                if !details.body.isEmpty {
                    Text(details.body)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if details.files.isEmpty {
                    Text("It changed no file.").font(.system(size: 11)).foregroundStyle(.tertiary)
                } else if details.diffsLeftOut {
                    Text("Its diffs are too large to show here.").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                ForEach(details.files) { file in
                    CommitFileRow(file: file, commit: commit)
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }
}

/// One file a commit changed. Pressed, its diff shows in the middle pane.
private struct CommitFileRow: View {
    @EnvironmentObject private var model: AppModel
    let file: FileDiff
    let commit: CommitInfo
    @State private var hovering = false

    private var name: String { (file.path as NSString).lastPathComponent }
    private var selected: Bool { model.diffTabCommit?.hash == commit.hash && model.diffTabFile?.path == file.path }
    private func open() { model.openDiff(file, of: commit) }

    var body: some View {
        HStack(spacing: 6) {
            Text(file.marker)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(file.status == .added ? Theme.added : (file.status == .deleted ? Theme.removed : .orange))
                .frame(width: 12)
            Text(name)
                .font(.system(size: 11.5))
                .strikethrough(file.status == .deleted)
                .lineLimit(1)
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
        .accessibilityLabel("\(name), in \(commit.short), \(file.added) added, \(file.deleted) removed")
        .accessibilityIdentifier("commit-file-" + file.path)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, open)
    }
}
