import Foundation

/// Version of the wire protocol. Bumped on incompatible changes.
public let agenttyProtocolVersion = 4

/// Default TCP port the host daemon listens on.
public let agenttyDefaultPort: UInt16 = 7717

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

    public init(
        id: SessionID, title: String, cwd: String, size: TermSize, createdAt: Date,
        agent: String? = nil, summary: String? = nil, conversationID: String? = nil, usage: SessionUsage? = nil
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
    /// size, unless nobody else is attached.
    case attach(session: SessionID, size: TermSize)
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
    /// Commits what is staged.
    case gitCommit(path: String, message: String)
    /// Asks for what the agents' accounts have used and have left. With
    /// `refresh`, the agents' services are asked again first.
    case accountUsage(refresh: Bool)
    /// Asks for the files and folders in a folder. Answered with `files`.
    case files(path: String)
    /// Asks for what a file holds. Answered with `file`.
    case readFile(path: String)
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
    case handoff(agent: String, sessionID: String, cwd: String, target: String, plan: String?, prompt: String?, note: String, size: TermSize)
    /// Asks which folders are inside a folder, or inside home when `path` is nil.
    case listDirectory(path: String?)
}

/// JSON text frames sent by the host.
public enum ServerMessage: Codable, Equatable, Sendable {
    case welcome(version: Int, host: String)
    case sessions([SessionInfo])
    case agents([AgentInfo])
    /// Project folders on the host, in the order they were added.
    case folders([String])
    case attached(SessionInfo)
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
    /// `file` is nil when it no longer has changes.
    case diffFile(path: String, file: FileDiff?)
    case history(path: String?, conversations: [Conversation])
    case directory(DirectoryListing)
    /// Answer to `handoffPlan`: the prompt, and an id to hand off with.
    case handoffPlan(id: String, prompt: String)
    /// What the accounts of the agents in use have used and have left. Sent
    /// when asked for and whenever it changes.
    case accountUsage([AccountUsage])
    /// The files and folders in a folder.
    case files(path: String, entries: [FileEntry])
    /// What a file holds. `data` carries the bytes of an image.
    case file(path: String, content: FileContent, data: Data?)
    case fileSaved(path: String)
    case fileCreated(path: String, isDirectory: Bool)
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
