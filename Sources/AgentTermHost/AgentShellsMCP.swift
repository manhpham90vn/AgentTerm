#if os(macOS)
import AgentTermProtocol
import Foundation

/// The MCP server an agent is given (#10): `agenttermd mcp`, which speaks MCP
/// as JSON-RPC, one message to a line, on standard input and output, and
/// asks the running host for what an agent's tools do.
///
/// It offers its tools only inside a session of an agent AgentTerm started,
/// whose environment names the host's port and the session's key
/// (`HostServer.agentShellsVariable`). Elsewhere, in a terminal of another
/// app, it offers none.
public final class AgentShellsMCP {
    /// Asks the host, and waits for its answer.
    public typealias Ask = (AgentShellRequest) -> AgentShellResult

    private let ask: Ask?
    private let version: String
    /// How long `wait` looks between two reads of the screen.
    var pollInterval: TimeInterval = 0.2

    /// - Parameter ask: Nil outside a session of AgentTerm: no tools then.
    public init(ask: Ask?, version: String) {
        self.ask = ask
        self.version = version
    }

    /// Answers one line, a JSON-RPC message. Nil for a notification, which
    /// is not answered.
    public func handle(_ line: String) -> String? {
        guard let message = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else {
            return Self.encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
        }
        guard let id = message["id"], let method = message["method"] as? String else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]
        func result(_ value: Any) -> String? { Self.encode(["jsonrpc": "2.0", "id": id, "result": value]) }
        switch method {
        case "initialize":
            return result([
                "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": "agentterm", "version": version],
                "instructions": ask == nil
                    ? "Not in a session of AgentTerm: no tools."
                    : "Open shells the user can see in AgentTerm, next to your session, and work in them. Use them for what keeps running or what the user should watch: an SSH session, a dev server, a REPL.",
            ])
        case "ping":
            return result([:])
        case "tools/list":
            return result(["tools": ask == nil ? [] : Self.tools])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            let (text, failed) = call(name, arguments)
            return result(["content": [["type": "text", "text": text]], "isError": failed])
        default:
            return Self.encode(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found: \(method)"]])
        }
    }

    // MARK: The tools

    static let tools: [[String: Any]] = [
        tool(
            "open_shell",
            "Opens a shell in a new AgentTerm tab, in your folder, that the user sees and can type in. With a command (`ssh build-server`, `npm run dev`) it runs that; without, a login shell. Starting an agent is refused.",
            ["command": string("The command to run; none for a plain login shell"), "title": string("The tab's name")], required: []),
        tool("list_shells", "The shells you opened that still run, with their numbers.", [:], required: []),
        tool(
            "read_screen", "The shell's screen as text, with lines above it when asked.",
            ["session": integer("The shell's number"), "lines_above": integer("How many lines above the screen to include; 0 by default")],
            required: ["session"]),
        tool(
            "send_input",
            "Types into the shell: text, then keys by name, as a person would. Keys: Return, Tab, Escape, Backspace, Up, Down, Left, Right, Home, End, Page Up, Page Down, Delete, Control A to Control Z.",
            ["session": integer("The shell's number"), "text": string("Text to type"), "keys": ["type": "array", "items": ["type": "string"], "description": "Keys to press after the text"]],
            required: ["session"]),
        tool(
            "wait",
            "Waits until the shell's screen has been still for a moment, or a text appears on it, or the time is up, and returns the screen.",
            [
                "session": integer("The shell's number"), "until_text": string("Wait until this text is on the screen"),
                "quiet_seconds": number("How long the screen must stay the same; 1 by default"), "timeout_seconds": number("At most this long; 30 by default"),
            ],
            required: ["session"]),
        tool("close_shell", "Ends a shell you opened.", ["session": integer("The shell's number")], required: ["session"]),
    ]

    private static func tool(_ name: String, _ description: String, _ properties: [String: Any], required: [String]) -> [String: Any] {
        ["name": name, "description": description, "inputSchema": ["type": "object", "properties": properties, "required": required]]
    }
    private static func string(_ description: String) -> [String: Any] { ["type": "string", "description": description] }
    private static func integer(_ description: String) -> [String: Any] { ["type": "integer", "description": description] }
    private static func number(_ description: String) -> [String: Any] { ["type": "number", "description": description] }

    /// What a tool returns, and whether it failed.
    private func call(_ name: String, _ arguments: [String: Any]) -> (String, Bool) {
        guard let ask else { return ("Not in a session of AgentTerm: there are no shells to open.", true) }
        let session = (arguments["session"] as? NSNumber).map { SessionID(truncatingIfNeeded: $0.intValue) }
        func needsSession() -> (String, Bool) { ("Which shell: give its number as `session`.", true) }
        let result: AgentShellResult
        switch name {
        case "open_shell":
            result = ask(.open(command: (arguments["command"] as? String).flatMap { $0.isEmpty ? nil : $0 }, title: arguments["title"] as? String))
        case "list_shells":
            result = ask(.list)
        case "read_screen":
            guard let session else { return needsSession() }
            result = ask(.read(session: session, linesAbove: (arguments["lines_above"] as? NSNumber)?.intValue ?? 0))
        case "send_input":
            guard let session else { return needsSession() }
            result = ask(.send(session: session, text: arguments["text"] as? String, keys: arguments["keys"] as? [String] ?? []))
        case "wait":
            guard let session else { return needsSession() }
            return wait(
                session: session, until: arguments["until_text"] as? String,
                quiet: (arguments["quiet_seconds"] as? NSNumber)?.doubleValue ?? 1, timeout: (arguments["timeout_seconds"] as? NSNumber)?.doubleValue ?? 30)
        case "close_shell":
            guard let session else { return needsSession() }
            result = ask(.close(session: session))
        default:
            return ("There is no tool called \(name).", true)
        }
        return Self.words(result)
    }

    /// Reads the screen until it says `until`, or has stayed the same for
    /// `quiet` seconds, or `timeout` seconds have passed.
    private func wait(session: SessionID, until: String?, quiet: TimeInterval, timeout: TimeInterval) -> (String, Bool) {
        guard let ask else { return ("", true) }
        let started = Date()
        var last: String?
        var stillSince = Date()
        while true {
            guard case .screen(let screen) = ask(.read(session: session, linesAbove: 0)) else {
                return Self.words(ask(.read(session: session, linesAbove: 0)))
            }
            if let until, !until.isEmpty, screen.contains(until) { return ("“\(until)” is on the screen:\n\n\(screen)", false) }
            if screen != last {
                last = screen
                stillSince = Date()
            } else if until == nil || until?.isEmpty == true, Date().timeIntervalSince(stillSince) >= quiet {
                return ("The screen has been still for \(Self.seconds(quiet)):\n\n\(screen)", false)
            }
            if Date().timeIntervalSince(started) >= timeout {
                return ("Still waiting after \(Self.seconds(timeout)); the screen now:\n\n\(screen)", false)
            }
            Thread.sleep(forTimeInterval: pollInterval)
        }
    }

    private static func seconds(_ value: TimeInterval) -> String {
        value == value.rounded() ? "\(Int(value)) s" : String(format: "%.1f s", value)
    }

    /// A result in words for the agent.
    static func words(_ result: AgentShellResult) -> (String, Bool) {
        switch result {
        case .opened(let shell): return ("Opened shell \(shell.id), “\(shell.title)”, in \(shell.cwd).", false)
        case .shells(let list):
            if list.isEmpty { return ("You have no shells open.", false) }
            return (list.map { "\($0.id): \($0.title)" }.joined(separator: "\n"), false)
        case .screen(let text): return (text, false)
        case .done: return ("Done.", false)
        case .refused(let why): return (why, true)
        }
    }

    private static func encode(_ object: [String: Any]) -> String? {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) }
    }
}
#endif
