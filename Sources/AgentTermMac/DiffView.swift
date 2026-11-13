import AgentTermHost
import AgentTermProtocol
import AgentTermTerminal
import SwiftUI

struct DiffView: View {
    @EnvironmentObject private var model: AppModel
    /// "list" shows every file in one flat list, "tree" groups them by folder.
    @AppStorage("diffViewMode") private var viewMode = "list"
    @State private var collapsedFolders: Set<String> = []

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
            content
        }
        .background(Theme.panel)
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let branch = model.diff?.branch {
                Label(branch, systemImage: "arrow.triangle.branch")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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
            } else if diff.files.isEmpty {
                placeholder("No uncommitted changes.")
            } else {
                // The list only: a file that is clicked shows its diff in the middle pane.
                VStack(spacing: 0) {
                    CommitBox(stagedCount: diff.staged.count)
                    Theme.hairline.frame(height: 1)
                    fileList(diff)
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
                if !staged.isEmpty {
                    ChangesHeader(title: "Staged", count: staged.count, symbol: "minus", help: "Unstage all") { model.unstage([]) }
                    rows(staged)
                }
                if !unstaged.isEmpty {
                    ChangesHeader(title: "Changes", count: unstaged.count, symbol: "plus", help: "Stage all") { model.stage([]) }
                        .padding(.top, staged.isEmpty ? 0 : 6)
                    rows(unstaged)
                }
            }
            .padding(6)
        }
    }

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

/// Push and pull for the branch that is checked out, with how far it is
/// from the branch it follows.
private struct SyncBar: View {
    @EnvironmentObject private var model: AppModel
    let diff: DiffSnapshot

    private var busy: String? { model.panelFolder.flatMap { model.syncing[$0] } }

    var body: some View {
        HStack(spacing: 6) {
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
            Spacer(minLength: 4)
            Text(diff.upstream ?? "not on a remote yet")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.head)
        }
        .disabled(busy != nil)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

private struct SyncButton: View {
    let title: String
    let symbol: String
    let count: Int
    let working: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if working {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: symbol).font(.system(size: 9.5, weight: .bold))
                }
                Text(title)
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

    private var canCommit: Bool {
        stagedCount > 0 && !model.isCommitting && !message.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isWriting: Bool { model.panelFolder.map(model.writingCommitMessage.contains) ?? false }

    /// The agent that would write the message: the one chosen in Settings,
    /// or the first one installed.
    private var writer: AgentInfo? {
        model.commitWriter.writer(among: model.agents)
    }

    var body: some View {
        VStack(spacing: 6) {
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
                        Text(stagedCount > 0 ? "Commit \(stagedCount) \(stagedCount == 1 ? "File" : "Files")" : "Commit")
                    }
                    .frame(maxWidth: .infinity)
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .disabled(!canCommit)
                .help(stagedCount == 0 ? "Stage the changes to commit first" : "Commit what is staged")
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
    let action: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
            Spacer()
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

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(file.isStaged ? "STAGED" : "CHANGES")
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
                Button(file.isStaged ? "Unstage" : "Stage") {
                    if file.isStaged { model.unstage([file]) } else { model.stage([file]) }
                }
                .controlSize(.small)
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
