import Foundation
import Network

struct WristPrivateNetworkConfiguration: Codable, Equatable, Sendable {
    static let port: UInt16 = 60_927
    static let disabled = WristPrivateNetworkConfiguration(isEnabled: false, host: "")

    let isEnabled: Bool
    let host: String

    private init(isEnabled: Bool, host: String) {
        self.isEnabled = isEnabled
        self.host = host
    }

    static func validated(
        isEnabled: Bool,
        host rawHost: String,
        privateOnly: Bool = WristInternetRelayConfiguration.isPrivateOnlyBuild
    ) -> Result<WristPrivateNetworkConfiguration, WristPrivateNetworkConfigurationError> {
        let trimmed = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return isEnabled ? .failure(.hostRequired) : .success(.disabled)
        }
        guard let host = WristPrivateNetworkHostValidator.normalizedHost(
            trimmed,
            allowMagicDNS: !privateOnly
        ) else {
            if !isEnabled { return .success(.disabled) }
            return .failure(.invalidHost)
        }
        return .success(WristPrivateNetworkConfiguration(
            isEnabled: isEnabled,
            host: host
        ))
    }

    var endpoint: NWEndpoint? {
        guard isEnabled,
              let port = NWEndpoint.Port(rawValue: Self.port)
        else { return nil }
        return .hostPort(host: NWEndpoint.Host(host), port: port)
    }
}

enum WristPrivateNetworkConfigurationError: LocalizedError, Equatable {
    case hostRequired
    case invalidHost
    case storageFailed

    var errorDescription: String? {
        switch self {
        case .hostRequired:
            return "请输入 Mac 的 Tailscale 专用 IP。"
        case .invalidHost:
            return "私有版本只接受 Tailscale 专用 IP，不接受公网地址、端口、URL 或 DNS 名称。"
        case .storageFailed:
            return "无法把私有网络设置安全保存到本机钥匙串。"
        }
    }
}

enum WristPrivateNetworkHostValidator {
    static func normalizedHost(
        _ rawHost: String,
        allowMagicDNS: Bool = true
    ) -> String? {
        var candidate = rawHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while candidate.hasSuffix(".") { candidate.removeLast() }
        guard !candidate.isEmpty,
              candidate.utf8.count <= 253,
              !candidate.contains(where: { $0.isWhitespace }),
              !candidate.contains("://"),
              !candidate.contains("/"),
              !candidate.contains("@"),
              !candidate.contains("%")
        else { return nil }

        if let address = IPv4Address(candidate) {
            return isTailscaleIPv4([UInt8](address.rawValue)) ? candidate : nil
        }
        if let address = IPv6Address(candidate) {
            return isTailscaleIPv6([UInt8](address.rawValue)) ? candidate : nil
        }
        guard allowMagicDNS,
              candidate.hasSuffix(".ts.net"),
              isValidDNSName(candidate)
        else {
            return nil
        }
        // A full MagicDNS name contains at least a machine label, a tailnet
        // label, and the fixed `ts.net` suffix. Requiring the FQDN avoids
        // ambiguous public DNS and can trigger Tailscale VPN On Demand.
        guard candidate.split(separator: ".", omittingEmptySubsequences: false).count >= 4 else {
            return nil
        }
        return candidate
    }

    static func isTailscaleIPv4(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 4 else { return false }
        return bytes[0] == 100 && (64 ... 127).contains(bytes[1])
    }

    static func isTailscaleIPv6(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return false }
        return bytes[0] == 0xfd
            && bytes[1] == 0x7a
            && bytes[2] == 0x11
            && bytes[3] == 0x5c
            && bytes[4] == 0xa1
            && bytes[5] == 0xe0
    }

    private static func isValidDNSName(_ host: String) -> Bool {
        host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            guard !label.isEmpty,
                  label.utf8.count <= 63,
                  label.first != "-",
                  label.last != "-"
            else { return false }
            return label.utf8.allSatisfy {
                ($0 >= 97 && $0 <= 122)
                    || ($0 >= 48 && $0 <= 57)
                    || $0 == 45
            }
        }
    }
}

enum WristPrivateNetworkConfigurationStore {
    private static let account = "private-network-configuration-v1"
    private static var service: String {
        "\(Bundle.main.bundleIdentifier ?? "dev.wristremote.ios").private-network"
    }

    static func load() -> WristPrivateNetworkConfiguration {
        guard let stored = WristInternetRelayKeychain.load(
            WristPrivateNetworkConfiguration.self,
            account: account,
            service: service
        ) else { return .disabled }
        return (try? stored.revalidated().get()) ?? .disabled
    }

    @discardableResult
    static func save(_ configuration: WristPrivateNetworkConfiguration) -> Bool {
        WristInternetRelayKeychain.save(
            configuration,
            account: account,
            service: service
        )
    }
}

private extension WristPrivateNetworkConfiguration {
    func revalidated() -> Result<Self, WristPrivateNetworkConfigurationError> {
        Self.validated(isEnabled: isEnabled, host: host)
    }
}
