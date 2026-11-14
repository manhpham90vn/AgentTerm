#if os(macOS)
import AgentTermProtocol
import Foundation

/// A repository's git worktrees (#23, #33): those AgentTerm makes for a
/// session, in `<project>/.agentterm/worktrees/<branch>`, and any other.
public enum GitWorktrees {
    public struct Failure: Error, LocalizedError, Equatable {
        public var text: String
        public var errorDescription: String? { text }
    }

    private static func git(_ arguments: [String], in directory: String, timeout: TimeInterval = 30, environment: [String: String]? = nil) -> (status: Int32, output: String) {
        let result = Subprocess.run("/usr/bin/git", ["-C", directory] + arguments, timeout: timeout, mergeErrors: true, environment: environment)
        return (result?.status ?? -1, String(decoding: result?.output ?? Data(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func run(_ arguments: [String], in directory: String, timeout: TimeInterval = 30, environment: [String: String]? = nil) throws -> String {
        let result = git(arguments, in: directory, timeout: timeout, environment: environment)
        guard result.status == 0 else { throw Failure(text: result.output.isEmpty ? "git \(arguments.first ?? "") failed." : result.output) }
        return result.output
    }

    /// The top of the folder's repository, written the way the folder is
    /// written: git gives the real path, and a folder opened through a
    /// symbolic link (`/var`, `/tmp`) would not be found in it.
    static func top(of folder: String) throws -> (asWritten: String, real: String) {
        let real = try run(["rev-parse", "--show-toplevel"], in: folder)
        let prefix = (try? run(["rev-parse", "--show-prefix"], in: folder)) ?? ""
        var written = folder
        if !prefix.isEmpty, written.hasSuffix("/" + prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))) {
            written = String(written.dropLast(prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/")).count + 1))
        }
        return (written, real)
    }

    /// A path git gave, written the way the folder is.
    private static func written(_ path: String, top: (asWritten: String, real: String)) -> String {
        guard top.asWritten != top.real, path == top.real || path.hasPrefix(top.real + "/") else { return path }
        return top.asWritten + path.dropFirst(top.real.count)
    }

    /// The folder's repository's worktrees, the repository's own first.
    /// `inUse` names the folders sessions run in.
    public static func list(folder: String, inUse: Set<String> = []) -> [WorktreeInfo] {
        guard let porcelain = try? run(["worktree", "list", "--porcelain"], in: folder), let top = try? top(of: folder) else { return [] }
        let base = (try? run(["rev-parse", "--abbrev-ref", "HEAD"], in: folder)) ?? "HEAD"
        var list: [WorktreeInfo] = []
        for block in porcelain.components(separatedBy: "\n\n") {
            var path: String?
            var branch: String?
            var prunable = false
            for line in block.split(separator: "\n") {
                if line.hasPrefix("worktree ") { path = written(String(line.dropFirst("worktree ".count)), top: top) }
                if line.hasPrefix("branch ") { branch = String(line.dropFirst("branch ".count)).replacingOccurrences(of: "refs/heads/", with: "") }
                if line.hasPrefix("prunable") { prunable = true }
            }
            guard let path else { continue }
            let missing = prunable || !FileManager.default.fileExists(atPath: path)
            var info = WorktreeInfo(
                path: path, branch: branch, isMain: list.isEmpty, missing: missing,
                isAgentTerm: WorktreePath.project(of: path) != nil)
            if !info.isMain, let branch {
                info.ahead = Int((try? run(["rev-list", "--count", "\(base)..\(branch)"], in: folder)) ?? "") ?? 0
            }
            if !missing {
                info.changed = ((try? run(["status", "--porcelain"], in: path)) ?? "").split(separator: "\n").count
            }
            list.append(info)
        }
        // A session is in the deepest worktree its folder is in: one in a
        // worktree inside the project is not in the project's own.
        // Compared as real paths: a session's folder may be written another way.
        func real(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().path }
        let roots = list.map { real($0.path) }
        for used in inUse.map(real) {
            let holding = roots.indices.filter { used == roots[$0] || used.hasPrefix(roots[$0] + "/") }
            if let deepest = holding.max(by: { roots[$0].count < roots[$1].count }) { list[deepest].inUse = true }
        }
        return list
    }

    /// Makes a worktree of the folder's repository on a new branch cut from
    /// its current commit, and returns where to start the session: the same
    /// folder inside it. Nothing is brought along: no uncommitted change,
    /// nothing git ignores.
    public static func create(in folder: String, agent: String, branch wanted: String?) throws -> (directory: String, branch: String) {
        let top = try top(of: folder).asWritten
        // A worktree made from one made by AgentTerm goes next to the others.
        let projectTop = WorktreePath.project(of: top) ?? top
        let taken = Set(((try? run(["branch", "--list", "--format=%(refname:short)"], in: folder)) ?? "").split(separator: "\n").map(String.init))
        let branch = (wanted?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 } ?? WorktreePath.branchName(agent: agent, taken: taken)
        guard (try? run(["check-ref-format", "--branch", branch], in: folder)) != nil else { throw Failure(text: "“\(branch)” is not a name a branch can have.") }
        guard !taken.contains(branch) else { throw Failure(text: "A branch called “\(branch)” is there already.") }
        let root = URL(fileURLWithPath: projectTop).appendingPathComponent(WorktreePath.folder).appendingPathComponent(branch).path
        Handoff.keepOutOfGit(projectTop)
        try FileManager.default.createDirectory(atPath: (root as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        _ = try run(["worktree", "add", "-b", branch, root, "HEAD"], in: folder, timeout: 120)
        // The folder's place in its own checkout, in the new one: from the
        // top of the worktree it is in, not from the project's.
        let inside = folder.hasPrefix(top + "/") ? String(folder.dropFirst(top.count)) : ""
        return (root + inside, branch)
    }

    /// Merges, opens a pull request for, or throws away a worktree. What
    /// was done, in words: a pull request's address, for one.
    public static func finish(folder: String, path: String, finish: WorktreeFinish, deleteBranch: Bool) throws -> String {
        let worktrees = list(folder: folder)
        guard let worktree = worktrees.first(where: { $0.path == path }), !worktree.isMain else { throw Failure(text: "That is not a worktree of this folder.") }
        let branch = worktree.branch
        switch finish {
        case .merge:
            guard let branch else { throw Failure(text: "Its HEAD is detached: there is no branch to merge.") }
            guard worktree.changed == 0 else { throw Failure(text: "It has changes that are not committed: commit or discard them first.") }
            let merged = git(["merge", "--no-edit", branch], in: folder, timeout: 120, environment: GitActions.actionEnvironment)
            guard merged.status == 0 else {
                _ = git(["merge", "--abort"], in: folder)
                throw Failure(text: "The merge ran into conflicts and was undone. Merge in a terminal to resolve them.\n\n\(merged.output)")
            }
            _ = try run(["worktree", "remove", path], in: folder)
            if deleteBranch { _ = try run(["branch", "-d", branch], in: folder) }
            return "Merged \(branch) and removed its worktree."
        case .pullRequest:
            guard let branch else { throw Failure(text: "Its HEAD is detached: there is no branch to push.") }
            _ = try run(["push", "--set-upstream", "origin", branch], in: path, timeout: 120, environment: GitActions.actionEnvironment)
            // gh is the user's, found through their shell.
            let line = "gh pr create --fill --head " + Handoff.shellQuote(branch)
            guard
                let result = Subprocess.run(
                    HostEnvironment.shell, ["-l", "-i", "-c", line], cwd: path, timeout: 120, mergeErrors: true,
                    environment: HostEnvironment.loginShellCommandEnvironment)
            else {
                throw Failure(text: "gh could not be started.")
            }
            let said = String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard result.status == 0 else { throw Failure(text: said.isEmpty ? "gh could not open the pull request." : said) }
            return said.split(separator: "\n").last.map(String.init) ?? said
        case .discard:
            _ = try run(["worktree", "remove", "--force", path], in: folder)
            if deleteBranch, let branch { _ = try run(["branch", "-D", branch], in: folder) }
            return "Removed the worktree" + (deleteBranch && branch != nil ? " and its branch." : ".")
        }
    }
}
#endif
