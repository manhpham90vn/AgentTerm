import AgentTermEditor
import AgentTermProtocol
import SwiftUI

/// A folder's files on the Mac: a tree to browse, create, rename and remove
/// them. Tapping a file opens it.
struct FilesList: View {
    @EnvironmentObject private var model: PhoneModel
    let folder: String
    @State private var expanded: Set<String> = []
    @State private var prompt: NamePrompt?
    @State private var name = ""
    @State private var trashing: FileEntry?

    /// What a name is being asked for.
    private struct NamePrompt: Identifiable {
        enum Kind { case newFile, newFolder, rename }
        let kind: Kind
        /// The folder to create in, or the item to rename.
        let path: String
        var id: String { "\(kind)\(path)" }

        var title: String {
            switch kind {
            case .newFile: return "New File"
            case .newFolder: return "New Folder"
            case .rename: return "Rename"
            }
        }
    }

    private struct Row: Identifiable {
        let entry: FileEntry
        let depth: Int
        var id: String { entry.path }
    }

    /// The tree as shown: a folder that is open is followed by what is in it.
    private var rows: [Row] {
        var result: [Row] = []
        func add(_ directory: String, depth: Int) {
            for entry in model.fileListings[directory] ?? [] {
                result.append(Row(entry: entry, depth: depth))
                if entry.isDirectory, expanded.contains(entry.path) { add(entry.path, depth: depth + 1) }
            }
        }
        add(folder, depth: 0)
        return result
    }

    var body: some View {
        Group {
            if model.fileListings[folder] != nil {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        HStack(spacing: 18) {
                            Text((folder as NSString).lastPathComponent)
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer()
                            Button {
                                ask(.newFile, folder)
                            } label: {
                                Image(systemName: "doc.badge.plus").font(.system(size: 16, weight: .medium))
                            }
                            .accessibilityLabel("New File")
                            Button {
                                ask(.newFolder, folder)
                            } label: {
                                Image(systemName: "folder.badge.plus").font(.system(size: 16, weight: .medium))
                            }
                            .accessibilityLabel("New Folder")
                        }
                        .padding(.horizontal, 6)
                        .padding(.bottom, 10)
                        let rows = rows
                        if rows.isEmpty {
                            Text("This folder is empty.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .padding(.top, 40)
                        } else {
                            VStack(spacing: 0) {
                                ForEach(rows) { row in
                                    rowView(row)
                                    if row.id != rows.last?.id {
                                        Palette.hairline.frame(height: 1).padding(.leading, 44 + CGFloat(row.depth) * 16)
                                    }
                                }
                            }
                            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.panel))
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
                .refreshable { reload() }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear(perform: reload)
        .alert(prompt?.title ?? "", isPresented: Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } }), presenting: prompt) { prompt in
            TextField("Name", text: $name)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button(prompt.kind == .rename ? "Rename" : "Create") { finish(prompt) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Move \"\(trashing?.name ?? "")\" to the Mac's Trash?",
            isPresented: Binding(get: { trashing != nil }, set: { if !$0 { trashing = nil } }),
            titleVisibility: .visible, presenting: trashing
        ) { entry in
            Button("Move to Trash", role: .destructive) { model.trashFile(entry.path) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("It can be put back from the Trash on the Mac.")
        }
        .onChange(of: model.createdFile) { _, created in
            // A file that was just created opens, to be written.
            guard let created, created.hasPrefix(folder + "/") else { return }
            model.createdFile = nil
            let parent = (created as NSString).deletingLastPathComponent
            if parent != folder { expanded.insert(parent) }
            model.path.append(Route.document(path: created))
        }
    }

    @ViewBuilder
    private func rowView(_ row: Row) -> some View {
        let entry = row.entry
        Group {
            if entry.isDirectory {
                Button {
                    toggle(entry.path)
                } label: {
                    FileTreeRow(entry: entry, depth: row.depth, isExpanded: expanded.contains(entry.path), marker: nil)
                }
                .buttonStyle(.plain)
            } else {
                NavigationLink(value: Route.document(path: entry.path)) {
                    FileTreeRow(entry: entry, depth: row.depth, isExpanded: false, marker: marker(for: entry.path))
                }
                .buttonStyle(.plain)
            }
        }
        .contextMenu {
            if entry.isDirectory {
                Button {
                    ask(.newFile, entry.path)
                } label: {
                    Label("New File…", systemImage: "doc.badge.plus")
                }
                Button {
                    ask(.newFolder, entry.path)
                } label: {
                    Label("New Folder…", systemImage: "folder.badge.plus")
                }
            }
            Button {
                ask(.rename, entry.path, name: entry.name)
            } label: {
                Label("Rename…", systemImage: "pencil")
            }
            Button {
                UIPasteboard.general.string = entry.path
            } label: {
                Label("Copy Path", systemImage: "doc.on.doc")
            }
            Button(role: .destructive) {
                trashing = entry
            } label: {
                Label("Move to Trash", systemImage: "trash")
            }
        }
    }

    /// Git's letter for a file with uncommitted changes, as the Git tab shows it.
    private func marker(for path: String) -> FileDiff? {
        guard let files = model.diffs[folder]?.files, path.hasPrefix(folder + "/") else { return nil }
        let relative = String(path.dropFirst(folder.count + 1))
        return files.first { $0.path == relative }
    }

    private func reload() {
        model.loadFiles(folder)
        for directory in expanded { model.loadFiles(directory) }
        model.loadDiff(folder)
    }

    private func toggle(_ directory: String) {
        if expanded.contains(directory) {
            expanded.remove(directory)
        } else {
            expanded.insert(directory)
            model.loadFiles(directory)
        }
    }

    private func ask(_ kind: NamePrompt.Kind, _ path: String, name: String = "") {
        self.name = name
        prompt = NamePrompt(kind: kind, path: path)
    }

    private func finish(_ prompt: NamePrompt) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        switch prompt.kind {
        case .newFile:
            if prompt.path != folder { expanded.insert(prompt.path) }
            model.createFile(named: name, in: prompt.path, isDirectory: false)
        case .newFolder:
            if prompt.path != folder { expanded.insert(prompt.path) }
            model.createFile(named: name, in: prompt.path, isDirectory: true)
        case .rename:
            // What was open under the old name is no longer there.
            expanded.remove(prompt.path)
            model.renameFile(prompt.path, to: name)
        }
    }
}

private struct FileTreeRow: View {
    let entry: FileEntry
    let depth: Int
    let isExpanded: Bool
    let marker: FileDiff?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: entry.isDirectory ? (isExpanded ? "chevron.down" : "chevron.right") : "")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 12)
            Image(systemName: entry.isDirectory ? "folder.fill" : "doc")
                .font(.system(size: 14))
                .foregroundStyle(entry.isDirectory ? Palette.tint : .secondary)
                .frame(width: 20)
            Text(entry.name)
                .font(.body)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if let marker {
                Text(marker.marker)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(marker.isUntracked || marker.status == .added ? Palette.added : Color.orange)
            }
        }
        .padding(.leading, 12 + CGFloat(depth) * 16)
        .padding(.trailing, 14)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }
}

/// A file on the Mac: an editor for text, a picture for an image.
struct DocumentScreen: View {
    @EnvironmentObject private var model: PhoneModel
    let path: String
    /// The text as edited here.
    @State private var text = ""
    /// The text on the Mac that the edits started from. Nil until it loads.
    @State private var base: String?
    /// Markdown opens rendered. Editing is one tap away.
    @State private var previewing = true
    @State private var askingToLeave = false
    @State private var leaveWhenSaved = false

    private var isDirty: Bool { base != nil && text != base }
    private var isSaving: Bool { model.savingFile == path }
    private var hasPreview: Bool { base != nil && (FileLanguage.isMarkdown(path) || FileLanguage.isMermaid(path)) }

    var body: some View {
        VStack(spacing: 0) {
            if hasPreview {
                Picker("Mode", selection: $previewing) {
                    Text("Preview").tag(true)
                    Text("Edit").tag(false)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            content
        }
        .background(Palette.canvas.ignoresSafeArea())
        .navigationTitle((path as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        // Leaving with unsaved changes asks first, so the system's own back
        // button, which would not, is replaced while there are any.
        .navigationBarBackButtonHidden(isDirty)
        .toolbar {
            if isDirty {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        askingToLeave = true
                    } label: {
                        Image(systemName: "chevron.left").fontWeight(.semibold)
                    }
                    .accessibilityLabel("Back")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save") { model.saveFile(path, text: text) }.fontWeight(.semibold)
                    }
                }
            }
        }
        .confirmationDialog("Save changes to \"\((path as NSString).lastPathComponent)\"?", isPresented: $askingToLeave, titleVisibility: .visible) {
            Button("Save") {
                leaveWhenSaved = true
                model.saveFile(path, text: text)
            }
            Button("Don't Save", role: .destructive) { leave() }
            Button("Cancel", role: .cancel) {}
        }
        .onAppear {
            adopt(model.remoteFiles[path])
            model.loadFile(path)
        }
        .onChange(of: model.remoteFiles[path]) { _, file in adopt(file) }
        .onChange(of: model.savingFile) { _, saving in
            // A save that failed leaves the edits here, and the screen open.
            if saving == nil, isDirty { leaveWhenSaved = false }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let file = model.remoteFiles[path] {
            switch file.content {
            case .text:
                if hasPreview, previewing, FileLanguage.isMermaid(path) {
                    ScrollView { MermaidView(code: text).padding(16) }
                } else if hasPreview, previewing {
                    // Pictures the document refers to are on the Mac and are not shown here.
                    MarkdownPreview(text: text, baseURL: nil)
                } else {
                    CodeEditor(text: $text, path: path)
                }
            case .image:
                if let data = file.data, let image = UIImage(data: data) {
                    // As wide as the screen and scrolling down only, so a
                    // tall picture opens at its top.
                    ScrollView(.vertical) {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: min(image.size.width, UIScreen.main.bounds.width - 32))
                            .frame(maxWidth: .infinity)
                            .padding(16)
                    }
                } else {
                    Placeholder(text: "This image cannot be shown.")
                }
            case .binary:
                Placeholder(text: "This file is not text, so it is not shown here.")
            case .tooLarge(let bytes):
                Placeholder(text: "This file is \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)), too large to open here.")
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Takes in what the Mac has. Edits made here are kept.
    private func adopt(_ file: RemoteFile?) {
        guard let file, case .text(let saved) = file.content else { return }
        if !isDirty { text = saved }
        base = saved
        if leaveWhenSaved, text == saved { leave() }
    }

    private func leave() {
        leaveWhenSaved = false
        if !model.path.isEmpty { model.path.removeLast() }
    }
}
