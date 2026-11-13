import Foundation

/// Where AgentTerm keeps the git worktrees it makes for sessions (#23):
/// inside the project, `<project>/.agentterm/worktrees/<branch>`, next to
/// the handoffs, so the project stays one folder to move, back up or delete.
public enum WorktreePath {
    public static let folder = ".agentterm/worktrees"

    /// The project a worktree AgentTerm made belongs to, nil for any other path.
    public static func project(of path: String) -> String? {
        guard let range = path.range(of: "/" + folder + "/") else { return nil }
        return String(path[..<range.lowerBound])
    }

    /// Whether a session started in `cwd` is one of `folder`'s: in it, or in
    /// one of the worktrees AgentTerm made for it.
    public static func belongs(_ cwd: String, to folder: String) -> Bool {
        cwd == folder || project(of: cwd) == folder
    }

    /// The default name of a new worktree's branch: the agent and a number
    /// no branch has yet.
    public static func branchName(agent: String, taken: Set<String>) -> String {
        var number = 1
        while taken.contains("agentterm/\(agent)-\(number)") { number += 1 }
        return "agentterm/\(agent)-\(number)"
    }
}

/// One of a repository's git worktrees (#23, #33), whoever made it.
public struct WorktreeInfo: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var path: String
    /// Its branch, nil for a detached HEAD.
    public var branch: String?
    /// The repository's own folder, the first of its worktrees.
    public var isMain: Bool
    /// Commits on its branch that the folder's branch does not have.
    public var ahead: Int
    /// Files changed in it and not committed.
    public var changed: Int
    /// A session runs in it.
    public var inUse: Bool
    /// git knows of it, and its folder is gone.
    public var missing: Bool
    /// AgentTerm made it, in the project's `.agentterm/worktrees`.
    public var isAgentTerm: Bool

    public var id: String { path }

    /// Work in it that is not in the folder's branch.
    public var hasUnmergedWork: Bool { ahead > 0 || changed > 0 }

    public init(path: String, branch: String?, isMain: Bool, ahead: Int = 0, changed: Int = 0, inUse: Bool = false, missing: Bool = false, isAgentTerm: Bool = false) {
        self.path = path
        self.branch = branch
        self.isMain = isMain
        self.ahead = ahead
        self.changed = changed
        self.inUse = inUse
        self.missing = missing
        self.isAgentTerm = isAgentTerm
    }
}

/// What to do with a worktree whose work is finished (#23).
public enum WorktreeFinish: String, Codable, Sendable {
    /// Merge its branch into the folder's branch, then remove it.
    case merge
    /// Push its branch and open a pull request with `gh`; it is kept.
    case pullRequest
    /// Remove it, and what is in it.
    case discard
}
