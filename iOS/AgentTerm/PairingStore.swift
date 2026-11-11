import Foundation
import Security

/// A Mac this iPhone is paired with, and the token it connects to it with.
struct SavedHost: Codable, Equatable, Identifiable {
    var id: String
    var host: String
    var port: UInt16
    var name: String
    /// This device's own token for that Mac, given when pairing. The Mac can
    /// revoke it without affecting other devices.
    var token: String
}

/// Keeps the paired Macs in the Keychain, since the tokens grant shell access.
enum PairingStore {
    private static func query(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.manhpham.agentterm",
            kSecAttrAccount as String: account,
        ]
    }

    private static func read(account: String) -> Data? {
        var request = query(account: account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func load() -> [SavedHost] {
        if let data = read(account: "hosts"), let hosts = try? JSONDecoder().decode([SavedHost].self, from: data) {
            return hosts
        }
        // Builds that paired with a single Mac kept it under another name.
        struct Single: Codable {
            var host: String
            var port: UInt16
            var name: String
            var token: String
        }
        guard let data = read(account: "host"), let old = try? JSONDecoder().decode(Single.self, from: data) else { return [] }
        let migrated = [SavedHost(id: UUID().uuidString, host: old.host, port: old.port, name: old.name, token: old.token)]
        save(migrated)
        SecItemDelete(query(account: "host") as CFDictionary)
        return migrated
    }

    @discardableResult
    static func save(_ hosts: [SavedHost]) -> Bool {
        SecItemDelete(query(account: "hosts") as CFDictionary)
        guard !hosts.isEmpty, let data = try? JSONEncoder().encode(hosts) else { return true }
        var item = query(account: "hosts")
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
}
