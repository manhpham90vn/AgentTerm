import Foundation

/// Version of the wire protocol. Bumped on incompatible changes.
public let agenttermProtocolVersion = 8

/// How the version a host speaks compares with this build's. The two apps
/// of one release speak the same; anything else is not supported together.
public enum ProtocolMatch: Equatable, Sendable {
    case same
    /// The host is from an older release than this app.
    case hostOlder
    /// The host is from a newer release than this app.
    case hostNewer

    public init(host: Int, own: Int = agenttermProtocolVersion) {
        self = host == own ? .same : (host < own ? .hostOlder : .hostNewer)
    }
}

/// Default TCP port the host daemon listens on.
public var agenttermDefaultPort: UInt16 { AppChannel.current.defaultPort }

public typealias SessionID = UInt32

/// Size of a terminal grid in character cells.
public struct TermSize: Codable, Equatable, Hashable, Sendable {
    public var cols: Int
    public var rows: Int

    public init(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
    }

    public static let `default` = TermSize(cols: 80, rows: 24)

    /// Clamps to a range every PTY and emulator can handle.
    public var clamped: TermSize {
        TermSize(cols: min(max(cols, 2), 1000), rows: min(max(rows, 2), 1000))
    }
}

public struct SessionInfo: Codable, Equatable, Identifiable, Sendable {
    public var id: SessionID
    /// Short label shown in the UI, e.g. "claude" or "zsh".
    public var title: String
    /// Working directory the session was started in.
    public var cwd: String
    public var size: TermSize
    public var createdAt: Date
    /// Id of the agent running in the session ("claude", "codex", "agy",
    /// "copilot"), or nil for a shell or any other program.
    public var agent: String?
    /// What the session is about: the title of the conversation the agent is
    /// having in it. Nil until the agent has saved one.
    public var summary: String?
    /// The agent's own id of that conversation, once it is known.
    public var conversationID: String?
    /// What the conversation has used, as far as the agent records it.
    public var usage: SessionUsage?
    /// What the agent is doing, as it says it itself. Nil when that is not
    /// known: a shell, an agent that has said nothing yet.
    public var state: AgentState?
    /// Why the state of this session's agent is not known, or not all of
    /// it, and what to do about it, when there is something to say.
    public var stateNote: String?
    /// The agent's session that opened this shell through MCP (#10), when
    /// one did. The shell stays, and is the user's, when that one ends.
    public var openedBy: SessionID?
    /// The branch of the worktree it runs in, when AgentTerm made one for it (#23).
    public var branch: String?
    /// The schedule this session is a run of (#11), by name, and how its
    /// agent handles permissions.
    public var schedule: String?
    public var schedulePermissions: SchedulePermissions?

    public init(
        id: SessionID, title: String, cwd: String, size: TermSize, createdAt: Date,
        agent: String? = nil, summary: String? = nil, conversationID: String? = nil, usage: SessionUsage? = nil,
        state: AgentState? = nil, stateNote: String? = nil, openedBy: SessionID? = nil
    ) {
        self.id = id
        self.title = title
        self.cwd = cwd
        self.size = size
        self.createdAt = createdAt
        self.agent = agent
        self.summary = summary
        self.conversationID = conversationID
        self.usage = usage
        self.state = state
        self.stateNote = stateNote
        self.openedBy = openedBy
    }

    /// What to call the session in a list: its summary, or its title until
    /// there is one.
    public var displayName: String { summary ?? title }
}

public struct CreateRequest: Codable, Equatable, Sendable {
    /// Command line run through the user's login shell (`$SHELL -l -i -c`).
    /// `nil` starts a plain interactive login shell.
    public var command: String?
    /// Working directory. `nil` means the user's home directory.
    public var cwd: String?
    public var title: String?
    public var size: TermSize

    public init(command: String? = nil, cwd: String? = nil, title: String? = nil, size: TermSize = .default) {
        self.command = command
        self.cwd = cwd
        self.title = title
        self.size = size
    }
}

/// A coding agent CLI the host knows how to launch.
public struct AgentInfo: Codable, Equatable, Identifiable, Sendable {
    /// Stable identifier, also the command name: "claude", "codex", "agy", "copilot".
    public var id: String
    public var name: String
    /// Resolved location on the host, or `nil` when the CLI is not installed.
    public var path: String?

    public var isInstalled: Bool { path != nil }

    public init(id: String, name: String, path: String?) {
        self.id = id
        self.name = name
        self.path = path
    }
}

/// A device that was paired with the host and holds its own token.
public struct DeviceInfo: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var pairedAt: Date
    /// When the device last connected, if it ever did after pairing.
    public var lastSeenAt: Date?
    public var isConnected: Bool

    public init(id: String, name: String, pairedAt: Date, lastSeenAt: Date?, isConnected: Bool) {
        self.id = id
        self.name = name
        self.pairedAt = pairedAt
        self.lastSeenAt = lastSeenAt
        self.isConnected = isConnected
    }
}

/// JSON text frames sent by a client.
public enum ClientMessage: Codable, Equatable, Sendable {
    /// Must be the first message on a connection, unless the client is
    /// pairing. The token is a paired device's own, or the host's local one.
    case hello(token: String, client: String)
    /// First message of a device that is not paired yet. Trades a pairing
    /// code, which works once and for a few minutes, for a token of its own.
    case pair(code: String, device: String)
    /// The four below are only accepted from the host's own machine.
    /// Asks for a new pairing code. Any earlier code stops working.
    case createPairingCode
    case cancelPairingCode
    case listDevices
    /// Takes a device's token away and disconnects it.
    case revokeDevice(id: String)
    case list
    /// Asks which agent CLIs are installed on the host.
    case agents(refresh: Bool)
    /// Starts a session and attaches the sender to it.
    case create(CreateRequest)
    /// Starts receiving a session. Watching does not change the session's
    /// size, unless nobody else is attached. `have` is how far into the
    /// session's output the sender's terminal already is, as `replaying`
    /// and what followed it told: the host then sends only what came after,
    /// when it still keeps that. Nil for a terminal that starts empty.
    /// `history` is how many of the lines above the screen to send, the
    /// nearest ones; nil for all of them. A phone opens a long session with
    /// a few hundred and attaches again with more as it scrolls up.
    case attach(session: SessionID, size: TermSize, have: Int? = nil, history: Int? = nil)
    case detach(session: SessionID)
    /// Reports that the sender's own grid changed (a window was resized, a
    /// keyboard appeared). The session follows only if the sender is the one
    /// driving it.
    case resize(session: SessionID, size: TermSize)
    /// The user is using the session on this client: it becomes the driver
    /// and the session takes its size.
    case takeControl(session: SessionID, size: TermSize)
    case kill(session: SessionID)
    /// Adds a project folder to the list every client shares.
    case addFolder(path: String)
    case removeFolder(path: String)
    /// Puts a listed folder just before another, or last when `before` is nil.
    case moveFolder(path: String, before: String?)
    /// Asks for a folder's uncommitted git changes, without the diffs.
    case diff(path: String)
    /// Asks for the diff of one changed file: the staged part of it, or
    /// what is only in the working tree.
    case diffFile(path: String, file: String, staged: Bool)
    /// Stages files for the next commit. No files means every change.
    /// Answered with the folder's changes, as `diff` is.
    case gitStage(path: String, files: [String])
    /// Takes files out of the next commit. No files means all of them.
    case gitUnstage(path: String, files: [String])
    /// Throws away changes that are not staged (#39): a file git tracks goes
    /// back to what is staged or to the last commit, one it does not track
    /// yet goes to the Mac's Trash. No files means every such change.
    case gitDiscard(path: String, files: [String])
    /// Asks for the repository's branches, its own and its remotes' (#35).
    /// Answered with `gitBranches`.
    case gitBranches(path: String)
    /// Checks a branch out. A remote's (`origin/feature`) is checked out as
    /// a branch of the repository's own that follows it, made if there is
    /// none. Refused, in words, when changes that are not committed would
    /// be lost. Answered with `gitBranches` and the folder's changes.
    case gitSwitch(path: String, branch: String)
    /// Makes a branch from another branch or a commit (`from`, the checked
    /// out commit when nil), and checks it out when asked.
    case gitCreateBranch(path: String, name: String, from: String?, checkout: Bool)
    case gitRenameBranch(path: String, from: String, to: String)
    /// Deletes a branch of the repository's own. One with commits that are
    /// on no other branch is deleted only with `force`.
    case gitDeleteBranch(path: String, name: String, force: Bool)
    /// Stages, unstages or discards a part of one file's change (#40): one
    /// hunk of its diff, or lines of one. `patch` is that part as a patch
    /// (`PatchParts.patch`), and `use` what it is applied for: "stage",
    /// "unstage" or "discard". Answered with the folder's changes.
    case gitApplyPart(path: String, file: String, patch: String, use: String)
    /// Asks for the commit the checked out branch is at (#41). Answered
    /// with `gitLastCommit`.
    case gitLastCommit(path: String)
    /// Replaces the last commit by one with this message and with what is
    /// staged now added to it. An empty message keeps the one it has.
    case gitAmend(path: String, message: String)
    /// Takes the last commit back and leaves what it changed staged.
    case gitUndoCommit(path: String)
    /// Asks for what is in the repository's stash (#38), newest first.
    /// Answered with `gitStashes`.
    case gitStashes(path: String)
    /// Puts the changes aside: what is staged and what is not, and with
    /// `untracked` the files git does not track yet. `message` names it;
    /// empty, git names it after the last commit.
    case gitStash(path: String, message: String, untracked: Bool)
    /// Asks what a stash holds: its files, each with its diff. `hash`
    /// names the stash (`StashInfo.hash`). Answered with `gitStashShow`.
    case gitStashShow(path: String, hash: String)
    /// Brings what a stash holds back into the folder. With `pop` the
    /// stash is dropped once that worked; when it conflicts, it is kept.
    case gitStashApply(path: String, hash: String, pop: Bool)
    /// Throws a stash away. Sent only after the user was asked.
    case gitStashDrop(path: String, hash: String)
    /// Asks for commits of a branch (#36), the checked out one when nil,
    /// newest first: `limit` of them after the first `skip`. Answered with
    /// `gitLog`.
    case gitLog(path: String, branch: String?, skip: Int, limit: Int)
    /// Asks for a commit's message and what it changed. Answered with `gitShow`.
    case gitShow(path: String, hash: String)
    /// Makes a commit on the checked out branch that takes back what the
    /// named one changed. One that conflicts is undone, and says so.
    case gitRevert(path: String, hash: String)
    /// Makes the change of the named commit on the checked out branch too.
    /// One that conflicts is undone, and says so.
    case gitCherryPick(path: String, hash: String)
    /// Commits what is staged.
    case gitCommit(path: String, message: String)
    /// Pushes the branch that is checked out to its upstream. A branch
    /// without one is pushed to the remote the folder's changes name
    /// (`DiffSnapshot.pushRemote`), which becomes its upstream. Answered
    /// with the folder's changes, as `diff` is.
    ///
    /// With `force` true, what the upstream has and the branch has not is
    /// overwritten (`--force-with-lease`): sent only after the user was
    /// told what that is (`gitForcePushPreview`).
    case gitPush(path: String, force: Bool? = nil)
    /// Brings in what the upstream has: the way the repository is set up
    /// to (`mode` nil or "default"), by "merge" or by "rebase" (#37). A
    /// pull that conflicts is undone.
    case gitPull(path: String, mode: String? = nil)
    /// Asks the remotes for what is new, without changing the branch or the
    /// files (#37). `automatic` when no one asked: the app does it every
    /// few minutes while the folder is shown. Answered with `gitFetched`,
    /// then the folder's changes.
    case gitFetch(path: String, automatic: Bool)
    /// Asks what a forced push would overwrite. Answered with
    /// `gitForcePushPreview`.
    case gitForcePushPreview(path: String)
    /// Asks an agent to write the commit message for what is staged.
    /// Answered with `commitMessage`. It never commits.
    case writeCommitMessage(path: String)
    /// Stops the agent that is writing a commit message for the folder.
    case cancelCommitMessage(path: String)
    /// Replaces which agent writes commit messages, and how it is asked.
    case setCommitWriter(CommitWriterSettings)
    /// Asks for what the agents' accounts have used and have left. With
    /// `refresh`, the agents' services are asked again first.
    case accountUsage(refresh: Bool)
    /// Replaces how the tabs are arranged: order, pins and groups. The host
    /// keeps it and passes it on, so the Mac and the phones show the same.
    case setTabLayout(TabLayout)
    /// Has the host start when the user logs in to the Mac, or not. Answered
    /// with `startAtLogin` to every client.
    case setStartAtLogin(Bool)
    /// Keep the Mac awake while sessions are running, or stop doing so.
    case setKeepAwake(Bool)
    /// Replaces how the Mac is kept awake: the display too, only on power,
    /// and for how long. `until` is the host's to set and is ignored here.
    case setKeepAwakeOptions(KeepAwakeOptions)
    /// Replaces how things are shown on every device: the temperature's
    /// unit, diffs in one panel or two, changes as a list or a tree.
    case setDisplaySettings(DisplaySettings)
    /// Asks for the hosts of the Mac's SSH configuration. Answered with `sshHosts`.
    case sshHosts
    /// Opens `ssh <host>` in a new session the sender is attached to. The
    /// host has to be one the Mac's SSH configuration names.
    case connectSSH(host: String, size: TermSize)
    /// Asks for the files and folders in a folder. Answered with `files`.
    case files(path: String)
    /// Asks for what a file holds. Answered with `file`.
    /// `anyway`: a text file over the size the editor opens by itself, up
    /// to `FileContent.largestOpenedAnyway`, which the user asked for.
    case readFile(path: String, anyway: Bool? = nil)
    /// Replaces a file's text. Answered with `fileSaved`.
    case writeFile(path: String, text: String)
    /// Creates an empty file or a folder. Answered with `fileCreated`, then
    /// with `files` for the folder it is in.
    case createFile(directory: String, name: String, isDirectory: Bool)
    /// Gives a file or folder another name in the same place. Answered with
    /// `files` for the folder it is in.
    case renameFile(path: String, name: String)
    /// Moves a file or folder to the Mac's Trash. Answered with `files`.
    case trashFile(path: String)
    /// Asks for the conversations agents had in a folder, or everywhere on
    /// the host when `path` is nil.
    case history(path: String?)
    /// Reopens a conversation in its agent, in a new session the sender is attached to.
    case resume(agent: String, sessionID: String, cwd: String, size: TermSize)
    /// Asks what the receiving agent would be told when a conversation of
    /// `agent` is handed off, so the prompt can be shown and edited first.
    case handoffPlan(agent: String)
    /// Hands a conversation's work to `target`, in a new session the sender
    /// is attached to. `plan` is the id of a plan that was shown; `prompt`
    /// replaces that plan's prompt when the user edited it.
    /// `folder` is where the receiving agent starts. Nil means the folder
    /// the conversation happened in.
    case handoff(agent: String, sessionID: String, cwd: String, target: String, plan: String?, prompt: String?, note: String, size: TermSize, folder: String?)
    /// Asks which folders are inside a folder, or inside home when `path` is nil.
    case listDirectory(path: String?)
    /// The user has seen the report of a part that stopped: it is no longer
    /// sent, to this client or any other. Answered with `failures` to all.
    case dismissFailure(id: String)
    /// An agent's request about the shells it opened (#10): sent by
    /// `agenttermd mcp`, with the key of the agent's session. Answered with
    /// `agentShellResult` to that client only.
    case agentShell(id: Int, key: String, request: AgentShellRequest)
    /// Installs the MCP server in each agent's configuration, or removes it.
    case setAgentShells(Bool)
    /// Asks the agents to run their commands in shells the user sees,
    /// opened through the MCP server, rather than in their own (on by default).
    case setAgentsUseShells(Bool)
    /// A reply to an agent where it was told of (#22): typed into the
    /// session, then Return, only while its agent is still in `to`, the
    /// state the reply answers. One that comes after it moved on is dropped.
    case answer(session: SessionID, to: AgentState, text: String)
    /// The Mac app is in front, or is no longer: then the Mac is in use.
    case appInFront(Bool)
    /// The user opened this session on this device while its agent was
    /// done or waited, in `state`: what it was told about is seen (#60).
    /// The host passes it on to the other devices, which hide their notice
    /// of it.
    case noticeSeen(session: SessionID, state: AgentState)
    /// Someone used the Mac app: a key or a click in its window. The Mac
    /// is then in use again after a device was used.
    case used
    /// Adds a schedule, or changes the one with its id (#11). One that
    /// skips permissions is refused unless its warning was accepted.
    case saveSchedule(Schedule)
    case removeSchedule(id: String)
    /// Starts a session in a new git worktree of `request.cwd`, on a branch
    /// of its own cut from the folder's current commit (#23). Nil `branch`
    /// names it after the agent.
    case createInWorktree(request: CreateRequest, branch: String?)
    /// The worktrees of a folder's repository (#23, #33). Answered with `worktrees`.
    case listWorktrees(folder: String)
    /// Merges, opens a pull request for, or throws away a worktree, and
    /// removes it (but for a pull request), its branch too when asked.
    case finishWorktree(folder: String, path: String, finish: WorktreeFinish, deleteBranch: Bool)
    /// The command a folder runs in each new worktree before its agent
    /// (`npm install`); nil or empty for none.
    case setWorktreeSetup(folder: String, command: String?)
}

/// JSON text frames sent by the host.
public enum ServerMessage: Codable, Equatable, Sendable {
    case welcome(version: Int, host: String)
    case sessions([SessionInfo])
    case agents([AgentInfo])
    /// Project folders on the host, in the order they were added.
    case folders([String])
    case attached(SessionInfo)
    /// Sent after `attached`, before the session's earlier output: where in
    /// the session's output what follows starts. It is the `have` the
    /// client attached with when the host could go on from there. Any other
    /// number means all that is kept comes again, for a terminal that
    /// starts empty. `above` is how many lines the host keeps above the
    /// screen, whether or not all of them follow.
    case replaying(session: SessionID, from: Int, above: Int? = nil)
    /// Sent after `attached` and the session's earlier output that follows
    /// it: everything before this was a replay of what already happened.
    case replayed(session: SessionID)
    /// The PTY now has this size. `driver` is true when the receiving client
    /// is the one whose size was chosen.
    case resized(session: SessionID, size: TermSize, driver: Bool)
    case exited(session: SessionID, status: Int32)
    case error(String)
    /// Answer to `pair`: the token this device connects with from now on.
    case paired(device: String, token: String)
    /// Answer to `createPairingCode`.
    case pairingCode(code: String, expiresAt: Date)
    /// The paired devices. Sent to the host's own machine when they change.
    case devices([DeviceInfo])
    case diff(path: String, snapshot: DiffSnapshot)
    /// The commit the checked out branch is at; nil for a repository
    /// without a commit.
    case gitLastCommit(path: String, last: LastCommit?)
    /// What is in the repository's stash, newest first.
    case gitStashes(path: String, stashes: [StashInfo])
    /// The files a stash holds, each with its diff. `files` nil when the
    /// stash is no longer there.
    case gitStashShow(path: String, hash: String, files: [FileDiff]?)
    /// Commits of `branch` (the checked out one when nil), newest first,
    /// after the first `skip`; `more` when there are older ones still.
    case gitLog(path: String, branch: String?, skip: Int, commits: [CommitInfo], more: Bool)
    /// A commit's message and what it changed. `details` nil when there is
    /// no such commit.
    case gitShow(path: String, hash: String, details: CommitDetails?)
    /// A fetch is over: `problem` is what git said when it failed. One that
    /// was `automatic` is not to interrupt anyone with it.
    case gitFetched(path: String, problem: String?, automatic: Bool)
    /// What a forced push of the checked out branch would overwrite on
    /// `upstream`: the commits it has and the branch has not, newest
    /// first, as of now. `upstream` nil when there is nothing to push to,
    /// or the remote could not be asked.
    case gitForcePushPreview(path: String, upstream: String?, loses: [String])
    /// The repository's branches: its own, the checked out one first, then
    /// its remotes'. None for a folder that is not a repository.
    case gitBranches(path: String, branches: [BranchInfo])
    /// `file` is nil when it no longer has changes.
    case diffFile(path: String, file: FileDiff?)
    case history(path: String?, conversations: [Conversation])
    case directory(DirectoryListing)
    /// Answer to `handoffPlan`: the prompt, and an id to hand off with.
    case handoffPlan(id: String, prompt: String)
    /// What the accounts of the agents in use have used and have left. Sent
    /// when asked for and whenever it changes.
    case accountUsage([AccountUsage])
    /// How the tabs are arranged. Sent on connecting and when a client changes it.
    case tabLayout(TabLayout)
    /// Whether the Mac is kept awake while sessions are running. Sent on
    /// connecting and when a client changes it.
    case keepAwake(Bool)
    /// How the Mac is kept awake. Sent with `keepAwake`.
    case keepAwakeOptions(KeepAwakeOptions)
    /// Which agent writes commit messages, and how it is asked. Sent on
    /// connecting and when a client changes it.
    case commitWriter(CommitWriterSettings)
    /// Answer to `writeCommitMessage`. `message` is nil when the agent was
    /// stopped or failed; an `error` says why before it.
    case commitMessage(path: String, message: String?)
    /// How things are shown, the same on every device. Sent on connecting
    /// and when a client changes it. Nil from a host that keeps none yet:
    /// the client then hands it its own.
    case displaySettings(DisplaySettings?)
    /// The hosts the Mac's SSH configuration names, as they are written there.
    case sshHosts([String])
    /// Whether the host starts when the user logs in to the Mac. Sent on
    /// connecting and when a client changes it, by a host that can do it.
    case startAtLogin(Bool)
    /// A push or a pull in a folder is over, whether git took it or not.
    /// Sent after the `error` and the `diff` that answer it: a `diff` alone
    /// may be the answer to something else asked in the meantime.
    case gitSynced(path: String)
    /// How the Mac itself is doing: processor, memory, network, heat,
    /// battery and uptime. Sent every few seconds while a client is connected.
    case systemStats(SystemStats)
    /// The files and folders in a folder.
    case files(path: String, entries: [FileEntry])
    /// What a file holds. `data` carries the bytes of an image.
    case file(path: String, content: FileContent, data: Data?)
    case fileSaved(path: String)
    case fileCreated(path: String, isDirectory: Bool)
    /// The parts of AgentTerm that stopped without being asked to and that
    /// the user has not seen yet, oldest first. Sent on connecting and
    /// whenever the list changes.
    case failures([PartFailure])
    case agentShellResult(id: Int, result: AgentShellResult)
    /// Whether the MCP server is installed in the agents' configuration.
    /// Not sent by a host that does not install it (a test's, a trial run).
    case agentShells(Bool)
    /// Whether the agents are asked to run their commands in shells the user sees.
    case agentsUseShells(Bool)
    /// What keeps the agents from opening shells although that is on
    /// (#58); none when nothing does. Sent on connecting and whenever it
    /// changes.
    case agentShellsFaults([AgentShellsFault])
    /// Whether someone is at the Mac (#22, #24): its app in front, or a key
    /// or the pointer used in the last five minutes; and not since a device
    /// (an iPhone, another Mac) was used, until the Mac app is used again.
    case macInUse(Bool)
    /// What this session's agent said or asks, in `state`, was seen on
    /// another device (#60): a notice of it is hidden here too. Also sent
    /// on connecting, for what was seen while this device was away.
    case noticeSeen(session: SessionID, state: AgentState)
    /// Every schedule, with its last runs and when it runs next.
    case schedules([Schedule])
    /// A folder's worktrees, the folder's own first, and its setup command.
    case worktrees(folder: String, list: [WorktreeInfo], setup: String?)
    /// What became of `finishWorktree`: a pull request's address, or that
    /// it was merged or removed.
    case worktreeFinished(folder: String, path: String, said: String)
}

public enum MessageCoding {
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    public static func encode<T: Encodable>(_ value: T) -> Data {
        // Encoding these plain value types cannot fail.
        (try? encoder.encode(value)) ?? Data()
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        try? decoder.decode(type, from: data)
    }
}
