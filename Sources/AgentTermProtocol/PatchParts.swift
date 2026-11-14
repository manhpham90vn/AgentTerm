import Foundation

/// One hunk of a file's diff, as the parts of it that can be staged,
/// unstaged or discarded by themselves (#40).
public struct PatchHunk: Equatable, Identifiable, Sendable {
    /// Its place among the file's hunks.
    public var id: Int
    /// "@@ -10,6 +10,9 @@ func name": the header as git wrote it.
    public var header: String
    /// Where it starts in the file as it was, and as it is.
    public var oldStart: Int
    public var newStart: Int
    /// What follows the second "@@" of the header: the function it is in.
    public var section: String
    /// Its lines, each with its first character: " " for one that is the
    /// same on both sides, "-" for one taken out, "+" for one put in, and
    /// "\" for git's note that a file does not end with a newline.
    public var lines: [String]

    /// The lines that are a change, by their place in `lines`.
    public var changed: [Int] { lines.indices.filter { lines[$0].hasPrefix("+") || lines[$0].hasPrefix("-") } }

    public var added: Int { lines.filter { $0.hasPrefix("+") }.count }
    public var removed: Int { lines.filter { $0.hasPrefix("-") }.count }
}

/// A file's diff taken apart into hunks, and put together again as a patch
/// that holds one hunk, or some lines of one, for `git apply`.
public enum PatchParts {
    /// The hunks of a patch that starts at its first hunk header, which is
    /// how `FileDiff.patch` holds it.
    public static func hunks(of patch: String) -> [PatchHunk] {
        var hunks: [PatchHunk] = []
        for line in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("@@") {
                guard let (old, new, section) = header(String(line)) else { continue }
                hunks.append(PatchHunk(id: hunks.count, header: String(line), oldStart: old, newStart: new, section: section, lines: []))
            } else if !hunks.isEmpty {
                // What the diff was cut off with is not part of it.
                if line.hasPrefix("…") { break }
                hunks[hunks.count - 1].lines.append(String(line))
            }
        }
        // A patch ends with a newline, which leaves an empty piece after
        // the last line: not a line of the hunk.
        for index in hunks.indices {
            while let last = hunks[index].lines.last, last.isEmpty { hunks[index].lines.removeLast() }
        }
        return hunks
    }

    /// "@@ -10,6 +10,9 @@ func name" as (10, 10, "func name").
    static func header(_ line: String) -> (Int, Int, String)? {
        let parts = line.components(separatedBy: "@@")
        guard parts.count >= 3 else { return nil }
        let ranges = parts[1].trimmingCharacters(in: .whitespaces).split(separator: " ")
        guard ranges.count == 2, ranges[0].hasPrefix("-"), ranges[1].hasPrefix("+") else { return nil }
        func start(_ range: Substring) -> Int? { Int(range.dropFirst().split(separator: ",").first ?? "") }
        guard let old = start(ranges[0]), let new = start(ranges[1]) else { return nil }
        return (old, new, parts[2...].joined(separator: "@@").trimmingCharacters(in: .whitespaces))
    }

    /// What a part of a diff is applied for.
    public enum Use: String, Sendable {
        /// Into the next commit: a change that is not staged yet.
        case stage
        /// Out of the next commit: a change that is staged.
        case unstage
        /// Out of the folder: a change that is not staged, thrown away.
        case discard

        /// Staging puts the change in; the other two take it back out,
        /// which is the same patch applied the other way round.
        public var reversed: Bool { self != .stage }
    }

    /// A patch for `git apply` that holds one hunk of a file's diff, or only
    /// the lines of it that were picked.
    ///
    /// The lines left out have to read, in the patch, as what the side the
    /// patch is applied to holds. Applied forward, that side is the file
    /// as it was: a line put in that is left out is not there, so it goes;
    /// a line taken out that is left out is still there, so it stays as a
    /// line both sides have. Applied the other way round, that side is the
    /// file as it is, and it is the reverse.
    ///
    /// - Parameters:
    ///   - picked: The changed lines to keep, by their place in the hunk's
    ///     lines; nil for all of them.
    /// - Returns: Nil when nothing of the hunk is picked.
    public static func patch(path: String, hunk: PatchHunk, picked: Set<Int>? = nil, use: Use) -> String? {
        var lines: [String] = []
        var anything = false
        // Whether the line before is in the patch: git's note that a file
        // does not end with a newline belongs to the line it follows.
        var keptLast = false
        for (index, line) in hunk.lines.enumerated() {
            if line.hasPrefix("\\") {
                if keptLast { lines.append(line) }
                continue
            }
            guard line.hasPrefix("+") || line.hasPrefix("-") else {
                lines.append(line.isEmpty ? " " : line)
                keptLast = true
                continue
            }
            if picked?.contains(index) ?? true {
                lines.append(line)
                anything = true
                keptLast = true
            } else if line.hasPrefix(use.reversed ? "+" : "-") {
                // Still there on the side the patch is applied to.
                lines.append(" " + line.dropFirst())
                keptLast = true
            } else {
                keptLast = false
            }
        }
        guard anything else { return nil }
        let old = lines.filter { $0.hasPrefix(" ") || $0.hasPrefix("-") }.count
        let new = lines.filter { $0.hasPrefix(" ") || $0.hasPrefix("+") }.count
        var text = "diff --git a/\(path) b/\(path)\n"
        text += "--- a/\(path)\n+++ b/\(path)\n"
        return text + "@@ -\(hunk.oldStart),\(old) +\(hunk.newStart),\(new) @@\n" + lines.joined(separator: "\n") + "\n"
    }
}
