#if os(macOS)
import AgentTermProtocol
import Foundation

/// Reads the uncommitted changes of a working directory with the `git` CLI.
public enum GitDiff {
    private static let git = "/usr/bin/git"
    private static let maxPatchBytes = 400_000
    private static let maxUntrackedFiles = 50

    /// Blocks while git runs. Call off the main thread.
    public static func snapshot(directory: String) -> DiffSnapshot {
        guard let inside = run(["rev-parse", "--is-inside-work-tree"], in: directory),
              inside.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
        else { return .notARepository }

        let branch = run(["branch", "--show-current"], in: directory)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // A rename is listed as a deleted file and a new one, so that every
        // entry is one path that can be staged or unstaged on its own.
        let options = ["--no-color", "--no-ext-diff", "--relative", "--no-renames"]
        // The index against the last commit is what a commit would record.
        // In a repository without commits git compares against nothing.
        var files = parse(run(["diff", "--cached"] + options, in: directory) ?? "").map { file -> FileDiff in
            var file = file
            file.isStaged = true
            return file
        }
        // The working tree against the index is what is not staged.
        files += parse(run(["diff"] + options, in: directory) ?? "")

        let untracked = (run(["ls-files", "--others", "--exclude-standard"], in: directory) ?? "")
            .split(whereSeparator: \.isNewline).map(String.init)
        for path in untracked.prefix(maxUntrackedFiles) {
            // `diff --no-index` exits with 1 when the files differ, which is the normal case here.
            let text = run(["diff", "--no-index"] + options + ["--", "/dev/null", path], in: directory, acceptStatus: [0, 1]) ?? ""
            var file = parse(text).first ?? FileDiff(path: path, added: 0, deleted: 0, isUntracked: true, patch: "")
            file.path = path
            file.isUntracked = true
            file.status = .added
            files.append(file)
        }
        return DiffSnapshot(isRepository: true, branch: branch?.isEmpty == false ? branch : nil, files: files)
    }

    private static func name(_ text: Substring) -> String {
        String(text.hasSuffix("\t") ? text.dropLast() : text)
    }

    /// Splits `git diff` output into one entry per file.
    static func parse(_ text: String) -> [FileDiff] {
        var files: [FileDiff] = []
        var header: [Substring] = []
        var body: [Substring] = []
        var inFile = false

        func flush() {
            guard inFile else { return }
            var path = ""
            for line in header {
                // git ends a name that has a space in it with a tab.
                if line.hasPrefix("+++ b/") { path = Self.name(line.dropFirst(6)) }
                else if line.hasPrefix("--- a/") && path.isEmpty { path = Self.name(line.dropFirst(6)) }
                else if line.hasPrefix("rename to ") { path = String(line.dropFirst(10)) }
            }
            if path.isEmpty, let first = header.first, let range = first.range(of: " b/", options: .backwards) {
                path = String(first[range.upperBound...])
            }
            let added = body.filter { $0.hasPrefix("+") }.count
            let deleted = body.filter { $0.hasPrefix("-") }.count
            var patch = body.joined(separator: "\n")
            if patch.utf8.count > maxPatchBytes {
                patch = String(patch.prefix(maxPatchBytes)) + "\n… diff truncated …"
            }
            if patch.isEmpty, header.contains(where: { $0.hasPrefix("Binary files") }) {
                patch = "Binary file changed"
            }
            var status = FileDiff.Status.modified
            if header.contains(where: { $0.hasPrefix("new file mode") }) { status = .added }
            if header.contains(where: { $0.hasPrefix("deleted file mode") }) { status = .deleted }
            files.append(FileDiff(path: path, added: added, deleted: deleted, isUntracked: false, patch: patch, status: status))
        }

        var inHunks = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git ") {
                flush()
                header = [line]
                body = []
                inFile = true
                inHunks = false
            } else if inFile {
                if line.hasPrefix("@@") { inHunks = true }
                if inHunks { body.append(line) } else { header.append(line) }
            }
        }
        if body.last == "" { body.removeLast() }
        flush()
        return files
    }

    private static func run(_ arguments: [String], in directory: String, acceptStatus: Set<Int32> = [0]) -> String? {
        guard let result = Subprocess.run(git, ["-C", directory, "-c", "core.quotepath=false"] + arguments, timeout: 15),
              acceptStatus.contains(result.status)
        else { return nil }
        return String(decoding: result.output, as: UTF8.self)
    }
}
/// Changes what the next commit will contain, and makes the commit.
///
/// Each call returns nil when it worked, or what git said when it did not.
public enum GitActions {
    private static let git = "/usr/bin/git"

    /// Stages files for the next commit. No files means every change,
    /// new and deleted files included.
    public static func stage(_ files: [String], in directory: String) -> String? {
        files.isEmpty ? run(["add", "--all"], in: directory) : run(["add", "--"] + files, in: directory)
    }

    /// Takes files out of the next commit, leaving the working tree as it
    /// is. No files means all of them.
    public static func unstage(_ files: [String], in directory: String) -> String? {
        // Before the first commit there is nothing to restore the index to,
        // so the files are taken out of it instead.
        let hasCommit = run(["rev-parse", "--verify", "--quiet", "HEAD"], in: directory) == nil
        if hasCommit {
            return run(["restore", "--staged", "--"] + (files.isEmpty ? ["."] : files), in: directory)
        }
        return run(["rm", "--cached", "-r", "--quiet", "--"] + (files.isEmpty ? ["."] : files), in: directory)
    }

    /// Commits what is staged, with the identity and hooks the repository is
    /// set up with.
    public static func commit(message: String, in directory: String) -> String? {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Write a commit message first." }
        return run(["commit", "--quiet", "--message", trimmed], in: directory, timeout: 120)
    }

    private static func run(_ arguments: [String], in directory: String, timeout: TimeInterval = 30) -> String? {
        // File names are taken as they are, not as patterns.
        guard let result = Subprocess.run(git, ["-C", directory, "--literal-pathspecs"] + arguments, timeout: timeout, mergeErrors: true) else {
            return "git could not be started."
        }
        guard result.status != 0 else { return nil }
        let said = String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return said.isEmpty ? "git exited with status \(result.status)." : said
    }
}
#endif
