import AgenttyHost
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
    var isMarkdown: Bool { ["md", "markdown", "mdx"].contains((path as NSString).pathExtension.lowercased()) }
}

/// State of the Files tab: the tree of one project folder and the open file.
@MainActor
final class FilesModel: ObservableObject {
    @Published private(set) var root: String?
    /// Loaded contents of folders, by path.
    @Published private(set) var children: [String: [FileEntry]] = [:]
    @Published private(set) var expanded: Set<String> = []
    @Published var document: OpenDocument?
    @Published var error: String?
    /// A file the user asked to open while the open one has unsaved changes.
    @Published var pendingOpen: String?

    private static let lastOpenKey = "filesLastOpen"

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
        document = nil
        pendingOpen = nil
        guard let folder else { return }
        load(folder)
        // Back to the file that was open in this folder last time.
        let remembered = (UserDefaults.standard.dictionary(forKey: Self.lastOpenKey) as? [String: String])?[folder]
        if let remembered, FileManager.default.fileExists(atPath: remembered) { open(remembered) }
    }

    func toggle(_ directory: String) {
        if expanded.contains(directory) {
            expanded.remove(directory)
        } else {
            expanded.insert(directory)
            load(directory)
        }
    }

    /// Reads again what is on disk for every folder that is showing.
    func refresh() {
        guard let root else { return }
        for directory in [root] + expanded.sorted() {
            if FileManager.default.fileExists(atPath: directory) {
                load(directory)
            } else {
                expanded.remove(directory)
                children[directory] = nil
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

    /// Opens a file, asking first when the open one has unsaved changes.
    func requestOpen(_ path: String) {
        guard path != document?.path else { return }
        if document?.isDirty == true {
            pendingOpen = path
        } else {
            open(path)
        }
    }

    func open(_ path: String) {
        pendingOpen = nil
        let content = FileBrowser.read(path)
        var text = ""
        if case .text(let loaded) = content { text = loaded }
        document = OpenDocument(path: path, content: content, text: text, savedText: text)
        if let root {
            var remembered = (UserDefaults.standard.dictionary(forKey: Self.lastOpenKey) as? [String: String]) ?? [:]
            remembered[root] = path
            UserDefaults.standard.set(remembered, forKey: Self.lastOpenKey)
        }
    }

    func closeDocument() {
        document = nil
    }

    @discardableResult
    func save() -> Bool {
        guard var open = document, open.isDirty else { return true }
        do {
            try FileBrowser.write(open.text, to: open.path)
            open.savedText = open.text
            document = open
            return true
        } catch {
            self.error = "\(error)"
            return false
        }
    }

    func discardChanges() {
        guard var open = document else { return }
        open.text = open.savedText
        document = open
    }

    // MARK: Changing files

    func createFile(named name: String, in directory: String) {
        perform {
            let path = try FileBrowser.createFile(named: name, in: directory)
            self.reveal(directory)
            self.requestOpen(path)
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
            if let open = self.document, open.path == entry.path || open.path.hasPrefix(entry.path + "/") {
                var moved = open
                moved.path = target + open.path.dropFirst(entry.path.count)
                self.document = moved
            }
            self.expanded = Set(self.expanded.map { $0 == entry.path || $0.hasPrefix(entry.path + "/") ? target + $0.dropFirst(entry.path.count) : $0 })
            self.children = [:]
            self.refresh()
        }
    }

    func trash(_ entry: FileEntry) {
        perform {
            try FileBrowser.trash(entry.path)
            if let open = self.document, open.path == entry.path || open.path.hasPrefix(entry.path + "/") { self.document = nil }
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
