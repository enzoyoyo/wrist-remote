import CryptoKit
import Foundation
import Network
import OSLog
import Security
import UIKit

enum WristInternetRelayClearMarker {
    private struct KeychainRecord: Codable {
        let version: Int
        let cleared: Bool
    }

    private static let defaultsKey = "internetRelayProvisioningClearedV1"
    private static let keychainAccount = "device-provisioning-cleared-v1"
    private static var keychainService: String {
        "\(Bundle.main.bundleIdentifier ?? "dev.wristremote.ios").internet-relay"
    }
    private static let recordVersion = 1

    static func isSet(
        defaults: UserDefaults = .standard,
        keychainCleared: Bool? = nil
    ) -> Bool {
        defaults.bool(forKey: defaultsKey)
            || (keychainCleared ?? isKeychainMarkerSet())
    }

    @discardableResult
    static func setCleared(
        _ cleared: Bool,
        defaults: UserDefaults = .standard,
        updateKeychain: ((Bool) -> Bool)? = nil
    ) -> Bool {
        let updateKeychain = updateKeychain ?? updateKeychainMarker

        // This contains no credential material. Keep the revocation in both
        // stores: UserDefaults remains available when Keychain is temporarily
        // locked, while the Keychain copy survives an uninstall/reinstall just
        // like the credential it revokes.
        if cleared {
            let keychainPersisted = updateKeychain(true)
            defaults.set(true, forKey: defaultsKey)
            return defaults.synchronize() && keychainPersisted
        } else {
            // Never make a newly installed credential active while a durable
            // Keychain revocation marker may still survive the process.
            guard updateKeychain(false) else { return false }
            defaults.removeObject(forKey: defaultsKey)
            return defaults.synchronize()
        }
    }

    private static func isKeychainMarkerSet() -> Bool {
        let result = WristInternetRelayKeychain.loadResult(
            KeychainRecord.self,
            account: keychainAccount,
            service: keychainService
        )
        return WristInternetRelayKeychain.blocksCredentialRecovery(
            for: result,
            isRevoked: { record in
                // Unknown marker versions are ambiguous and therefore revoke
                // recovery until the user explicitly provisions again.
                record.version != recordVersion || record.cleared
            }
        )
    }

    private static func updateKeychainMarker(_ cleared: Bool) -> Bool {
        if cleared {
            return WristInternetRelayKeychain.save(
                KeychainRecord(version: recordVersion, cleared: true),
                account: keychainAccount,
                service: keychainService
            )
        }
        return WristInternetRelayKeychain.delete(
            account: keychainAccount,
            service: keychainService
        )
    }
}

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

    enum DirectRoute: String, Hashable {
        case lan
        case tailnet

        var displayTitle: String {
            switch self {
            case .lan: return "局域网"
            case .tailnet: return "Tailscale 私有网络"
            }
        }
    }

    enum ServerTrustDecision: Equatable {
        case trusted
        case requiresApproval
        case mismatch
        case storageUnavailable
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
        let codexConversationTarget: WatchCodexConversationTarget?
        let requestID: UInt64
        let generation: Int
        let continuation: CheckedContinuation<Bool, Never>
    }

    private struct PendingAudioDelivery {
        let sessionID: String
        let profileRevision: Int
        let intent: WatchVoiceIntent
        let codexTaskIdentity: WatchCodexTaskIdentity?
        let codexConversationTarget: WatchCodexConversationTarget?
        let generation: Int
        let completion: (WristBridgeAudioDeliveryReceipt) -> Void
    }

    private struct AwaitingVoiceOutcome {
        let intent: WatchVoiceIntent
        let codexTaskIdentity: WatchCodexTaskIdentity?
        let codexConversationTarget: WatchCodexConversationTarget?
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

    struct CodexConversationCatalogReceipt: Equatable {
        let requestID: UUID
        let catalog: WatchCodexConversationCatalog?
        let accepted: Bool
        let detail: String?
    }

    struct CodexConversationTargetReceipt: Equatable {
        let requestID: UUID
        let requestedTarget: WatchCodexConversationTarget
        let selectedTarget: WatchCodexConversationTarget?
        let accepted: Bool
        let detail: String?
    }

    struct CodexConversationDraftReceipt: Equatable {
        let submissionID: UUID
        let draftID: UUID
        let requestedTarget: WatchCodexConversationTarget
        let resolvedTarget: WatchCodexConversationTarget?
        let accepted: Bool
        let detail: String?
    }

    private struct PendingCodexConversationCatalogRequest {
        let generation: Int
        let completion: (CodexConversationCatalogReceipt) -> Void
    }

    private struct PendingCodexConversationTargetSelection {
        let target: WatchCodexConversationTarget
        let generation: Int
        let completion: (CodexConversationTargetReceipt) -> Void
    }

    private struct PendingCodexConversationDraftSubmission {
        let draftID: UUID
        let target: WatchCodexConversationTarget
        let generation: Int
        let completion: (CodexConversationDraftReceipt) -> Void
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
    @Published private(set) var codexConversationCatalog: WatchCodexConversationCatalog?
    @Published private(set) var lastVoiceOutcome: WatchVoiceOutcome?
    @Published private(set) var speechLocaleIdentifier = "zh-CN"
    @Published private(set) var internetRelayProvisioning: WristInternetRelayDeviceProvisioning?
    @Published private(set) var internetRelayProvisioningCleared = false
    @Published private(set) var privateNetworkConfiguration: WristPrivateNetworkConfiguration
    @Published private(set) var activeDirectRoute: DirectRoute?
    @Published private(set) var pendingServerIdentityFingerprint: String?
    @Published private(set) var pairingLinkError: String?
    @Published private(set) var supportsPhoneButtonTriggers = false
    @Published private(set) var directBridgeConfiguration: WristDirectBridgeConfiguration?
    @Published private(set) var directBridgeConfigurationCleared = false

    private let queue = DispatchQueue(label: "WristRemote.bridge.network", qos: .userInitiated)
    private let networkingEnabled: Bool
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "dev.wristremote.ios",
        category: "BridgeConnection"
    )
    nonisolated static let connectionWatchdogSeconds: TimeInterval = 12
    nonisolated static let privateNetworkFallbackSeconds: TimeInterval = 0.9
    nonisolated static let lanConnectionWatchdogSeconds: TimeInterval = 2.5
    nonisolated static let tailnetConnectionWatchdogSeconds: TimeInterval = 6
    nonisolated static let livenessProbeTimeoutSeconds: TimeInterval = 1
    nonisolated static let audioDeliveryTimeoutSeconds: TimeInterval = 3
    nonisolated static let codexConversationRequestTimeoutSeconds: TimeInterval = 13
    nonisolated static let codexConversationTargetSelectionTimeoutSeconds: TimeInterval = 30
    nonisolated static let codexConversationSubmissionTimeoutSeconds: TimeInterval = 22

    private var identityPrivateKey: P256.Signing.PrivateKey?
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var candidateConnections: [DirectRoute: NWConnection] = [:]
    private var reconnectTask: Task<Void, Never>?
    private var privateNetworkFallbackTask: Task<Void, Never>?
    private var connectionWatchdogTasks: [DirectRoute: Task<Void, Never>] = [:]
    private var livenessProbeTimeoutTask: Task<Void, Never>?
    private var pendingLivenessProbe: PendingLivenessProbe?
    private var protectedDataObserver: NSObjectProtocol?
    private var reconnectAttempt = 0
    private var isSceneActive = false
    private var connectionGeneration = 0
    private var attemptedDirectRoute: DirectRoute?
    private var receiveBuffer = Data()
    private var ephemeralPrivateKey: Curve25519.KeyAgreement.PrivateKey?
    private var clientEphemeralPublicKey: Data?
    private var serverEphemeralPublicKey: Data?
    private var serverIdentityPublicKey: Data?
    private var sessionKey: SymmetricKey?
    private var secureChannel = WristBridgeSecureChannel()
    private var pairingCode: String?
    private var didReceiveServerKey = false
    private var didSendClientAuthentication = false
    private var trustedServerIdentityFingerprint: String?
    private var trustedServerIdentityStoreAvailable = false
    private var verifiedServerIdentityFingerprint: String?
    private var pendingServerIdentityLocallyApproved = false
    private var supportsVoiceSessions = false
    private var supportsCodexTasks = false
    private var supportsVoiceOutcomes = false
    private var supportsCodexReplyReceipts = false
    private var supportsCodexConversations = false
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
    private var pendingAudioDeliveries: [UInt64: PendingAudioDelivery] = [:]
    private var audioDeliveryTimeoutTasks: [UInt64: Task<Void, Never>] = [:]
    private var macAudioContiguousThrough: UInt64?
    private var activeVoiceSessionID: String?
    private var activeVoiceProfileRevision: Int?
    private var activeVoiceIntent: WatchVoiceIntent = .foregroundDictation
    private var activeVoiceCodexTaskIdentity: WatchCodexTaskIdentity?
    private var activeVoiceCodexConversationTarget: WatchCodexConversationTarget?
    private var awaitingVoiceOutcomes: [String: AwaitingVoiceOutcome] = [:]
    private var pendingCodexReplies: [UUID: PendingCodexReply] = [:]
    private var codexReplyTimeoutTasks: [UUID: Task<Void, Never>] = [:]
    private var pendingCodexConversationCatalogRequests:
        [UUID: PendingCodexConversationCatalogRequest] = [:]
    private var pendingCodexConversationTargetSelections:
        [UUID: PendingCodexConversationTargetSelection] = [:]
    private var pendingCodexConversationDraftSubmissions:
        [UUID: PendingCodexConversationDraftSubmission] = [:]
    private var codexConversationTimeoutTasks: [UUID: Task<Void, Never>] = [:]
    private var lastAppliedCodexTaskRevision = -1
    private var pairingTarget: WristPairingLink?
    private var pairingRoutePolicy = WristPairingRoutePolicy()
    private var phoneButtonReceiptLedger = WristPhoneButtonReceiptLedger()
    private var phoneButtonCompletions: [UUID: (WristPhoneButtonReceipt) -> Void] = [:]
    private var phoneButtonTimeoutTasks: [UUID: Task<Void, Never>] = [:]

    init(networkingEnabled: Bool = true) {
        self.networkingEnabled = networkingEnabled
        privateNetworkConfiguration = WristPrivateNetworkConfigurationStore.load()
        internetRelayProvisioningCleared = WristInternetRelayClearMarker.isSet()
        switch WristBridgeTrustedServerIdentityStore.load() {
        case .notFound:
            trustedServerIdentityStoreAvailable = true
        case let .loaded(fingerprint):
            trustedServerIdentityFingerprint = fingerprint
            trustedServerIdentityStoreAvailable = true
        case .unavailable:
            trustedServerIdentityStoreAvailable = false
        }
        if let savedTarget = WristPairingLink.load(),
           savedTarget.identityFingerprint == trustedServerIdentityFingerprint {
            pairingTarget = savedTarget
        }
        if Self.permitsInternetRelayKeychainRecovery(
            relayEnabledForCurrentBuild:
                WristInternetRelayConfiguration.isEnabledForCurrentBuild,
            privateNetworkEnabled: privateNetworkConfiguration.isEnabled,
            explicitlyCleared: internetRelayProvisioningCleared
        ) {
            internetRelayProvisioning = WristInternetRelayKeychain.load(
                WristInternetRelayDeviceProvisioning.self,
                account: Self.internetRelayKeychainAccount,
                service: Self.internetRelayKeychainService
            )
        } else {
            _ = WristInternetRelayClearMarker.setCleared(true)
            internetRelayProvisioningCleared = true
            internetRelayProvisioning = nil
            _ = WristInternetRelayKeychain.delete(
                account: Self.internetRelayKeychainAccount,
                service: Self.internetRelayKeychainService
            )
        }
        protectedDataObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.protectedDataDidBecomeAvailable()
            }
        }
        if !networkingEnabled { state = .unavailable("界面预览：已禁用联网") }
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

    var requiresServerTrustConfirmation: Bool {
        pendingServerIdentityFingerprint != nil
            && !pendingServerIdentityLocallyApproved
            && state == .awaitingApproval
    }

    var displayedServerIdentityFingerprint: String? {
        pendingServerIdentityFingerprint.map { fingerprint in
            stride(from: 0, to: min(fingerprint.count, 24), by: 4).map { offset in
                let start = fingerprint.index(fingerprint.startIndex, offsetBy: offset)
                let end = fingerprint.index(
                    start,
                    offsetBy: min(4, fingerprint.distance(from: start, to: fingerprint.endIndex))
                )
                return String(fingerprint[start ..< end])
            }.joined(separator: " ")
        }
    }

    var hasTrustedMacIdentity: Bool {
        trustedServerIdentityFingerprint != nil
    }

    var trustedMacIdentitySummary: String? {
        trustedServerIdentityFingerprint.map { fingerprint in
            let end = fingerprint.index(
                fingerprint.startIndex,
                offsetBy: min(12, fingerprint.count)
            )
            return String(fingerprint[..<end])
        }
    }

    func resolveServerTrust(_ allowed: Bool) {
        guard requiresServerTrustConfirmation else { return }
        guard allowed else {
            fail("你拒绝了这台 Mac 的身份，未建立连接")
            return
        }
        pendingServerIdentityLocallyApproved = true
        sendClientAuthentication()
    }

    @discardableResult
    func forgetTrustedMacIdentity() -> Bool {
        guard WristBridgeTrustedServerIdentityStore.delete() else { return false }
        WristPairingLink.clear()
        pairingTarget = nil
        pairingRoutePolicy.resetForImportedLink()
        pairingLinkError = nil
        directBridgeConfiguration = nil
        directBridgeConfigurationCleared = true
        trustedServerIdentityFingerprint = nil
        trustedServerIdentityStoreAvailable = true
        pendingServerIdentityFingerprint = nil
        pendingServerIdentityLocallyApproved = false
        if isSceneActive {
            restartDiscovery(reason: "trusted_mac_identity_forgotten")
        } else {
            resetConnection(sendVoiceCancel: true)
            state = .unavailable("已忘记旧 Mac 身份；打开 App 后重新配对")
        }
        return true
    }

    @discardableResult
    func resetInstallationIdentity() -> Bool {
        guard let replacement = WristBridgeInstallationIdentity.reset() else { return false }
        identityPrivateKey = replacement
        if isSceneActive {
            restartDiscovery(reason: "iphone_installation_identity_reset")
        } else {
            resetConnection(sendVoiceCancel: true)
            state = .unavailable("已重置此 iPhone 的配对身份；打开 App 后重新配对")
        }
        return true
    }

    var privateNetworkHost: String { privateNetworkConfiguration.host }

    @discardableResult
    func importPairingLink(_ url: URL) -> Bool {
        do {
            let target = try WristPairingLink.parse(url)
            if let trustedServerIdentityFingerprint,
               !target.matchesIdentity(trustedServerIdentityFingerprint) {
                throw WristPairingLinkError.identityMismatch
            }
            pairingLinkError = nil
            pairingTarget = target
            pairingRoutePolicy.resetForImportedLink()
            restartDiscovery(reason: "pairing_qr_imported")
            return true
        } catch {
            pairingLinkError = error.localizedDescription
            return false
        }
    }

    var isPrivateNetworkEnabled: Bool { privateNetworkConfiguration.isEnabled }

    var directRouteStatusText: String {
        if let activeDirectRoute, isConnected {
            return "已通过\(activeDirectRoute.displayTitle)连接"
        }
        if privateNetworkConfiguration.isEnabled {
            return "局域网优先，Tailscale 自动备用"
        }
        return "未启用"
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
        guard isSceneActive,
              browser == nil,
              connection == nil,
              candidateConnections.isEmpty
        else { return }
        startBrowser()
    }

    func restartDiscovery(reason: String = "manual") {
        guard networkingEnabled else { return }
        logger.notice("Restarting bridge discovery: \(reason, privacy: .public)")
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempt = 0
        resetConnection(sendVoiceCancel: true)
        browser?.cancel()
        browser = nil
        state = .searching
        macName = "正在查找 Mac"
        startBrowser()
    }

    @discardableResult
    func updatePrivateNetwork(
        isEnabled: Bool,
        host: String
    ) -> WristPrivateNetworkConfigurationError? {
        let result = WristPrivateNetworkConfiguration.validated(
            isEnabled: isEnabled,
            host: host
        )
        guard case let .success(configuration) = result else {
            if case let .failure(error) = result { return error }
            return .invalidHost
        }
        guard WristPrivateNetworkConfigurationStore.save(configuration) else {
            return .storageFailed
        }
        privateNetworkConfiguration = configuration
        if configuration.isEnabled,
           !applyInternetRelayProvisioning(.clear) {
            watchActionProfileError = "无法安全清除旧的公网遥控凭证"
        }
        if isSceneActive {
            restartDiscovery(reason: "private_network_configuration_changed")
        }
        return nil
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
            hasConnection: connection != nil || !candidateConnections.isEmpty
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
        let recoveredPrivateNetwork = WristPrivateNetworkConfigurationStore.load()
        if recoveredPrivateNetwork != privateNetworkConfiguration {
            privateNetworkConfiguration = recoveredPrivateNetwork
            recoveredProtectedValue = true
        }
        if WristInternetRelayClearMarker.isSet() {
            internetRelayProvisioningCleared = true
            internetRelayProvisioning = nil
        }
        if !Self.permitsInternetRelayKeychainRecovery(
            relayEnabledForCurrentBuild:
                WristInternetRelayConfiguration.isEnabledForCurrentBuild,
            privateNetworkEnabled: privateNetworkConfiguration.isEnabled,
            explicitlyCleared: internetRelayProvisioningCleared
        ) {
            _ = WristInternetRelayClearMarker.setCleared(true)
            internetRelayProvisioningCleared = true
            internetRelayProvisioning = nil
            if !WristInternetRelayKeychain.delete(
                account: Self.internetRelayKeychainAccount,
                service: Self.internetRelayKeychainService
            ) {
                watchActionProfileError = "无法安全清除公网遥控凭证"
            }
        } else if internetRelayProvisioning == nil,
           let recoveredProvisioning = WristInternetRelayKeychain.load(
               WristInternetRelayDeviceProvisioning.self,
               account: Self.internetRelayKeychainAccount,
               service: Self.internetRelayKeychainService
           ), recoveredProvisioning.isValid {
            internetRelayProvisioning = recoveredProvisioning
            recoveredProtectedValue = true
        }
        if !trustedServerIdentityStoreAvailable {
            switch WristBridgeTrustedServerIdentityStore.load() {
            case .notFound:
                trustedServerIdentityStoreAvailable = true
                recoveredProtectedValue = true
            case let .loaded(fingerprint):
                trustedServerIdentityFingerprint = fingerprint
                trustedServerIdentityStoreAvailable = true
                recoveredProtectedValue = true
            case .unavailable:
                break
            }
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

    func isPhoneRemoteReady(revision: Int) -> Bool {
        isWatchActionProfileReady(revision: revision) && supportsPhoneButtonTriggers
    }

    func sendPhoneButtonTrigger(
        _ command: WristBridgeCommand,
        trigger: WatchActionTrigger,
        profileRevision: Int
    ) async -> WristPhoneButtonReceipt {
        let requestID = UUID()
        guard isPhoneRemoteReady(revision: profileRevision) else {
            return WristPhoneButtonReceipt(
                requestID: requestID, outcome: .rejected,
                detail: "Mac 未连接或按键配置尚未确认，未发送操作"
            )
        }
        let issued = Self.currentEpochMilliseconds()
        guard phoneButtonReceiptLedger.begin(id: requestID, nowEpochMilliseconds: issued) else {
            return WristPhoneButtonReceipt(
                requestID: requestID, outcome: .rejected,
                detail: "尚有较多操作等待回执，请稍后再试"
            )
        }
        return await withCheckedContinuation { continuation in
            phoneButtonCompletions[requestID] = { continuation.resume(returning: $0) }
            phoneButtonTimeoutTasks[requestID] = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(
                    WristPhoneButtonReceiptLedger.timeoutMilliseconds
                ))
                guard let self, !Task.isCancelled,
                      let receipt = phoneButtonReceiptLedger.expire(
                        id: requestID,
                        nowEpochMilliseconds: max(Self.currentEpochMilliseconds(),
                            issued + WristPhoneButtonReceiptLedger.timeoutMilliseconds)
                      )
                else { return }
                completePhoneButtonReceipt(receipt)
            }
            var message = WristBridgeWireMessage(type: "buttonTrigger")
            message.command = command.rawValue
            message.buttonTrigger = trigger.rawValue
            message.profileRevision = profileRevision
            message.inputSource = "iPhone"
            message.requestID = requestID.uuidString
            message.issuedAtEpochMilliseconds = issued
            sendSecure(message)
        }
    }

    private func completePhoneButtonReceipt(_ receipt: WristPhoneButtonReceipt) {
        phoneButtonTimeoutTasks.removeValue(forKey: receipt.requestID)?.cancel()
        phoneButtonCompletions.removeValue(forKey: receipt.requestID)?(receipt)
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
        codexTaskIdentity: WatchCodexTaskIdentity?,
        codexConversationTarget: WatchCodexConversationTarget? = nil
    ) async -> Bool {
        guard UUID(uuidString: sessionID) != nil,
              isWatchActionProfileReady(revision: profileRevision),
              supportsVoiceSessions,
              voiceOwner == nil,
              pendingVoice == nil,
              pendingAudioDeliveries.isEmpty,
              activeVoiceSessionID == nil,
              Self.acceptsVoiceTarget(
                  intent: intent,
                  codexTaskIdentity: codexTaskIdentity,
                  codexConversationTarget: codexConversationTarget,
                  snapshot: codexTaskSnapshot,
                  catalog: codexConversationCatalog,
                  supportsCodexTasks: supportsCodexTasks,
                  supportsCodexConversations: supportsCodexConversations
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
                codexConversationTarget: codexConversationTarget,
                requestID: requestID,
                generation: generation,
                continuation: continuation
            )
            guard let start = Self.voiceMessage(
                type: "voiceStart",
                sessionID: sessionID,
                profileRevision: profileRevision,
                intent: intent,
                codexTaskIdentity: codexTaskIdentity,
                codexConversationTarget: codexConversationTarget
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
                if let cancel = Self.voiceMessage(
                    type: "voiceCancel",
                    sessionID: sessionID,
                    profileRevision: profileRevision,
                    intent: intent,
                    codexTaskIdentity: codexTaskIdentity,
                    codexConversationTarget: codexConversationTarget
                ) {
                    sendSecure(cancel)
                }
                resolveVoice(sessionID: sessionID, accepted: false)
            }
        }
    }

    @discardableResult
    func sendRelayedVoicePCM(
        _ data: Data,
        sessionID: String,
        profileRevision: Int,
        audioSequence: UInt64,
        completion: @escaping (WristBridgeAudioDeliveryReceipt) -> Void
    ) -> Bool {
        guard voiceOwner == .watch,
              isConnected,
              activeVoiceSessionID == sessionID,
              activeVoiceProfileRevision == profileRevision,
              acceptedWatchProfileRevision == profileRevision,
              pendingAudioDeliveries[audioSequence] == nil,
              !data.isEmpty,
              data.count.isMultiple(of: MemoryLayout<Int16>.size),
              let message = Self.voiceMessage(
                  type: "audio",
                  sessionID: sessionID,
                  profileRevision: profileRevision,
                  intent: pendingVoice?.intent ?? activeVoiceIntent,
                  codexTaskIdentity: pendingVoice?.codexTaskIdentity
                      ?? activeVoiceCodexTaskIdentity,
                  codexConversationTarget: pendingVoice?.codexConversationTarget
                      ?? activeVoiceCodexConversationTarget,
                  samples: data.base64EncodedString(),
                  audioSequence: audioSequence
              )
        else { return false }
        let generation = connectionGeneration
        pendingAudioDeliveries[audioSequence] = PendingAudioDelivery(
            sessionID: sessionID,
            profileRevision: profileRevision,
            intent: activeVoiceIntent,
            codexTaskIdentity: activeVoiceCodexTaskIdentity,
            codexConversationTarget: activeVoiceCodexConversationTarget,
            generation: generation,
            completion: completion
        )
        sendSecure(message)
        audioDeliveryTimeoutTasks[audioSequence]?.cancel()
        audioDeliveryTimeoutTasks[audioSequence] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.audioDeliveryTimeoutSeconds))
            guard let self,
                  !Task.isCancelled,
                  connectionGeneration == generation,
                  let pending = pendingAudioDeliveries.removeValue(forKey: audioSequence),
                  pending.generation == generation
            else { return }
            audioDeliveryTimeoutTasks.removeValue(forKey: audioSequence)?.cancel()
            pending.completion(WristBridgeAudioDeliveryReceipt(
                sequence: audioSequence,
                accepted: false,
                contiguousThrough: macAudioContiguousThrough
            ))
        }
        return true
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
        let conversationTarget = pendingVoice?.codexConversationTarget
            ?? activeVoiceCodexConversationTarget
        failPendingAudioDeliveries()
        cancelVoiceContinuation()
        activeVoiceSessionID = nil
        activeVoiceProfileRevision = nil
        activeVoiceIntent = .foregroundDictation
        activeVoiceCodexTaskIdentity = nil
        activeVoiceCodexConversationTarget = nil
        voiceOwner = nil
        if shouldSend,
           let message = Self.voiceMessage(
               type: "voiceStop",
               sessionID: sessionID,
               profileRevision: profileRevision,
               intent: intent,
               codexTaskIdentity: identity,
               codexConversationTarget: conversationTarget
           ) {
            sendSecure(message)
        }
    }

    func cancelRelayedVoice(sessionID: String, profileRevision: Int) {
        guard voiceOwner == .watch,
              (activeVoiceSessionID == sessionID || pendingVoice?.sessionID == sessionID),
              (activeVoiceProfileRevision == profileRevision
                  || pendingVoice?.profileRevision == profileRevision)
        else { return }
        let shouldSend = activeVoiceSessionID != nil || pendingVoice != nil
        let intent = pendingVoice?.intent ?? activeVoiceIntent
        let identity = pendingVoice?.codexTaskIdentity ?? activeVoiceCodexTaskIdentity
        let conversationTarget = pendingVoice?.codexConversationTarget
            ?? activeVoiceCodexConversationTarget
        failPendingAudioDeliveries()
        cancelVoiceContinuation()
        activeVoiceSessionID = nil
        activeVoiceProfileRevision = nil
        activeVoiceIntent = .foregroundDictation
        activeVoiceCodexTaskIdentity = nil
        activeVoiceCodexConversationTarget = nil
        voiceOwner = nil
        if shouldSend,
           let message = Self.voiceMessage(
               type: "voiceCancel",
               sessionID: sessionID,
               profileRevision: profileRevision,
               intent: intent,
               codexTaskIdentity: identity,
               codexConversationTarget: conversationTarget
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
        codexConversationTarget: WatchCodexConversationTarget? = nil,
        samples: String? = nil,
        audioSequence: UInt64? = nil
    ) -> WristBridgeWireMessage? {
        guard ["voiceStart", "audio", "voiceStop", "voiceCancel"].contains(type),
              UUID(uuidString: sessionID) != nil,
              profileRevision >= 0,
              acceptsVoiceTargetShape(
                  intent: intent,
                  codexTaskIdentity: codexTaskIdentity,
                  codexConversationTarget: codexConversationTarget
              ),
              (type == "audio" ? samples?.isEmpty == false : samples == nil),
              (type == "audio" ? audioSequence != nil : audioSequence == nil)
        else { return nil }
        return WristBridgeWireMessage(
            type: type,
            samples: samples,
            audioSequence: audioSequence,
            sessionID: sessionID,
            inputSource: WristBridgeWireMessage.appleWatchInputSource,
            profileRevision: profileRevision,
            voiceIntent: intent.rawValue,
            threadID: codexTaskIdentity?.threadID,
            turnID: codexTaskIdentity?.turnID,
            taskRevision: codexTaskIdentity?.revision,
            codexConversationTarget: codexConversationTarget
        )
    }

    nonisolated static func audioDeliveryReceipt(
        from message: WristBridgeWireMessage,
        expectedSessionID: String,
        expectedProfileRevision: Int,
        expectedSequence: UInt64,
        expectedIntent: WatchVoiceIntent,
        expectedCodexTaskIdentity: WatchCodexTaskIdentity?,
        expectedCodexConversationTarget: WatchCodexConversationTarget?
    ) -> WristBridgeAudioDeliveryReceipt? {
        guard message.type == "audioAck",
              message.sessionID == expectedSessionID,
              message.inputSource == WristBridgeWireMessage.appleWatchInputSource,
              message.profileRevision == expectedProfileRevision,
              message.audioSequence == expectedSequence,
              message.samples == nil,
              message.voiceIntent == expectedIntent.rawValue,
              wireCodexTaskIdentity(from: message) == expectedCodexTaskIdentity,
              message.codexConversationTarget == expectedCodexConversationTarget,
              acceptsVoiceTargetShape(
                  intent: expectedIntent,
                  codexTaskIdentity: expectedCodexTaskIdentity,
                  codexConversationTarget: expectedCodexConversationTarget
              ),
              let accepted = message.audioAccepted
        else { return nil }
        let contiguousThrough = message.audioContiguousThrough
        if accepted {
            guard contiguousThrough == expectedSequence else { return nil }
        } else {
            guard contiguousThrough.map({ $0 < expectedSequence }) != false else { return nil }
        }
        return WristBridgeAudioDeliveryReceipt(
            sequence: expectedSequence,
            accepted: accepted,
            contiguousThrough: contiguousThrough
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

    @discardableResult
    func requestCodexConversationCatalog(
        requestID: UUID,
        completion: @escaping (CodexConversationCatalogReceipt) -> Void
    ) -> Bool {
        guard isConnected,
              supportsCodexConversations,
              isCodexConversationRequestIDAvailable(requestID)
        else { return false }
        let generation = connectionGeneration
        pendingCodexConversationCatalogRequests[requestID] =
            PendingCodexConversationCatalogRequest(
                generation: generation,
                completion: completion
            )
        scheduleCodexConversationTimeout(id: requestID, generation: generation) {
            [weak self] in
            self?.resolveCodexConversationCatalogRequest(
                requestID: requestID,
                catalog: nil,
                accepted: false,
                detail: "Mac 会话目录请求超时"
            )
        }
        sendSecure(WristBridgeWireMessage(
            type: "codexConversationCatalogRequest",
            requestID: requestID.uuidString
        ))
        return true
    }

    @discardableResult
    func selectCodexConversationTarget(
        requestID: UUID,
        target: WatchCodexConversationTarget,
        completion: @escaping (CodexConversationTargetReceipt) -> Void
    ) -> Bool {
        guard isConnected,
              supportsCodexConversations,
              codexConversationCatalog?.entries.contains(where: {
                  $0.target == target && $0.canAcceptInput
              }) == true,
              !target.isExpired(atEpochMilliseconds: Self.currentEpochMilliseconds()),
              isCodexConversationRequestIDAvailable(requestID)
        else { return false }
        let generation = connectionGeneration
        pendingCodexConversationTargetSelections[requestID] =
            PendingCodexConversationTargetSelection(
                target: target,
                generation: generation,
                completion: completion
            )
        scheduleCodexConversationTimeout(
            id: requestID,
            generation: generation,
            timeoutSeconds: Self.codexConversationTargetSelectionTimeoutSeconds
        ) {
            [weak self] in
            self?.resolveCodexConversationTargetSelection(
                requestID: requestID,
                selectedTarget: nil,
                accepted: false,
                detail: "Mac 会话选择确认超时"
            )
        }
        sendSecure(WristBridgeWireMessage(
            type: "codexConversationTargetSelect",
            requestID: requestID.uuidString,
            codexConversationTarget: target
        ))
        return true
    }

    @discardableResult
    func submitCodexConversationDraft(
        submissionID: UUID,
        draftID: UUID,
        target: WatchCodexConversationTarget,
        transcript: String,
        completion: @escaping (CodexConversationDraftReceipt) -> Void
    ) -> Bool {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isConnected,
              supportsCodexConversations,
              target.kind == .existing,
              WatchCodexConversationWireValidation.isValidTranscript(text),
              !target.isExpired(atEpochMilliseconds: Self.currentEpochMilliseconds()),
              isCodexConversationRequestIDAvailable(submissionID)
        else { return false }
        let generation = connectionGeneration
        pendingCodexConversationDraftSubmissions[submissionID] =
            PendingCodexConversationDraftSubmission(
                draftID: draftID,
                target: target,
                generation: generation,
                completion: completion
            )
        scheduleCodexConversationTimeout(
            id: submissionID,
            generation: generation,
            timeoutSeconds: Self.codexConversationSubmissionTimeoutSeconds
        ) {
            [weak self] in
            self?.resolveCodexConversationDraftSubmission(
                submissionID: submissionID,
                resolvedTarget: nil,
                accepted: false,
                detail: "Mac 发送确认超时，草稿已保留"
            )
        }
        sendSecure(WristBridgeWireMessage(
            type: "codexConversationDraftSubmit",
            transcript: text,
            submissionID: submissionID.uuidString,
            draftID: draftID.uuidString,
            codexConversationTarget: target
        ))
        return true
    }

    private func isCodexConversationRequestIDAvailable(_ id: UUID) -> Bool {
        pendingCodexConversationCatalogRequests[id] == nil
            && pendingCodexConversationTargetSelections[id] == nil
            && pendingCodexConversationDraftSubmissions[id] == nil
    }

    nonisolated static func acceptsVoiceTargetShape(
        intent: WatchVoiceIntent,
        codexTaskIdentity: WatchCodexTaskIdentity?,
        codexConversationTarget: WatchCodexConversationTarget? = nil
    ) -> Bool {
        switch intent {
        case .foregroundDictation:
            return codexTaskIdentity == nil && codexConversationTarget == nil
        case .codexTask:
            return codexTaskIdentity != nil && codexConversationTarget == nil
        case .codexConversation:
            return codexTaskIdentity == nil && codexConversationTarget?.kind == .existing
        }
    }

    nonisolated static func acceptsVoiceTarget(
        intent: WatchVoiceIntent,
        codexTaskIdentity: WatchCodexTaskIdentity?,
        codexConversationTarget: WatchCodexConversationTarget? = nil,
        snapshot: WatchCodexTaskSnapshot?,
        catalog: WatchCodexConversationCatalog? = nil,
        supportsCodexTasks: Bool,
        supportsCodexConversations: Bool = false,
        nowEpochMilliseconds: Int64 = currentEpochMilliseconds()
    ) -> Bool {
        guard acceptsVoiceTargetShape(
            intent: intent,
            codexTaskIdentity: codexTaskIdentity,
            codexConversationTarget: codexConversationTarget
        ) else { return false }
        switch intent {
        case .foregroundDictation:
            return true
        case .codexTask:
            return supportsCodexTasks
                && WatchCodexTaskIdentity(snapshot) == codexTaskIdentity
                && snapshot?.state == .completed
        case .codexConversation:
            guard supportsCodexConversations,
                  let codexConversationTarget,
                  !codexConversationTarget.isExpired(
                      atEpochMilliseconds: nowEpochMilliseconds
                  )
            else { return false }
            return catalog?.entries.contains(where: {
                $0.target == codexConversationTarget && $0.canAcceptInput
            }) == true
        }
    }

    nonisolated static func acceptsVoiceOutcomeTargetShape(
        message: WristBridgeWireMessage,
        intent: WatchVoiceIntent,
        kind: WatchVoiceOutcomeKind,
        expectedTaskIdentity: WatchCodexTaskIdentity?,
        expectedConversationTarget: WatchCodexConversationTarget?
    ) -> Bool {
        let identity = wireCodexTaskIdentity(from: message)
        let hasTaskFields = hasWireCodexTaskIdentityFields(message)
        let hasRawDraftFields = message.draftID != nil
            || message.draftExpiresAtEpochMilliseconds != nil
            || message.codexConversationTarget != nil
        switch intent {
        case .foregroundDictation:
            return !hasTaskFields && !hasRawDraftFields
        case .codexTask:
            return identity == expectedTaskIdentity && !hasRawDraftFields
        case .codexConversation:
            guard !hasTaskFields, expectedConversationTarget != nil else { return false }
            if kind == .draft {
                return message.codexConversationTarget == expectedConversationTarget
                    && message.draftID != nil
                    && message.draftExpiresAtEpochMilliseconds != nil
            }
            return !hasRawDraftFields
        }
    }

    nonisolated static func currentEpochMilliseconds() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1_000).rounded())
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

    nonisolated static func codexConversationCatalogEnvelope(
        from message: WristBridgeWireMessage
    ) -> (catalog: WatchCodexConversationCatalog?, requestID: UUID?)? {
        guard ["ready", "status", "codexConversationCatalogSnapshot"].contains(message.type),
              WatchCodexConversationWireValidation.isValidDetail(message.detail)
        else { return nil }
        let requestID: UUID?
        if message.requestID != nil {
            guard let parsed = canonicalWireUUID(message.requestID) else { return nil }
            requestID = parsed
        } else {
            requestID = nil
        }
        return (message.codexConversationCatalog, requestID)
    }

    nonisolated static func codexConversationTargetReceipt(
        from message: WristBridgeWireMessage,
        expectedRequestID: UUID,
        expectedTarget: WatchCodexConversationTarget
    ) -> CodexConversationTargetReceipt? {
        guard message.type == "codexConversationTargetResult",
              canonicalWireUUID(message.requestID) == expectedRequestID,
              let accepted = message.accepted,
              WatchCodexConversationWireValidation.isValidDetail(message.detail)
        else { return nil }
        let selectedTarget = message.codexConversationTarget
        if accepted {
            guard let selectedTarget,
                  WatchCodexConversationSelectionResolution.isSafeReplacement(
                      requested: expectedTarget,
                      selected: selectedTarget,
                      nowEpochMilliseconds: currentEpochMilliseconds()
                  )
            else { return nil }
        } else {
            guard selectedTarget == nil else { return nil }
        }
        return CodexConversationTargetReceipt(
            requestID: expectedRequestID,
            requestedTarget: expectedTarget,
            selectedTarget: selectedTarget,
            accepted: accepted,
            detail: message.detail
        )
    }

    nonisolated static func codexConversationDraftReceipt(
        from message: WristBridgeWireMessage,
        expectedSubmissionID: UUID,
        expectedDraftID: UUID,
        expectedTarget: WatchCodexConversationTarget
    ) -> CodexConversationDraftReceipt? {
        guard message.type == "codexConversationDraftReceipt",
              canonicalWireUUID(message.submissionID) == expectedSubmissionID,
              canonicalWireUUID(message.draftID) == expectedDraftID,
              message.codexConversationTarget == expectedTarget,
              let accepted = message.accepted,
              WatchCodexConversationWireValidation.isValidDetail(message.detail)
        else { return nil }
        let resolvedTarget = message.resolvedCodexConversationTarget
        guard accepted == (resolvedTarget != nil) else { return nil }
        if accepted, resolvedTarget != expectedTarget { return nil }
        return CodexConversationDraftReceipt(
            submissionID: expectedSubmissionID,
            draftID: expectedDraftID,
            requestedTarget: expectedTarget,
            resolvedTarget: resolvedTarget,
            accepted: accepted,
            detail: message.detail
        )
    }

    private nonisolated static func canonicalWireUUID(_ value: String?) -> UUID? {
        guard let value,
              WatchCodexConversationWireValidation.isCanonicalUUIDString(value)
        else { return nil }
        return UUID(uuidString: value)
    }

    nonisolated static func acceptsServerIdentity(_ message: WristBridgeWireMessage) -> Bool {
        message.protocolID == WristBridgeWireMessage.protocolID
            && message.serverRole == WristBridgeWireMessage.serverRole
            && message.clientRole == nil
            && message.publicKey == nil
            && message.identityPublicKey == nil
            && message.identitySignature == nil
            && message.serverIdentityVersion == nil
            && message.serverIdentityPublicKey == nil
            && message.serverIdentitySignature == nil
            && message.serverIdentityPinned == nil
    }

    nonisolated static func acceptsServerKey(_ message: WristBridgeWireMessage) -> Bool {
        message.type == "serverKey"
            && message.protocolID == WristBridgeWireMessage.protocolID
            && message.serverRole == WristBridgeWireMessage.serverRole
            && message.clientRole == nil
            && message.deviceName == nil
            && message.identityPublicKey == nil
            && message.identitySignature == nil
            && message.serverIdentityVersion == WristBridgeWireMessage.serverIdentityVersion
            && message.publicKey != nil
            && message.serverIdentityPublicKey != nil
            && message.serverIdentitySignature != nil
            && message.serverIdentityPinned == nil
    }

    nonisolated static func serverTrustDecision(
        storedFingerprint: String?,
        storeAvailable: Bool,
        presentedFingerprint: String
    ) -> ServerTrustDecision {
        guard storeAvailable else { return .storageUnavailable }
        guard let storedFingerprint else { return .requiresApproval }
        return storedFingerprint == presentedFingerprint ? .trusted : .mismatch
    }

    nonisolated static func fingerprint(for publicKey: Data) -> String {
        SHA256.hash(data: publicKey).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func acceptsCapabilities(_ capabilities: [String]?) -> Bool {
        let values = Set(capabilities ?? [])
        return values.contains(WristBridgeWireMessage.voiceSessionsCapability)
            && values.contains(WristBridgeWireMessage.watchActionProfileCapability)
            && values.contains(WristBridgeWireMessage.codexTasksCapability)
            && values.contains(WristBridgeWireMessage.voiceOutcomesCapability)
            && values.contains(WristBridgeWireMessage.codexReplyReceiptsCapability)
            && values.contains(WristBridgeWireMessage.connectionLivenessCapability)
            && values.contains(WristBridgeWireMessage.serverIdentityCapability)
            && values.contains(WristBridgeWireMessage.secureSequenceCapability)
            && values.contains(WristBridgeWireMessage.audioDeliveryReceiptsCapability)
    }

    nonisolated static func permitsInternetRelayKeychainRecovery(
        relayEnabledForCurrentBuild: Bool,
        privateNetworkEnabled: Bool,
        explicitlyCleared: Bool
    ) -> Bool {
        relayEnabledForCurrentBuild && !privateNetworkEnabled && !explicitlyCleared
    }

    nonisolated static func supportsCodexConversationCapability(
        _ capabilities: [String]?
    ) -> Bool {
        Set(capabilities ?? []).contains(WristBridgeWireMessage.codexConversationsCapability)
    }

    nonisolated static func acceptsSecureMessageBeforeReady(_ type: String) -> Bool {
        type == "ready" || type == "denied"
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

    nonisolated static func connectionWatchdogSeconds(for route: DirectRoute) -> TimeInterval {
        switch route {
        case .lan: return lanConnectionWatchdogSeconds
        case .tailnet: return tailnetConnectionWatchdogSeconds
        }
    }

    private func startBrowser() {
        guard networkingEnabled else { return }
        if let pairingTarget, pairingRoutePolicy.takeAddressAttempt() {
            macName = pairingTarget.serverName
            let route: DirectRoute = WristPrivateNetworkHostValidator.normalizedHost(
                pairingTarget.host, allowMagicDNS: false
            ) != nil ? .tailnet : .lan
            connectCandidate(
                to: .hostPort(host: NWEndpoint.Host(pairingTarget.host),
                              port: NWEndpoint.Port(rawValue: UInt16(WristPairingLink.port))!),
                route: route
            )
            return
        }
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
                    if self.connection == nil, self.candidateConnections.isEmpty {
                        self.state = .searching
                    }
                case let .failed(error), let .waiting(error):
                    if self.connection == nil {
                        if self.privateNetworkFallbackEndpoint != nil {
                            self.startPrivateNetworkFallback(reason: "bonjour_unavailable")
                        } else if self.candidateConnections.isEmpty {
                            self.state = .unavailable(
                                "无法发现腕上遥控桥：\(error.localizedDescription)"
                            )
                            self.scheduleReconnect()
                        }
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
                self.connectCandidate(to: endpoint, route: .lan)
            }
        }
        self.browser = browser
        browser.start(queue: queue)
        schedulePrivateNetworkFallback()
    }

    private func schedulePrivateNetworkFallback() {
        privateNetworkFallbackTask?.cancel()
        guard privateNetworkFallbackEndpoint != nil else { return }
        privateNetworkFallbackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.privateNetworkFallbackSeconds))
            guard let self, !Task.isCancelled, connection == nil else { return }
            startPrivateNetworkFallback(reason: "lan_discovery_grace_elapsed")
        }
    }

    private func startPrivateNetworkFallback(reason: String) {
        guard connection == nil,
              candidateConnections[.tailnet] == nil,
              let endpoint = privateNetworkFallbackEndpoint
        else { return }
        logger.notice("Trying private-network bridge fallback: \(reason, privacy: .public)")
        connectCandidate(to: endpoint, route: .tailnet)
    }

    private var privateNetworkFallbackEndpoint: NWEndpoint? {
        if let endpoint = privateNetworkConfiguration.endpoint { return endpoint }
        // A Tailscale QR is an explicit choice of private route. Keep it as a
        // fallback after local discovery without enabling any public service.
        guard let pairingTarget,
              WristPrivateNetworkHostValidator.normalizedHost(
                pairingTarget.host, allowMagicDNS: false
              ) != nil
        else { return nil }
        return .hostPort(host: NWEndpoint.Host(pairingTarget.host),
                         port: NWEndpoint.Port(rawValue: UInt16(WristPairingLink.port))!)
    }

    private func connectCandidate(to endpoint: NWEndpoint, route: DirectRoute) {
        guard networkingEnabled, connection == nil, candidateConnections[route] == nil else { return }
        if candidateConnections.isEmpty {
            connectionGeneration &+= 1
        }
        state = .connecting
        let generation = connectionGeneration
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let candidate = NWConnection(to: endpoint, using: parameters)
        candidateConnections[route] = candidate
        scheduleConnectionWatchdog(candidate, generation: generation, route: route)
        candidate.stateUpdateHandler = { [weak self, weak candidate] connectionState in
            DispatchQueue.main.async {
                guard let self, let candidate,
                      generation == self.connectionGeneration
                else { return }
                if candidate === self.connection {
                    switch connectionState {
                    case let .failed(error):
                        self.fail("连接腕上遥控桥失败：\(error.localizedDescription)")
                    case .cancelled:
                        if self.connection != nil { self.fail("腕上遥控桥连接已断开") }
                    default:
                        break
                    }
                    return
                }
                guard candidate === self.candidateConnections[route] else { return }
                switch connectionState {
                case .ready:
                    self.adoptCandidate(
                        candidate,
                        endpoint: endpoint,
                        route: route,
                        generation: generation
                    )
                case let .failed(error):
                    self.candidateDidFail(
                        candidate,
                        route: route,
                        detail: error.localizedDescription
                    )
                case .waiting:
                    // Network.framework may wait while the VPN path comes up.
                    // The route-specific watchdog remains the fail-closed bound.
                    break
                case .cancelled:
                    self.candidateDidFail(candidate, route: route, detail: "连接已取消")
                default:
                    break
                }
            }
        }
        candidate.start(queue: queue)
    }

    private func adoptCandidate(
        _ candidate: NWConnection,
        endpoint: NWEndpoint,
        route: DirectRoute,
        generation: Int
    ) {
        guard connection == nil,
              generation == connectionGeneration,
              candidate === candidateConnections[route]
        else { return }
        candidateConnections.removeValue(forKey: route)
        connection = candidate
        attemptedDirectRoute = route
        for (otherRoute, otherCandidate) in candidateConnections {
            connectionWatchdogTasks.removeValue(forKey: otherRoute)?.cancel()
            otherCandidate.cancel()
        }
        candidateConnections.removeAll()
        privateNetworkFallbackTask?.cancel()
        privateNetworkFallbackTask = nil
        browser?.cancel()
        browser = nil
        if case let .service(name, _, _, _) = endpoint {
            macName = name
        } else if route == .tailnet {
            macName = "Tailscale 上的 Mac"
        }
        sendHello(generation: generation)
    }

    private func candidateDidFail(
        _ candidate: NWConnection,
        route: DirectRoute,
        detail: String
    ) {
        guard candidate === candidateConnections[route] else { return }
        candidateConnections.removeValue(forKey: route)
        connectionWatchdogTasks.removeValue(forKey: route)?.cancel()
        candidate.cancel()
        if route == .lan, privateNetworkFallbackEndpoint != nil {
            startPrivateNetworkFallback(reason: "lan_connection_failed")
        }
        guard connection == nil, candidateConnections.isEmpty else { return }
        if browser != nil {
            state = .searching
            scheduleReconnect()
        } else {
            state = .unavailable("通过\(route.displayTitle)连接失败：\(detail)")
            scheduleReconnect()
        }
    }

    private func scheduleConnectionWatchdog(
        _ candidate: NWConnection,
        generation: Int,
        route: DirectRoute
    ) {
        connectionWatchdogTasks.removeValue(forKey: route)?.cancel()
        connectionWatchdogTasks[route] = Task { @MainActor [weak self, weak candidate] in
            try? await Task.sleep(for: .seconds(Self.connectionWatchdogSeconds(for: route)))
            guard let self, let candidate, !Task.isCancelled,
                  generation == connectionGeneration
            else { return }
            if candidate === candidateConnections[route] {
                candidateDidFail(candidate, route: route, detail: "连接超时")
            } else if candidate === connection,
                      Self.shouldExpireConnectionWatchdog(
                          expectedGeneration: generation,
                          currentGeneration: connectionGeneration,
                          state: state,
                          hasConnection: true
                      ) {
                fail("通过\(route.displayTitle)连接腕上遥控桥超时，请确认 Mac 桥仍在运行")
            }
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
        _ = identityPrivateKey
        ephemeralPrivateKey = privateKey
        clientEphemeralPublicKey = publicData
        sendPlain(WristBridgeWireMessage(
            type: "hello",
            protocolID: WristBridgeWireMessage.protocolID,
            clientRole: WristBridgeWireMessage.clientRole,
            publicKey: publicData.base64EncodedString(),
            capabilities: [
                WristBridgeWireMessage.secureSequenceCapability,
                WristBridgeWireMessage.audioDeliveryReceiptsCapability,
            ]
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
            guard !frame.isEmpty else { continue }
            guard let message = try? JSONDecoder().decode(
                      WristBridgeWireMessage.self,
                      from: frame
                  ) else {
                fail("腕上遥控桥返回了无效握手数据")
                return
            }
            handleEnvelope(message, generation: generation)
        }
    }

    private func handleEnvelope(_ envelope: WristBridgeWireMessage, generation: Int) {
        if envelope.type == "serverKey" {
            guard !didReceiveServerKey,
                  sessionKey == nil,
                  Self.acceptsServerKey(envelope)
            else {
                fail("发现的 Mac 不是 WristRemoteBridge")
                return
            }
            establishSession(envelope, generation: generation)
            return
        }
        guard didReceiveServerKey,
              envelope.type == "secure",
              let message = decrypt(envelope)
        else {
            fail("腕上遥控桥握手顺序或加密数据无效")
            return
        }
        handleSecure(message, generation: generation)
    }

    private func establishSession(_ message: WristBridgeWireMessage, generation: Int) {
        guard generation == connectionGeneration,
              let ephemeralPrivateKey,
              let clientEphemeralPublicKey,
              let encodedServerEphemeralKey = message.publicKey,
              let serverEphemeralPublicKey = Data(base64Encoded: encodedServerEphemeralKey),
              let serverEphemeralKey = try? Curve25519.KeyAgreement.PublicKey(
                  rawRepresentation: serverEphemeralPublicKey
              ),
              let encodedServerIdentityKey = message.serverIdentityPublicKey,
              let serverIdentityPublicKey = Data(base64Encoded: encodedServerIdentityKey),
              let serverIdentityKey = try? P256.Signing.PublicKey(
                  rawRepresentation: serverIdentityPublicKey
              ),
              let encodedServerSignature = message.serverIdentitySignature,
              let serverSignatureData = Data(base64Encoded: encodedServerSignature),
              let serverSignature = try? P256.Signing.ECDSASignature(
                  rawRepresentation: serverSignatureData
              ),
              let serverProof = WristBridgeWireMessage.serverIdentityProof(
                  clientEphemeralPublicKey: clientEphemeralPublicKey,
                  serverEphemeralPublicKey: serverEphemeralPublicKey
              ),
              serverIdentityKey.isValidSignature(serverSignature, for: serverProof),
              let transcript = WristBridgeWireMessage.sessionTranscript(
                  clientEphemeralPublicKey: clientEphemeralPublicKey,
                  serverEphemeralPublicKey: serverEphemeralPublicKey,
                  serverIdentityPublicKey: serverIdentityPublicKey
              ),
              let secret = try? ephemeralPrivateKey.sharedSecretFromKeyAgreement(
                  with: serverEphemeralKey
              )
        else {
            fail("Mac 身份签名无效，已拒绝连接")
            return
        }

        let fingerprint = Self.fingerprint(for: serverIdentityPublicKey)
        if let pairingTarget, !pairingTarget.matchesIdentity(fingerprint) {
            fail("连接到的 Mac 身份与配对二维码不一致，已拒绝连接")
            return
        }
        let trustDecision = Self.serverTrustDecision(
            storedFingerprint: trustedServerIdentityFingerprint,
            storeAvailable: trustedServerIdentityStoreAvailable,
            presentedFingerprint: fingerprint
        )
        switch trustDecision {
        case .mismatch:
            fail("Mac 身份与已信任记录不一致，已拒绝连接")
            return
        case .storageUnavailable:
            fail("无法读取已信任的 Mac 身份；请解锁 iPhone 后重试")
            return
        case .trusted, .requiresApproval:
            break
        }

        let key = secret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(WristBridgeWireMessage.sessionSalt.utf8),
            sharedInfo: Data(SHA256.hash(data: transcript)),
            outputByteCount: 32
        )
        didReceiveServerKey = true
        secureChannel.reset()
        sessionKey = key
        self.ephemeralPrivateKey = nil
        self.serverEphemeralPublicKey = serverEphemeralPublicKey
        self.serverIdentityPublicKey = serverIdentityPublicKey
        verifiedServerIdentityFingerprint = fingerprint
        pairingCode = Self.pairingCode(key)
        if let attemptedDirectRoute {
            connectionWatchdogTasks.removeValue(forKey: attemptedDirectRoute)?.cancel()
        }
        state = .awaitingApproval
        switch trustDecision {
        case .trusted:
            sendClientAuthentication()
        case .requiresApproval:
            pendingServerIdentityFingerprint = fingerprint
        case .mismatch, .storageUnavailable:
            break
        }
    }

    private func sendClientAuthentication() {
        guard !didSendClientAuthentication,
              let identityPrivateKey,
              let clientEphemeralPublicKey,
              let serverEphemeralPublicKey,
              let serverIdentityPublicKey,
              let verifiedServerIdentityFingerprint,
              let proof = WristBridgeWireMessage.clientAuthenticationProof(
                  clientEphemeralPublicKey: clientEphemeralPublicKey,
                  serverEphemeralPublicKey: serverEphemeralPublicKey,
                  serverIdentityPublicKey: serverIdentityPublicKey,
                  clientIdentityPublicKey: identityPrivateKey.publicKey.rawRepresentation
              ),
              let signature = try? identityPrivateKey.signature(for: proof)
        else {
            fail("无法签署 Wrist Remote 客户端身份")
            return
        }
        didSendClientAuthentication = true
        sendSecure(WristBridgeWireMessage(
            type: "clientAuth",
            deviceName: UIDevice.current.name,
            identityPublicKey: identityPrivateKey.publicKey.rawRepresentation.base64EncodedString(),
            identitySignature: signature.rawRepresentation.base64EncodedString(),
            serverIdentityPinned: trustedServerIdentityFingerprint
                == verifiedServerIdentityFingerprint
        ))
    }

    private func handleSecure(_ message: WristBridgeWireMessage, generation: Int) {
        guard generation == connectionGeneration else { return }
        guard Self.acceptsSecureMessageBeforeReady(message.type) || isConnected else {
            fail("Mac 在身份确认完成前发送了应用数据")
            return
        }
        switch message.type {
        case "hello", "serverKey", "clientAuth":
            fail("Mac 重复或错位发送了握手消息")

        case "ready":
            let conversationCapability = Self.supportsCodexConversationCapability(
                message.capabilities
            )
            let internetRelayDirective = WristBridgeWireMessage
                .internetRelayProvisioningDirective(
                    encoded: message.internetRelayProvisioning,
                    cleared: message.internetRelayProvisioningCleared
                )
            guard let internetRelayDirective else {
                _ = applyInternetRelayProvisioning(.clear)
                fail("WristRemoteBridge 未明确声明公网遥控配置状态")
                return
            }
            guard !isConnected,
                  didSendClientAuthentication,
                  let verifiedServerIdentityFingerprint,
                  Self.acceptsServerIdentity(message),
                  Self.acceptsCapabilities(message.capabilities),
                  let taskUpdate = Self.codexTaskUpdate(from: message),
                  let catalogEnvelope = Self.codexConversationCatalogEnvelope(from: message),
                  (conversationCapability || message.codexConversationCatalog == nil)
            else {
                fail("WristRemoteBridge 身份或协议能力不完整")
                return
            }
            if trustedServerIdentityFingerprint == nil {
                guard pendingServerIdentityLocallyApproved,
                      pendingServerIdentityFingerprint == verifiedServerIdentityFingerprint,
                      WristBridgeTrustedServerIdentityStore.save(
                          verifiedServerIdentityFingerprint
                      )
                else {
                    fail("无法安全保存 Mac 身份，未建立连接")
                    return
                }
                trustedServerIdentityFingerprint = verifiedServerIdentityFingerprint
                trustedServerIdentityStoreAvailable = true
            } else if trustedServerIdentityFingerprint != verifiedServerIdentityFingerprint {
                fail("Mac 身份与已信任记录不一致，已拒绝连接")
                return
            }
            macName = message.deviceName ?? macName
            supportsVoiceSessions = true
            supportsWatchActionProfiles = true
            supportsCodexTasks = true
            supportsVoiceOutcomes = true
            supportsCodexReplyReceipts = true
            supportsCodexConversations = conversationCapability
            supportsPhoneButtonTriggers = Set(message.capabilities ?? [])
                .contains(WristDirectBridgeProtocol.buttonTriggerCapability)
            watchApplicationTitles = Self.normalizedTitles(message.watchApplicationTitles ?? [:])
            applyCodexTaskUpdate(taskUpdate)
            applyCodexConversationCatalog(
                conversationCapability ? catalogEnvelope.catalog : nil
            )
            speechLocaleIdentifier = message.speechLocaleIdentifier ?? "zh-CN"
            guard applyInternetRelayProvisioning(internetRelayDirective) else {
                fail("无法安全应用 Mac 的公网遥控配置")
                return
            }
            guard applyDirectBridgeConfiguration(
                message,
                allowMissing: !Set(message.capabilities ?? [])
                    .contains(WristDirectBridgeProtocol.capability)
            ) else {
                fail("Mac 发送的手表直连配置无效或身份不匹配")
                return
            }
            pairingTarget?.save()
            pairingLinkError = nil
            profileQueue.reset()
            desiredProfile = nil
            acceptedWatchProfileRevision = nil
            watchActionProfileError = nil
            pairingCode = nil
            pendingServerIdentityFingerprint = nil
            pendingServerIdentityLocallyApproved = false
            state = .connected
            activeDirectRoute = attemptedDirectRoute
            reconnectAttempt = 0
            reconnectTask?.cancel()
            reconnectTask = nil

        case "watchApplicationTitles":
            watchApplicationTitles = Self.normalizedTitles(message.watchApplicationTitles ?? [:])

        case "buttonTriggerResult":
            if let receipt = phoneButtonReceiptLedger.resolve(
                message, nowEpochMilliseconds: Self.currentEpochMilliseconds()
            ) {
                completePhoneButtonReceipt(receipt)
            }

        case "directBridgeConfiguration":
            guard applyDirectBridgeConfiguration(message, allowMissing: false) else {
                fail("Mac 发送的手表直连配置无效或身份不匹配")
                return
            }

        case "internetRelayProvisioning":
            guard let directive = WristBridgeWireMessage.internetRelayProvisioningDirective(
                encoded: message.internetRelayProvisioning,
                cleared: message.internetRelayProvisioningCleared
            ) else {
                _ = applyInternetRelayProvisioning(.clear)
                fail("Mac 发送了无效的公网遥控配置")
                return
            }
            guard applyInternetRelayProvisioning(directive) else {
                fail("无法安全应用 Mac 的公网遥控配置")
                return
            }

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
                  message.codexConversationTarget
                    == pendingVoice?.codexConversationTarget,
                  Self.acceptsVoiceTargetShape(
                      intent: intent,
                      codexTaskIdentity: Self.wireCodexTaskIdentity(from: message),
                      codexConversationTarget: message.codexConversationTarget
                  ),
                  (intent == .codexTask || !Self.hasWireCodexTaskIdentityFields(message)),
                  (intent == .codexConversation
                    || message.codexConversationTarget == nil)
            else { return }
            resolveVoice(
                sessionID: message.sessionID,
                accepted: message.type == "voiceReady"
            )

        case "audioAck":
            guard let audioSequence = message.audioSequence,
                  let pending = pendingAudioDeliveries[audioSequence],
                  pending.generation == connectionGeneration,
                  let receipt = Self.audioDeliveryReceipt(
                      from: message,
                      expectedSessionID: pending.sessionID,
                      expectedProfileRevision: pending.profileRevision,
                      expectedSequence: audioSequence,
                      expectedIntent: pending.intent,
                      expectedCodexTaskIdentity: pending.codexTaskIdentity,
                      expectedCodexConversationTarget: pending.codexConversationTarget
                  )
            else { return }
            pendingAudioDeliveries.removeValue(forKey: audioSequence)
            audioDeliveryTimeoutTasks.removeValue(forKey: audioSequence)?.cancel()
            if let contiguousThrough = receipt.contiguousThrough {
                macAudioContiguousThrough = max(
                    macAudioContiguousThrough ?? contiguousThrough,
                    contiguousThrough
                )
            }
            pending.completion(receipt)

        case "codexTaskSnapshot":
            guard supportsCodexTasks,
                  let update = Self.codexTaskUpdate(from: message)
            else { return }
            applyCodexTaskUpdate(update)

        case "status", "codexConversationCatalogSnapshot":
            guard supportsCodexConversations,
                  let envelope = Self.codexConversationCatalogEnvelope(from: message)
            else { return }
            if let requestID = envelope.requestID {
                guard let pending = pendingCodexConversationCatalogRequests[requestID],
                      pending.generation == connectionGeneration
                else { return }
                let acceptedCatalog = applyCodexConversationCatalog(envelope.catalog)
                resolveCodexConversationCatalogRequest(
                    requestID: requestID,
                    catalog: acceptedCatalog ? envelope.catalog : nil,
                    accepted: acceptedCatalog,
                    detail: acceptedCatalog
                        ? message.detail
                        : "Mac 返回了过期或冲突的会话目录"
                )
            } else {
                applyCodexConversationCatalog(envelope.catalog)
            }

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
                  Self.acceptsVoiceOutcomeTargetShape(
                      message: message,
                      intent: intent,
                      kind: kind,
                      expectedTaskIdentity: expected.codexTaskIdentity,
                      expectedConversationTarget: expected.codexConversationTarget
                  )
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
                localeIdentifier: message.speechLocaleIdentifier ?? speechLocaleIdentifier,
                draftID: Self.canonicalWireUUID(message.draftID),
                codexConversationTarget: message.codexConversationTarget,
                draftExpiresAtEpochMilliseconds: message.draftExpiresAtEpochMilliseconds
            )
            guard outcome.hasValidWireShape else { return }
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

        case "codexConversationTargetResult":
            guard supportsCodexConversations,
                  let requestID = Self.canonicalWireUUID(message.requestID),
                  let pending = pendingCodexConversationTargetSelections[requestID],
                  pending.generation == connectionGeneration,
                  let receipt = Self.codexConversationTargetReceipt(
                      from: message,
                      expectedRequestID: requestID,
                      expectedTarget: pending.target
                  )
            else { return }
            if receipt.accepted,
               pending.target.kind == .newConversation,
               let selectedTarget = receipt.selectedTarget,
               let updated = codexConversationCatalog?
                .installingImmediatelyCreatedConversation(
                    selectedTarget,
                    nowEpochMilliseconds: Self.currentEpochMilliseconds()
                ) {
                codexConversationCatalog = updated
            }
            resolveCodexConversationTargetSelection(
                requestID: requestID,
                selectedTarget: receipt.selectedTarget,
                accepted: receipt.accepted,
                detail: receipt.detail
            )

        case "codexConversationDraftReceipt":
            guard supportsCodexConversations,
                  let submissionID = Self.canonicalWireUUID(message.submissionID),
                  let pending = pendingCodexConversationDraftSubmissions[submissionID],
                  pending.generation == connectionGeneration,
                  let receipt = Self.codexConversationDraftReceipt(
                      from: message,
                      expectedSubmissionID: submissionID,
                      expectedDraftID: pending.draftID,
                      expectedTarget: pending.target
                  )
            else { return }
            resolveCodexConversationDraftSubmission(
                submissionID: submissionID,
                resolvedTarget: receipt.resolvedTarget,
                accepted: receipt.accepted,
                detail: receipt.detail
            )

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
            fail(message.detail ?? "Mac 拒绝了 Wrist Remote 配对")

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
            macAudioContiguousThrough = nil
            activeVoiceSessionID = sessionID
            activeVoiceProfileRevision = pendingVoice.profileRevision
            activeVoiceIntent = pendingVoice.intent
            activeVoiceCodexTaskIdentity = pendingVoice.codexTaskIdentity
            activeVoiceCodexConversationTarget = pendingVoice.codexConversationTarget
            awaitingVoiceOutcomes[sessionID] = AwaitingVoiceOutcome(
                intent: pendingVoice.intent,
                codexTaskIdentity: pendingVoice.codexTaskIdentity,
                codexConversationTarget: pendingVoice.codexConversationTarget
            )
        } else {
            failPendingAudioDeliveries()
            activeVoiceSessionID = nil
            activeVoiceProfileRevision = nil
            activeVoiceIntent = .foregroundDictation
            activeVoiceCodexTaskIdentity = nil
            activeVoiceCodexConversationTarget = nil
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

    @discardableResult
    private func applyCodexConversationCatalog(
        _ catalog: WatchCodexConversationCatalog?
    ) -> Bool {
        if let catalog {
            switch WatchCodexConversationCatalogAcceptancePolicy.disposition(
                current: codexConversationCatalog,
                candidate: catalog
            ) {
            case .install:
                break
            case .unchanged:
                return true
            case .rejectRevisionRollback, .rejectRevisionConflict:
                return false
            }
        }
        func permitsContinuation(_ target: WatchCodexConversationTarget) -> Bool {
            catalog?.permitsContinuingVoice(
                for: target, nowEpochMilliseconds: Self.currentEpochMilliseconds()
            ) == true
        }
        if let pendingVoice,
           pendingVoice.intent == .codexConversation,
           let target = pendingVoice.codexConversationTarget,
           !permitsContinuation(target) {
            if let cancel = Self.voiceMessage(
                type: "voiceCancel",
                sessionID: pendingVoice.sessionID,
                profileRevision: pendingVoice.profileRevision,
                intent: pendingVoice.intent,
                codexConversationTarget: target
            ) {
                sendSecure(cancel)
            }
            cancelVoiceContinuation()
            voiceOwner = nil
        }
        if activeVoiceIntent == .codexConversation,
           let sessionID = activeVoiceSessionID,
           let revision = activeVoiceProfileRevision,
           let target = activeVoiceCodexConversationTarget,
           !permitsContinuation(target) {
            failPendingAudioDeliveries()
            if let cancel = Self.voiceMessage(
                type: "voiceCancel",
                sessionID: sessionID,
                profileRevision: revision,
                intent: .codexConversation,
                codexConversationTarget: target
            ) {
                sendSecure(cancel)
            }
            activeVoiceSessionID = nil
            activeVoiceProfileRevision = nil
            activeVoiceIntent = .foregroundDictation
            activeVoiceCodexTaskIdentity = nil
            activeVoiceCodexConversationTarget = nil
            awaitingVoiceOutcomes.removeValue(forKey: sessionID)
            voiceOwner = nil
        }
        codexConversationCatalog = catalog
        return catalog != nil
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
            if let cancel = Self.voiceMessage(
                type: "voiceCancel",
                sessionID: pending.sessionID,
                profileRevision: pending.profileRevision,
                intent: pending.intent,
                codexTaskIdentity: pending.codexTaskIdentity
            ) {
                sendSecure(cancel)
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
        failPendingAudioDeliveries()
        if let cancel = Self.voiceMessage(
            type: "voiceCancel",
            sessionID: activeSessionID,
            profileRevision: activeRevision,
            intent: .codexTask,
            codexTaskIdentity: activeIdentity
        ) {
            sendSecure(cancel)
        }
        activeVoiceSessionID = nil
        activeVoiceProfileRevision = nil
        activeVoiceIntent = .foregroundDictation
        activeVoiceCodexTaskIdentity = nil
        activeVoiceCodexConversationTarget = nil
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

    private func failPendingAudioDeliveries() {
        let pending = pendingAudioDeliveries
        pendingAudioDeliveries.removeAll()
        audioDeliveryTimeoutTasks.values.forEach { $0.cancel() }
        audioDeliveryTimeoutTasks.removeAll()
        for (sequence, request) in pending.sorted(by: { $0.key < $1.key }) {
            request.completion(WristBridgeAudioDeliveryReceipt(
                sequence: sequence,
                accepted: false,
                contiguousThrough: macAudioContiguousThrough
            ))
        }
        macAudioContiguousThrough = nil
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

    private func scheduleCodexConversationTimeout(
        id: UUID,
        generation: Int,
        timeoutSeconds: TimeInterval = codexConversationRequestTimeoutSeconds,
        action: @escaping @MainActor () -> Void
    ) {
        codexConversationTimeoutTasks[id]?.cancel()
        codexConversationTimeoutTasks[id] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(timeoutSeconds))
            guard let self,
                  !Task.isCancelled,
                  connectionGeneration == generation
            else { return }
            action()
        }
    }

    private func resolveCodexConversationCatalogRequest(
        requestID: UUID,
        catalog: WatchCodexConversationCatalog?,
        accepted: Bool,
        detail: String?
    ) {
        guard let pending = pendingCodexConversationCatalogRequests.removeValue(
            forKey: requestID
        ) else { return }
        codexConversationTimeoutTasks.removeValue(forKey: requestID)?.cancel()
        pending.completion(CodexConversationCatalogReceipt(
            requestID: requestID,
            catalog: catalog,
            accepted: accepted,
            detail: detail
        ))
    }

    private func resolveCodexConversationTargetSelection(
        requestID: UUID,
        selectedTarget: WatchCodexConversationTarget?,
        accepted: Bool,
        detail: String?
    ) {
        guard let pending = pendingCodexConversationTargetSelections.removeValue(
            forKey: requestID
        ) else { return }
        codexConversationTimeoutTasks.removeValue(forKey: requestID)?.cancel()
        pending.completion(CodexConversationTargetReceipt(
            requestID: requestID,
            requestedTarget: pending.target,
            selectedTarget: selectedTarget,
            accepted: accepted,
            detail: detail
        ))
    }

    private func resolveCodexConversationDraftSubmission(
        submissionID: UUID,
        resolvedTarget: WatchCodexConversationTarget?,
        accepted: Bool,
        detail: String?
    ) {
        guard let pending = pendingCodexConversationDraftSubmissions.removeValue(
            forKey: submissionID
        ) else { return }
        codexConversationTimeoutTasks.removeValue(forKey: submissionID)?.cancel()
        pending.completion(CodexConversationDraftReceipt(
            submissionID: submissionID,
            draftID: pending.draftID,
            requestedTarget: pending.target,
            resolvedTarget: resolvedTarget,
            accepted: accepted,
            detail: detail
        ))
    }

    private func failPendingCodexConversationRequests(detail: String) {
        let catalogs = pendingCodexConversationCatalogRequests
        let targets = pendingCodexConversationTargetSelections
        let drafts = pendingCodexConversationDraftSubmissions
        pendingCodexConversationCatalogRequests.removeAll()
        pendingCodexConversationTargetSelections.removeAll()
        pendingCodexConversationDraftSubmissions.removeAll()
        codexConversationTimeoutTasks.values.forEach { $0.cancel() }
        codexConversationTimeoutTasks.removeAll()
        for (requestID, pending) in catalogs {
            pending.completion(CodexConversationCatalogReceipt(
                requestID: requestID,
                catalog: nil,
                accepted: false,
                detail: detail
            ))
        }
        for (requestID, pending) in targets {
            pending.completion(CodexConversationTargetReceipt(
                requestID: requestID,
                requestedTarget: pending.target,
                selectedTarget: nil,
                accepted: false,
                detail: detail
            ))
        }
        for (submissionID, pending) in drafts {
            pending.completion(CodexConversationDraftReceipt(
                submissionID: submissionID,
                draftID: pending.draftID,
                requestedTarget: pending.target,
                resolvedTarget: nil,
                accepted: false,
                detail: detail
            ))
        }
    }

    private func sendSecure(_ message: WristBridgeWireMessage) {
        guard let sessionKey,
              let envelope = secureChannel.seal(
                  message,
                  using: sessionKey,
                  senderRole: WristBridgeWireMessage.clientRole
              )
        else { return }
        sendPlain(envelope)
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
        guard let sessionKey else { return nil }
        return secureChannel.open(
            envelope,
            using: sessionKey,
            senderRole: WristBridgeWireMessage.serverRole
        )
    }

    private func fail(_ detail: String) {
        let failedRoute = attemptedDirectRoute
        resetConnection(sendVoiceCancel: false)
        browser?.cancel()
        browser = nil
        if failedRoute == .lan,
           privateNetworkFallbackEndpoint != nil {
            state = .searching
            macName = "正在连接 Tailscale 上的 Mac"
            startPrivateNetworkFallback(reason: "lan_connection_failed")
            return
        }
        state = .unavailable(detail)
        macName = "未找到可用的 Mac"
        scheduleReconnect()
    }

    private func applyDirectBridgeConfiguration(
        _ message: WristBridgeWireMessage,
        allowMissing: Bool
    ) -> Bool {
        if let encoded = message.directBridgeConfiguration {
            guard message.directBridgeConfigurationCleared != true,
                  let configuration = try? WristDirectBridgeConfiguration.decodeBase64(encoded),
                  let publicKey = Data(base64Encoded: configuration.serverIdentityPublicKey),
                  Self.fingerprint(for: publicKey) == verifiedServerIdentityFingerprint
            else { return false }
            directBridgeConfiguration = configuration
            directBridgeConfigurationCleared = false
            return true
        }
        guard message.directBridgeConfigurationCleared == true || allowMissing else {
            return false
        }
        directBridgeConfiguration = nil
        directBridgeConfigurationCleared = true
        return true
    }

    private func applyInternetRelayProvisioning(
        _ directive: WristBridgeWireMessage.InternetRelayProvisioningDirective
    ) -> Bool {
        switch directive {
        case .clear:
            // Persist the fail-closed decision before touching Keychain. Even
            // if credential deletion fails, a restart cannot load it again.
            let persistedClearMarker = WristInternetRelayClearMarker.setCleared(true)
            internetRelayProvisioningCleared = true
            internetRelayProvisioning = nil
            let deletedProvisioning = WristInternetRelayKeychain.delete(
                account: Self.internetRelayKeychainAccount,
                service: Self.internetRelayKeychainService
            )
            return persistedClearMarker && deletedProvisioning
        case let .install(encoded):
            guard WristInternetRelayConfiguration.isEnabledForCurrentBuild,
                  let provisioning = WristInternetRelayDeviceProvisioning.decodeBase64(encoded),
                  WristInternetRelayKeychain.save(
                      provisioning,
                      account: Self.internetRelayKeychainAccount,
                      service: Self.internetRelayKeychainService
                  )
            else {
                _ = WristInternetRelayClearMarker.setCleared(true)
                internetRelayProvisioningCleared = true
                internetRelayProvisioning = nil
                _ = WristInternetRelayKeychain.delete(
                    account: Self.internetRelayKeychainAccount,
                    service: Self.internetRelayKeychainService
                )
                return false
            }
            guard WristInternetRelayClearMarker.setCleared(false) else {
                _ = WristInternetRelayClearMarker.setCleared(true)
                internetRelayProvisioningCleared = true
                internetRelayProvisioning = nil
                _ = WristInternetRelayKeychain.delete(
                    account: Self.internetRelayKeychainAccount,
                    service: Self.internetRelayKeychainService
                )
                return false
            }
            internetRelayProvisioningCleared = false
            internetRelayProvisioning = provisioning
            return true
        }
    }

    private func scheduleReconnect() {
        guard isSceneActive else { return }
        reconnectTask?.cancel()
        let attempt = reconnectAttempt
        reconnectAttempt = min(reconnectAttempt + 1, 5)
        let delay = Self.reconnectDelaySeconds(attempt: attempt)
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self,
                  !Task.isCancelled,
                  isSceneActive,
                  connection == nil,
                  candidateConnections.isEmpty
            else { return }
            browser?.cancel()
            browser = nil
            state = .searching
            macName = "正在查找 Mac"
            startBrowser()
        }
    }

    private func resetConnection(sendVoiceCancel: Bool) {
        for receipt in phoneButtonReceiptLedger.disconnect() {
            completePhoneButtonReceipt(receipt)
        }
        privateNetworkFallbackTask?.cancel()
        privateNetworkFallbackTask = nil
        connectionWatchdogTasks.values.forEach { $0.cancel() }
        connectionWatchdogTasks.removeAll()
        cancelPendingLivenessProbe()
        if sendVoiceCancel,
           let sessionID = activeVoiceSessionID ?? pendingVoice?.sessionID,
           let revision = activeVoiceProfileRevision ?? pendingVoice?.profileRevision,
           let cancel = Self.voiceMessage(
               type: "voiceCancel",
               sessionID: sessionID,
               profileRevision: revision,
               intent: pendingVoice?.intent ?? activeVoiceIntent,
               codexTaskIdentity: pendingVoice?.codexTaskIdentity
                    ?? activeVoiceCodexTaskIdentity,
               codexConversationTarget: pendingVoice?.codexConversationTarget
                    ?? activeVoiceCodexConversationTarget
           ) {
            sendSecure(cancel)
        }
        failPendingAudioDeliveries()
        connectionGeneration &+= 1
        cancelVoiceContinuation()
        let candidates = Array(candidateConnections.values)
        candidateConnections.removeAll()
        candidates.forEach { $0.cancel() }
        connection?.cancel()
        connection = nil
        attemptedDirectRoute = nil
        activeDirectRoute = nil
        receiveBuffer.removeAll(keepingCapacity: true)
        ephemeralPrivateKey = nil
        clientEphemeralPublicKey = nil
        serverEphemeralPublicKey = nil
        serverIdentityPublicKey = nil
        sessionKey = nil
        secureChannel.reset()
        pairingCode = nil
        didReceiveServerKey = false
        didSendClientAuthentication = false
        verifiedServerIdentityFingerprint = nil
        pendingServerIdentityFingerprint = nil
        pendingServerIdentityLocallyApproved = false
        supportsVoiceSessions = false
        supportsCodexTasks = false
        supportsVoiceOutcomes = false
        supportsCodexReplyReceipts = false
        supportsCodexConversations = false
        supportsWatchActionProfiles = false
        supportsPhoneButtonTriggers = false
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
        activeVoiceCodexConversationTarget = nil
        awaitingVoiceOutcomes.removeAll()
        failPendingCodexReplies(detail: "Mac 连接已中断，草稿已保留")
        failPendingCodexConversationRequests(detail: "Mac 连接已中断，草稿已保留")
        codexConversationCatalog = nil
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
        case reject
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
            return storeNewKey()
        case .reject:
            return nil
        }
    }

    static func storageAction(
        copyStatus: OSStatus,
        hasStoredData: Bool,
        hasValidKey: Bool
    ) -> StorageAction {
        if copyStatus == errSecSuccess {
            return hasStoredData && hasValidKey ? .useStored : .reject
        }
        if copyStatus == errSecItemNotFound { return .create }
        return .reject
    }

    static func reset() -> P256.Signing.PrivateKey? {
        let key = P256.Signing.PrivateKey()
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: key.rawRepresentation] as CFDictionary
        )
        if updateStatus == errSecSuccess { return key }
        guard updateStatus == errSecItemNotFound else { return nil }
        return storeNewKey(key)
    }

    private static func storeNewKey(
        _ key: P256.Signing.PrivateKey = P256.Signing.PrivateKey() // gitleaks:allow
    ) -> P256.Signing.PrivateKey? {
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
