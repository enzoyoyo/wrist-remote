import CryptoKit
import Foundation
import Security

enum WristRemoteServerIdentityStore {
    enum StorageAction: Equatable {
        case useStored
        case create
        case reject
    }

    private static let account = "p256-signing-v1"
    private static var service: String {
        "\(Bundle.main.bundleIdentifier ?? "dev.wristremote.bridge").server-identity"
    }

    static func loadOrCreate() -> P256.Signing.PrivateKey? {
        let stored = storedData()
        let storedKey = stored.data.flatMap {
            try? P256.Signing.PrivateKey(rawRepresentation: $0)
        }
        switch storageAction(
            copyStatus: stored.status,
            hasStoredData: stored.data != nil,
            hasValidKey: storedKey != nil
        ) {
        case .useStored:
            return storedKey
        case .create:
            return createKey()
        case .reject:
            // A locked/unavailable Keychain or corrupt identity must never
            // silently rotate a server identity already pinned by the iPhone.
            return nil
        }
    }

    static func storageAction(
        copyStatus: OSStatus,
        hasStoredData: Bool,
        hasValidKey: Bool
    ) -> StorageAction {
        if copyStatus == errSecSuccess {
            return hasStoredData && hasValidKey ? .useStored : .reject
        }
        return copyStatus == errSecItemNotFound ? .create : .reject
    }

    private static func createKey() -> P256.Signing.PrivateKey? {
        let key = P256.Signing.PrivateKey()
        var attributes = baseQuery
        attributes[kSecValueData as String] = key.rawRepresentation
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecSuccess { return key }
        guard status == errSecDuplicateItem else { return nil }
        let stored = storedData()
        guard stored.status == errSecSuccess, let data = stored.data else { return nil }
        return try? P256.Signing.PrivateKey(rawRepresentation: data)
    }

    private static func storedData() -> (status: OSStatus, data: Data?) {
        var lookup = baseQuery
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        return (status, result as? Data)
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
