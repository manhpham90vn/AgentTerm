#if os(macOS)
import AgentTermProtocol
import Foundation

/// What is done while a merge, a rebase, a cherry-pick or a revert is
/// stopped on conflicts (#42): each file is resolved by taking one side or
/// by hand, and then it is continued, or it is all aborted.
extension GitActions {
    /// How a file that conflicts is resolved.
    public enum Resolution: String, Sendable {
        /// What the checked out side has (`--ours`).
        case ours
        /// What is being brought in (`--theirs`).
        case theirs
        /// As the file is now: the user edited it, and its markers are gone.
        case edited
    }

    /// The two letters git gives a file that conflicts, nil for one that does not.
    private static func conflictCode(of file: String, in directory: String) -> String? {
        guard let records = list(["status", "--porcelain=v2", "-z", "--", file], in: directory) else { return nil }
        for record in records where record.hasPrefix("u ") { return String(record.dropFirst(2).prefix(2)) }
        return nil
    }

    /// Resolves one file. Taking a side that deleted the file deletes it.
    /// A file said to be edited is refused while it still has a marker.
    public static func resolve(_ file: String, as resolution: Resolution, in directory: String) -> String? {
        guard let code = conflictCode(of: file, in: directory) else { return "\(file) does not conflict, or no longer." }
        switch resolution {
        case .edited:
            let path = (directory as NSString).appendingPathComponent(file)
            if let text = try? String(contentsOfFile: path, encoding: .utf8),
                text.split(separator: "\n", omittingEmptySubsequences: false).contains(where: { $0.hasPrefix("<<<<<<< ") || $0.hasPrefix(">>>>>>> ") })
            {
                return "\(file) still has conflict markers (<<<<<<< and >>>>>>>). Edit them out, or take one side."
            }
            // A file that was deleted by hand is resolved as deleted.
            return FileManager.default.fileExists(atPath: path) ? run(["add", "--", file], in: directory) : run(["rm", "--quiet", "--", file], in: directory)
        case .ours, .theirs:
            // In git's letters the first is ours and the second theirs: "D"
            // where that side deleted the file, "A" where only it has it.
            let side = resolution == .ours ? code.first : code.last
            let other = resolution == .ours ? code.last : code.first
            if side == "D" || (side == "U" && other == "A") {
                // That side has no such file.
                return run(["rm", "--quiet", "--", file], in: directory)
            }
            if let problem = run(["checkout", resolution == .ours ? "--ours" : "--theirs", "--", file], in: directory) { return problem }
            return run(["add", "--", file], in: directory)
        }
    }

    /// The operation git is stopped in the middle of in a folder.
    public static func operation(in directory: String) -> GitOperation? {
        guard
            let result = Subprocess.run("/usr/bin/git", ["-C", directory, "rev-parse", "--absolute-git-dir"], timeout: 15), result.status == 0
        else { return nil }
        return GitDiff.operation(inGitDirectory: String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The commit that is checked out in a folder; nil when it is no
    /// repository, or has no commit yet.
    public static func head(in directory: String) -> String? {
        guard let result = Subprocess.run("/usr/bin/git", ["-C", directory, "rev-parse", "--verify", "--quiet", "HEAD"], timeout: 15), result.status == 0 else { return nil }
        let hash = String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return hash.isEmpty ? nil : hash
    }

    /// How a folder was when a run started in it (#47): what was changed
    /// in it already is not what the run changed.
    public struct Baseline: Sendable {
        /// The commit that was checked out; nil with none yet.
        public var head: String?
        /// The files as they were, changes that were not committed
        /// included, as a commit nothing points to; the head when nothing
        /// was changed.
        public var tree: String?
        /// The files nobody tracked.
        public var untracked: Set<String>
    }

    /// Nil when the folder is no repository.
    public static func baseline(in directory: String) -> Baseline? {
        guard let untracked = list(["ls-files", "--others", "--exclude-standard", "-z"], in: directory) else { return nil }
        let head = head(in: directory)
        var tree = head
        // Writes the state of the files as a commit, and changes nothing:
        // no branch, no stash, not the index. It says nothing when the
        // files are as the head has them.
        if head != nil, let made = Subprocess.run("/usr/bin/git", ["-C", directory, "stash", "create"], timeout: 60), made.status == 0 {
            let hash = String(decoding: made.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !hash.isEmpty { tree = hash }
        }
        return Baseline(head: head, tree: tree, untracked: Set(untracked))
    }

    /// What was changed in a folder since a run started in it, in words:
    /// the commits made since, the files changed since, committed or not,
    /// and the new files nobody tracks. "Nothing changed" when nothing did.
    public static func changes(since start: Baseline, in directory: String) -> String? {
        guard let untracked = list(["ls-files", "--others", "--exclude-standard", "-z"], in: directory) else { return nil }
        var parts: [String] = []
        let now = head(in: directory)
        if let from = start.head, let now, from != now,
            let count = list(["rev-list", "--count", "\(from)..\(now)"], in: directory)?.first.flatMap({ Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }), count > 0
        {
            parts.append("\(count) \(count == 1 ? "commit" : "commits")")
        } else if start.head == nil, now != nil {
            parts.append("the first commit")
        }
        // The files as they are against the files as they were.
        if let tree = start.tree, let stat = list(["diff", "--shortstat", tree], in: directory)?.first?.trimmingCharacters(in: .whitespacesAndNewlines), !stat.isEmpty {
            parts.append(stat.replacingOccurrences(of: "(+)", with: "").replacingOccurrences(of: "(-)", with: ""))
        }
        let new = untracked.filter { !start.untracked.contains($0) }.count
        if new > 0 { parts.append("\(new) new \(new == 1 ? "file" : "files") not tracked") }
        return parts.isEmpty ? "Nothing changed" : parts.joined(separator: ", ")
    }

    /// Goes on with what was stopped, once every file is resolved. A rebase
    /// may stop again, on the next of its commits that conflicts: said so.
    public static func continueOperation(in directory: String) -> String? {
        guard let operation = operation(in: directory) else { return "Nothing is stopped on conflicts here." }
        let left = GitDiff.snapshot(directory: directory).conflicts
        guard left.isEmpty else {
            return "\(left.count) \(left.count == 1 ? "file still conflicts" : "files still conflict"): \(left.map(\.path).joined(separator: ", ")). Resolve them first."
        }
        // No editor is opened for a message: the one git made is kept.
        let quiet = ["-c", "core.editor=true"]
        let arguments: [String]
        switch operation {
        case .merge: arguments = quiet + ["commit", "--no-edit", "--quiet"]
        case .rebase: arguments = quiet + ["rebase", "--continue"]
        case .cherryPick: arguments = quiet + ["cherry-pick", "--continue"]
        case .revert: arguments = quiet + ["revert", "--continue"]
        }
        return findingTools { () -> String? in
            guard let problem = run(arguments, in: directory, timeout: 120, environment: actionEnvironment, literalPaths: false) else { return nil }
            if self.operation(in: directory) != nil, !GitDiff.snapshot(directory: directory).conflicts.isEmpty {
                return "It went on and stopped again, on the next change that conflicts. Resolve those files, then Continue.\n\n\(problem)"
            }
            return problem
        }
    }

    /// Gives up what was stopped: the folder and the branch are as before it began.
    public static func abortOperation(in directory: String) -> String? {
        guard let operation = operation(in: directory) else { return "Nothing is stopped on conflicts here." }
        return run([operation.rawValue, "--abort"], in: directory, literalPaths: false)
    }
}
#endif
