import AgentTermProtocol
import Foundation

/// What History does beyond listing the conversations (#46): filtering
/// and grouping them, searching what was said, reading one, pinning,
/// hiding and deleting. The host does the reading and keeps the pins, for
/// this Mac as for another, so that every device shows the same.
@MainActor
final class HistoryStore: ObservableObject {
    /// One of the two lists: every conversation on the Mac, in History,
    /// or the folder on show's, in the side panel.
    struct Scope {
        var filter = HistoryFilter()
        var query = ""
        /// What a search found; nil while nothing is searched for.
        var hits: [HistoryHit]?
        var isSearching = false
        /// Pages of older conversations asked for after the first.
        var older: [Conversation] = []
        /// Whether there may be older ones still.
        var more = true
    }

    @Published var all = Scope()
    @Published var folder = Scope()
    @Published private(set) var pinned: Set<String> = []
    @Published private(set) var hidden: Set<String> = []
    /// Conversations as they were read, by their id; nil for one that is
    /// no longer there.
    @Published private(set) var details: [String: ConversationDetails?] = [:]
    /// The conversation the user is asked about before it is deleted, and
    /// the one asked about a second time: two questions, one after the other.
    @Published var deleting: Conversation?
    @Published var deletingAgain: Conversation?

    var send: ((ClientMessage) -> Void)?
    /// A transcript was written out as a file, here.
    var exported: ((String) -> Void)?
    /// A conversation was deleted.
    var deleted: ((String) -> Void)?

    private var number = 0
    /// Which list the search that is going on is for: the folder's, or all.
    private var searchOfFolder: Bool?
    private var pending: DispatchWorkItem?

    subscript(ofFolder ofFolder: Bool) -> Scope {
        get { ofFolder ? folder : all }
        set { if ofFolder { folder = newValue } else { all = newValue } }
    }

    /// Everything known of another Mac is forgotten; the filters stay.
    func reset() {
        pending?.cancel()
        all.hits = nil
        all.isSearching = false
        all.older = []
        all.more = true
        folderChanged()
        details = [:]
        deleting = nil
        deletingAgain = nil
    }

    /// The side panel shows another folder: its own conversations.
    func folderChanged() {
        folder.hits = nil
        folder.isSearching = false
        folder.older = []
        folder.more = true
        folder.query = ""
    }

    // MARK: Searching

    /// Searches for what is typed in one of the lists, a moment after the
    /// last key. An empty field shows the list again.
    func search(ofFolder: Bool, path: String?) {
        pending?.cancel()
        let query = self[ofFolder: ofFolder].query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            number += 1
            self[ofFolder: ofFolder].hits = nil
            self[ofFolder: ofFolder].isSearching = false
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.number += 1
            self.searchOfFolder = ofFolder
            self[ofFolder: ofFolder].hits = []
            self[ofFolder: ofFolder].isSearching = true
            self.send?(.searchHistory(search: self.number, path: ofFolder ? path : nil, query: query))
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    // MARK: One conversation

    func read(_ conversation: Conversation) {
        send?(.readConversation(agent: conversation.agent, sessionID: conversation.sessionID, cwd: conversation.cwd))
    }

    func export(_ conversation: Conversation) {
        send?(.exportConversation(agent: conversation.agent, sessionID: conversation.sessionID, cwd: conversation.cwd))
    }

    func pin(_ conversation: Conversation, _ pinned: Bool) { send?(.markConversation(id: conversation.id, pinned: pinned, hidden: nil)) }
    func hide(_ conversation: Conversation, _ hidden: Bool) { send?(.markConversation(id: conversation.id, pinned: nil, hidden: hidden)) }

    /// Deleting is asked about twice: it is the agent's own record that
    /// goes. The second question comes once the first has left the screen.
    func firstQuestionConfirmed() {
        guard let asked = deleting else { return }
        deleting = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.deletingAgain = asked }
    }

    func deleteConfirmed() {
        guard let asked = deletingAgain else { return }
        deletingAgain = nil
        send?(.deleteConversation(agent: asked.agent, sessionID: asked.sessionID, cwd: asked.cwd))
    }

    func loadOlder(ofFolder: Bool, path: String?, shown: [Conversation]) {
        guard let oldest = (shown + self[ofFolder: ofFolder].older).map(\.updatedAt).min() else { return }
        send?(.historyOlder(path: ofFolder ? path : nil, before: oldest))
    }

    // MARK: From the host

    /// - Parameter folderPath: The folder the side panel shows.
    func handle(_ message: ServerMessage, folderPath: String?) {
        switch message {
        case .historyMarks(let pinned, let hidden):
            self.pinned = Set(pinned)
            self.hidden = Set(hidden)
        case .conversationRead(let id, let read):
            details[id] = .some(read)
            // The last few are kept: each may be megabytes.
            if details.count > 8, let other = details.keys.first(where: { $0 != id }) { details[other] = nil }
        case .historyFound(let search, let hits):
            guard search == number, let ofFolder = searchOfFolder else { return }
            self[ofFolder: ofFolder].hits = (self[ofFolder: ofFolder].hits ?? []) + hits
        case .historySearchEnded(let search):
            guard search == number, let ofFolder = searchOfFolder else { return }
            self[ofFolder: ofFolder].isSearching = false
        case .historyOlder(let path, let conversations, let more):
            let ofFolder = path != nil
            guard !ofFolder || path == folderPath else { return }
            let known = Set(self[ofFolder: ofFolder].older.map(\.id))
            self[ofFolder: ofFolder].older += conversations.filter { !known.contains($0.id) }
            self[ofFolder: ofFolder].more = more
        case .conversationDeleted(let id):
            details[id] = nil
            all.older.removeAll { $0.id == id }
            folder.older.removeAll { $0.id == id }
            all.hits?.removeAll { $0.id == id }
            folder.hits?.removeAll { $0.id == id }
            deleted?(id)
        case .conversationExported(_, let path):
            exported?(path)
        default:
            break
        }
    }
}
