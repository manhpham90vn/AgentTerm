#if os(macOS)
import AgentTermProtocol
import Foundation

/// Reads the uncommitted changes of a working directory with the `git` CLI.
public enum GitDiff {
    private static let git = "/usr/bin/git"
    private static let maxPatchBytes = 400_000
    private static let maxUntrackedFiles = 50

    /// Blocks while git runs. Call off the main thread.
    ///
    /// One `git status` says what changed, the branch and how far it is
    /// from its upstream, in one walk of the working tree; `git diff` runs
    /// only for what status says is staged or not, and the patches of new
    /// files are made here rather than by a git for each (#21).
    public static func snapshot(directory: String) -> DiffSnapshot {
        guard let head = run(["rev-parse", "--is-inside-work-tree", "--show-prefix"], in: directory) else { return .notARepository }
        let lines = head.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first == "true" else { return .notARepository }
        // The folder's place in its repository: status names paths from the top.
        let prefix = lines.count > 1 ? lines[1] : ""
        guard let status = run(["status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all", "--no-renames", "--", "."], in: directory)
        else { return .notARepository }
        let read = readStatus(status, prefix: prefix)

        // A rename is listed as a deleted file and a new one, so that every
        // entry is one path that can be staged or unstaged on its own.
        let options = ["--no-color", "--no-ext-diff", "--relative", "--no-renames"]
        // The index against the last commit is what a commit would record.
        // In a repository without commits git compares against nothing.
        var files: [FileDiff] = []
        if read.staged {
            files += parse(run(["diff", "--cached"] + options, in: directory) ?? "").map { file -> FileDiff in
                var file = file
                file.isStaged = true
                return file
            }
        }
        // The working tree against the index is what is not staged.
        if read.unstaged { files += parse(run(["diff"] + options, in: directory) ?? "") }
        for path in read.untracked.prefix(maxUntrackedFiles) { files.append(newFile(path, in: directory)) }

        var snapshot = DiffSnapshot(isRepository: true, branch: read.branch, files: files)
        if snapshot.branch != nil {
            snapshot.upstream = read.upstream
            snapshot.ahead = read.upstream == nil ? nil : read.ahead
            snapshot.behind = read.upstream == nil ? nil : read.behind
            if read.upstream == nil {
                // One that follows a branch of a remote not fetched yet, a
                // clone of an empty repository for one, is said to by its settings.
                let followed = read.branch.map { tracking(of: $0, in: directory) }
                snapshot.upstream = followed?.upstream
                if followed?.upstream == nil { snapshot.pushRemote = pushRemote(in: directory) }
            }
        }
        return snapshot
    }

    /// What `git status --porcelain=v2 -z --branch` says, for the paths
    /// under `prefix`, named from there.
    static func readStatus(_ text: String, prefix: String) -> (
        branch: String?, upstream: String?, ahead: Int?, behind: Int?, staged: Bool, unstaged: Bool, untracked: [String]
    ) {
        var branch: String?
        var upstream: String?
        var ahead: Int?
        var behind: Int?
        var staged = false
        var unstaged = false
        var untracked: [String] = []
        for record in text.split(separator: "\0") {
            if record.hasPrefix("# branch.head ") {
                let name = String(record.dropFirst("# branch.head ".count))
                branch = name == "(detached)" ? nil : name
            } else if record.hasPrefix("# branch.upstream ") {
                upstream = String(record.dropFirst("# branch.upstream ".count))
            } else if record.hasPrefix("# branch.ab ") {
                let counts = record.dropFirst("# branch.ab ".count).split(separator: " ")
                ahead = counts.first.flatMap { Int($0.dropFirst()) }
                behind = counts.dropFirst().first.flatMap { Int($0.dropFirst()) }
            } else if record.hasPrefix("1 ") || record.hasPrefix("2 ") || record.hasPrefix("u ") {
                let code = record.dropFirst(2).prefix(2)
                if record.hasPrefix("u ") {
                    unstaged = true
                } else {
                    if code.first != "." { staged = true }
                    if code.last != "." { unstaged = true }
                }
            } else if record.hasPrefix("? ") {
                let path = String(record.dropFirst(2))
                if path.hasPrefix(prefix) { untracked.append(String(path.dropFirst(prefix.count))) }
            }
        }
        return (branch, upstream, ahead, behind, staged, unstaged, untracked)
    }

    /// The largest new file whose lines are shown.
    private static let maxNewFileBytes = 8 * 1024 * 1024

    /// A file git does not track yet, as `git diff --no-index` shows it:
    /// every line added.
    static func newFile(_ path: String, in directory: String) -> FileDiff {
        var file = FileDiff(path: path, added: 0, deleted: 0, isUntracked: true, patch: "")
        file.status = .added
        let url = URL(fileURLWithPath: directory).appendingPathComponent(path)
        var text: String
        if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) {
            text = target
        } else {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            guard size <= maxNewFileBytes, let data = try? Data(contentsOf: url) else {
                file.patch = size > maxNewFileBytes ? "File too large to show (\(size / 1_048_576) MB)" : ""
                return file
            }
            guard !data.prefix(8000).contains(0), let decoded = String(data: data, encoding: .utf8) else {
                file.patch = data.isEmpty ? "" : "Binary file changed"
                return file
            }
            text = decoded
        }
        guard !text.isEmpty else { return file }
        let endsWithNewline = text.hasSuffix("\n")
        if endsWithNewline { text.removeLast() }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        file.added = lines.count
        var patch = "@@ -0,0 +\(lines.count == 1 ? "1" : "1,\(lines.count)") @@\n" + lines.map { "+" + $0 }.joined(separator: "\n")
        if !endsWithNewline { patch += "\n\\ No newline at end of file" }
        if patch.utf8.count > maxPatchBytes { patch = String(patch.prefix(maxPatchBytes)) + "\n… diff truncated …" }
        file.patch = patch
        return file
    }

    /// The branch a local branch follows, and how far the two are apart as
    /// of the last fetch. Nothing is asked of the remote here.
    static func tracking(of branch: String, in directory: String) -> (upstream: String?, ahead: Int?, behind: Int?) {
        let format = "--format=%(upstream:short)%09%(upstream:track,nobracket)"
        guard
            let line = run(["for-each-ref", format, "refs/heads/\(branch)"], in: directory)?
                .split(whereSeparator: \.isNewline).first
        else {
            // A branch without a commit yet, in a clone of an empty
            // repository for one, is no ref, but may be set up to follow one.
            func setting(_ name: String) -> String? {
                let value = run(["config", "--get", "branch.\(branch).\(name)"], in: directory)?.trimmingCharacters(in: .whitespacesAndNewlines)
                return value?.isEmpty == false ? value : nil
            }
            guard let remote = setting("remote"), let merge = setting("merge"), merge.hasPrefix("refs/heads/") else { return (nil, nil, nil) }
            return (remote + "/" + merge.dropFirst("refs/heads/".count), nil, nil)
        }
        let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
        guard let upstream = parts.first, !upstream.isEmpty else { return (nil, nil, nil) }
        let track = parts.count > 1 ? String(parts[1]) : ""
        // A branch whose upstream was deleted on the remote has no counts.
        guard track != "gone" else { return (String(upstream), nil, nil) }
        return (String(upstream), count("ahead", in: track), count("behind", in: track))
    }

    /// The number after a word in "ahead 2, behind 1". Zero when the word is not there.
    static func count(_ word: String, in track: String) -> Int {
        for part in track.split(separator: ",") {
            let words = part.split(separator: " ")
            if words.count == 2, words[0] == word, let number = Int(words[1]) { return number }
        }
        return 0
    }

    /// The remote a branch without an upstream would be pushed to: "origin"
    /// when there is one, else the only or first remote.
    static func pushRemote(in directory: String) -> String? {
        let remotes = (run(["remote"], in: directory) ?? "").split(whereSeparator: \.isNewline).map(String.init)
        return remotes.contains("origin") ? "origin" : remotes.first
    }

    private static func name(_ text: Substring) -> String {
        String(text.hasSuffix("\t") ? text.dropLast() : text)
    }

    /// Splits `git diff` output into one entry per file.
    static func parse(_ text: String) -> [FileDiff] {
        var files: [FileDiff] = []
        var header: [Substring] = []
        var body: [Substring] = []
        var inFile = false

        func flush() {
            guard inFile else { return }
            var path = ""
            for line in header {
                // git ends a name that has a space in it with a tab.
                if line.hasPrefix("+++ b/") {
                    path = Self.name(line.dropFirst(6))
                } else if line.hasPrefix("--- a/") && path.isEmpty {
                    path = Self.name(line.dropFirst(6))
                } else if line.hasPrefix("rename to ") {
                    path = String(line.dropFirst(10))
                }
            }
            if path.isEmpty, let first = header.first, let range = first.range(of: " b/", options: .backwards) {
                path = String(first[range.upperBound...])
            }
            let added = body.filter { $0.hasPrefix("+") }.count
            let deleted = body.filter { $0.hasPrefix("-") }.count
            var patch = body.joined(separator: "\n")
            if patch.utf8.count > maxPatchBytes {
                patch = String(patch.prefix(maxPatchBytes)) + "\n… diff truncated …"
            }
            if patch.isEmpty, header.contains(where: { $0.hasPrefix("Binary files") }) {
                patch = "Binary file changed"
            }
            var status = FileDiff.Status.modified
            if header.contains(where: { $0.hasPrefix("new file mode") }) { status = .added }
            if header.contains(where: { $0.hasPrefix("deleted file mode") }) { status = .deleted }
            files.append(FileDiff(path: path, added: added, deleted: deleted, isUntracked: false, patch: patch, status: status))
        }

        var inHunks = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git ") {
                flush()
                header = [line]
                body = []
                inFile = true
                inHunks = false
            } else if inFile {
                if line.hasPrefix("@@") { inHunks = true }
                if inHunks { body.append(line) } else { header.append(line) }
            }
        }
        if body.last == "" { body.removeLast() }
        flush()
        return files
    }

    private static func run(_ arguments: [String], in directory: String, acceptStatus: Set<Int32> = [0]) -> String? {
        guard let result = Subprocess.run(git, ["-C", directory, "-c", "core.quotepath=false"] + arguments, timeout: 15),
            acceptStatus.contains(result.status)
        else { return nil }
        return String(decoding: result.output, as: UTF8.self)
    }
}
/// Changes what the next commit will contain, and makes the commit.
///
/// Each call returns nil when it worked, or what git said when it did not.
public enum GitActions {
    private static let git = "/usr/bin/git"

    /// Stages files for the next commit. No files means every change,
    /// new and deleted files included.
    public static func stage(_ files: [String], in directory: String) -> String? {
        files.isEmpty ? run(["add", "--all"], in: directory) : run(["add", "--"] + files, in: directory)
    }

    /// Takes files out of the next commit, leaving the working tree as it
    /// is. No files means all of them.
    public static func unstage(_ files: [String], in directory: String) -> String? {
        // Before the first commit there is nothing to restore the index to,
        // so the files are taken out of it instead.
        let hasCommit = run(["rev-parse", "--verify", "--quiet", "HEAD"], in: directory) == nil
        if hasCommit {
            return run(["restore", "--staged", "--"] + (files.isEmpty ? ["."] : files), in: directory)
        }
        return run(["rm", "--cached", "-r", "--quiet", "--"] + (files.isEmpty ? ["."] : files), in: directory)
    }

    /// Throws away changes that are not staged (#39). A file git tracks
    /// goes back to what is staged of it, or to the last commit; one git
    /// does not track yet is moved to the Trash, where it can be put back
    /// from, since nothing else keeps it. No files means every change that
    /// is not staged. What is staged is left as it is: it is taken out of
    /// the next commit first, by whoever means to lose it.
    public static func discard(_ files: [String], in directory: String) -> String? {
        let all = files.isEmpty
        let named = all ? ["."] : files
        // Every change at once takes a folder git does not track whole,
        // rather than leave it behind empty.
        guard let changed = list(["diff", "--name-only", "--relative", "-z", "--"] + named, in: directory),
            let untracked = list(["ls-files", "--others", "--exclude-standard", "-z"] + (all ? ["--directory", "--no-empty-directory"] : []) + ["--"] + named, in: directory)
        else { return "git could not be started." }
        guard !changed.isEmpty || !untracked.isEmpty else { return "There is no change to discard." }
        if !changed.isEmpty, let problem = run(["restore", "--worktree", "--"] + changed, in: directory) { return problem }
        for file in untracked {
            let path = (directory as NSString).appendingPathComponent(file.hasSuffix("/") ? String(file.dropLast()) : file)
            do {
                try FileBrowser.trash(path)
            } catch {
                return "\(file) could not be moved to the Trash: \(error.localizedDescription)"
            }
        }
        return nil
    }

    /// The paths a git command prints, separated by NUL. Nil when git
    /// could not be run or refused.
    static func list(_ arguments: [String], in directory: String) -> [String]? {
        guard let result = Subprocess.run(git, ["-C", directory, "--literal-pathspecs"] + arguments, timeout: 30), result.status == 0 else { return nil }
        return String(decoding: result.output, as: UTF8.self).split(separator: "\0").map(String.init)
    }

    /// Commits what is staged, with the identity and hooks the repository is
    /// set up with.
    public static func commit(message: String, in directory: String) -> String? {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Write a commit message first." }
        // Hooks run here, and may call tools the user's shell finds.
        return findingTools { run(["commit", "--quiet", "--message", trimmed], in: directory, timeout: 120, environment: actionEnvironment) }
    }

    /// Pushes the checked out branch to its upstream. A branch without one
    /// goes to the remote `GitDiff.pushRemote` names, under its own name,
    /// and follows it from then on.
    ///
    /// With `force`, what the upstream has and the branch has not is
    /// overwritten, but only as long as the upstream is still where it was
    /// last seen (`--force-with-lease`): commits someone pushed since are
    /// not lost to it. The apps ask first, saying what would be overwritten
    /// (`forcePushLoses`).
    public static func push(in directory: String, force: Bool = false) -> String? {
        guard let branch = currentBranch(in: directory) else { return "Check out a branch to push: this is a detached HEAD." }
        let arguments: [String]
        if GitDiff.tracking(of: branch, in: directory).upstream != nil {
            arguments = force ? ["push", "--force-with-lease"] : ["push"]
        } else {
            guard let remote = GitDiff.pushRemote(in: directory) else { return "This repository has no remote to push to." }
            arguments = ["push", "--set-upstream", remote, branch]
        }
        let problem = findingTools { run(arguments, in: directory, timeout: remoteTimeout, environment: actionEnvironment) }
        return problem.map(explainingSignIn).map { said in
            // Refused because the remote has commits the branch has not:
            // said in words, with what there is to do about it.
            guard !force, said.contains("non-fast-forward") || said.contains("fetch first") else { return said }
            return "The remote has commits this branch does not have, so the push was refused. Pull first, or force the push to overwrite them.\n\n\(said)"
        }
    }

    /// Asks the remotes for what is new, without changing the branch or the
    /// files: how far ahead and behind the branch is then is as of now.
    /// Branches that are gone from a remote are forgotten here too.
    public static func fetch(in directory: String) -> String? {
        guard list(["remote"], in: directory)?.isEmpty == false else { return "This repository has no remote to fetch from." }
        let problem = findingTools { run(["fetch", "--all", "--prune", "--quiet"], in: directory, timeout: remoteTimeout, environment: actionEnvironment) }
        return problem.map(explainingSignIn)
    }

    /// What a forced push would overwrite: the commits the upstream has and
    /// the checked out branch has not, newest first, as "hash subject",
    /// after asking the remote, so that it is as of now. Nil when the
    /// branch follows none, or the remote could not be asked.
    public static func forcePushLoses(in directory: String) -> (upstream: String, commits: [String])? {
        guard let branch = currentBranch(in: directory), let upstream = GitDiff.tracking(of: branch, in: directory).upstream else { return nil }
        guard fetch(in: directory) == nil else { return nil }
        guard let lines = list(["log", "--format=%h %s", "HEAD..@{upstream}"], in: directory) else { return nil }
        return (upstream, lines.flatMap { $0.split(separator: "\n").map(String.init) })
    }

    /// How a pull brings in what the upstream has.
    public enum PullMode: String, Sendable {
        /// The way the repository is set up to: git's own setting.
        case asSetUp = "default"
        case merge
        case rebase
    }

    /// Brings in what the upstream has, the way the repository is set up to
    /// unless a merge or a rebase is asked for. A pull that stops on a
    /// conflict is undone, since there is nowhere here to resolve it.
    public static func pull(in directory: String, mode: PullMode = .asSetUp) -> String? {
        guard let branch = currentBranch(in: directory) else { return "Check out a branch to pull: this is a detached HEAD." }
        guard GitDiff.tracking(of: branch, in: directory).upstream != nil else {
            return "\(branch) does not follow a branch on a remote yet. Push it first."
        }
        // A merge or rebase the user left unfinished is theirs, not this pull's.
        let before = unfinished(in: directory)
        let problem = findingTools { () -> String? in
            let how = mode == .merge ? ["--no-rebase"] : mode == .rebase ? ["--rebase"] : []
            guard let problem = run(["pull", "--no-edit"] + how, in: directory, timeout: remoteTimeout, environment: actionEnvironment) else { return nil }
            guard before == nil, let left = unfinished(in: directory) else { return problem }
            _ = run([left, "--abort"], in: directory)
            return "The pull ran into conflicts and was undone. Pull in a terminal to resolve them.\n\n\(problem)"
        }
        return problem.map(explainingSignIn)
    }

    private static let remoteTimeout: TimeInterval = 120

    /// Where the `PATH` for what git starts by name comes from. A test puts
    /// a stand-in for the user's shell here.
    nonisolated(unsafe) static var shellPath = LoginShellPath.shared

    /// What commit, push and pull run with: the host's own environment, with
    /// the `PATH` of the user's shell, so that git finds the credential
    /// helpers, hooks' tools and `git-lfs` it starts by name (when the shell
    /// did not say, the `PATH` stays as it is). The first call may wait for
    /// the shell to start: never on the main thread.
    ///
    /// Neither git nor a hook may wait for a password or a passphrase: there
    /// is no terminal to type it in. Credential helpers and the SSH agent
    /// still answer; anything that would ask fails with git's own message.
    static var actionEnvironment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        if let path = shellPath.value() { environment["PATH"] = path }
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_ASKPASS"] = nil
        environment["SSH_ASKPASS"] = nil
        environment["SSH_ASKPASS_REQUIRE"] = "never"
        environment["GIT_EDITOR"] = "true"
        return environment
    }

    /// Runs `action`, and once more when git could not find a program and the
    /// user's shell has another `PATH` since it was asked: the program may
    /// have been installed in between.
    static func findingTools(_ action: () -> String?) -> String? {
        guard let problem = action() else { return nil }
        guard missesAProgram(problem), shellPath.refresh() else { return problem }
        return action()
    }

    /// What a shell says of a program it cannot find, and what git says of a
    /// `git-<name>` it cannot find.
    private static func missesAProgram(_ said: String) -> Bool {
        said.contains(": command not found") || said.contains("' is not a git command")
    }

    /// Puts a sentence above git's words when a push or pull could not sign
    /// in because a credential helper was not found, naming the helper.
    /// A sign-in that was refused is left as git said it.
    static func explainingSignIn(_ said: String) -> String {
        guard let host = signInHost(in: said) else { return said }
        let missing = missingHelpers(in: said)
        guard !missing.isEmpty else { return said }
        let names = missing.map { "`\($0)`" }
        let sentence =
            names.count == 1
            ? "git could not sign in to \(host): its credential helper \(names[0]) was not found."
            : "git could not sign in to \(host): its credential helpers \(names.dropLast().joined(separator: ", ")) and \(names.last!) were not found."
        return "\(sentence)\n\n\(said)"
    }

    /// The host in git's "could not read Username for '<url>'", which is how
    /// git says that nothing gave it a sign-in and it may not ask for one.
    private static func signInHost(in said: String) -> String? {
        let start = "could not read Username for '"
        guard let range = said.range(of: start), let end = said[range.upperBound...].firstIndex(of: "'") else { return nil }
        let url = String(said[range.upperBound..<end])
        return URLComponents(string: url)?.host ?? url
    }

    /// The helpers git could not start: one written as a shell command
    /// (`!gh auth git-credential`), of which the shell says
    /// "gh auth git-credential get: gh: command not found", and one git knows
    /// by name (`manager`), of which git says
    /// "git: 'credential-manager' is not a git command".
    static func missingHelpers(in said: String) -> [String] {
        var names: [String] = []
        for line in said.split(whereSeparator: \.isNewline) {
            let parts = line.components(separatedBy: ": ")
            if parts.count >= 3, parts.last == "command not found" {
                let command = parts[0], name = parts[parts.count - 2]
                // The shell names the command git ran, which ends with the
                // operation git asked of the helper; a hook's line does not.
                let operation = command.split(separator: " ").last.map(String.init)
                if command.hasPrefix(name), ["get", "store", "erase"].contains(operation), !names.contains(name) { names.append(name) }
            } else if line.hasPrefix("git: 'credential-"), line.contains("' is not a git command") {
                let rest = line.dropFirst("git: 'credential-".count)
                if let end = rest.firstIndex(of: "'") {
                    let name = String(rest[..<end])
                    if !names.contains(name) { names.append(name) }
                }
            }
        }
        return names
    }

    static func currentBranch(in directory: String) -> String? {
        guard let result = Subprocess.run(git, ["-C", directory, "branch", "--show-current"], timeout: 15), result.status == 0 else { return nil }
        let name = String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// Whether git's own folder of the repository holds `marker`: the file
    /// git keeps while a revert (`REVERT_HEAD`) or a cherry-pick
    /// (`CHERRY_PICK_HEAD`) is under way.
    static func marks(_ marker: String, in directory: String) -> Bool {
        guard let result = Subprocess.run(git, ["-C", directory, "rev-parse", "--absolute-git-dir"], timeout: 15), result.status == 0 else { return false }
        let gitDirectory = String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return FileManager.default.fileExists(atPath: (gitDirectory as NSString).appendingPathComponent(marker))
    }

    /// "merge" or "rebase" when one is under way in the repository.
    static func unfinished(in directory: String) -> String? {
        guard let result = Subprocess.run(git, ["-C", directory, "rev-parse", "--absolute-git-dir"], timeout: 15), result.status == 0 else { return nil }
        let gitDirectory = URL(fileURLWithPath: String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: gitDirectory.appendingPathComponent(name).path) }
        if exists("rebase-merge") || exists("rebase-apply") { return "rebase" }
        return exists("MERGE_HEAD") ? "merge" : nil
    }

    static func run(
        _ arguments: [String], in directory: String, timeout: TimeInterval = 30, environment: [String: String]? = nil, literalPaths: Bool = true
    ) -> String? {
        // File names are taken as they are, not as patterns (`literalPaths`,
        // unless the command names no file and goes wrong with it). No
        // program is asked for a password either: see `actionEnvironment`.
        guard
            let result = Subprocess.run(
                git, ["-C", directory] + (literalPaths ? ["--literal-pathspecs"] : []) + ["-c", "core.askPass="] + arguments, timeout: timeout,
                mergeErrors: true, environment: environment)
        else {
            return "git could not be started."
        }
        guard result.status != 0 else { return nil }
        let said = String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return said.isEmpty ? "git exited with status \(result.status)." : said
    }
}
#endif
