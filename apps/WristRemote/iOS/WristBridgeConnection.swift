import CryptoKit
import Foundation
import Network
import OSLog
import Security
import UIKit

@MainActor
final class WristBridgeConnection: ObservableObject {
    enum State: Equatable {
        case searching
        case connecting
        case awaitingApproval
        case connected
        case connectedWithError(String)
        case unavailable(String)

        var shouldRestartDiscoveryOnActivation: Bool {
            switch self {
            case .searching, .connecting, .unavailable:
                return true
            case .awaitingApproval, .connected, .connectedWithError:
                return false
            }
        }

        var needsConnectionWatchdog: Bool {
            if case .connecting = self { return true }
            return false
        }
    }

    enum VoiceOwner: String, Equatable {
        case watch
    }

    enum ButtonPhase: String, Equatable {
        case press
        case release
    }

    struct ProfileRevisionQueue: Equatable {
        enum Completion: Equatable {
            case ready(nextRevision: Int?)
            case rejected(nextRevision: Int?)
            case invalidated
            case stale
        }

        private(set) var desiredRevision: Int?
        private(set) var pendingRevision: Int?
        private(set) var acceptedRevision: Int?

        mutating func request(_ revision: Int) -> Int? {
            guard revision >= 0 else { return nil }
            desiredRevision = revision
            guard pendingRevision == nil, acceptedRevision != revision else { return nil }
            pendingRevision = revision
            acceptedRevision = nil
            return revision
        }

        mutating func complete(type: String, revision: Int?) -> Completion {
            guard let revision else { return .stale }
            if pendingRevision == nil,
               type == "watchProfileRejected",
               revision == acceptedRevision {
                acceptedRevision = nil
                return .invalidated
            }
            guard revision == pendingRevision else { return .stale }
            pendingRevision = nil
            let accepted: Bool
            if type == "watchProfileReady" {
                acceptedRevision = revision
                accepted = true
            } else if type == "watchProfileRejected" {
                acceptedRevision = nil
                accepted = false
            } else {
                acceptedRevision = nil
                return .stale
            }

            let next = desiredRevision != acceptedRevision
                && (accepted || desiredRevision != revision)
                ? desiredRevision
                : nil
            if let next {
                pendingRevision = next
                acceptedRevision = nil
            }
            return accepted ? .ready(nextRevision: next) : .rejected(nextRevision: next)
        }

        mutating func timeout(revision: Int) -> Bool {
            guard pendingRevision == revision else { return false }
            pendingRevision = nil
            acceptedRevision = nil
            return true
        }

        mutating func reset() {
            desiredRevision = nil
            pendingRevision = nil
            acceptedRevision = nil
        }
    }

    private struct PendingVoice {
        let sessionID: String
        let profileRevision: Int
        let intent: WatchVoiceIntent
        let codexTaskIdentity: WatchCodexTaskIdentity?
        let requestID: UInt64
        let generation: Int
        let continuation: CheckedContinuation<Bool, Never>
    }

    private struct AwaitingVoiceOutcome {
        let intent: WatchVoiceIntent
        let codexTaskIdentity: WatchCodexTaskIdentity?
    }

    struct CodexReplyReceipt: Equatable {
        let submissionID: UUID
        let codexTaskIdentity: WatchCodexTaskIdentity
        let accepted: Bool
        let detail: String?
    }

    private struct PendingCodexReply {
        let identity: WatchCodexTaskIdentity
        let generation: Int
        let completion: (CodexReplyReceipt) -> Void
    }

    private struct PendingLivenessProbe {
        let probeID: String
        let generation: Int
        let continuation: CheckedContinuation<Bool, Never>
    }

    @Published private(set) var state: State = .searching
    @Published private(set) var macName = "正在查找 Mac"
    @Published private(set) var voiceOwner: VoiceOwner? {
        didSet {
            if oldValue != nil, voiceOwner == nil {
                retryBusyProfileAfterVoiceEndedIfNeeded()
            }
        }
    }
    @Published private(set) var supportsWatchActionProfiles = false
    @Published private(set) var acceptedWatchProfileRevision: Int?
    @Published private(set) var watchApplicationTitles: [String: String] = [:]
    @Published private(set) var watchActionProfileError: String?
    @Published private(set) var codexTaskSnapshot: WatchCodexTaskSnapshot?
    @Published private(set) var codexTaskStateRevision = -1
    @Published private(set) var lastVoiceOutcome: WatchVoiceOutcome?
    @Published private(set) var speechLocaleIdentifier = "zh-CN"
    @Published private(set) var internetRelayProvisioning: WristInternetRelayDeviceProvisioning?

    private let queue = DispatchQueue(label: "WristRemote.bridge.network", qos: .userInitiated)
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "dev.wristremote.ios",
        category: "BridgeConnection"
    )
    nonisolated static let connectionWatchdogSeconds: TimeInterval = 12
    nonisolated static let livenessProbeTimeoutSeconds: TimeInterval = 1

    private var identityPrivateKey: P256.Signing.PrivateKey?
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var reconnectTask: Task<Void, Never>?
    private var connectionWatchdogTask: Task<Void, Never>?
    private var livenessProbeTimeoutTask: Task<Void, Never>?
    private var pendingLivenessProbe: PendingLivenessProbe?
    private var protectedDataObserver: NSObjectProtocol?
    private var reconnectAttempt = 0
    private var isSceneActive = false
    private var connectionGeneration = 0
    private var receiveBuffer = Data()
    private var ephemeralPrivateKey: Curve25519.KeyAgreement.PrivateKey?
    private var sessionKey: SymmetricKey?
    private var pairingCode: String?
    private var supportsVoiceSessions = false
    private var supportsCodexTasks = false
    private var supportsVoiceOutcomes = false
    private var supportsCodexReplyReceipts = false
    private var profileQueue = ProfileRevisionQueue()
    private var desiredProfile: WatchActionProfileWire?
    private var profileTimeoutTask: Task<Void, Never>?
    private var profileRetryCount = 0
    private var profileBusyRetryTask: Task<Void, Never>?
    private var profileBusyRetryCount = 0
    private var profileBusyWaitingRevision: Int?
    private var voiceRequestID: UInt64 = 0
    private var pendingVoice: PendingVoice?
    private var voiceTimeoutTask: Task<Void, Never>?
    private var activeVoiceSessionID: String?
    private var activeVoiceProfileRevision: Int?
    private var activeVoiceIntent: WatchVoiceIntent = .foregroundDictation
    private var activeVoiceCodexTaskIdentity: WatchCodexTaskIdentity?
    private var awaitingVoiceOutcomes: [String: AwaitingVoiceOutcome] = [:]
    private var pendingCodexReplies: [UUID: PendingCodexReply] = [:]
    private var codexReplyTimeoutTasks: [UUID: Task<Void, Never>] = [:]
    private var lastAppliedCodexTaskRevision = -1

    init() {
        internetRelayProvisioning = WristInternetRelayKeychain.load(
            WristInternetRelayDeviceProvisioning.self,
            account: Self.internetRelayKeychainAccount,
            service: Self.internetRelayKeychainService
        )
        protectedDataObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.protectedDataDidBecomeAvailable()
            }
        }
    }

    deinit {
        if let protectedDataObserver {
            NotificationCenter.default.removeObserver(protectedDataObserver)
        }
    }

    var isConnected: Bool {
        switch state {
        case .connected, .connectedWithError: return true
        default: return false
        }
    }

    var displayedPairingCode: String? {
        guard case .awaitingApproval = state else { return nil }
        return pairingCode
    }

    var statusText: String {
        switch state {
        case .searching: return "正在查找"
        case .connecting: return "正在连接"
        case .awaitingApproval: return pairingCode.map { "确认码 \($0)" } ?? "等待 Mac 确认"
        case .connected: return "已连接"
        case .connectedWithError: return "需要处理"
        case .unavailable: return "未连接"
        }
    }

    var hasIssue: Bool {
        switch state {
        case .connectedWithError, .unavailable: return true
        default: return false
        }
    }

    var guidanceText: String {
        switch state {
        case let .connectedWithError(detail), let .unavailable(detail): return detail
        default: return ""
        }
    }

    func start() {
        guard isSceneActive, browser == nil, connection == nil else { return }
        startBrowser()
    }

    func restartDiscovery(reason: String = "manual") {
        logger.notice("Restarting bridge discovery: \(reason, privacy: .public)")
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempt = 0
        resetConnection(sendVoiceStop: true)
        browser?.cancel()
        browser = nil
        state = .searching
        macName = "正在查找 Mac"
        startBrowser()
    }

    func sceneDidBecomeActive() {
        isSceneActive = true
        retryBusyProfileAfterVoiceEndedIfNeeded()
        if state.shouldRestartDiscoveryOnActivation {
            restartDiscovery(reason: "scene_active")
        }
    }

    func sceneDidBecomeInactive() {
        isSceneActive = false
        reconnectTask?.cancel()
        reconnectTask = nil
        profileBusyRetryTask?.cancel()
        profileBusyRetryTask = nil
    }

    func prepareForWatchStatusRequest() async {
        if Self.shouldStartDiscoveryForWatchStatusRequest(
            state: state,
            hasBrowser: browser != nil,
            hasConnection: connection != nil
        ) {
            restartDiscovery(reason: "watch_live_status_request")
            return
        }
        switch state {
        case .searching, .connecting, .awaitingApproval, .unavailable:
            // A Watch retry must join an in-flight browser/connection instead
            // of cancelling it and starting a second recovery generation.
            return
        case .connected, .connectedWithError:
            break
        }
        guard isConnected else { return }
        let isLive = await verifyConnectionLiveness()
        guard !Task.isCancelled, !isLive, state != .awaitingApproval else { return }
        restartDiscovery(reason: "watch_liveness_probe_timeout")
    }

    nonisolated static func shouldStartDiscoveryForWatchStatusRequest(
        state: State,
        hasBrowser: Bool,
        hasConnection: Bool
    ) -> Bool {
        switch state {
        case .searching:
            return !hasBrowser && !hasConnection
        case .unavailable:
            return true
        case .connecting, .awaitingApproval, .connected, .connectedWithError:
            return false
        }
    }

    private func verifyConnectionLiveness() async -> Bool {
        guard isConnected, connection != nil, sessionKey != nil else { return false }
        cancelPendingLivenessProbe()
        let probeID = UUID().uuidString
        let generation = connectionGeneration
        return await withCheckedContinuation { continuation in
            pendingLivenessProbe = PendingLivenessProbe(
                probeID: probeID,
                generation: generation,
                continuation: continuation
            )
            livenessProbeTimeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(Self.livenessProbeTimeoutSeconds))
                guard let self, !Task.isCancelled else { return }
                self.resolveLivenessProbe(
                    probeID: probeID,
                    generation: generation,
                    isLive: false
                )
            }
            sendSecure(WristBridgeWireMessage(type: "livenessProbe", probeID: probeID))
        }
    }

    private func resolveLivenessProbe(
        probeID: String,
        generation: Int,
        isLive: Bool
    ) {
        guard let pendingLivenessProbe,
              pendingLivenessProbe.probeID == probeID,
              pendingLivenessProbe.generation == generation
        else { return }
        livenessProbeTimeoutTask?.cancel()
        livenessProbeTimeoutTask = nil
        self.pendingLivenessProbe = nil
        pendingLivenessProbe.continuation.resume(returning: isLive)
    }

    private func cancelPendingLivenessProbe() {
        guard let pendingLivenessProbe else { return }
        livenessProbeTimeoutTask?.cancel()
        livenessProbeTimeoutTask = nil
        self.pendingLivenessProbe = nil
        pendingLivenessProbe.continuation.resume(returning: false)
    }

    private func protectedDataDidBecomeAvailable() {
        var recoveredProtectedValue = false
        if identityPrivateKey == nil {
            identityPrivateKey = WristBridgeInstallationIdentity.loadOrCreate()
            recoveredProtectedValue = identityPrivateKey != nil
        }
        if internetRelayProvisioning == nil,
           let recoveredProvisioning = WristInternetRelayKeychain.load(
               WristInternetRelayDeviceProvisioning.self,
               account: Self.internetRelayKeychainAccount,
               service: Self.internetRelayKeychainService
           ), recoveredProvisioning.isValid {
            internetRelayProvisioning = recoveredProvisioning
            recoveredProtectedValue = true
        }
        guard identityPrivateKey != nil,
              recoveredProtectedValue,
              isSceneActive,
              !isConnected
        else { return }
        restartDiscovery(reason: "protected_data_available")
    }

    @discardableResult
    func syncWatchActionProfile(_ profile: WatchActionProfileWire) -> Bool {
        guard isConnected,
              supportsWatchActionProfiles,
              let normalized = try? profile.validatedAndNormalized()
        else {
            acceptedWatchProfileRevision = nil
            return false
        }
        if desiredProfile?.revision != normalized.revision {
            profileRetryCount = 0
            profileBusyRetryTask?.cancel()
            profileBusyRetryTask = nil
            profileBusyRetryCount = 0
            profileBusyWaitingRevision = nil
        }
        desiredProfile = normalized
        if let revision = profileQueue.request(normalized.revision) {
            sendProfile(normalized, revision: revision)
        }
        acceptedWatchProfileRevision = profileQueue.acceptedRevision
        return true
    }

    func isWatchActionProfileReady(revision: Int) -> Bool {
        isConnected
            && supportsWatchActionProfiles
            && acceptedWatchProfileRevision == revision
    }

    @discardableResult
    func sendWatchButtonEvent(
        _ command: WristBridgeCommand,
        phase: ButtonPhase,
        profileRevision: Int
    ) -> Bool {
        guard isWatchActionProfileReady(revision: profileRevision) else { return false }
        sendSecure(WristBridgeWireMessage(
            type: "buttonEvent",
            command: command.rawValue,
            buttonPhase: phase.rawValue,
            inputSource: WristBridgeWireMessage.appleWatchInputSource,
            profileRevision: profileRevision
        ))
        return true
    }

    func beginRelayedVoice(
        sessionID: String,
        profileRevision: Int,
        intent: WatchVoiceIntent,
        codexTaskIdentity: WatchCodexTaskIdentity?
    ) async -> Bool {
        guard UUID(uuidString: sessionID) != nil,
              isWatchActionProfileReady(revision: profileRevision),
              supportsVoiceSessions,
              voiceOwner == nil,
              pendingVoice == nil,
              activeVoiceSessionID == nil,
              Self.acceptsVoiceTarget(
                  intent: intent,
                  codexTaskIdentity: codexTaskIdentity,
                  snapshot: codexTaskSnapshot,
                  supportsCodexTasks: supportsCodexTasks
              )
        else { return false }

        voiceRequestID &+= 1
        let requestID = voiceRequestID
        let generation = connectionGeneration
        voiceOwner = .watch
        return await withCheckedContinuation { continuation in
            pendingVoice = PendingVoice(
                sessionID: sessionID,
                profileRevision: profileRevision,
                intent: intent,
                codexTaskIdentity: codexTaskIdentity,
                requestID: requestID,
                generation: generation,
                continuation: continuation
            )
            guard let start = Self.voiceMessage(
                type: "voiceStart",
                sessionID: sessionID,
                profileRevision: profileRevision,
                intent: intent,
                codexTaskIdentity: codexTaskIdentity
            ) else {
                pendingVoice = nil
                voiceOwner = nil
                continuation.resume(returning: false)
                return
            }
            sendSecure(start)
            voiceTimeoutTask?.cancel()
            voiceTimeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard let self,
                      !Task.isCancelled,
                      pendingVoice?.requestID == requestID,
                      connectionGeneration == generation
                else { return }
                if let stop = Self.voiceMessage(
                    type: "voiceStop",
                    sessionID: sessionID,
                    profileRevision: profileRevision,
                    intent: intent,
                    codexTaskIdentity: codexTaskIdentity
                ) {
                    sendSecure(stop)
                }
                resolveVoice(sessionID: sessionID, accepted: false)
            }
        }
    }

    func sendRelayedVoicePCM(
        _ data: Data,
        sessionID: String,
        profileRevision: Int
    ) {
        guard voiceOwner == .watch,
              activeVoiceSessionID == sessionID,
              activeVoiceProfileRevision == profileRevision,
              acceptedWatchProfileRevision == profileRevision,
              !data.isEmpty,
              data.count.isMultiple(of: MemoryLayout<Int16>.size),
              let message = Self.voiceMessage(
                  type: "audio",
                  sessionID: sessionID,
                  profileRevision: profileRevision,
                  intent: pendingVoice?.intent ?? activeVoiceIntent,
                  codexTaskIdentity: pendingVoice?.codexTaskIdentity
                      ?? activeVoiceCodexTaskIdentity,
                  samples: data.base64EncodedString()
              )
        else { return }
        sendSecure(message)
    }

    func endRelayedVoice(sessionID: String, profileRevision: Int) {
        guard voiceOwner == .watch,
              (activeVoiceSessionID == sessionID || pendingVoice?.sessionID == sessionID),
              (activeVoiceProfileRevision == profileRevision
                  || pendingVoice?.profileRevision == profileRevision)
        else { return }
        let shouldSend = activeVoiceSessionID != nil || pendingVoice != nil
        let intent = pendingVoice?.intent ?? activeVoiceIntent
        let identity = pendingVoice?.codexTaskIdentity ?? activeVoiceCodexTaskIdentity
        cancelVoiceContinuation()
        activeVoiceSessionID = nil
        activeVoiceProfileRevision = nil
        activeVoiceIntent = .foregroundDictation
        activeVoiceCodexTaskIdentity = nil
        voiceOwner = nil
        if shouldSend,
           let message = Self.voiceMessage(
               type: "voiceStop",
               sessionID: sessionID,
               profileRevision: profileRevision,
               intent: intent,
               codexTaskIdentity: identity
           ) {
            sendSecure(message)
        }
    }

    nonisolated static func voiceMessage(
        type: String,
        sessionID: String,
        profileRevision: Int,
        intent: WatchVoiceIntent = .foregroundDictation,
        codexTaskIdentity: WatchCodexTaskIdentity? = nil,
        samples: String? = nil
    ) -> WristBridgeWireMessage? {
        guard ["voiceStart", "audio", "voiceStop"].contains(type),
              UUID(uuidString: sessionID) != nil,
              profileRevision >= 0,
              acceptsVoiceTargetShape(intent: intent, codexTaskIdentity: codexTaskIdentity),
              (type == "audio" ? samples?.isEmpty == false : samples == nil)
        else { return nil }
        return WristBridgeWireMessage(
            type: type,
            samples: samples,
            sessionID: sessionID,
            inputSource: WristBridgeWireMessage.appleWatchInputSource,
            profileRevision: profileRevision,
            voiceIntent: intent.rawValue,
            threadID: codexTaskIdentity?.threadID,
            turnID: codexTaskIdentity?.turnID,
            taskRevision: codexTaskIdentity?.revision
        )
    }

    @discardableResult
    func submitCodexReply(
        codexTaskIdentity: WatchCodexTaskIdentity,
        submissionID: UUID,
        transcript: String,
        completion: @escaping (CodexReplyReceipt) -> Void
    ) -> Bool {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isConnected,
              supportsCodexTasks,
              supportsCodexReplyReceipts,
              WatchCodexTaskIdentity(codexTaskSnapshot) == codexTaskIdentity,
              codexTaskSnapshot?.state == .completed,
              !text.isEmpty,
              text.count <= 2_000,
              pendingCodexReplies[submissionID] == nil
        else { return false }
        let generation = connectionGeneration
        pendingCodexReplies[submissionID] = PendingCodexReply(
            identity: codexTaskIdentity,
            generation: generation,
            completion: completion
        )
        codexReplyTimeoutTasks[submissionID]?.cancel()
        codexReplyTimeoutTasks[submissionID] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(13))
            guard let self,
                  !Task.isCancelled,
                  connectionGeneration == generation
            else { return }
            resolveCodexReply(
                submissionID: submissionID,
                accepted: false,
                detail: "Mac 发送确认超时，草稿已保留"
            )
        }
        sendSecure(WristBridgeWireMessage(
            type: "codexReplySubmit",
            threadID: codexTaskIdentity.threadID,
            turnID: codexTaskIdentity.turnID,
            taskRevision: codexTaskIdentity.revision,
            transcript: text,
            submissionID: submissionID.uuidString
        ))
        return true
    }

    nonisolated static func acceptsVoiceTargetShape(
        intent: WatchVoiceIntent,
        codexTaskIdentity: WatchCodexTaskIdentity?
    ) -> Bool {
        switch intent {
        case .foregroundDictation:
            return codexTaskIdentity == nil
        case .codexTask:
            return codexTaskIdentity != nil
        }
    }

    nonisolated static func acceptsVoiceTarget(
        intent: WatchVoiceIntent,
        codexTaskIdentity: WatchCodexTaskIdentity?,
        snapshot: WatchCodexTaskSnapshot?,
        supportsCodexTasks: Bool
    ) -> Bool {
        guard acceptsVoiceTargetShape(
            intent: intent,
            codexTaskIdentity: codexTaskIdentity
        ) else { return false }
        if intent == .foregroundDictation { return true }
        return supportsCodexTasks
            && WatchCodexTaskIdentity(snapshot) == codexTaskIdentity
            && snapshot?.state == .completed
    }

    nonisolated static func wireCodexTaskIdentity(
        from message: WristBridgeWireMessage
    ) -> WatchCodexTaskIdentity? {
        WatchCodexTaskIdentity(
            threadID: message.threadID,
            turnID: message.turnID,
            revision: message.taskRevision
        )
    }

    nonisolated static func hasWireCodexTaskIdentityFields(
        _ message: WristBridgeWireMessage
    ) -> Bool {
        message.threadID != nil || message.turnID != nil || message.taskRevision != nil
    }

    nonisolated static func codexTaskUpdate(
        from message: WristBridgeWireMessage
    ) -> WatchCodexTaskUpdate? {
        guard let cleared = message.codexTaskCleared,
              let stateRevision = message.codexTaskStateRevision,
              stateRevision >= 0
        else { return nil }
        if cleared {
            guard message.codexTask == nil else { return nil }
            return .cleared(stateRevision: stateRevision)
        }
        guard let snapshot = message.codexTask,
              CodexThreadIdentifier.isValid(snapshot.threadID),
              snapshot.revision >= 0
        else { return nil }
        return .snapshot(snapshot, stateRevision: stateRevision)
    }

    nonisolated static func acceptsServerIdentity(_ message: WristBridgeWireMessage) -> Bool {
        message.protocolID == WristBridgeWireMessage.protocolID
            && message.serverRole == WristBridgeWireMessage.serverRole
            && message.clientRole == nil
    }

    nonisolated static func acceptsCapabilities(_ capabilities: [String]?) -> Bool {
        let values = Set(capabilities ?? [])
        return values.contains(WristBridgeWireMessage.voiceSessionsCapability)
            && values.contains(WristBridgeWireMessage.watchActionProfileCapability)
            && values.contains(WristBridgeWireMessage.codexTasksCapability)
            && values.contains(WristBridgeWireMessage.voiceOutcomesCapability)
            && values.contains(WristBridgeWireMessage.codexReplyReceiptsCapability)
            && values.contains(WristBridgeWireMessage.connectionLivenessCapability)
    }

    nonisolated static func profileUpdateMessage(
        _ profile: WatchActionProfileWire
    ) -> WristBridgeWireMessage? {
        guard let normalized = try? profile.validatedAndNormalized(),
              let encoded = try? normalized.encodedBase64()
        else { return nil }
        return WristBridgeWireMessage(
            type: "watchProfileUpdate",
            inputSource: WristBridgeWireMessage.appleWatchInputSource,
            profileRevision: normalized.revision,
            watchProfile: encoded
        )
    }

    nonisolated static func reconnectDelaySeconds(attempt: Int) -> Double {
        min(8, 0.5 * pow(2, Double(max(0, attempt))))
    }

    nonisolated static func shouldExpireConnectionWatchdog(
        expectedGeneration: Int,
        currentGeneration: Int,
        state: State,
        hasConnection: Bool
    ) -> Bool {
        expectedGeneration == currentGeneration
            && hasConnection
            && state.needsConnectionWatchdog
    }

    private func startBrowser() {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(
            for: .bonjour(type: WristBridgeWireMessage.serviceType, domain: nil),
            using: parameters
        )
        browser.stateUpdateHandler = { [weak self, weak browser] browserState in
            DispatchQueue.main.async {
                guard let self, browser === self.browser else { return }
                switch browserState {
                case .ready:
                    if self.connection == nil { self.state = .searching }
                case let .failed(error), let .waiting(error):
                    if self.connection == nil {
                        self.state = .unavailable(
                            "无法发现腕上遥控桥：\(error.localizedDescription)"
                        )
                        self.scheduleReconnect()
                    }
                default:
                    break
                }
            }
        }
        browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
            DispatchQueue.main.async {
                guard let self, browser === self.browser, self.connection == nil,
                      let endpoint = results.first?.endpoint
                else { return }
                self.connect(to: endpoint)
            }
        }
        self.browser = browser
        browser.start(queue: queue)
    }

    private func connect(to endpoint: NWEndpoint) {
        guard connection == nil else { return }
        state = .connecting
        connectionGeneration &+= 1
        let generation = connectionGeneration
        if case let .service(name, _, _, _) = endpoint { macName = name }
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let connection = NWConnection(to: endpoint, using: parameters)
        self.connection = connection
        scheduleConnectionWatchdog(generation: generation)
        connection.stateUpdateHandler = { [weak self, weak connection] connectionState in
            DispatchQueue.main.async {
                guard let self,
                      connection === self.connection,
                      generation == self.connectionGeneration
                else { return }
                switch connectionState {
                case .ready: self.sendHello(generation: generation)
                case let .failed(error), let .waiting(error):
                    self.fail("连接腕上遥控桥失败：\(error.localizedDescription)")
                case .cancelled:
                    if self.connection != nil { self.fail("腕上遥控桥连接已断开") }
                default:
                    break
                }
            }
        }
        connection.start(queue: queue)
    }

    private func scheduleConnectionWatchdog(generation: Int) {
        connectionWatchdogTask?.cancel()
        connectionWatchdogTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.connectionWatchdogSeconds))
            guard let self,
                  !Task.isCancelled,
                  Self.shouldExpireConnectionWatchdog(
                      expectedGeneration: generation,
                      currentGeneration: connectionGeneration,
                      state: state,
                      hasConnection: connection != nil
                  )
            else { return }
            fail("连接腕上遥控桥超时，请确认 Mac 桥仍在运行")
        }
    }

    private func sendHello(generation: Int) {
        guard generation == connectionGeneration else { return }
        if identityPrivateKey == nil {
            identityPrivateKey = WristBridgeInstallationIdentity.loadOrCreate()
        }
        guard let identityPrivateKey else {
            fail("无法准备 Wrist Remote 独立身份")
            return
        }
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let publicData = privateKey.publicKey.rawRepresentation
        var identityProof = Data((WristBridgeWireMessage.identityProofDomain + "\0").utf8)
        identityProof.append(publicData)
        guard let signature = try? identityPrivateKey.signature(for: identityProof) else {
            fail("无法签署 Wrist Remote 独立身份")
            return
        }
        ephemeralPrivateKey = privateKey
        sendPlain(WristBridgeWireMessage(
            type: "hello",
            protocolID: WristBridgeWireMessage.protocolID,
            clientRole: WristBridgeWireMessage.clientRole,
            deviceName: UIDevice.current.name,
            publicKey: publicData.base64EncodedString(),
            identityPublicKey: identityPrivateKey.publicKey.rawRepresentation.base64EncodedString(),
            identitySignature: signature.rawRepresentation.base64EncodedString()
        ))
        receiveNext(generation: generation)
    }

    private func receiveNext(generation: Int) {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) {
            [weak self] data, _, complete, error in
            DispatchQueue.main.async {
                guard let self, generation == self.connectionGeneration else { return }
                if let data { self.consume(data, generation: generation) }
                if complete || error != nil {
                    self.fail("腕上遥控桥连接已断开")
                } else {
                    self.receiveNext(generation: generation)
                }
            }
        }
    }

    private func consume(_ data: Data, generation: Int) {
        receiveBuffer.append(data)
        guard receiveBuffer.count <= 2 * 1_024 * 1_024 else {
            fail("腕上遥控桥返回数据过大")
            return
        }
        while let newline = receiveBuffer.firstIndex(of: 0x0A) {
            let frame = receiveBuffer[..<newline]
            receiveBuffer.removeSubrange(...newline)
            guard !frame.isEmpty,
                  let message = try? JSONDecoder().decode(
                      WristBridgeWireMessage.self,
                      from: frame
                  )
            else { continue }
            handleEnvelope(message, generation: generation)
        }
    }

    private func handleEnvelope(_ envelope: WristBridgeWireMessage, generation: Int) {
        if envelope.type == "serverKey" {
            guard Self.acceptsServerIdentity(envelope) else {
                fail("发现的 Mac 不是 WristRemoteBridge")
                return
            }
            establishSession(envelope, generation: generation)
            return
        }
        guard envelope.type == "secure", let message = decrypt(envelope) else { return }
        handleSecure(message, generation: generation)
    }

    private func establishSession(_ message: WristBridgeWireMessage, generation: Int) {
        guard generation == connectionGeneration,
              let ephemeralPrivateKey,
              let encoded = message.publicKey,
              let data = Data(base64Encoded: encoded),
              let publicKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: data),
              let secret = try? ephemeralPrivateKey.sharedSecretFromKeyAgreement(with: publicKey)
        else {
            fail("无法建立 Wrist Remote 独立加密会话")
            return
        }
        let key = secret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(WristBridgeWireMessage.sessionSalt.utf8),
            sharedInfo: Data(),
            outputByteCount: 32
        )
        sessionKey = key
        self.ephemeralPrivateKey = nil
        pairingCode = Self.pairingCode(key)
        connectionWatchdogTask?.cancel()
        connectionWatchdogTask = nil
        state = .awaitingApproval
        sendSecure(WristBridgeWireMessage(type: "pairingReady"))
    }

    private func handleSecure(_ message: WristBridgeWireMessage, generation: Int) {
        guard generation == connectionGeneration else { return }
        switch message.type {
        case "ready":
            guard Self.acceptsServerIdentity(message),
                  Self.acceptsCapabilities(message.capabilities)
            else {
                fail("WristRemoteBridge 身份或协议能力不完整")
                return
            }
            macName = message.deviceName ?? macName
            supportsVoiceSessions = true
            supportsWatchActionProfiles = true
            supportsCodexTasks = true
            supportsVoiceOutcomes = true
            supportsCodexReplyReceipts = true
            watchApplicationTitles = Self.normalizedTitles(message.watchApplicationTitles ?? [:])
            guard let taskUpdate = Self.codexTaskUpdate(from: message) else {
                fail("WristRemoteBridge 未提供明确的 Codex 任务状态")
                return
            }
            applyCodexTaskUpdate(taskUpdate)
            speechLocaleIdentifier = message.speechLocaleIdentifier ?? "zh-CN"
            applyInternetRelayProvisioning(message.internetRelayProvisioning)
            profileQueue.reset()
            desiredProfile = nil
            acceptedWatchProfileRevision = nil
            watchActionProfileError = nil
            pairingCode = nil
            connectionWatchdogTask?.cancel()
            connectionWatchdogTask = nil
            state = .connected
            reconnectAttempt = 0
            reconnectTask?.cancel()
            reconnectTask = nil

        case "watchApplicationTitles":
            watchApplicationTitles = Self.normalizedTitles(message.watchApplicationTitles ?? [:])

        case "internetRelayProvisioning":
            applyInternetRelayProvisioning(message.internetRelayProvisioning)

        case "livenessAck":
            guard WristBridgeWireMessage.isValidProbeID(message.probeID),
                  let probeID = message.probeID
            else { return }
            resolveLivenessProbe(
                probeID: probeID,
                generation: generation,
                isLive: true
            )

        case "watchProfileReady", "watchProfileRejected":
            let hasMatchingPending = profileQueue.pendingRevision != nil
                && message.profileRevision == profileQueue.pendingRevision
            let isAcceptedInvalidation = profileQueue.pendingRevision == nil
                && message.type == "watchProfileRejected"
                && message.profileRevision == profileQueue.acceptedRevision
            guard hasMatchingPending || isAcceptedInvalidation else {
                watchActionProfileError = "忽略了过期的映射确认"
                return
            }
            if hasMatchingPending {
                profileTimeoutTask?.cancel()
                profileTimeoutTask = nil
            }
            let completion = profileQueue.complete(
                type: message.type,
                revision: message.profileRevision
            )
            acceptedWatchProfileRevision = profileQueue.acceptedRevision
            let next: Int?
            switch completion {
            case .stale:
                watchActionProfileError = "忽略了过期的映射确认"
                return
            case .invalidated:
                watchActionProfileError = message.detail ?? "Mac 已撤销当前独立映射"
                next = nil
            case let .ready(revision):
                profileRetryCount = 0
                profileBusyRetryTask?.cancel()
                profileBusyRetryTask = nil
                profileBusyRetryCount = 0
                profileBusyWaitingRevision = nil
                watchActionProfileError = nil
                next = revision
            case let .rejected(revision):
                if message.profileUpdateRetryReason == .voiceActive,
                   let rejectedRevision = message.profileRevision,
                   desiredProfile?.revision == rejectedRevision {
                    watchActionProfileError = message.detail
                        ?? "语音进行中，结束后将自动重试独立映射"
                    scheduleBusyProfileRetry(
                        revision: rejectedRevision,
                        generation: generation
                    )
                } else {
                    profileBusyRetryTask?.cancel()
                    profileBusyRetryTask = nil
                    profileBusyRetryCount = 0
                    profileBusyWaitingRevision = nil
                    watchActionProfileError = revision == nil
                        ? (message.detail ?? "腕上遥控桥拒绝了独立映射")
                        : nil
                }
                next = revision
            }
            if let next, desiredProfile?.revision == next, let desiredProfile {
                sendProfile(desiredProfile, revision: next)
            }

        case "voiceReady", "voiceRejected":
            guard message.inputSource == WristBridgeWireMessage.appleWatchInputSource,
                  message.sessionID == pendingVoice?.sessionID,
                  message.profileRevision == pendingVoice?.profileRevision,
                  let rawIntent = message.voiceIntent,
                  let intent = WatchVoiceIntent(rawValue: rawIntent),
                  intent == pendingVoice?.intent,
                  Self.wireCodexTaskIdentity(from: message)
                    == pendingVoice?.codexTaskIdentity,
                  Self.acceptsVoiceTargetShape(
                      intent: intent,
                      codexTaskIdentity: Self.wireCodexTaskIdentity(from: message)
                  ),
                  (intent == .codexTask || !Self.hasWireCodexTaskIdentityFields(message))
            else { return }
            resolveVoice(
                sessionID: message.sessionID,
                accepted: message.type == "voiceReady"
            )

        case "codexTaskSnapshot":
            guard supportsCodexTasks,
                  let update = Self.codexTaskUpdate(from: message)
            else { return }
            applyCodexTaskUpdate(update)

        case "voiceOutcome":
            guard supportsVoiceOutcomes,
                  let rawKind = message.voiceOutcome,
                  let kind = WatchVoiceOutcomeKind(rawValue: rawKind),
                  let rawIntent = message.voiceIntent,
                  let intent = WatchVoiceIntent(rawValue: rawIntent),
                  let sessionID = message.sessionID,
                  UUID(uuidString: sessionID) != nil,
                  let expected = awaitingVoiceOutcomes[sessionID],
                  expected.intent == intent,
                  Self.acceptsVoiceTargetShape(
                      intent: intent,
                      codexTaskIdentity: Self.wireCodexTaskIdentity(from: message)
                  ),
                  (intent == .codexTask || !Self.hasWireCodexTaskIdentityFields(message)),
                  expected.codexTaskIdentity == Self.wireCodexTaskIdentity(from: message)
            else { return }
            let identity = Self.wireCodexTaskIdentity(from: message)
            var outcome = WatchVoiceOutcome(
                sessionID: sessionID,
                intent: intent,
                threadID: message.threadID,
                turnID: message.turnID,
                taskRevision: message.taskRevision,
                kind: kind,
                text: message.transcript,
                detail: message.detail,
                localeIdentifier: message.speechLocaleIdentifier ?? speechLocaleIdentifier
            )
            if kind == .draft,
               intent == .codexTask,
               WatchCodexTaskIdentity(codexTaskSnapshot) != identity {
                outcome = WatchVoiceOutcome(
                    sessionID: sessionID,
                    intent: .codexTask,
                    threadID: identity?.threadID,
                    turnID: identity?.turnID,
                    taskRevision: identity?.revision,
                    kind: .failed,
                    text: nil,
                    detail: "Codex 任务已更新，旧录音结果已拒绝。",
                    localeIdentifier: message.speechLocaleIdentifier
                        ?? speechLocaleIdentifier
                )
            }
            awaitingVoiceOutcomes.removeValue(forKey: sessionID)
            speechLocaleIdentifier = outcome.localeIdentifier
            lastVoiceOutcome = outcome

        case "codexReplyResult":
            guard let rawSubmissionID = message.submissionID,
                  let submissionID = UUID(uuidString: rawSubmissionID),
                  submissionID.uuidString == rawSubmissionID,
                  let accepted = message.accepted,
                  let pending = pendingCodexReplies[submissionID],
                  pending.generation == connectionGeneration,
                  Self.wireCodexTaskIdentity(from: message) == pending.identity
            else { return }
            resolveCodexReply(
                submissionID: submissionID,
                accepted: accepted,
                detail: message.detail
            )

        case "denied":
            fail("Mac 拒绝了 Wrist Remote 配对")

        case "error":
            state = .connectedWithError(message.detail ?? "腕上遥控桥无法执行该动作")

        default:
            break
        }
    }

    private func sendProfile(_ profile: WatchActionProfileWire, revision: Int) {
        guard profile.revision == revision,
              let message = Self.profileUpdateMessage(profile)
        else {
            watchActionProfileError = "独立映射无法编码"
            return
        }
        sendSecure(message)
        scheduleProfileTimeout(revision: revision, generation: connectionGeneration)
    }

    private func scheduleProfileTimeout(revision: Int, generation: Int) {
        profileTimeoutTask?.cancel()
        profileTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self,
                  !Task.isCancelled,
                  generation == connectionGeneration,
                  profileQueue.timeout(revision: revision)
            else { return }
            acceptedWatchProfileRevision = nil
            if profileRetryCount < 1,
               desiredProfile?.revision == revision,
               let desiredProfile {
                profileRetryCount += 1
                _ = profileQueue.request(revision)
                sendProfile(desiredProfile, revision: revision)
            } else {
                watchActionProfileError = "独立映射确认超时"
            }
        }
    }

    private func scheduleBusyProfileRetry(revision: Int, generation: Int) {
        profileBusyWaitingRevision = revision
        guard WatchProfileBusyRetryPolicy.shouldSchedule(
            isForeground: isSceneActive,
            hasValidConnection: isConnected
        ) else {
            profileBusyRetryTask?.cancel()
            profileBusyRetryTask = nil
            watchActionProfileError = "语音进行中，回到前台或语音结束后将自动重试独立映射"
            return
        }
        guard let delayMilliseconds = WatchProfileBusyRetryPolicy.delayMilliseconds(
            afterFailureCount: profileBusyRetryCount
        ) else {
            profileBusyRetryTask?.cancel()
            profileBusyRetryTask = nil
            watchActionProfileError = "语音持续占用，独立映射保持不变；语音结束或再次进入前台后自动重试"
            return
        }
        profileBusyRetryCount += 1
        profileBusyRetryTask?.cancel()
        profileBusyRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(delayMilliseconds))
            guard let self,
                  !Task.isCancelled,
                  generation == connectionGeneration,
                  isSceneActive,
                  isConnected,
                  desiredProfile?.revision == revision,
                  let desiredProfile
            else { return }
            profileBusyRetryTask = nil
            guard let nextRevision = profileQueue.request(revision) else { return }
            sendProfile(desiredProfile, revision: nextRevision)
        }
    }

    private func retryBusyProfileAfterVoiceEndedIfNeeded() {
        guard voiceOwner == nil,
              let revision = profileBusyWaitingRevision,
              WatchProfileBusyRetryPolicy.shouldSchedule(
                isForeground: isSceneActive,
                hasValidConnection: isConnected
              ),
              desiredProfile?.revision == revision,
              let desiredProfile
        else { return }
        profileBusyRetryTask?.cancel()
        profileBusyRetryTask = nil
        profileBusyRetryCount = 0
        profileBusyWaitingRevision = nil
        guard let nextRevision = profileQueue.request(revision) else { return }
        sendProfile(desiredProfile, revision: nextRevision)
    }

    private func resolveVoice(sessionID: String?, accepted: Bool) {
        guard let sessionID,
              let pendingVoice,
              pendingVoice.sessionID == sessionID,
              pendingVoice.requestID == voiceRequestID,
              pendingVoice.generation == connectionGeneration
        else { return }
        self.pendingVoice = nil
        voiceTimeoutTask?.cancel()
        voiceTimeoutTask = nil
        if accepted,
           isWatchActionProfileReady(revision: pendingVoice.profileRevision) {
            activeVoiceSessionID = sessionID
            activeVoiceProfileRevision = pendingVoice.profileRevision
            activeVoiceIntent = pendingVoice.intent
            activeVoiceCodexTaskIdentity = pendingVoice.codexTaskIdentity
            awaitingVoiceOutcomes[sessionID] = AwaitingVoiceOutcome(
                intent: pendingVoice.intent,
                codexTaskIdentity: pendingVoice.codexTaskIdentity
            )
        } else {
            activeVoiceSessionID = nil
            activeVoiceProfileRevision = nil
            activeVoiceIntent = .foregroundDictation
            activeVoiceCodexTaskIdentity = nil
            voiceOwner = nil
        }
        pendingVoice.continuation.resume(returning: accepted && voiceOwner == .watch)
    }

    private func applyCodexTaskUpdate(_ update: WatchCodexTaskUpdate) {
        let nextSnapshot: WatchCodexTaskSnapshot?
        switch update {
        case let .snapshot(snapshot, stateRevision):
            guard stateRevision >= lastAppliedCodexTaskRevision else { return }
            if stateRevision == lastAppliedCodexTaskRevision {
                guard codexTaskSnapshot == snapshot else { return }
                return
            }
            lastAppliedCodexTaskRevision = stateRevision
            codexTaskStateRevision = stateRevision
            nextSnapshot = snapshot
        case let .cleared(stateRevision):
            guard stateRevision >= lastAppliedCodexTaskRevision else { return }
            if stateRevision == lastAppliedCodexTaskRevision {
                guard codexTaskSnapshot == nil else { return }
                return
            }
            lastAppliedCodexTaskRevision = stateRevision
            codexTaskStateRevision = stateRevision
            nextSnapshot = nil
        }

        let nextIdentity = WatchCodexTaskIdentity(nextSnapshot)
        invalidateCodexVoiceIfNeeded(nextIdentity: nextIdentity)
        codexTaskSnapshot = nextSnapshot
        if nextSnapshot == nil { lastVoiceOutcome = nil }
    }

    private func invalidateCodexVoiceIfNeeded(nextIdentity: WatchCodexTaskIdentity?) {
        let pending = pendingVoice
        let activeSessionID = activeVoiceSessionID
        let activeRevision = activeVoiceProfileRevision
        let activeIntentValue = activeVoiceIntent
        let activeIdentity = activeVoiceCodexTaskIdentity

        if let pending,
           pending.intent == .codexTask,
           pending.codexTaskIdentity != nextIdentity {
            if let stop = Self.voiceMessage(
                type: "voiceStop",
                sessionID: pending.sessionID,
                profileRevision: pending.profileRevision,
                intent: pending.intent,
                codexTaskIdentity: pending.codexTaskIdentity
            ) {
                sendSecure(stop)
            }
            cancelVoiceContinuation()
            voiceOwner = nil
        }

        guard activeIntentValue == .codexTask,
              let activeSessionID,
              let activeRevision,
              let activeIdentity,
              activeIdentity != nextIdentity
        else { return }
        if let stop = Self.voiceMessage(
            type: "voiceStop",
            sessionID: activeSessionID,
            profileRevision: activeRevision,
            intent: .codexTask,
            codexTaskIdentity: activeIdentity
        ) {
            sendSecure(stop)
        }
        activeVoiceSessionID = nil
        activeVoiceProfileRevision = nil
        activeVoiceIntent = .foregroundDictation
        activeVoiceCodexTaskIdentity = nil
        voiceOwner = nil
        awaitingVoiceOutcomes.removeValue(forKey: activeSessionID)
        lastVoiceOutcome = WatchVoiceOutcome(
            sessionID: activeSessionID,
            intent: .codexTask,
            threadID: activeIdentity.threadID,
            turnID: activeIdentity.turnID,
            taskRevision: activeIdentity.revision,
            kind: .failed,
            text: nil,
            detail: "Codex 任务已更新，旧录音已拒绝。",
            localeIdentifier: speechLocaleIdentifier
        )
    }

    private func cancelVoiceContinuation() {
        guard let pendingVoice else { return }
        self.pendingVoice = nil
        voiceTimeoutTask?.cancel()
        voiceTimeoutTask = nil
        pendingVoice.continuation.resume(returning: false)
    }

    private func resolveCodexReply(
        submissionID: UUID,
        accepted: Bool,
        detail: String?
    ) {
        guard let pending = pendingCodexReplies.removeValue(forKey: submissionID) else { return }
        codexReplyTimeoutTasks.removeValue(forKey: submissionID)?.cancel()
        pending.completion(CodexReplyReceipt(
            submissionID: submissionID,
            codexTaskIdentity: pending.identity,
            accepted: accepted,
            detail: detail
        ))
    }

    private func failPendingCodexReplies(detail: String) {
        let pending = pendingCodexReplies
        pendingCodexReplies.removeAll()
        codexReplyTimeoutTasks.values.forEach { $0.cancel() }
        codexReplyTimeoutTasks.removeAll()
        for (submissionID, request) in pending {
            request.completion(CodexReplyReceipt(
                submissionID: submissionID,
                codexTaskIdentity: request.identity,
                accepted: false,
                detail: detail
            ))
        }
    }

    private func sendSecure(_ message: WristBridgeWireMessage) {
        guard let sessionKey,
              let cleartext = try? JSONEncoder().encode(message),
              let sealed = try? ChaChaPoly.seal(cleartext, using: sessionKey)
        else { return }
        sendPlain(WristBridgeWireMessage(
            type: "secure",
            payload: sealed.combined.base64EncodedString()
        ))
    }

    private func sendPlain(_ message: WristBridgeWireMessage) {
        guard let connection, var data = try? JSONEncoder().encode(message) else { return }
        let generation = connectionGeneration
        data.append(0x0A)
        connection.send(content: data, completion: .contentProcessed {
            [weak self, weak connection] error in
            guard error != nil else { return }
            DispatchQueue.main.async {
                guard let self,
                      let connection,
                      connection === self.connection,
                      generation == self.connectionGeneration
                else { return }
                self.fail("向腕上遥控桥发送失败")
            }
        })
    }

    private func decrypt(_ envelope: WristBridgeWireMessage) -> WristBridgeWireMessage? {
        guard let sessionKey,
              let encoded = envelope.payload,
              let data = Data(base64Encoded: encoded),
              let box = try? ChaChaPoly.SealedBox(combined: data),
              let cleartext = try? ChaChaPoly.open(box, using: sessionKey)
        else { return nil }
        return try? JSONDecoder().decode(WristBridgeWireMessage.self, from: cleartext)
    }

    private func fail(_ detail: String) {
        resetConnection(sendVoiceStop: false)
        browser?.cancel()
        browser = nil
        state = .unavailable(detail)
        macName = "未找到可用的 Mac"
        scheduleReconnect()
    }

    private func applyInternetRelayProvisioning(_ encoded: String?) {
        guard let encoded,
              let provisioning = WristInternetRelayDeviceProvisioning.decodeBase64(encoded)
        else { return }
        guard provisioning != internetRelayProvisioning else { return }
        guard WristInternetRelayKeychain.save(
            provisioning,
            account: Self.internetRelayKeychainAccount,
            service: Self.internetRelayKeychainService
        ) else {
            watchActionProfileError = "无法安全保存公网遥控凭证"
            return
        }
        internetRelayProvisioning = provisioning
    }

    private func scheduleReconnect() {
        guard isSceneActive else { return }
        reconnectTask?.cancel()
        let attempt = reconnectAttempt
        reconnectAttempt = min(reconnectAttempt + 1, 5)
        let delay = Self.reconnectDelaySeconds(attempt: attempt)
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled, isSceneActive, connection == nil else { return }
            browser?.cancel()
            browser = nil
            state = .searching
            macName = "正在查找 Mac"
            startBrowser()
        }
    }

    private func resetConnection(sendVoiceStop: Bool) {
        connectionWatchdogTask?.cancel()
        connectionWatchdogTask = nil
        cancelPendingLivenessProbe()
        if sendVoiceStop,
           let sessionID = activeVoiceSessionID ?? pendingVoice?.sessionID,
           let revision = activeVoiceProfileRevision ?? pendingVoice?.profileRevision,
           let stop = Self.voiceMessage(
               type: "voiceStop",
               sessionID: sessionID,
               profileRevision: revision,
               intent: pendingVoice?.intent ?? activeVoiceIntent,
               codexTaskIdentity: pendingVoice?.codexTaskIdentity
                    ?? activeVoiceCodexTaskIdentity
           ) {
            sendSecure(stop)
        }
        connectionGeneration &+= 1
        cancelVoiceContinuation()
        connection?.cancel()
        connection = nil
        receiveBuffer.removeAll(keepingCapacity: true)
        ephemeralPrivateKey = nil
        sessionKey = nil
        pairingCode = nil
        supportsVoiceSessions = false
        supportsCodexTasks = false
        supportsVoiceOutcomes = false
        supportsCodexReplyReceipts = false
        supportsWatchActionProfiles = false
        profileTimeoutTask?.cancel()
        profileTimeoutTask = nil
        profileBusyRetryTask?.cancel()
        profileBusyRetryTask = nil
        profileBusyRetryCount = 0
        profileBusyWaitingRevision = nil
        profileQueue.reset()
        desiredProfile = nil
        acceptedWatchProfileRevision = nil
        watchApplicationTitles = [:]
        watchActionProfileError = nil
        activeVoiceSessionID = nil
        activeVoiceProfileRevision = nil
        activeVoiceIntent = .foregroundDictation
        activeVoiceCodexTaskIdentity = nil
        awaitingVoiceOutcomes.removeAll()
        failPendingCodexReplies(detail: "Mac 连接已中断，草稿已保留")
        voiceOwner = nil
        // Keep the last task and outcome as stale display state. Connectivity
        // gates all actions, and retaining the identity lets Watch preserve a
        // draft and its submission ID across a temporary Mac disconnect.
    }

    private nonisolated static func normalizedTitles(
        _ titles: [String: String]
    ) -> [String: String] {
        Dictionary(uniqueKeysWithValues: titles.compactMap { rawID, rawTitle in
            guard let id = UUID(uuidString: rawID) else { return nil }
            let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            return (id.uuidString, title)
        })
    }

    private nonisolated static func pairingCode(_ key: SymmetricKey) -> String {
        let value = key.withUnsafeBytes { bytes in
            bytes.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }
        return String(format: "%06d", value % 1_000_000)
    }

    private static let internetRelayKeychainAccount = "device-provisioning-v1"
    private static var internetRelayKeychainService: String {
        "\(Bundle.main.bundleIdentifier ?? "dev.wristremote.ios").internet-relay"
    }
}

enum WristBridgeInstallationIdentity {
    enum StorageAction: Equatable {
        case useStored
        case create
        case replaceCorrupt
        case retry
    }

    private static let account = "wrist-bridge-client-identity-v1"

    static func loadOrCreate() -> P256.Signing.PrivateKey? {
        let stored = storedData()
        let storedKey = stored.data.flatMap {
            try? P256.Signing.PrivateKey(rawRepresentation: $0)
        }

        switch storageAction(
            copyStatus: stored.status,
            hasStoredData: stored.data != nil,
            hasValidKey: storedKey != nil
        ) {
        case .useStored:
            return storedKey
        case .create:
            return storeNewKey(replacingExisting: false)
        case .replaceCorrupt:
            return storeNewKey(replacingExisting: true)
        case .retry:
            return nil
        }
    }

    static func storageAction(
        copyStatus: OSStatus,
        hasStoredData: Bool,
        hasValidKey: Bool
    ) -> StorageAction {
        if copyStatus == errSecSuccess {
            guard hasStoredData else { return .retry }
            return hasValidKey ? .useStored : .replaceCorrupt
        }
        if copyStatus == errSecItemNotFound { return .create }
        return .retry
    }

    private static func storeNewKey(
        replacingExisting: Bool
    ) -> P256.Signing.PrivateKey? {
        if replacingExisting {
            let deleteStatus = SecItemDelete(query as CFDictionary)
            guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
                return nil
            }
        }

        let key = P256.Signing.PrivateKey()
        var attributes = query
        attributes[kSecValueData as String] = key.rawRepresentation
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        if addStatus == errSecSuccess { return key }
        if addStatus == errSecDuplicateItem {
            let stored = storedData()
            guard stored.status == errSecSuccess,
                  let data = stored.data
            else { return nil }
            return try? P256.Signing.PrivateKey(rawRepresentation: data)
        }
        return nil
    }

    private static var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Bundle.main.bundleIdentifier
                ?? "dev.wristremote.ios",
            kSecAttrAccount as String: account,
        ]
    }

    private static func storedData() -> (status: OSStatus, data: Data?) {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        return (status, result as? Data)
    }
}
