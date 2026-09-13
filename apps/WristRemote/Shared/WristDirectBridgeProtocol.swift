import CryptoKit
import Darwin
import Foundation
import Security

/// Public discovery material only. Authentication still uses the signed,
/// encrypted Wrist Bridge handshake; this object never contains a secret.
struct WristDirectBridgeConfiguration: Codable, Equatable {
    static let port = 60_929
    static let route = "/v1/bridge"

    let endpoint: String
    let serverIdentityPublicKey: String
    let serverName: String

    func validated() -> WristDirectBridgeConfiguration? {
        guard endpoint.count <= 512,
              let url = URLComponents(string: endpoint),
              url.scheme == "http",
              url.port == Self.port,
              url.path == Self.route,
              url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil,
              let rawHost = url.host,
              Self.isPrivateLiteral(rawHost),
              Self.isValidServerIdentityPublicKey(serverIdentityPublicKey),
              !serverName.isEmpty, serverName.count <= 80,
              serverName == serverName.trimmingCharacters(in: .whitespacesAndNewlines),
              !serverName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { return nil }
        return self
    }

    static func isValidServerIdentityPublicKey(_ encoded: String) -> Bool {
        guard let raw = Data(base64Encoded: encoded), raw.count == 64,
              raw.contains(where: { $0 != 0 }),
              (try? P256.Signing.PublicKey(rawRepresentation: raw)) != nil
        else { return false }
        var x963 = Data([0x04])
        x963.append(raw)
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits as String: 256,
        ]
        return SecKeyCreateWithData(x963 as CFData, attributes as CFDictionary, nil) != nil
    }

    func encodeBase64() throws -> String {
        guard validated() != nil else { throw WristDirectBridgeProtocolError.invalidConfiguration }
        return try JSONEncoder().encode(self).base64EncodedString()
    }

    static func decodeBase64(_ value: String) throws -> WristDirectBridgeConfiguration {
        guard value.utf8.count <= 2_048,
              let data = Data(base64Encoded: value),
              let configuration = try? JSONDecoder().decode(Self.self, from: data),
              configuration.validated() != nil
        else { throw WristDirectBridgeProtocolError.invalidConfiguration }
        return configuration
    }

    var pairingURL: URL? {
        guard let encoded = try? encodeBase64() else { return nil }
        var url = URLComponents()
        url.scheme = "wristremote"
        url.host = "pair"
        url.queryItems = [URLQueryItem(name: "configuration", value: encoded)]
        return url.url
    }

    static func fromPairingURL(_ value: URL) -> WristDirectBridgeConfiguration? {
        guard let url = URLComponents(url: value, resolvingAgainstBaseURL: false),
              url.scheme == "wristremote", url.host == "pair",
              url.path.isEmpty, url.user == nil, url.password == nil,
              url.port == nil, url.fragment == nil,
              let items = url.queryItems, items.count == 1,
              items[0].name == "configuration", let encoded = items[0].value
        else { return nil }
        return try? decodeBase64(encoded)
    }

    static func isPrivateLiteral(_ value: String) -> Bool {
        var host = value
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        guard !host.contains("%"), !host.contains(" ") else { return false }
        var ipv4 = in_addr()
        if inet_pton(AF_INET, host, &ipv4) == 1 {
            let bytes = withUnsafeBytes(of: ipv4.s_addr) { Array($0) }
            return bytes[0] == 10
                || (bytes[0] == 172 && (16 ... 31).contains(bytes[1]))
                || (bytes[0] == 192 && bytes[1] == 168)
                || (bytes[0] == 169 && bytes[1] == 254)
        }
        var ipv6 = in6_addr()
        guard inet_pton(AF_INET6, host, &ipv6) == 1 else { return false }
        let bytes = withUnsafeBytes(of: ipv6) { Array($0) }
        // ULA only; no public, loopback, mapped or scoped IPv6 address.
        return bytes.count == 16 && (bytes[0] & 0xfe) == 0xfc
    }
}

enum WristDirectBridgeProtocolError: Error {
    case invalidConfiguration
}

struct WristDirectBridgeHTTPRequest: Codable, Equatable {
    let sessionID: String?
    let message: WristBridgeWireMessage
}

struct WristDirectBridgeHTTPResponse: Codable, Equatable {
    let sessionID: String
    let messages: [WristBridgeWireMessage]
}

enum WristDirectBridgeProtocol {
    static let capability = "directBridgeHTTPV1"
    static let buttonTriggerCapability = "buttonTriggerV1"
    static let maximumRequestBodyBytes = 256 * 1_024
    static let maximumResponseBodyBytes = 512 * 1_024
    static let maximumOutboxMessages = 32
    static let buttonCommitLifetimeMilliseconds: Int64 = 5_000

    static func isCanonicalSessionID(_ value: String?) -> Bool {
        guard let value, let id = UUID(uuidString: value) else { return false }
        return id.uuidString == value
    }

    static func isFreshButtonCommit(
        _ message: WristBridgeWireMessage,
        nowEpochMilliseconds: Int64
    ) -> Bool {
        guard message.type == "buttonTrigger",
              isCanonicalSessionID(message.requestID),
              let issued = message.issuedAtEpochMilliseconds,
              issued > 0, issued <= nowEpochMilliseconds,
              nowEpochMilliseconds - issued <= buttonCommitLifetimeMilliseconds,
              let trigger = message.buttonTrigger,
              ["singleClick", "doubleClick", "longPress"].contains(trigger)
        else { return false }
        return true
    }
}
