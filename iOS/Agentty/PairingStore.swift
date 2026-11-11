import Foundation
import Security

/// The Mac this iPhone is paired with, and the token it connects with.
struct SavedHost: Codable, Equatable {
    var host: String
    var port: UInt16
    var name: String
    /// This device's own token, given by the Mac when pairing. The Mac can
    /// revoke it without affecting other devices.
    var token: String
}

/// Keeps the paired Mac in the Keychain, since the token grants shell access.
enum PairingStore {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "click.manhdev.agentty",
        kSecAttrAccount as String: "host",
    ]

    static func load() -> SavedHost? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(SavedHost.self, from: data)
    }

    @discardableResult
    static func save(_ host: SavedHost) -> Bool {
        guard let data = try? JSONEncoder().encode(host) else { return false }
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func clear() {
        SecItemDelete(query as CFDictionary)
    }
}
