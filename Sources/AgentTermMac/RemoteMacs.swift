import AgentTermProtocol
import Foundation
import Security

/// Another Mac this app is paired with, and the token it connects to it
/// with. The app then shows that Mac's sessions, folders, changes and
/// files, the way the iPhone does.
struct RemoteMac: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var host: String
    var port: UInt16
    /// This Mac's own token for that one, given when pairing. The other
    /// Mac can take it away without affecting its other devices.
    var token: String
}

/// Keeps the paired Macs in the Keychain, since the tokens grant shell
/// access. A host that keeps its files in a folder of its own, a test or a
/// trial run, keeps these there too, and leaves the Keychain alone.
enum RemoteMacStore {
    private static let account = "remote-macs"

    private static var file: URL? {
        guard let folder = ProcessInfo.processInfo.environment["AGENTTERM_STATE_DIR"], !folder.isEmpty else { return nil }
        return URL(fileURLWithPath: folder, isDirectory: true).appendingPathComponent("remote-macs.json")
    }

    private static var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: AppChannel.current.bundleIdentifier,
            kSecAttrAccount as String: account,
        ]
    }

    static func load() -> [RemoteMac] {
        let data: Data?
        if let file {
            data = try? Data(contentsOf: file)
        } else {
            var request = query
            request[kSecReturnData as String] = true
            request[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            data = SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess ? result as? Data : nil
        }
        return data.flatMap { try? JSONDecoder().decode([RemoteMac].self, from: $0) } ?? []
    }

    @discardableResult
    static func save(_ macs: [RemoteMac]) -> Bool {
        guard let data = try? JSONEncoder().encode(macs) else { return false }
        if let file {
            do {
                try data.write(to: file, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                return true
            } catch {
                return false
            }
        }
        SecItemDelete(query as CFDictionary)
        guard !macs.isEmpty else { return true }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
}
