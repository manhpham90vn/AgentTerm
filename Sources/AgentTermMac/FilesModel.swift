import AgentTermEditor
import AgentTermHost
import AgentTermProtocol
import AppKit
import SwiftUI

/// A file open in the Files tab.
struct OpenDocument: Equatable {
    var path: String
    var content: FileContent
    /// The text as edited. Only meaningful for text content.
    var text: String
    /// The text as it is on disk.
    var savedText: String

    var name: String { (path as NSString).lastPathComponent }
    var isText: Bool { if case .text = content { return true } else { return false } }
    var isDirty: Bool { isText && text != savedText }
    var isMarkdown: Bool { FileLanguage.isMarkdown(path) }
    /// A file that is one Mermaid diagram.
    var isMermaid: Bool { FileLanguage.isMermaid(path) }
    /// Text that has a rendered form to look at besides its source.
    var hasPreview: Bool { isText && (isMarkdown || isMermaid) }
}

/// State of the Files tab and of the files open in the middle pane.
@MainActor
final class FilesModel: ObservableObject {
    @Published private(set) var root: String?
    /// Loaded contents of folders, by path.
    @Published private(set) var children: [String: [FileEntry]] = [:]
    @Published private(set) var expanded: Set<String> = []
    /// Files open as tabs next to the sessions, in tab order. They belong to
    /// the window, not to the folder being browsed.
    @Published var documents: [OpenDocument] = []
    /// The file shown in the middle pane. Nil while a terminal is shown.
    @Published var active: String?
    @Published var error: String?
    /// A file with unsaved changes that the user asked to close.
    @Published var pendingClose: String?

    private static let openFilesKey = "openFiles"

    init() {
        // The files that were open last time come back as tabs, behind the terminal.
        for path in UserDefaults.standard.stringArray(forKey: Self.openFilesKey) ?? [] where FileManager.default.fileExists(atPath: path) {
            documents.append(Self.load(path))
        }
    }

    var activeDocument: OpenDocument? { documents.first { $0.path == active } }

    /// A row of the tree as shown: folders that are open are followed by
    /// what is in them.
    struct Row: Identifiable, Equatable {
        let entry: FileEntry
        let depth: Int
        var id: String { entry.path }
    }

    var rows: [Row] {
        guard let root else { return [] }
        var result: [Row] = []
        func add(_ directory: String, depth: Int) {
            for entry in children[directory] ?? [] {
                result.append(Row(entry: entry, depth: depth))
                if entry.isDirectory, expanded.contains(entry.path) { add(entry.path, depth: depth + 1) }
            }
        }
        add(root, depth: 0)
        return result
    }

    // MARK: Tree

    func setRoot(_ folder: String?) {
        guard folder != root else { return }
        root = folder
        children = [:]
        expanded = []
        if let folder { load(folder) }
    }

    func toggle(_ directory: String) {
        if expanded.contains(directory) {
            expanded.remove(directory)
        } else {
            expanded.insert(directory)
            load(directory)
        }
    }

    /// Reads again what is on disk: every folder that is showing, and the
    /// open files, which an agent may have rewritten meanwhile.
    func refresh() {
        if let root {
            for directory in [root] + expanded.sorted() {
                if FileManager.default.fileExists(atPath: directory) {
                    load(directory)
                } else {
                    expanded.remove(directory)
                    children[directory] = nil
                }
            }
        }
        for index in documents.indices where documents[index].isText && !documents[index].isDirty {
            // Only files without edits of our own follow the disk. One with
            // unsaved changes keeps them; saving then overwrites the disk.
            if case .text(let onDisk) = FileBrowser.read(documents[index].path), onDisk != documents[index].savedText {
                documents[index].content = .text(onDisk)
                documents[index].text = onDisk
                documents[index].savedText = onDisk
            }
        }
    }

    private func load(_ directory: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let entries = FileBrowser.list(directory)
            DispatchQueue.main.async {
                guard let self, self.root != nil else { return }
                if self.children[directory] != entries { self.children[directory] = entries }
            }
        }
    }

    // MARK: Documents

    private static func load(_ path: String) -> OpenDocument {
        let content = FileBrowser.read(path)
        var text = ""
        if case .text(let loaded) = content { text = loaded }
        return OpenDocument(path: path, content: content, text: text, savedText: text)
    }

    /// Shows a file in the middle pane, opening a tab for it if it has none.
    func open(_ path: String) {
        if !documents.contains(where: { $0.path == path }) {
            documents.append(Self.load(path))
            rememberOpenFiles()
        }
        active = path
    }

    /// Closes a file's tab, asking first when it has unsaved changes.
    func requestClose(_ path: String) {
        guard let document = documents.first(where: { $0.path == path }) else { return }
        if document.isDirty {
            active = path
            pendingClose = path
        } else {
            close(path)
        }
    }

    func close(_ path: String) {
        pendingClose = nil
        guard let index = documents.firstIndex(where: { $0.path == path }) else { return }
        documents.remove(at: index)
        if active == path {
            // The tab that takes its place, or the terminal when it was the last file.
            active = documents.indices.contains(index) ? documents[index].path : documents.last?.path
        }
        rememberOpenFiles()
    }

    /// Closes every file's tab but the one given. A file with unsaved
    /// changes stays open, and the first of them asks what to do with it.
    /// `keeping` names files that stay open whatever else is closed.
    func closeAll(except kept: String? = nil, keeping: Set<String> = []) {
        for document in documents where document.path != kept && !keeping.contains(document.path) && !document.isDirty {
            close(document.path)
        }
        if let unsaved = documents.first(where: { $0.path != kept && !keeping.contains($0.path) && $0.isDirty }) {
            requestClose(unsaved.path)
        } else if let kept, active != nil {
            active = kept
        }
    }

    @discardableResult
    func save(_ path: String? = nil) -> Bool {
        guard let path = path ?? active, let index = documents.firstIndex(where: { $0.path == path }), documents[index].isDirty else { return true }
        do {
            try FileBrowser.write(documents[index].text, to: path)
            documents[index].savedText = documents[index].text
            return true
        } catch {
            self.error = "\(error)"
            return false
        }
    }

    func discardChanges(_ path: String) {
        guard let index = documents.firstIndex(where: { $0.path == path }) else { return }
        documents[index].text = documents[index].savedText
    }

    func setText(_ text: String, for path: String) {
        guard let index = documents.firstIndex(where: { $0.path == path }), documents[index].text != text else { return }
        documents[index].text = text
    }

    private func rememberOpenFiles() {
        UserDefaults.standard.set(documents.map(\.path), forKey: Self.openFilesKey)
    }

    // MARK: Changing files

    func createFile(named name: String, in directory: String) {
        perform {
            let path = try FileBrowser.createFile(named: name, in: directory)
            self.reveal(directory)
            self.open(path)
        }
    }

    func createFolder(named name: String, in directory: String) {
        perform {
            let path = try FileBrowser.createFolder(named: name, in: directory)
            self.reveal(directory)
            self.expanded.insert(path)
        }
    }

    func rename(_ entry: FileEntry, to name: String) {
        perform {
            let target = try FileBrowser.rename(entry.path, to: name)
            guard target != entry.path else { return }
            // What was open or expanded under the old path moves with it.
            for index in self.documents.indices {
                let old = self.documents[index].path
                guard old == entry.path || old.hasPrefix(entry.path + "/") else { continue }
                let moved = target + old.dropFirst(entry.path.count)
                self.documents[index].path = moved
                if self.active == old { self.active = moved }
            }
            self.rememberOpenFiles()
            self.expanded = Set(self.expanded.map { $0 == entry.path || $0.hasPrefix(entry.path + "/") ? target + $0.dropFirst(entry.path.count) : $0 })
            self.children = [:]
            self.refresh()
        }
    }

    func trash(_ entry: FileEntry) {
        perform {
            try FileBrowser.trash(entry.path)
            for document in self.documents where document.path == entry.path || document.path.hasPrefix(entry.path + "/") {
                self.close(document.path)
            }
            self.expanded.remove(entry.path)
            self.refresh()
        }
    }

    private func reveal(_ directory: String) {
        if directory != root { expanded.insert(directory) }
        refresh()
    }

    private func perform(_ work: () throws -> Void) {
        do {
            try work()
        } catch {
            self.error = "\(error)"
        }
    }
}
