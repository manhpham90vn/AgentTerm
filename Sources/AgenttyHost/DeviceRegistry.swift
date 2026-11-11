#if os(macOS)
import AgenttyProtocol
import CryptoKit
import Foundation

/// Who may talk to the host: the Mac itself, and devices that were paired.
///
/// - The **local token** belongs to the Mac. It is only honored on
///   connections that arrive on the loopback interface, so it is useless to
///   anyone who is not already on the Mac.
/// - A **pairing code** is shown as a QR code or link. It works once, for a
///   few minutes, and only to obtain a device token.
/// - A **device token** is made for one device when it pairs, and can be
///   revoked. Only its SHA-256 is stored, so the file does not hold anything
///   that can be used to connect.
///
/// Not thread safe: the host server uses it from its own queue.
public final class DeviceRegistry {
    public enum Identity: Equatable {
        /// The Mac's own apps, allowed to pair and revoke devices.
        case local
        case device(id: String)
    }

    public static let codeLifetime: TimeInterval = 5 * 60

    private struct Record: Codable {
        var id: String
        var name: String
        var tokenHash: String
        var pairedAt: Date
        var lastSeenAt: Date?
    }

    private let localToken: String
    private let file: URL?
    private let now: () -> Date
    private var records: [Record] = []
    private var code: (value: String, expiresAt: Date)?

    public init(localToken: String, file: URL?, now: @escaping () -> Date = Date.init) {
        self.localToken = localToken
        self.file = file
        self.now = now
        if let file, let data = try? Data(contentsOf: file) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            records = (try? decoder.decode([Record].self, from: data)) ?? []
        }
    }

    // MARK: Pairing codes

    /// Makes a new code and forgets any earlier one.
    public func createCode() -> (code: String, expiresAt: Date) {
        let created = (value: Self.randomToken(), expiresAt: now().addingTimeInterval(Self.codeLifetime))
        code = created
        return (created.value, created.expiresAt)
    }

    public func cancelCode() {
        code = nil
    }

    /// Trades a valid code for a new device and its token. The code is used
    /// up whether or not another device tries it afterwards.
    public func redeem(code attempt: String, deviceName: String) -> (device: DeviceInfo, token: String)? {
        guard let code, now() < code.expiresAt, Self.constantTimeEquals(attempt, code.value) else { return nil }
        self.code = nil
        let token = Self.randomToken()
        let trimmed = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let record = Record(
            id: UUID().uuidString,
            name: trimmed.isEmpty ? "iPhone" : String(trimmed.prefix(60)),
            tokenHash: Self.hash(token),
            pairedAt: now(),
            lastSeenAt: nil
        )
        records.append(record)
        save()
        return (info(record, connected: true), token)
    }

    // MARK: Authentication

    /// - Parameter isLocal: whether the connection arrived on the loopback interface.
    public func authenticate(token: String, isLocal: Bool) -> Identity? {
        if isLocal, Self.constantTimeEquals(token, localToken) { return .local }
        let hash = Self.hash(token)
        guard let index = records.firstIndex(where: { Self.constantTimeEquals($0.tokenHash, hash) }) else { return nil }
        records[index].lastSeenAt = now()
        save()
        return .device(id: records[index].id)
    }

    // MARK: Devices

    public func devices(connected: Set<String> = []) -> [DeviceInfo] {
        records.map { info($0, connected: connected.contains($0.id)) }
    }

    /// Returns false when there is no such device.
    @discardableResult
    public func revoke(_ id: String) -> Bool {
        guard records.contains(where: { $0.id == id }) else { return false }
        records.removeAll { $0.id == id }
        save()
        return true
    }

    private func info(_ record: Record, connected: Bool) -> DeviceInfo {
        DeviceInfo(id: record.id, name: record.name, pairedAt: record.pairedAt, lastSeenAt: record.lastSeenAt, isConnected: connected)
    }

    private func save() {
        guard let file else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(records) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? data.write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    // MARK: Helpers

    /// 32 random bytes as URL-safe text.
    static func randomToken() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
#endif
