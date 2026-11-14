import Foundation

/// What an agent asks of the shells agents opened through MCP (#10), sent
/// by `agenttermd mcp` on its behalf with the key of its session. An agent
/// types into and closes only the shells it opened itself, and reads those
/// any agent opened (#61); it never reaches the user's own sessions, and
/// opens shells only, never another agent.
public enum AgentShellRequest: Codable, Equatable, Sendable {
    /// Starts a shell in the agent's folder, running `command` when given.
    case open(command: String?, title: String?)
    /// The shells agents opened that still run, with which are this agent's.
    case list
    /// The screen as text, with as many lines above it as asked for. Of any
    /// shell an agent opened.
    case read(session: SessionID, linesAbove: Int)
    /// Text, then keys by name ("Return", "Control C", "Up"), as typed.
    /// Into a shell this agent opened only.
    case send(session: SessionID, text: String?, keys: [String])
    /// Ends a shell this agent opened.
    case close(session: SessionID)
}

public enum AgentShellResult: Codable, Equatable, Sendable {
    case opened(SessionInfo)
    /// Every shell an agent opened; `own` are the asking agent's, which it
    /// may type into, the others it may only read.
    case shells([SessionInfo], own: [SessionID])
    case screen(String)
    case done
    /// Not done, and why, in words for the agent.
    case refused(String)
}

extension SessionInfo {
    /// Whose shell this is, for the lists: the name of the session of the
    /// agent that opened it, or that its agent has ended. Nil for a session
    /// no agent opened. Only that agent types into it (#61).
    public func openedByName(among sessions: [SessionInfo]) -> String? {
        guard let openedBy else { return nil }
        return sessions.first { $0.id == openedBy }?.displayName ?? "an agent that has ended"
    }
}

/// Something that keeps the agents from opening shells the user sees,
/// although "Agents can open shells you see" is on (#58). The host tells
/// every client, for as long as it lasts, and the apps warn of it in their
/// top banner: without it, the switch says on while no agent can open a
/// shell, and the agents run their commands out of sight.
public struct AgentShellsFault: Codable, Equatable, Hashable, Identifiable, Sendable {
    /// What is wrong. Text rather than a closed list, so that a client
    /// still reads a cause that was added after it was built.
    public struct Cause: RawRepresentable, Codable, Hashable, Sendable {
        public var rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }

        /// The server could not be added to an agent's configuration.
        public static let install = Cause(rawValue: "install")
        /// An agent's server was refused when it signed in to the host.
        public static let signIn = Cause(rawValue: "signIn")
    }

    public var cause: Cause
    /// The agents it is about, by name ("Claude Code"); none when the host
    /// cannot tell which.
    public var agents: [String]

    public init(cause: Cause, agents: [String] = []) {
        self.cause = cause
        self.agents = agents
    }

    public var id: String { ([cause.rawValue] + agents).joined(separator: "|") }

    /// What is wrong, in one sentence, the same on the Mac and the iPhone.
    /// `mac` names the Mac the host is on when the app runs on another.
    public func headline(on mac: String? = nil) -> String {
        let onMac = mac.map { " on \($0)" } ?? ""
        switch cause {
        case .install:
            let named = agents.isEmpty ? "an agent" : Self.list(agents)
            return "AgentTerm's shells could not be set up in \(named)\(onMac)."
        case .signIn:
            return "An agent's MCP server was refused by the AgentTerm host\(onMac)."
        default:
            return "Agents cannot open shells you see\(onMac) (\(cause.rawValue))."
        }
    }

    /// What follows from it and what to do about it.
    public var advice: String {
        switch cause {
        case .install:
            return "Agents started there cannot open shells you see. Turning “Agents can open shells you see” off and on in Settings tries again."
        case .signIn:
            return "Its agent cannot open shells you see: it was started by another copy of AgentTerm, or before the host was set up again. Start that agent's session again."
        default:
            return "Turning “Agents can open shells you see” off and on in Settings sets it up again."
        }
    }

    /// "Codex", "Codex and Copilot CLI", "Codex, Copilot CLI and Antigravity".
    static func list(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
    }
}

/// Keys an agent may send by name, as the bytes a terminal sends for them.
public enum TerminalKeys {
    public static func bytes(for name: String) -> String? {
        let named: [String: String] = [
            "return": "\r", "enter": "\r", "tab": "\t", "escape": "\u{1b}", "esc": "\u{1b}", "backspace": "\u{7f}", "space": " ",
            "up": "\u{1b}[A", "down": "\u{1b}[B", "right": "\u{1b}[C", "left": "\u{1b}[D",
            "home": "\u{1b}[H", "end": "\u{1b}[F", "page up": "\u{1b}[5~", "page down": "\u{1b}[6~", "delete": "\u{1b}[3~",
        ]
        let key = name.lowercased().trimmingCharacters(in: .whitespaces)
        if let bytes = named[key] { return bytes }
        // "Control C", "Ctrl-C", "C-c".
        for prefix in ["control ", "control-", "ctrl ", "ctrl-", "ctrl+", "c-"] where key.hasPrefix(prefix) {
            let rest = key.dropFirst(prefix.count)
            guard rest.count == 1, let letter = rest.unicodeScalars.first, ("a"..."z").contains(Character(letter)) else { return nil }
            return String(UnicodeScalar(UInt8(letter.value - 96)))
        }
        return nil
    }
}

/// What the agents are told when they are to run their commands in shells
/// the user sees (#10): in the MCP server's instructions, and in Claude
/// Code's system prompt.
public enum AgentShellsInstructions {
    /// As this build says it, naming its own server.
    public static var useShells: String { useShells(server: AppChannel.current.mcpServerName) }

    /// - Parameter server: The name the MCP server has in the agent's
    ///   configuration, which differs between the builds (#57).
    public static func useShells(server: String) -> String {
        "You run inside AgentTerm, where the user watches what you do. Run shell commands in a shell of the \(server) MCP server rather than with your own command tool. Open a shell of your own with open_shell, and keep using it: type each command with send_input and the Return key, wait for it with wait, and read the result with read_screen. Only the agent that opened a shell may type into it: list_shells says which are yours, and another agent's you may read but not type into. Open another of your own only while yours runs something that keeps running, such as a dev server. Leave a shell open for the next task rather than close it, unless it runs something that should end."
    }
}
