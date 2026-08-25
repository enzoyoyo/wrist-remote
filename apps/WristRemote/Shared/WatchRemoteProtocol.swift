import Foundation

enum WatchRemoteCommand: String, CaseIterable, Codable, Identifiable, Sendable {
    case power
    case up
    case down
    case left
    case right
    case ok
    case back
    case home
    case menu
    case tv
    case volumeUp
    case volumeDown

    var id: String { rawValue }

    static let defaultFavorites: [WatchRemoteCommand] = [
        .back,
        .home,
        .volumeUp,
        .volumeDown,
    ]

    var wireButtonID: String {
        switch self {
        case .volumeUp: return "volume_up"
        case .volumeDown: return "volume_down"
        default: return rawValue
        }
    }
}

enum WatchRemoteProtocol {
    static let version = 7
    static let audioPacketDurationMilliseconds = 80
    static let audioPacketSampleCount = 1_280
    static let audioReorderWindowPackets = 32
    static let voiceFinalAckTimeoutMilliseconds = 2_000
    static let voiceStartReplyTimeoutMilliseconds = 6_000

    enum Key: String {
        case protocolVersion
        case kind
        case command
        case phase
        case macConnected
        case macName
        case voiceOwner
        case detail
        case favorites
        case buttonTitles
        case actionProfileReady
        case profileRevision
        case accepted
        case requestID
        case streamID
        case voiceIntent
        case threadID
        case turnID
        case taskRevision
        case codexTaskPayload
        case codexTaskCleared
        case codexTaskStateRevision
        case voiceOutcomePayload
        case finalSequence
        case transcript
        case submissionID
        case internetRelayProvisioning
    }

    enum Kind: String {
        case buttonEvent
        case voiceStart
        case voiceStop
        case requestStatus
        case favoritesUpdate
        case status
        case codexTaskSnapshot
        case voiceOutcome
        case codexReplySubmit
    }

    enum ButtonPhase: String, Codable, Sendable {
        case press
        case release
    }

    enum VoiceOwner: String, Codable, Sendable {
        case none
        case watch
    }

    static func buttonMessage(
        command: WatchRemoteCommand,
        phase: ButtonPhase,
        profileRevision: Int
    ) -> [String: Any] {
        baseMessage(kind: .buttonEvent).merging([
            Key.command.rawValue: command.rawValue,
            Key.phase.rawValue: phase.rawValue,
            Key.profileRevision.rawValue: profileRevision,
        ]) { _, newValue in newValue }
    }

    static func buttonEvent(
        from message: [String: Any]
    ) -> (command: WatchRemoteCommand, phase: ButtonPhase, profileRevision: Int)? {
        guard kind(from: message) == .buttonEvent,
              let rawCommand = message[Key.command.rawValue] as? String,
              let command = WatchRemoteCommand(rawValue: rawCommand),
              let rawPhase = message[Key.phase.rawValue] as? String,
              let phase = ButtonPhase(rawValue: rawPhase),
              let profileRevision = integer(
                  in: message,
                  key: Key.profileRevision.rawValue
              ),
              profileRevision >= 0
        else { return nil }
        return (command, phase, profileRevision)
    }

    static func voiceStartMessage(
        streamID: UUID,
        profileRevision: Int,
        intent: WatchVoiceIntent = .foregroundDictation,
        codexTaskIdentity: WatchCodexTaskIdentity? = nil
    ) -> [String: Any]? {
        guard acceptsVoiceTargetShape(intent: intent, identity: codexTaskIdentity) else {
            return nil
        }
        var values: [String: Any] = [
            Key.streamID.rawValue: streamID.uuidString,
            Key.profileRevision.rawValue: profileRevision,
            Key.voiceIntent.rawValue: intent.rawValue,
        ]
        add(identity: codexTaskIdentity, to: &values)
        return baseMessage(kind: .voiceStart).merging(values) { _, newValue in newValue }
    }

    static func voiceStopMessage(
        streamID: UUID,
        profileRevision: Int,
        intent: WatchVoiceIntent = .foregroundDictation,
        codexTaskIdentity: WatchCodexTaskIdentity? = nil,
        finalSequence: UInt64? = nil
    ) -> [String: Any]? {
        guard acceptsVoiceTargetShape(intent: intent, identity: codexTaskIdentity) else {
            return nil
        }
        var values: [String: Any] = [
            Key.streamID.rawValue: streamID.uuidString,
            Key.profileRevision.rawValue: profileRevision,
            Key.voiceIntent.rawValue: intent.rawValue,
        ]
        add(identity: codexTaskIdentity, to: &values)
        if let finalSequence { values[Key.finalSequence.rawValue] = finalSequence }
        return baseMessage(kind: .voiceStop).merging(values) { _, newValue in newValue }
    }

    static func requestStatusMessage(requestID: UUID) -> [String: Any] {
        baseMessage(kind: .requestStatus).merging([
            Key.requestID.rawValue: requestID.uuidString,
        ]) { _, newValue in newValue }
    }

    static func voiceStartReply(
        accepted: Bool,
        streamID: UUID,
        profileRevision: Int,
        intent: WatchVoiceIntent = .foregroundDictation,
        codexTaskIdentity: WatchCodexTaskIdentity? = nil
    ) -> [String: Any]? {
        guard acceptsVoiceTargetShape(intent: intent, identity: codexTaskIdentity) else {
            return nil
        }
        var values: [String: Any] = [
            Key.accepted.rawValue: accepted,
            Key.streamID.rawValue: streamID.uuidString,
            Key.profileRevision.rawValue: profileRevision,
            Key.voiceIntent.rawValue: intent.rawValue,
        ]
        add(identity: codexTaskIdentity, to: &values)
        return baseMessage(kind: .voiceStart).merging(values) { _, newValue in newValue }
    }

    static func voiceStartReply(
        from message: [String: Any]
    ) -> (
        accepted: Bool,
        streamID: UUID,
        profileRevision: Int,
        intent: WatchVoiceIntent,
        codexTaskIdentity: WatchCodexTaskIdentity?
    )? {
        guard protocolVersion(in: message) == version,
              message[Key.kind.rawValue] as? String == Kind.voiceStart.rawValue,
              let event = voiceEvent(from: message, kind: .voiceStart)
        else { return nil }
        let accepted: Bool
        if let accepted = message[Key.accepted.rawValue] as? Bool {
            return (
                accepted,
                event.streamID,
                event.profileRevision,
                event.intent,
                event.codexTaskIdentity
            )
        }
        if let number = message[Key.accepted.rawValue] as? NSNumber {
            accepted = number.boolValue
            return (
                accepted,
                event.streamID,
                event.profileRevision,
                event.intent,
                event.codexTaskIdentity
            )
        }
        return nil
    }

    static func favoritesUpdateMessage(
        _ favorites: [WatchRemoteCommand]
    ) -> [String: Any]? {
        guard let favorites = validatedFavorites(favorites) else { return nil }
        return baseMessage(kind: .favoritesUpdate).merging([
            Key.favorites.rawValue: favorites.map(\.rawValue),
        ]) { _, newValue in newValue }
    }

    static func statusMessage(_ status: WatchRemoteStatus) -> [String: Any] {
        var message = baseMessage(kind: .status)
        message[Key.macConnected.rawValue] = status.isMacConnected
        message[Key.macName.rawValue] = status.macName
        message[Key.voiceOwner.rawValue] = status.voiceOwner.rawValue
        message[Key.actionProfileReady.rawValue] = status.isActionProfileReady
        message[Key.buttonTitles.rawValue] = Dictionary(
            uniqueKeysWithValues: status.buttonTitles.map { ($0.key.rawValue, $0.value) }
        )
        if let profileRevision = status.profileRevision {
            message[Key.profileRevision.rawValue] = profileRevision
        }
        if let detail = status.detail, !detail.isEmpty {
            message[Key.detail.rawValue] = detail
        }
        return message
    }

    static func statusReplyMessage(
        _ status: WatchRemoteStatus,
        requestID: UUID
    ) -> [String: Any] {
        statusMessage(status).merging([
            Key.requestID.rawValue: requestID.uuidString,
        ]) { _, newValue in newValue }
    }

    static func applicationContext(
        status: WatchRemoteStatus,
        favorites: [WatchRemoteCommand],
        codexTask: WatchCodexTaskSnapshot? = nil,
        codexTaskStateRevision: Int,
        voiceOutcome: WatchVoiceOutcome? = nil,
        internetRelayProvisioning: WristInternetRelayDeviceProvisioning? = nil
    ) -> [String: Any] {
        var context = statusMessage(status)
        if let favorites = validatedFavorites(favorites) {
            context[Key.favorites.rawValue] = favorites.map(\.rawValue)
        }
        if let codexTask,
           let payload = encodedPayload(codexTask) {
            context[Key.codexTaskPayload.rawValue] = payload
            context[Key.codexTaskCleared.rawValue] = false
            context[Key.codexTaskStateRevision.rawValue] = codexTaskStateRevision
        } else {
            context[Key.codexTaskCleared.rawValue] = true
            context[Key.codexTaskStateRevision.rawValue] = codexTaskStateRevision
        }
        if let voiceOutcome,
           let payload = encodedPayload(voiceOutcome) {
            context[Key.voiceOutcomePayload.rawValue] = payload
        }
        if let internetRelayProvisioning,
           let payload = internetRelayProvisioning.encodedBase64() {
            context[Key.internetRelayProvisioning.rawValue] = payload
        }
        return context
    }

    static func internetRelayProvisioning(
        from message: [String: Any]
    ) -> WristInternetRelayDeviceProvisioning? {
        guard let encoded = message[Key.internetRelayProvisioning.rawValue] as? String else {
            return nil
        }
        return WristInternetRelayDeviceProvisioning.decodeBase64(encoded)
    }

    static func codexTaskMessage(
        _ snapshot: WatchCodexTaskSnapshot,
        stateRevision: Int
    ) -> [String: Any]? {
        guard stateRevision >= 0,
              let payload = encodedPayload(snapshot)
        else { return nil }
        return baseMessage(kind: .codexTaskSnapshot).merging([
            Key.codexTaskPayload.rawValue: payload,
            Key.codexTaskCleared.rawValue: false,
            Key.codexTaskStateRevision.rawValue: stateRevision,
        ]) { _, newValue in newValue }
    }

    static func codexTaskClearedMessage(stateRevision: Int) -> [String: Any] {
        baseMessage(kind: .codexTaskSnapshot).merging([
            Key.codexTaskCleared.rawValue: true,
            Key.codexTaskStateRevision.rawValue: stateRevision,
        ]) { _, newValue in newValue }
    }

    static func codexTaskUpdate(from message: [String: Any]) -> WatchCodexTaskUpdate? {
        guard protocolVersion(in: message) == version else { return nil }
        guard let isCleared = boolean(
            in: message,
            key: Key.codexTaskCleared.rawValue
        ),
        let stateRevision = integer(
            in: message,
            key: Key.codexTaskStateRevision.rawValue
        ),
        stateRevision >= 0
        else { return nil }
        let payload = message[Key.codexTaskPayload.rawValue] as? String
        if isCleared {
            guard payload == nil else { return nil }
            return .cleared(stateRevision: stateRevision)
        }
        guard let payload,
              let snapshot = decodedPayload(WatchCodexTaskSnapshot.self, from: payload)
        else { return nil }
        return .snapshot(snapshot, stateRevision: stateRevision)
    }

    static func codexTask(from message: [String: Any]) -> WatchCodexTaskSnapshot? {
        guard case let .snapshot(snapshot, _) = codexTaskUpdate(from: message) else { return nil }
        return snapshot
    }

    static func voiceOutcomeMessage(_ outcome: WatchVoiceOutcome) -> [String: Any]? {
        guard let payload = encodedPayload(outcome) else { return nil }
        return baseMessage(kind: .voiceOutcome).merging([
            Key.voiceOutcomePayload.rawValue: payload,
        ]) { _, newValue in newValue }
    }

    static func voiceOutcome(from message: [String: Any]) -> WatchVoiceOutcome? {
        guard protocolVersion(in: message) == version,
              let payload = message[Key.voiceOutcomePayload.rawValue] as? String
        else { return nil }
        return decodedPayload(WatchVoiceOutcome.self, from: payload)
    }

    static func codexReplySubmitMessage(
        codexTaskIdentity: WatchCodexTaskIdentity,
        submissionID: UUID,
        transcript: String
    ) -> [String: Any]? {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              text.count <= 2_000
        else { return nil }
        var values: [String: Any] = [
            Key.transcript.rawValue: text,
            Key.submissionID.rawValue: submissionID.uuidString,
        ]
        add(identity: codexTaskIdentity, to: &values)
        return baseMessage(kind: .codexReplySubmit).merging(values) { _, newValue in newValue }
    }

    static func codexReplySubmit(
        from message: [String: Any]
    ) -> (
        codexTaskIdentity: WatchCodexTaskIdentity,
        submissionID: UUID,
        transcript: String
    )? {
        guard kind(from: message) == .codexReplySubmit,
              message[Key.accepted.rawValue] == nil,
              let identity = codexTaskIdentity(from: message),
              let rawSubmissionID = message[Key.submissionID.rawValue] as? String,
              let submissionID = UUID(uuidString: rawSubmissionID),
              submissionID.uuidString == rawSubmissionID,
              let transcript = message[Key.transcript.rawValue] as? String
        else { return nil }
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 2_000 else { return nil }
        return (identity, submissionID, text)
    }

    static func codexReplyAckMessage(
        accepted: Bool,
        codexTaskIdentity: WatchCodexTaskIdentity,
        submissionID: UUID,
        detail: String? = nil
    ) -> [String: Any] {
        var values: [String: Any] = [
            Key.accepted.rawValue: accepted,
            Key.submissionID.rawValue: submissionID.uuidString,
        ]
        add(identity: codexTaskIdentity, to: &values)
        if let detail, !detail.isEmpty { values[Key.detail.rawValue] = detail }
        return baseMessage(kind: .codexReplySubmit).merging(values) { _, newValue in newValue }
    }

    static func codexReplyAck(
        from message: [String: Any]
    ) -> (
        accepted: Bool,
        codexTaskIdentity: WatchCodexTaskIdentity,
        submissionID: UUID,
        detail: String?
    )? {
        guard kind(from: message) == .codexReplySubmit,
              message[Key.transcript.rawValue] == nil,
              let accepted = boolean(in: message, key: Key.accepted.rawValue),
              let identity = codexTaskIdentity(from: message),
              let rawSubmissionID = message[Key.submissionID.rawValue] as? String,
              let submissionID = UUID(uuidString: rawSubmissionID),
              submissionID.uuidString == rawSubmissionID
        else { return nil }
        return (accepted, identity, submissionID, message[Key.detail.rawValue] as? String)
    }

    static func status(from message: [String: Any]) -> WatchRemoteStatus? {
        guard protocolVersion(in: message) == version,
              message[Key.kind.rawValue] as? String == Kind.status.rawValue,
              let isMacConnected = message[Key.macConnected.rawValue] as? Bool,
              let ownerRawValue = message[Key.voiceOwner.rawValue] as? String,
              let voiceOwner = VoiceOwner(rawValue: ownerRawValue)
        else { return nil }

        let rawTitles = message[Key.buttonTitles.rawValue] as? [String: String] ?? [:]
        let buttonTitles: [WatchRemoteCommand: String] = Dictionary(
            uniqueKeysWithValues: rawTitles.compactMap { rawCommand, title in
                guard let command = WatchRemoteCommand(rawValue: rawCommand) else { return nil }
                let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedTitle.isEmpty else { return nil }
                return (command, trimmedTitle)
            }
        )

        let profileRevision = integer(
            in: message,
            key: Key.profileRevision.rawValue
        )
        let isActionProfileReady = boolean(
            in: message,
            key: Key.actionProfileReady.rawValue
        ) == true && profileRevision != nil

        return WatchRemoteStatus(
            isMacConnected: isMacConnected,
            macName: message[Key.macName.rawValue] as? String ?? "Mac",
            voiceOwner: voiceOwner,
            detail: message[Key.detail.rawValue] as? String,
            buttonTitles: buttonTitles,
            isActionProfileReady: isActionProfileReady,
            profileRevision: profileRevision
        )
    }

    static func kind(from message: [String: Any]) -> Kind? {
        guard protocolVersion(in: message) == version,
              let rawKind = message[Key.kind.rawValue] as? String
        else { return nil }
        return Kind(rawValue: rawKind)
    }

    static func requestID(from message: [String: Any]) -> UUID? {
        guard let rawRequestID = message[Key.requestID.rawValue] as? String else {
            return nil
        }
        return UUID(uuidString: rawRequestID)
    }

    static func streamID(from message: [String: Any], kind: Kind) -> UUID? {
        guard self.kind(from: message) == kind,
              let rawStreamID = message[Key.streamID.rawValue] as? String
        else { return nil }
        return UUID(uuidString: rawStreamID)
    }

    static func voiceEvent(
        from message: [String: Any],
        kind: Kind
    ) -> (
        streamID: UUID,
        profileRevision: Int,
        intent: WatchVoiceIntent,
        codexTaskIdentity: WatchCodexTaskIdentity?,
        finalSequence: UInt64?
    )? {
        guard kind == .voiceStart || kind == .voiceStop,
              let streamID = streamID(from: message, kind: kind),
              let profileRevision = integer(
                  in: message,
                  key: Key.profileRevision.rawValue
              ),
              profileRevision >= 0,
              let rawIntent = message[Key.voiceIntent.rawValue] as? String,
              let intent = WatchVoiceIntent(rawValue: rawIntent)
        else { return nil }
        let identity = codexTaskIdentity(from: message)
        let hasAnyIdentityField = message[Key.threadID.rawValue] != nil
            || message[Key.turnID.rawValue] != nil
            || message[Key.taskRevision.rawValue] != nil
        guard acceptsVoiceTargetShape(intent: intent, identity: identity),
              (intent == .codexTask || !hasAnyIdentityField)
        else { return nil }
        let rawFinalSequence = message[Key.finalSequence.rawValue]
        let finalSequence = unsignedInteger(
            in: message,
            key: Key.finalSequence.rawValue
        )
        if rawFinalSequence != nil, finalSequence == nil { return nil }
        if kind == .voiceStart, rawFinalSequence != nil { return nil }
        return (streamID, profileRevision, intent, identity, finalSequence)
    }

    static func codexTaskIdentity(from message: [String: Any]) -> WatchCodexTaskIdentity? {
        WatchCodexTaskIdentity(
            threadID: message[Key.threadID.rawValue] as? String,
            turnID: message[Key.turnID.rawValue] as? String,
            revision: integer(in: message, key: Key.taskRevision.rawValue)
        )
    }

    private static func acceptsVoiceTargetShape(
        intent: WatchVoiceIntent,
        identity: WatchCodexTaskIdentity?
    ) -> Bool {
        switch intent {
        case .foregroundDictation: return identity == nil
        case .codexTask: return identity != nil
        }
    }

    private static func add(
        identity: WatchCodexTaskIdentity?,
        to values: inout [String: Any]
    ) {
        guard let identity else { return }
        values[Key.threadID.rawValue] = identity.threadID
        values[Key.turnID.rawValue] = identity.turnID
        values[Key.taskRevision.rawValue] = identity.revision
    }

    static func favorites(from message: [String: Any]) -> [WatchRemoteCommand]? {
        guard let rawFavorites = message[Key.favorites.rawValue] as? [String] else { return nil }
        let favorites = rawFavorites.compactMap(WatchRemoteCommand.init(rawValue:))
        guard favorites.count == rawFavorites.count else { return nil }
        return validatedFavorites(favorites)
    }

    static func pcm16Data(samples: [Int16]) -> Data {
        var data = Data(capacity: samples.count * MemoryLayout<Int16>.size)
        for sample in samples {
            var littleEndianSample = sample.littleEndian
            withUnsafeBytes(of: &littleEndianSample) { bytes in
                data.append(contentsOf: bytes)
            }
        }
        return data
    }

    static func decodePCM16(_ data: Data) -> [Int16]? {
        guard !data.isEmpty,
              data.count.isMultiple(of: MemoryLayout<Int16>.size)
        else { return nil }

        return data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            return stride(from: 0, to: bytes.count, by: 2).map { index in
                let value = UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8)
                return Int16(bitPattern: value)
            }
        }
    }

    static func audioEnvelopeData(
        streamID: UUID,
        profileRevision: Int,
        sequence: UInt64,
        pcm16Data: Data
    ) -> Data? {
        guard profileRevision >= 0,
              pcm16Data.count == audioPacketSampleCount * MemoryLayout<Int16>.size
        else { return nil }
        let envelope = WatchRemoteAudioEnvelope(
            protocolVersion: version,
            streamID: streamID,
            profileRevision: profileRevision,
            sequence: sequence,
            pcm16Data: pcm16Data
        )
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try? encoder.encode(envelope)
    }

    static func audioEnvelope(from data: Data) -> WatchRemoteAudioEnvelope? {
        guard let envelope = try? PropertyListDecoder().decode(
            WatchRemoteAudioEnvelope.self,
            from: data
        ),
        envelope.protocolVersion == version,
        envelope.profileRevision >= 0,
        envelope.pcm16Data.count == audioPacketSampleCount * MemoryLayout<Int16>.size
        else { return nil }
        return envelope
    }

    static func audioAckData(
        streamID: UUID,
        profileRevision: Int,
        sequence: UInt64,
        accepted: Bool,
        contiguousThrough: UInt64?
    ) -> Data? {
        guard profileRevision >= 0 else { return nil }
        let acknowledgement = WatchRemoteAudioAcknowledgement(
            protocolVersion: version,
            streamID: streamID,
            profileRevision: profileRevision,
            sequence: sequence,
            accepted: accepted,
            contiguousThrough: contiguousThrough
        )
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try? encoder.encode(acknowledgement)
    }

    static func audioAcknowledgement(from data: Data) -> WatchRemoteAudioAcknowledgement? {
        guard let acknowledgement = try? PropertyListDecoder().decode(
            WatchRemoteAudioAcknowledgement.self,
            from: data
        ),
        acknowledgement.protocolVersion == version,
        acknowledgement.profileRevision >= 0
        else { return nil }
        return acknowledgement
    }

    private static func baseMessage(kind: Kind) -> [String: Any] {
        [
            Key.protocolVersion.rawValue: version,
            Key.kind.rawValue: kind.rawValue,
        ]
    }

    private static func protocolVersion(in message: [String: Any]) -> Int? {
        integer(in: message, key: Key.protocolVersion.rawValue)
    }

    private static func integer(in message: [String: Any], key: String) -> Int? {
        if let value = message[key] as? Int { return value }
        return (message[key] as? NSNumber)?.intValue
    }

    private static func boolean(in message: [String: Any], key: String) -> Bool? {
        if let value = message[key] as? Bool { return value }
        return (message[key] as? NSNumber)?.boolValue
    }

    private static func unsignedInteger(in message: [String: Any], key: String) -> UInt64? {
        if let value = message[key] as? UInt64 { return value }
        if let value = message[key] as? Int, value >= 0 { return UInt64(value) }
        if message[key] is Bool { return nil }
        if let number = message[key] as? NSNumber {
            let value = number.doubleValue
            guard value.isFinite,
                  value >= 0,
                  value <= Double(Int64.max),
                  value.rounded(.towardZero) == value
            else { return nil }
            return UInt64(value)
        }
        return nil
    }

    private static func encodedPayload<T: Encodable>(_ value: T) -> String? {
        try? JSONEncoder().encode(value).base64EncodedString()
    }

    private static func decodedPayload<T: Decodable>(
        _ type: T.Type,
        from encoded: String
    ) -> T? {
        guard let data = Data(base64Encoded: encoded) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func validatedFavorites(
        _ favorites: [WatchRemoteCommand]
    ) -> [WatchRemoteCommand]? {
        guard favorites.count == 4,
              Set(favorites).count == favorites.count
        else { return nil }
        return favorites
    }
}

struct WatchRemoteAudioEnvelope: Codable, Equatable, Sendable {
    let protocolVersion: Int
    let streamID: UUID
    let profileRevision: Int
    let sequence: UInt64
    let pcm16Data: Data
}

struct WatchRemoteAudioAcknowledgement: Codable, Equatable, Sendable {
    let protocolVersion: Int
    let streamID: UUID
    let profileRevision: Int
    let sequence: UInt64
    let accepted: Bool
    let contiguousThrough: UInt64?
}

struct WatchRemoteAudioGateInsertion: Equatable, Sendable {
    let accepted: Bool
    let readyEnvelopes: [WatchRemoteAudioEnvelope]
    let contiguousThrough: UInt64?
}

struct WatchRemoteAudioStreamGate: Equatable, Sendable {
    private(set) var activeStreamID: UUID?
    private(set) var activeProfileRevision: Int?
    private(set) var nextExpectedSequence: UInt64 = 0
    private var reorderedEnvelopes: [UInt64: WatchRemoteAudioEnvelope] = [:]

    var contiguousThrough: UInt64? {
        nextExpectedSequence == 0 ? nil : nextExpectedSequence - 1
    }

    // Compatibility name for status/drain callers. This is deliberately the
    // contiguous watermark, never the largest packet merely observed.
    var lastAcceptedSequence: UInt64? { contiguousThrough }

    mutating func start(streamID: UUID, profileRevision: Int) {
        guard profileRevision >= 0 else {
            clear()
            return
        }
        activeStreamID = streamID
        activeProfileRevision = profileRevision
        nextExpectedSequence = 0
        reorderedEnvelopes.removeAll(keepingCapacity: true)
    }

    mutating func insert(_ envelope: WatchRemoteAudioEnvelope) -> WatchRemoteAudioGateInsertion {
        guard envelope.streamID == activeStreamID,
              envelope.profileRevision == activeProfileRevision
        else {
            return WatchRemoteAudioGateInsertion(
                accepted: false,
                readyEnvelopes: [],
                contiguousThrough: contiguousThrough
            )
        }
        guard envelope.sequence >= nextExpectedSequence,
              reorderedEnvelopes[envelope.sequence] == nil,
              envelope.sequence - nextExpectedSequence
                <= UInt64(WatchRemoteProtocol.audioReorderWindowPackets)
        else {
            return WatchRemoteAudioGateInsertion(
                accepted: false,
                readyEnvelopes: [],
                contiguousThrough: contiguousThrough
            )
        }

        reorderedEnvelopes[envelope.sequence] = envelope
        var ready: [WatchRemoteAudioEnvelope] = []
        while let next = reorderedEnvelopes.removeValue(forKey: nextExpectedSequence) {
            ready.append(next)
            nextExpectedSequence &+= 1
        }
        return WatchRemoteAudioGateInsertion(
            accepted: true,
            readyEnvelopes: ready,
            contiguousThrough: contiguousThrough
        )
    }

    @discardableResult
    mutating func stop(streamID: UUID, profileRevision: Int) -> Bool {
        guard activeStreamID == streamID,
              activeProfileRevision == profileRevision
        else { return false }
        clear()
        return true
    }

    mutating func clear() {
        activeStreamID = nil
        activeProfileRevision = nil
        nextExpectedSequence = 0
        reorderedEnvelopes.removeAll(keepingCapacity: false)
    }
}

enum WatchRemoteAudioAckProgress: Equatable, Sendable {
    case waiting
    case finalized
    case rejected
}

struct WatchRemoteAudioAckTracker: Equatable, Sendable {
    private(set) var streamID: UUID?
    private(set) var profileRevision: Int?
    private(set) var highestSentSequence: UInt64?
    private(set) var contiguousThrough: UInt64?
    private(set) var finalSequence: UInt64?

    mutating func start(streamID: UUID, profileRevision: Int) {
        self.streamID = streamID
        self.profileRevision = profileRevision
        highestSentSequence = nil
        contiguousThrough = nil
        finalSequence = nil
    }

    mutating func recordSent(sequence: UInt64) {
        guard streamID != nil else { return }
        highestSentSequence = max(highestSentSequence ?? sequence, sequence)
    }

    mutating func beginFinalization(finalSequence: UInt64?) -> WatchRemoteAudioAckProgress {
        self.finalSequence = finalSequence
        guard let finalSequence else { return .finalized }
        return contiguousThrough.map { $0 >= finalSequence } == true ? .finalized : .waiting
    }

    mutating func accept(
        _ acknowledgement: WatchRemoteAudioAcknowledgement
    ) -> WatchRemoteAudioAckProgress {
        guard acknowledgement.streamID == streamID,
              acknowledgement.profileRevision == profileRevision,
              let highestSentSequence,
              acknowledgement.sequence <= highestSentSequence,
              acknowledgement.accepted,
              acknowledgement.contiguousThrough.map({ $0 <= highestSentSequence }) != false
        else { return .rejected }

        if let acknowledgedThrough = acknowledgement.contiguousThrough {
            contiguousThrough = max(contiguousThrough ?? acknowledgedThrough, acknowledgedThrough)
        }
        guard let finalSequence else { return .waiting }
        return contiguousThrough.map { $0 >= finalSequence } == true ? .finalized : .waiting
    }

    mutating func clear() {
        streamID = nil
        profileRevision = nil
        highestSentSequence = nil
        contiguousThrough = nil
        finalSequence = nil
    }
}

/// A tiny lock-protected FIFO between the realtime audio callback and the
/// main-actor WatchConnectivity sender. `finishAndDrain` closes the mailbox and
/// atomically takes every packet captured before `WatchAudioCapture.stop()`
/// returned, so releasing the UI cannot discard an already captured tail.
final class WatchRemoteAudioMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var packets: [Data] = []

    func begin() {
        lock.lock()
        packets.removeAll(keepingCapacity: true)
        isOpen = true
        lock.unlock()
    }

    @discardableResult
    func enqueue(_ packet: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard isOpen else { return false }
        packets.append(packet)
        return true
    }

    func drain() -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        let drained = packets
        packets.removeAll(keepingCapacity: true)
        return drained
    }

    func finishAndDrain(finalPacket: Data? = nil) -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        if isOpen, let finalPacket {
            packets.append(finalPacket)
        }
        isOpen = false
        let drained = packets
        packets.removeAll(keepingCapacity: false)
        return drained
    }

    func clear() {
        lock.lock()
        isOpen = false
        packets.removeAll(keepingCapacity: false)
        lock.unlock()
    }
}

struct WatchRemoteVoiceStartHandshake: Equatable, Sendable {
    private(set) var pendingRequestID: UInt64?
    private(set) var pendingStreamID: UUID?
    private(set) var pendingProfileRevision: Int?

    mutating func begin(requestID: UInt64, streamID: UUID, profileRevision: Int) {
        pendingRequestID = requestID
        pendingStreamID = streamID
        pendingProfileRevision = profileRevision
    }

    func isPending(requestID: UInt64, streamID: UUID, profileRevision: Int) -> Bool {
        pendingRequestID == requestID
            && pendingStreamID == streamID
            && pendingProfileRevision == profileRevision
    }

    @discardableResult
    mutating func consumeCompletion(
        requestID: UInt64,
        streamID: UUID,
        profileRevision: Int
    ) -> Bool {
        guard isPending(
            requestID: requestID,
            streamID: streamID,
            profileRevision: profileRevision
        ) else { return false }
        invalidate()
        return true
    }

    @discardableResult
    mutating func cancel(
        requestID: UInt64,
        streamID: UUID,
        profileRevision: Int
    ) -> Bool {
        consumeCompletion(
            requestID: requestID,
            streamID: streamID,
            profileRevision: profileRevision
        )
    }

    mutating func invalidate() {
        pendingRequestID = nil
        pendingStreamID = nil
        pendingProfileRevision = nil
    }
}

/// Orders the iPhone relay's voice start/stop messages before any asynchronous
/// Mac acknowledgement work begins. A stop that arrives before the matching
/// start is retained as a bounded tombstone so that delayed delivery cannot
/// resurrect a released voice gesture.
struct WatchRemoteVoiceRelayReservation: Equatable, Sendable {
    private static let stoppedStreamLimit = 32

    private(set) var pendingStreamID: UUID?
    private(set) var pendingProfileRevision: Int?
    private var stoppedStreams: [WatchRemoteVoiceStreamIdentity] = []

    var stoppedStreamIDs: [UUID] { stoppedStreams.map(\.streamID) }

    mutating func reserve(streamID: UUID, profileRevision: Int) -> Bool {
        let identity = WatchRemoteVoiceStreamIdentity(
            streamID: streamID,
            profileRevision: profileRevision
        )
        guard pendingStreamID == nil,
              profileRevision >= 0,
              !stoppedStreams.contains(identity)
        else { return false }
        pendingStreamID = streamID
        pendingProfileRevision = profileRevision
        return true
    }

    mutating func stop(streamID: UUID, profileRevision: Int) {
        let identity = WatchRemoteVoiceStreamIdentity(
            streamID: streamID,
            profileRevision: profileRevision
        )
        if pendingStreamID == streamID, pendingProfileRevision == profileRevision {
            pendingStreamID = nil
            pendingProfileRevision = nil
        }
        guard !stoppedStreams.contains(identity) else { return }
        stoppedStreams.append(identity)
        if stoppedStreams.count > Self.stoppedStreamLimit {
            stoppedStreams.removeFirst(stoppedStreams.count - Self.stoppedStreamLimit)
        }
    }

    @discardableResult
    mutating func consumeCompletion(streamID: UUID, profileRevision: Int) -> Bool {
        guard pendingStreamID == streamID,
              pendingProfileRevision == profileRevision
        else { return false }
        pendingStreamID = nil
        pendingProfileRevision = nil
        return true
    }

    mutating func clear() {
        pendingStreamID = nil
        pendingProfileRevision = nil
        stoppedStreams.removeAll(keepingCapacity: true)
    }
}

private struct WatchRemoteVoiceStreamIdentity: Equatable, Sendable {
    let streamID: UUID
    let profileRevision: Int
}

struct WatchRemoteStatusHandshake: Equatable, Sendable {
    private(set) var pendingRequestID: UUID?
    private(set) var hasFreshStatus = false

    mutating func begin(requestID: UUID = UUID()) -> UUID {
        pendingRequestID = requestID
        hasFreshStatus = false
        return requestID
    }

    mutating func acceptReply(_ message: [String: Any]) -> WatchRemoteStatus? {
        guard let pendingRequestID,
              WatchRemoteProtocol.requestID(from: message) == pendingRequestID,
              let status = WatchRemoteProtocol.status(from: message)
        else { return nil }
        self.pendingRequestID = nil
        hasFreshStatus = true
        return status
    }

    mutating func acceptLivePush(_ message: [String: Any]) -> WatchRemoteStatus? {
        guard WatchRemoteProtocol.requestID(from: message) == nil,
              let status = WatchRemoteProtocol.status(from: message)
        else { return nil }
        pendingRequestID = nil
        hasFreshStatus = true
        return status
    }

    mutating func invalidate() {
        pendingRequestID = nil
        hasFreshStatus = false
    }
}

enum WatchConnectivityRecoveryPolicy {
    static let statusRetryDelays: [TimeInterval] = [1, 2, 4, 8]
    static let steadyStateStatusRetryDelay: TimeInterval = 15
    static let healthyStatusRefreshInterval: TimeInterval = 8

    static func shouldRequestActivation(
        isActivated: Bool,
        isInactive: Bool,
        requestInFlight: Bool
    ) -> Bool {
        !isActivated && !isInactive && !requestInFlight
    }

    static func statusRetryDelay(attempt: Int) -> TimeInterval? {
        guard attempt >= 0 else { return nil }
        if statusRetryDelays.indices.contains(attempt) {
            return statusRetryDelays[attempt]
        }
        return steadyStateStatusRetryDelay
    }
}

struct WatchStatusRetryCursor: Equatable, Sendable {
    private(set) var attempt = 0

    mutating func nextDelay() -> TimeInterval? {
        guard let delay = WatchConnectivityRecoveryPolicy.statusRetryDelay(attempt: attempt) else {
            return nil
        }
        if attempt < Int.max { attempt += 1 }
        return delay
    }

    mutating func reset() {
        attempt = 0
    }
}

struct WatchRemoteStatus: Equatable, Sendable {
    let isMacConnected: Bool
    let macName: String
    let voiceOwner: WatchRemoteProtocol.VoiceOwner
    let detail: String?
    let buttonTitles: [WatchRemoteCommand: String]
    let isActionProfileReady: Bool
    let profileRevision: Int?

    func requiresInteractionReset(from previous: WatchRemoteStatus) -> Bool {
        previous.isMacConnected != isMacConnected
            || previous.isActionProfileReady != isActionProfileReady
            || previous.profileRevision != profileRevision
    }

    static let unavailable = WatchRemoteStatus(
        isMacConnected: false,
        macName: "Mac",
        voiceOwner: .none,
        detail: nil,
        buttonTitles: [:],
        isActionProfileReady: false,
        profileRevision: nil
    )
}
