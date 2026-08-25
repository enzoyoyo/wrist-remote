#!/usr/bin/env swift

import Foundation
import Security

private struct DeviceProvisioning: Codable {
    let baseURL: URL
    let roomID: UUID
    let deviceID: UUID
    let deviceToken: Data
    let encryptionKey: Data
}

private struct MacCredentials: Codable {
    let provisioning: DeviceProvisioning
    let macToken: Data
}

private enum ProvisionError: Error, CustomStringConvertible {
    case invalidArguments
    case invalidURL
    case invalidBundlePrefix
    case randomGeneration(OSStatus)
    case keychain(OSStatus)
    case corruptExistingCredentials
    case wranglerFailed(String, Int32)

    var description: String {
        switch self {
        case .invalidArguments:
            return "usage: provision-relay.swift --base-url HTTPS_URL --bundle-prefix REVERSE_DOMAIN --relay-dir PATH --xcconfig PATH"
        case .invalidURL:
            return "The relay URL must use HTTPS and include a host."
        case .invalidBundlePrefix:
            return "The Bundle prefix must be a non-example reverse-domain identifier."
        case let .randomGeneration(status):
            return "Secure random generation failed with status \(status)."
        case let .keychain(status):
            return "Keychain operation failed with status \(status)."
        case .corruptExistingCredentials:
            return "Existing relay credentials are corrupt. Remove them manually before retrying."
        case let .wranglerFailed(name, status):
            return "Cloudflare rejected secret \(name) with status \(status)."
        }
    }
}

private func argument(named name: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: name),
          CommandLine.arguments.indices.contains(index + 1)
    else { return nil }
    return CommandLine.arguments[index + 1]
}

private func randomData(count: Int) throws -> Data {
    var data = Data(count: count)
    let status = data.withUnsafeMutableBytes { buffer in
        SecRandomCopyBytes(kSecRandomDefault, count, buffer.baseAddress!)
    }
    guard status == errSecSuccess else { throw ProvisionError.randomGeneration(status) }
    return data
}

private func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

private func keychainQuery(service: String) -> [String: Any] {
    [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: "mac-credentials-v1",
    ]
}

private func loadCredentials(service: String) throws -> MacCredentials? {
    var query = keychainQuery(service: service)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data else {
        throw ProvisionError.keychain(status)
    }
    guard let credentials = try? JSONDecoder().decode(MacCredentials.self, from: data) else {
        throw ProvisionError.corruptExistingCredentials
    }
    return credentials
}

private func saveCredentials(_ credentials: MacCredentials, service: String) throws {
    let data = try JSONEncoder().encode(credentials)
    let query = keychainQuery(service: service)
    let update = [kSecValueData as String: data]
    let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
    if updateStatus == errSecSuccess { return }
    guard updateStatus == errSecItemNotFound else { throw ProvisionError.keychain(updateStatus) }
    var insert = query
    insert[kSecValueData as String] = data
    insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let insertStatus = SecItemAdd(insert as CFDictionary, nil)
    guard insertStatus == errSecSuccess else { throw ProvisionError.keychain(insertStatus) }
}

private func putWranglerSecret(
    name: String,
    value: String,
    relayDirectory: URL
) throws {
    let input = Pipe()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["npx", "wrangler", "secret", "put", name]
    process.currentDirectoryURL = relayDirectory
    process.standardInput = input
    process.standardOutput = FileHandle.standardOutput
    process.standardError = FileHandle.standardError
    try process.run()
    input.fileHandleForWriting.write(Data((value + "\n").utf8))
    try input.fileHandleForWriting.close()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw ProvisionError.wranglerFailed(name, process.terminationStatus)
    }
}

private func updateRelayURL(_ url: URL, in xcconfigURL: URL) throws {
    let original = try String(contentsOf: xcconfigURL, encoding: .utf8)
    let replacement = "WRISTREMOTE_RELAY_BASE_URL = \(url.absoluteString.replacingOccurrences(of: "//", with: "/$()/"))"
    let lines = original.split(separator: "\n", omittingEmptySubsequences: false)
    var replaced = false
    let updated = lines.map { line -> String in
        if line.trimmingCharacters(in: .whitespaces).hasPrefix("WRISTREMOTE_RELAY_BASE_URL =") {
            replaced = true
            return replacement
        }
        return String(line)
    }
    let output = (replaced ? updated : updated + [replacement]).joined(separator: "\n")
    try (output.hasSuffix("\n") ? output : output + "\n").write(
        to: xcconfigURL,
        atomically: true,
        encoding: .utf8
    )
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: xcconfigURL.path
    )
}

do {
    guard let rawBaseURL = argument(named: "--base-url"),
          let baseURL = URL(string: rawBaseURL),
          let bundlePrefix = argument(named: "--bundle-prefix"),
          let relayPath = argument(named: "--relay-dir"),
          let xcconfigPath = argument(named: "--xcconfig")
    else { throw ProvisionError.invalidArguments }
    guard baseURL.scheme == "https", baseURL.host != nil else {
        throw ProvisionError.invalidURL
    }
    let bundlePattern = #"^[A-Za-z][A-Za-z0-9-]*(\.[A-Za-z0-9-]+)+$"#
    guard bundlePrefix.range(of: bundlePattern, options: .regularExpression) != nil,
          !bundlePrefix.hasPrefix("example."),
          !bundlePrefix.contains(".example.")
    else { throw ProvisionError.invalidBundlePrefix }

    let service = "\(bundlePrefix).bridge.internet-relay"
    let existing = try loadCredentials(service: service)
    let credentials: MacCredentials
    if let existing {
        credentials = MacCredentials(
            provisioning: DeviceProvisioning(
                baseURL: baseURL,
                roomID: existing.provisioning.roomID,
                deviceID: existing.provisioning.deviceID,
                deviceToken: existing.provisioning.deviceToken,
                encryptionKey: existing.provisioning.encryptionKey
            ),
            macToken: existing.macToken
        )
    } else {
        credentials = MacCredentials(
            provisioning: DeviceProvisioning(
                baseURL: baseURL,
                roomID: UUID(),
                deviceID: UUID(),
                deviceToken: try randomData(count: 32),
                encryptionKey: try randomData(count: 32)
            ),
            macToken: try randomData(count: 32)
        )
    }
    guard credentials.provisioning.deviceToken.count == 32,
          credentials.provisioning.encryptionKey.count == 32,
          credentials.macToken.count == 32
    else { throw ProvisionError.corruptExistingCredentials }

    try saveCredentials(credentials, service: service)
    let relayDirectory = URL(fileURLWithPath: relayPath, isDirectory: true)
    try putWranglerSecret(
        name: "ALLOWED_ROOM_ID",
        value: credentials.provisioning.roomID.uuidString.lowercased(),
        relayDirectory: relayDirectory
    )
    try putWranglerSecret(
        name: "BOOTSTRAP_MAC_TOKEN",
        value: base64URL(credentials.macToken),
        relayDirectory: relayDirectory
    )
    try updateRelayURL(baseURL, in: URL(fileURLWithPath: xcconfigPath))
    print("Relay credentials were stored in Keychain and Cloudflare secrets without printing their values.")
} catch {
    FileHandle.standardError.write(Data(("error: \(error)\n").utf8))
    exit(1)
}
