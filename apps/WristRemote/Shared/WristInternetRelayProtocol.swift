import CryptoKit
import Foundation
import Security

enum WristInternetRelayConfiguration {
    /// Version 3 carries the Watch-side button commit time in addition to the
    /// resolved gesture, so an action cannot execute after a long offline or
    /// HTTP queue delay.
    static let protocolVersion = 3
    static var productionBaseURL: URL {
        guard let rawValue = Bundle.main.object(
            forInfoDictionaryKey: "WristRemoteRelayBaseURL"
        ) as? String,
        let configuredURL = URL(string: rawValue),
        configuredURL.scheme == "https",
        configuredURL.host != nil
        else {
            // RFC 2606's .invalid TLD is deliberately unreachable. This makes
            // local-only builds safe until the developer opts into a relay.
            return URL(string: "https://relay.example.invalid")!
        }
        return configuredURL
    }
    static let maximumClockSkewMilliseconds: Int64 = 30_000
    static let maximumFrameLifetimeMilliseconds: Int64 = 30_000
    static let normalFrameLifetimeMilliseconds: Int64 = 10_000
    static let maximumCiphertextBytes = 512 * 1_024

    static func supportsServerProtocolVersion(_ version: Int) -> Bool {
        version == protocolVersion
    }
}

enum WristInternetRelayRequestBudget {
    static let timeoutMilliseconds = 22_000
}

/// A voice start can arrive while one older status request still owns the
/// serialized HTTP client. Keep the UI handshake alive for both complete
/// request budgets plus a small scheduling margin.
enum WristInternetVoiceStartPolicy {
    static let replyTimeoutMilliseconds =
        WristInternetRelayRequestBudget.timeoutMilliseconds * 2 + 6_000
}

/// The bridge stops a public voice capture if the Watch disappears without a
/// stop operation. This must outlive the full Watch HTTP reply budget while a
/// WebSocket disconnect still stops capture immediately.
enum WristInternetVoiceLeasePolicy {
    /// One unrelated request can already own the actor's serial HTTP slot when
    /// audio becomes ready. Cover that request plus the following audio request
    /// and a scheduling margin before abandoning the Mac capture.
    static let timeoutMilliseconds =
        WristInternetRelayRequestBudget.timeoutMilliseconds * 2 + 6_000
}

/// Voice-stop returns before the Watch begins polling status for the eventual
/// transcription outcome. The polling window must outlive one complete status
/// request, otherwise a valid response at the HTTP deadline can be discarded.
enum WristInternetVoiceOutcomePollingPolicy {
    static let intervalMilliseconds = 750
    static let timeoutMilliseconds =
        WristInternetRelayRequestBudget.timeoutMilliseconds + 6_000
    static let attemptCount =
        (timeoutMilliseconds + intervalMilliseconds - 1) / intervalMilliseconds
}

/// Public button actions are intentionally not an offline command queue. A
/// small, short-lived FIFO preserves ordering during one slow round trip, then
/// drops stale taps instead of executing them unexpectedly later.
enum WristInternetButtonQueuePolicy {
    static let maximumPendingEventCount = 6
    static let maximumEventAgeMilliseconds = 3_000
    static let maximumFutureClockSkewMilliseconds = 2_000

    static func canEnqueue(pendingEventCount: Int) -> Bool {
        pendingEventCount >= 0 && pendingEventCount < maximumPendingEventCount
    }

    static func isFresh(committedAt: Date, now: Date) -> Bool {
        isFresh(
            committedAtEpochMilliseconds: Int64(
                (committedAt.timeIntervalSince1970 * 1_000).rounded()
            ),
            nowEpochMilliseconds: Int64((now.timeIntervalSince1970 * 1_000).rounded())
        )
    }

    static func isFresh(
        committedAtEpochMilliseconds: Int64,
        nowEpochMilliseconds: Int64
    ) -> Bool {
        let ageMilliseconds = nowEpochMilliseconds - committedAtEpochMilliseconds
        return ageMilliseconds >= -Int64(maximumFutureClockSkewMilliseconds)
            && ageMilliseconds <= Int64(maximumEventAgeMilliseconds)
    }
}

/// Keeps live Watch microphone traffic ahead of typical cellular round-trip
/// latency without making the first packet unnecessarily large. A request
/// starts after five 80 ms packets, then drains up to ten packets per round
/// trip whenever latency has allowed a backlog to form.
enum WristInternetAudioBatchingPolicy {
    static let preferredPacketCount = 5
    static let maximumPacketCount = 10
    static let maximumBufferedPacketCount = 350
    static let baseFinalAckTimeoutMilliseconds = 20_000
    static let extraMillisecondsPerPendingBatch =
        WristInternetRelayRequestBudget.timeoutMilliseconds
    static let maximumPendingBatchCount =
        (maximumBufferedPacketCount + maximumPacketCount * 2 - 1)
            / maximumPacketCount
    static let maximumFinalAckTimeoutMilliseconds =
        baseFinalAckTimeoutMilliseconds
            + maximumPendingBatchCount * extraMillisecondsPerPendingBatch

    static func shouldFlush(bufferedPacketCount: Int, isFinal: Bool) -> Bool {
        bufferedPacketCount >= preferredPacketCount
            || (isFinal && bufferedPacketCount > 0)
    }

    static func nextPacketCount(bufferedPacketCount: Int) -> Int {
        min(maximumPacketCount, max(0, bufferedPacketCount))
    }

    static func canBuffer(packetCount: Int) -> Bool {
        packetCount >= 0 && packetCount <= maximumBufferedPacketCount
    }

    static func finalAckTimeoutMilliseconds(
        sentPacketCount: UInt64,
        contiguousAcknowledgement: UInt64?
    ) -> Int {
        let acknowledgedPacketCount: UInt64
        if let contiguousAcknowledgement {
            acknowledgedPacketCount = min(sentPacketCount, contiguousAcknowledgement &+ 1)
        } else {
            acknowledgedPacketCount = 0
        }
        let pendingPacketCount = sentPacketCount - acknowledgedPacketCount
        let pendingBatchCount = pendingPacketCount == 0
            ? 0
            : (pendingPacketCount + UInt64(maximumPacketCount) - 1)
                / UInt64(maximumPacketCount)
        let boundedBatchCount = min(
            pendingBatchCount,
            UInt64((maximumFinalAckTimeoutMilliseconds
                - baseFinalAckTimeoutMilliseconds)
                / extraMillisecondsPerPendingBatch)
        )
        return baseFinalAckTimeoutMilliseconds
            + Int(boundedBatchCount) * extraMillisecondsPerPendingBatch
    }
}

enum WristInternetRelayDirection: String, Codable, Sendable {
    case deviceToMac
    case macToDevice
}

enum WristInternetRelayOperationKind: String, Codable, Sendable {
    case status
    case profileUpdate
    case buttonEvent
    case voiceStart
    case audio
    case voiceStop
    case codexReplySubmit
}

enum WristInternetRelayButtonTrigger: String, Codable, CaseIterable, Sendable {
    case singleClick
    case doubleClick
    case longPress
}

enum WristInternetButtonGesturePolicy {
    static let doubleClickCommitDelayMilliseconds = 320
    static let longPressCommitDelayMilliseconds = 620
}

struct WristInternetRelayOperation: Codable, Equatable, Sendable {
    let protocolVersion: Int
    let operationID: UUID
    let kind: WristInternetRelayOperationKind
    var profileRevision: Int?
    var command: WatchRemoteCommand?
    var buttonTrigger: WristInternetRelayButtonTrigger?
    var buttonCommittedAtEpochMilliseconds: Int64?
    var watchProfile: WatchActionProfileWire?
    var streamID: UUID?
    var voiceIntent: WatchVoiceIntent?
    var codexTaskIdentity: WatchCodexTaskIdentity?
    var audioSequence: UInt64?
    var pcm16Data: Data?
    var finalSequence: UInt64?
    var submissionID: UUID?
    var transcript: String?

    init(
        operationID: UUID = UUID(),
        kind: WristInternetRelayOperationKind,
        profileRevision: Int? = nil,
        command: WatchRemoteCommand? = nil,
        buttonTrigger: WristInternetRelayButtonTrigger? = nil,
        buttonCommittedAtEpochMilliseconds: Int64? = nil,
        watchProfile: WatchActionProfileWire? = nil,
        streamID: UUID? = nil,
        voiceIntent: WatchVoiceIntent? = nil,
        codexTaskIdentity: WatchCodexTaskIdentity? = nil,
        audioSequence: UInt64? = nil,
        pcm16Data: Data? = nil,
        finalSequence: UInt64? = nil,
        submissionID: UUID? = nil,
        transcript: String? = nil
    ) {
        protocolVersion = WristInternetRelayConfiguration.protocolVersion
        self.operationID = operationID
        self.kind = kind
        self.profileRevision = profileRevision
        self.command = command
        self.buttonTrigger = buttonTrigger
        self.buttonCommittedAtEpochMilliseconds = buttonCommittedAtEpochMilliseconds
        self.watchProfile = watchProfile
        self.streamID = streamID
        self.voiceIntent = voiceIntent
        self.codexTaskIdentity = codexTaskIdentity
        self.audioSequence = audioSequence
        self.pcm16Data = pcm16Data
        self.finalSequence = finalSequence
        self.submissionID = submissionID
        self.transcript = transcript
    }

    func validated() -> WristInternetRelayOperation? {
        guard protocolVersion == WristInternetRelayConfiguration.protocolVersion else { return nil }
        switch kind {
        case .status:
            guard profileRevision == nil,
                  command == nil,
                  buttonTrigger == nil,
                  buttonCommittedAtEpochMilliseconds == nil,
                  watchProfile == nil,
                  streamID == nil,
                  voiceIntent == nil,
                  codexTaskIdentity == nil,
                  audioSequence == nil,
                  pcm16Data == nil,
                  finalSequence == nil,
                  submissionID == nil,
                  transcript == nil
            else { return nil }
        case .profileUpdate:
            guard let watchProfile,
                  let normalized = try? watchProfile.validatedAndNormalized(),
                  normalized == watchProfile,
                  profileRevision == watchProfile.revision,
                  command == nil,
                  buttonTrigger == nil,
                  buttonCommittedAtEpochMilliseconds == nil,
                  streamID == nil,
                  voiceIntent == nil,
                  codexTaskIdentity == nil,
                  audioSequence == nil,
                  pcm16Data == nil,
                  finalSequence == nil,
                  submissionID == nil,
                  transcript == nil
            else { return nil }
        case .buttonEvent:
            guard let profileRevision,
                  profileRevision >= 0,
                  command != nil,
                  buttonTrigger != nil,
                  let buttonCommittedAtEpochMilliseconds,
                  buttonCommittedAtEpochMilliseconds > 0,
                  watchProfile == nil,
                  streamID == nil,
                  voiceIntent == nil,
                  codexTaskIdentity == nil,
                  audioSequence == nil,
                  pcm16Data == nil,
                  finalSequence == nil,
                  submissionID == nil,
                  transcript == nil
            else { return nil }
        case .voiceStart:
            guard validVoiceShape,
                  let profileRevision,
                  profileRevision >= 0,
                  streamID != nil,
                  command == nil,
                  buttonTrigger == nil,
                  buttonCommittedAtEpochMilliseconds == nil,
                  watchProfile == nil,
                  audioSequence == nil,
                  pcm16Data == nil,
                  finalSequence == nil,
                  submissionID == nil,
                  transcript == nil
            else { return nil }
        case .audio:
            guard let profileRevision,
                  profileRevision >= 0,
                  streamID != nil,
                  audioSequence != nil,
                  let pcm16Data,
                  !pcm16Data.isEmpty,
                  pcm16Data.count <= 32 * 1_024,
                  pcm16Data.count.isMultiple(of: MemoryLayout<Int16>.size),
                  command == nil,
                  buttonTrigger == nil,
                  buttonCommittedAtEpochMilliseconds == nil,
                  watchProfile == nil,
                  voiceIntent == nil,
                  codexTaskIdentity == nil,
                  finalSequence == nil,
                  submissionID == nil,
                  transcript == nil
            else { return nil }
        case .voiceStop:
            guard validVoiceShape,
                  let profileRevision,
                  profileRevision >= 0,
                  streamID != nil,
                  command == nil,
                  buttonTrigger == nil,
                  buttonCommittedAtEpochMilliseconds == nil,
                  watchProfile == nil,
                  audioSequence == nil,
                  pcm16Data == nil,
                  submissionID == nil,
                  transcript == nil
            else { return nil }
        case .codexReplySubmit:
            guard let transcript,
                  !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  transcript.count <= 2_000,
                  submissionID != nil,
                  codexTaskIdentity != nil,
                  profileRevision == nil,
                  command == nil,
                  buttonTrigger == nil,
                  buttonCommittedAtEpochMilliseconds == nil,
                  watchProfile == nil,
                  streamID == nil,
                  voiceIntent == nil,
                  audioSequence == nil,
                  pcm16Data == nil,
                  finalSequence == nil
            else { return nil }
        }
        return self
    }

    func hasFreshButtonCommit(now: Date = Date()) -> Bool {
        guard kind == .buttonEvent,
              let buttonCommittedAtEpochMilliseconds
        else { return false }
        let nowMilliseconds = Int64((now.timeIntervalSince1970 * 1_000).rounded())
        return WristInternetButtonQueuePolicy.isFresh(
            committedAtEpochMilliseconds: buttonCommittedAtEpochMilliseconds,
            nowEpochMilliseconds: nowMilliseconds
        )
    }

    private var validVoiceShape: Bool {
        guard let voiceIntent else { return false }
        switch voiceIntent {
        case .foregroundDictation: return codexTaskIdentity == nil
        case .codexTask: return codexTaskIdentity != nil
        }
    }
}

struct WristInternetRelayStatus: Codable, Equatable, Sendable {
    let macName: String
    let profileRevision: Int?
    let buttonTitles: [String: String]
    /// Enabled gestures per command. The Watch uses this to resolve timing
    /// locally, so WAN latency cannot split a double-click or invent a hold.
    let buttonTriggers: [String: [WristInternetRelayButtonTrigger]]
    let voiceOwner: WatchRemoteProtocol.VoiceOwner
    let codexTask: WatchCodexTaskSnapshot?
    let codexTaskStateRevision: Int
    let voiceOutcome: WatchVoiceOutcome?
    let speechLocaleIdentifier: String
}

struct WristInternetRelayResult: Codable, Equatable, Sendable {
    let protocolVersion: Int
    let operationID: UUID
    let accepted: Bool
    let detail: String?
    let status: WristInternetRelayStatus?
    let audioAcknowledgement: WatchRemoteAudioAcknowledgement?
    let profileUpdateRetryReason: WatchProfileUpdateRetryReason?

    init(
        operationID: UUID,
        accepted: Bool,
        detail: String? = nil,
        status: WristInternetRelayStatus? = nil,
        audioAcknowledgement: WatchRemoteAudioAcknowledgement? = nil,
        profileUpdateRetryReason: WatchProfileUpdateRetryReason? = nil
    ) {
        protocolVersion = WristInternetRelayConfiguration.protocolVersion
        self.operationID = operationID
        self.accepted = accepted
        self.detail = detail
        self.status = status
        self.audioAcknowledgement = audioAcknowledgement
        self.profileUpdateRetryReason = profileUpdateRetryReason
    }

    func isValid(for operationID: UUID) -> Bool {
        protocolVersion == WristInternetRelayConfiguration.protocolVersion
            && self.operationID == operationID
            && (detail?.count ?? 0) <= 300
            && (profileUpdateRetryReason == nil || !accepted)
    }
}

struct WristInternetRelayFrame: Codable, Equatable, Sendable {
    let protocolVersion: Int
    let operationID: UUID
    let senderID: UUID
    let sequence: UInt64
    let issuedAtEpochMilliseconds: Int64
    let expiresAtEpochMilliseconds: Int64
    let direction: WristInternetRelayDirection
    let ciphertext: Data

    private struct Header: Codable {
        let protocolVersion: Int
        let operationID: UUID
        let senderID: UUID
        let sequence: UInt64
        let issuedAtEpochMilliseconds: Int64
        let expiresAtEpochMilliseconds: Int64
        let direction: WristInternetRelayDirection
    }

    static func seal<T: Encodable>(
        _ value: T,
        operationID: UUID,
        senderID: UUID,
        sequence: UInt64,
        direction: WristInternetRelayDirection,
        keyData: Data,
        now: Date = Date(),
        lifetimeMilliseconds: Int64 = WristInternetRelayConfiguration
            .normalFrameLifetimeMilliseconds
    ) throws -> WristInternetRelayFrame {
        guard keyData.count == 32,
              lifetimeMilliseconds > 0,
              lifetimeMilliseconds <= WristInternetRelayConfiguration
                .maximumFrameLifetimeMilliseconds
        else { throw WristInternetRelayCryptoError.invalidCredentials }
        let issuedAt = Int64((now.timeIntervalSince1970 * 1_000).rounded())
        let header = Header(
            protocolVersion: WristInternetRelayConfiguration.protocolVersion,
            operationID: operationID,
            senderID: senderID,
            sequence: sequence,
            issuedAtEpochMilliseconds: issuedAt,
            expiresAtEpochMilliseconds: issuedAt + lifetimeMilliseconds,
            direction: direction
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let cleartext = try encoder.encode(value)
        let authenticatedData = try encoder.encode(header)
        let sealed = try ChaChaPoly.seal(
            cleartext,
            using: SymmetricKey(data: keyData),
            authenticating: authenticatedData
        )
        guard sealed.combined.count <= WristInternetRelayConfiguration.maximumCiphertextBytes else {
            throw WristInternetRelayCryptoError.payloadTooLarge
        }
        return WristInternetRelayFrame(
            protocolVersion: header.protocolVersion,
            operationID: header.operationID,
            senderID: header.senderID,
            sequence: header.sequence,
            issuedAtEpochMilliseconds: header.issuedAtEpochMilliseconds,
            expiresAtEpochMilliseconds: header.expiresAtEpochMilliseconds,
            direction: header.direction,
            ciphertext: sealed.combined
        )
    }

    func open<T: Decodable>(
        _ type: T.Type,
        direction expectedDirection: WristInternetRelayDirection,
        operationID expectedOperationID: UUID? = nil,
        keyData: Data,
        now: Date = Date()
    ) throws -> T {
        guard keyData.count == 32 else {
            throw WristInternetRelayCryptoError.invalidCredentials
        }
        guard isFresh(now: now),
              direction == expectedDirection,
              expectedOperationID.map({ $0 == operationID }) != false,
              ciphertext.count <= WristInternetRelayConfiguration.maximumCiphertextBytes
        else { throw WristInternetRelayCryptoError.invalidFrame }
        let header = Header(
            protocolVersion: protocolVersion,
            operationID: operationID,
            senderID: senderID,
            sequence: sequence,
            issuedAtEpochMilliseconds: issuedAtEpochMilliseconds,
            expiresAtEpochMilliseconds: expiresAtEpochMilliseconds,
            direction: direction
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let authenticatedData = try encoder.encode(header)
        let box = try ChaChaPoly.SealedBox(combined: ciphertext)
        let cleartext = try ChaChaPoly.open(
            box,
            using: SymmetricKey(data: keyData),
            authenticating: authenticatedData
        )
        return try JSONDecoder().decode(type, from: cleartext)
    }

    func isFresh(now: Date = Date()) -> Bool {
        guard protocolVersion == WristInternetRelayConfiguration.protocolVersion,
              expiresAtEpochMilliseconds > issuedAtEpochMilliseconds,
              expiresAtEpochMilliseconds - issuedAtEpochMilliseconds
                <= WristInternetRelayConfiguration.maximumFrameLifetimeMilliseconds
        else { return false }
        let nowMilliseconds = Int64((now.timeIntervalSince1970 * 1_000).rounded())
        return issuedAtEpochMilliseconds
            <= nowMilliseconds + WristInternetRelayConfiguration.maximumClockSkewMilliseconds
            && expiresAtEpochMilliseconds
                >= nowMilliseconds - WristInternetRelayConfiguration.maximumClockSkewMilliseconds
    }
}

struct WristInternetReplayWindow: Equatable, Sendable {
    private var lastSequenceBySender: [UUID: UInt64] = [:]

    mutating func accept(
        _ frame: WristInternetRelayFrame,
        direction: WristInternetRelayDirection,
        now: Date = Date()
    ) -> Bool {
        guard frame.direction == direction, frame.isFresh(now: now) else { return false }
        if let lastSequence = lastSequenceBySender[frame.senderID],
           frame.sequence <= lastSequence {
            return false
        }
        lastSequenceBySender[frame.senderID] = frame.sequence
        return true
    }
}

struct WristInternetRelayDeviceProvisioning: Codable, Equatable, Sendable {
    let baseURL: URL
    let roomID: UUID
    let deviceID: UUID
    let deviceToken: Data
    let encryptionKey: Data

    var isValid: Bool {
        baseURL.scheme == "https"
            && baseURL.host != nil
            && roomID.uuidString.count == 36
            && deviceToken.count == 32
            && encryptionKey.count == 32
    }

    func encodedBase64() -> String? {
        guard isValid else { return nil }
        return try? JSONEncoder().encode(self).base64EncodedString()
    }

    static func decodeBase64(_ encoded: String) -> WristInternetRelayDeviceProvisioning? {
        guard let data = Data(base64Encoded: encoded),
              data.count <= 4_096,
              let value = try? JSONDecoder().decode(Self.self, from: data),
              value.isValid
        else { return nil }
        return value
    }
}

struct WristInternetRelayMacCredentials: Codable, Equatable, Sendable {
    let provisioning: WristInternetRelayDeviceProvisioning
    let macToken: Data

    var isValid: Bool { provisioning.isValid && macToken.count == 32 }

    static func generate(
        baseURL: URL = WristInternetRelayConfiguration.productionBaseURL
    ) throws -> WristInternetRelayMacCredentials {
        let credentials = WristInternetRelayMacCredentials(
            provisioning: WristInternetRelayDeviceProvisioning(
                baseURL: baseURL,
                roomID: UUID(),
                deviceID: UUID(),
                deviceToken: try randomData(count: 32),
                encryptionKey: try randomData(count: 32)
            ),
            macToken: try randomData(count: 32)
        )
        guard credentials.isValid else {
            throw WristInternetRelayCryptoError.invalidCredentials
        }
        return credentials
    }

    private static func randomData(count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw WristInternetRelayCryptoError.randomGenerationFailed
        }
        return data
    }
}

enum WristInternetRelayCryptoError: Error, Equatable {
    case invalidCredentials
    case invalidFrame
    case payloadTooLarge
    case randomGenerationFailed
}

enum WristInternetRelayKeychain {
    static func load<T: Decodable>(
        _ type: T.Type,
        account: String,
        service: String
    ) -> T? {
        var query = baseQuery(account: account, service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    @discardableResult
    static func save<T: Encodable>(
        _ value: T,
        account: String,
        service: String
    ) -> Bool {
        guard let data = try? JSONEncoder().encode(value) else { return false }
        let query = baseQuery(account: account, service: service)
        let update: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }
        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func delete(account: String, service: String) -> Bool {
        let status = SecItemDelete(baseQuery(account: account, service: service) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static func baseQuery(account: String, service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

extension Data {
    func wristBase64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
