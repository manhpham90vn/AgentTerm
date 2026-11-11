import AgenttyProtocol
import Foundation
import Security

/// Keeps the paired Mac in the Keychain. The pairing link contains the token
/// that grants shell access, so it does not belong in preferences.
enum PairingStore {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "click.manhdev.agentty",
        kSecAttrAccount as String: "pairing",
    ]

    static func load() -> PairingInfo? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let url = URL(string: String(decoding: data, as: UTF8.self))
        else { return nil }
        return PairingInfo(url: url)
    }

    @discardableResult
    static func save(_ info: PairingInfo) -> Bool {
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = Data(info.url.absoluteString.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func clear() {
        SecItemDelete(query as CFDictionary)
    }
}
