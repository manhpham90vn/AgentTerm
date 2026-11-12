#if os(macOS)
import Darwin
import Foundation

/// Reads which hosts the user's SSH configuration names, to offer `ssh
/// <host>` as a session. It only reads, and only names: keys, addresses
/// and options stay where they are.
public enum SSHConfig {
    /// The aliases of `~/.ssh/config` and the files it includes, in the
    /// order they are written. Patterns (`*`, `?`, `!`) are not hosts and
    /// are left out, and so is any name that is not plain, since a name is
    /// put on a command line.
    public static func hosts(home: String = NSHomeDirectory()) -> [String] {
        let directory = URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent(".ssh", isDirectory: true)
        var found: [String] = []
        var visited: Set<String> = []
        read(directory.appendingPathComponent("config").path, directory: directory.path, home: home, depth: 0, into: &found, visited: &visited)
        var seen: Set<String> = []
        return found.filter { seen.insert($0).inserted }
    }

    /// Whether a name may be put after `ssh` on a command line.
    public static func isSafeHost(_ name: String) -> Bool { AgentHistory.isSafeIdentifier(name) }

    private static func read(_ path: String, directory: String, home: String, depth: Int, into found: inout [String], visited: inout Set<String>) {
        // Includes may point back at a file already read.
        guard depth <= 8, visited.insert(path).inserted, let data = FileManager.default.contents(atPath: path), data.count <= 1_048_576 else {
            return
        }
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            let words = words(of: line)
            guard let keyword = words.first?.lowercased() else { continue }
            switch keyword {
            case "host":
                found += words.dropFirst().filter { !$0.contains("*") && !$0.contains("?") && !$0.hasPrefix("!") && isSafeHost($0) }
            case "include":
                for pattern in words.dropFirst() {
                    for file in expand(pattern, directory: directory, home: home) {
                        read(file, directory: directory, home: home, depth: depth + 1, into: &found, visited: &visited)
                    }
                }
            default:
                break
            }
        }
    }

    /// A line as its words: `Keyword value value`, or `Keyword=value`.
    /// Quotes group a value that has spaces. A `#` where a word would
    /// start makes the rest of the line a comment, as ssh reads it: without
    /// that, the words of a comment after `Host` would be taken for hosts.
    static func words(of line: Substring) -> [String] {
        var words: [String] = []
        var current = ""
        var quoted = false
        var started = false
        for character in line {
            if character == "\"" {
                quoted.toggle()
                started = true
            } else if !quoted, !started, character == "#" {
                break
            } else if !quoted, character == " " || character == "\t" || (character == "=" && words.isEmpty) {
                if started { words.append(current) }
                current = ""
                started = false
            } else {
                current.append(character)
                started = true
            }
        }
        if started { words.append(current) }
        return words
    }

    /// The files an `Include` names: relative to `~/.ssh`, with `~` and
    /// wildcards, as ssh reads it.
    private static func expand(_ pattern: String, directory: String, home: String) -> [String] {
        var path = pattern
        if path == "~" || path.hasPrefix("~/") {
            path = home + path.dropFirst()
        } else if !path.hasPrefix("/") {
            path = directory + "/" + path
        }
        var matches = glob_t()
        defer { globfree(&matches) }
        guard glob(path, 0, nil, &matches) == 0, let paths = matches.gl_pathv else { return [] }
        return (0..<Int(matches.gl_pathc)).compactMap { paths[$0].map { String(cString: $0) } }
    }
}
#endif
