#if os(macOS)
import AgenttyProtocol
import Foundation

/// Lets Agentty see what Claude Code tells its status line.
///
/// Claude Code does not write the account's rate limits anywhere, but it
/// hands them to the status line command, with how full the context is. So
/// the sessions Agentty starts get a status line command of Agentty's own,
/// `agenttyd statusline <file>`. It saves what it is given for the host to
/// read, then runs the status line the user had set up, if any, and passes
/// on what that prints, so theirs still shows.
public enum StatusLineRelay {
    /// The command line to start Claude Code with so that it reports to `file`.
    public static func launchArguments(tool: String, file: String) -> String {
        let command = Handoff.shellQuote(tool) + " statusline " + Handoff.shellQuote(file)
        let settings: [String: Any] = ["statusLine": ["type": "command", "command": command]]
        let json = (try? JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return " --settings " + Handoff.shellQuote(json)
    }

    /// Saves the status line's input and returns what the user's own status
    /// line prints for it.
    public static func run(input: Data, file: String, home: String = NSHomeDirectory(), environment: [String: String] = ProcessInfo.processInfo.environment) -> Data {
        let object = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any]
        if object != nil {
            let url = URL(fileURLWithPath: file)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try? input.write(to: url, options: .atomic)
        }
        let project = (object?["workspace"] as? [String: Any])?["project_dir"] as? String ?? object?["cwd"] as? String
        guard let command = userCommand(project: project, home: home, environment: environment) else { return Data() }
        return pipe(input, through: command)
    }

    /// The status line the user set up, looked for where Claude Code looks:
    /// the project's settings first, then their own.
    static func userCommand(project: String?, home: String, environment: [String: String]) -> String? {
        var files: [String] = []
        if let project {
            files += [project + "/.claude/settings.local.json", project + "/.claude/settings.json"]
        }
        let configuration = environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 } ?? home + "/.claude"
        files.append(configuration + "/settings.json")
        for file in files {
            guard let data = FileManager.default.contents(atPath: file),
                  let settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let statusLine = settings["statusLine"] as? [String: Any],
                  let command = statusLine["command"] as? String, !command.isEmpty
            else { continue }
            // Never ourselves: that would run without end.
            if command.contains("agenttyd") && command.contains("statusline") { continue }
            return command
        }
        return nil
    }

    private static func pipe(_ input: Data, through command: String) -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return Data() }
        // A status line that hangs must not hang Claude Code's.
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: timeout)
        DispatchQueue.global().async {
            try? stdin.fileHandleForWriting.write(contentsOf: input)
            try? stdin.fileHandleForWriting.close()
        }
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()
        return output
    }

    /// What Claude Code told the status line, as usage.
    public static func usage(from data: Data) -> SessionUsage? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var usage = SessionUsage()
        let model = object["model"] as? [String: Any]
        usage.model = model?["display_name"] as? String ?? model?["id"] as? String
        if let context = object["context_window"] as? [String: Any] {
            usage.contextWindow = (context["context_window_size"] as? NSNumber)?.intValue
            if let current = context["current_usage"] as? [String: Any] {
                let sent = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"]
                    .reduce(0) { $0 + ((current[$1] as? NSNumber)?.intValue ?? 0) }
                if sent > 0 { usage.contextTokens = sent }
            }
            if usage.contextTokens == nil, let percent = (context["used_percentage"] as? NSNumber)?.doubleValue, let window = usage.contextWindow {
                usage.contextTokens = Int(percent / 100 * Double(window))
            }
        }
        if let limits = object["rate_limits"] as? [String: Any] {
            for (key, minutes) in [("five_hour", 300), ("seven_day", 10080)] {
                guard let limit = limits[key] as? [String: Any], let used = (limit["used_percentage"] as? NSNumber)?.doubleValue else { continue }
                let resets = (limit["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
                usage.limits.append(UsageLimit(windowMinutes: minutes, usedPercent: used, resetsAt: resets))
            }
        }
        return usage.isEmpty ? nil : usage
    }
}
#endif
