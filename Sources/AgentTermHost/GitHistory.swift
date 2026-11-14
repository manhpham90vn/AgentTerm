#if os(macOS)
import AgentTermProtocol
import Foundation

/// The history of a repository (#36): its commits a page at a time, what
/// one of them changed, and making a commit that takes one back or brings
/// one over.
extension GitActions {
    /// What `git log` and `git show` are asked to print of a commit: fields
    /// apart by NUL, which none of them can hold.
    private static let commitFormat = "%H%x00%P%x00%an%x00%at%x00%D%x00%s"

    private static func commit(from fields: [String]) -> CommitInfo? {
        guard fields.count >= 6, !fields[0].isEmpty else { return nil }
        // "HEAD -> main, origin/main, tag: v1": what points at it, by name.
        let refs = fields[4].components(separatedBy: ", ").map { $0.hasPrefix("HEAD -> ") ? String($0.dropFirst(8)) : $0 }
            .filter { !$0.isEmpty && $0 != "HEAD" && !$0.hasSuffix("/HEAD") }
        return CommitInfo(
            hash: fields[0], parents: fields[1].split(separator: " ").map(String.init), subject: fields[5], author: fields[2],
            date: Date(timeIntervalSince1970: TimeInterval(fields[3]) ?? 0), refs: refs)
    }

    /// Commits of a branch, the checked out one when none is named, newest
    /// first: `limit` of them after the first `skip`, and whether there are
    /// older ones still. None for a repository without a commit.
    public static func log(in directory: String, branch: String? = nil, skip: Int = 0, limit: Int = 50) -> (commits: [CommitInfo], more: Bool) {
        // One more than asked for says whether there are more.
        var arguments = ["-C", directory, "log", "--format=" + commitFormat + "%x01", "--skip=\(max(skip, 0))", "--max-count=\(max(limit, 1) + 1)"]
        if let branch, !branch.isEmpty { arguments.append(branch) }
        // After `--`, nothing is taken for a path or an option.
        arguments.append("--")
        guard let result = Subprocess.run("/usr/bin/git", arguments, timeout: 30), result.status == 0 else { return ([], false) }
        let found = String(decoding: result.output, as: UTF8.self).components(separatedBy: "\u{1}").compactMap {
            commit(from: $0.trimmingCharacters(in: .newlines).components(separatedBy: "\0"))
        }
        return (Array(found.prefix(max(limit, 1))), found.count > max(limit, 1))
    }

    /// As much of a commit's diffs as is sent with it; past this they are
    /// left out, and the commit says so.
    static let showLimit = 2_000_000

    /// A commit's message and what it changed, each file with its diff. A
    /// merge is shown against its first parent: what it brought in.
    public static func show(_ hash: String, in directory: String) -> CommitDetails? {
        guard
            let result = Subprocess.run(
                "/usr/bin/git",
                ["-C", directory, "show", "--first-parent", "-m", "--format=" + commitFormat + "%x00%b%x01", "--patch", "--no-color", "--no-ext-diff", hash, "--"],
                timeout: 30),
            result.status == 0
        else { return nil }
        let text = String(decoding: result.output, as: UTF8.self)
        guard let end = text.firstIndex(of: "\u{1}") else { return nil }
        let fields = text[..<end].components(separatedBy: "\0")
        guard let commit = commit(from: fields) else { return nil }
        var files = GitDiff.parse(String(text[text.index(after: end)...]))
        let tooLarge = files.reduce(0) { $0 + $1.patch.utf8.count } > showLimit
        if tooLarge {
            files = files.map {
                var file = $0; file.patch = ""; return file
            }
        }
        return CommitDetails(
            commit: commit, body: fields.count > 6 ? fields[6].trimmingCharacters(in: .whitespacesAndNewlines) : "", files: files, diffsLeftOut: tooLarge)
    }

    /// The commit the checked out branch is at, with its whole message and
    /// whether a remote has it. Nil for a repository without a commit.
    public static func lastCommit(in directory: String) -> LastCommit? {
        guard
            let result = Subprocess.run("/usr/bin/git", ["-C", directory, "log", "-1", "--format=" + commitFormat + "%x00%B", "HEAD", "--"], timeout: 30),
            result.status == 0
        else { return nil }
        let fields = String(decoding: result.output, as: UTF8.self).components(separatedBy: "\0")
        guard let commit = commit(from: fields), fields.count > 6 else { return nil }
        let onRemotes = list(["branch", "--remotes", "--contains", "HEAD", "--format=%(refname:short)"], in: directory) ?? []
        return LastCommit(commit: commit, message: fields[6].trimmingCharacters(in: .whitespacesAndNewlines), isPushed: !onRemotes.joined().isEmpty)
    }

    /// Replaces the last commit by one with `message` and with what is
    /// staged now added to it; an empty message keeps the one it has.
    public static func amend(message: String, in directory: String) -> String? {
        guard lastCommit(in: directory) != nil else { return "There is no commit to amend yet." }
        guard unfinished(in: directory) == nil else { return "A merge or a rebase is under way: finish it or abort it before amending." }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        // Hooks run here, and may call tools the user's shell finds.
        return findingTools {
            run(["commit", "--amend", "--quiet"] + (trimmed.isEmpty ? ["--no-edit"] : ["--message", trimmed]), in: directory, timeout: 120, environment: actionEnvironment)
        }
    }

    /// Takes the last commit back: the branch is at the commit before it,
    /// and what the commit changed is staged, with whatever was staged or
    /// changed besides. Nothing in the folder changes.
    public static func undoLastCommit(in directory: String) -> String? {
        guard let last = lastCommit(in: directory) else { return "There is no commit to undo yet." }
        guard unfinished(in: directory) == nil else { return "A merge or a rebase is under way: finish it or abort it before undoing a commit." }
        // The first commit has none before it: the branch is unborn again.
        if last.commit.parents.isEmpty { return run(["update-ref", "-d", "HEAD"], in: directory) }
        return run(["reset", "--soft", "HEAD~1"], in: directory)
    }

    /// Makes a commit on the checked out branch that takes back what
    /// `hash` changed. When that conflicts it is left to be resolved and
    /// continued, or aborted (#42).
    public static func revert(_ hash: String, in directory: String) -> String? {
        apply("revert", ["revert", "--no-edit"], hash, in: directory)
    }

    /// Makes the change of `hash` on the checked out branch too.
    public static func cherryPick(_ hash: String, in directory: String) -> String? {
        apply("cherry-pick", ["cherry-pick"], hash, in: directory)
    }

    private static func apply(_ what: String, _ command: [String], _ hash: String, in directory: String) -> String? {
        guard let details = show(hash, in: directory) else { return "There is no commit \(hash) here." }
        guard !details.commit.isMerge else {
            return "\(details.commit.short) is a merge of \(details.commit.parents.count) lines of history: git has to be told which one to keep (git \(what) -m), which is done in a terminal."
        }
        // One the user left unfinished is theirs, not this one's to undo.
        let marker = what == "revert" ? "REVERT_HEAD" : "CHERRY_PICK_HEAD"
        let before = marks(marker, in: directory)
        return findingTools { () -> String? in
            guard let problem = run(command + [hash], in: directory, timeout: 120, environment: actionEnvironment) else { return nil }
            guard !before, marks(marker, in: directory) else { return problem }
            // Left as it is, to be resolved and continued, or aborted (#42).
            return stoppedOnConflicts("\(what == "revert" ? "Reverting" : "Picking") \(details.commit.short)", as: what, said: problem)
        }
    }
}
#endif
