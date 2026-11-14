#if os(macOS)
import AgentTermProtocol
import Foundation

/// The branches of a repository (#35): what there is, and checking out,
/// making, renaming and deleting one. Each change returns nil when it
/// worked, or what to tell the user when it did not, with git's own words.
extension GitActions {
    /// The repository's own branches, the checked out one first and the
    /// rest by their last commit, newest first; then its remotes', the
    /// same way. Empty for a folder that is not a repository.
    public static func branches(in directory: String) -> [BranchInfo] {
        // One field to a line would break on a subject with a tab in it;
        // NUL cannot be in any of them.
        let fields = ["%(refname)", "%(refname:short)", "%(HEAD)", "%(upstream:short)", "%(upstream:track,nobracket)", "%(committerdate:unix)", "%(worktreepath)", "%(contents:subject)"]
        guard
            let result = Subprocess.run(
                "/usr/bin/git", ["-C", directory, "for-each-ref", "--format=" + fields.joined(separator: "%00") + "%01", "refs/heads", "refs/remotes"], timeout: 30),
            result.status == 0
        else { return [] }
        let merged = Set(list(["branch", "--format=%(refname:short)", "--merged", "HEAD"], in: directory)?.flatMap { $0.split(separator: "\n").map(String.init) } ?? [])
        let here = (try? URL(fileURLWithPath: directory).resourceValues(forKeys: [.canonicalPathKey]).canonicalPath) ?? directory
        let top = list(["rev-parse", "--show-toplevel"], in: directory)?.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? here
        var found: [BranchInfo] = []
        // A record ends with a byte no field holds: two fields that are
        // both empty leave two NULs side by side.
        for record in String(decoding: result.output, as: UTF8.self).components(separatedBy: "\u{1}") {
            let parts = record.trimmingCharacters(in: .newlines).components(separatedBy: "\0")
            guard parts.count == fields.count else { continue }
            let isRemote = parts[0].hasPrefix("refs/remotes/")
            // A remote's HEAD names another of its branches: not one itself.
            if isRemote && parts[0].hasSuffix("/HEAD") { continue }
            let track = parts[4]
            let worktree = parts[6]
            found.append(
                BranchInfo(
                    name: parts[1], isRemote: isRemote, isCurrent: parts[2] == "*", upstream: parts[3].isEmpty ? nil : parts[3],
                    ahead: parts[3].isEmpty || track == "gone" ? nil : GitDiff.count("ahead", in: track),
                    behind: parts[3].isEmpty || track == "gone" ? nil : GitDiff.count("behind", in: track), upstreamGone: track == "gone",
                    isMerged: !isRemote && merged.contains(parts[1]), committedAt: TimeInterval(parts[5]).map(Date.init(timeIntervalSince1970:)),
                    subject: parts[7], worktree: worktree.isEmpty || worktree == top || parts[2] == "*" ? nil : worktree))
        }
        func ordered(_ list: [BranchInfo]) -> [BranchInfo] {
            list.sorted {
                if $0.isCurrent != $1.isCurrent { return $0.isCurrent }
                if $0.committedAt != $1.committedAt { return ($0.committedAt ?? .distantPast) > ($1.committedAt ?? .distantPast) }
                return $0.name < $1.name
            }
        }
        return ordered(found.filter { !$0.isRemote }) + ordered(found.filter(\.isRemote))
    }

    /// Checks a branch out. A remote's is checked out as a branch of the
    /// repository's own of that name, which follows it: the one there is,
    /// or a new one.
    public static func switchTo(_ branch: String, in directory: String) -> String? {
        let all = branches(in: directory)
        var arguments = ["switch", "--no-guess", branch]
        if let remote = all.first(where: { $0.isRemote && $0.name == branch }), !all.contains(where: { !$0.isRemote && $0.name == branch }) {
            arguments =
                all.contains { !$0.isRemote && $0.name == remote.localName }
                ? ["switch", "--no-guess", remote.localName] : ["switch", "--no-guess", "--track", branch]
        }
        guard let problem = run(arguments, in: directory) else { return nil }
        if problem.contains("would be overwritten") {
            return "Switching to \(branch) would lose changes that are not committed. Commit, stash or discard them first.\n\n\(problem)"
        }
        return problem
    }

    /// Makes a branch from another branch or a commit, the checked out
    /// commit when none is named, and checks it out when asked. It follows
    /// no branch of a remote until it is pushed.
    public static func createBranch(_ name: String, from start: String?, checkout: Bool, in directory: String) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return "Give the branch a name." }
        guard list(["check-ref-format", "--branch", name], in: directory) != nil else {
            return "“\(name)” cannot be the name of a branch: no spaces, no “..”, and none of ~ ^ : ? * [ \\."
        }
        let from = (start?.isEmpty == false) ? [start!] : []
        return run((checkout ? ["switch", "--no-track", "-c", name] : ["branch", "--no-track", name]) + from, in: directory)
    }

    public static func renameBranch(_ branch: String, to name: String, in directory: String) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return "Give the branch a name." }
        guard list(["check-ref-format", "--branch", name], in: directory) != nil else {
            return "“\(name)” cannot be the name of a branch: no spaces, no “..”, and none of ~ ^ : ? * [ \\."
        }
        return run(["branch", "--move", branch, name], in: directory)
    }

    /// Deletes a branch of the repository's own. One whose commits are on
    /// no other branch is deleted only with `force`: without it git
    /// refuses, and its words are returned.
    public static func deleteBranch(_ branch: String, force: Bool, in directory: String) -> String? {
        run(["branch", force ? "-D" : "-d", branch], in: directory)
    }
}
#endif
