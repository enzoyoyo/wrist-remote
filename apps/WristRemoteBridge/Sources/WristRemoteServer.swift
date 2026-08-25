import CryptoKit
import Darwin
import Foundation
import Network

enum WristRemoteIdentityVerification: Equatable {
    case unavailable
    case verified(String)
    case invalid
}

enum WristRemoteIdentityVerifier {
    static let identityProofDomain = "WristRemoteBridge nearby identity v1"

    static func verify(
        identityPublicKey encodedIdentityKey: String?,
        identitySignature encodedSignature: String?,
        sessionPublicKey: Data
    ) -> WristRemoteIdentityVerification {
        if encodedIdentityKey == nil, encodedSignature == nil { return .unavailable }
        guard let encodedIdentityKey,
              let encodedSignature,
              let identityData = Data(base64Encoded: encodedIdentityKey),
              let signatureData = Data(base64Encoded: encodedSignature),
              let identityKey = try? P256.Signing.PublicKey(rawRepresentation: identityData),
              let signature = try? P256.Signing.ECDSASignature(rawRepresentation: signatureData),
              identityKey.isValidSignature(signature, for: proof(for: sessionPublicKey))
        else { return .invalid }
        let fingerprint = SHA256.hash(data: identityData)
            .map { String(format: "%02x", $0) }
            .joined()
        return .verified(fingerprint)
    }

    static func proof(for sessionPublicKey: Data) -> Data {
        var proof = Data((identityProofDomain + "\0").utf8)
        proof.append(sessionPublicKey)
        return proof
    }
}

enum WristRemoteHandshake {
    static let protocolID = BridgeWireMessage.wristRemoteProtocolID
    static let clientRole = BridgeWireMessage.wristRemoteClientRole
    static let serverRole = BridgeWireMessage.wristRemoteServerRole

    static func acceptsClient(_ message: BridgeWireMessage) -> Bool {
        message.type == "hello"
            && message.protocolID == protocolID
            && message.clientRole == clientRole
            && message.serverRole == nil
    }
}

enum WristRemoteCodexTargetValidator {
    static func accepts(
        _ identity: WatchCodexTaskIdentity?,
        snapshot: WatchCodexTaskSnapshot?
    ) -> Bool {
        identity != nil
            && WatchCodexTaskIdentity(snapshot) == identity
            && snapshot?.state == .completed
    }
}

enum WristRemotePeerAccessPolicy {
    static func permits(
        _ endpoint: NWEndpoint,
        localPhysicalIPv6Addresses: [Data] = currentPhysicalIPv6Addresses()
    ) -> Bool {
        guard case let .hostPort(host, _) = endpoint else { return false }
        return permits(host, localPhysicalIPv6Addresses: localPhysicalIPv6Addresses)
    }

    static func permits(
        _ host: NWEndpoint.Host,
        localPhysicalIPv6Addresses: [Data] = currentPhysicalIPv6Addresses()
    ) -> Bool {
        switch host {
        case let .ipv4(address):
            return isPermittedIPv4([UInt8](address.rawValue))
        case let .ipv6(address):
            let bytes = [UInt8](address.rawValue)
            if isPermittedIPv6(bytes) { return true }
            guard isGlobalUnicastIPv6(bytes) else { return false }
            return localPhysicalIPv6Addresses.contains { localAddress in
                let localBytes = [UInt8](localAddress)
                return isGlobalUnicastIPv6(localBytes)
                    && localBytes.prefix(8).elementsEqual(bytes.prefix(8))
            }
        case .name:
            // An accepted inbound connection should already have a numeric
            // peer address. Never resolve or trust a hostname here.
            return false
        @unknown default:
            return false
        }
    }

    private static func isPermittedIPv4(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 4 else { return false }
        return bytes[0] == 10
            || bytes[0] == 127
            || (bytes[0] == 169 && bytes[1] == 254)
            || (bytes[0] == 172 && (16 ... 31).contains(bytes[1]))
            || (bytes[0] == 192 && bytes[1] == 168)
    }

    private static func isPermittedIPv6(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return false }
        let loopback = bytes.prefix(15).allSatisfy { $0 == 0 } && bytes[15] == 1
        let linkLocal = bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80
        let uniqueLocal = (bytes[0] & 0xfe) == 0xfc
        let mappedIPv4 = bytes.prefix(10).allSatisfy { $0 == 0 }
            && bytes[10] == 0xff
            && bytes[11] == 0xff
            && isPermittedIPv4(Array(bytes[12 ..< 16]))
        return loopback || linkLocal || uniqueLocal || mappedIPv4
    }

    private static func isGlobalUnicastIPv6(_ bytes: [UInt8]) -> Bool {
        bytes.count == 16 && (bytes[0] & 0xe0) == 0x20
    }

    private static func currentPhysicalIPv6Addresses() -> [Data] {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return [] }
        defer { freeifaddrs(interfaces) }

        var result: [Data] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            let interface = current.pointee
            cursor = interface.ifa_next
            guard (interface.ifa_flags & UInt32(IFF_UP)) != 0,
                  let address = interface.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET6)
            else { continue }
            let name = String(cString: interface.ifa_name)
            guard isPhysicalInterface(name) else { continue }
            let ipv6 = UnsafeRawPointer(address)
                .assumingMemoryBound(to: sockaddr_in6.self)
                .pointee.sin6_addr
            let data = withUnsafeBytes(of: ipv6) { Data($0) }
            if isGlobalUnicastIPv6([UInt8](data)) { result.append(data) }
        }
        return result
    }

    private static func isPhysicalInterface(_ name: String) -> Bool {
        name.hasPrefix("en")
            || name.hasPrefix("bridge")
            || name.hasPrefix("awdl")
            || name.hasPrefix("llw")
    }
}

final class WristRemoteServer {
    static let serviceType = "_wristremote._tcp"
    static let sessionSalt = "WristRemoteBridge nearby session"
    static let port: UInt16 = 60_927

    enum Status: Equatable {
        case stopped
        case starting
        case ready
        case connected(String)
        case failed(String)
    }

    typealias ApprovalHandler = (
        _ deviceName: String,
        _ pairingCode: String,
        _ fingerprint: String?,
        _ completion: @escaping (Bool) -> Void
    ) -> Void

    private let queue = DispatchQueue(label: "WristRemoteBridge.server", qos: .userInitiated)
    private var listener: NWListener?
    private var clients: [ObjectIdentifier: WristRemoteServerClient] = [:]
    private var applicationTitles: [String: String] = [:]
    private var codexTaskSnapshot: WatchCodexTaskSnapshot?
    private var codexTaskStateRevision = 0
    private var speechLocaleIdentifier = "zh-CN"
    private var internetRelayProvisioning: String?

    var onStatus: ((Status) -> Void)?
    var onApprovalRequested: ApprovalHandler?
    var onApprovalCancelled: (() -> Void)?
    var isIdentityTrusted: ((String) -> Bool)?
    var onIdentityApproved: ((String) -> Void)?
    var onWatchProfileUpdate: ((
        WatchActionProfileWire,
        @escaping (WatchProfileRuntimeInstallResult) -> Void
    ) -> Void)?
    var onWatchButtonEvent: ((WristRemoteButton, WristRemoteButtonPhase, @escaping (Bool) -> Void) -> Void)?
    var onProfileReset: (() -> Void)?
    var onVoiceStart: ((
        String?,
        WatchVoiceIntent,
        WatchCodexTaskIdentity?,
        @escaping (Bool) -> Void
    ) -> Void)?
    var onVoiceStop: (() -> Void)?
    var onAudio: (([Int16]) -> Void)?
    var onCodexReplySubmit: ((
        UUID,
        WatchCodexTaskIdentity,
        String,
        @escaping (Bool, String?) -> Void
    ) -> Void)?

    func start() {
        queue.async { [weak self] in self?.startOnQueue() }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            listener?.cancel()
            listener = nil
            let currentClients = Array(clients.values)
            clients.removeAll()
            currentClients.forEach { $0.cancel() }
            publish(.stopped)
        }
    }

    func updateApplicationTitles(_ titles: [String: String]) {
        queue.async { [weak self] in
            guard let self else { return }
            applicationTitles = titles
            clients.values.forEach { $0.updateApplicationTitles(titles) }
        }
    }

    func updateCodexTask(
        _ snapshot: WatchCodexTaskSnapshot?,
        stateRevision: Int
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            codexTaskSnapshot = snapshot
            codexTaskStateRevision = stateRevision
            clients.values.forEach {
                $0.updateCodexTask(snapshot, stateRevision: stateRevision)
            }
        }
    }

    func updateSpeechLocaleIdentifier(_ identifier: String) {
        queue.async { [weak self] in
            guard let self else { return }
            speechLocaleIdentifier = identifier
            clients.values.forEach { $0.updateSpeechLocaleIdentifier(identifier) }
        }
    }

    func updateInternetRelayProvisioning(_ encoded: String?) {
        queue.async { [weak self] in
            guard let self else { return }
            internetRelayProvisioning = encoded
            clients.values.forEach { $0.updateInternetRelayProvisioning(encoded) }
        }
    }

    func sendVoiceOutcome(_ outcome: WatchVoiceOutcome) {
        queue.async { [weak self] in
            self?.clients.values.forEach { $0.sendVoiceOutcome(outcome) }
        }
    }

    func invalidateProfiles(detail: String) {
        queue.async { [weak self] in
            guard let self else { return }
            clients.values.forEach { $0.invalidateProfile(detail: detail) }
            onProfileReset?()
        }
    }

    private func startOnQueue() {
        guard listener == nil else { return }
        publish(.starting)
        do {
            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = true
            guard let port = NWEndpoint.Port(rawValue: Self.port) else {
                publish(.failed("腕上遥控桥端口无效。"))
                return
            }
            let listener = try NWListener(using: parameters, on: port)
            listener.service = NWListener.Service(
                name: Self.serviceName,
                type: Self.serviceType
            )
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, listener === self.listener else { return }
                switch state {
                case .ready:
                    self.publish(.ready)
                case let .failed(error):
                    self.listener = nil
                    self.publish(.failed(error.localizedDescription))
                case .cancelled:
                    if self.listener != nil { self.publish(.stopped) }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            publish(.failed(error.localizedDescription))
        }
    }

    private func accept(_ connection: NWConnection) {
        guard WristRemotePeerAccessPolicy.permits(connection.endpoint) else {
            connection.cancel()
            return
        }
        let client = WristRemoteServerClient(
            connection: connection,
            queue: queue,
            macName: Self.macName,
            appVersion: Self.appVersion,
            applicationTitles: applicationTitles,
            codexTaskSnapshot: codexTaskSnapshot,
            codexTaskStateRevision: codexTaskStateRevision,
            speechLocaleIdentifier: speechLocaleIdentifier,
            internetRelayProvisioning: internetRelayProvisioning
        )
        let id = ObjectIdentifier(client)
        clients[id] = client
        client.isIdentityTrusted = { [weak self] fingerprint in
            self?.isIdentityTrusted?(fingerprint) ?? false
        }
        client.onIdentityApproved = { [weak self] fingerprint in
            self?.onIdentityApproved?(fingerprint)
        }
        client.onApprovalRequested = { [weak self, weak client] name, code, fingerprint in
            guard let self, let client else { return }
            guard let approval = onApprovalRequested else {
                client.resolveApproval(false)
                return
            }
            approval(name, code, fingerprint) { [weak self, weak client] allowed in
                self?.queue.async { client?.resolveApproval(allowed) }
            }
        }
        client.onApproved = { [weak self, weak client] deviceName in
            guard let self, let client else { return }
            let others = clients.values.filter { $0 !== client }
            others.forEach { $0.cancel() }
            publish(.connected(deviceName))
        }
        client.onWatchProfileUpdate = { [weak self] profile, completion in
            guard let handler = self?.onWatchProfileUpdate else {
                completion(.rejected)
                return
            }
            handler(profile, completion)
        }
        client.onWatchButtonEvent = { [weak self] button, phase, completion in
            guard let handler = self?.onWatchButtonEvent else {
                completion(false)
                return
            }
            handler(button, phase, completion)
        }
        client.onVoiceStart = { [weak self] sessionID, intent, identity, completion in
            guard let handler = self?.onVoiceStart else {
                completion(false)
                return
            }
            handler(sessionID, intent, identity, completion)
        }
        client.onVoiceStop = { [weak self] in self?.onVoiceStop?() }
        client.onAudio = { [weak self] samples in self?.onAudio?(samples) }
        client.onCodexReplySubmit = {
            [weak self] submissionID, identity, transcript, completion in
            guard let handler = self?.onCodexReplySubmit else {
                completion(false, "Codex 回复服务未就绪。")
                return
            }
            handler(submissionID, identity, transcript, completion)
        }
        client.onClosed = { [weak self, weak client] wasApproved, wasAwaitingApproval in
            guard let self else { return }
            clients.removeValue(forKey: id)
            if wasApproved {
                onProfileReset?()
                if !clients.values.contains(where: \.hasApprovedSession) {
                    publish(.ready)
                }
            }
            if wasAwaitingApproval { onApprovalCancelled?() }
            _ = client
        }
        client.start()
    }

    private func publish(_ status: Status) {
        DispatchQueue.main.async { [weak self] in self?.onStatus?(status) }
    }

    private static var serviceName: String {
        "\(macName) · Wrist Remote"
    }

    private static var macName: String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    private static var appVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }
}

private final class WristRemoteServerClient {
    private struct VoiceTarget {
        let intent: WatchVoiceIntent
        let codexTaskIdentity: WatchCodexTaskIdentity?
    }

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let macName: String
    private let appVersion: String?
    private var applicationTitles: [String: String]
    private var codexTaskSnapshot: WatchCodexTaskSnapshot?
    private var codexTaskStateRevision: Int
    private var speechLocaleIdentifier: String
    private var internetRelayProvisioning: String?
    private var receiveBuffer = Data()
    private var sessionKey: SymmetricKey?
    private var identityFingerprint: String?
    private var pendingName: String?
    private var connectedDeviceName = "Wrist Remote"
    private var pendingPairingCode: String?
    private var waitsForPairingReady = false
    private var requestedApproval = false
    private var approved = false
    private var closed = false
    private var watchProfileSession = WatchProfileSession()
    private var voiceSession = BridgeVoiceSession()
    private var activeVoiceIntent: WatchVoiceIntent = .foregroundDictation
    private var activeVoiceCodexTaskIdentity: WatchCodexTaskIdentity?
    private var activeVoiceSessionID: String?
    private var awaitingVoiceOutcomes: [String: VoiceTarget] = [:]

    var isIdentityTrusted: ((String) -> Bool)?
    var onIdentityApproved: ((String) -> Void)?
    var onApprovalRequested: ((String, String, String?) -> Void)?
    var onApproved: ((String) -> Void)?
    var onWatchProfileUpdate: ((
        WatchActionProfileWire,
        @escaping (WatchProfileRuntimeInstallResult) -> Void
    ) -> Void)?
    var onWatchButtonEvent: ((WristRemoteButton, WristRemoteButtonPhase, @escaping (Bool) -> Void) -> Void)?
    var onVoiceStart: ((
        String?,
        WatchVoiceIntent,
        WatchCodexTaskIdentity?,
        @escaping (Bool) -> Void
    ) -> Void)?
    var onVoiceStop: (() -> Void)?
    var onAudio: (([Int16]) -> Void)?
    var onCodexReplySubmit: ((
        UUID,
        WatchCodexTaskIdentity,
        String,
        @escaping (Bool, String?) -> Void
    ) -> Void)?
    var onClosed: ((Bool, Bool) -> Void)?

    var hasApprovedSession: Bool { approved }

    init(
        connection: NWConnection,
        queue: DispatchQueue,
        macName: String,
        appVersion: String?,
        applicationTitles: [String: String],
        codexTaskSnapshot: WatchCodexTaskSnapshot?,
        codexTaskStateRevision: Int,
        speechLocaleIdentifier: String,
        internetRelayProvisioning: String?
    ) {
        self.connection = connection
        self.queue = queue
        self.macName = macName
        self.appVersion = appVersion
        self.applicationTitles = applicationTitles
        self.codexTaskSnapshot = codexTaskSnapshot
        self.codexTaskStateRevision = codexTaskStateRevision
        self.speechLocaleIdentifier = speechLocaleIdentifier
        self.internetRelayProvisioning = internetRelayProvisioning
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.receiveNext()
            case .failed, .cancelled:
                self?.close()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func cancel() {
        connection.cancel()
        close()
    }

    func resolveApproval(_ allowed: Bool) {
        guard requestedApproval, !approved else { return }
        guard allowed else {
            sendSecure(BridgeWireMessage(type: "denied")) { [weak self] in
                self?.connection.cancel()
            }
            return
        }
        approved = true
        if let identityFingerprint { onIdentityApproved?(identityFingerprint) }
        sendReady()
    }

    func updateApplicationTitles(_ titles: [String: String]) {
        applicationTitles = titles
        guard approved else { return }
        sendSecure(BridgeWireMessage(
            type: "watchApplicationTitles",
            watchApplicationTitles: titles
        ))
    }

    func updateCodexTask(
        _ snapshot: WatchCodexTaskSnapshot?,
        stateRevision: Int
    ) {
        let nextIdentity = WatchCodexTaskIdentity(snapshot)
        if activeVoiceIntent == .codexTask,
           let activeVoiceSessionID,
           let activeVoiceCodexTaskIdentity,
           activeVoiceCodexTaskIdentity != nextIdentity {
            if voiceSession.stop(sessionID: activeVoiceSessionID, force: true) {
                onVoiceStop?()
            }
            sendVoiceOutcome(WatchVoiceOutcome(
                sessionID: activeVoiceSessionID,
                intent: .codexTask,
                threadID: activeVoiceCodexTaskIdentity.threadID,
                turnID: activeVoiceCodexTaskIdentity.turnID,
                taskRevision: activeVoiceCodexTaskIdentity.revision,
                kind: .failed,
                text: nil,
                detail: "Codex 任务已更新，旧录音已拒绝。",
                localeIdentifier: speechLocaleIdentifier
            ))
            clearActiveVoiceTarget()
        }
        codexTaskSnapshot = snapshot
        codexTaskStateRevision = stateRevision
        guard approved else { return }
        sendSecure(BridgeWireMessage(
            type: "codexTaskSnapshot",
            codexTask: snapshot,
            codexTaskCleared: snapshot == nil,
            codexTaskStateRevision: stateRevision
        ))
    }

    func updateSpeechLocaleIdentifier(_ identifier: String) {
        speechLocaleIdentifier = identifier
    }

    func updateInternetRelayProvisioning(_ encoded: String?) {
        internetRelayProvisioning = encoded
        guard approved else { return }
        sendSecure(BridgeWireMessage(
            type: "internetRelayProvisioning",
            internetRelayProvisioning: encoded
        ))
    }

    func sendVoiceOutcome(_ outcome: WatchVoiceOutcome) {
        guard approved,
              UUID(uuidString: outcome.sessionID) != nil,
              let expected = awaitingVoiceOutcomes[outcome.sessionID],
              expected.intent == outcome.intent
        else { return }

        let normalized: WatchVoiceOutcome
        switch expected.intent {
        case .foregroundDictation:
            guard outcome.threadID == nil,
                  outcome.turnID == nil,
                  outcome.taskRevision == nil
            else { return }
            normalized = outcome
        case .codexTask:
            guard let identity = expected.codexTaskIdentity,
                  (outcome.threadID == nil || outcome.threadID == identity.threadID),
                  (outcome.turnID == nil || outcome.turnID == identity.turnID),
                  (outcome.taskRevision == nil
                    || outcome.taskRevision == identity.revision)
            else { return }
            if WatchCodexTaskIdentity(codexTaskSnapshot) == identity {
                normalized = outcome.bound(to: identity)
            } else {
                normalized = WatchVoiceOutcome(
                    sessionID: outcome.sessionID,
                    intent: .codexTask,
                    threadID: identity.threadID,
                    turnID: identity.turnID,
                    taskRevision: identity.revision,
                    kind: .failed,
                    text: nil,
                    detail: "Codex 任务已更新，旧录音结果已拒绝。",
                    localeIdentifier: outcome.localeIdentifier
                )
            }
        }
        awaitingVoiceOutcomes.removeValue(forKey: outcome.sessionID)
        sendSecure(BridgeWireMessage(
            type: "voiceOutcome",
            detail: normalized.detail,
            sessionID: normalized.sessionID,
            voiceIntent: normalized.intent.rawValue,
            threadID: normalized.threadID,
            turnID: normalized.turnID,
            taskRevision: normalized.taskRevision,
            transcript: normalized.text,
            voiceOutcome: normalized.kind.rawValue,
            speechLocaleIdentifier: normalized.localeIdentifier
        ))
    }

    func invalidateProfile(detail: String) {
        let revision = watchProfileSession.acceptedProfile?.revision
        if voiceSession.stop(sessionID: nil, force: true) { onVoiceStop?() }
        clearActiveVoiceTarget()
        awaitingVoiceOutcomes.removeAll()
        watchProfileSession.reset()
        guard approved, let revision else { return }
        sendWatchProfileRejected(revision: revision, detail: detail)
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, complete, error in
            guard let self else { return }
            if let data { consume(data) }
            if complete || error != nil { close() } else { receiveNext() }
        }
    }

    private func consume(_ data: Data) {
        receiveBuffer.append(data)
        guard receiveBuffer.count <= 2 * 1_024 * 1_024 else {
            cancel()
            return
        }
        while let newline = receiveBuffer.firstIndex(of: 0x0A) {
            let frame = receiveBuffer[..<newline]
            receiveBuffer.removeSubrange(...newline)
            guard !frame.isEmpty,
                  let message = try? JSONDecoder().decode(BridgeWireMessage.self, from: frame)
            else { continue }
            handleEnvelope(message)
        }
    }

    private func handleEnvelope(_ envelope: BridgeWireMessage) {
        if envelope.type == "hello" {
            guard !requestedApproval else { return }
            establishSession(with: envelope)
            return
        }
        guard envelope.type == "secure", let message = decrypt(envelope) else { return }
        if message.type == "pairingReady" {
            finishSessionSetup()
            return
        }
        guard approved else { return }
        handleSecure(message)
    }

    private func establishSession(with message: BridgeWireMessage) {
        guard WristRemoteHandshake.acceptsClient(message),
              let encoded = message.publicKey,
              let publicData = Data(base64Encoded: encoded),
              let publicKey = try? Curve25519.KeyAgreement.PublicKey(
                  rawRepresentation: publicData
              )
        else {
            cancel()
            return
        }
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        guard let sharedSecret = try? privateKey.sharedSecretFromKeyAgreement(with: publicKey) else {
            cancel()
            return
        }
        sessionKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(WristRemoteServer.sessionSalt.utf8),
            sharedInfo: Data(),
            outputByteCount: 32
        )
        switch WristRemoteIdentityVerifier.verify(
            identityPublicKey: message.identityPublicKey,
            identitySignature: message.identitySignature,
            sessionPublicKey: publicData
        ) {
        case .unavailable:
            identityFingerprint = nil
            waitsForPairingReady = false
        case let .verified(fingerprint):
            identityFingerprint = fingerprint
            waitsForPairingReady = true
        case .invalid:
            cancel()
            return
        }
        requestedApproval = true
        let trimmedName = message.deviceName?.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingName = trimmedName.flatMap { $0.isEmpty ? nil : String($0.prefix(80)) } ?? "iPhone"
        connectedDeviceName = pendingName ?? "Wrist Remote"
        pendingPairingCode = sessionKey.map(Self.pairingCode)
        sendPlain(BridgeWireMessage(
            type: "serverKey",
            protocolID: WristRemoteHandshake.protocolID,
            serverRole: WristRemoteHandshake.serverRole,
            publicKey: privateKey.publicKey.rawRepresentation.base64EncodedString()
        )) { [weak self] in
            guard let self, !waitsForPairingReady else { return }
            finishSessionSetup()
        }
    }

    private func finishSessionSetup() {
        guard requestedApproval,
              !approved,
              let name = pendingName,
              let pairingCode = pendingPairingCode
        else { return }
        pendingName = nil
        pendingPairingCode = nil
        if let identityFingerprint, isIdentityTrusted?(identityFingerprint) == true {
            approved = true
            sendReady()
            return
        }
        onApprovalRequested?(name, pairingCode, identityFingerprint)
    }

    private func sendReady() {
        sendSecure(BridgeWireMessage(
            type: "ready",
            protocolID: WristRemoteHandshake.protocolID,
            serverRole: WristRemoteHandshake.serverRole,
            deviceName: macName,
            buttonTitles: [:],
            appVersion: appVersion,
            capabilities: [
                BridgeWireMessage.voiceSessionsCapability,
                BridgeWireMessage.watchActionProfileCapability,
                BridgeWireMessage.codexTasksCapability,
                BridgeWireMessage.voiceOutcomesCapability,
                BridgeWireMessage.codexReplyReceiptsCapability,
                BridgeWireMessage.connectionLivenessCapability,
            ],
            watchApplicationTitles: applicationTitles,
            codexTask: codexTaskSnapshot,
            codexTaskCleared: codexTaskSnapshot == nil,
            codexTaskStateRevision: codexTaskStateRevision,
            speechLocaleIdentifier: speechLocaleIdentifier,
            internetRelayProvisioning: internetRelayProvisioning
        )) { [weak self] in
            guard let self else { return }
            onApproved?(connectedDeviceName)
        }
    }

    private func handleSecure(_ message: BridgeWireMessage) {
        switch message.type {
        case "livenessProbe":
            guard BridgeWireMessage.isValidProbeID(message.probeID),
                  let probeID = message.probeID
            else { return }
            sendSecure(BridgeWireMessage(type: "livenessAck", probeID: probeID))

        case "watchProfileUpdate":
            handleWatchProfileUpdate(message)

        case "buttonEvent":
            guard let command = message.command,
                  let button = WristRemoteButton(rawValue: command),
                  let rawPhase = message.buttonPhase,
                  let phase = WristRemoteButtonPhase(rawValue: rawPhase),
                  watchProfileSession.accepts(
                      inputSource: message.inputSource,
                      revision: message.profileRevision
                  ),
                  let onWatchButtonEvent
            else {
                sendWatchProfileRejected(
                    revision: message.profileRevision,
                    detail: "映射尚未确认，来源错误，或版本已经变化。"
                )
                return
            }
            onWatchButtonEvent(button, phase) { [weak self] succeeded in
                self?.queue.async {
                    if !succeeded { self?.sendOperationError("该动作当前不可用。") }
                }
            }

        case "voiceStart":
            let parsedIntent = message.voiceIntent.flatMap(WatchVoiceIntent.init(rawValue:))
            let parsedTarget = parsedIntent.flatMap {
                voiceTarget(from: message, intent: $0)
            }
            guard let intent = parsedIntent,
                  let target = parsedTarget,
                  acceptsVoiceTarget(target),
                  watchProfileSession.accepts(
                inputSource: message.inputSource,
                revision: message.profileRevision
            ), voiceSession.begin(
                sessionID: message.sessionID,
                inputSource: message.inputSource,
                profileRevision: message.profileRevision,
                acceptedProfileRevision: watchProfileSession.acceptedProfile?.revision
            ) else {
                sendVoiceRejected(
                    sessionID: message.sessionID,
                    profileRevision: message.profileRevision,
                    target: parsedTarget
                )
                return
            }
            activeVoiceIntent = intent
            activeVoiceCodexTaskIdentity = target.codexTaskIdentity
            activeVoiceSessionID = message.sessionID
            guard let onVoiceStart else {
                _ = voiceSession.completeStart(succeeded: false)
                clearActiveVoiceTarget()
                sendVoiceRejected(
                    sessionID: message.sessionID,
                    profileRevision: message.profileRevision,
                    target: target
                )
                return
            }
            onVoiceStart(
                message.sessionID,
                intent,
                target.codexTaskIdentity
            ) { [weak self] succeeded in
                self?.queue.async {
                    guard let self,
                          let identity = self.voiceSession.completeStart(succeeded: succeeded)
                    else { return }
                    self.sendSecure(BridgeWireMessage(
                        type: succeeded ? "voiceReady" : "voiceRejected",
                        sessionID: identity.sessionID.uuidString,
                        inputSource: BridgeWireMessage.appleWatchInputSource,
                        profileRevision: identity.profileRevision,
                        voiceIntent: target.intent.rawValue,
                        threadID: target.codexTaskIdentity?.threadID,
                        turnID: target.codexTaskIdentity?.turnID,
                        taskRevision: target.codexTaskIdentity?.revision
                    ))
                    if succeeded {
                        self.awaitingVoiceOutcomes[identity.sessionID.uuidString] = target
                    } else {
                        self.clearActiveVoiceTarget()
                    }
                }
            }

        case "voiceStop":
            if messageMatchesActiveVoiceTarget(message), voiceSession.stop(
                sessionID: message.sessionID,
                inputSource: message.inputSource,
                profileRevision: message.profileRevision,
                acceptedProfileRevision: watchProfileSession.acceptedProfile?.revision
            ) {
                onVoiceStop?()
                clearActiveVoiceTarget()
            }

        case "audio":
            guard watchProfileSession.accepts(
                      inputSource: message.inputSource,
                      revision: message.profileRevision
                  ),
                  voiceSession.acceptsAudio(
                      sessionID: message.sessionID,
                      inputSource: message.inputSource,
                      profileRevision: message.profileRevision,
                      acceptedProfileRevision: watchProfileSession.acceptedProfile?.revision
                  ),
                  messageMatchesActiveVoiceTarget(message),
                  let encoded = message.samples,
                  let data = Data(base64Encoded: encoded),
                  data.count.isMultiple(of: MemoryLayout<Int16>.size)
            else { return }
            onAudio?(Self.samples(from: data))

        case "codexReplySubmit":
            let text = message.transcript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard let rawSubmissionID = message.submissionID,
                  let submissionID = UUID(uuidString: rawSubmissionID),
                  submissionID.uuidString == rawSubmissionID,
                  let identity = wireCodexTaskIdentity(from: message)
            else {
                sendOperationError("Codex 回复缺少有效提交身份，语音未发送。")
                return
            }
            guard
                  WatchCodexTaskIdentity(codexTaskSnapshot) == identity,
                  codexTaskSnapshot?.state == .completed,
                  !text.isEmpty,
                  text.count <= 2_000,
                  let onCodexReplySubmit
            else {
                let detail = "Codex 任务已变化，语音未发送。"
                sendCodexReplyResult(
                    submissionID: submissionID,
                    identity: identity,
                    accepted: false,
                    detail: detail
                )
                sendOperationError(detail)
                return
            }
            onCodexReplySubmit(submissionID, identity, text) { [weak self] accepted, detail in
                self?.queue.async {
                    guard let self else { return }
                    self.sendCodexReplyResult(
                        submissionID: submissionID,
                        identity: identity,
                        accepted: accepted,
                        detail: detail
                    )
                    if !accepted {
                        self.sendOperationError(detail ?? "Codex 暂时无法接收回复。")
                    }
                }
            }

        case "command":
            // This service accepts only the dedicated Wrist Remote protocol.
            sendOperationError("腕上遥控桥只接受 Apple Watch 独立映射事件。")

        default:
            break
        }
    }

    private func handleWatchProfileUpdate(_ message: BridgeWireMessage) {
        guard WatchProfileSession.acceptsProfileUpdateSource(
                  inputSource: message.inputSource
              ),
              let encoded = message.watchProfile,
              let profile = try? WatchActionProfileWire.decodeBase64(encoded),
              message.profileRevision == profile.revision
        else {
            sendWatchProfileRejected(revision: message.profileRevision, detail: "映射数据无效。")
            return
        }
        if let retryReason = WatchProfileRuntimeUpdatePolicy.retryReason(for: voiceSession) {
            sendWatchProfileRejected(
                revision: profile.revision,
                detail: "语音进行中，独立映射保持不变；结束语音后将自动重试。",
                retryReason: retryReason
            )
            return
        }
        switch watchProfileSession.begin(profile) {
        case let .alreadyReady(revision):
            sendWatchProfileReady(revision)
        case let .reject(revision, detail):
            sendWatchProfileRejected(revision: revision, detail: detail)
        case let .accept(profile):
            guard let onWatchProfileUpdate else {
                _ = watchProfileSession.complete(revision: profile.revision, succeeded: false)
                sendWatchProfileRejected(revision: profile.revision, detail: "无法安装映射。")
                return
            }
            onWatchProfileUpdate(profile) { [weak self] result in
                self?.queue.async {
                    guard let self,
                          let accepted = self.watchProfileSession.complete(
                              revision: profile.revision,
                              succeeded: result.isAccepted
                          )
                    else { return }
                    if accepted {
                        self.sendWatchProfileReady(profile.revision)
                    } else {
                        let retryReason: WatchProfileUpdateRetryReason?
                        let detail: String
                        switch result {
                        case .accepted:
                            retryReason = nil
                            detail = "无法安装映射。"
                        case .rejected:
                            retryReason = nil
                            detail = "映射引用了腕上遥控桥中不存在的独立 App。"
                        case let .retryable(reason):
                            retryReason = reason
                            detail = "语音进行中，独立映射保持不变；结束语音后将自动重试。"
                        }
                        self.sendWatchProfileRejected(
                            revision: profile.revision,
                            detail: detail,
                            retryReason: retryReason
                        )
                    }
                }
            }
        }
    }

    private func sendWatchProfileReady(_ revision: Int) {
        sendSecure(BridgeWireMessage(type: "watchProfileReady", profileRevision: revision))
    }

    private func sendWatchProfileRejected(
        revision: Int?,
        detail: String,
        retryReason: WatchProfileUpdateRetryReason? = nil
    ) {
        sendSecure(BridgeWireMessage(
            type: "watchProfileRejected",
            detail: detail,
            profileRevision: revision,
            profileUpdateRetryReason: retryReason
        ))
    }

    private func sendVoiceRejected(
        sessionID: String?,
        profileRevision: Int?,
        target: VoiceTarget?
    ) {
        sendSecure(BridgeWireMessage(
            type: "voiceRejected",
            sessionID: sessionID,
            inputSource: BridgeWireMessage.appleWatchInputSource,
            profileRevision: profileRevision,
            voiceIntent: target?.intent.rawValue,
            threadID: target?.codexTaskIdentity?.threadID,
            turnID: target?.codexTaskIdentity?.turnID,
            taskRevision: target?.codexTaskIdentity?.revision
        ))
    }

    private func sendOperationError(_ detail: String) {
        sendSecure(BridgeWireMessage(type: "error", detail: detail))
    }

    private func sendCodexReplyResult(
        submissionID: UUID,
        identity: WatchCodexTaskIdentity,
        accepted: Bool,
        detail: String?
    ) {
        sendSecure(BridgeWireMessage(
            type: "codexReplyResult",
            detail: detail,
            threadID: identity.threadID,
            turnID: identity.turnID,
            taskRevision: identity.revision,
            submissionID: submissionID.uuidString,
            accepted: accepted
        ))
    }

    private func acceptsVoiceTarget(_ target: VoiceTarget) -> Bool {
        switch target.intent {
        case .foregroundDictation:
            return target.codexTaskIdentity == nil
        case .codexTask:
            return WristRemoteCodexTargetValidator.accepts(
                target.codexTaskIdentity,
                snapshot: codexTaskSnapshot
            )
        }
    }

    private func voiceTarget(
        from message: BridgeWireMessage,
        intent: WatchVoiceIntent
    ) -> VoiceTarget? {
        let identity = wireCodexTaskIdentity(from: message)
        switch intent {
        case .foregroundDictation:
            guard message.threadID == nil,
                  message.turnID == nil,
                  message.taskRevision == nil
            else { return nil }
        case .codexTask:
            guard identity != nil else { return nil }
        }
        return VoiceTarget(intent: intent, codexTaskIdentity: identity)
    }

    private func wireCodexTaskIdentity(
        from message: BridgeWireMessage
    ) -> WatchCodexTaskIdentity? {
        WatchCodexTaskIdentity(
            threadID: message.threadID,
            turnID: message.turnID,
            revision: message.taskRevision
        )
    }

    private func messageMatchesActiveVoiceTarget(_ message: BridgeWireMessage) -> Bool {
        message.voiceIntent == activeVoiceIntent.rawValue
            && wireCodexTaskIdentity(from: message) == activeVoiceCodexTaskIdentity
            && (activeVoiceIntent == .codexTask
                || (message.threadID == nil
                    && message.turnID == nil
                    && message.taskRevision == nil))
    }

    private func clearActiveVoiceTarget() {
        activeVoiceIntent = .foregroundDictation
        activeVoiceCodexTaskIdentity = nil
        activeVoiceSessionID = nil
    }

    private func close() {
        guard !closed else { return }
        closed = true
        if voiceSession.stop(sessionID: nil, force: true) { onVoiceStop?() }
        clearActiveVoiceTarget()
        awaitingVoiceOutcomes.removeAll()
        watchProfileSession.reset()
        connection.stateUpdateHandler = nil
        connection.cancel()
        sessionKey = nil
        onClosed?(approved, requestedApproval && !approved)
        onClosed = nil
    }

    private func sendSecure(
        _ message: BridgeWireMessage,
        completion: (() -> Void)? = nil
    ) {
        guard let sessionKey,
              let cleartext = try? JSONEncoder().encode(message),
              let sealed = try? ChaChaPoly.seal(cleartext, using: sessionKey)
        else { return }
        sendPlain(BridgeWireMessage(
            type: "secure",
            payload: sealed.combined.base64EncodedString()
        ), completion: completion)
    }

    private func sendPlain(
        _ message: BridgeWireMessage,
        completion: (() -> Void)? = nil
    ) {
        guard var data = try? JSONEncoder().encode(message) else { return }
        data.append(0x0A)
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard error == nil else {
                self?.cancel()
                return
            }
            completion?()
        })
    }

    private func decrypt(_ envelope: BridgeWireMessage) -> BridgeWireMessage? {
        guard let sessionKey,
              let encoded = envelope.payload,
              let data = Data(base64Encoded: encoded),
              let sealed = try? ChaChaPoly.SealedBox(combined: data),
              let cleartext = try? ChaChaPoly.open(sealed, using: sessionKey)
        else { return nil }
        return try? JSONDecoder().decode(BridgeWireMessage.self, from: cleartext)
    }

    private static func pairingCode(_ key: SymmetricKey) -> String {
        let value = key.withUnsafeBytes { bytes in
            bytes.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }
        return String(format: "%06d", value % 1_000_000)
    }

    private static func samples(from data: Data) -> [Int16] {
        var samples = [Int16]()
        samples.reserveCapacity(data.count / 2)
        var index = data.startIndex
        while index < data.endIndex {
            let next = data.index(after: index)
            let low = UInt16(data[index])
            let high = UInt16(data[next]) << 8
            samples.append(Int16(bitPattern: low | high))
            index = data.index(next, offsetBy: 1)
        }
        return samples
    }

}
