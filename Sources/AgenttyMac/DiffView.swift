import AgenttyHost
import SwiftUI

struct DiffView: View {
    @EnvironmentObject private var model: AppModel
    /// "list" shows every file in one flat list, "tree" groups them by folder.
    @AppStorage("diffViewMode") private var viewMode = "list"
    @State private var collapsedFolders: Set<String> = []

    private var isTree: Bool { viewMode == "tree" }

    private var selectedFile: FileDiff? {
        guard let files = model.diff?.files else { return nil }
        return files.first { $0.path == model.selectedDiffFile } ?? files.first
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Theme.hairline.frame(height: 1)
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
            Button { viewMode = isTree ? "list" : "tree" } label: {
                Image(systemName: isTree ? "list.bullet" : "list.bullet.indent")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(isTree ? "Show as a flat list" : "Group by folder")
            .accessibilityLabel(isTree ? "Show as a flat list" : "Group by folder")
            Button { model.refreshDiff() } label: {
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
        if model.selectedFolder == nil {
            placeholder("Select a folder to see its changes.")
        } else if let diff = model.diff {
            if !diff.isRepository {
                placeholder("This folder is not a git repository.")
            } else if diff.files.isEmpty {
                placeholder("No uncommitted changes.")
            } else {
                VSplitView {
                    fileList(diff.files)
                        .frame(minHeight: 70, idealHeight: 170, maxHeight: 320)
                    if let file = selectedFile {
                        PatchView(file: file)
                            .frame(minHeight: 120, maxHeight: .infinity)
                    }
                }
            }
        } else {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private func fileList(_ files: [FileDiff]) -> some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                if isTree {
                    ForEach(DiffTree.rows(for: files, collapsed: collapsedFolders)) { row in
                        switch row.kind {
                        case .folder(let expanded):
                            DiffFolderRow(row: row, expanded: expanded)
                                .onTapGesture {
                                    if expanded { collapsedFolders.insert(row.id) } else { collapsedFolders.remove(row.id) }
                                }
                        case .file(let file):
                            FileRow(file: file, selected: file.path == selectedFile?.path, showsDirectory: false, depth: row.depth)
                                .onTapGesture { model.selectedDiffFile = file.path }
                        }
                    }
                } else {
                    ForEach(files) { file in
                        FileRow(file: file, selected: file.path == selectedFile?.path)
                            .onTapGesture { model.selectedDiffFile = file.path }
                    }
                }
            }
            .padding(6)
        }
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
            Text(file.isUntracked ? "U" : "M")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(file.isUntracked ? Theme.added : Color.orange)
                .frame(width: 12)
            Text(name)
                .font(.system(size: 12))
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
        .padding(.leading, 8 + CGFloat(depth) * treeIndent)
        .padding(.trailing, 8)
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

/// One file's unified diff with added and removed lines tinted.
private struct PatchView: View {
    let file: FileDiff
    private static let maxLines = 4000

    private var lines: [(offset: Int, text: Substring)] {
        Array(file.patch.split(separator: "\n", omittingEmptySubsequences: false).prefix(Self.maxLines).enumerated())
            .map { (offset: $0.offset, text: $0.element) }
    }

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(lines, id: \.offset) { line in
                    Text(line.text.isEmpty ? " " : String(line.text))
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(foreground(line.text))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(background(line.text))
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
            .textSelection(.enabled)
        }
        .background(Theme.canvas)
        .id(file.path)
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
