#if os(macOS)
import AgenttyProtocol
import Foundation

/// Finds out which coding agent CLIs are installed.
public enum AgentDetector {
    /// Agents Agentty offers a quick launch button for.
    public static let known: [(id: String, name: String)] = [
        ("claude", "Claude Code"),
        ("codex", "Codex"),
        ("agy", "Antigravity"),
        ("copilot", "Copilot CLI"),
    ]

    private static let marker = "AGENTTY_AGENT:"

    /// Resolves every known agent through the user's interactive login shell,
    /// so tools installed via nvm, Homebrew or a custom PATH are found exactly
    /// when they would be found in a terminal. Blocks for up to a few seconds.
    public static func detect() -> [AgentInfo] {
        let names = known.map(\.id).joined(separator: " ")
        // `whence -p` / `type -P` print the executable path and ignore aliases
        // and functions; `command -v` is the portable fallback.
        let script = """
        for a in \(names); do
          p=$(whence -p "$a" 2>/dev/null || type -P "$a" 2>/dev/null || command -v "$a" 2>/dev/null)
          printf '\(marker)%s=%s\\n' "$a" "$p"
        done
        """
        let result = Subprocess.run(HostEnvironment.shell, ["-l", "-i", "-c", script], cwd: HostEnvironment.homeDirectory, timeout: 8)
        let output = String(data: result?.output ?? Data(), encoding: .utf8) ?? ""
        return parse(output)
    }

    static func parse(_ output: String) -> [AgentInfo] {
        var paths: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            guard let range = line.range(of: marker) else { continue }
            let entry = line[range.upperBound...]
            guard let equals = entry.firstIndex(of: "=") else { continue }
            let path = entry[entry.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if !path.isEmpty { paths[String(entry[..<equals])] = path }
        }
        return known.map { AgentInfo(id: $0.id, name: $0.name, path: paths[$0.id]) }
    }
}
#endif
