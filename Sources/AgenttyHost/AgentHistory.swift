#if os(macOS)
import Foundation

/// A past conversation with an agent, found in that agent's own files.
public struct Conversation: Identifiable, Equatable, Sendable {
    /// Agent id: "claude", "codex", "agy" or "copilot".
    public var agent: String
    /// The agent's own identifier for the conversation.
    public var sessionID: String
    public var title: String
    public var updatedAt: Date
    /// Directory the conversation ran in.
    public var cwd: String
    /// File holding the conversation's messages, when the agent keeps one
    /// that can be read.
    public var source: String?

    public var id: String { agent + ":" + sessionID }

    /// Command line that reopens the conversation in its agent.
    public var resumeCommand: String {
        switch agent {
        case "claude": return "claude --resume \(sessionID)"
        case "codex": return "codex resume \(sessionID)"
        case "agy": return "agy --conversation \(sessionID)"
        case "copilot": return "copilot --resume=\(sessionID)"
        default: return agent
        }
    }
}

/// Reads the conversation history each agent CLI keeps on disk.
///
/// Nothing here is a public format: these are the files the CLIs happen to
/// write today. Every reader therefore treats missing or unexpected data as
/// "no conversations" instead of failing.
public enum AgentHistory {
    private static let headBytes = 256 * 1024
    private static let tailBytes = 64 * 1024
    private static let maxFilesPerAgent = 400

    /// Conversations that ran in `directory`, newest first. Blocks on file
    /// access, so call it off the main thread. `home` is replaceable for tests.
    ///
    /// Only the directory itself counts unless `includeSubfolders` is set. A
    /// project folder shows its own conversations, the way it shows its own
    /// git changes; a workspace of several projects would otherwise list
    /// every project's conversations under the workspace.
    public static func conversations(
        in directory: String,
        includeSubfolders: Bool = false,
        home: String = NSHomeDirectory(),
        limit: Int = 200
    ) -> [Conversation] {
        let directory = URL(fileURLWithPath: directory).standardizedFileURL.path
        let home = URL(fileURLWithPath: home, isDirectory: true)
        let scope = Scope(directory: directory, includeSubfolders: includeSubfolders)
        let all = claude(scope, home) + codex(scope, home) + antigravity(scope, home) + copilot(scope, home)
        return Array(
            all.filter { isSafeIdentifier($0.sessionID) && !$0.title.isEmpty }
                .sorted { $0.updatedAt > $1.updatedAt }
                .prefix(limit)
        )
    }

    /// Every conversation the agents have on this machine, newest first,
    /// whatever folder it ran in.
    public static func allConversations(home: String = NSHomeDirectory(), limit: Int = 300) -> [Conversation] {
        let home = URL(fileURLWithPath: home, isDirectory: true)
        let scope = Scope(directory: nil, includeSubfolders: true)
        let all = claude(scope, home) + codex(scope, home) + antigravity(scope, home) + copilot(scope, home)
        return Array(
            all.filter { isSafeIdentifier($0.sessionID) && !$0.title.isEmpty }
                .sorted { $0.updatedAt > $1.updatedAt }
                .prefix(limit)
        )
    }

    private struct Scope {
        /// `nil` means every folder.
        let directory: String?
        let includeSubfolders: Bool

        /// True when a conversation that ran in `path` belongs to this scope.
        func contains(_ path: String) -> Bool {
            guard let directory else { return true }
            let path = URL(fileURLWithPath: path).standardizedFileURL.path
            if path == directory { return true }
            return includeSubfolders && path.hasPrefix(directory.hasSuffix("/") ? directory : directory + "/")
        }
    }

    /// Session ids end up in a shell command line, so only plain ones pass.
    static func isSafeIdentifier(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 128 && id.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" || $0 == "_" || $0 == "."
        } && !id.hasPrefix("-")
    }

    // MARK: Claude Code

    /// `~/.claude/projects/<directory with every non-alphanumeric as "-">/<session>.jsonl`
    private static func claude(_ scope: Scope, _ home: URL) -> [Conversation] {
        let projects = home.appendingPathComponent(".claude/projects")
        let own = scope.directory.map(claudeProjectName)
        // Subfolders of the directory have their own project folder. The name
        // alone cannot tell "apps/web" from a sibling "apps-web", and cannot
        // be turned back into a path at all, so for any folder but the
        // directory's own the path recorded inside the session is used.
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: projects.path)) ?? []).filter { name in
            guard let own else { return true }
            return name == own || (scope.includeSubfolders && name.hasPrefix(own + "-"))
        }
        let files = names.flatMap { name in
            recentFiles(in: projects.appendingPathComponent(name), suffix: ".jsonl").map { (name: name, file: $0) }
        }
        return files.sorted { $0.file.modified > $1.file.modified }.prefix(maxFilesPerAgent).compactMap { entry -> Conversation? in
            let file = entry.file
            let session = file.url.deletingPathExtension().lastPathComponent
            guard !session.hasPrefix("agent-") else { return nil }
            var head: Data?
            let cwd: String
            if let directory = scope.directory, entry.name == own {
                cwd = directory
            } else {
                let data = read(file.url, head: headBytes)
                head = data
                guard let recorded = lines(of: data, containing: "\"cwd\"", limit: 1).first?["cwd"] as? String,
                      scope.contains(recorded)
                else { return nil }
                cwd = recorded
            }
            // The CLI keeps rewriting an "ai-title" line, so the newest is near the end.
            var title = lines(of: read(file.url, tail: tailBytes), containing: "\"ai-title\"").reversed()
                .lazy.compactMap { $0["aiTitle"] as? String }.first
            if title == nil {
                let data = head ?? read(file.url, head: headBytes)
                title = lines(of: data, containing: "\"summary\"").lazy.compactMap { $0["summary"] as? String }.first
                    ?? lines(of: data, containing: "\"user\"").lazy.compactMap(claudePrompt).first
            }
            guard let title else { return nil }
            return Conversation(agent: "claude", sessionID: session, title: clean(title), updatedAt: file.modified, cwd: cwd, source: file.url.path)
        }
    }

    static func claudeProjectName(for directory: String) -> String {
        String(directory.unicodeScalars.map { scalar -> Character in
            scalar.isASCII && CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "-"
        })
    }

    static func claudePrompt(_ line: [String: Any]) -> String? {
        guard line["type"] as? String == "user", line["isMeta"] as? Bool != true, line["isSidechain"] as? Bool != true,
              let message = line["message"] as? [String: Any]
        else { return nil }
        var text: String?
        if let content = message["content"] as? String {
            text = content
        } else if let parts = message["content"] as? [[String: Any]] {
            text = parts.lazy.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.first
        }
        // Slash commands and their output are recorded as tagged user lines.
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<") else { return nil }
        return text
    }

    // MARK: Codex

    /// `~/.codex/sessions/<year>/<month>/<day>/rollout-<time>-<id>.jsonl`, whose
    /// first line holds the id and directory. Prompts are in `history.jsonl`.
    private static func codex(_ scope: Scope, _ home: URL) -> [Conversation] {
        let root = home.appendingPathComponent(".codex/sessions")
        var files: [(url: URL, modified: Date)] = []
        if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for case let url as URL in enumerator where url.lastPathComponent.hasPrefix("rollout-") && url.pathExtension == "jsonl" {
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                files.append((url, modified))
            }
        }
        files = Array(files.sorted { $0.modified > $1.modified }.prefix(maxFilesPerAgent))
        guard !files.isEmpty else { return [] }

        var prompts: [String: String] = [:]
        for line in lines(of: read(home.appendingPathComponent(".codex/history.jsonl"), tail: 2 * 1024 * 1024), containing: "session_id") {
            if let id = line["session_id"] as? String, let text = line["text"] as? String, prompts[id] == nil { prompts[id] = text }
        }

        return files.compactMap { file in
            let head = read(file.url, head: headBytes)
            guard let meta = lines(of: head, containing: "\"session_meta\"", limit: 1).first?["payload"] as? [String: Any],
                  let id = meta["id"] as? String, let cwd = meta["cwd"] as? String, scope.contains(cwd)
            else { return nil }
            // Sessions an agent started for a sub-task are not the user's conversations.
            if let source = meta["source"] as? [String: Any], source["subagent"] != nil { return nil }
            let title = prompts[id] ?? lines(of: head, containing: "\"user_message\"").lazy.compactMap { line -> String? in
                guard let payload = line["payload"] as? [String: Any], payload["type"] as? String == "user_message" else { return nil }
                return payload["message"] as? String
            }.first
            guard let title else { return nil }
            return Conversation(agent: "codex", sessionID: id, title: clean(title), updatedAt: file.modified, cwd: cwd, source: file.url.path)
        }
    }

    // MARK: Antigravity

    /// `~/.gemini/antigravity-cli/cache/conversation_metadata.json`
    private static func antigravity(_ scope: Scope, _ home: URL) -> [Conversation] {
        let file = home.appendingPathComponent(".gemini/antigravity-cli/cache/conversation_metadata.json")
        guard let data = try? Data(contentsOf: file),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let conversations = root["conversations"] as? [String: Any]
        else { return [] }
        return conversations.compactMap { id, value in
            guard let entry = value as? [String: Any], entry["is_internal"] as? Bool != true,
                  let summary = entry["summary"] as? [String: Any], summary["Internal"] as? Bool != true,
                  let workspaces = summary["WorkspaceURIs"] as? [String]
            else { return nil }
            let paths = workspaces.compactMap { URL(string: $0)?.standardizedFileURL.path }
            guard let cwd = paths.first(where: scope.contains) else { return nil }
            let title = [summary["Title"], summary["Preview"]].lazy.compactMap { $0 as? String }.first { !$0.isEmpty }
            let stamp = (summary["UpdatedAt"] as? String) ?? (entry["last_modified_time"] as? String) ?? ""
            guard let title, let date = parseDate(stamp) else { return nil }
            // The CLI also writes each conversation as readable JSON lines;
            // the "full" file is the one without truncated messages.
            let logs = home.appendingPathComponent(".gemini/antigravity-cli/brain/\(id)/.system_generated/logs")
            let transcript = ["transcript_full.jsonl", "transcript.jsonl"]
                .map { logs.appendingPathComponent($0).path }
                .first(where: FileManager.default.fileExists(atPath:))
            return Conversation(agent: "agy", sessionID: id, title: clean(title), updatedAt: date, cwd: cwd, source: transcript)
        }
    }

    // MARK: Copilot CLI

    /// `~/.copilot/session-state/<id>/workspace.yaml`, flat `key: value` lines.
    private static func copilot(_ scope: Scope, _ home: URL) -> [Conversation] {
        let root = home.appendingPathComponent(".copilot/session-state")
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return folders.prefix(maxFilesPerAgent * 4).compactMap { folder in
            let workspace = folder.appendingPathComponent("workspace.yaml")
            guard let text = try? String(contentsOf: workspace, encoding: .utf8) else { return nil }
            var fields: [String: String] = [:]
            for line in text.split(whereSeparator: \.isNewline) {
                guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" ") else { continue }
                var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" {
                    value = String(value.dropFirst().dropLast())
                }
                fields[String(line[..<colon])] = value
            }
            guard let cwd = fields["cwd"], scope.contains(cwd) else { return nil }
            let id = fields["id"] ?? folder.lastPathComponent
            var title = fields["name"]
            if title?.isEmpty != false {
                title = lines(of: read(folder.appendingPathComponent("events.jsonl"), head: headBytes), containing: "\"user.message\"")
                    .lazy.compactMap { ($0["data"] as? [String: Any])?["content"] as? String }.first
            }
            let modified = (try? workspace.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            guard let title, let date = fields["updated_at"].flatMap(parseDate) ?? modified else { return nil }
            return Conversation(agent: "copilot", sessionID: id, title: clean(title), updatedAt: date, cwd: cwd, source: folder.appendingPathComponent("events.jsonl").path)
        }
    }

    // MARK: Helpers

    private static func recentFiles(in folder: URL, suffix: String) -> [(url: URL, modified: Date)] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return Array(
            urls.filter { $0.lastPathComponent.hasSuffix(suffix) }
                .map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast) }
                .sorted { $0.1 > $1.1 }
                .prefix(maxFilesPerAgent)
        )
    }

    /// Session files grow to many megabytes, so only an end of them is read.
    static func read(_ url: URL, head: Int? = nil, tail: Int? = nil) -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? handle.close() }
        if let tail, let size = try? handle.seekToEnd(), size > UInt64(tail) {
            try? handle.seek(toOffset: size - UInt64(tail))
        } else {
            try? handle.seek(toOffset: 0)
        }
        return (try? handle.read(upToCount: head ?? tail ?? 0)) ?? Data()
    }

    /// Parses the JSON lines that mention `needle`. A line cut off by the
    /// read window does not parse and is skipped.
    private static func lines(of data: Data, containing needle: String, limit: Int = .max) -> [[String: Any]] {
        let needle = Data(needle.utf8)
        var result: [[String: Any]] = []
        for line in data.split(separator: 0x0a) where line.range(of: needle) != nil {
            if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                result.append(object)
                if result.count >= limit { break }
            }
        }
        return result
    }

    /// One line, no runs of whitespace, short enough for a list row.
    static func clean(_ title: String) -> String {
        let words = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return words.count > 140 ? String(words.prefix(140)) + "…" : words
    }

    /// ISO 8601 with any number of fractional digits, which Foundation's
    /// parser does not accept beyond milliseconds.
    static func parseDate(_ text: String) -> Date? {
        var text = text
        if let dot = text.firstIndex(of: ".") {
            let end = text[dot...].dropFirst().firstIndex { !$0.isNumber } ?? text.endIndex
            let digits = text[text.index(after: dot)..<end]
            text.replaceSubrange(dot..<end, with: "." + digits.prefix(3).padding(toLength: 3, withPad: "0", startingAt: 0))
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.date(from: text)
        }
        return ISO8601DateFormatter().date(from: text)
    }
}
#endif
