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
