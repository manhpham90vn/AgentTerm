#if os(macOS)
import AgentTermProtocol
import Foundation

/// Installs AgentTerm's MCP server (`agenttermd mcp`) in each agent's own
/// configuration, for the whole user, and removes it (#10). It is installed
/// by default the first time the host runs, and Settings removes it. Each
/// agent is asked with its own command, `<agent> mcp add`, so its
/// configuration is written the way it writes it itself.
///
/// What was installed, and with which command, is kept in the state folder
/// (`agent-shells.json`): only that is ever removed, and an agent is asked
/// again when the host's program moved (the app was moved or updated).
public final class AgentShellsInstall {
    /// The name the server has in each agent's configuration.
    public static let name = "agentterm"

    /// Runs an agent's command line and says whether it worked.
    public typealias Run = (_ arguments: [String]) -> Bool

    private struct Record: Codable, Equatable {
        /// Nil until the user turned it on or off: on by default.
        var on: Bool?
        /// The agents it is installed in, with the program it names.
        var installed: [String: String] = [:]
    }

    private let file: URL
    private let tool: String
    private let run: Run

    /// - Parameters:
    ///   - directory: The host's state folder.
    ///   - tool: The host's program, which the server runs as `<tool> mcp`.
    ///   - run: Runs an agent's command line; through the user's login shell
    ///     unless a test stands in for it.
    public init(directory: URL, tool: String, run: Run? = nil) {
        file = directory.appendingPathComponent("agent-shells.json")
        self.tool = tool
        self.run = run ?? AgentShellsInstall.throughLoginShell
    }

    private var record: Record {
        get { (FileManager.default.contents(atPath: file.path)).flatMap { try? JSONDecoder().decode(Record.self, from: $0) } ?? Record() }
        set {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(newValue).write(to: file, options: .atomic)
        }
    }

    /// Whether the user wants it: on unless turned off.
    public var isOn: Bool { record.on ?? true }

    /// Installs it in every agent that is installed and does not have this
    /// host's yet, when it is on. Blocks while the agents run.
    public func ensure(agents: [AgentInfo]) {
        guard isOn else { return }
        var record = self.record
        for agent in agents {
            guard let path = agent.path, record.installed[agent.id] != tool, let add = Self.add(agent: agent.id, path: path, tool: tool) else { continue }
            // One left by a host that has moved since is replaced.
            if record.installed[agent.id] != nil { _ = run(Self.remove(agent: agent.id, path: path)) }
            if run(add) { record.installed[agent.id] = tool }
        }
        self.record = record
    }

    /// Turns it on (and installs it) or off (and removes what was installed).
    public func set(on: Bool, agents: [AgentInfo]) {
        var record = self.record
        record.on = on
        if !on {
            for agent in agents {
                guard let path = agent.path, record.installed[agent.id] != nil else { continue }
                if run(Self.remove(agent: agent.id, path: path)) { record.installed[agent.id] = nil }
            }
        }
        self.record = record
        if on { ensure(agents: agents) }
    }

    /// `<agent> mcp add`, as each agent takes it.
    static func add(agent: String, path: String, tool: String) -> [String]? {
        switch agent {
        case "claude": return [path, "mcp", "add", "--scope", "user", name, "--", tool, "mcp"]
        case "codex", "copilot", "agy": return [path, "mcp", "add", name, "--", tool, "mcp"]
        default: return nil
        }
    }

    static func remove(agent: String, path: String) -> [String] {
        agent == "claude" ? [path, "mcp", "remove", "--scope", "user", name] : [path, "mcp", "remove", name]
    }

    /// As in a terminal: the agents find their sign-in and their PATH there.
    private static func throughLoginShell(_ arguments: [String]) -> Bool {
        let line = arguments.map(Handoff.shellQuote).joined(separator: " ")
        guard let result = Subprocess.run(HostEnvironment.shell, ["-l", "-i", "-c", line], cwd: HostEnvironment.homeDirectory, timeout: 30) else {
            return false
        }
        return result.status == 0
    }
}
#endif
