#if os(macOS)
import AgentTermProtocol
import Foundation

/// The MCP server an agent is given (#10): `agenttermd mcp`, which speaks MCP
/// as JSON-RPC, one message to a line, on standard input and output, and
/// asks the running host for what an agent's tools do.
///
/// It offers its tools only inside a session of an agent its own build of
/// AgentTerm started, whose environment names the host's port, the
/// session's key and the build (`HostServer.agentShellsVariable`).
/// Elsewhere, in a terminal of another app or in a session of the other
/// build (#57), it offers none.
public final class AgentShellsMCP {
    /// Asks the host, and waits for its answer.
    public typealias Ask = (AgentShellRequest) -> AgentShellResult

    /// What a session's variable tells its agent's server: the host to ask,
    /// as which session, and whether the agent is to run its commands in
    /// the shells. Written as `<port> <key> <channel> [use]`.
    public struct Session: Equatable {
        public var port: UInt16
        public var key: String
        public var useShells: Bool

        public init(port: UInt16, key: String, useShells: Bool) {
            self.port = port
            self.key = key
            self.useShells = useShells
        }

        /// The variable's value, for a session of the build `channel`.
        public func variable(channel: AppChannel = .current) -> String {
            "\(port) \(key) \(channel.rawValue)" + (useShells ? " use" : "")
        }

        /// What the variable says, or nil when it names no session, or one
        /// of another build than `channel`: that build's host has a token
        /// of its own, and its own server is the one to answer there. A
        /// variable that names no build is from before the builds had a
        /// server each, when only the released one was meant to.
        public init?(variable: String?, channel: AppChannel = .current) {
            let words = variable?.split(separator: " ").map(String.init) ?? []
            guard words.count >= 2, let port = UInt16(words[0]) else { return nil }
            let rest = words.dropFirst(2)
            let named = rest.compactMap(AppChannel.init(rawValue:)).first ?? .release
            guard named == channel else { return nil }
            self.init(port: port, key: words[1], useShells: rest.contains("use"))
        }
    }

    private let ask: Ask?
    private let name: String
    private let version: String
    /// The agent is to run its commands in these shells.
    private let useShells: Bool
    /// How long `wait` looks between two reads of the screen.
    var pollInterval: TimeInterval = 0.2

    /// Tool calls are answered side by side (#64): one that takes long, a
    /// `wait`, does not hold up the others of the same agent.
    private let calls = DispatchQueue(label: "agentterm.mcp.calls", attributes: .concurrent)
    private let lock = NSLock()
    /// The calls going on, by their request's id, and those of them that
    /// were cancelled: a cancelled one ends, and is not answered.
    private var running: Set<String> = []
    private var cancelled: Set<String> = []

    /// A request's id as the key it is kept under: a number or a string.
    private static func key(_ id: Any) -> String { id is String ? "s:\(id)" : "n:\(id)" }

    private func isCancelled(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled.contains(key)
    }

    /// - Parameters:
    ///   - ask: Nil outside a session of this build of AgentTerm: no tools then.
    ///   - name: The server's name in the agents' configuration.
    public init(ask: Ask?, name: String = AppChannel.current.mcpServerName, version: String, useShells: Bool = false) {
        self.ask = ask
        self.name = name
        self.version = version
        self.useShells = useShells
    }

    /// Takes one line, a JSON-RPC message, and hands its answer to `reply`
    /// (#64): at once for most, and for a tool call when the tool is done,
    /// which for a `wait` may be long after later lines were answered. Each
    /// request is answered once, by its id. A notification is not
    /// answered, and neither is a call that was cancelled meanwhile
    /// (`notifications/cancelled`), which ends there.
    public func handle(_ line: String, reply: @escaping (String) -> Void) {
        guard let message = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else {
            if let answer = handle(line) { reply(answer) }
            return
        }
        let params = message["params"] as? [String: Any] ?? [:]
        if message["method"] as? String == "notifications/cancelled", let id = params["requestId"] {
            lock.lock()
            if running.contains(Self.key(id)) { cancelled.insert(Self.key(id)) }
            lock.unlock()
            return
        }
        guard message["method"] as? String == "tools/call", let id = message["id"] else {
            if let answer = handle(line) { reply(answer) }
            return
        }
        let key = Self.key(id)
        lock.lock()
        running.insert(key)
        lock.unlock()
        calls.async { [self] in
            let answer = answer(message, isCancelled: { self.isCancelled(key) })
            lock.lock()
            running.remove(key)
            let dropped = cancelled.remove(key) != nil
            lock.unlock()
            if !dropped, let answer { reply(answer) }
        }
    }

    /// Answers one line, a JSON-RPC message, and returns when it is
    /// answered. Nil for a notification, which is not answered.
    public func handle(_ line: String) -> String? {
        guard let message = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else {
            return Self.encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
        }
        return answer(message, isCancelled: { false })
    }

    private func answer(_ message: [String: Any], isCancelled: @escaping () -> Bool) -> String? {
        guard let id = message["id"], let method = message["method"] as? String else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]
        func result(_ value: Any) -> String? { Self.encode(["jsonrpc": "2.0", "id": id, "result": value]) }
        switch method {
        case "initialize":
            return result([
                "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": name, "version": version],
                "instructions": ask == nil
                    ? "Not in a session of AgentTerm: no tools."
                    : useShells
                        ? AgentShellsInstructions.useShells(server: name)
                        : "Open shells the user can see in AgentTerm, next to your session, and work in them. Use them for what keeps running or what the user should watch: an SSH session, a dev server, a REPL. Only the agent that opened a shell may type into it: list_shells says which are yours, and another agent's you may read but not type into."
                    ,
            ])
        case "ping":
            return result([:])
        case "tools/list":
            return result(["tools": ask == nil ? [] : Self.tools])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            let (text, failed) = call(name, arguments, isCancelled: isCancelled)
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
        tool(
            "list_shells",
            "The shells open in AgentTerm that agents opened, with their numbers and folders, and whose each is: you may type into yours, and only read another agent's.",
            [:], required: []),
        tool(
            "read_screen", "The screen as text of a shell any agent opened, with lines above it when asked.",
            ["session": integer("The shell's number"), "lines_above": integer("How many lines above the screen to include; 0 by default")],
            required: ["session"]),
        tool(
            "send_input",
            "Types into a shell you opened: text, then keys by name, as a person would. Another agent's shell is refused. Keys: Return, Tab, Escape, Backspace, Up, Down, Left, Right, Home, End, Page Up, Page Down, Delete, Control A to Control Z.",
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
        tool("close_shell", "Ends a shell you opened, when you no longer need it. Another agent's shell is refused.", ["session": integer("The shell's number")], required: ["session"]),
    ]

    private static func tool(_ name: String, _ description: String, _ properties: [String: Any], required: [String]) -> [String: Any] {
        ["name": name, "description": description, "inputSchema": ["type": "object", "properties": properties, "required": required]]
    }
    private static func string(_ description: String) -> [String: Any] { ["type": "string", "description": description] }
    private static func integer(_ description: String) -> [String: Any] { ["type": "integer", "description": description] }
    private static func number(_ description: String) -> [String: Any] { ["type": "number", "description": description] }

    /// What a tool returns, and whether it failed.
    private func call(_ name: String, _ arguments: [String: Any], isCancelled: () -> Bool) -> (String, Bool) {
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
                quiet: (arguments["quiet_seconds"] as? NSNumber)?.doubleValue ?? 1, timeout: (arguments["timeout_seconds"] as? NSNumber)?.doubleValue ?? 30,
                isCancelled: isCancelled)
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
    private func wait(session: SessionID, until: String?, quiet: TimeInterval, timeout: TimeInterval, isCancelled: () -> Bool) -> (String, Bool) {
        guard let ask else { return ("", true) }
        let started = Date()
        var last: String?
        var stillSince = Date()
        while true {
            // Nobody listens any more: it ends here, and is not answered.
            if isCancelled() { return ("Cancelled.", true) }
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
        case .shells(let list, let own):
            if list.isEmpty { return ("No agent has a shell open.", false) }
            let lines = list.map { "\($0.id): \($0.title), in \($0.cwd) (\(own.contains($0.id) ? "yours" : "another agent's: read only"))" }
            return (lines.joined(separator: "\n"), false)
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
