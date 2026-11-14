#if os(macOS)
import AgentTermProtocol
import Foundation

/// Finding a file of a folder by its name, and the lines of its files that
/// hold a word (#45). Done by the host, so that it works the same for the
/// Mac app, for another Mac and for the iPhone.
///
/// What git ignores is left out, with `.git` and AgentTerm's own folder; a
/// submodule's files are the folder's too. In a folder that is no
/// repository the folder is walked.
public enum FileSearch {
    /// The most files of a folder that are looked through by name.
    static let maxFiles = 200_000
    /// The most lines a search for text gives.
    public static let maxMatches = 2000
    /// The most characters of a line that are sent with a match.
    static let maxLineLength = 300

    private static let skipped: Set<String> = [".git", ".DS_Store", ".agentterm"]

    // MARK: The files of a folder

    /// The files of a folder, named from it: what git tracks and what it
    /// does not track and does not ignore, its submodules' too; in a folder
    /// that is no repository, every file but the skipped ones.
    public static func files(in directory: String, isCancelled: () -> Bool = { false }) -> [String] {
        var found: [String] = []
        if !gitFiles(in: directory, prefix: "", into: &found, isCancelled: isCancelled) { walk(directory, into: &found, isCancelled: isCancelled) }
        return found
    }

    private static func git(_ arguments: [String], in directory: String, timeout: TimeInterval = 60) -> Data? {
        guard let result = Subprocess.run("/usr/bin/git", ["-C", directory] + arguments, timeout: timeout), result.status == 0 else { return nil }
        return result.output
    }

    /// False when the folder is not in a repository.
    private static func gitFiles(in directory: String, prefix: String, into found: inout [String], isCancelled: () -> Bool) -> Bool {
        guard let staged = git(["ls-files", "--stage", "-z"], in: directory) else { return false }
        let deleted = Set(records(git(["ls-files", "--deleted", "-z"], in: directory) ?? Data()))
        var last: Substring?
        for record in records(staged) {
            // "<mode> <hash> <stage>\t<path>"; a file that conflicts is there once for each side.
            guard let tab = record.firstIndex(of: "\t") else { continue }
            let path = record[record.index(after: tab)...]
            guard path != last, !deleted.contains(path) else { continue }
            last = path
            if record.hasPrefix("160000 ") {
                // A submodule: its own files, when it is checked out.
                if isCancelled() || found.count >= maxFiles { return true }
                _ = gitFiles(in: (directory as NSString).appendingPathComponent(String(path)), prefix: prefix + path + "/", into: &found, isCancelled: isCancelled)
            } else {
                found.append(prefix + path)
            }
            if found.count >= maxFiles { return true }
        }
        // A folder of another repository inside this one is listed as a
        // folder, with a slash: not a file.
        for path in records(git(["ls-files", "--others", "--exclude-standard", "-z"], in: directory) ?? Data()) where !path.hasSuffix("/") {
            guard !skipped.contains(String(path.split(separator: "/").first ?? "")) else { continue }
            found.append(prefix + path)
            if found.count >= maxFiles { return true }
        }
        return true
    }

    private static func records(_ data: Data) -> [Substring] {
        String(decoding: data, as: UTF8.self).split(separator: "\0")
    }

    private static func walk(_ directory: String, into found: inout [String], isCancelled: () -> Bool) {
        let root = URL(fileURLWithPath: directory).standardizedFileURL
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: []) else { return }
        let base = root.path.hasSuffix("/") ? root.path : root.path + "/"
        var count = 0
        for case let url as URL in walker {
            if skipped.contains(url.lastPathComponent) {
                walker.skipDescendants()
                continue
            }
            count += 1
            if count % 512 == 0, isCancelled() { return }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let path = url.standardizedFileURL.path
            found.append(path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path)
            if found.count >= maxFiles { return }
        }
    }

    // MARK: By name

    /// The files whose name or path holds the letters of `query` in their
    /// order, the best first: a name that has it whole before one that has
    /// its letters apart, the name before the folders it is in, a short
    /// path before a long one. With a slash in it the query is of the path.
    public static func rank(_ files: [String], query: String, limit: Int = 100) -> [String] {
        let wanted = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !wanted.isEmpty else { return [] }
        let ofPath = wanted.contains("/")
        var scored: [(score: Int, path: String)] = []
        for path in files {
            let lower = Array(path.lowercased())
            let nameStart = (lower.lastIndex(of: "/").map { $0 + 1 }) ?? 0
            var best: Int?
            if !ofPath, let score = score(wanted, in: lower[nameStart...]) { best = score + 10_000 }
            if best == nil, let score = score(wanted, in: lower[...]) { best = score }
            if let best { scored.append((best - path.count, path)) }
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.path < $1.path }
        return scored.prefix(limit).map(\.path)
    }

    /// How well the letters match a piece of text, nil when they are not
    /// all in it in their order.
    private static func score(_ wanted: [Character], in text: ArraySlice<Character>) -> Int? {
        // All of it in one piece is best, and best of all at the start or
        // after a separator.
        if let at = firstRange(of: wanted, in: text) {
            let atStart = at == text.startIndex || isSeparator(text[at - 1])
            return 5000 + (atStart ? 2000 : 0)
        }
        var score = 0
        var index = text.startIndex
        var previous: Int?
        for letter in wanted {
            guard let found = text[index...].firstIndex(of: letter) else { return nil }
            if let previous, found == previous + 1 { score += 30 }
            if found == text.startIndex || isSeparator(text[found - 1]) { score += 20 }
            if let previous { score -= min(found - previous - 1, 10) }
            previous = found
            index = found + 1
        }
        return score
    }

    private static func isSeparator(_ character: Character) -> Bool { character == "/" || character == "." || character == "-" || character == "_" || character == " " }

    private static func firstRange(of wanted: [Character], in text: ArraySlice<Character>) -> Int? {
        guard wanted.count <= text.count else { return nil }
        var start = text.startIndex
        let last = text.endIndex - wanted.count
        while start <= last {
            if text[start] == wanted[0], Array(text[start..<start + wanted.count]) == wanted { return start }
            start += 1
        }
        return nil
    }

    // MARK: Text in files

    /// How a search for text ended.
    public struct Ending: Equatable, Sendable {
        /// There were more lines than are given.
        public var truncated = false
        /// Why it could not be done, in words.
        public var problem: String?
    }

    /// The lines of the folder's files that hold `query`, given as they
    /// are found, a file's at a time or more. Binary files and those larger
    /// than the editor opens are not searched.
    ///
    /// Blocks until it is over. `isCancelled` is asked between pieces; a
    /// search that is stopped ends quietly.
    public static func text(
        _ query: String, in directory: String, caseSensitive: Bool, limit: Int = maxMatches, isCancelled: @escaping () -> Bool, found: @escaping ([TextMatch]) -> Void
    ) -> Ending {
        guard !query.isEmpty else { return Ending() }
        var left = limit
        var ending = Ending()
        if let inRepository = grep(query, in: directory, prefix: "", caseSensitive: caseSensitive, left: &left, isCancelled: isCancelled, found: found) {
            ending = inRepository
        } else {
            ending = walkForText(query, in: directory, caseSensitive: caseSensitive, left: &left, isCancelled: isCancelled, found: found)
        }
        return ending
    }

    /// Whether a file is one the search gives lines of: not larger than
    /// the editor opens. Asked once for each file.
    private final class Sizes {
        private var known: [String: Bool] = [:]
        func isSearched(_ path: String) -> Bool {
            if let known = known[path] { return known }
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
            let searched = size <= FileBrowser.maxTextBytes
            known[path] = searched
            return searched
        }
    }

    /// `git grep` in a repository and then in each of its submodules. Nil
    /// when the folder is not in a repository.
    private static func grep(
        _ query: String, in directory: String, prefix: String, caseSensitive: Bool, left: inout Int, isCancelled: @escaping () -> Bool,
        found: @escaping ([TextMatch]) -> Void
    ) -> Ending? {
        guard let staged = git(["ls-files", "--stage", "-z"], in: directory) else { return nil }
        var ending = Ending()
        // Fixed text, not a pattern; files nobody tracks too, but not what
        // is ignored; no binary files; each match with its line and column.
        var arguments = ["-C", directory, "grep", "--untracked", "-I", "-n", "--column", "-F", "--no-color", "-z"]
        if !caseSensitive { arguments.append("-i") }
        arguments += ["-e", query, "--", "."]
        let sizes = Sizes()
        var pending = Data()
        var given = left
        let ended = Subprocess.stream("/usr/bin/git", arguments) { data in
            if isCancelled() { return false }
            pending.append(data)
            // Whole lines only: the last piece may be cut anywhere.
            guard let end = pending.lastIndex(of: 0x0A) else { return true }
            let whole = pending[pending.startIndex...end]
            pending = Data(pending[pending.index(after: end)...])
            var matches: [TextMatch] = []
            for line in whole.split(separator: 0x0A) {
                guard given > 0 else { break }
                // "path\0line\0column\0text"
                let parts = line.split(separator: 0, maxSplits: 3, omittingEmptySubsequences: false)
                guard parts.count == 4, let number = Int(String(decoding: parts[1], as: UTF8.self)), let column = Int(String(decoding: parts[2], as: UTF8.self)) else {
                    continue
                }
                let path = String(decoding: parts[0], as: UTF8.self)
                guard !skipped.contains(String(path.split(separator: "/").first ?? "")),
                    sizes.isSearched((directory as NSString).appendingPathComponent(path))
                else { continue }
                matches.append(match(file: prefix + path, line: number, column: column, bytes: parts[3], length: query.utf8.count))
                given -= 1
            }
            if !matches.isEmpty { found(matches) }
            return given > 0
        }
        if given <= 0 { ending.truncated = true }
        left = given
        // 1 is git's "nothing found"; ended by this search when it had enough or was stopped.
        if case .exited(let status)? = ended, status > 1, left > 0, !isCancelled() { ending.problem = "git could not search \(prefix.isEmpty ? "the folder" : prefix)." }
        if ended == nil { ending.problem = "git could not be started." }

        // Each submodule that is checked out, the same way.
        for record in records(staged) where record.hasPrefix("160000 ") {
            guard left > 0, !isCancelled(), let tab = record.firstIndex(of: "\t") else { break }
            let path = String(record[record.index(after: tab)...])
            let inside = grep(
                query, in: (directory as NSString).appendingPathComponent(path), prefix: prefix + path + "/", caseSensitive: caseSensitive, left: &left,
                isCancelled: isCancelled, found: found)
            if inside?.truncated == true { ending.truncated = true }
        }
        return ending
    }

    /// One line that holds the text: cut to what is shown of it, around
    /// where the text is, with where the text is in what is left.
    static func match(file: String, line: Int, column: Int, bytes: Data.SubSequence, length: Int) -> TextMatch {
        let text = String(decoding: bytes, as: UTF8.self)
        // The column is counted in bytes, from 1.
        let before = String(decoding: bytes.prefix(max(column - 1, 0)), as: UTF8.self)
        let found = String(decoding: bytes.dropFirst(max(column - 1, 0)).prefix(length), as: UTF8.self)
        var start = before.count
        var shown = text
        // Leading blanks say nothing in a list of lines.
        let blanks = shown.prefix { $0 == " " || $0 == "\t" }.count
        if blanks > 0, blanks <= start {
            shown.removeFirst(blanks)
            start -= blanks
        }
        if shown.count > maxLineLength {
            // A long line, a minified file's for one: what is around the text.
            let from = max(0, min(start - 40, shown.count - maxLineLength))
            let cut = shown.dropFirst(from).prefix(maxLineLength)
            shown = (from > 0 ? "…" : "") + cut + (from + maxLineLength < shown.count ? "…" : "")
            start = start - from + (from > 0 ? 1 : 0)
        }
        return TextMatch(file: file, line: line, text: shown, start: start, length: found.count)
    }

    /// The same in a folder that is no repository: each file read and
    /// looked through.
    private static func walkForText(
        _ query: String, in directory: String, caseSensitive: Bool, left: inout Int, isCancelled: () -> Bool, found: ([TextMatch]) -> Void
    ) -> Ending {
        var ending = Ending()
        var files: [String] = []
        walk(directory, into: &files, isCancelled: isCancelled)
        let needle = Data((caseSensitive ? query : query.lowercased()).utf8)
        for file in files {
            if isCancelled() { return ending }
            guard left > 0 else {
                ending.truncated = true
                return ending
            }
            let path = (directory as NSString).appendingPathComponent(file)
            guard let size = try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int, size <= FileBrowser.maxTextBytes, size >= needle.count,
                let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe), !data.prefix(8000).contains(0)
            else { continue }
            // Most files do not hold it: said by one look at the whole.
            guard let whole = String(data: data, encoding: .utf8) else { continue }
            let searched = caseSensitive ? whole : whole.lowercased()
            guard searched.contains(caseSensitive ? query : query.lowercased()) else { continue }
            var matches: [TextMatch] = []
            var number = 0
            let most = left
            whole.enumerateLines { line, stop in
                number += 1
                let range = caseSensitive ? line.range(of: query) : line.range(of: query, options: .caseInsensitive)
                guard let range else { return }
                let bytes = Data(line.utf8)
                let column = line[..<range.lowerBound].utf8.count + 1
                matches.append(match(file: file, line: number, column: column, bytes: bytes[...], length: line[range].utf8.count))
                if matches.count >= most { stop = true }
            }
            if !matches.isEmpty {
                left -= matches.count
                found(matches)
            }
        }
        if left <= 0 { ending.truncated = true }
        return ending
    }
}
#endif
