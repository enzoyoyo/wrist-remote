import Foundation
import Security

enum WristBridgeTrustedServerIdentityStore {
    enum LoadResult: Equatable {
        case notFound
        case loaded(String)
        case unavailable
    }

    private static let account = "trusted-server-fingerprint-v1"
    private static var service: String {
        "\(Bundle.main.bundleIdentifier ?? "dev.wristremote.ios").trusted-server-identity"
    }

    static func load() -> LoadResult {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return .notFound }
        guard status == errSecSuccess,
              let data = result as? Data,
              let fingerprint = String(data: data, encoding: .utf8),
              isValidFingerprint(fingerprint)
        else { return .unavailable }
        return .loaded(fingerprint)
    }

    @discardableResult
    static func save(_ fingerprint: String) -> Bool {
        guard isValidFingerprint(fingerprint),
              let data = fingerprint.data(using: .utf8)
        else { return false }
        switch load() {
        case let .loaded(existing):
            return existing == fingerprint
        case .unavailable:
            return false
        case .notFound:
            break
        }
        var insert = baseQuery
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(insert as CFDictionary, nil)
        if status == errSecSuccess { return true }
        guard status == errSecDuplicateItem,
              case let .loaded(existing) = load()
        else { return false }
        return existing == fingerprint
    }

    @discardableResult
    static func delete() -> Bool {
        let status = SecItemDelete(baseQuery as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    static func isValidFingerprint(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
