import Foundation

/// Version of the wire protocol. Bumped on incompatible changes.
public let agenttyProtocolVersion = 2

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

    public init(id: SessionID, title: String, cwd: String, size: TermSize, createdAt: Date) {
        self.id = id
        self.title = title
        self.cwd = cwd
        self.size = size
        self.createdAt = createdAt
    }
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
