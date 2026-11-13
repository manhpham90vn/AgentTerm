#if os(macOS)
import AgentTermProtocol
import Foundation

/// How the host learns what the agent in a session is doing (#3): from the
/// agent itself, through its hooks, never from what is on the screen.
///
/// Each agent is given hooks for one session only, without a change to the
/// user's own configuration of it, in the way that agent takes them:
///
/// | Agent | Given by |
/// |---|---|
/// | Claude Code | `--settings`, with the status line |
/// | Codex | `-c hooks.<Event>=...` |
/// | Copilot CLI | `--plugin-dir`, a plugin of the host's holding `hooks.json` |
/// | Antigravity | `--add-dir`, a folder of the host's holding `.agents/hooks.json`, trusted for the session by `--settings` |
///
/// Every hook runs `agenttermd hook <agent> <event>`, which saves what it is
/// told in the file `AGENTTERM_EVENTS` names, set in the session's
/// environment. The command is the same for every session: Codex trusts a
/// hook by its command, and asks again when that changes.
public enum AgentHooks {
    /// The variable that names the file a session's hooks write to.
    public static let eventsVariable = "AGENTTERM_EVENTS"

    static let claudeEvents = ["UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse", "Notification", "Stop"]
    static let codexEvents = ["UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse", "Stop", "Interrupt"]
    static let copilotEvents = ["userPromptSubmitted", "preToolUse", "permissionRequest", "postToolUse", "postToolUseFailure", "agentStop"]
    static let antigravityEvents = ["PreInvocation", "PreToolUse", "PostToolUse", "Stop"]

    /// What a hook runs.
    static func command(tool: String, agent: String, event: String) -> String {
        Handoff.shellQuote(tool) + " hook " + agent + " " + event
    }

    // MARK: Given to each agent

    /// What an agent's command line is given: its hooks, and for Claude
    /// Code its status line too (`usageFile`). Copilot CLI and Antigravity
    /// need a `directory` to keep what they are given in; without one,
    /// they get nothing.
    /// `useShells`: each agent is told to run its commands in shells the
    /// user sees (`AgentShellsInstructions`): Claude Code in its system
    /// prompt, Antigravity in a rule of the folder it is given, Copilot CLI
    /// in instructions it is told of (`instructionsEnvironment`), Codex by
    /// the MCP server's instructions, which it reads.
    public static func launchArguments(
        agent: String, tool: String, usageFile: String?, directory: URL?, home: String, trust: [String] = [], useShells: Bool = false
    ) throws -> String {
        switch agent {
        case "claude":
            var settings: [String: Any] = ["hooks": claudeHooks(tool: tool)]
            if let usageFile { settings["statusLine"] = StatusLineRelay.statusLine(tool: tool, file: usageFile) }
            let json = try JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys])
            return " --settings " + Handoff.shellQuote(String(decoding: json, as: UTF8.self))
                + (useShells ? " --append-system-prompt " + Handoff.shellQuote(AgentShellsInstructions.useShells) : "")
        case "codex":
            return codexArguments(tool: tool)
        case "copilot":
            guard let directory else { throw CocoaError(.fileNoSuchFile) }
            return try copilotArguments(tool: tool, directory: directory)
        case "agy":
            guard let directory else { throw CocoaError(.fileNoSuchFile) }
            return try antigravityArguments(tool: tool, directory: directory, home: home, trust: trust, useShells: useShells)
        default:
            throw CocoaError(.featureUnsupported)
        }
    }

    /// Claude Code's hooks, for the settings it is started with.
    static func claudeHooks(tool: String) -> [String: Any] {
        var hooks: [String: Any] = [:]
        for event in claudeEvents {
            hooks[event] = [["hooks": [["type": "command", "command": command(tool: tool, agent: "claude", event: event)]]]]
        }
        return hooks
    }

    /// What Codex is started with: one `-c` for each event.
    static func codexArguments(tool: String) -> String {
        codexEvents.map { event in
            let line = command(tool: tool, agent: "codex", event: event)
            let value = "hooks.\(event)=[{hooks=[{type=\"command\",command=\(tomlString(line))}]}]"
            return " -c " + Handoff.shellQuote(value)
        }.joined()
    }

    /// A TOML basic string.
    static func tomlString(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Writes the plugin Copilot CLI is given, and returns what it is
    /// started with.
    static func copilotArguments(tool: String, directory: URL) throws -> String {
        let plugin = directory.appendingPathComponent("copilot", isDirectory: true)
        try FileManager.default.createDirectory(at: plugin, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let manifest: [String: Any] = ["name": "agentterm", "description": "Tells AgentTerm what the agent is doing", "version": "1.0.0"]
        var hooks: [String: Any] = [:]
        for event in copilotEvents {
            hooks[event] = [["type": "command", "bash": command(tool: tool, agent: "copilot", event: event), "timeoutSec": 10]]
        }
        try write(manifest, to: plugin.appendingPathComponent("plugin.json"))
        try write(["version": 1, "hooks": hooks], to: plugin.appendingPathComponent("hooks.json"))
        return " --plugin-dir " + Handoff.shellQuote(plugin.path)
    }

    /// Writes the folder Antigravity is given, and returns what it is
    /// started with. The folder is trusted for the session, next to the
    /// folders the user trusts already, which are read from their settings
    /// and not changed: `--settings` is for this session only.
    /// `trust`: folders trusted for the session too, a schedule's (#11).
    static func antigravityArguments(tool: String, directory: URL, home: String, trust: [String] = [], useShells: Bool = false) throws -> String {
        let folder = directory.appendingPathComponent("antigravity", isDirectory: true)
        let agents = folder.appendingPathComponent(".agents", isDirectory: true)
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Antigravity reads the rules of a folder it is given, as it does
        // a project's: the only way to tell it something more (MCP-13).
        let rule = agents.appendingPathComponent("rules/agentterm.md")
        if useShells {
            try FileManager.default.createDirectory(at: rule.deletingLastPathComponent(), withIntermediateDirectories: true)
            try writeText("---\ntrigger: always_on\n---\n" + AgentShellsInstructions.useShells + "\n", to: rule)
        } else {
            try? FileManager.default.removeItem(at: rule)
        }
        var events: [String: Any] = [:]
        for event in antigravityEvents {
            let hook: [String: Any] = ["type": "command", "command": command(tool: tool, agent: "agy", event: event), "timeout": 10]
            events[event] = event.hasSuffix("ToolUse") ? [["matcher": "*", "hooks": [hook]]] : [hook]
        }
        try write(["agentterm": events], to: agents.appendingPathComponent("hooks.json"))
        let settingsFile = URL(fileURLWithPath: home).appendingPathComponent(".gemini/antigravity-cli/settings.json")
        let own = (FileManager.default.contents(atPath: settingsFile.path)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        var trusted = own?["trustedWorkspaces"] as? [String] ?? []
        for path in [folder.path] + trust where !trusted.contains(path) { trusted.append(path) }
        let settings = try JSONSerialization.data(withJSONObject: ["trustedWorkspaces": trusted], options: [.sortedKeys])
        return " --add-dir " + Handoff.shellQuote(folder.path) + " --settings " + Handoff.shellQuote(String(decoding: settings, as: UTF8.self))
    }

    /// What an agent's environment is given besides: for Copilot CLI, the
    /// folder of instructions it is told to run its commands in shells the
    /// user sees, next to any its own environment names (MCP-13).
    public static func instructionsEnvironment(agent: String, directory: URL?, useShells: Bool, current: [String: String]) throws -> [String: String] {
        guard agent == "copilot", useShells, let directory else { return [:] }
        let folder = directory.appendingPathComponent("copilot-instructions", isDirectory: true)
        let file = folder.appendingPathComponent("instructions/agentterm.instructions.md")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try writeText("---\napplyTo: \"**\"\n---\n" + AgentShellsInstructions.useShells + "\n", to: file)
        let name = "COPILOT_CUSTOM_INSTRUCTIONS_DIRS"
        let theirs = current[name].flatMap { $0.isEmpty ? nil : $0 }
        return [name: [theirs, folder.path].compactMap { $0 }.joined(separator: ",")]
    }

    private static func writeText(_ text: String, to file: URL) throws {
        if FileManager.default.contents(atPath: file.path) == Data(text.utf8) { return }
        try Data(text.utf8).write(to: file, options: .atomic)
    }

    private static func write(_ object: [String: Any], to file: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        if FileManager.default.contents(atPath: file.path) == data { return }
        try data.write(to: file, options: .atomic)
    }

    // MARK: What a hook does

    /// Saves what a hook was told, for the host: the latest event only,
    /// since the state follows from it.
    public static func save(_ input: Data, agent: String, event: String, to file: String, now: Date = Date()) {
        let told = (try? JSONSerialization.jsonObject(with: input)) ?? [:]
        let record: [String: Any] = ["agent": agent, "event": event, "at": now.timeIntervalSince1970, "input": told]
        guard let data = try? JSONSerialization.data(withJSONObject: record) else { return }
        try? data.write(to: URL(fileURLWithPath: file), options: .atomic)
    }

    /// What a hook prints back to its agent. Antigravity asks every
    /// `PreToolUse` hook for a decision; "allow" leaves it to its own rules
    /// (it asks the user as it would without the hook). The others need
    /// nothing.
    public static func reply(agent: String, event: String) -> String? {
        guard agent == "agy" else { return nil }
        return event == "PreToolUse" ? #"{"decision":"allow"}"# : "{}"
    }

    // MARK: What the host makes of it

    public enum Change: Equatable {
        /// The session's state becomes this (nil: not known).
        case set(AgentState?)
        /// The event says nothing new.
        case keep
    }

    /// The state an event puts a session in, from what each agent was seen
    /// to tell its hooks.
    public static func change(agent: String, event: String, input: [String: Any], now: Date = Date()) -> Change {
        switch agent {
        case "claude": return claude(event, input, now)
        case "codex": return codex(event, input, now)
        case "copilot": return copilot(event, input, now)
        case "agy": return antigravity(event, input, now)
        default: return .keep
        }
    }

    private static func claude(_ event: String, _ input: [String: Any], _ now: Date) -> Change {
        let tool = input["tool_name"] as? String
        let toolInput = input["tool_input"] as? [String: Any] ?? [:]
        switch event {
        case "UserPromptSubmit", "PostToolUse": return .set(.working(since: now))
        case "PreToolUse", "PermissionRequest":
            if tool == "AskUserQuestion", let question = claudeQuestion(toolInput) { return .set(.waitingForAnswer(question)) }
            if event == "PreToolUse" { return .set(.working(since: now)) }
            return .set(.waitingForPermission(AgentQuestion(text: describe(tool: tool, input: toolInput))))
        case "Notification":
            guard input["notification_type"] as? String == "elicitation_dialog" else { return .keep }
            return .set(.waitingForAnswer(AgentQuestion(text: input["message"] as? String ?? "")))
        case "Stop": return .set(.done(said: input["last_assistant_message"] as? String))
        default: return .keep
        }
    }

    private static func claudeQuestion(_ input: [String: Any]) -> AgentQuestion? {
        guard let first = (input["questions"] as? [[String: Any]])?.first, let text = first["question"] as? String else { return nil }
        let choices = (first["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String }
        return AgentQuestion(text: text, choices: choices)
    }

    private static func codex(_ event: String, _ input: [String: Any], _ now: Date) -> Change {
        switch event {
        case "UserPromptSubmit", "PreToolUse", "PostToolUse": return .set(.working(since: now))
        case "PermissionRequest":
            let toolInput = input["tool_input"] as? [String: Any] ?? [:]
            let text = (toolInput["description"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? describe(tool: input["tool_name"] as? String, input: toolInput)
            return .set(.waitingForPermission(AgentQuestion(text: text)))
        case "Stop": return .set(.done(said: input["last_assistant_message"] as? String))
        // The user stopped the turn: what comes next is not known.
        case "Interrupt": return .set(nil)
        default: return .keep
        }
    }

    private static func copilot(_ event: String, _ input: [String: Any], _ now: Date) -> Change {
        let tool = input["toolName"] as? String
        switch event {
        case "userPromptSubmitted", "postToolUse", "postToolUseFailure": return .set(.working(since: now))
        case "preToolUse":
            if tool == "ask_user", let args = input["toolArgs"] as? [String: Any] {
                let properties = (args["requestedSchema"] as? [String: Any])?["properties"] as? [String: Any] ?? [:]
                let choices = properties.values.compactMap { ($0 as? [String: Any])?["enum"] as? [String] }.first ?? []
                return .set(.waitingForAnswer(AgentQuestion(text: args["message"] as? String ?? "", choices: choices)))
            }
            return .set(.working(since: now))
        case "permissionRequest":
            let toolInput = input["toolInput"] as? [String: Any] ?? [:]
            return .set(.waitingForPermission(AgentQuestion(text: describe(tool: tool, input: toolInput))))
        case "agentStop": return .set(.done(said: nil))
        default: return .keep
        }
    }

    /// Antigravity says nothing when it waits for permission: its question
    /// comes after `PreToolUse`, with nothing in between. So while a tool
    /// runs, its state is not known: running and waiting look the same.
    private static func antigravity(_ event: String, _ input: [String: Any], _ now: Date) -> Change {
        switch event {
        case "PreInvocation", "PostToolUse": return .set(.working(since: now))
        case "PreToolUse":
            let call = input["toolCall"] as? [String: Any] ?? [:]
            if call["name"] as? String == "ask_question",
                let first = ((call["args"] as? [String: Any])?["questions"] as? [[String: Any]])?.first,
                let text = first["question"] as? String
            {
                return .set(.waitingForAnswer(AgentQuestion(text: text, choices: first["options"] as? [String] ?? [])))
            }
            return .set(nil)
        case "Stop":
            // Background work of its own may still run.
            guard input["fullyIdle"] as? Bool != false else { return .keep }
            return .set(.done(said: nil))
        default: return .keep
        }
    }

    /// What a tool wants to do, in a line: the command it runs, the file it
    /// changes, else its name.
    static func describe(tool: String?, input: [String: Any]) -> String {
        for key in ["command", "file_path", "path", "url"] {
            if let value = input[key] as? String, !value.isEmpty { return value }
        }
        return tool ?? "a tool"
    }

    // MARK: Notes

    /// What is said of a session whose agent's state cannot all be known,
    /// before it said anything (`beforeAnyEvent`) and after.
    public static func note(agent: String?, beforeAnyEvent: Bool) -> String? {
        switch agent {
        case "codex" where beforeAnyEvent:
            return "Codex says what it is doing once AgentTerm's hooks are trusted: when Codex asks, choose “Trust all and continue”, or review them with /hooks."
        case "agy":
            return "Antigravity does not say when it waits for permission: while it runs a tool, its state is not shown."
        default:
            return nil
        }
    }

    /// Input that may have stopped a turn: Escape alone, or Control C.
    /// After it the state is not known until the agent says more.
    public static func mayStopATurn(_ input: Data) -> Bool {
        input == Data([0x1b]) || input.contains(0x03)
    }
}
#endif
