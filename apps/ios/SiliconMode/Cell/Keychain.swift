import Foundation
import Security

/// Generic-password Keychain items for this app, readable after first unlock on this device only
/// (never synced, never restored onto another phone).
enum Keychain {
    private static let service = "ai.tos.mode.ios"

    private static func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func data(_ account: String) -> Data? {
        var q = base(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    @discardableResult
    static func set(_ data: Data, for account: String) -> Bool {
        let q = base(account)
        let attrs: [String: Any] = [kSecValueData as String: data,
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(q as CFDictionary, attrs as CFDictionary)
        if status == errSecSuccess { return true }
        var item = q
        item.merge(attrs) { $1 }
        SecItemDelete(q as CFDictionary)
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func delete(_ account: String) {
        SecItemDelete(base(account) as CFDictionary)
    }

    static func load<T: Decodable>(_ type: T.Type, _ account: String) -> T? {
        data(account).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    @discardableResult
    static func save<T: Encodable>(_ value: T, _ account: String) -> Bool {
        guard let d = try? JSONEncoder().encode(value) else { return false }
        return set(d, for: account)
    }

    /// A random id per install of this app (identifies this iPhone in `devices`), kept across launches.
    static func installID() -> String {
        if let d = data("install_id"), let s = String(data: d, encoding: .utf8), !s.isEmpty { return s }
        let s = UUID().uuidString.lowercased()
        set(Data(s.utf8), for: "install_id")
        return s
    }
}
