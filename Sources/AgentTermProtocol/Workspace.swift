import Foundation

// What a client can ask the host about a folder: its git changes, the
// conversations agents had in it, and what folders exist. Shared by the host,
// which produces these, and by the macOS and iOS apps, which show them.

public struct FileDiff: Codable, Identifiable, Equatable, Sendable {
    /// What happened to the file, as git names it.
    public enum Status: String, Codable, Sendable {
        case modified = "M"
        case added = "A"
        case deleted = "D"
    }

    public var path: String
    public var added: Int
    public var deleted: Int
    public var isUntracked: Bool
    /// Unified diff for this file, starting at the first hunk header. Empty
    /// in a list of files sent over the network; ask for the file to get it.
    public var patch: String
    /// True for what is staged for the next commit, false for what is only
    /// in the working tree. A file changed after it was staged has an entry
    /// of each kind.
    public var isStaged: Bool
    public var status: Status

    /// Staged and unstaged entries of one file are different rows.
    public var id: String { (isStaged ? "staged:" : "") + path }

    public init(
        path: String, added: Int, deleted: Int, isUntracked: Bool, patch: String,
        isStaged: Bool = false, status: Status = .modified
    ) {
        self.path = path
        self.added = added
        self.deleted = deleted
        self.isUntracked = isUntracked
        self.patch = patch
        self.isStaged = isStaged
        self.status = status
    }

    /// One letter for a list: git's letter, or "U" for a file git does not track yet.
    public var marker: String { isUntracked ? "U" : status.rawValue }
}

/// Changes put aside in a repository's stash (#38).
public struct StashInfo: Codable, Equatable, Hashable, Identifiable, Sendable {
    /// The hash of the commit git keeps the stash as: what names it here,
    /// since its place in the list ("stash@{1}") moves when another is
    /// dropped.
    public var hash: String
    /// Its place in the list as git names it: "stash@{0}" is the newest.
    public var ref: String
    /// What it was called when it was made, or git's own words for it.
    public var message: String
    /// The branch it was made on, when git's words say so.
    public var branch: String?
    public var date: Date

    public var id: String { hash }

    public init(hash: String, ref: String, message: String, branch: String? = nil, date: Date = Date(timeIntervalSince1970: 0)) {
        self.hash = hash
        self.ref = ref
        self.message = message
        self.branch = branch
        self.date = date
    }

    /// From what git notes of a stash: "On main: half of the login" has a
    /// name; "WIP on main: abc1234 the last commit" has none, and is told
    /// by the commit it was made on.
    public init(hash: String, ref: String, noted: String, date: Date) {
        var message = noted
        var branch: String?
        for prefix in ["WIP on ", "On "] where noted.hasPrefix(prefix) {
            let rest = noted.dropFirst(prefix.count)
            if let colon = rest.range(of: ": ") {
                branch = String(rest[..<colon.lowerBound])
                message = prefix == "On " ? String(rest[colon.upperBound...]) : "Changes on " + String(rest[colon.upperBound...])
            }
            break
        }
        self.init(hash: hash, ref: ref, message: message, branch: branch, date: date)
    }
}

/// What is asked before a stash is dropped (#38): it is the only copy of
/// what it holds.
public struct DropStashQuestion: Equatable, Sendable {
    public var title: String
    public var message: String
    public var confirm: String

    public init(stash: StashInfo) {
        title = "Drop the stash “\(stash.message)”?"
        message = "What it holds is in no commit and no file: once dropped it cannot be brought back from AgentTerm."
        confirm = "Drop Stash"
    }
}

/// One commit of a repository's history (#36).
public struct CommitInfo: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var hash: String
    /// The commits it follows: one, two or more for a merge, none for the first.
    public var parents: [String]
    public var subject: String
    public var author: String
    public var date: Date
    /// The branches and tags that point at it: "main", "origin/main", "tag: v1".
    public var refs: [String]

    public var id: String { hash }
    /// The hash as it is shown: its first seven letters.
    public var short: String { String(hash.prefix(7)) }
    public var isMerge: Bool { parents.count > 1 }

    public init(hash: String, parents: [String] = [], subject: String, author: String = "", date: Date = Date(timeIntervalSince1970: 0), refs: [String] = []) {
        self.hash = hash
        self.parents = parents
        self.subject = subject
        self.author = author
        self.date = date
        self.refs = refs
    }
}

/// A commit with the rest of its message and what it changed, each file
/// with its diff: against its first parent, for a merge.
public struct CommitDetails: Codable, Equatable, Sendable {
    public var commit: CommitInfo
    /// The message after its first line.
    public var body: String
    public var files: [FileDiff]
    /// The diffs were left out: together they were too large to send.
    public var diffsLeftOut: Bool

    public init(commit: CommitInfo, body: String = "", files: [FileDiff] = [], diffsLeftOut: Bool = false) {
        self.commit = commit
        self.body = body
        self.files = files
        self.diffsLeftOut = diffsLeftOut
    }
}

/// Where each commit of a list is drawn in the graph beside it (#36): a
/// lane for every line of history that is open at that row, so that where
/// branches part and meet shows.
public struct CommitGraphRow: Equatable, Sendable {
    /// The lane the commit's dot is in.
    public var lane: Int
    /// The lanes that come in from the row above, by where each goes at
    /// this row: its own lane to pass through, or the commit's to end at it.
    public var incoming: [Int: Int]
    /// The lanes that go on to the row below, by where each starts at
    /// this row: its own lane, or the commit's when it is one of its parents.
    public var outgoing: [Int: Int]

    /// How many lanes this row needs room for.
    public var width: Int { (Array(incoming.keys) + Array(outgoing.keys) + [lane]).reduce(0, max) + 1 }

    /// A row for each commit, in the order given (newest first, as `git
    /// log` lists them).
    public static func rows(for commits: [CommitInfo]) -> [CommitGraphRow] {
        // What each open lane waits for: the hash of the commit that
        // continues it. Nil for a lane that is free.
        var lanes: [String?] = []
        var rows: [CommitGraphRow] = []
        for commit in commits {
            // Every lane that waits for this commit ends at it; it sits in the first.
            let waiting = lanes.indices.filter { lanes[$0] == commit.hash }
            let lane = waiting.first ?? lanes.firstIndex(where: { $0 == nil }) ?? lanes.count
            if lane == lanes.count { lanes.append(nil) }
            var incoming: [Int: Int] = [:]
            for index in lanes.indices where lanes[index] != nil { incoming[index] = waiting.contains(index) ? lane : index }
            for index in waiting { lanes[index] = nil }
            // Its first parent goes on in its lane; the others take a lane
            // that already waits for them, or a free one.
            var outgoing: [Int: Int] = [:]
            for (number, parent) in commit.parents.enumerated() {
                if number == 0 {
                    lanes[lane] = parent
                    outgoing[lane] = lane
                } else if let there = lanes.firstIndex(where: { $0 == parent }) {
                    outgoing[there] = there == lane ? lane : outgoing[there] ?? lane
                } else {
                    let free = lanes.firstIndex(where: { $0 == nil }) ?? lanes.count
                    if free == lanes.count { lanes.append(parent) } else { lanes[free] = parent }
                    outgoing[free] = lane
                }
            }
            for index in lanes.indices where lanes[index] != nil && outgoing[index] == nil { outgoing[index] = index }
            while lanes.last == .some(nil) { lanes.removeLast() }
            rows.append(CommitGraphRow(lane: lane, incoming: incoming, outgoing: outgoing))
        }
        return rows
    }
}

/// What is asked before a commit is reverted or picked onto the checked
/// out branch (#36), the same on every device.
public struct CommitActionQuestion: Equatable, Sendable {
    public enum Action: String, Sendable {
        case revert
        case cherryPick
    }

    public var title: String
    public var message: String
    public var confirm: String

    public init(_ action: Action, commit: CommitInfo, onto branch: String?) {
        let onto = branch.map { "“\($0)”" } ?? "the checked out commit"
        switch action {
        case .revert:
            title = "Revert \(commit.short)?"
            message = "A new commit on \(onto) takes back what “\(commit.subject)” changed. Nothing is removed from the history."
            confirm = "Revert"
        case .cherryPick:
            title = "Pick \(commit.short) onto \(onto)?"
            message = "A new commit on \(onto) makes the change of “\(commit.subject)” there too."
            confirm = "Cherry-Pick"
        }
    }
}

/// What is asked before a push is forced (#37), the same on every device:
/// which commits on the remote would be gone from the branch there.
public struct ForcePushQuestion: Equatable, Sendable {
    public var title: String
    public var message: String
    public var confirm: String
    /// Nothing would be overwritten: a plain push does it.
    public var isNeeded: Bool

    /// How many of the commits are named before the rest are counted.
    public static let shown = 8

    public init(branch: String, upstream: String, loses: [String]) {
        isNeeded = !loses.isEmpty
        title = "Force push “\(branch)” to \(upstream)?"
        confirm = "Force Push"
        guard isNeeded else {
            message = "\(upstream) has no commit that “\(branch)” does not have: a push without force does the same."
            return
        }
        let count = loses.count == 1 ? "This commit on \(upstream) is" : "These \(loses.count) commits on \(upstream) are"
        var lines = loses.prefix(Self.shown).map { "• " + $0 }
        if loses.count > Self.shown { lines.append("… and \(loses.count - Self.shown) more") }
        message =
            "\(count) not in “\(branch)” and will be gone from it there:\n\n" + lines.joined(separator: "\n")
            + "\n\nAnyone who has them is not asked. The push is refused if the remote changed again since it was looked at just now."
    }
}

/// A branch of a repository (#35): one of its own, or one of a remote's as
/// of the last time the remote was asked.
public struct BranchInfo: Codable, Equatable, Hashable, Identifiable, Sendable {
    /// "main", or "origin/main" for a remote's.
    public var name: String
    public var isRemote: Bool
    /// Checked out in the folder that was asked about.
    public var isCurrent: Bool
    /// The branch on a remote it follows, "origin/main". Nil when none.
    public var upstream: String?
    /// Commits it has that its upstream has not, and the other way round.
    /// Nil without an upstream, or when the upstream is gone.
    public var ahead: Int?
    public var behind: Int?
    /// The branch it followed has been deleted on the remote.
    public var upstreamGone: Bool
    /// Everything on it is on the checked out branch too: deleting it
    /// loses nothing. Always false for a remote's.
    public var isMerged: Bool
    /// When its last commit was made, and what that commit says.
    public var committedAt: Date?
    public var subject: String
    /// The folder of another worktree it is checked out in, which is why
    /// it cannot be switched to here. Nil when in none, or in this one.
    public var worktree: String?

    public var id: String { (isRemote ? "remote:" : "") + name }

    public init(
        name: String, isRemote: Bool = false, isCurrent: Bool = false, upstream: String? = nil, ahead: Int? = nil, behind: Int? = nil,
        upstreamGone: Bool = false, isMerged: Bool = false, committedAt: Date? = nil, subject: String = "", worktree: String? = nil
    ) {
        self.name = name
        self.isRemote = isRemote
        self.isCurrent = isCurrent
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
        self.upstreamGone = upstreamGone
        self.isMerged = isMerged
        self.committedAt = committedAt
        self.subject = subject
        self.worktree = worktree
    }

    /// The name a branch of the repository's own has when it is made from
    /// this one: "feature" for "origin/feature", its own name otherwise.
    public var localName: String {
        guard isRemote, let slash = name.firstIndex(of: "/") else { return name }
        return String(name[name.index(after: slash)...])
    }

    /// How far it is from the branch it follows, in a few words for a row:
    /// "2 ahead, 1 behind", "its remote branch is gone", or nothing.
    public var tracking: String {
        if upstreamGone { return "its remote branch is gone" }
        var parts: [String] = []
        if let ahead, ahead > 0 { parts.append("\(ahead) ahead") }
        if let behind, behind > 0 { parts.append("\(behind) behind") }
        return parts.joined(separator: ", ")
    }
}

/// What is asked before a branch is deleted (#35), the same on every
/// device. A branch whose commits are on the checked out branch too is
/// asked about once; one that has commits of its own is asked about twice,
/// the second time saying what would be lost.
public struct DeleteBranchQuestion: Equatable, Sendable {
    public var title: String
    public var message: String
    public var confirm: String

    /// - Parameter again: The second question, for a branch that is not merged.
    public init(branch: BranchInfo, into current: String?, again: Bool = false) {
        let onto = current.map { "“\($0)”" } ?? "the checked out commit"
        if again {
            title = "Delete “\(branch.name)” and lose its commits?"
            message = "Its commits are on no other branch here. Once it is deleted, git forgets them after a while, and nothing in AgentTerm brings them back."
            confirm = "Delete and Lose Its Commits"
        } else if branch.isMerged {
            title = "Delete the branch “\(branch.name)”?"
            message = "Everything on it is on \(onto) too, so nothing is lost."
            confirm = "Delete Branch"
        } else {
            title = "Delete the branch “\(branch.name)”?"
            message = "It has commits that are not on \(onto). You are asked once more before they are lost."
            confirm = "Delete…"
        }
    }
}

/// What the user is asked before changes are discarded (#39), the same on
/// the Mac and the iPhone: discarding cannot be taken back for a file git
/// tracks, and moves one it does not track to the Trash.
public struct DiscardQuestion: Equatable, Sendable {
    public var title: String
    public var message: String
    /// The button that does it.
    public var confirm: String

    /// - Parameter files: The changes to discard, none of them staged.
    public init(files: [FileDiff]) {
        let new = files.filter(\.isUntracked).count
        let tracked = files.count - new
        if files.count == 1, let file = files.first {
            let name = (file.path as NSString).lastPathComponent
            if file.isUntracked {
                title = "Move \(name) to the Trash?"
                message = "git does not track it yet, so nothing else keeps it. It can be put back from the Trash of the Mac."
                confirm = "Move to Trash"
            } else {
                title = "Discard the changes to \(name)?"
                message = "It goes back to what is staged of it, or to the last commit. This cannot be undone."
                confirm = "Discard Changes"
            }
            return
        }
        title = "Discard all \(files.count) changes?"
        var parts: [String] = []
        if tracked > 0 {
            parts.append(
                "\(tracked) \(tracked == 1 ? "file goes" : "files go") back to what is staged or to the last commit, which cannot be undone.")
        }
        if new > 0 { parts.append("\(new) new \(new == 1 ? "file is" : "files are") moved to the Trash of the Mac.") }
        message = parts.joined(separator: " ")
        confirm = "Discard All"
    }
}

extension FileDiff {
    /// What discarding this change is called on its row.
    public var discardLabel: String {
        let name = (path as NSString).lastPathComponent
        return isUntracked ? "Move \(name) to the Trash" : "Discard changes to \(name)"
    }
}

public struct DiffSnapshot: Codable, Equatable, Sendable {
    public var isRepository: Bool
    public var branch: String?
    public var files: [FileDiff]
    /// The branch on the remote that the checked out branch follows,
    /// "origin/main". Nil when it follows none.
    public var upstream: String?
    /// Commits the branch has that its upstream has not, and the other way
    /// round, as of the last time the remote was asked.
    public var ahead: Int?
    public var behind: Int?
    /// The remote a first push would go to, for a branch without an
    /// upstream. Nil when there is an upstream, or no remote at all.
    public var pushRemote: String?

    public init(
        isRepository: Bool, branch: String?, files: [FileDiff],
        upstream: String? = nil, ahead: Int? = nil, behind: Int? = nil, pushRemote: String? = nil
    ) {
        self.isRepository = isRepository
        self.branch = branch
        self.files = files
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
        self.pushRemote = pushRemote
    }

    /// Whether there is somewhere to push the branch to.
    public var canPush: Bool { branch != nil && (upstream != nil || pushRemote != nil) }
    /// Whether there is somewhere to pull from.
    public var canPull: Bool { branch != nil && upstream != nil }

    public static let notARepository = DiffSnapshot(isRepository: false, branch: nil, files: [])

    /// What the next commit would contain.
    public var staged: [FileDiff] { files.filter(\.isStaged) }
    /// Changes that are not staged, files git does not track yet included.
    public var unstaged: [FileDiff] { files.filter { !$0.isStaged } }

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

/// One file or folder in a listing.
public struct FileEntry: Codable, Identifiable, Equatable, Sendable {
    public var path: String
    public var name: String
    public var isDirectory: Bool
    /// True for a folder that is a git repository of its own.
    public var isRepository: Bool?

    public var id: String { path }

    public init(path: String, name: String, isDirectory: Bool, isRepository: Bool? = nil) {
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
        self.isRepository = isRepository
    }
}

/// What a file turned out to hold when it was opened.
public enum FileContent: Codable, Equatable, Sendable {
    case text(String)
    /// An image the system can draw.
    case image
    /// Not text in UTF-8, so not something to edit here.
    case binary
    case tooLarge(bytes: Int)

    /// A text file over the size the editor opens by itself is opened when
    /// asked, up to this size (#21).
    public static let largestOpenedAnyway = 20 * 1024 * 1024
}
