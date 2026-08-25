import Foundation

struct WristBridgeWireMessage: Codable, Equatable {
    static let protocolID = "dev.wristremote.bridge.protocol.v1"
    static let clientRole = "wristRemoteClient"
    static let serverRole = "wristRemoteBridge"
    static let serviceType = "_wristremote._tcp"
    static let sessionSalt = "WristRemoteBridge nearby session"
    static let identityProofDomain = "WristRemoteBridge nearby identity v1"
    static let voiceSessionsCapability = "voiceSessionsV1"
    static let watchActionProfileCapability = "watchActionProfileV1"
    static let codexTasksCapability = "codexTasksV2"
    static let voiceOutcomesCapability = "voiceOutcomesV1"
    static let codexReplyReceiptsCapability = "codexReplyReceiptsV1"
    static let connectionLivenessCapability = "connectionLivenessV1"
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
    var buttonTitles: [String: String]?
    var appVersion: String?
    var payload: String?
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
    var accepted: Bool?
    var voiceOutcome: String?
    var speechLocaleIdentifier: String?
    var probeID: String?
    var internetRelayProvisioning: String?
    var profileUpdateRetryReason: WatchProfileUpdateRetryReason?

    static func isValidProbeID(_ value: String?) -> Bool {
        guard let value, let parsed = UUID(uuidString: value) else { return false }
        return parsed.uuidString == value
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
    let cwd: String
    let title: String
    let summary: String?
    let state: WatchCodexTaskState
    let revision: Int
    let updatedAtEpochMilliseconds: Int64

    init(
        threadID: String,
        turnID: String? = nil,
        cwd: String,
        title: String,
        summary: String? = nil,
        state: WatchCodexTaskState,
        revision: Int,
        updatedAtEpochMilliseconds: Int64
    ) {
        self.threadID = threadID
        self.turnID = turnID
        self.cwd = cwd
        self.title = title
        self.summary = summary
        self.state = state
        self.revision = revision
        self.updatedAtEpochMilliseconds = updatedAtEpochMilliseconds
    }
}

enum WatchVoiceIntent: String, Codable, Equatable, Sendable {
    case foregroundDictation
    case codexTask
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

    init(
        sessionID: String,
        intent: WatchVoiceIntent,
        threadID: String?,
        turnID: String? = nil,
        taskRevision: Int? = nil,
        kind: WatchVoiceOutcomeKind,
        text: String?,
        detail: String?,
        localeIdentifier: String
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
            localeIdentifier: localeIdentifier
        )
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
