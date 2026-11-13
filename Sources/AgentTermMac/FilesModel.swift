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
    /// A file on another Mac that was asked for and is not here yet.
    var isLoading = false
    /// The bytes of an image on another Mac: there is no file here to read it from.
    var imageData: Data?

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

    /// Set while another Mac is on screen: its files are not on this
    /// disk, and are asked for through its host instead. Every request is
    /// answered with a message that `handle` takes.
    private var remote: ((ClientMessage) -> Void)?
    var isRemote: Bool { remote != nil }
    /// False while there is no connection to the other Mac: what is asked
    /// of it then goes nowhere.
    var isOnline = true
    /// The text sent to the other Mac to be written, by path, until it
    /// says the file is saved. Until then the file's changes are not saved.
    private var saving: [String: String] = [:]
    /// Files saved again while the other Mac was still writing them.
    private var saveAgain: Set<String> = []
    /// Files whose tab closes once the other Mac has saved them.
    private var closeWhenSaved: Set<String> = []
    /// How many times a file was asked for and not yet answered.
    private var readsDue: [String: Int] = [:]
    /// Files saved while a read was on its way: the answer to that read
    /// may be the file as it was before, and is not shown.
    private var staleReads: Set<String> = []

    init() {
        restoreOpenFiles()
    }

    /// The files that were open last time come back as tabs, behind the terminal.
    private func restoreOpenFiles() {
        for path in UserDefaults.standard.stringArray(forKey: Self.openFilesKey) ?? [] where FileManager.default.fileExists(atPath: path) {
            documents.append(Self.load(path))
        }
    }

    /// Whether a file has changes that are not saved.
    var hasUnsavedChanges: Bool { documents.contains(where: \.isDirty) }

    /// Starts over for another Mac, or for this one again (nil). The files
    /// that were open belong to the Mac that is left.
    func reset(remote: ((ClientMessage) -> Void)?) {
        self.remote = remote
        root = nil
        children = [:]
        expanded = []
        documents = []
        active = nil
        error = nil
        pendingClose = nil
        forgetRequests()
        if remote == nil { restoreOpenFiles() }
    }

    /// The connection to the other Mac is gone, and with it the answers
    /// that were on their way. A file that was being saved keeps its changes.
    func connectionLost() {
        isOnline = false
        forgetRequests()
    }

    /// The other Mac said something went wrong. It does not say with what,
    /// so no file that was being saved is taken as saved.
    func requestFailed() {
        saving = [:]
        saveAgain = []
        closeWhenSaved = []
    }

    private func forgetRequests() {
        requestFailed()
        readsDue = [:]
        staleReads = []
    }

    private func read(_ path: String) {
        guard let remote else { return }
        readsDue[path, default: 0] += 1
        remote(.readFile(path: path))
    }

    /// What another Mac's host answered about its files.
    func handle(_ message: ServerMessage) {
        guard isRemote else { return }
        switch message {
        case .files(let directory, let entries):
            guard root != nil, directory == root || expanded.contains(directory) else { return }
            if children[directory] != entries { children[directory] = entries }
        case .file(let path, let content, let data):
            let due = max((readsDue[path] ?? 0) - 1, 0)
            readsDue[path] = due == 0 ? nil : due
            if staleReads.contains(path) {
                // Asked for before the file was saved from here. The next
                // look at the files reads it again.
                if due == 0 { staleReads.remove(path) }
                return
            }
            guard let index = documents.firstIndex(where: { $0.path == path }) else { return }
            // One with edits of our own keeps them, as with a file on this disk.
            if documents[index].isDirty { return }
            var text = ""
            if case .text(let loaded) = content { text = loaded }
            if documents[index].isLoading || documents[index].savedText != text || documents[index].content != content {
                documents[index] = OpenDocument(path: path, content: content, text: text, savedText: text, isLoading: false, imageData: data)
            }
        case .fileCreated(let path, let isDirectory):
            let directory = (path as NSString).deletingLastPathComponent
            if directory != root { expanded.insert(directory) }
            if isDirectory { expanded.insert(path) } else { open(path) }
            refresh()
        case .fileSaved(let path):
            guard let text = saving.removeValue(forKey: path) else { return }
            let index = documents.firstIndex(where: { $0.path == path })
            if let index { documents[index].savedText = text }
            let again = saveAgain.remove(path) != nil
            let closing = closeWhenSaved.remove(path) != nil
            guard let index else { return }
            if documents[index].isDirty {
                // Changed again since: what closes it is the next save.
                if again || closing { saveAndClose(path, closing: closing) }
            } else if closing {
                close(path)
            }
        default:
            break
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
        if let remote {
            if let root { for directory in [root] + expanded.sorted() { remote(.files(path: directory)) } }
            for document in documents where document.isText && !document.isDirty && !document.isLoading && !staleReads.contains(document.path) {
                read(document.path)
            }
            return
        }
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
        if let remote {
            remote(.files(path: directory))
            return
        }
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
            if isRemote {
                documents.append(OpenDocument(path: path, content: .text(""), text: "", savedText: "", isLoading: true))
                read(path)
            } else {
                documents.append(Self.load(path))
            }
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
        if let remote {
            guard isOnline else {
                error = "The other Mac is not connected, so the file could not be saved. Its changes are kept: save again once it is back."
                return false
            }
            // One write at a time: two on their way could be done in either order.
            if saving[path] != nil {
                saveAgain.insert(path)
                return true
            }
            // Not saved until the other Mac says so. If it cannot write
            // the file it says that instead, and the changes stay changes.
            saving[path] = documents[index].text
            if readsDue[path] != nil { staleReads.insert(path) }
            remote(.writeFile(path: path, text: documents[index].text))
            return true
        }
        do {
            try FileBrowser.write(documents[index].text, to: path)
            documents[index].savedText = documents[index].text
            return true
        } catch {
            self.error = "\(error)"
            return false
        }
    }

    /// Saves a file and closes its tab. A file on another Mac closes once
    /// that Mac has it: if it cannot be saved, it stays open with its changes.
    func saveAndClose(_ path: String, closing: Bool = true) {
        guard save(path) else { return }
        guard closing else { return }
        if isRemote, documents.first(where: { $0.path == path })?.isDirty == true {
            pendingClose = nil
            closeWhenSaved.insert(path)
        } else {
            close(path)
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
        // Only this Mac's: another Mac's files are not here to come back to.
        guard !isRemote else { return }
        UserDefaults.standard.set(documents.map(\.path), forKey: Self.openFilesKey)
    }

    // MARK: Changing files

    func createFile(named name: String, in directory: String) {
        if let remote {
            remote(.createFile(directory: directory, name: name, isDirectory: false))
            return
        }
        perform {
            let path = try FileBrowser.createFile(named: name, in: directory)
            self.reveal(directory)
            self.open(path)
        }
    }

    func createFolder(named name: String, in directory: String) {
        if let remote {
            remote(.createFile(directory: directory, name: name, isDirectory: true))
            return
        }
        perform {
            let path = try FileBrowser.createFolder(named: name, in: directory)
            self.reveal(directory)
            self.expanded.insert(path)
        }
    }

    func rename(_ entry: FileEntry, to name: String) {
        perform {
            let target: String
            if let remote {
                // Where it will be, if the other Mac takes the name: it
                // answers with the folder as it is then.
                target = ((entry.path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(name)
                guard target != entry.path else { return }
                remote(.renameFile(path: entry.path, name: name))
            } else {
                target = try FileBrowser.rename(entry.path, to: name)
            }
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
            if let remote { remote(.trashFile(path: entry.path)) } else { try FileBrowser.trash(entry.path) }
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
