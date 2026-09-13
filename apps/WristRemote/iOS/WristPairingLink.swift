import CryptoKit
import Foundation

/// A QR code contains a network address and a public identity, never pairing
/// approval or a device private key. Both devices must still approve the code.
struct WristPairingLink: Codable, Equatable {
    static let port = 60_927
    private static let storageKey = "WristRemote.pairedMacAddress.v1"

    let host: String
    let serverIdentityPublicKey: String
    let serverName: String

    var identityFingerprint: String {
        SHA256.hash(data: Data(base64Encoded: serverIdentityPublicKey) ?? Data())
            .map { String(format: "%02x", $0) }.joined()
    }

    static func parse(_ value: URL) throws -> WristPairingLink {
        guard value.absoluteString.utf8.count <= 4_096,
              let url = URLComponents(url: value, resolvingAgainstBaseURL: false),
              url.scheme == "wristremote", url.host == "pair",
              url.path.isEmpty, url.user == nil, url.password == nil,
              url.port == nil, url.fragment == nil,
              let items = url.queryItems
        else { throw WristPairingLinkError.invalidLink }

        let names = ["version", "host", "port", "identity", "name"]
        guard items.count == names.count,
              Set(items.map(\.name)) == Set(names),
              items.allSatisfy({ $0.value != nil })
        else { throw WristPairingLinkError.invalidLink }
        let fields = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value!) })
        guard fields["version"] == "1", fields["port"] == String(port),
              let host = fields["host"], let key = fields["identity"],
              let name = fields["name"]
        else { throw WristPairingLinkError.invalidLink }
        return try validated(host: host, publicKey: key, serverName: name)
    }

    static func validated(
        host: String,
        publicKey: String,
        serverName: String
    ) throws -> WristPairingLink {
        let normalizedHost = host.hasPrefix("[") && host.hasSuffix("]")
            ? String(host.dropFirst().dropLast()) : host
        let isPrivateHost = WristDirectBridgeConfiguration.isPrivateLiteral(normalizedHost)
            || WristPrivateNetworkHostValidator.normalizedHost(
                normalizedHost, allowMagicDNS: false
            ) == normalizedHost
        guard isPrivateHost, normalizedHost.count <= 80,
              let key = Data(base64Encoded: publicKey), key.count == 64,
              key.base64EncodedString() == publicKey,
              WristDirectBridgeConfiguration.isValidServerIdentityPublicKey(publicKey),
              !serverName.isEmpty, serverName.count <= 80,
              serverName == serverName.trimmingCharacters(in: .whitespacesAndNewlines),
              !serverName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw WristPairingLinkError.invalidLink }
        return WristPairingLink(host: normalizedHost,
                                serverIdentityPublicKey: publicKey,
                                serverName: serverName)
    }

    func matchesIdentity(_ fingerprint: String) -> Bool {
        identityFingerprint == fingerprint
    }

    static func load(defaults: UserDefaults = .standard) -> WristPairingLink? {
        guard let data = defaults.data(forKey: storageKey),
              let target = try? JSONDecoder().decode(Self.self, from: data)
        else { return nil }
        return try? validated(host: target.host, publicKey: target.serverIdentityPublicKey,
                              serverName: target.serverName)
    }

    func save(defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: storageKey)
    }
}

enum WristPairingLinkError: LocalizedError {
    case invalidLink
    case identityMismatch

    var errorDescription: String? {
        switch self {
        case .invalidLink:
            return "配对链接无效。请用 iPhone 相机扫描腕上遥控桥的新二维码，或粘贴完整链接。"
        case .identityMismatch:
            return "二维码中的 Mac 与已信任身份不一致，未更换连接。请核对 Mac；只有确实更换设备时才使用配对管理。"
        }
    }
}

/// A saved numeric address is a one-shot connection hint. It must not suppress
/// Bonjour indefinitely after DHCP or a Wi-Fi change; the identity pin is kept
/// independently by the connection and applies to every discovered endpoint.
struct WristPairingRoutePolicy {
    private(set) var hasTriedAddress = false

    mutating func takeAddressAttempt() -> Bool {
        guard !hasTriedAddress else { return false }
        hasTriedAddress = true
        return true
    }

    mutating func resetForImportedLink() {
        hasTriedAddress = false
    }
}
