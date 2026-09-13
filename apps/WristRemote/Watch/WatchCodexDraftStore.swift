import Foundation
import Security

/// Device-local protected storage for a user-confirmed Codex draft.
///
/// The store deliberately has no synchronizable or access-group attributes, so
/// draft text never leaves this Watch through iCloud Keychain. Values are only
/// readable while the device is unlocked.
enum WatchCodexDraftStore {
    enum LoadResult<Value> {
        case loaded(Value)
        case notFound
        case unavailable
    }

    private static let account = "pending-codex-draft-v2"

    static func load<T: Decodable>(_ type: T.Type) -> LoadResult<T> {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return .notFound }
        guard status == errSecSuccess,
              let data = result as? Data,
              let decoded = try? JSONDecoder().decode(type, from: data)
        else { return .unavailable }
        return .loaded(decoded)
    }

    @discardableResult
    static func save<T: Encodable>(_ value: T) -> Bool {
        guard let data = try? JSONEncoder().encode(value) else { return false }
        let update = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }

        var insertion = baseQuery
        insertion[kSecValueData as String] = data
        insertion[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        insertion[kSecAttrSynchronizable as String] = false
        return SecItemAdd(insertion as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func delete() -> Bool {
        let status = SecItemDelete(baseQuery as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String:
                "\(Bundle.main.bundleIdentifier ?? "dev.wristremote.watch").codex-draft",
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
    }
}
