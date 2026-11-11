import Foundation

// What a client can ask the host about a folder: its git changes, the
// conversations agents had in it, and what folders exist. Shared by the host,
// which produces these, and by the macOS and iOS apps, which show them.

public struct FileDiff: Codable, Identifiable, Equatable, Sendable {
    public var path: String
    public var added: Int
    public var deleted: Int
    public var isUntracked: Bool
    /// Unified diff for this file, starting at the first hunk header. Empty
    /// in a list of files sent over the network; ask for the file to get it.
    public var patch: String

    public var id: String { path }

    public init(path: String, added: Int, deleted: Int, isUntracked: Bool, patch: String) {
        self.path = path
        self.added = added
        self.deleted = deleted
        self.isUntracked = isUntracked
        self.patch = patch
    }
}

public struct DiffSnapshot: Codable, Equatable, Sendable {
    public var isRepository: Bool
    public var branch: String?
    public var files: [FileDiff]

    public init(isRepository: Bool, branch: String?, files: [FileDiff]) {
        self.isRepository = isRepository
        self.branch = branch
        self.files = files
    }

    public static let notARepository = DiffSnapshot(isRepository: false, branch: nil, files: [])

    /// The same list without the diffs themselves, which can be megabytes.
    public var withoutPatches: DiffSnapshot {
        var copy = self
        copy.files = files.map { file in
            var file = file
            file.patch = ""
            return file
        }
        return copy
    }
}

/// A past conversation with an agent, found in that agent's own files.
public struct Conversation: Codable, Identifiable, Equatable, Sendable {
    /// Agent id: "claude", "codex", "agy" or "copilot".
    public var agent: String
    /// The agent's own identifier for the conversation.
    public var sessionID: String
    public var title: String
    public var updatedAt: Date
    /// Directory the conversation ran in.
    public var cwd: String
    /// File on the host holding the conversation's messages, when the agent
    /// keeps one that can be read.
    public var source: String?
    /// When the conversation began, where the agent's files tell.
    public var startedAt: Date?

    public var id: String { agent + ":" + sessionID }

    public init(
        agent: String, sessionID: String, title: String, updatedAt: Date, cwd: String,
        source: String? = nil, startedAt: Date? = nil
    ) {
        self.agent = agent
        self.sessionID = sessionID
        self.title = title
        self.updatedAt = updatedAt
        self.cwd = cwd
        self.source = source
        self.startedAt = startedAt
    }

    /// Command line that reopens the conversation in its agent.
    public var resumeCommand: String {
        switch agent {
        case "claude": return "claude --resume \(sessionID)"
        case "codex": return "codex resume \(sessionID)"
        case "agy": return "agy --conversation \(sessionID)"
        case "copilot": return "copilot --resume=\(sessionID)"
        default: return agent
        }
    }
}

/// The folders inside one folder on the host, for picking where to work.
public struct DirectoryListing: Codable, Equatable, Sendable {
    public var path: String
    /// `nil` at the root.
    public var parent: String?
    /// Names of the folders inside, without hidden ones.
    public var folders: [String]
    /// True when this is the user's home folder.
    public var isHome: Bool

    public init(path: String, parent: String?, folders: [String], isHome: Bool) {
        self.path = path
        self.parent = parent
        self.folders = folders
        self.isHome = isHome
    }
}
