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
