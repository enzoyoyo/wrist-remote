import CryptoKit
import Foundation

struct WristBridgeWireMessage: Codable, Equatable {
    enum InternetRelayProvisioningDirective: Equatable {
        case install(String)
        case clear
    }

    static let protocolID = "dev.wristremote.bridge.protocol.v1"
    static let clientRole = "wristRemoteClient"
    static let serverRole = "wristRemoteBridge"
    static let serviceType = "_wristremote._tcp"
    static let sessionSalt = "WristRemoteBridge nearby session"
    static let serverIdentityProofDomain = "WristRemoteBridge server identity v1"
    static let clientAuthenticationProofDomain = "WristRemoteBridge client auth v1"
    static let sessionTranscriptDomain = "WristRemoteBridge session transcript v1"
    static let secureEnvelopeDomain = "WristRemoteBridge secure envelope v1"
    static let serverIdentityVersion = 1
    static let serverIdentityCapability = "serverIdentityV1"
    static let voiceSessionsCapability = "voiceSessionsV1"
    static let watchActionProfileCapability = "watchActionProfileV1"
    static let codexTasksCapability = "codexTasksV2"
    static let voiceOutcomesCapability = "voiceOutcomesV1"
    static let codexReplyReceiptsCapability = "codexReplyReceiptsV1"
    static let codexConversationsCapability = "codexConversationsV1"
    static let connectionLivenessCapability = "connectionLivenessV1"
    static let secureSequenceCapability = "secureSequenceV1"
    static let audioDeliveryReceiptsCapability = "audioDeliveryReceiptsV1"
    static let appleWatchInputSource = "appleWatch"

    // Transitional aliases keep the sidecar source concise while both targets
    // compile this single wire schema.
    static let wristRemoteProtocolID = protocolID
    static let wristRemoteClientRole = clientRole
    static let wristRemoteServerRole = serverRole

    let type: String
    var protocolID: String?
    var clientRole: String?
    var serverRole: String?
    var deviceName: String?
    var command: String?
    var samples: String?
    var detail: String?
    var publicKey: String?
    var identityPublicKey: String?
    var identitySignature: String?
    var serverIdentityVersion: Int?
    var serverIdentityPublicKey: String?
    var serverIdentitySignature: String?
    var serverIdentityPinned: Bool?
    var buttonTitles: [String: String]?
    var appVersion: String?
    var payload: String?
    var sequence: UInt64?
    var audioSequence: UInt64?
    var audioAccepted: Bool?
    var audioContiguousThrough: UInt64?
    var capabilities: [String]?
    var buttonPhase: String?
    var sessionID: String?
    var inputSource: String?
    var profileRevision: Int?
    var watchProfile: String?
    var watchApplicationTitles: [String: String]?
    var codexTask: WatchCodexTaskSnapshot?
    var codexTaskCleared: Bool?
    var codexTaskStateRevision: Int?
    var voiceIntent: String?
    var threadID: String?
    var turnID: String?
    var taskRevision: Int?
    var transcript: String?
    var submissionID: String?
    var requestID: String?
    var draftID: String?
    var draftExpiresAtEpochMilliseconds: Int64?
    var codexConversationCatalog: WatchCodexConversationCatalog?
    var codexConversationTarget: WatchCodexConversationTarget?
    var resolvedCodexConversationTarget: WatchCodexConversationTarget?
    var accepted: Bool?
    var voiceOutcome: String?
    var speechLocaleIdentifier: String?
    var probeID: String?
    var internetRelayProvisioning: String?
    var internetRelayProvisioningCleared: Bool?
    var profileUpdateRetryReason: WatchProfileUpdateRetryReason?
    var directBridgeConfiguration: String?
    var directBridgeConfigurationCleared: Bool?
    var buttonTrigger: String?
    var issuedAtEpochMilliseconds: Int64?

    static func isValidProbeID(_ value: String?) -> Bool {
        guard let value, let parsed = UUID(uuidString: value) else { return false }
        return parsed.uuidString == value
    }

    static func serverIdentityProof(
        clientEphemeralPublicKey: Data,
        serverEphemeralPublicKey: Data
    ) -> Data? {
        guard clientEphemeralPublicKey.count == 32,
              serverEphemeralPublicKey.count == 32
        else { return nil }
        return transcript(
            domain: serverIdentityProofDomain,
            components: [
                Data(protocolID.utf8),
                clientEphemeralPublicKey,
                serverEphemeralPublicKey,
            ]
        )
    }

    static func clientAuthenticationProof(
        clientEphemeralPublicKey: Data,
        serverEphemeralPublicKey: Data,
        serverIdentityPublicKey: Data,
        clientIdentityPublicKey: Data
    ) -> Data? {
        guard clientEphemeralPublicKey.count == 32,
              serverEphemeralPublicKey.count == 32,
              serverIdentityPublicKey.count == 64,
              clientIdentityPublicKey.count == 64
        else { return nil }
        guard let sessionTranscript = sessionTranscript(
            clientEphemeralPublicKey: clientEphemeralPublicKey,
            serverEphemeralPublicKey: serverEphemeralPublicKey,
            serverIdentityPublicKey: serverIdentityPublicKey
        ) else { return nil }
        return transcript(
            domain: clientAuthenticationProofDomain,
            components: [
                sessionTranscript,
                clientIdentityPublicKey,
            ]
        )
    }

    static func sessionTranscript(
        clientEphemeralPublicKey: Data,
        serverEphemeralPublicKey: Data,
        serverIdentityPublicKey: Data
    ) -> Data? {
        guard clientEphemeralPublicKey.count == 32,
              serverEphemeralPublicKey.count == 32,
              serverIdentityPublicKey.count == 64
        else { return nil }
        var version = UInt32(serverIdentityVersion).bigEndian
        let versionData = withUnsafeBytes(of: &version) { Data($0) }
        return transcript(
            domain: sessionTranscriptDomain,
            components: [
                Data(protocolID.utf8),
                Data(clientRole.utf8),
                Data(serverRole.utf8),
                versionData,
                clientEphemeralPublicKey,
                serverEphemeralPublicKey,
                serverIdentityPublicKey,
            ]
        )
    }

    static func secureEnvelopeAuthenticatedData(
        senderRole: String,
        sequence: UInt64
    ) -> Data? {
        guard senderRole == clientRole || senderRole == serverRole else { return nil }
        var encodedSequence = sequence.bigEndian
        let sequenceData = withUnsafeBytes(of: &encodedSequence) { Data($0) }
        return transcript(
            domain: secureEnvelopeDomain,
            components: [
                Data(protocolID.utf8),
                Data(senderRole.utf8),
                sequenceData,
            ]
        )
    }

    static func acceptsSecureSequence(_ received: UInt64?, expected: UInt64) -> Bool {
        received == expected
    }

    static func internetRelayProvisioningDirective(
        encoded: String?,
        cleared: Bool?
    ) -> InternetRelayProvisioningDirective? {
        switch (encoded, cleared) {
        case let (.some(encoded), .some(false)) where !encoded.isEmpty:
            return .install(encoded)
        case (nil, .some(true)):
            return .clear
        default:
            return nil
        }
    }

    private static func transcript(domain: String, components: [Data]) -> Data {
        var proof = Data((domain + "\0").utf8)
        for component in components {
            var length = UInt32(component.count).bigEndian
            withUnsafeBytes(of: &length) { proof.append(contentsOf: $0) }
            proof.append(component)
        }
        return proof
    }
}

struct WristBridgeAudioDeliveryReceipt: Equatable, Sendable {
    let sequence: UInt64
    let accepted: Bool
    let contiguousThrough: UInt64?
}

/// Mac-side delivery watermark for original Watch audio.
///
/// The secure-envelope sequence protects the connection as a whole. This
/// independent sequence protects the semantic delivery of audio packets and
/// makes a positive receipt mean that the Bridge audio consumer accepted the
/// packet, not merely that TCP delivered some bytes to the Mac.
struct WristBridgeAudioReceiveGate: Equatable, Sendable {
    private(set) var nextExpectedSequence: UInt64 = 0

    var contiguousThrough: UInt64? {
        nextExpectedSequence == 0 ? nil : nextExpectedSequence - 1
    }

    mutating func receive(
        sequence: UInt64,
        deliver: () -> Bool
    ) -> WristBridgeAudioDeliveryReceipt {
        if sequence < nextExpectedSequence {
            return WristBridgeAudioDeliveryReceipt(
                sequence: sequence,
                accepted: true,
                contiguousThrough: contiguousThrough
            )
        }
        guard sequence == nextExpectedSequence else {
            return WristBridgeAudioDeliveryReceipt(
                sequence: sequence,
                accepted: false,
                contiguousThrough: contiguousThrough
            )
        }
        let (next, overflow) = nextExpectedSequence.addingReportingOverflow(1)
        guard !overflow, deliver() else {
            return WristBridgeAudioDeliveryReceipt(
                sequence: sequence,
                accepted: false,
                contiguousThrough: contiguousThrough
            )
        }
        nextExpectedSequence = next
        return WristBridgeAudioDeliveryReceipt(
            sequence: sequence,
            accepted: true,
            contiguousThrough: contiguousThrough
        )
    }

    mutating func reset() {
        nextExpectedSequence = 0
    }
}

struct WristBridgeSecureChannel {
    private(set) var nextOutboundSequence: UInt64 = 0
    private(set) var nextInboundSequence: UInt64 = 0

    mutating func seal(
        _ message: WristBridgeWireMessage,
        using key: SymmetricKey,
        senderRole: String
    ) -> WristBridgeWireMessage? {
        let sequence = nextOutboundSequence
        let (nextSequence, overflow) = sequence.addingReportingOverflow(1)
        guard !overflow,
              let authenticatedData = WristBridgeWireMessage.secureEnvelopeAuthenticatedData(
                  senderRole: senderRole,
                  sequence: sequence
              ),
              let cleartext = try? JSONEncoder().encode(message),
              let sealed = try? ChaChaPoly.seal(
                  cleartext,
                  using: key,
                  authenticating: authenticatedData
              )
        else { return nil }
        let envelope = WristBridgeWireMessage(
            type: "secure",
            payload: sealed.combined.base64EncodedString(),
            sequence: sequence
        )
        guard (try? JSONEncoder().encode(envelope)) != nil else { return nil }
        nextOutboundSequence = nextSequence
        return envelope
    }

    mutating func open(
        _ envelope: WristBridgeWireMessage,
        using key: SymmetricKey,
        senderRole: String
    ) -> WristBridgeWireMessage? {
        let expectedSequence = nextInboundSequence
        let (nextSequence, overflow) = expectedSequence.addingReportingOverflow(1)
        guard !overflow,
              envelope.type == "secure",
              WristBridgeWireMessage.acceptsSecureSequence(
                  envelope.sequence,
                  expected: expectedSequence
              ),
              let authenticatedData = WristBridgeWireMessage.secureEnvelopeAuthenticatedData(
                  senderRole: senderRole,
                  sequence: expectedSequence
              ),
              let encoded = envelope.payload,
              let data = Data(base64Encoded: encoded),
              let sealed = try? ChaChaPoly.SealedBox(combined: data),
              let cleartext = try? ChaChaPoly.open(
                  sealed,
                  using: key,
                  authenticating: authenticatedData
              ),
              let message = try? JSONDecoder().decode(
                  WristBridgeWireMessage.self,
                  from: cleartext
              )
        else { return nil }
        nextInboundSequence = nextSequence
        return message
    }

    mutating func reset() {
        nextOutboundSequence = 0
        nextInboundSequence = 0
    }
}

enum WatchCodexTaskState: String, Codable, Equatable, Sendable {
    case running
    case completed
    case failed
}

enum WatchCodexTaskUpdate: Equatable, Sendable {
    case snapshot(WatchCodexTaskSnapshot, stateRevision: Int)
    case cleared(stateRevision: Int)

    var stateRevision: Int {
        switch self {
        case let .snapshot(_, stateRevision): return stateRevision
        case let .cleared(stateRevision): return stateRevision
        }
    }
}

struct WatchCodexTaskSnapshot: Codable, Equatable, Sendable {
    let threadID: String
    let turnID: String?
    let workspaceLabel: String
    let title: String
    let summary: String?
    let state: WatchCodexTaskState
    let revision: Int
    let updatedAtEpochMilliseconds: Int64

    init(
        threadID: String,
        turnID: String? = nil,
        workspaceLabel: String,
        title: String,
        summary: String? = nil,
        state: WatchCodexTaskState,
        revision: Int,
        updatedAtEpochMilliseconds: Int64
    ) {
        self.threadID = threadID
        self.turnID = turnID
        self.workspaceLabel = Self.sanitizedWorkspaceLabel(workspaceLabel)
        self.title = title
        self.summary = summary
        self.state = state
        self.revision = revision
        self.updatedAtEpochMilliseconds = updatedAtEpochMilliseconds
    }

    private enum CodingKeys: String, CodingKey {
        case threadID
        case turnID
        case workspaceLabel
        case title
        case summary
        case state
        case revision
        case updatedAtEpochMilliseconds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let threadID = try container.decode(String.self, forKey: .threadID)
        let turnID = try container.decodeIfPresent(String.self, forKey: .turnID)
        let workspaceLabel = try container.decode(String.self, forKey: .workspaceLabel)
        let title = try container.decode(String.self, forKey: .title)
        let summary = try container.decodeIfPresent(String.self, forKey: .summary)
        let revision = try container.decode(Int.self, forKey: .revision)
        let updatedAtEpochMilliseconds = try container.decode(
            Int64.self,
            forKey: .updatedAtEpochMilliseconds
        )
        guard CodexThreadIdentifier.isValid(threadID),
              turnID.map(CodexThreadIdentifier.isValid) ?? true,
              WatchCodexConversationWireValidation.isValidTitle(title),
              WatchCodexConversationWireValidation.isValidDetail(summary),
              revision >= 0,
              updatedAtEpochMilliseconds >= 0
        else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid privacy-redacted Codex task snapshot"
                )
            )
        }
        self.init(
            threadID: threadID,
            turnID: turnID,
            workspaceLabel: workspaceLabel,
            title: title,
            summary: summary,
            state: try container.decode(WatchCodexTaskState.self, forKey: .state),
            revision: revision,
            updatedAtEpochMilliseconds: updatedAtEpochMilliseconds
        )
    }

    private static func sanitizedWorkspaceLabel(_ raw: String) -> String {
        let lastComponent = raw
            .split(whereSeparator: { $0 == "/" || $0 == "\\" })
            .last
            .map(String.init)
            ?? raw
        let normalized = lastComponent
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard WatchCodexConversationWireValidation.isValidWorkspaceLabel(normalized)
        else { return "Mac 工作区" }
        return normalized
    }
}

enum WatchVoiceIntent: String, Codable, Equatable, Sendable {
    case foregroundDictation
    case codexTask
    case codexConversation
}

enum WatchVoiceOutcomeKind: String, Codable, Equatable, Sendable {
    case delivered
    case draft
    case failed
}

enum CodexThreadIdentifier {
    static func isValid(_ value: String?) -> Bool {
        guard let value,
              !value.isEmpty,
              value.utf8.count <= 128,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              value.first != "-",
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return false }
        return true
    }
}

struct WatchCodexTaskIdentity: Codable, Equatable, Hashable, Sendable {
    let threadID: String
    let turnID: String
    let revision: Int

    init?(threadID: String?, turnID: String?, revision: Int?) {
        guard CodexThreadIdentifier.isValid(threadID),
              CodexThreadIdentifier.isValid(turnID),
              let threadID,
              let turnID,
              let revision,
              revision >= 0
        else { return nil }
        self.threadID = threadID
        self.turnID = turnID
        self.revision = revision
    }

    init?(_ snapshot: WatchCodexTaskSnapshot?) {
        self.init(
            threadID: snapshot?.threadID,
            turnID: snapshot?.turnID,
            revision: snapshot?.revision
        )
    }
}

struct WatchVoiceOutcome: Codable, Equatable, Sendable {
    let sessionID: String
    let intent: WatchVoiceIntent
    let threadID: String?
    let turnID: String?
    let taskRevision: Int?
    let kind: WatchVoiceOutcomeKind
    let text: String?
    let detail: String?
    let localeIdentifier: String
    let draftID: UUID?
    let codexConversationTarget: WatchCodexConversationTarget?
    let draftExpiresAtEpochMilliseconds: Int64?

    init(
        sessionID: String,
        intent: WatchVoiceIntent,
        threadID: String?,
        turnID: String? = nil,
        taskRevision: Int? = nil,
        kind: WatchVoiceOutcomeKind,
        text: String?,
        detail: String?,
        localeIdentifier: String,
        draftID: UUID? = nil,
        codexConversationTarget: WatchCodexConversationTarget? = nil,
        draftExpiresAtEpochMilliseconds: Int64? = nil
    ) {
        self.sessionID = sessionID
        self.intent = intent
        self.threadID = threadID
        self.turnID = turnID
        self.taskRevision = taskRevision
        self.kind = kind
        self.text = text
        self.detail = detail
        self.localeIdentifier = localeIdentifier
        self.draftID = draftID
        self.codexConversationTarget = codexConversationTarget
        self.draftExpiresAtEpochMilliseconds = draftExpiresAtEpochMilliseconds
    }

    var codexTaskIdentity: WatchCodexTaskIdentity? {
        WatchCodexTaskIdentity(
            threadID: threadID,
            turnID: turnID,
            revision: taskRevision
        )
    }

    var hasCodexTaskIdentityFields: Bool {
        threadID != nil || turnID != nil || taskRevision != nil
    }

    func bound(to identity: WatchCodexTaskIdentity) -> WatchVoiceOutcome {
        WatchVoiceOutcome(
            sessionID: sessionID,
            intent: intent,
            threadID: identity.threadID,
            turnID: identity.turnID,
            taskRevision: identity.revision,
            kind: kind,
            text: text,
            detail: detail,
            localeIdentifier: localeIdentifier,
            draftID: draftID,
            codexConversationTarget: codexConversationTarget,
            draftExpiresAtEpochMilliseconds: draftExpiresAtEpochMilliseconds
        )
    }

    var codexConversationDraftLease: WatchCodexDraftLease? {
        guard let draftID,
              let codexConversationTarget,
              let draftExpiresAtEpochMilliseconds
        else { return nil }
        return WatchCodexDraftLease(
            draftID: draftID,
            target: codexConversationTarget,
            expiresAtEpochMilliseconds: draftExpiresAtEpochMilliseconds
        )
    }

    var hasCodexConversationDraftFields: Bool {
        draftID != nil
            || codexConversationTarget != nil
            || draftExpiresAtEpochMilliseconds != nil
    }

    var hasValidWireShape: Bool {
        guard WatchCodexConversationWireValidation.isCanonicalUUIDString(sessionID),
              WatchCodexConversationWireValidation.isValidLocaleIdentifier(localeIdentifier),
              WatchCodexConversationWireValidation.isValidDetail(detail),
              text.map(WatchCodexConversationWireValidation.isValidTranscript) ?? true
        else { return false }
        switch intent {
        case .foregroundDictation:
            return !hasCodexTaskIdentityFields && !hasCodexConversationDraftFields
        case .codexTask:
            return codexTaskIdentity != nil && !hasCodexConversationDraftFields
        case .codexConversation:
            guard !hasCodexTaskIdentityFields else { return false }
            switch kind {
            case .draft:
                return codexConversationDraftLease != nil && text != nil
            case .delivered, .failed:
                return !hasCodexConversationDraftFields
            }
        }
    }
}

typealias BridgeWireMessage = WristBridgeWireMessage

enum WristBridgeCommand: String, Sendable {
    case power
    case up
    case down
    case left
    case right
    case confirm = "ok"
    case back
    case home
    case menu
    case television = "tv"
    case volumeUp = "volume_up"
    case volumeDown = "volume_down"
}
