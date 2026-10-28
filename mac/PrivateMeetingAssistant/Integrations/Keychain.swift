import Foundation
import Security

/// Linked accounts' sign-in tokens, in the login Keychain rather than in
/// preferences, so they're encrypted at rest and only this app reads them.
enum Keychain {
    private static let service = "dev.ruy.private-meeting-assistant.accounts"

    static func data(_ account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    static func set(_ data: Data?, for account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        guard let data else { return }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func decode<T: Decodable>(_ type: T.Type, _ account: String) -> T? {
        data(account).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    static func encode<T: Encodable>(_ value: T?, for account: String) {
        set(value.flatMap { try? JSONEncoder().encode($0) }, for: account)
    }
}
