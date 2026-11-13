import Foundation

/// Binary WebSocket frame carrying raw terminal bytes.
///
/// Layout: 1 byte kind, 4 bytes session id (big endian), then the payload.
public struct DataFrame: Equatable, Sendable {
    public enum Kind: UInt8, Sendable {
        /// Host to client: bytes written by the program in the PTY.
        case output = 0
        /// Client to host: keystrokes and pasted text.
        case input = 1
        /// Host to client: a piece of a message too large for one frame
        /// (`MessageParts`); `session` numbers the message.
        case messagePart = 2
        /// The last piece: the message can be read.
        case messageEnd = 3
    }

    public var kind: Kind
    public var session: SessionID
    public var payload: Data

    public init(kind: Kind, session: SessionID, payload: Data) {
        self.kind = kind
        self.session = session
        self.payload = payload
    }

    public static let headerSize = 5

    public func encoded() -> Data {
        var data = Data(capacity: Self.headerSize + payload.count)
        data.append(kind.rawValue)
        withUnsafeBytes(of: session.bigEndian) { data.append(contentsOf: $0) }
        data.append(payload)
        return data
    }

    public init?(decoding data: Data) {
        guard data.count >= Self.headerSize else { return nil }
        let bytes = [UInt8](data.prefix(Self.headerSize))
        guard let kind = Kind(rawValue: bytes[0]) else { return nil }
        self.kind = kind
        self.session = bytes[1...4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        self.payload = data.dropFirst(Self.headerSize)
        // Rebase so callers can index from zero.
        self.payload = Data(self.payload)
    }
}

/// A message larger than `limit` is sent as pieces, each a frame of its own,
/// one after the other, so that nothing sent is larger than that (#21): a
/// folder's list, a file, a diff. The receiver joins them before reading.
public enum MessageParts {
    /// The largest frame sent, header included.
    public static let limit = 256 * 1024

    /// The frames for a message, or nil when it fits in one.
    public static func frames(for data: Data, id: UInt32) -> [DataFrame]? {
        guard data.count > limit else { return nil }
        let size = limit - DataFrame.headerSize
        var frames: [DataFrame] = []
        var start = data.startIndex
        while start < data.endIndex {
            let end = data.index(start, offsetBy: size, limitedBy: data.endIndex) ?? data.endIndex
            frames.append(DataFrame(kind: end == data.endIndex ? .messageEnd : .messagePart, session: id, payload: Data(data[start..<end])))
            start = end
        }
        return frames
    }

    /// Joins the pieces of the messages that arrive.
    public struct Joiner: Sendable {
        private var id: UInt32?
        private var pieces = Data()

        public init() {}

        /// The whole message once its last piece came, nil before.
        public mutating func add(_ frame: DataFrame) -> Data? {
            guard frame.kind == .messagePart || frame.kind == .messageEnd else { return nil }
            // Pieces of another message: what came before is not whole.
            if id != frame.session {
                id = frame.session
                pieces = Data()
            }
            pieces.append(frame.payload)
            guard frame.kind == .messageEnd else { return nil }
            defer {
                id = nil
                pieces = Data()
            }
            return pieces
        }
    }
}
