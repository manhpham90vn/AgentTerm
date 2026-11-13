#if os(macOS)
import AgentTermProtocol
import Foundation

/// Reads the uncommitted changes of a working directory with the `git` CLI.
public enum GitDiff {
    private static let git = "/usr/bin/git"
    private static let maxPatchBytes = 400_000
    private static let maxUntrackedFiles = 50

    /// Blocks while git runs. Call off the main thread.
    public static func snapshot(directory: String) -> DiffSnapshot {
        guard let inside = run(["rev-parse", "--is-inside-work-tree"], in: directory),
            inside.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
        else { return .notARepository }

        let branch = run(["branch", "--show-current"], in: directory)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // A rename is listed as a deleted file and a new one, so that every
        // entry is one path that can be staged or unstaged on its own.
        let options = ["--no-color", "--no-ext-diff", "--relative", "--no-renames"]
        // The index against the last commit is what a commit would record.
        // In a repository without commits git compares against nothing.
        var files = parse(run(["diff", "--cached"] + options, in: directory) ?? "").map { file -> FileDiff in
            var file = file
            file.isStaged = true
            return file
        }
        // The working tree against the index is what is not staged.
        files += parse(run(["diff"] + options, in: directory) ?? "")

        let untracked = (run(["ls-files", "--others", "--exclude-standard"], in: directory) ?? "")
            .split(whereSeparator: \.isNewline).map(String.init)
        for path in untracked.prefix(maxUntrackedFiles) {
            // `diff --no-index` exits with 1 when the files differ, which is the normal case here.
            let text = run(["diff", "--no-index"] + options + ["--", "/dev/null", path], in: directory, acceptStatus: [0, 1]) ?? ""
            var file = parse(text).first ?? FileDiff(path: path, added: 0, deleted: 0, isUntracked: true, patch: "")
            file.path = path
            file.isUntracked = true
            file.status = .added
            files.append(file)
        }
        var snapshot = DiffSnapshot(isRepository: true, branch: branch?.isEmpty == false ? branch : nil, files: files)
        if let branch = snapshot.branch {
            let followed = tracking(of: branch, in: directory)
            snapshot.upstream = followed.upstream
            snapshot.ahead = followed.ahead
            snapshot.behind = followed.behind
            if followed.upstream == nil { snapshot.pushRemote = pushRemote(in: directory) }
        }
        return snapshot
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
    public static func push(in directory: String) -> String? {
        guard let branch = currentBranch(in: directory) else { return "Check out a branch to push: this is a detached HEAD." }
        let arguments: [String]
        if GitDiff.tracking(of: branch, in: directory).upstream != nil {
            arguments = ["push"]
        } else {
            guard let remote = GitDiff.pushRemote(in: directory) else { return "This repository has no remote to push to." }
            arguments = ["push", "--set-upstream", remote, branch]
        }
        let problem = findingTools { run(arguments, in: directory, timeout: remoteTimeout, environment: actionEnvironment) }
        return problem.map(explainingSignIn)
    }

    /// Brings in what the upstream has, the way the repository is set up to
    /// (merge or rebase). A pull that stops on a conflict is undone, since
    /// there is nowhere here to resolve it.
    public static func pull(in directory: String) -> String? {
        guard let branch = currentBranch(in: directory) else { return "Check out a branch to pull: this is a detached HEAD." }
        guard GitDiff.tracking(of: branch, in: directory).upstream != nil else {
            return "\(branch) does not follow a branch on a remote yet. Push it first."
        }
        // A merge or rebase the user left unfinished is theirs, not this pull's.
        let before = unfinished(in: directory)
        let problem = findingTools { () -> String? in
            guard let problem = run(["pull", "--no-edit"], in: directory, timeout: remoteTimeout, environment: actionEnvironment) else { return nil }
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
    private static func findingTools(_ action: () -> String?) -> String? {
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

    private static func currentBranch(in directory: String) -> String? {
        guard let result = Subprocess.run(git, ["-C", directory, "branch", "--show-current"], timeout: 15), result.status == 0 else { return nil }
        let name = String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// "merge" or "rebase" when one is under way in the repository.
    private static func unfinished(in directory: String) -> String? {
        guard let result = Subprocess.run(git, ["-C", directory, "rev-parse", "--absolute-git-dir"], timeout: 15), result.status == 0 else { return nil }
        let gitDirectory = URL(fileURLWithPath: String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: gitDirectory.appendingPathComponent(name).path) }
        if exists("rebase-merge") || exists("rebase-apply") { return "rebase" }
        return exists("MERGE_HEAD") ? "merge" : nil
    }

    private static func run(
        _ arguments: [String], in directory: String, timeout: TimeInterval = 30, environment: [String: String]? = nil
    ) -> String? {
        // File names are taken as they are, not as patterns. No program is
        // asked for a password either: see `actionEnvironment`.
        guard
            let result = Subprocess.run(
                git, ["-C", directory, "--literal-pathspecs", "-c", "core.askPass="] + arguments, timeout: timeout, mergeErrors: true,
                environment: environment)
        else {
            return "git could not be started."
        }
        guard result.status != 0 else { return nil }
        let said = String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return said.isEmpty ? "git exited with status \(result.status)." : said
    }
}
#endif
