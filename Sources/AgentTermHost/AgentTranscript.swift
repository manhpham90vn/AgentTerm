#if os(macOS)
import AgentTermProtocol
import Foundation

/// Reading a conversation as a transcript, searching what was said in the
/// conversations, and deleting one (#46).
///
/// How each agent writes its conversations was read from the files of the
/// versions in use on 2026-11-14: Claude Code 2.1, Codex CLI 0.169, Copilot
/// CLI and Antigravity CLI. A line that is not as expected is left out.
extension AgentHistory {
    /// Largest part of a session file that is read.
    private static let detailBytes = 24 * 1024 * 1024
    /// The most entries of a conversation that are given: its end.
    static let maxEntries = 600
    /// The most characters of one entry.
    static let maxEntryLength = 12_000
    /// The most characters of what a tool was run on.
    private static let maxToolLength = 300

    /// The tools of Claude Code that write to a file, and the argument that
    /// names it. Copilot says which files it changed when a session ends;
    /// Codex and Antigravity run commands, which do not say.
    private static let writingTools: [String: String] = [
        "Edit": "file_path", "Write": "file_path", "MultiEdit": "file_path", "NotebookEdit": "notebook_path",
    ]

    /// Reads a conversation from its agent's file. Blocks on file access.
    public static func details(of conversation: Conversation) -> ConversationDetails {
        var details = ConversationDetails(conversation: conversation)
        guard let source = conversation.source else { return details }
        let data = read(URL(fileURLWithPath: source), tail: detailBytes)
        var reader = Reader(agent: conversation.agent)
        for line in data.split(separator: 0x0a) {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            reader.take(object)
        }
        details.omitted = max(reader.entries.count - maxEntries, 0)
        details.entries = reader.entries.suffix(maxEntries).enumerated().map { index, entry in
            var entry = entry
            entry.id = details.omitted + index
            return entry
        }
        details.startedAt = reader.first
        details.endedAt = reader.last
        details.model = reader.model
        details.inputTokens = reader.input
        details.outputTokens = reader.output
        details.cost = reader.cost
        details.branch = reader.branch
        details.files = reader.tellsFiles ? reader.files : nil
        details.tools = reader.tools
        return details
    }

    /// What is gathered from a conversation's lines, one at a time.
    private struct Reader {
        let agent: String
        var entries: [TranscriptEntry] = []
        var first: Date?
        var last: Date?
        var model: String?
        var input: Int?
        var output: Int?
        var cost: Double?
        var branch: String?
        var files: [String] = []
        /// Whether this record names the files that were written: Claude
        /// Code's does with each tool, Copilot's once its session ended.
        var tellsFiles: Bool
        var tools = 0
        /// Claude Code writes a message's usage on each of its lines.
        private var counted: Set<String> = []

        init(agent: String) {
            self.agent = agent
            tellsFiles = agent == "claude"
        }

        private mutating func say(_ kind: TranscriptEntry.Kind, _ text: String, tool: String? = nil, at: Date?) {
            var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if kind != .tool, text.isEmpty { return }
            let limit = kind == .tool ? AgentHistory.maxToolLength : AgentHistory.maxEntryLength
            if text.count > limit { text = String(text.prefix(limit)) + "…" }
            if kind == .tool {
                tools += 1
                // One line for a tool: what follows a line break says little.
                text = text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
            }
            entries.append(TranscriptEntry(id: entries.count, kind: kind, text: text, tool: tool, at: at))
        }

        private mutating func wrote(_ file: String?) {
            guard let file, !file.isEmpty, !files.contains(file) else { return }
            files.append(file)
        }

        /// What a tool was run on, from its arguments: a command, a file,
        /// a pattern; the first of them that is there.
        private func subject(_ arguments: [String: Any]) -> String {
            for key in ["command", "file_path", "path", "notebook_path", "pattern", "query", "url", "description", "prompt"] {
                if let value = arguments[key] as? String, !value.isEmpty { return value }
            }
            return ""
        }

        mutating func take(_ line: [String: Any]) {
            let stamp = ((line["timestamp"] as? String) ?? (line["created_at"] as? String)).flatMap(AgentHistory.parseDate)
            if let stamp {
                if first == nil { first = stamp }
                last = stamp
            }
            switch agent {
            case "claude": claude(line, at: stamp)
            case "codex": codex(line, at: stamp)
            case "copilot": copilot(line, at: stamp)
            case "agy": antigravity(line, at: stamp)
            default: break
            }
        }

        private mutating func claude(_ line: [String: Any], at stamp: Date?) {
            guard line["isSidechain"] as? Bool != true else { return }
            if let name = line["gitBranch"] as? String, !name.isEmpty { branch = name }
            switch line["type"] as? String {
            case "user":
                if let prompt = AgentHistory.claudePrompt(line) { say(.user, prompt, at: stamp) }
            case "assistant":
                guard let message = line["message"] as? [String: Any] else { return }
                if let name = message["model"] as? String, !name.hasPrefix("<") { model = name }
                if let id = message["id"] as? String, counted.insert(id).inserted, let usage = message["usage"] as? [String: Any] {
                    let read = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"].compactMap { usage[$0] as? Int }.reduce(0, +)
                    input = (input ?? 0) + read
                    output = (output ?? 0) + (usage["output_tokens"] as? Int ?? 0)
                }
                for part in message["content"] as? [[String: Any]] ?? [] {
                    switch part["type"] as? String {
                    case "text": say(.agent, part["text"] as? String ?? "", at: stamp)
                    case "tool_use":
                        let name = part["name"] as? String ?? "tool"
                        let arguments = part["input"] as? [String: Any] ?? [:]
                        say(.tool, subject(arguments), tool: name, at: stamp)
                        if let key = AgentHistory.writingTools[name] { wrote(arguments[key] as? String) }
                    default: break
                    }
                }
            default: break
            }
        }

        private mutating func codex(_ line: [String: Any], at stamp: Date?) {
            guard let payload = line["payload"] as? [String: Any] else { return }
            switch line["type"] as? String {
            case "turn_context":
                if let name = payload["model"] as? String { model = name }
            case "token_usage_record":
                if let usage = payload["thread_token_usage"] as? [String: Any] {
                    input = usage["input_tokens"] as? Int ?? input
                    output = usage["output_tokens"] as? Int ?? output
                }
            case "event_msg":
                guard payload["type"] as? String == "token_count", let usage = (payload["info"] as? [String: Any])?["total_token_usage"] as? [String: Any] else { return }
                input = usage["input_tokens"] as? Int ?? input
                output = usage["output_tokens"] as? Int ?? output
            case "response_item":
                switch payload["type"] as? String {
                case "message":
                    guard let parts = payload["content"] as? [[String: Any]] else { return }
                    let text = parts.compactMap { part -> String? in
                        guard let type = part["type"] as? String, ["input_text", "output_text", "text"].contains(type) else { return nil }
                        return part["text"] as? String
                    }.joined(separator: "\n\n")
                    if payload["role"] as? String == "assistant" {
                        say(.agent, text, at: stamp)
                    } else if payload["role"] as? String == "user" {
                        // The CLI records the context it adds as the user's too.
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !["<environment_context", "<user_instructions", "<permissions", "<turn_aborted"].contains(where: trimmed.hasPrefix) { say(.user, text, at: stamp) }
                    }
                case "function_call":
                    let arguments = (payload["arguments"] as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } ?? [:]
                    say(.tool, subject(arguments), tool: payload["name"] as? String ?? "tool", at: stamp)
                case "custom_tool_call", "local_shell_call":
                    say(.tool, payload["input"] as? String ?? "", tool: payload["name"] as? String ?? "shell", at: stamp)
                default: break
                }
            default: break
            }
        }

        private mutating func copilot(_ line: [String: Any], at stamp: Date?) {
            guard let data = line["data"] as? [String: Any] else { return }
            switch line["type"] as? String {
            case "user.message": say(.user, data["content"] as? String ?? "", at: stamp)
            case "assistant.message":
                if let name = data["model"] as? String { model = name }
                say(.agent, data["content"] as? String ?? "", at: stamp)
            case "session.model_change":
                if let name = data["newModel"] as? String { model = name }
            case "tool.execution_start":
                let name = data["toolName"] as? String ?? "tool"
                let arguments = data["arguments"] as? [String: Any] ?? [:]
                say(.tool, subject(arguments), tool: name, at: stamp)
            case "session.shutdown":
                guard let changed = (data["codeChanges"] as? [String: Any])?["filesModified"] as? [String] else { return }
                tellsFiles = true
                changed.forEach { wrote($0) }
            case "session.usage_record":
                // Its "cost" is in a unit of Copilot's own, not money: left out.
                guard let usage = data["usage"] as? [String: Any] else { return }
                if let tokens = usage["inputTokens"] as? Int { input = (input ?? 0) + tokens }
                if let tokens = usage["outputTokens"] as? Int { output = (output ?? 0) + tokens }
            default: break
            }
        }

        private mutating func antigravity(_ line: [String: Any], at stamp: Date?) {
            let source = line["source"] as? String, type = line["type"] as? String
            let content = line["content"] as? String ?? ""
            if source == "USER_EXPLICIT" || source == "USER", type == "USER_INPUT" || type == "REQUEST" {
                // The request is wrapped in a tag, next to context the CLI adds.
                if let open = content.range(of: "<USER_REQUEST>") {
                    let rest = content[open.upperBound...]
                    say(.user, String(rest[..<(rest.range(of: "</USER_REQUEST>")?.lowerBound ?? rest.endIndex)]), at: stamp)
                } else {
                    say(.user, content, at: stamp)
                }
                return
            }
            guard source == "MODEL", type == "PLANNER_RESPONSE" else { return }
            if let tokens = line["input_tokens"] as? Int { input = (input ?? 0) + tokens + (line["cache_read_tokens"] as? Int ?? 0) }
            if let tokens = line["output_tokens"] as? Int { output = (output ?? 0) + tokens }
            say(.agent, content, at: stamp)
            for call in line["tool_calls"] as? [[String: Any]] ?? [] {
                say(.tool, subject(call["args"] as? [String: Any] ?? [:]), tool: call["name"] as? String ?? "tool", at: stamp)
            }
        }
    }

    /// The conversation an agent has under an id, found among its own
    /// files: what a client names is looked up, never taken as a path.
    public static func conversation(agent: String, sessionID: String, cwd: String, home: String = NSHomeDirectory()) -> Conversation? {
        guard isSafeIdentifier(sessionID) else { return nil }
        return conversations(in: cwd, home: home, limit: .max).first { $0.agent == agent && $0.sessionID == sessionID }
    }

    // MARK: Searching

    /// The conversations whose title or what was said in them holds
    /// `query`, whatever its case, given as they are found. Blocks until it
    /// is over; `isCancelled` is asked between conversations.
    public static func search(_ query: String, in conversations: [Conversation], isCancelled: () -> Bool, found: (HistoryHit) -> Void) {
        let wanted = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !wanted.isEmpty else { return }
        // Text is written in the file as it was said, unless it holds a
        // character JSON writes another way: then the file's bytes cannot
        // say that the words are not there.
        let plain = wanted.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == " " || $0 == "-" || $0 == "_" || $0 == ".") }
        for conversation in conversations {
            if isCancelled() { return }
            let inTitle = conversation.title.lowercased().contains(wanted)
            var hit = HistoryHit(conversation: conversation)
            if let source = conversation.source {
                let data = read(URL(fileURLWithPath: source), tail: detailBytes)
                if !plain || holds(data, wanted) {
                    for message in transcript(of: conversation, data: data) {
                        let lower = message.text.lowercased()
                        guard let range = lower.range(of: wanted) else { continue }
                        hit.count += 1
                        if hit.snippet == nil { hit.snippet = snippet(of: message.text, around: lower.distance(from: lower.startIndex, to: range.lowerBound), length: wanted.count) }
                    }
                }
            }
            if inTitle || hit.count > 0 { found(hit) }
        }
    }

    /// Whether the bytes hold the text, whatever the case of its ASCII letters.
    static func holds(_ data: Data, _ lowercased: String) -> Bool {
        let needle = Array(lowercased.utf8)
        guard !needle.isEmpty, data.count >= needle.count else { return false }
        return data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Bool in
            let count = bytes.count
            let first = needle[0]
            var index = 0
            let last = count - needle.count
            while index <= last {
                var byte = bytes[index]
                if byte >= 0x41, byte <= 0x5A { byte += 0x20 }
                if byte == first {
                    var matched = 1
                    while matched < needle.count {
                        var next = bytes[index + matched]
                        if next >= 0x41, next <= 0x5A { next += 0x20 }
                        if next != needle[matched] { break }
                        matched += 1
                    }
                    if matched == needle.count { return true }
                }
                index += 1
            }
            return false
        }
    }

    /// A piece of text around a place in it, on one line.
    static func snippet(of text: String, around offset: Int, length: Int) -> String {
        let characters = Array(text)
        let from = max(offset - 60, 0)
        let to = min(offset + length + 100, characters.count)
        let piece = String(characters[from..<to]).split(whereSeparator: \.isNewline).joined(separator: " ")
        return (from > 0 ? "…" : "") + piece + (to < characters.count ? "…" : "")
    }

    // MARK: Deleting

    /// Moves a conversation's record to the Trash, so that its agent no
    /// longer has it. Nil when done, or why it was not.
    public static func delete(_ conversation: Conversation, home: String = NSHomeDirectory()) -> String? {
        guard let source = conversation.source else { return "This conversation has no file of its own to delete." }
        // As real paths, the folder a file is in resolved rather than the
        // file, which may be gone: a link on the way would otherwise make
        // an agent's own file look like one from elsewhere, or the reverse.
        let home = URL(fileURLWithPath: home, isDirectory: true).resolvingSymlinksInPath().path
        let file = URL(fileURLWithPath: source).standardizedFileURL
        let path = file.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(file.lastPathComponent).path
        // Only what an agent keeps its conversations in, whatever a client sends.
        let target: String
        switch conversation.agent {
        case "claude":
            guard path.hasPrefix(home + "/.claude/projects/"), path.hasSuffix(".jsonl") else { return "That is not a conversation of Claude Code." }
            target = path
        case "codex":
            guard path.hasPrefix(home + "/.codex/sessions/"), path.hasSuffix(".jsonl") else { return "That is not a conversation of Codex." }
            target = path
        case "copilot":
            // Its folder: the events, and what names the conversation.
            guard path.hasPrefix(home + "/.copilot/session-state/"), path.hasSuffix("/events.jsonl") else { return "That is not a conversation of Copilot." }
            target = (path as NSString).deletingLastPathComponent
        case "agy":
            return "Antigravity keeps its list of conversations in a file of its own, which AgentTerm does not rewrite: this one can be hidden here, and deleted in Antigravity."
        default:
            return "Conversations of this agent cannot be deleted here."
        }
        guard FileManager.default.fileExists(atPath: target) else { return "Its file is gone already." }
        do {
            try FileBrowser.trash(target)
            return nil
        } catch {
            return "It could not be moved to the Trash: \(error.localizedDescription)"
        }
    }
}
#endif
