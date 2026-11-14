#if os(macOS)
import AgentTermProtocol
import Foundation

/// How a run of a schedule starts its agent (#11), so that nobody has to do
/// anything when it runs: with the agent's own switch for the schedule's
/// permissions, and with the folder trusted where the agent would ask.
///
/// Found on 2026-11-13 by running each: Claude Code asks whether the folder
/// is trusted even with permissions skipped, and has "No, exit" selected;
/// once trusted, it runs. Copilot CLI with `COPILOT_ALLOW_ALL=true` runs in
/// a folder it has not seen without asking.
public enum ScheduleRunner {
    /// The command line and the variables a run starts its agent with.
    public static func launch(_ schedule: Schedule) -> (command: String, environment: [String: String]) {
        let prompt = Handoff.shellQuote(schedule.prompt)
        let skip = schedule.permissions == .skipAll
        switch schedule.agent {
        case "claude":
            switch schedule.permissions {
            case .skipAll: return ("claude --permission-mode bypassPermissions \(prompt)", [:])
            case .acceptEdits: return ("claude --permission-mode acceptEdits \(prompt)", [:])
            case .ask: return ("claude \(prompt)", [:])
            }
        case "codex":
            // Its hooks run without the user's trust: the warning says so.
            return (skip ? "codex --dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust \(prompt)" : "codex \(prompt)", [:])
        case "copilot":
            switch schedule.permissions {
            // Allows every tool, path and address, and trusts the folder.
            case .skipAll: return ("copilot -i \(prompt)", ["COPILOT_ALLOW_ALL": "true"])
            case .acceptEdits: return ("copilot --allow-tool=write -i \(prompt)", [:])
            case .ask: return ("copilot -i \(prompt)", [:])
            }
        case "agy":
            switch schedule.permissions {
            case .skipAll: return ("agy --dangerously-skip-permissions -i \(prompt)", [:])
            case .acceptEdits: return ("agy --mode accept-edits -i \(prompt)", [:])
            case .ask: return ("agy -i \(prompt)", [:])
            }
        default:
            return ("\(schedule.agent) \(prompt)", [:])
        }
    }

    /// Trusts the schedule's folder where its agent keeps that, so that a
    /// run does not stop at the question: done when the schedule is saved,
    /// while the user is there. Antigravity is told for the run itself
    /// (`AgentHooks`), Copilot CLI too when it skips permissions; Codex was
    /// not seen to ask.
    public static func trustFolder(of schedule: Schedule, home: String) throws {
        switch schedule.agent {
        case "claude":
            try editJSON(at: URL(fileURLWithPath: home).appendingPathComponent(".claude.json")) { settings in
                var projects = settings["projects"] as? [String: Any] ?? [:]
                var project = projects[schedule.folder] as? [String: Any] ?? [:]
                project["hasTrustDialogAccepted"] = true
                projects[schedule.folder] = project
                settings["projects"] = projects
            }
        case "copilot" where schedule.permissions != .skipAll:
            try editJSON(at: URL(fileURLWithPath: home).appendingPathComponent(".copilot/config.json")) { settings in
                var folders = settings["trustedFolders"] as? [String] ?? []
                if !folders.contains(schedule.folder) { folders.append(schedule.folder) }
                settings["trustedFolders"] = folders
            }
        default:
            break
        }
    }

    /// Changes one part of an agent's settings file and leaves the rest as
    /// it was. A file that cannot be read as JSON is left alone.
    ///
    /// The agent writes this file too, often, while it runs (#51). So the
    /// file is read again just before it is written, and when it is no
    /// longer what the change was made to, the change is made anew to what
    /// is there now: what the agent wrote in between is kept. Slashes are
    /// written as the agents write them. What cannot be helped from here:
    /// the order of the keys is not kept, and an agent that later writes
    /// back a copy it read before this change undoes it.
    private static func editJSON(at file: URL, _ change: (inout [String: Any]) -> Void) throws {
        for _ in 0..<editAttempts {
            let read = FileManager.default.contents(atPath: file.path)
            var settings: [String: Any] = [:]
            if let read {
                guard let object = try JSONSerialization.jsonObject(with: read) as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
                settings = object
            }
            let before = settings as NSDictionary
            change(&settings)
            guard !before.isEqual(to: settings) else { return }
            let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .withoutEscapingSlashes])
            beforeWriting?(file)
            // Written by someone else since it was read: once more, from that.
            guard FileManager.default.contents(atPath: file.path) == read else { continue }
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            return
        }
        // Written again every time it was looked at: not something to
        // overwrite blindly.
        throw CocoaError(.fileWriteUnknown)
    }

    /// How often a settings file that keeps changing is read again.
    static let editAttempts = 5
    /// Called between reading a settings file and writing it, by a test
    /// that plays the agent writing the file at that moment.
    static var beforeWriting: ((URL) -> Void)?
}
#endif
