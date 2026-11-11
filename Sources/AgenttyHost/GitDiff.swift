#if os(macOS)
import AgenttyProtocol
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

        // Compare against HEAD so staged and unstaged edits both show. A
        // repository without commits has no HEAD, so fall back to the index.
        let options = ["--no-color", "--no-ext-diff", "--relative"]
        let tracked = run(["diff", "HEAD"] + options, in: directory) ?? run(["diff"] + options, in: directory) ?? ""
        var files = parse(tracked)

        let untracked = (run(["ls-files", "--others", "--exclude-standard"], in: directory) ?? "")
            .split(whereSeparator: \.isNewline).map(String.init)
        for path in untracked.prefix(maxUntrackedFiles) {
            // `diff --no-index` exits with 1 when the files differ, which is the normal case here.
            let text = run(["diff", "--no-index"] + options + ["--", "/dev/null", path], in: directory, acceptStatus: [0, 1]) ?? ""
            var file = parse(text).first ?? FileDiff(path: path, added: 0, deleted: 0, isUntracked: true, patch: "")
            file.path = path
            file.isUntracked = true
            files.append(file)
        }
        return DiffSnapshot(isRepository: true, branch: branch?.isEmpty == false ? branch : nil, files: files)
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
                if line.hasPrefix("+++ b/") { path = String(line.dropFirst(6)) }
                else if line.hasPrefix("--- a/") && path.isEmpty { path = String(line.dropFirst(6)) }
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
            files.append(FileDiff(path: path, added: added, deleted: deleted, isUntracked: false, patch: patch))
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
#endif
