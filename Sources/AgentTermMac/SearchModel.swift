import AgentTermHost
import AgentTermProtocol
import Foundation

/// Searching the files of the folder the side panel shows (#45): by name
/// as it is typed, and by what is in them. On this Mac it is done here;
/// for another Mac its host does it.
@MainActor
final class SearchModel: ObservableObject {
    enum Mode: String { case names, text }

    @Published var mode = Mode.names
    @Published var query = "" { didSet { if query != oldValue { changed() } } }
    @Published var caseSensitive = false { didSet { if caseSensitive != oldValue, mode == .text { changed() } } }
    /// The search is on show in the Files tab, in place of the tree.
    @Published var isShown = false
    /// Changes each time the field is to take the keyboard.
    @Published private(set) var focusToken = 0

    /// Files whose name matches, best first, and how many were looked through.
    @Published private(set) var files: [String] = []
    @Published private(set) var among = 0
    /// Lines that hold the text.
    @Published private(set) var matches: [TextMatch] = []
    @Published private(set) var isSearching = false
    @Published private(set) var truncated = false
    @Published private(set) var problem: String?
    /// The row the arrow keys are on.
    @Published var selection = 0

    private(set) var root: String?
    private var remote: ((ClientMessage) -> Void)?
    /// Numbers the searches: an answer to an earlier one is not shown.
    private var number: Int

    /// - Parameter firstNumber: Where its searches' numbers start. Two
    ///   searches of one connection number theirs apart, so that neither
    ///   takes the other's answers for its own.
    init(firstNumber: Int = 0) {
        number = firstNumber
    }
    private var pending: DispatchWorkItem?
    private var flag: Flag?
    /// This Mac's folder's files, kept while its search is open.
    private var listed: (root: String, files: [String])?

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false
        var isStopped: Bool {
            lock.lock()
            defer { lock.unlock() }
            return stopped
        }
        func stop() {
            lock.lock()
            stopped = true
            lock.unlock()
        }
    }

    func reset(remote: ((ClientMessage) -> Void)?) {
        stop()
        self.remote = remote
        listed = nil
        clear()
    }

    func setRoot(_ folder: String?) {
        guard folder != root else { return }
        stop()
        root = folder
        listed = nil
        clear()
        if isShown { changed(now: true) }
    }

    private func clear() {
        files = []
        among = 0
        matches = []
        truncated = false
        problem = nil
        selection = 0
    }

    /// Shows the search in one of its two ways, with the keyboard in its field.
    func show(_ mode: Mode) {
        let wasShown = isShown
        self.mode = mode
        isShown = true
        focusToken += 1
        // The folder's files are read again each time it is opened.
        if !wasShown { listed = nil }
        changed(now: true)
    }

    func hide() {
        stop()
        isShown = false
    }

    func setMode(_ mode: Mode) {
        guard mode != self.mode else { return }
        self.mode = mode
        changed(now: true)
    }

    /// The absolute path of a file that was found.
    func path(of file: String) -> String? { root.map { ($0 as NSString).appendingPathComponent(file) } }

    /// Stops a search for text that is going on.
    func stop() {
        pending?.cancel()
        pending = nil
        flag?.stop()
        flag = nil
        if isSearching, remote != nil { remote?(.stopSearch(search: number)) }
        isSearching = false
    }

    /// Searches for what is typed now. Names at once; text a moment after
    /// the last key, so that a word is not searched a letter at a time.
    private func changed(now: Bool = false) {
        pending?.cancel()
        guard isShown, root != nil else { return }
        selection = 0
        switch mode {
        case .names: findFiles()
        case .text:
            let work = DispatchWorkItem { [weak self] in self?.findText() }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + (now ? 0 : 0.25), execute: work)
        }
    }

    private func findFiles() {
        guard let root else { return }
        number += 1
        let search = number
        let query = query
        if let remote {
            remote(.findFiles(search: search, path: root, query: query))
            return
        }
        let known = listed?.root == root ? listed?.files : nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let all = known ?? FileSearch.files(in: root)
            let found = FileSearch.rank(all, query: query)
            DispatchQueue.main.async {
                guard let self, self.root == root else { return }
                self.listed = (root, all)
                guard search == self.number, self.mode == .names else { return }
                self.files = found
                self.among = all.count
            }
        }
    }

    private func findText() {
        guard let root else { return }
        stop()
        number += 1
        let search = number
        matches = []
        truncated = false
        problem = nil
        let query = query
        guard !query.isEmpty else { return }
        isSearching = true
        if let remote {
            remote(.findText(search: search, path: root, query: query, caseSensitive: caseSensitive))
            return
        }
        let flag = Flag()
        self.flag = flag
        let caseSensitive = caseSensitive
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let ending = FileSearch.text(query, in: root, caseSensitive: caseSensitive, isCancelled: { flag.isStopped }) { found in
                DispatchQueue.main.async {
                    guard let self, search == self.number, !flag.isStopped else { return }
                    self.matches += found
                }
            }
            DispatchQueue.main.async {
                guard let self, search == self.number else { return }
                self.isSearching = false
                self.truncated = ending.truncated
                self.problem = ending.problem
            }
        }
    }

    /// What another Mac's host found.
    func handle(_ message: ServerMessage) {
        switch message {
        case .filesFound(let search, let files, let among):
            guard search == number, mode == .names else { return }
            self.files = files
            self.among = among
        case .textFound(let search, let found):
            guard search == number, mode == .text else { return }
            matches += found
        case .searchEnded(let search, let truncated, let problem):
            guard search == number else { return }
            isSearching = false
            self.truncated = truncated
            self.problem = problem
        default:
            break
        }
    }

    /// The connection to the other Mac is gone, and its answers with it.
    func connectionLost() {
        if isSearching {
            isSearching = false
            problem = "The search stopped: the other Mac is not connected."
        }
    }
}
