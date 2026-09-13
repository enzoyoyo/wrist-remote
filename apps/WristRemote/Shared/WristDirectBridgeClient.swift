import CryptoKit
import Foundation
import Security

enum WristDirectBridgeClientError: LocalizedError, Equatable {
    case invalidConfiguration, invalidResponse, identityUnavailable, identityMismatch
    case notReady, busy, expired, approvalRequired, denied(String), operationUnconfirmed

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return "直连配置无效，请先连接 iPhone 与 Mac"
        case .invalidResponse: return "Mac 直连响应无效，已断开"
        case .identityUnavailable: return "无法读取手表独立身份，请解锁后重试"
        case .identityMismatch: return "Mac 身份不匹配，已拒绝直连"
        case .notReady: return "直连尚未就绪，本次未发送"
        case .busy: return "按键繁忙，本次未发送"
        case .expired: return "按键已过期，本次未发送"
        case .approvalRequired: return "请在 Mac 确认手表配对，然后点重新连接"
        case let .denied(detail): return detail
        case .operationUnconfirmed: return "Mac 未确认执行；不会自动重发"
        }
    }
}

/// HTTP is intentional: ordinary watchOS apps cannot use raw TCP, Bonjour or
/// WebSocket. All HTTP bodies after serverKey remain authenticated/encrypted.
@MainActor
final class WristDirectBridgeClient {
    enum State: Equatable {
        case idle, connecting, awaitingApproval(String), waitingForProfile, ready, suspended
        case failed(String)
    }

    struct Snapshot: Equatable {
        let macName: String
        let profile: WatchActionProfileWire
        let applicationTitles: [String: String]

        var revision: Int { profile.revision }

        func triggers(for command: WatchRemoteCommand) -> Set<WristInternetRelayButtonTrigger> {
            Set((profile.bindings[command.wireButtonID] ?? [:]).compactMap { raw, binding in
                guard binding.action != .disabled else { return nil }
                return WristInternetRelayButtonTrigger(rawValue: raw)
            })
        }
    }

    typealias HTTPExchange = @MainActor (URLRequest) async throws -> (Data, URLResponse)
    var onChange: (() -> Void)?
    private(set) var state: State = .idle { didSet { onChange?() } }
    private(set) var snapshot: Snapshot? { didSet { onChange?() } }
    private(set) var configuration: WristDirectBridgeConfiguration?

    private let deviceName: String
    private let identityProvider: () -> P256.Signing.PrivateKey?
    private let injectedExchange: HTTPExchange?
    private let pollInterval: TimeInterval
    private var urlSession: URLSession?
    private var sessionID: String?
    private var sessionKey: SymmetricKey?
    private var sessionAuthenticated = false
    private var secureChannel = WristBridgeSecureChannel()
    private var generation: UInt64 = 0
    private var sceneActive = false
    private var loopTask: Task<Void, Never>?
    private var loopTaskID: UUID?
    private var requestInFlight = false
    private var sendWaiters: [CheckedContinuation<Void, Never>] = []
    private var pendingProfile: WatchActionProfileWire?
    private var macName = "Mac"
    private var applicationTitles: [String: String] = [:]

    init(
        deviceName: String = "Apple Watch",
        identityProvider: @escaping () -> P256.Signing.PrivateKey? = {
            WristDirectBridgeIdentityStore.loadOrCreate()
        },
        exchange: HTTPExchange? = nil,
        pollInterval: TimeInterval = 3
    ) {
        self.deviceName = String(deviceName.prefix(80))
        self.identityProvider = identityProvider
        injectedExchange = exchange
        self.pollInterval = max(0.01, pollInterval)
    }

    var isReady: Bool { state == .ready && snapshot != nil && sceneActive }

    func configure(_ value: WristDirectBridgeConfiguration?) {
        let validated = value?.validated()
        guard configuration != validated else { return }
        configuration = validated
        restart()
    }

    func setSceneActive(_ active: Bool) {
        guard sceneActive != active else { return }
        sceneActive = active
        restart()
    }

    func reconnect() { restart() }

    @discardableResult
    func sendButton(
        command: WatchRemoteCommand,
        trigger: WristInternetRelayButtonTrigger,
        profileRevision: Int,
        issuedAtEpochMilliseconds: Int64
    ) async throws -> WristBridgeWireMessage {
        guard isReady, snapshot?.revision == profileRevision else {
            throw WristDirectBridgeClientError.notReady
        }
        guard sendWaiters.count < 6 else { throw WristDirectBridgeClientError.busy }
        let expectedGeneration = generation
        await acquireSendSlot()
        defer { releaseSendSlot() }
        try checkGeneration(expectedGeneration)
        let requestID = UUID().uuidString
        var message = WristBridgeWireMessage(type: "buttonTrigger")
        message.command = command.wireButtonID
        message.buttonTrigger = trigger.rawValue
        message.inputSource = WristBridgeWireMessage.appleWatchInputSource
        message.profileRevision = profileRevision
        message.requestID = requestID
        message.issuedAtEpochMilliseconds = issuedAtEpochMilliseconds
        guard isReady, snapshot?.revision == profileRevision else {
            throw WristDirectBridgeClientError.notReady
        }
        guard WristDirectBridgeProtocol.isFreshButtonCommit(
            message, nowEpochMilliseconds: Self.nowMilliseconds
        ) else { throw WristDirectBridgeClientError.expired }
        do {
            let replies = try await exchangeSecure(message, generation: expectedGeneration)
            guard let result = replies.first(where: {
                $0.type == "buttonTriggerResult" && $0.requestID == requestID
            }), let accepted = result.accepted else {
                throw WristDirectBridgeClientError.operationUnconfirmed
            }
            guard accepted else {
                throw WristDirectBridgeClientError.denied(result.detail ?? "Mac 未执行该动作")
            }
            return result
        } catch {
            if case .denied = error as? WristDirectBridgeClientError { throw error }
            // A transport failure is an ambiguous outcome, never permission to
            // replay a command over this or the companion-iPhone path.
            if !(error is CancellationError), expectedGeneration == generation {
                snapshot = nil
                state = .failed(error.localizedDescription)
                loopTask?.cancel()
                loopTask = nil
                startLoopIfNeeded()
            }
            throw error
        }
    }

    private func restart() {
        generation &+= 1
        loopTask?.cancel()
        loopTask = nil
        loopTaskID = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        sessionID = nil
        sessionKey = nil
        sessionAuthenticated = false
        secureChannel.reset()
        pendingProfile = nil
        applicationTitles = [:]
        snapshot = nil
        state = sceneActive ? .idle : .suspended
        startLoopIfNeeded()
    }

    private func startLoopIfNeeded() {
        guard sceneActive, configuration != nil, loopTask == nil else { return }
        let expectedGeneration = generation
        let currentLoopID = UUID()
        loopTaskID = currentLoopID
        loopTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                // An older cancelled loop must not clear a newer reconnect.
                if loopTaskID == currentLoopID {
                    loopTask = nil
                    loopTaskID = nil
                }
            }
            var attempts = 0
            while !Task.isCancelled, sceneActive, expectedGeneration == generation {
                do {
                    await acquireSendSlot()
                    do {
                        try checkGeneration(expectedGeneration)
                        try await connect(generation: expectedGeneration)
                        releaseSendSlot()
                    } catch {
                        releaseSendSlot()
                        throw error
                    }
                    attempts = 0
                    while !Task.isCancelled, sessionAuthenticated, expectedGeneration == generation {
                        try await Task.sleep(for: .seconds(pollInterval))
                        await acquireSendSlot()
                        do {
                            try checkGeneration(expectedGeneration)
                            let probeID = UUID().uuidString
                            let replies = try await exchangeSecure(
                                WristBridgeWireMessage(type: "livenessProbe", probeID: probeID),
                                generation: expectedGeneration
                            )
                            guard replies.contains(where: {
                                $0.type == "livenessAck" && $0.probeID == probeID
                            }) else { throw WristDirectBridgeClientError.invalidResponse }
                            if pendingProfile != nil, snapshot?.profile != pendingProfile {
                                try await installPendingProfile(generation: expectedGeneration)
                            }
                            releaseSendSlot()
                        } catch {
                            releaseSendSlot()
                            throw error
                        }
                    }
                } catch is CancellationError {
                    return
                } catch {
                    guard expectedGeneration == generation, sceneActive else { return }
                    let wasAwaitingApproval: Bool
                    if case .awaitingApproval = state { wasAwaitingApproval = true }
                    else { wasAwaitingApproval = false }
                    snapshot = nil
                    let explicitlyDenied: Bool
                    if case .denied = error as? WristDirectBridgeClientError { explicitlyDenied = true }
                    else { explicitlyDenied = false }
                    state = .failed(wasAwaitingApproval && !explicitlyDenied
                        ? WristDirectBridgeClientError.approvalRequired.localizedDescription
                        : error.localizedDescription)
                    if wasAwaitingApproval || error as? WristDirectBridgeClientError == .identityMismatch
                        || error as? WristDirectBridgeClientError == .identityUnavailable {
                        // Never recreate an unanswered human approval loop.
                        return
                    }
                    attempts = min(attempts + 1, 5)
                    try? await Task.sleep(for: .seconds(min(8, 0.5 * pow(2, Double(attempts - 1)))))
                }
            }
        }
    }

    private func connect(generation expectedGeneration: UInt64) async throws {
        guard let configuration, configuration.validated() != nil else {
            throw WristDirectBridgeClientError.invalidConfiguration
        }
        state = .connecting
        snapshot = nil
        sessionID = nil
        sessionKey = nil
        sessionAuthenticated = false
        pendingProfile = nil
        secureChannel.reset()
        guard let identity = identityProvider() else { throw WristDirectBridgeClientError.identityUnavailable }
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let publicKey = ephemeral.publicKey.rawRepresentation
        let hello = WristBridgeWireMessage(
            type: "hello", protocolID: WristBridgeWireMessage.protocolID,
            clientRole: WristBridgeWireMessage.clientRole,
            publicKey: publicKey.base64EncodedString(),
            capabilities: [WristBridgeWireMessage.secureSequenceCapability,
                           WristBridgeWireMessage.audioDeliveryReceiptsCapability,
                           WristDirectBridgeProtocol.capability,
                           WristDirectBridgeProtocol.buttonTriggerCapability]
        )
        let response = try await post(hello, generation: expectedGeneration)
        guard response.messages.count == 1, let server = response.messages.first,
              server.type == "serverKey",
              server.protocolID == WristBridgeWireMessage.protocolID,
              server.serverRole == WristBridgeWireMessage.serverRole,
              server.serverIdentityVersion == WristBridgeWireMessage.serverIdentityVersion,
              server.serverIdentityPublicKey == configuration.serverIdentityPublicKey,
              let serverIdentityData = Data(base64Encoded: configuration.serverIdentityPublicKey),
              let serverIdentity = try? P256.Signing.PublicKey(rawRepresentation: serverIdentityData),
              let encodedServerKey = server.publicKey,
              let serverPublicKey = Data(base64Encoded: encodedServerKey),
              let serverEphemeral = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: serverPublicKey),
              let encodedSignature = server.serverIdentitySignature,
              let signatureData = Data(base64Encoded: encodedSignature),
              let signature = try? P256.Signing.ECDSASignature(rawRepresentation: signatureData),
              let proof = WristBridgeWireMessage.serverIdentityProof(
                clientEphemeralPublicKey: publicKey, serverEphemeralPublicKey: serverPublicKey
              ), serverIdentity.isValidSignature(signature, for: proof),
              let transcript = WristBridgeWireMessage.sessionTranscript(
                clientEphemeralPublicKey: publicKey, serverEphemeralPublicKey: serverPublicKey,
                serverIdentityPublicKey: serverIdentityData
              ) else { throw WristDirectBridgeClientError.identityMismatch }
        let secret = try ephemeral.sharedSecretFromKeyAgreement(with: serverEphemeral)
        let key = secret.hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: Data(WristBridgeWireMessage.sessionSalt.utf8),
            sharedInfo: Data(SHA256.hash(data: transcript)), outputByteCount: 32
        )
        sessionKey = key
        guard let clientProof = WristBridgeWireMessage.clientAuthenticationProof(
            clientEphemeralPublicKey: publicKey, serverEphemeralPublicKey: serverPublicKey,
            serverIdentityPublicKey: serverIdentityData,
            clientIdentityPublicKey: identity.publicKey.rawRepresentation
        ) else { throw WristDirectBridgeClientError.invalidResponse }
        let clientSignature = try identity.signature(for: clientProof)
        state = .awaitingApproval(Self.pairingCode(key))
        let auth = WristBridgeWireMessage(
            type: "clientAuth", deviceName: deviceName,
            identityPublicKey: identity.publicKey.rawRepresentation.base64EncodedString(),
            identitySignature: clientSignature.rawRepresentation.base64EncodedString(),
            serverIdentityPinned: true
        )
        let replies = try await exchangeSecure(auth, generation: expectedGeneration, timeout: 40)
        guard replies.contains(where: { $0.type == "ready" }), sessionAuthenticated else {
            throw WristDirectBridgeClientError.invalidResponse
        }
        if pendingProfile != nil {
            try await installPendingProfile(generation: expectedGeneration)
        } else {
            state = .waitingForProfile
        }
    }

    private func installPendingProfile(generation expectedGeneration: UInt64) async throws {
        guard let profile = pendingProfile else { throw WristDirectBridgeClientError.notReady }
        snapshot = nil
        state = .connecting
        var install = WristBridgeWireMessage(type: "watchProfileUpdate")
        install.inputSource = WristBridgeWireMessage.appleWatchInputSource
        install.profileRevision = profile.revision
        install.watchProfile = try profile.encodedBase64()
        let installed = try await exchangeSecure(install, generation: expectedGeneration)
        guard pendingProfile == profile, installed.contains(where: {
            $0.type == "watchProfileReady" && $0.profileRevision == profile.revision
        }) else { throw WristDirectBridgeClientError.notReady }
        snapshot = Snapshot(macName: macName, profile: profile, applicationTitles: applicationTitles)
        state = .ready
    }

    private func exchangeSecure(
        _ message: WristBridgeWireMessage,
        generation expectedGeneration: UInt64,
        timeout: TimeInterval = 6
    ) async throws -> [WristBridgeWireMessage] {
        guard let key = sessionKey,
              let envelope = secureChannel.seal(message, using: key, senderRole: WristBridgeWireMessage.clientRole)
        else { throw WristDirectBridgeClientError.notReady }
        let response = try await post(envelope, generation: expectedGeneration, timeout: timeout)
        var replies: [WristBridgeWireMessage] = []
        for envelope in response.messages {
            guard let clear = secureChannel.open(envelope, using: key, senderRole: WristBridgeWireMessage.serverRole)
            else { throw WristDirectBridgeClientError.invalidResponse }
            guard !["hello", "serverKey", "clientAuth"].contains(clear.type),
                  clear.type != "ready" || message.type == "clientAuth" else {
                throw WristDirectBridgeClientError.invalidResponse
            }
            if clear.type == "denied" {
                throw WristDirectBridgeClientError.denied(clear.detail ?? "Mac 拒绝了手表连接")
            }
            if clear.type == "ready" {
                guard clear.protocolID == WristBridgeWireMessage.protocolID,
                      clear.serverRole == WristBridgeWireMessage.serverRole,
                      Set(clear.capabilities ?? []).isSuperset(of: [
                        WristDirectBridgeProtocol.capability,
                        WristDirectBridgeProtocol.buttonTriggerCapability,
                        WristBridgeWireMessage.watchActionProfileCapability,
                        WristBridgeWireMessage.secureSequenceCapability,
                      ])
                else { throw WristDirectBridgeClientError.invalidResponse }
                sessionAuthenticated = true
                state = .waitingForProfile
                if clear.watchProfile == nil, clear.profileRevision == nil {
                    pendingProfile = nil
                } else {
                    guard let encodedProfile = clear.watchProfile,
                          let profile = try? WatchActionProfileWire.decodeBase64(encodedProfile),
                          profile.revision == clear.profileRevision else {
                        throw WristDirectBridgeClientError.invalidResponse
                    }
                    pendingProfile = profile
                }
                macName = clear.deviceName ?? configuration?.serverName ?? "Mac"
                applicationTitles = clear.watchApplicationTitles ?? [:]
            }
            if clear.type == "watchProfileRejected" {
                snapshot = nil
                pendingProfile = nil
                state = .waitingForProfile
            }
            if clear.type == "watchProfileSnapshot" {
                if clear.watchProfile == nil, clear.profileRevision == nil {
                    pendingProfile = nil
                    snapshot = nil
                    state = .waitingForProfile
                } else {
                    guard let encoded = clear.watchProfile,
                          let profile = try? WatchActionProfileWire.decodeBase64(encoded),
                          profile.revision == clear.profileRevision else {
                        throw WristDirectBridgeClientError.invalidResponse
                    }
                    pendingProfile = profile
                    if snapshot?.profile != profile { snapshot = nil }
                }
            }
            if clear.type == "watchApplicationTitles" {
                applicationTitles = clear.watchApplicationTitles ?? [:]
                if let current = snapshot {
                    snapshot = Snapshot(macName: current.macName, profile: current.profile,
                                        applicationTitles: applicationTitles)
                }
            }
            replies.append(clear)
        }
        return replies
    }

    private func post(
        _ message: WristBridgeWireMessage,
        generation expectedGeneration: UInt64,
        timeout: TimeInterval = 6
    ) async throws -> WristDirectBridgeHTTPResponse {
        try checkGeneration(expectedGeneration)
        guard let configuration, configuration.validated() != nil,
              let endpoint = URL(string: configuration.endpoint)
        else { throw WristDirectBridgeClientError.invalidConfiguration }
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(WristDirectBridgeHTTPRequest(sessionID: sessionID, message: message))
        let transport: HTTPExchange
        if let injectedExchange { transport = injectedExchange }
        else {
            if urlSession == nil {
                let options = URLSessionConfiguration.ephemeral
                options.waitsForConnectivity = false
                options.timeoutIntervalForResource = 42
                options.httpCookieStorage = nil
                options.urlCache = nil
                options.connectionProxyDictionary = [:]
                urlSession = URLSession(configuration: options, delegate: WristDirectBridgeRedirectBlocker(), delegateQueue: nil)
            }
            guard let session = urlSession else { throw WristDirectBridgeClientError.notReady }
            transport = { request in try await session.data(for: request) }
        }
        let (data, rawResponse) = try await transport(request)
        try checkGeneration(expectedGeneration)
        guard let response = rawResponse as? HTTPURLResponse,
              response.url == endpoint, response.statusCode == 200,
              data.count <= WristDirectBridgeProtocol.maximumResponseBodyBytes,
              let decoded = try? JSONDecoder().decode(WristDirectBridgeHTTPResponse.self, from: data),
              WristDirectBridgeProtocol.isCanonicalSessionID(decoded.sessionID),
              decoded.messages.count <= WristDirectBridgeProtocol.maximumOutboxMessages,
              sessionID == nil || sessionID == decoded.sessionID
        else { throw WristDirectBridgeClientError.invalidResponse }
        sessionID = decoded.sessionID
        return decoded
    }

    private func checkGeneration(_ expected: UInt64) throws {
        try Task.checkCancellation()
        guard sceneActive, expected == generation else { throw CancellationError() }
    }

    private func acquireSendSlot() async {
        if !requestInFlight { requestInFlight = true; return }
        await withCheckedContinuation { sendWaiters.append($0) }
    }

    private func releaseSendSlot() {
        if sendWaiters.isEmpty { requestInFlight = false }
        else { sendWaiters.removeFirst().resume() }
    }

    private static var nowMilliseconds: Int64 { Int64(Date().timeIntervalSince1970 * 1_000) }

    private static func pairingCode(_ key: SymmetricKey) -> String {
        let number = key.withUnsafeBytes { bytes in
            bytes.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }
        return String(format: "%06u", number % 1_000_000)
    }
}

private final class WristDirectBridgeRedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) { completionHandler(nil) }
}

enum WristDirectBridgeIdentityStore {
    static func loadOrCreate() -> P256.Signing.PrivateKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "\(Bundle.main.bundleIdentifier ?? "dev.wristremote.watch").direct-bridge.client-identity",
            kSecAttrAccount as String: "watch-p256-signing-v1",
        ]
        var read = query
        read[kSecReturnData as String] = true
        read[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(read as CFDictionary, &result)
        if status == errSecSuccess {
            guard let data = result as? Data else { return nil }
            return try? P256.Signing.PrivateKey(rawRepresentation: data)
        }
        guard status == errSecItemNotFound else { return nil }
        let key = P256.Signing.PrivateKey()
        var item = query
        item[kSecValueData as String] = key.rawRepresentation
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { return nil }
        return key
    }
}
