import Foundation

/// What an agent asks of the shells it opened through MCP (#10), sent by
/// `agenttermd mcp` on its behalf with the key of its session. An agent
/// reaches only the shells it opened, never the user's or another agent's,
/// and opens shells only, never another agent.
public enum AgentShellRequest: Codable, Equatable, Sendable {
    /// Starts a shell in the agent's folder, running `command` when given.
    case open(command: String?, title: String?)
    /// The shells this agent opened that still run.
    case list
    /// The screen as text, with as many lines above it as asked for.
    case read(session: SessionID, linesAbove: Int)
    /// Text, then keys by name ("Return", "Control C", "Up"), as typed.
    case send(session: SessionID, text: String?, keys: [String])
    /// Ends a shell it opened.
    case close(session: SessionID)
}

public enum AgentShellResult: Codable, Equatable, Sendable {
    case opened(SessionInfo)
    case shells([SessionInfo])
    case screen(String)
    case done
    /// Not done, and why, in words for the agent.
    case refused(String)
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
    public static let useShells =
        "You run inside AgentTerm, where the user watches what you do. Run shell commands in a shell of the agentterm MCP server rather than with your own command tool. The shells agents open there are shared, so first look with list_shells for one in your folder that is not running anything, and use it; open one with open_shell only when there is none. Type each command with send_input and the Return key, wait for it with wait, and read the result with read_screen. Keep using the same shell; open another only for something that keeps running, such as a dev server. Leave a shell open for the next task rather than close it, unless it runs something that should end."
}
