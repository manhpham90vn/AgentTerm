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
///
/// A released build and a development build each install a server under a
/// name of their own (`AppChannel.mcpServerName`, #57), and each installs,
/// repairs and removes only its own.
public final class AgentShellsInstall {
    /// The name servers had before each build had its own.
    static let formerName = "agentterm"

    /// The name the server has in each agent's configuration.
    public let name: String

    /// Runs an agent's command line and says whether it worked.
    public typealias Run = (_ arguments: [String]) -> Bool

    private struct Record: Codable, Equatable {
        /// Nil until the user turned it on or off: on by default.
        var on: Bool?
        /// The agents it is installed in, with the program it names.
        var installed: [String: String] = [:]
        /// The name they were installed under; nil for one from before each
        /// build had its own (`formerName`).
        var name: String?
    }

    private let file: URL
    private let tool: String
    private let run: Run
    private let codexConfig: URL

    /// - Parameters:
    ///   - directory: The host's state folder.
    ///   - tool: The host's program, which the server runs as `<tool> mcp`.
    ///   - name: The server's name in the agents' configuration; this
    ///     build's unless a test's.
    ///   - codexConfig: Codex's configuration; its own unless a test's.
    ///   - run: Runs an agent's command line; through the user's login shell
    ///     unless a test stands in for it.
    public init(directory: URL, tool: String, name: String = AppChannel.current.mcpServerName, codexConfig: URL? = nil, run: Run? = nil) {
        file = directory.appendingPathComponent("agent-shells.json")
        self.tool = tool
        self.name = name
        self.codexConfig = codexConfig ?? Self.codexConfigFile
        self.run = run ?? AgentShellsInstall.throughLoginShell
    }

    private var record: Record {
        get {
            var record = (FileManager.default.contents(atPath: file.path)).flatMap { try? JSONDecoder().decode(Record.self, from: $0) } ?? Record()
            // What a build from before installed under the name every build
            // shared is not this build's any more: it is left where it is,
            // for the build that has that name, and not counted as installed.
            if (record.name ?? Self.formerName) != name { record.installed = [:] }
            record.name = name
            return record
        }
        set {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(newValue).write(to: file, options: .atomic)
        }
    }

    /// Whether the user wants it: on unless turned off.
    public var isOn: Bool { record.on ?? true }

    /// Installs it in every agent that is installed and does not have this
    /// host's yet, when it is on. Blocks while the agents run.
    ///
    /// - Returns: The agents it could not be installed in (#58).
    @discardableResult
    public func ensure(agents: [AgentInfo]) -> [AgentInfo] {
        guard isOn else { return [] }
        var record = self.record
        var failed: [AgentInfo] = []
        for agent in agents {
            guard let path = agent.path, record.installed[agent.id] != tool, let add = Self.add(agent: agent.id, path: path, tool: tool, name: name) else {
                continue
            }
            // One left by a host that has moved since is replaced.
            if record.installed[agent.id] != nil { _ = run(Self.remove(agent: agent.id, path: path, name: name)) }
            if run(add) {
                record.installed[agent.id] = tool
            } else if run(Self.remove(agent: agent.id, path: path, name: name)), run(add) {
                // An agent refuses a name it has already: one under this
                // build's name that it did not record (the record was lost,
                // or the entry was written by hand) is replaced by its own.
                record.installed[agent.id] = tool
            } else {
                failed.append(agent)
            }
        }
        // Also mends what a host from before installed without it.
        if record.installed["codex"] != nil { Self.forwardSessionVariable(in: codexConfig, name: name) }
        self.record = record
        return failed
    }

    /// Turns it on (and installs it) or off (and removes what was installed).
    ///
    /// - Returns: The agents it could not be installed in, when turned on.
    @discardableResult
    public func set(on: Bool, agents: [AgentInfo]) -> [AgentInfo] {
        var record = self.record
        record.on = on
        if !on {
            for agent in agents {
                guard let path = agent.path, record.installed[agent.id] != nil else { continue }
                if run(Self.remove(agent: agent.id, path: path, name: name)) { record.installed[agent.id] = nil }
            }
        }
        self.record = record
        return on ? ensure(agents: agents) : []
    }

    /// `<agent> mcp add`, as each agent takes it.
    static func add(agent: String, path: String, tool: String, name: String) -> [String]? {
        switch agent {
        case "claude": return [path, "mcp", "add", "--scope", "user", name, "--", tool, "mcp"]
        case "codex", "copilot", "agy": return [path, "mcp", "add", name, "--", tool, "mcp"]
        default: return nil
        }
    }

    static func remove(agent: String, path: String, name: String) -> [String] {
        agent == "claude" ? [path, "mcp", "remove", "--scope", "user", name] : [path, "mcp", "remove", name]
    }

    /// Codex starts an MCP server with only a few of its own variables
    /// (`HOME`, `PATH` and the like) unless its configuration names more in
    /// `env_vars`: without the session's, the server is not in a session and
    /// offers no tools. `codex mcp add` cannot name them, so the line is
    /// written into the server's table, next to what the user may have
    /// named there.
    static func forwardSessionVariable(in config: URL, name: String) {
        guard let text = try? String(contentsOf: config, encoding: .utf8) else { return }
        var lines = text.components(separatedBy: "\n")
        guard let header = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "[mcp_servers.\(name)]" }) else { return }
        let end = lines[(header + 1)...].firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") } ?? lines.endIndex
        let variable = "\"\(HostServer.agentShellsVariable)\""
        if let line = lines[(header + 1)..<end].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("env_vars") }) {
            guard !lines[line].contains(variable), let open = lines[line].firstIndex(of: "[") else { return }
            let rest = lines[line][lines[line].index(after: open)...]
            lines[line] = String(lines[line][...open]) + variable + (rest.trimmingCharacters(in: .whitespaces).hasPrefix("]") ? "" : ", ") + rest
        } else {
            lines.insert("env_vars = [\(variable)]", at: header + 1)
        }
        try? lines.joined(separator: "\n").write(to: config, atomically: true, encoding: .utf8)
    }

    /// Codex's own configuration file, where `codex mcp add` writes.
    static var codexConfigFile: URL {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        return (home ?? URL(fileURLWithPath: HostEnvironment.homeDirectory).appendingPathComponent(".codex")).appendingPathComponent("config.toml")
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
