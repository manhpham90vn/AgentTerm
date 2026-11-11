#if os(macOS)
import AgenttyProtocol
import Foundation

/// Reads what a conversation has used from the file its agent keeps of it.
///
/// Nothing is asked of the agents' services, and no credentials are read:
/// this is only what each agent wrote down itself. That differs per agent.
/// Codex records its rate limits; Claude Code and Antigravity do not.
public enum AgentUsage {
    /// The newest records are at the end, and the files grow to many megabytes.
    private static let tailBytes = 768 * 1024

    public static func read(agent: String, file: String) -> SessionUsage? {
        parse(agent: agent, data: AgentHistory.read(URL(fileURLWithPath: file), tail: tailBytes))
    }

    /// - Parameter data: the end of the conversation's file. A first line cut
    ///   off by the read window does not parse and is skipped.
    public static func parse(agent: String, data: Data) -> SessionUsage? {
        let usage: SessionUsage
        switch agent {
        case "claude": usage = claude(data)
        case "codex": usage = codex(data)
        case "copilot": usage = copilot(data)
        case "agy": usage = antigravity(data)
        default: return nil
        }
        return usage.isEmpty ? nil : usage
    }

    /// The model an agent starts with when nothing says otherwise: what its
    /// own settings name. Shown until a session records the model it uses,
    /// and for Antigravity, which records none per conversation.
    public static func configuredModel(agent: String, home: String = NSHomeDirectory(), environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        switch agent {
        case "codex":
            let directory = environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? home + "/.codex"
            guard let text = try? String(contentsOfFile: directory + "/config.toml", encoding: .utf8) else { return nil }
            // The top-level `model = "..."`, before the first table.
            for line in text.split(whereSeparator: \.isNewline) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("[") { break }
                guard trimmed.hasPrefix("model"), let equals = trimmed.firstIndex(of: "=") else { continue }
                guard trimmed[..<equals].trimmingCharacters(in: .whitespaces) == "model" else { continue }
                let value = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
                let name = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                return name.isEmpty ? nil : name
            }
            return nil
        case "agy":
            guard let data = FileManager.default.contents(atPath: home + "/.gemini/antigravity-cli/settings.json"),
                  let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let model = settings["model"] as? String, !model.isEmpty
            else { return nil }
            return model
        default:
            return nil
        }
    }

    /// The file Copilot CLI keeps of a session that began in `cwd` at or
    /// after `start`. Copilot writes it from the first moment, before there
    /// is a conversation to find the session by, and names its model in it.
    public static func copilotSessionFile(cwd: String, startedAfter start: Date, home: String = NSHomeDirectory()) -> String? {
        let root = URL(fileURLWithPath: home).appendingPathComponent(".copilot/session-state")
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey])) ?? []
        let wanted = URL(fileURLWithPath: cwd).standardizedFileURL.path
        return folders.compactMap { folder -> (String, Date)? in
            guard let created = (try? folder.resourceValues(forKeys: [.creationDateKey]))?.creationDate, created >= start.addingTimeInterval(-5),
                  let workspace = try? String(contentsOf: folder.appendingPathComponent("workspace.yaml"), encoding: .utf8)
            else { return nil }
            let recorded = workspace.split(whereSeparator: \.isNewline).first { $0.hasPrefix("cwd:") }
                .map { $0.dropFirst(4).trimmingCharacters(in: CharacterSet(charactersIn: " \"'")) }
            guard let recorded, URL(fileURLWithPath: recorded).standardizedFileURL.path == wanted else { return nil }
            return (folder.appendingPathComponent("events.jsonl").path, created)
        }
        // The first one to begin after the session did is the session's own.
        .min { $0.1 < $1.1 }?.0
    }

    /// The JSON lines that mention `needle`, newest first.
    private static func newest(_ data: Data, containing needle: String) -> LazySequence<[[String: Any]]> {
        let needle = Data(needle.utf8)
        // Parsed lazily from the end: usually the first match is all that is needed.
        return data.split(separator: 0x0a).reversed().lazy
            .filter { $0.range(of: needle) != nil }
            .compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            .prefix(200).map { $0 }.lazy
    }

    private static func int(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }

    // MARK: Claude Code

    /// Each reply carries the tokens of its request. What was sent, cached
    /// or not, is what the conversation takes up in the context.
    private static func claude(_ data: Data) -> SessionUsage {
        for line in newest(data, containing: "\"usage\"") {
            // Sub-agents have a context of their own.
            guard line["isSidechain"] as? Bool != true,
                  let message = line["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any]
            else { continue }
            let model = message["model"] as? String
            if model == "<synthetic>" { continue }
            let sent = (int(usage["input_tokens"]) ?? 0) + (int(usage["cache_read_input_tokens"]) ?? 0) + (int(usage["cache_creation_input_tokens"]) ?? 0)
            guard sent > 0 else { continue }
            return SessionUsage(model: model, contextTokens: sent)
        }
        return SessionUsage()
    }

    // MARK: Codex

    private static func codex(_ data: Data) -> SessionUsage {
        var usage = SessionUsage()
        for line in newest(data, containing: "\"token_count\"") {
            guard let payload = line["payload"] as? [String: Any], payload["type"] as? String == "token_count" else { continue }
            if usage.contextTokens == nil, let info = payload["info"] as? [String: Any] {
                usage.contextTokens = int((info["last_token_usage"] as? [String: Any])?["total_tokens"])
                usage.contextWindow = int(info["model_context_window"])
            }
            if usage.limits.isEmpty, let limits = payload["rate_limits"] as? [String: Any] {
                usage.limits = ["primary", "secondary"].compactMap { key -> UsageLimit? in
                    guard let limit = limits[key] as? [String: Any],
                          let used = (limit["used_percent"] as? NSNumber)?.doubleValue,
                          let minutes = int(limit["window_minutes"])
                    else { return nil }
                    let resets = (limit["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
                    return UsageLimit(windowMinutes: minutes, usedPercent: used, resetsAt: resets)
                }
            }
            if usage.contextTokens != nil, !usage.limits.isEmpty { break }
        }
        for line in newest(data, containing: "\"turn_context\"") {
            if let model = (line["payload"] as? [String: Any])?["model"] as? String {
                usage.model = model
                break
            }
        }
        if usage.contextWindow == nil {
            // Before the first reply the session only says how large its window is.
            for line in newest(data, containing: "\"session_meta\"") {
                guard let window = int((line["payload"] as? [String: Any])?["context_window"]), window > 0 else { continue }
                usage.contextWindow = window
                if usage.contextTokens == nil { usage.contextTokens = 0 }
                break
            }
        }
        return usage
    }

    // MARK: Copilot CLI

    private static func copilot(_ data: Data) -> SessionUsage {
        var usage = SessionUsage()
        for line in newest(data, containing: "session.usage_record") {
            guard line["type"] as? String == "session.usage_record",
                  let record = (line["data"] as? [String: Any])?["usage"] as? [String: Any]
            else { continue }
            usage.model = record["modelDisplayName"] as? String ?? record["model"] as? String
            usage.contextTokens = int(record["inputTokens"])
            usage.contextWindow = int(record["maxPromptTokens"])
            break
        }
        if usage.model == nil {
            for line in newest(data, containing: "session.model_change") {
                if let model = (line["data"] as? [String: Any])?["newModel"] as? String {
                    usage.model = model
                    break
                }
            }
        }
        for line in newest(data, containing: "totalPremiumRequests") {
            guard let data = line["data"] as? [String: Any], let spent = (data["totalPremiumRequests"] as? NSNumber)?.doubleValue else { continue }
            usage.premiumRequests = spent
            break
        }
        return usage
    }

    // MARK: Antigravity

    private static func antigravity(_ data: Data) -> SessionUsage {
        for line in newest(data, containing: "\"input_tokens\"") {
            guard let sent = int(line["input_tokens"]), sent > 0 else { continue }
            return SessionUsage(contextTokens: sent + (int(line["cache_read_tokens"]) ?? 0))
        }
        return SessionUsage()
    }
}
#endif
