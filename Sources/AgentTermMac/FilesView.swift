import AgentTermEditor
import AgentTermHost
import AgentTermProtocol
import AgentTermTerminal
import Combine
import SwiftUI

/// The project folder's files: a tree to browse, create, rename and remove
/// them. A file that is clicked opens in the middle pane.
struct FilesView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var files: FilesModel
    @State private var prompt: NamePrompt?
    @State private var name = ""
    @State private var trashing: FileEntry?
    private let refresh = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    /// What a name is being asked for.
    private enum NamePrompt: Identifiable {
        case newFile(in: String)
        case newFolder(in: String)
        case rename(FileEntry)

        var id: String {
            switch self {
            case .newFile(let directory): return "file:" + directory
            case .newFolder(let directory): return "folder:" + directory
            case .rename(let entry): return "rename:" + entry.path
            }
        }

        var title: String {
            switch self {
            case .newFile: return "New File"
            case .newFolder: return "New Folder"
            case .rename(let entry): return "Rename \"\(entry.name)\""
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Theme.hairline.frame(height: 1)
            if files.root == nil {
                placeholder("Select a folder to see its files.")
            } else {
                tree
            }
        }
        .onReceive(refresh) { _ in
            if NSApp.isActive { files.refresh() }
        }
        .alert(prompt?.title ?? "", isPresented: Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } }), presenting: prompt) { prompt in
            TextField("Name", text: $name)
            Button(confirmTitle(for: prompt)) { confirm(prompt) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Move \"\(trashing?.name ?? "")\" to the Trash?", isPresented: Binding(get: { trashing != nil }, set: { if !$0 { trashing = nil } }),
            titleVisibility: .visible, presenting: trashing
        ) { entry in
            Button("Move to Trash", role: .destructive) { files.trash(entry) }
        } message: { entry in
            Text(entry.isDirectory ? "The folder and everything in it can be put back from the Trash." : "It can be put back from the Trash.")
        }
        .alert("AgentTerm", isPresented: Binding(get: { files.error != nil }, set: { if !$0 { files.error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(files.error ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(files.root.map { ($0 as NSString).lastPathComponent } ?? "Files")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            if let root = files.root {
                headerButton("doc.badge.plus", "New file") { ask(.newFile(in: root)) }
                headerButton("folder.badge.plus", "New folder") { ask(.newFolder(in: root)) }
                headerButton("arrow.clockwise", "Refresh") { files.refresh() }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private func headerButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11.5, weight: .semibold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
        .accessibilityLabel(help)
    }

    private var tree: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(files.rows) { row in
                    FileTreeRow(row: row, changed: change(for: row.entry))
                        .contextMenu { menu(for: row.entry) }
                        // The same, for who has no pointer to open the menu with.
                        .accessibilityAction(named: "Rename") { ask(.rename(row.entry)) }
                        .accessibilityAction(named: "Move to Trash") { trashing = row.entry }
                }
                if files.rows.isEmpty {
                    Text("This folder is empty.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(12)
                }
            }
            .padding(6)
        }
    }

    /// How git sees a file, to color its name as the Git tab marks it.
    private func change(for entry: FileEntry) -> FileDiff? {
        guard !entry.isDirectory, let root = files.root, entry.path.hasPrefix(root + "/") else { return nil }
        let relative = String(entry.path.dropFirst(root.count + 1))
        return model.diff?.files.first { $0.path == relative }
    }

    @ViewBuilder
    private func menu(for entry: FileEntry) -> some View {
        let directory = entry.isDirectory ? entry.path : (entry.path as NSString).deletingLastPathComponent
        Button("New File…") { ask(.newFile(in: directory)) }
        Button("New Folder…") { ask(.newFolder(in: directory)) }
        Divider()
        Button("Rename…") { ask(.rename(entry)) }
        Button("Move to Trash", role: .destructive) { trashing = entry }
        Divider()
        if !files.isRemote {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)]) }
        }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(entry.path, forType: .string)
        }
    }

    private func ask(_ prompt: NamePrompt) {
        if case .rename(let entry) = prompt { name = entry.name } else { name = "" }
        self.prompt = prompt
    }

    private func confirmTitle(for prompt: NamePrompt) -> String {
        if case .rename = prompt { return "Rename" }
        return "Create"
    }

    private func confirm(_ prompt: NamePrompt) {
        switch prompt {
        case .newFile(let directory): files.createFile(named: name, in: directory)
        case .newFolder(let directory): files.createFolder(named: name, in: directory)
        case .rename(let entry): files.rename(entry, to: name)
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
}

private struct FileTreeRow: View {
    @EnvironmentObject private var files: FilesModel
    let row: FilesModel.Row
    let changed: FileDiff?
    @State private var hovering = false

    private var entry: FileEntry { row.entry }
    private var isOpen: Bool { files.active == entry.path }
    private var isExpanded: Bool { files.expanded.contains(entry.path) }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: entry.isDirectory ? (isExpanded ? "chevron.down" : "chevron.right") : "circle.fill")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.secondary)
                .opacity(entry.isDirectory ? 1 : 0)
                .frame(width: 10)
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(entry.isDirectory ? Color.accentColor.opacity(0.9) : .secondary)
                .frame(width: 15)
            Text(entry.name)
                .font(.system(size: 12))
                .foregroundStyle(nameColor)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if let changed {
                Text(changed.isUntracked ? "U" : "M")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(changed.isUntracked ? Theme.added : Color.orange)
            }
        }
        .padding(.leading, 6 + CGFloat(row.depth) * 14)
        .padding(.trailing, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isOpen ? Color.white.opacity(0.11) : (hovering ? Color.white.opacity(0.05) : .clear))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            if entry.isDirectory { files.toggle(entry.path) } else { files.open(entry.path) }
        }
        .help(entry.path)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(entry.isDirectory ? "\(entry.name), folder, \(isExpanded ? "expanded" : "collapsed")" : entry.name)
        .accessibilityIdentifier("file-" + entry.path)
        .accessibilityAddTraits(.isButton)
        // Said to be a button, so it has to act as one for VoiceOver and
        // for anything else that presses it without a pointer.
        .accessibilityAction {
            if entry.isDirectory { files.toggle(entry.path) } else { files.open(entry.path) }
        }
    }

    private var nameColor: Color {
        guard let changed else { return .primary }
        return changed.isUntracked ? Theme.added : Color.orange
    }

    private var symbol: String {
        if entry.isDirectory { return isExpanded ? "folder.fill" : "folder" }
        switch (entry.name as NSString).pathExtension.lowercased() {
        case "md", "markdown", "txt", "rtf": return "doc.text"
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "svg", "icns", "ico": return "photo"
        case "json", "yml", "yaml", "toml", "plist", "xml", "ini", "lock": return "curlybraces"
        case "sh", "bash", "zsh": return "terminal"
        case "pdf": return "doc.richtext"
        case "zip", "tar", "gz", "dmg": return "archivebox"
        case "": return "doc"
        default: return "chevron.left.forwardslash.chevron.right"
        }
    }
}

/// A file open in the middle pane: an editor for text, a picture for an image.
struct DocumentView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var files: FilesModel

    /// Where the file is: inside the selected project, its place in the
    /// project ("my-app/src"); anywhere else, its folder on the Mac.
    private var location: String {
        let directory = (document.path as NSString).deletingLastPathComponent
        if let folder = model.panelFolder, directory == folder || directory.hasPrefix(folder + "/") {
            return (folder as NSString).lastPathComponent + directory.dropFirst(folder.count)
        }
        return (directory as NSString).abbreviatingWithTildeInPath
    }
    let document: OpenDocument
    /// Markdown opens rendered. Editing is one click away.
    @State private var previewing = true

    var body: some View {
        VStack(spacing: 0) {
            bar
            Theme.hairline.frame(height: 1)
            content
        }
        .background(Theme.canvas)
        .onChange(of: document.path) { _, _ in previewing = true }
    }

    private var bar: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder").font(.system(size: 10.5)).foregroundStyle(.secondary)
            Text(location)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 6)
            if document.hasPreview {
                Picker("Mode", selection: $previewing) {
                    Text("Preview").tag(true)
                    Text("Edit").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }
            if document.isDirty {
                Button("Revert") { files.discardChanges(document.path) }
                    .controlSize(.small)
                    .help("Throw away the changes that are not saved")
                Button("Save") { files.save(document.path) }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .help("Save (⌘S)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Theme.panel)
    }

    @ViewBuilder
    private var content: some View {
        switch document.content {
        case .text where document.isLoading:
            LoadingView("Opening the file…")
        case .text:
            if document.isMermaid, previewing {
                ScrollView {
                    MermaidView(code: document.text).padding(16)
                }
                .background(Theme.canvas)
            } else if document.isMarkdown, previewing {
                // Pictures a document on another Mac refers to are on that Mac, and are not shown.
                MarkdownPreview(
                    text: document.text,
                    baseURL: files.isRemote ? nil : URL(fileURLWithPath: (document.path as NSString).deletingLastPathComponent, isDirectory: true))
            } else {
                let path = document.path
                CodeEditor(
                    text: Binding(get: { files.documents.first { $0.path == path }?.text ?? "" }, set: { files.setText($0, for: path) }),
                    path: path
                )
            }
        case .image:
            if let image = document.imageData.flatMap(NSImage.init(data:)) ?? (files.isRemote ? nil : NSImage(contentsOfFile: document.path)) {
                // The whole picture, fitted to the pane and centered, never
                // larger than it is. A view that scrolls both ways opens a
                // tall picture scrolled part of the way down.
                GeometryReader { area in
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(
                            maxWidth: min(image.size.width, max(1, area.size.width - 32)),
                            maxHeight: min(image.size.height, max(1, area.size.height - 32))
                        )
                        .frame(width: area.size.width, height: area.size.height)
                }
            } else {
                message("This image cannot be shown.")
            }
        case .binary:
            message("This file is not text, so it is not shown here.")
        case .tooLarge(let bytes):
            message("This file is \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)), too large to open here.")
        }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
