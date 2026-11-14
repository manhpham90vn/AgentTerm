#if os(macOS)
import AgentTermProtocol
import Foundation

/// The stash of a repository (#38): putting the changes aside under a
/// name, what is put aside, and bringing it back or throwing it away.
extension GitActions {
    /// What is in the stash, newest first. None for a folder that is no
    /// repository.
    public static func stashes(in directory: String) -> [StashInfo] {
        guard
            let result = Subprocess.run("/usr/bin/git", ["-C", directory, "stash", "list", "--format=%H%x00%gd%x00%gs%x00%at%x01"], timeout: 30),
            result.status == 0
        else { return [] }
        return String(decoding: result.output, as: UTF8.self).components(separatedBy: "\u{1}").compactMap { record in
            let fields = record.trimmingCharacters(in: .newlines).components(separatedBy: "\0")
            guard fields.count == 4, !fields[0].isEmpty else { return nil }
            return StashInfo(hash: fields[0], ref: fields[1], noted: fields[2], date: Date(timeIntervalSince1970: TimeInterval(fields[3]) ?? 0))
        }
    }

    /// Where a stash is in the list now. Its place moves when another is
    /// dropped, so it is looked up by its commit each time.
    private static func ref(of hash: String, in directory: String) -> String? {
        stashes(in: directory).first { $0.hash == hash }?.ref
    }

    private static let goneStash = "That stash is no longer there."

    /// Puts aside what is staged and what is not, and with `untracked` the
    /// files git does not track yet, under `message` when there is one.
    public static func stash(message: String, untracked: Bool, in directory: String) -> String? {
        let snapshot = GitDiff.snapshot(directory: directory)
        guard snapshot.files.contains(where: { untracked || !$0.isUntracked }) else {
            return snapshot.files.isEmpty ? "There is no change to stash." : "Only new files have changed: stash them too, or there is nothing to stash."
        }
        let name = message.trimmingCharacters(in: .whitespacesAndNewlines)
        // Not with names taken literally: with that, git 2.54 saves the
        // files it does not track in the stash and then leaves them in the
        // folder as well. No file is named here.
        return run(
            ["stash", "push"] + (untracked ? ["--include-untracked"] : []) + (name.isEmpty ? [] : ["--message", name]), in: directory, literalPaths: false)
    }

    /// The files a stash holds, each with its diff against the commit it
    /// was made on, the files git did not track then included. Nil when
    /// the stash is no longer there.
    public static func stashFiles(_ hash: String, in directory: String) -> [FileDiff]? {
        guard let ref = ref(of: hash, in: directory) else { return nil }
        guard
            let result = Subprocess.run(
                "/usr/bin/git", ["-C", directory, "stash", "show", "--include-untracked", "--patch", "--no-color", "--no-ext-diff", ref], timeout: 30),
            result.status == 0
        else { return nil }
        return GitDiff.parse(String(decoding: result.output, as: UTF8.self))
    }

    /// Brings what a stash holds back into the folder, and with `pop`
    /// drops it once that worked. When it conflicts, the files that do are
    /// left marked for the user to resolve and the stash is kept: said so.
    public static func applyStash(_ hash: String, pop: Bool, in directory: String) -> String? {
        guard let ref = ref(of: hash, in: directory) else { return goneStash }
        guard let problem = run(["stash", pop ? "pop" : "apply", ref], in: directory) else { return nil }
        if problem.contains("CONFLICT") {
            return "The stash conflicts with what is in the folder now. The files that conflict are marked there, to be resolved by hand, and the stash is kept.\n\n\(problem)"
        }
        if problem.contains("would be overwritten") || problem.contains("already exists") {
            return "The stash was not applied: it would overwrite changes or files that are in the folder now. Commit, stash or discard them first.\n\n\(problem)"
        }
        return problem
    }

    /// Throws a stash away.
    public static func dropStash(_ hash: String, in directory: String) -> String? {
        guard let ref = ref(of: hash, in: directory) else { return goneStash }
        return run(["stash", "drop", ref], in: directory)
    }
}
#endif
