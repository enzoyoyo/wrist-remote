import CryptoKit
import Foundation
@preconcurrency import WatchConnectivity
import WatchKit
import UserNotifications

private struct WatchInternetRelayRevocationMarker: Codable, Equatable {
    let isCleared: Bool
}

private enum WatchInternetRelayClearMarker {
    struct PersistenceResult {
        let defaultsSucceeded: Bool
        let keychainSucceeded: Bool

        var fullySucceeded: Bool {
            defaultsSucceeded && keychainSucceeded
        }
    }

    private static let defaultsKey = "internet-relay-explicitly-cleared-v1"
    private static let keychainAccount = "Wrist Remote relay revocation marker"
    private static var keychainService: String {
        "\(Bundle.main.bundleIdentifier ?? "dev.wristremote.watch").internet-relay-revocation"
    }

    static func isSet(defaults: UserDefaults = .standard) -> Bool {
        if defaults.bool(forKey: defaultsKey) { return true }
        let result = WristInternetRelayKeychain.loadResult(
            WatchInternetRelayRevocationMarker.self,
            account: keychainAccount,
            service: keychainService
        )
        return WristInternetRelayKeychain.blocksCredentialRecovery(
            for: result,
            isRevoked: { $0.isCleared }
        )
    }

    @discardableResult
    static func setCleared(
        _ cleared: Bool,
        defaults: UserDefaults = .standard
    ) -> PersistenceResult {
        if cleared {
            defaults.set(true, forKey: defaultsKey)
        } else {
            defaults.removeObject(forKey: defaultsKey)
        }
        let defaultsSucceeded = defaults.synchronize()
        let keychainSucceeded: Bool
        if cleared {
            keychainSucceeded = WristInternetRelayKeychain.save(
                WatchInternetRelayRevocationMarker(isCleared: true),
                account: keychainAccount,
                service: keychainService
            )
        } else {
            keychainSucceeded = WristInternetRelayKeychain.delete(
                account: keychainAccount,
                service: keychainService
            )
        }
        return PersistenceResult(
            defaultsSucceeded: defaultsSucceeded,
            keychainSucceeded: keychainSucceeded
        )
    }
}

struct WatchCodexConversationDraft: Codable, Equatable, Sendable {
    let text: String
    let draftID: UUID
    let target: WatchCodexConversationTarget
    let submissionID: UUID
    let expiresAtEpochMilliseconds: Int64

    init?(
        text: String,
        draftID: UUID,
        target: WatchCodexConversationTarget,
        submissionID: UUID,
        expiresAtEpochMilliseconds: Int64
    ) {
        guard WatchCodexConversationWireValidation.isValidTranscript(text),
              let lease = WatchCodexDraftLease(
                  draftID: draftID,
                  target: target,
                  expiresAtEpochMilliseconds: expiresAtEpochMilliseconds
              )
        else { return nil }
        self.text = text
        self.draftID = lease.draftID
        self.target = lease.target
        self.submissionID = submissionID
        self.expiresAtEpochMilliseconds = lease.expiresAtEpochMilliseconds
    }

    func isExpired(atEpochMilliseconds now: Int64) -> Bool {
        now >= expiresAtEpochMilliseconds
            || target.isExpired(atEpochMilliseconds: now)
    }

    private enum CodingKeys: String, CodingKey {
        case text
        case draftID
        case target
        case submissionID
        case expiresAtEpochMilliseconds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let value = Self(
            text: try container.decode(String.self, forKey: .text),
            draftID: try container.decode(UUID.self, forKey: .draftID),
            target: try container.decode(
                WatchCodexConversationTarget.self,
                forKey: .target
            ),
            submissionID: try container.decode(UUID.self, forKey: .submissionID),
            expiresAtEpochMilliseconds: try container.decode(
                Int64.self,
                forKey: .expiresAtEpochMilliseconds
            )
        ) else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid protected Codex conversation draft"
                )
            )
        }
        self = value
    }
}

enum WatchRemoteConnectionPath: Equatable {
    case direct
    case local
    case internet
    case offline
}

@MainActor
final class WatchSessionController: NSObject, ObservableObject {
    private static var presentationFixtureRequested: Bool {
        #if DEBUG && targetEnvironment(simulator)
        ProcessInfo.processInfo.arguments.contains("--presentation-fixture")
        #else
        false
        #endif
    }

    #if DEBUG && targetEnvironment(simulator)
    /// Presentation only: no activation, microphone, keychain or real requests.
    /// The route stays offline; this fixture must never simulate acceptance.
    private func loadPresentationFixture() {
        let epoch = UUID()
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        let title = "检查长标题下的会话选择、中文阅读与返回体验"
        let targets = [
            WatchCodexConversationTarget(
                leaseID: UUID(), kind: .existing, serverEpoch: epoch,
                catalogRevision: 1, entryRevision: 1, threadID: "sample-task",
                displayTitle: title, workspaceID: "sample-workspace",
                workspaceLabel: "示例项目", expiresAtEpochMilliseconds: now + 600_000
            ),
            WatchCodexConversationTarget(
                leaseID: UUID(), kind: .newConversation, serverEpoch: epoch,
                catalogRevision: 1, entryRevision: 1, threadID: nil,
                displayTitle: "在项目中新建", workspaceID: "sample-workspace",
                workspaceLabel: "示例项目", expiresAtEpochMilliseconds: now + 600_000
            ),
            WatchCodexConversationTarget(
                leaseID: UUID(), kind: .newConversation, serverEpoch: epoch,
                catalogRevision: 1, entryRevision: 1, threadID: nil,
                displayTitle: "完全空白任务",
                workspaceID: WatchCodexConversationTarget.standaloneWorkspaceID,
                workspaceLabel: "独立任务", expiresAtEpochMilliseconds: now + 600_000
            ),
        ].compactMap { $0 }
        let entries = targets.compactMap { target in
            WatchCodexConversationEntry(
                threadID: target.threadID, title: target.displayTitle,
                workspaceLabel: target.workspaceLabel, state: .idle,
                updatedAtEpochMilliseconds: now, canAcceptInput: true,
                entryRevision: 1, target: target
            )
        }
        codexConversationCatalog = WatchCodexConversationCatalog(
            serverEpoch: epoch, revision: 1, entries: entries,
            hasMore: false, refreshedAtEpochMilliseconds: now
        )
        codexTaskSnapshot = WatchCodexTaskSnapshot(
            threadID: "sample-task", turnID: "sample-turn",
            workspaceLabel: "示例项目", title: title,
            summary: "这是模拟器布局样例，用于检查较长中文结果的阅读体验。不会连接或控制真实任务。",
            state: .completed, revision: 1, updatedAtEpochMilliseconds: now
        )
        selectedCodexTarget = targets.first
        codexVoiceStatusText = ProcessInfo.processInfo.arguments.contains("--voice-failure-fixture")
            ? "Codex 转写未成功，本次未发送；请稍后重新录音。"
            : "布局预览 · 不连接设备"
    }
    #endif
    private static let favoritesDefaultsKey = "WristRemote.favoriteCommands"
    private static let notifiedCodexTurnsKey = "WristRemote.notifiedCodexTurns"
    private static let persistedCodexDraftKey = "WristRemote.persistedCodexDraft"
    private static let maxNotifiedCodexTurns = 32
    private static let internetVoiceStartReplyTimeoutMilliseconds =
        WristInternetVoiceStartPolicy.replyTimeoutMilliseconds

    @Published private(set) var activationState: WCSessionActivationState = .notActivated
    @Published private(set) var phoneIsReachable = false
    @Published private(set) var remoteStatus: WatchRemoteStatus
    @Published private(set) var favorites: [WatchRemoteCommand]
    @Published private(set) var isVoiceActive = false
    @Published private(set) var isVoiceStartPending = false
    @Published private(set) var hasFreshStatus = false
    @Published private(set) var issueText: String?
    @Published private(set) var codexTaskSnapshot: WatchCodexTaskSnapshot?
    @Published private(set) var codexReplyDraft: String?
    @Published private(set) var codexConversationCatalog: WatchCodexConversationCatalog?
    @Published private(set) var selectedCodexTarget: WatchCodexConversationTarget?
    @Published private(set) var pendingCodexConversationTarget: WatchCodexConversationTarget?
    @Published private(set) var isCodexConversationCatalogLoading = false
    @Published private(set) var isCodexDraftStoreReady = false
    @Published private(set) var codexConversationDraft: WatchCodexConversationDraft?
    @Published private(set) var codexVoiceStatusText: String?
    @Published private(set) var isCodexReplySubmitting = false
    @Published private(set) var connectionPath: WatchRemoteConnectionPath = .offline
    @Published private(set) var directBridgeEnabled = true
    @Published private(set) var directButtonOutcome: String?

    private let directBridge = WristDirectBridgeClient()
    private var directConfiguration: WristDirectBridgeConfiguration?
    private var directGestureResolver = WristInternetButtonGestureResolver()
    private var directHeldCommands: [WatchRemoteCommand: Int] = [:]
    private var directSingleClickTasks: [WatchRemoteCommand: Task<Void, Never>] = [:]
    private var directLongPressTasks: [WatchRemoteCommand: Task<Void, Never>] = [:]
    private var directSendTasks: [UUID: Task<Void, Never>] = [:]
    private var directGestureGeneration: UInt64 = 0
    private var companionGestureBarrierUntil = Date.distantPast
    private static let directConfigurationKey = "WristRemote.directBridge.configuration.v1"
    private static let directDisabledKey = "WristRemote.directBridge.userDisabled.v1"
    private static let directRevokedIdentityKey = "WristRemote.directBridge.revokedIdentity.v1"

    private let session: WCSession
    private let audioCapture: WatchAudioCapture
    private let audioMailbox = WatchRemoteAudioMailbox()
    private var heldCommandRevisions: [WatchRemoteCommand: Int] = [:]
    private var heldCommandUsesInternet: [WatchRemoteCommand: Bool] = [:]
    private var voiceGestureIsHeld = false
    private var voiceRequestID: UInt64 = 0
    private var voiceStartTimeoutTask: Task<Void, Never>?
    private var voiceDurationLimitTask: Task<Void, Never>?
    private var voiceStartHandshake = WatchRemoteVoiceStartHandshake()
    private var statusRequestTimeoutTask: Task<Void, Never>?
    private var statusHandshake = WatchRemoteStatusHandshake()
    private var voiceStreamID: UUID?
    private var voiceProfileRevision: Int?
    private var nextAudioSequence: UInt64 = 0
    private var audioAckTracker = WatchRemoteAudioAckTracker()
    private var isVoiceFinalizing = false
    private var voiceFinalAckTimeoutTask: Task<Void, Never>?
    private var voiceOutcomeTimeoutTask: Task<Void, Never>?
    private var voiceIntent: WatchVoiceIntent = .foregroundDictation
    private var voiceCodexTaskIdentity: WatchCodexTaskIdentity?
    private var voiceCodexConversationTarget: WatchCodexConversationTarget?
    private var awaitingVoiceOutcomeSessionID: String? {
        didSet {
            if awaitingVoiceOutcomeSessionID == nil {
                awaitingVoiceOutcomeUsesInternet = false
                if oldValue != nil {
                    Task { @MainActor [weak self] in
                        self?.reconcileDeferredCodexCatalog()
                    }
                }
            }
        }
    }
    private var awaitingVoiceOutcomeUsesInternet = false
    private var codexCatalogMaintenance = WatchCodexCatalogMaintenance()
    private var codexCatalogStartupGate = WatchCodexCatalogStartupGate()
    private var awaitingVoiceOutcomeIdentity: WatchCodexTaskIdentity?
    private var awaitingVoiceOutcomeConversationTarget: WatchCodexConversationTarget?
    private var codexDraftIdentity: WatchCodexTaskIdentity?
    private var codexDraftSubmissionID: UUID?
    private var codexReplySubmitTask: Task<Void, Never>?
    private var codexReplySubmitID: UInt64 = 0
    private var codexConversationCatalogRequestID: UUID?
    private var codexConversationCatalogRequestTimeoutTask: Task<Void, Never>?
    private var codexConversationTargetRequestID: UUID?
    private var codexConversationTargetTimeoutTask: Task<Void, Never>?
    private var codexConversationSelectionOperations:
        WatchCodexConversationSelectionOperationBook?
    private var codexConversationLeaseRefreshTask: Task<Void, Never>?
    private var hasStarted = false
    private var activationRequestInFlight = false
    private var isSceneActive = false
    private var statusRetryTask: Task<Void, Never>?
    private var healthyStatusRefreshTask: Task<Void, Never>?
    private var statusRetryCursor = WatchStatusRetryCursor()
    private var lastAppliedCodexTaskRevision = -1
    private var internetProvisioning: WristInternetRelayDeviceProvisioning?
    private var internetClient: WristInternetRelayHTTPClient?
    private var internetRemoteStatus: WatchRemoteStatus?
    private var internetButtonTriggers: [WatchRemoteCommand: Set<WristInternetRelayButtonTrigger>] = [:]
    private var internetStatusReceivedAt: Date?
    private var internetStatusTask: Task<Void, Never>?
    private var internetStatusTaskGeneration: UInt64 = 0
    private var internetProvisioningGeneration: UInt64 = 0
    private var voiceUsesInternet = false
    private var internetAudioBatch: [Data] = []
    private var internetAudioBatchStartSequence: UInt64?
    private var internetAudioFlushTask: Task<Void, Never>?
    private var internetAudioFinalFlushRequested = false
    private var internetVoiceStartTask: Task<Void, Never>?
    private var internetVoiceStartTaskStreamID: UUID?
    private var internetButtonQueue: [PendingInternetButtonEvent] = []
    private var internetButtonTask: Task<Void, Never>?
    private var internetButtonGestureResolver = WristInternetButtonGestureResolver()
    private var internetSingleClickCommitTasks: [WatchRemoteCommand: Task<Void, Never>] = [:]
    private var internetLongPressCommitTasks: [WatchRemoteCommand: Task<Void, Never>] = [:]
    private var codexReplyUsesInternet = false

    private var hasInternetVoiceTransportWork: Bool {
        voiceUsesInternet && (isVoiceStartPending || isVoiceActive || isVoiceFinalizing)
    }

    private struct PendingInternetButtonEvent {
        let command: WatchRemoteCommand
        let trigger: WristInternetRelayButtonTrigger
        let profileRevision: Int
        let committedAt: Date
    }

    private struct PersistedCodexTaskDraft: Codable {
        let text: String
        let identity: WatchCodexTaskIdentity
        let submissionID: UUID
    }

    private struct PersistedCodexDrafts: Codable {
        var task: PersistedCodexTaskDraft?
        var conversation: WatchCodexConversationDraft?
    }

    init(
        session: WCSession = .default,
        audioCapture: WatchAudioCapture = WatchAudioCapture(),
        initialStatus: WatchRemoteStatus = .unavailable,
        initialFavorites: [WatchRemoteCommand]? = nil
    ) {
        self.session = session
        self.audioCapture = audioCapture
        remoteStatus = initialStatus
        #if DEBUG && targetEnvironment(simulator)
        if Self.presentationFixtureRequested {
            favorites = WatchRemoteCommand.defaultFavorites
            super.init()
            loadPresentationFixture()
            return
        }
        #endif
        let storedProvisioning: WristInternetRelayDeviceProvisioning?
        let relayWasExplicitlyCleared = WatchInternetRelayClearMarker.isSet()
        if WristInternetRelayConfiguration.isEnabledForCurrentBuild,
           !relayWasExplicitlyCleared {
            storedProvisioning = WristInternetRelayKeychain.load(
                WristInternetRelayDeviceProvisioning.self,
                account: Self.internetRelayKeychainAccount,
                service: Self.internetRelayKeychainService
            )
        } else {
            _ = WatchInternetRelayClearMarker.setCleared(true)
            _ = WristInternetRelayKeychain.delete(
                account: Self.internetRelayKeychainAccount,
                service: Self.internetRelayKeychainService
            )
            storedProvisioning = nil
        }
        internetProvisioning = storedProvisioning
        internetClient = storedProvisioning.map {
            WristInternetRelayHTTPClient(provisioning: $0)
        }
        favorites = initialFavorites
            ?? Self.persistedFavorites()
            ?? WatchRemoteCommand.defaultFavorites
        super.init()
        restoreDirectBridgeConfiguration()
        directBridge.onChange = { [weak self] in
            guard let self else { return }
            objectWillChange.send()
            if !directBridge.isReady { cancelDirectButtonGestures() }
            reconcilePreferredConnectionPathIfIdle()
        }
        restoreCodexConversationSelectionOperations()
        restoreCodexDraft()
    }

    var isReady: Bool {
        directBridge.isReady || localIsReady || internetIsReady
    }

    private var localIsReady: Bool {
        activationState == .activated
            && phoneIsReachable
            && hasFreshStatus
            && remoteStatus.isMacConnected
            && remoteStatus.isActionProfileReady
            && remoteStatus.profileRevision != nil
    }

    private var internetIsReady: Bool {
        guard internetProvisioning != nil,
              let status = internetRemoteStatus,
              let receivedAt = internetStatusReceivedAt,
              Date().timeIntervalSince(receivedAt) < 35
        else { return false }
        return status.isMacConnected
            && status.isActionProfileReady
            && status.profileRevision != nil
    }

    private var effectiveRemoteStatus: WatchRemoteStatus {
        if voiceUsesInternet,
           (isVoiceStartPending || isVoiceActive || isVoiceFinalizing),
           let internetRemoteStatus {
            return internetRemoteStatus
        }
        if localIsReady { return remoteStatus }
        if internetIsReady, let internetRemoteStatus { return internetRemoteStatus }
        return remoteStatus
    }

    private var canSendVoiceStopForCurrentPath: Bool {
        if voiceUsesInternet { return internetClient != nil }
        return session.activationState == .activated && session.isReachable
    }

    var canStartVoice: Bool {
        (localIsReady || internetIsReady)
            && effectiveRemoteStatus.voiceOwner == .none
            && !isVoiceStartPending
            && !isVoiceActive
            && !isVoiceFinalizing
            && awaitingVoiceOutcomeSessionID == nil
    }

    var isVoiceControlEnabled: Bool {
        canStartVoice
            || voiceGestureIsHeld
            || isVoiceStartPending
            || isVoiceActive
            || isVoiceFinalizing
    }

    var canStartCodexVoice: Bool {
        guard isCodexDraftStoreReady,
              codexReplyDraft == nil,
              codexTaskSnapshot?.state == .completed,
              WatchCodexTaskIdentity(codexTaskSnapshot) != nil
        else { return false }
        return canStartVoice
    }

    var canStartCodexConversationVoice: Bool {
        guard isCodexDraftStoreReady,
              codexConversationDraft == nil,
              let target = selectedCodexTarget,
              target.kind == .existing,
              let entry = codexConversationCatalog?.entries.first(where: {
                  $0.target == target
              }),
              entry.canAcceptInput,
              !target.isExpired(atEpochMilliseconds: Self.nowEpochMilliseconds),
              privateCodexConversationRouteIsReady,
              pendingCodexConversationTarget == nil
        else { return false }
        return canStartVoice
    }

    var isCodexVoiceInteractionInProgress: Bool {
        ((voiceIntent == .codexTask || voiceIntent == .codexConversation)
            && (voiceGestureIsHeld || isVoiceStartPending || isVoiceActive || isVoiceFinalizing))
            || awaitingVoiceOutcomeIdentity != nil
            || awaitingVoiceOutcomeConversationTarget != nil
    }

    private var isCodexVoiceCaptureInProgress: Bool {
        (voiceIntent == .codexTask || voiceIntent == .codexConversation)
            && (voiceGestureIsHeld || isVoiceStartPending || isVoiceActive || isVoiceFinalizing)
    }

    var isCodexVoiceRecording: Bool {
        voiceIntent == .codexTask && isVoiceActive
    }

    var isCodexVoicePreparing: Bool {
        voiceIntent == .codexTask
            && voiceGestureIsHeld
            && !isVoiceActive
            && !isVoiceFinalizing
    }

    var isCodexConversationVoiceRecording: Bool {
        voiceIntent == .codexConversation && isVoiceActive
    }

    var isCodexConversationVoicePreparing: Bool {
        voiceIntent == .codexConversation
            && voiceGestureIsHeld
            && !isVoiceActive
            && !isVoiceFinalizing
    }

    var canChangeCodexDestination: Bool {
        !isCodexVoiceInteractionInProgress
            && !isCodexReplySubmitting
            && codexConversationDraft == nil
    }

    private var privateCodexConversationRouteIsReady: Bool {
        localIsReady
            && session.activationState == .activated
            && session.isReachable
    }

    var isCodexConversationRouteReady: Bool {
        privateCodexConversationRouteIsReady && isCodexDraftStoreReady
    }

    var codexConversationRouteStatusText: String {
        if !isCodexDraftStoreReady { return "正在恢复受保护草稿" }
        if activationState != .activated { return "正在连接 iPhone" }
        if !phoneIsReachable { return "iPhone 未连接" }
        if !hasFreshStatus { return "正在同步私有连接" }
        if !remoteStatus.isMacConnected { return "Mac 私有通道未连接" }
        if !remoteStatus.isActionProfileReady { return "Mac Bridge 未就绪" }
        return "Codex 私有通道暂不可用"
    }

    var codexConversationRouteStatusDetail: String {
        if !isCodexDraftStoreReady {
            return "请解锁 Apple Watch 后重新打开 App；恢复完成前不会录音或发送。"
        }
        if let issueText, !issueText.isEmpty { return issueText }
        return "Codex 会话只经配对 iPhone 与 Mac 的私有直连发送，不使用公网 Relay。"
    }

    private func acceptsVoiceTarget(
        intent: WatchVoiceIntent,
        codexTaskIdentity: WatchCodexTaskIdentity?,
        codexConversationTarget: WatchCodexConversationTarget?
    ) -> Bool {
        switch intent {
        case .foregroundDictation:
            return codexTaskIdentity == nil && codexConversationTarget == nil
        case .codexTask:
            guard let codexTaskIdentity else { return false }
            return codexTaskIdentity == WatchCodexTaskIdentity(codexTaskSnapshot)
                && codexConversationTarget == nil
        case .codexConversation:
            guard codexTaskIdentity == nil,
                  let codexConversationTarget,
                  codexConversationTarget.kind == .existing,
                  codexConversationTarget == selectedCodexTarget,
                  privateCodexConversationRouteIsReady,
                  !codexConversationTarget.isExpired(
                      atEpochMilliseconds: Self.nowEpochMilliseconds
                  )
            else { return false }
            return codexConversationCatalog?.entries.contains(where: {
                $0.target == codexConversationTarget && $0.canAcceptInput
            }) == true
        }
    }

    var statusText: String {
        if voiceUsesInternet,
           (isVoiceStartPending || isVoiceActive || isVoiceFinalizing),
           internetRemoteStatus != nil {
            return "公网 Relay · \(effectiveRemoteStatus.macName)"
        }
        if directBridge.isReady { return "直连 Mac · \(directBridge.snapshot?.macName ?? "Mac")" }
        if localIsReady { return "经 iPhone · \(remoteStatus.macName)" }
        if internetIsReady { return "公网 Relay · \(effectiveRemoteStatus.macName)" }
        if internetStatusTask != nil { return "正在连接公网 Relay" }
        if activationState != .activated { return "正在连接 iPhone" }
        if !phoneIsReachable, internetProvisioning == nil { return "iPhone 未连接" }
        if !hasFreshStatus { return "正在同步实时状态" }
        if !remoteStatus.isMacConnected { return "Mac 未连接" }
        if !remoteStatus.isActionProfileReady { return "独立映射未就绪" }
        return "暂时离线"
    }

    var statusDetail: String {
        if directBridge.isReady, !localIsReady, !internetIsReady {
            return directButtonOutcome ?? "按键已直连；语音仍需 iPhone 私有链路"
        }
        if let issueText { return issueText }
        if let detail = effectiveRemoteStatus.detail, !detail.isEmpty {
            return detail
        }
        return isReady ? "按住语音键说话" : "请保持 Mac 开机并连接网络"
    }

    func title(for command: WatchRemoteCommand) -> String? {
        if directBridge.isReady, let snapshot = directBridge.snapshot,
           let binding = snapshot.profile.bindings[command.wireButtonID]?["singleClick"] {
            switch binding.action {
            case .disabled: return "未设置"
            case .escape: return "Escape"
            case .returnKey: return "确认"
            case .commandReturn: return "⌘Return"
            case .shiftReturn: return "⇧Return"
            case .commandCopy: return "复制"
            case .commandPaste: return "粘贴"
            case .commandQuit: return "退出 App"
            case .arrowUp: return "上"
            case .arrowDown: return "下"
            case .arrowLeft: return "左"
            case .arrowRight: return "右"
            case .deleteBackward: return "退格"
            case .showDesktop: return "桌面"
            case .contextMenu: return "菜单"
            case .appSwitcher: return "切换 App"
            case .volumeUp: return "音量加"
            case .volumeDown: return "音量减"
            case .volumeMute: return "静音"
            case .playPause: return "播放/暂停"
            case .previousCommandLeft: return "上一个"
            case .nextCommandRight: return "下一个"
            case .openCustomApplication:
                return binding.applicationProfileID.flatMap { snapshot.applicationTitles[$0] } ?? "自定义 App"
            case .customShortcut:
                guard let shortcut = binding.shortcut else { return "快捷键" }
                let flags = shortcut.modifierFlagsRawValue
                let modifiers = [(UInt(1 << 18), "⌃"), (UInt(1 << 19), "⌥"),
                                 (UInt(1 << 17), "⇧"), (UInt(1 << 20), "⌘")]
                    .filter { flags & $0.0 != 0 }.map { $0.1 }.joined()
                return modifiers + shortcut.keyLabel
            }
        }
        return effectiveRemoteStatus.buttonTitles[command]
    }

    func start() {
        guard !Self.presentationFixtureRequested else { return }
        session.delegate = self
        let notificationCenter = UNUserNotificationCenter.current()
        notificationCenter.delegate = self
        if !hasStarted {
            hasStarted = true
            invalidateLiveStatus()
            applyApplicationContext(session.receivedApplicationContext)
            Task {
                _ = try? await notificationCenter.requestAuthorization(
                    options: [.alert, .sound]
                )
            }
        }

        refreshReachability()
        let shouldActivate = WatchConnectivityRecoveryPolicy.shouldRequestActivation(
            isActivated: session.activationState == .activated,
            isInactive: session.activationState == .inactive,
            requestInFlight: activationRequestInFlight
        )
        if shouldActivate {
            activationRequestInFlight = true
            session.activate()
        } else if isSceneActive, session.activationState == .activated {
            requestStatus()
        }
    }

    func sceneDidBecomeActive() {
        guard !Self.presentationFixtureRequested else { return }
        isSceneActive = true
        directBridge.setSceneActive(true)
        reconcileDeferredCodexCatalog()
        if !isCodexDraftStoreReady { restoreCodexDraft() }
        cancelHealthyStatusRefresh()
        cancelStatusRetry(resetAttempt: true)
        if WristInternetRelayConfiguration.isEnabledForCurrentBuild,
           !WatchInternetRelayClearMarker.isSet(),
           internetProvisioning == nil,
           let recoveredProvisioning = WristInternetRelayKeychain.load(
               WristInternetRelayDeviceProvisioning.self,
               account: Self.internetRelayKeychainAccount,
               service: Self.internetRelayKeychainService
           ), recoveredProvisioning.isValid {
            applyInternetProvisioning(recoveredProvisioning)
        }
        start()
        requestStatus()
        requestCodexConversationCatalog()
        scheduleCodexConversationLeaseRefresh()
    }

    func sceneDidBecomeInactive() {
        guard !Self.presentationFixtureRequested else { return }
        isSceneActive = false
        cancelDirectButtonGestures()
        directBridge.setSceneActive(false)
        codexCatalogStartupGate.cancel()
        cancelHealthyStatusRefresh()
        cancelStatusRetry(resetAttempt: false)
        statusRequestTimeoutTask?.cancel()
        statusRequestTimeoutTask = nil
        codexConversationLeaseRefreshTask?.cancel()
        codexConversationLeaseRefreshTask = nil
        invalidateLiveStatus()
        if isCodexVoiceCaptureInProgress {
            cancelCodexVoiceGesture()
        }
        stopAllInteractions(sendReleaseMessages: session.isReachable || internetClient != nil)
    }

    func requestStatus(preservingCurrentStatus: Bool = false) {
        guard !Self.presentationFixtureRequested else { return }
        cancelHealthyStatusRefresh()
        guard session.activationState == .activated, session.isReachable else {
            invalidateLiveStatus()
            invalidateCodexConversationRouteState(detail: "会话控制需要先连接 iPhone 私有链路")
            requestInternetStatus()
            scheduleStatusRetryIfNeeded()
            return
        }
        guard statusHandshake.pendingRequestID == nil else { return }

        let requestID = statusHandshake.begin()
        if !preservingCurrentStatus { hasFreshStatus = false }
        statusRequestTimeoutTask?.cancel()
        statusRequestTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard let self,
                  !Task.isCancelled,
                  statusHandshake.pendingRequestID == requestID
            else { return }
            invalidateLiveStatus()
            issueText = "iPhone 未返回实时连接状态"
            invalidateCodexConversationRouteState(detail: "iPhone 未返回 Codex 私有连接状态")
            requestInternetStatus()
            scheduleStatusRetryIfNeeded()
        }

        session.sendMessage(
            WatchRemoteProtocol.requestStatusMessage(requestID: requestID),
            replyHandler: { [weak self] reply in
                Task { @MainActor in
                    guard let self,
                          let status = self.statusHandshake.acceptReply(reply)
                    else { return }
                    self.statusRequestTimeoutTask?.cancel()
                    self.statusRequestTimeoutTask = nil
                    self.hasFreshStatus = self.statusHandshake.hasFreshStatus
                    self.issueText = nil
                    self.applyFreshStatus(status)
                }
            },
            errorHandler: { [weak self] _ in
                Task { @MainActor in
                    guard let self,
                          self.statusHandshake.pendingRequestID == requestID
                    else { return }
                    self.statusRequestTimeoutTask?.cancel()
                    self.statusRequestTimeoutTask = nil
                    self.handleCommunicationFailure()
                    self.requestInternetStatus()
                }
            }
        )
    }

    var directBridgeStatusText: String {
        if !directBridgeEnabled { return "直连已关闭" }
        guard directConfiguration != nil else { return "等待 iPhone 同步 Mac" }
        switch directBridge.state {
        case .idle, .connecting: return "正在直连 Mac"
        case let .awaitingApproval(code): return "在 Mac 确认 \(code)"
        case .waitingForProfile: return "Mac 已认证，等待 iPhone 同步按键映射"
        case .ready: return "直连 Mac · \(directBridge.snapshot?.macName ?? "Mac")"
        case .suspended: return "回到前台后连接"
        case let .failed(detail): return detail
        }
    }

    var remoteConnectionPathText: String {
        if directBridge.isReady { return "直连 Mac" }
        if localIsReady { return "经 iPhone" }
        if internetIsReady { return "公网 Relay" }
        return "离线"
    }

    var remoteVoiceAvailabilityText: String {
        (localIsReady || internetIsReady)
            ? "语音经现有 iPhone 私有链路发送"
            : "当前仅支持按键直连；语音需要 iPhone 私有链路"
    }

    func setDirectBridgeEnabled(_ enabled: Bool) {
        directBridgeEnabled = enabled
        UserDefaults.standard.set(!enabled, forKey: Self.directDisabledKey)
        if enabled {
            UserDefaults.standard.removeObject(forKey: Self.directRevokedIdentityKey)
        }
        cancelDirectButtonGestures()
        directBridge.configure(enabled ? directConfiguration : nil)
        if enabled { directBridge.reconnect() }
    }

    func reconnectRemoteControl() {
        if directBridgeEnabled { directBridge.reconnect() }
        requestStatus()
    }

    private func restoreDirectBridgeConfiguration() {
        let defaults = UserDefaults.standard
        if let encoded = defaults.string(forKey: Self.directConfigurationKey) {
            directConfiguration = try? WristDirectBridgeConfiguration.decodeBase64(encoded)
        }
        let revokedIdentity = defaults.string(forKey: Self.directRevokedIdentityKey)
        directBridgeEnabled = !defaults.bool(forKey: Self.directDisabledKey)
            && (revokedIdentity == nil || revokedIdentity != directConfiguration?.serverIdentityPublicKey)
        directBridge.configure(directBridgeEnabled ? directConfiguration : nil)
    }

    private func applyDirectBridgeConfiguration(_ context: [String: Any]) {
        let defaults = UserDefaults.standard
        if context["wristDirectBridgeConfigurationCleared"] as? Bool == true {
            // A stale application context cannot silently revive a revoked
            // Mac pin. Only the visible Watch switch clears this tombstone.
            if let key = directConfiguration?.serverIdentityPublicKey {
                defaults.set(key, forKey: Self.directRevokedIdentityKey)
                directBridgeEnabled = false
            }
            cancelDirectButtonGestures()
            directBridge.configure(nil)
            return
        }
        guard let encoded = context["wristDirectBridgeConfiguration"] as? String else { return }
        guard let configuration = try? WristDirectBridgeConfiguration.decodeBase64(encoded) else {
            cancelDirectButtonGestures()
            directBridgeEnabled = false
            directBridge.configure(nil)
            issueText = "Mac 直连配置无效，请重新同步 iPhone"
            return
        }
        let previous = directConfiguration
        directConfiguration = configuration
        defaults.set(encoded, forKey: Self.directConfigurationKey)
        let revokedIdentity = defaults.string(forKey: Self.directRevokedIdentityKey)
        directBridgeEnabled = !defaults.bool(forKey: Self.directDisabledKey)
            && revokedIdentity != configuration.serverIdentityPublicKey
        if previous != configuration { cancelDirectButtonGestures() }
        directBridge.configure(directBridgeEnabled ? configuration : nil)
    }

    private func setDirectButton(_ command: WatchRemoteCommand, isPressed: Bool) {
        if isPressed {
            guard directBridge.isReady, let snapshot = directBridge.snapshot,
                  directHeldCommands[command] == nil else { return }
            let revision = directGestureResolver.pendingRevision(for: command) ?? snapshot.revision
            guard revision == snapshot.revision else {
                cancelDirectButtonGestures()
                return
            }
            let triggers = snapshot.triggers(for: command)
            guard let outcome = directGestureResolver.press(
                command, profileRevision: revision,
                recognizesDoubleClick: triggers.contains(.doubleClick),
                recognizesLongPress: triggers.contains(.longPress)
            ) else { return }
            directButtonOutcome = nil
            directHeldCommands[command] = revision
            connectionPath = .direct
            // This haptic means touch-down, never successful execution.
            WatchHaptics.play(.click)
            if outcome.shouldCancelSingleClick {
                directSingleClickTasks.removeValue(forKey: command)?.cancel()
            }
            if outcome.shouldScheduleLongPress {
                scheduleDirectGestureCommit(command, revision: revision, longPress: true)
            }
        } else {
            guard let revision = directHeldCommands.removeValue(forKey: command) else { return }
            directLongPressTasks.removeValue(forKey: command)?.cancel()
            switch directGestureResolver.release(command, profileRevision: revision) {
            case .some(.none), nil: break
            case .some(.scheduleSingleClick):
                scheduleDirectGestureCommit(command, revision: revision, longPress: false)
            case let .some(.commit(trigger)):
                sendDirectButton(command, trigger: trigger, revision: revision)
            }
            reconcilePreferredConnectionPathIfIdle()
        }
    }

    private func scheduleDirectGestureCommit(
        _ command: WatchRemoteCommand, revision: Int, longPress: Bool
    ) {
        let expectedGeneration = directGestureGeneration
        let task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(longPress
                ? WristInternetButtonGesturePolicy.longPressCommitDelayMilliseconds
                : WristInternetButtonGesturePolicy.doubleClickCommitDelayMilliseconds))
            guard let self, !Task.isCancelled, expectedGeneration == directGestureGeneration else { return }
            if longPress { directLongPressTasks[command] = nil }
            else { directSingleClickTasks[command] = nil }
            let trigger = longPress
                ? directGestureResolver.longPressTimedOut(command, profileRevision: revision)
                : directGestureResolver.singleClickTimedOut(command, profileRevision: revision)
            if let trigger { sendDirectButton(command, trigger: trigger, revision: revision) }
            reconcilePreferredConnectionPathIfIdle()
        }
        if longPress {
            directLongPressTasks.removeValue(forKey: command)?.cancel()
            directLongPressTasks[command] = task
        } else {
            directSingleClickTasks.removeValue(forKey: command)?.cancel()
            directSingleClickTasks[command] = task
        }
    }

    private func sendDirectButton(
        _ command: WatchRemoteCommand, trigger: WristInternetRelayButtonTrigger, revision: Int
    ) {
        guard directBridge.isReady, directSendTasks.count < 6 else {
            directButtonOutcome = "连接未就绪或繁忙，本次未发送"
            return
        }
        let id = UUID()
        let expectedGeneration = directGestureGeneration
        let issued = Self.nowEpochMilliseconds
        directButtonOutcome = "等待 Mac 确认"
        directSendTasks[id] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                directSendTasks[id] = nil
                reconcilePreferredConnectionPathIfIdle()
            }
            do {
                _ = try await directBridge.sendButton(
                    command: command, trigger: trigger, profileRevision: revision,
                    issuedAtEpochMilliseconds: issued
                )
                guard !Task.isCancelled, expectedGeneration == directGestureGeneration else { return }
                directButtonOutcome = "Mac 已执行"
                WatchHaptics.play(.success)
            } catch is CancellationError {
                return
            } catch {
                guard expectedGeneration == directGestureGeneration else { return }
                directButtonOutcome = error.localizedDescription
                WatchHaptics.play(.failure)
            }
        }
    }

    private func cancelDirectButtonGestures() {
        directGestureGeneration &+= 1
        if !directSendTasks.isEmpty {
            directButtonOutcome = "执行结果未确认；不会自动重发"
        }
        directHeldCommands.removeAll()
        directGestureResolver.reset()
        directSingleClickTasks.values.forEach { $0.cancel() }
        directLongPressTasks.values.forEach { $0.cancel() }
        directSendTasks.values.forEach { $0.cancel() }
        directSingleClickTasks.removeAll()
        directLongPressTasks.removeAll()
        directSendTasks.removeAll()
    }

    private func requestInternetStatus() {
        guard WristInternetRelayConfiguration.isEnabledForCurrentBuild,
              isSceneActive,
              !hasInternetVoiceTransportWork,
              internetStatusTask == nil,
              let internetClient
        else { return }
        let generation = internetProvisioningGeneration
        internetStatusTaskGeneration &+= 1
        let taskGeneration = internetStatusTaskGeneration
        internetStatusTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if generation == internetProvisioningGeneration,
                   taskGeneration == internetStatusTaskGeneration {
                    internetStatusTask = nil
                }
            }
            do {
                let operation = WristInternetRelayOperation(kind: .status)
                let result = try await internetClient.send(operation)
                guard !Task.isCancelled,
                      generation == internetProvisioningGeneration,
                      result.accepted,
                      let status = result.status
                else {
                    throw WristInternetRelayHTTPError.invalidResponse
                }
                applyInternetStatus(status)
                issueText = nil
                if !localIsReady { connectionPath = .internet }
                cancelStatusRetry(resetAttempt: true)
                scheduleHealthyStatusRefreshIfNeeded()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled,
                      generation == internetProvisioningGeneration
                else { return }
                internetStatusReceivedAt = nil
                if localIsReady {
                    connectionPath = .local
                } else {
                    connectionPath = .offline
                    issueText = (error as? LocalizedError)?.errorDescription
                        ?? "互联网连接失败"
                    scheduleStatusRetryIfNeeded()
                }
            }
        }
    }

    private func applyInternetStatus(_ status: WristInternetRelayStatus) {
        let previousVoiceOwner = internetRemoteStatus?.voiceOwner
        let titles: [WatchRemoteCommand: String] = Dictionary(
            uniqueKeysWithValues: status.buttonTitles.compactMap { element in
                let (rawCommand, title) = element
                guard let command = WatchRemoteCommand(rawValue: rawCommand),
                      !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { return nil }
                return (command, title)
            }
        )
        internetRemoteStatus = WatchRemoteStatus(
            isMacConnected: true,
            macName: status.macName,
            voiceOwner: status.voiceOwner,
            detail: nil,
            buttonTitles: titles,
            isActionProfileReady: status.profileRevision != nil,
            profileRevision: status.profileRevision
        )
        internetButtonTriggers = Dictionary(uniqueKeysWithValues:
            status.buttonTriggers.compactMap { rawCommand, triggers in
                guard let command = WatchRemoteCommand(rawValue: rawCommand) else {
                    return nil
                }
                return (command, Set(triggers))
            }
        )
        internetStatusReceivedAt = Date()
        if !localIsReady { connectionPath = .internet }
        if let task = status.codexTask {
            applyCodexTask(
                task,
                stateRevision: status.codexTaskStateRevision
            )
        } else {
            clearCodexTask(stateRevision: status.codexTaskStateRevision)
        }
        if let outcome = status.voiceOutcome { applyVoiceOutcome(outcome) }
        if voiceUsesInternet,
           previousVoiceOwner == .watch,
           status.voiceOwner != .watch,
           (isVoiceActive || isVoiceFinalizing) {
            voiceRequestID &+= 1
            voiceGestureIsHeld = false
            if isVoiceFinalizing {
                completeVoiceFinalization(sendStopMessage: false, failureText: nil)
            } else {
                endVoice(sendStopMessage: false)
            }
            issueText = status.voiceOutcome?.detail ?? "Mac 已结束公网语音"
        } else if voiceUsesInternet,
                  status.voiceOwner == .watch,
                  !isVoiceActive,
                  !isVoiceFinalizing,
                  !voiceGestureIsHeld,
                  voiceStreamID != nil {
            sendVoiceStopForCurrentStream()
            clearVoiceStream()
        }
    }

    func setButton(_ command: WatchRemoteCommand, isPressed: Bool) {
        // Freeze an entire direct gesture (including double-click waiting) to
        // its original route. Never fall back after an ambiguous HTTP result.
        if directHeldCommands[command] != nil
            || directGestureResolver.pendingRevision(for: command) != nil
            || (isPressed && directBridge.isReady && heldCommandRevisions.isEmpty
                && Date() >= companionGestureBarrierUntil
                && !hasPendingInternetButtonInteraction) {
            setDirectButton(command, isPressed: isPressed)
            return
        }
        issueText = nil
        if isPressed {
            let pendingInternetRevision = internetButtonGestureResolver.pendingRevision(
                for: command
            )
            let usesInternet = pendingInternetRevision != nil
                || hasPendingInternetButtonInteraction
                || (!localIsReady && internetIsReady)
            let selectedStatus = usesInternet ? internetRemoteStatus : remoteStatus
            guard (usesInternet || localIsReady),
                  let revision = pendingInternetRevision
                    ?? selectedStatus?.profileRevision,
                  heldCommandRevisions[command] == nil
            else { return }

            if usesInternet {
                let enabledTriggers = internetButtonTriggers[command] ?? []
                guard let outcome = internetButtonGestureResolver.press(
                    command,
                    profileRevision: revision,
                    recognizesDoubleClick: enabledTriggers.contains(.doubleClick),
                    recognizesLongPress: enabledTriggers.contains(.longPress)
                ) else { return }
                if outcome.shouldCancelSingleClick {
                    internetSingleClickCommitTasks.removeValue(
                        forKey: command
                    )?.cancel()
                }
                if outcome.shouldScheduleLongPress {
                    scheduleInternetLongPressCommit(
                        command,
                        profileRevision: revision
                    )
                }
            }

            heldCommandRevisions[command] = revision
            heldCommandUsesInternet[command] = usesInternet
            connectionPath = usesInternet ? .internet : .local
            WatchHaptics.play(.click)
            if !usesInternet {
                sendControlMessage(WatchRemoteProtocol.buttonMessage(
                    command: command,
                    phase: .press,
                    profileRevision: revision
                ))
            }
        } else {
            guard let revision = heldCommandRevisions.removeValue(forKey: command) else { return }
            let usesInternet = heldCommandUsesInternet.removeValue(forKey: command) == true
            if usesInternet {
                internetLongPressCommitTasks.removeValue(forKey: command)?.cancel()
                switch internetButtonGestureResolver.release(
                    command,
                    profileRevision: revision
                ) {
                case .some(.none):
                    break
                case .some(.scheduleSingleClick):
                    scheduleInternetSingleClickCommit(
                        command,
                        profileRevision: revision
                    )
                case let .some(.commit(trigger)):
                    sendInternetButton(
                        command,
                        trigger: trigger,
                        profileRevision: revision
                    )
                case nil:
                    issueText = "公网按键状态已失效，请重试"
                    WatchHaptics.play(.failure)
                }
            } else {
                companionGestureBarrierUntil = Date().addingTimeInterval(
                    Double(WristInternetButtonGesturePolicy.doubleClickCommitDelayMilliseconds) / 1_000
                )
                sendControlMessage(WatchRemoteProtocol.buttonMessage(
                    command: command,
                    phase: .release,
                    profileRevision: revision
                ), reportsErrors: false)
            }
            reconcilePreferredConnectionPathIfIdle()
        }
    }

    private func sendInternetButton(
        _ command: WatchRemoteCommand,
        trigger: WristInternetRelayButtonTrigger,
        profileRevision: Int
    ) {
        guard internetClient != nil else { return }
        guard WristInternetButtonQueuePolicy.canEnqueue(
            pendingEventCount: internetButtonQueue.count
        ) else {
            issueText = "公网按键繁忙，本次未执行"
            WatchHaptics.play(.failure)
            return
        }
        internetButtonQueue.append(PendingInternetButtonEvent(
            command: command,
            trigger: trigger,
            profileRevision: profileRevision,
            committedAt: Date()
        ))
        startInternetButtonPumpIfNeeded()
    }

    private func scheduleInternetSingleClickCommit(
        _ command: WatchRemoteCommand,
        profileRevision: Int
    ) {
        internetSingleClickCommitTasks.removeValue(forKey: command)?.cancel()
        internetSingleClickCommitTasks[command] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(
                WristInternetButtonGesturePolicy.doubleClickCommitDelayMilliseconds
            ))
            guard let self, !Task.isCancelled else { return }
            internetSingleClickCommitTasks[command] = nil
            defer { reconcilePreferredConnectionPathIfIdle() }
            guard let trigger = internetButtonGestureResolver.singleClickTimedOut(
                command,
                profileRevision: profileRevision
            ) else { return }
            sendInternetButton(
                command,
                trigger: trigger,
                profileRevision: profileRevision
            )
        }
    }

    private func scheduleInternetLongPressCommit(
        _ command: WatchRemoteCommand,
        profileRevision: Int
    ) {
        internetLongPressCommitTasks.removeValue(forKey: command)?.cancel()
        internetLongPressCommitTasks[command] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(
                WristInternetButtonGesturePolicy.longPressCommitDelayMilliseconds
            ))
            guard let self,
                  !Task.isCancelled,
                  heldCommandRevisions[command] == profileRevision,
                  heldCommandUsesInternet[command] == true
            else { return }
            internetLongPressCommitTasks[command] = nil
            defer { reconcilePreferredConnectionPathIfIdle() }
            guard let trigger = internetButtonGestureResolver.longPressTimedOut(
                command,
                profileRevision: profileRevision
            ) else { return }
            WatchHaptics.play(.directionUp)
            sendInternetButton(
                command,
                trigger: trigger,
                profileRevision: profileRevision
            )
        }
    }

    private func startInternetButtonPumpIfNeeded() {
        guard internetButtonTask == nil,
              !internetButtonQueue.isEmpty,
              let internetClient
        else { return }
        let generation = internetProvisioningGeneration
        internetButtonTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if generation == internetProvisioningGeneration {
                    internetButtonTask = nil
                    if !internetButtonQueue.isEmpty {
                        startInternetButtonPumpIfNeeded()
                    } else {
                        reconcilePreferredConnectionPathIfIdle()
                    }
                }
            }
            while !Task.isCancelled,
                  generation == internetProvisioningGeneration,
                  !internetButtonQueue.isEmpty {
                let event = internetButtonQueue.removeFirst()
                guard WristInternetButtonQueuePolicy.isFresh(
                    committedAt: event.committedAt,
                    now: Date()
                ) else {
                    issueText = "公网按键已过期，本次未执行"
                    WatchHaptics.play(.failure)
                    continue
                }
                let operation = WristInternetRelayOperation(
                    kind: .buttonEvent,
                    profileRevision: event.profileRevision,
                    command: event.command,
                    buttonTrigger: event.trigger,
                    buttonCommittedAtEpochMilliseconds: Int64(
                        (event.committedAt.timeIntervalSince1970 * 1_000).rounded()
                    )
                )
                do {
                    let result = try await internetClient.send(operation)
                    guard generation == internetProvisioningGeneration,
                          result.accepted
                    else {
                        throw WristInternetRelayHTTPError.invalidResponse
                    }
                } catch is CancellationError {
                    return
                } catch {
                    guard generation == internetProvisioningGeneration else { return }
                    issueText = (error as? LocalizedError)?.errorDescription
                        ?? resultDetailFallback(for: event.trigger)
                    WatchHaptics.play(.failure)
                    requestInternetStatus()
                }
            }
        }
    }

    private func resultDetailFallback(
        for trigger: WristInternetRelayButtonTrigger
    ) -> String {
        switch trigger {
        case .singleClick: return "公网单击未送达"
        case .doubleClick: return "公网双击未送达"
        case .longPress: return "公网长按未送达"
        }
    }

    func activateButton(_ command: WatchRemoteCommand) {
        setButton(command, isPressed: true)
        setButton(command, isPressed: false)
    }

    func setVoicePressed(_ isPressed: Bool) {
        setVoicePressed(
            isPressed,
            intent: .foregroundDictation,
            codexTaskIdentity: nil,
            codexConversationTarget: nil
        )
    }

    func requestCodexConversationCatalog() {
        guard !Self.presentationFixtureRequested else { return }
        guard session.activationState == .activated, session.isReachable else {
            isCodexConversationCatalogLoading = false
            codexVoiceStatusText = "会话控制需要先连接 iPhone 私有链路"
            return
        }
        guard codexConversationCatalogRequestID == nil else { return }
        guard codexCatalogStartupGate.request(routeIsReady: privateCodexConversationRouteIsReady) else {
            isCodexConversationCatalogLoading = false
            codexVoiceStatusText = "正在连接 Mac，连接后自动同步会话"
            requestStatus()
            return
        }

        let requestID = UUID()
        codexConversationCatalogRequestID = requestID
        isCodexConversationCatalogLoading = true
        codexVoiceStatusText = codexConversationCatalog == nil ? "正在同步会话…" : nil
        codexConversationCatalogRequestTimeoutTask?.cancel()
        codexConversationCatalogRequestTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(16))
            guard let self,
                  !Task.isCancelled,
                  codexConversationCatalogRequestID == requestID
            else { return }
            codexConversationCatalogRequestID = nil
            isCodexConversationCatalogLoading = false
            codexVoiceStatusText = "会话同步超时，请重试"
            WatchHaptics.play(.failure)
        }

        session.sendMessage(
            WatchRemoteProtocol.codexConversationCatalogRequestMessage(requestID: requestID),
            replyHandler: { [weak self] reply in
                Task { @MainActor in
                    guard let self,
                          self.codexConversationCatalogRequestID == requestID
                    else { return }
                    self.codexConversationCatalogRequestTimeoutTask?.cancel()
                    self.codexConversationCatalogRequestTimeoutTask = nil
                    self.codexConversationCatalogRequestID = nil
                    self.isCodexConversationCatalogLoading = false
                    guard let response = WatchRemoteProtocol
                        .codexConversationCatalogSnapshot(from: reply),
                          response.requestID == requestID
                    else {
                        self.codexVoiceStatusText = "Mac 未返回有效的会话目录"
                        WatchHaptics.play(.failure)
                        return
                    }
                    self.applyCodexConversationCatalog(response.catalog)
                }
            },
            errorHandler: { [weak self] _ in
                Task { @MainActor in
                    guard let self,
                          self.codexConversationCatalogRequestID == requestID
                    else { return }
                    self.codexConversationCatalogRequestTimeoutTask?.cancel()
                    self.codexConversationCatalogRequestTimeoutTask = nil
                    self.codexConversationCatalogRequestID = nil
                    self.isCodexConversationCatalogLoading = false
                    self.codexVoiceStatusText = "会话同步失败，请检查私有连接"
                    WatchHaptics.play(.failure)
                }
            }
        )
    }

    func selectCodexConversationTarget(_ target: WatchCodexConversationTarget) {
        guard codexConversationDraft == nil else {
            codexVoiceStatusText = "草稿已锁定发送目标；请先发送或重说"
            WatchHaptics.play(.failure)
            return
        }
        guard !isCodexReplySubmitting else {
            codexVoiceStatusText = "正在确认发送结果，暂时不能切换会话"
            WatchHaptics.play(.failure)
            return
        }
        switch WatchCodexConversationSelectionRequestGate.disposition(
            requested: target,
            activeRequestID: codexConversationTargetRequestID,
            pendingTarget: pendingCodexConversationTarget
        ) {
        case .start:
            break
        case .alreadyPending:
            codexVoiceStatusText = "正在确认这个发送目标，请稍候"
            return
        case .busy:
            codexVoiceStatusText = "正在确认另一个发送目标，请稍候"
            WatchHaptics.play(.failure)
            return
        }
        guard !isCodexVoiceInteractionInProgress else {
            codexVoiceStatusText = "请先结束当前语音"
            WatchHaptics.play(.failure)
            return
        }
        guard let entry = codexConversationCatalog?.entries.first(where: {
            $0.target == target
        }),
              entry.canAcceptInput,
              !target.isExpired(atEpochMilliseconds: Self.nowEpochMilliseconds)
        else {
            codexVoiceStatusText = "会话目标已更新，请刷新后重选"
            WatchHaptics.play(.failure)
            return
        }
        guard session.activationState == .activated, session.isReachable else {
            codexVoiceStatusText = "会话选择需要 iPhone 私有链路"
            WatchHaptics.play(.failure)
            return
        }
        guard let requestID = selectionOperationID(for: target),
              let message = WatchRemoteProtocol.codexConversationTargetSelectMessage(
                  requestID: requestID,
                  target: target
              )
        else {
            if codexVoiceStatusText == nil {
                codexVoiceStatusText = "无法安全保存新会话重试状态"
            }
            WatchHaptics.play(.failure)
            return
        }

        codexConversationTargetRequestID = requestID
        pendingCodexConversationTarget = target
        codexVoiceStatusText = "正在确认发送目标…"
        codexConversationTargetTimeoutTask?.cancel()
        codexConversationTargetTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(35))
            guard let self,
                  !Task.isCancelled,
                  codexConversationTargetRequestID == requestID,
                  pendingCodexConversationTarget == target
            else { return }
            codexConversationTargetRequestID = nil
            pendingCodexConversationTarget = nil
            codexVoiceStatusText = "目标确认超时，请重试"
            WatchHaptics.play(.failure)
        }

        session.sendMessage(message, replyHandler: { [weak self] reply in
            Task { @MainActor in
                guard let self,
                      self.codexConversationTargetRequestID == requestID,
                      self.pendingCodexConversationTarget == target
                else { return }
                self.codexConversationTargetTimeoutTask?.cancel()
                self.codexConversationTargetTimeoutTask = nil
                self.codexConversationTargetRequestID = nil
                self.pendingCodexConversationTarget = nil
                guard let result = WatchRemoteProtocol.codexConversationTargetResult(
                    from: reply
                ),
                      result.requestID == requestID,
                      result.accepted,
                      let selectedTarget = result.selectedTarget,
                      WatchCodexConversationSelectionResolution.isAccepted(
                          requested: target,
                          selected: selectedTarget,
                          catalog: self.codexConversationCatalog,
                          nowEpochMilliseconds: Self.nowEpochMilliseconds
                      )
                else {
                    self.codexVoiceStatusText = WatchRemoteProtocol
                        .codexConversationTargetResult(from: reply)?.detail?.nonEmpty
                        ?? "Mac 未接受这个发送目标"
                    WatchHaptics.play(.failure)
                    return
                }
                if target.kind == .newConversation {
                    self.installImmediatelyCreatedConversation(selectedTarget)
                }
                self.selectedCodexTarget = selectedTarget
                let clearedRetryState = target.kind != .newConversation
                    || self.completeSelectionOperation(for: target)
                if target.kind == .newConversation {
                    self.codexVoiceStatusText = clearedRetryState
                        ? "已新建 · \(selectedTarget.displayTitle)"
                        : "已新建 · \(selectedTarget.displayTitle)；安全重试状态待清理"
                } else {
                    self.codexVoiceStatusText = "已选择 · \(selectedTarget.displayTitle)"
                }
                WatchHaptics.play(.success)
            }
        }, errorHandler: { [weak self] _ in
            Task { @MainActor in
                guard let self,
                      self.codexConversationTargetRequestID == requestID,
                      self.pendingCodexConversationTarget == target
                else { return }
                self.codexConversationTargetTimeoutTask?.cancel()
                self.codexConversationTargetTimeoutTask = nil
                self.codexConversationTargetRequestID = nil
                self.pendingCodexConversationTarget = nil
                self.codexVoiceStatusText = "目标确认失败，请检查私有连接"
                WatchHaptics.play(.failure)
            }
        })
    }

    /// Stops waiting on Watch without claiming that a request already delivered
    /// to the Mac was cancelled. New-conversation operation state is deliberately
    /// retained so a later retry reuses the same idempotency key.
    func stopWaitingForCodexConversationTarget() {
        guard pendingCodexConversationTarget != nil,
              codexConversationTargetRequestID != nil
        else { return }
        codexConversationTargetTimeoutTask?.cancel()
        codexConversationTargetTimeoutTask = nil
        codexConversationTargetRequestID = nil
        pendingCodexConversationTarget = nil
        codexVoiceStatusText = "已停止等待；刷新后可确认结果"
        WatchHaptics.play(.click)
    }

    private func restoreCodexConversationSelectionOperations() {
        switch WatchCodexConversationSelectionOperationStore.load() {
        case let .loaded(operations):
            codexConversationSelectionOperations = operations
        case .notFound:
            codexConversationSelectionOperations = .empty
        case .unavailable:
            codexConversationSelectionOperations = nil
            codexVoiceStatusText = "新会话安全重试状态损坏；已停止创建新会话"
        }
    }

    private func selectionOperationID(
        for target: WatchCodexConversationTarget
    ) -> UUID? {
        guard target.kind == .newConversation else { return UUID() }
        guard var operations = codexConversationSelectionOperations,
              let operationID = operations.operationID(for: target, creating: UUID())
        else {
            codexVoiceStatusText = "待确认的新会话过多；请先确认之前的创建结果"
            return nil
        }
        guard WatchCodexConversationSelectionOperationStore.save(operations) else {
            codexConversationSelectionOperations = nil
            codexVoiceStatusText = "无法安全保存新会话重试状态；操作已停止"
            return nil
        }
        codexConversationSelectionOperations = operations
        return operationID
    }

    private func completeSelectionOperation(
        for target: WatchCodexConversationTarget
    ) -> Bool {
        guard var operations = codexConversationSelectionOperations else { return false }
        operations.markCompleted(target)
        guard WatchCodexConversationSelectionOperationStore.save(operations) else {
            return false
        }
        codexConversationSelectionOperations = operations
        return true
    }

    private func installImmediatelyCreatedConversation(
        _ target: WatchCodexConversationTarget
    ) {
        guard let updated = codexConversationCatalog?
            .installingImmediatelyCreatedConversation(
                target,
                nowEpochMilliseconds: Self.nowEpochMilliseconds
            )
        else { return }
        codexConversationCatalog = updated
    }

    func setCodexVoicePressed(_ isPressed: Bool) {
        if isPressed {
            guard canStartCodexVoice,
                  let identity = WatchCodexTaskIdentity(codexTaskSnapshot)
            else {
                codexVoiceStatusText = "任务完成后才能语音追问"
                return
            }
            setVoicePressed(
                true,
                intent: .codexTask,
                codexTaskIdentity: identity,
                codexConversationTarget: nil
            )
        } else {
            guard voiceIntent == .codexTask else { return }
            setVoicePressed(
                false,
                intent: .codexTask,
                codexTaskIdentity: voiceCodexTaskIdentity,
                codexConversationTarget: nil
            )
        }
    }

    func setCodexConversationVoicePressed(_ isPressed: Bool) {
        if isPressed {
            guard canStartCodexConversationVoice,
                  let target = selectedCodexTarget
            else {
                codexVoiceStatusText = selectedCodexTarget == nil
                    ? "请先选择发送目标"
                    : "会话暂时不能接收语音，请刷新后重试"
                return
            }
            setVoicePressed(
                true,
                intent: .codexConversation,
                codexTaskIdentity: nil,
                codexConversationTarget: target
            )
        } else {
            guard voiceIntent == .codexConversation else { return }
            setVoicePressed(
                false,
                intent: .codexConversation,
                codexTaskIdentity: nil,
                codexConversationTarget: voiceCodexConversationTarget
            )
        }
    }

    func cancelCodexVoiceGesture() {
        guard isCodexVoiceInteractionInProgress else { return }
        abortCodexCapture()
    }

    func cancelCodexConversationVoice() {
        let isConversationInteraction = voiceIntent == .codexConversation
            && (voiceGestureIsHeld || isVoiceStartPending || isVoiceActive || isVoiceFinalizing)
        guard isConversationInteraction || awaitingVoiceOutcomeConversationTarget != nil else {
            return
        }
        abortCodexCapture()
    }

    /// Discard the capture without draining its tail or sending voiceStop.
    /// Once the stop has left Watch, keep waiting for its receipt: local UI
    /// cancellation cannot retract a request that Codex may already accept.
    private func abortCodexCapture(failureText: String? = nil) {
        guard voiceGestureIsHeld || isVoiceStartPending || isVoiceActive || isVoiceFinalizing else {
            if awaitingVoiceOutcomeSessionID != nil {
                codexVoiceStatusText = "已交给 Mac，正在确认发送结果"
            }
            return
        }
        if let streamID = voiceStreamID, let revision = voiceProfileRevision,
           !voiceUsesInternet, session.activationState == .activated, session.isReachable {
            sendControlMessage(
                WatchRemoteProtocol.voiceCancelMessage(
                    streamID: streamID,
                    profileRevision: revision,
                    intent: voiceIntent,
                    codexTaskIdentity: voiceCodexTaskIdentity,
                    codexConversationTarget: voiceCodexConversationTarget
                ),
                reportsErrors: false
            )
        }
        voiceRequestID &+= 1
        voiceGestureIsHeld = false
        voiceStartTimeoutTask?.cancel()
        voiceStartTimeoutTask = nil
        voiceStartHandshake.invalidate()
        isVoiceStartPending = false
        _ = audioCapture.stop()
        isVoiceActive = false
        voiceOutcomeTimeoutTask?.cancel()
        voiceOutcomeTimeoutTask = nil
        awaitingVoiceOutcomeSessionID = nil
        awaitingVoiceOutcomeIdentity = nil
        awaitingVoiceOutcomeConversationTarget = nil
        clearVoiceStream()
        codexVoiceStatusText = failureText ?? "本次录音已丢弃"
        WatchHaptics.play(failureText == nil ? .click : .failure)
    }

    func submitCodexReply() {
        guard !isCodexReplySubmitting,
              let identity = codexDraftIdentity,
              let submissionID = codexDraftSubmissionID,
              identity == WatchCodexTaskIdentity(codexTaskSnapshot),
              let draft = codexReplyDraft,
              let message = WatchRemoteProtocol.codexReplySubmitMessage(
                  codexTaskIdentity: identity,
                  submissionID: submissionID,
                  transcript: draft
              )
        else {
            codexVoiceStatusText = "任务已变化，已保留草稿；请重新录音后再发送"
            WatchHaptics.play(.failure)
            return
        }
        let usesInternet = !localIsReady && internetIsReady
        guard usesInternet
                || (session.activationState == .activated && session.isReachable)
        else {
            codexVoiceStatusText = "Mac 当前未连接，草稿已保留"
            WatchHaptics.play(.failure)
            return
        }

        isCodexReplySubmitting = true
        codexVoiceStatusText = "正在发送给 Codex…"
        codexReplySubmitID &+= 1
        let submitID = codexReplySubmitID
        codexReplySubmitTask?.cancel()
        if usesInternet {
            guard let internetClient else {
                isCodexReplySubmitting = false
                codexVoiceStatusText = "公网连接不可用，草稿已保留"
                WatchHaptics.play(.failure)
                return
            }
            let operation = WristInternetRelayOperation(
                kind: .codexReplySubmit,
                codexTaskIdentity: identity,
                submissionID: submissionID,
                transcript: draft
            )
            let generation = internetProvisioningGeneration
            codexReplyUsesInternet = true
            codexReplySubmitTask = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let result = try await internetClient.send(operation)
                    guard !Task.isCancelled,
                          generation == internetProvisioningGeneration,
                          isCodexReplySubmitting,
                          codexReplySubmitID == submitID
                    else { return }
                    codexReplySubmitTask = nil
                    codexReplyUsesInternet = false
                    isCodexReplySubmitting = false
                    guard result.accepted,
                          codexDraftIdentity == identity,
                          codexDraftSubmissionID == submissionID
                    else {
                        codexVoiceStatusText = result.detail?.nonEmpty
                            ?? "Codex 未接受，草稿已保留"
                        WatchHaptics.play(.failure)
                        return
                    }
                    codexReplyDraft = nil
                    codexDraftIdentity = nil
                    codexDraftSubmissionID = nil
                    persistCodexDraft()
                    codexVoiceStatusText = result.detail?.nonEmpty
                        ?? "已送达当前 Codex 聊天"
                    WatchHaptics.play(.success)
                } catch is CancellationError {
                    return
                } catch {
                    guard generation == internetProvisioningGeneration,
                          isCodexReplySubmitting,
                          codexReplySubmitID == submitID
                    else { return }
                    codexReplySubmitTask = nil
                    codexReplyUsesInternet = false
                    isCodexReplySubmitting = false
                    codexVoiceStatusText = (error as? LocalizedError)?.errorDescription
                        ?? "公网发送失败，草稿已保留"
                    WatchHaptics.play(.failure)
                }
            }
            return
        }
        codexReplySubmitTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(16))
            guard let self,
                  !Task.isCancelled,
                  isCodexReplySubmitting,
                  codexReplySubmitID == submitID
            else { return }
            isCodexReplySubmitting = false
            codexReplyUsesInternet = false
            codexVoiceStatusText = "发送确认超时，草稿已保留"
            WatchHaptics.play(.failure)
        }
        session.sendMessage(message, replyHandler: { [weak self] reply in
            Task { @MainActor in
                guard let self,
                      self.isCodexReplySubmitting,
                      self.codexReplySubmitID == submitID
                else { return }
                self.codexReplySubmitTask?.cancel()
                self.codexReplySubmitTask = nil
                self.isCodexReplySubmitting = false
                self.codexReplyUsesInternet = false
                guard let ack = WatchRemoteProtocol.codexReplyAck(from: reply),
                      ack.codexTaskIdentity == identity,
                      ack.submissionID == submissionID,
                      ack.accepted,
                      self.codexDraftIdentity == identity,
                      self.codexDraftSubmissionID == submissionID
                else {
                    let detail = WatchRemoteProtocol.codexReplyAck(from: reply)?.detail
                    self.codexVoiceStatusText = detail?.nonEmpty ?? "Codex 未接受，草稿已保留"
                    WatchHaptics.play(.failure)
                    return
                }
                self.codexReplyDraft = nil
                self.codexDraftIdentity = nil
                self.codexDraftSubmissionID = nil
                self.persistCodexDraft()
                self.codexVoiceStatusText = ack.detail?.nonEmpty ?? "已送达当前 Codex 聊天"
                WatchHaptics.play(.success)
            }
        }, errorHandler: { [weak self] _ in
            Task { @MainActor in
                guard let self,
                      self.isCodexReplySubmitting,
                      self.codexReplySubmitID == submitID
                else { return }
                self.codexReplySubmitTask?.cancel()
                self.codexReplySubmitTask = nil
                self.isCodexReplySubmitting = false
                self.codexReplyUsesInternet = false
                self.codexVoiceStatusText = "发送失败，草稿已保留"
                WatchHaptics.play(.failure)
            }
        })
    }

    func discardCodexReply() {
        guard !isCodexReplySubmitting else {
            codexVoiceStatusText = "发送已开始，结果确认前不能撤回"
            WatchHaptics.play(.failure)
            return
        }
        codexReplySubmitTask?.cancel()
        codexReplySubmitTask = nil
        codexReplySubmitID &+= 1
        isCodexReplySubmitting = false
        codexReplyUsesInternet = false
        codexReplyDraft = nil
        codexDraftIdentity = nil
        codexDraftSubmissionID = nil
        persistCodexDraft()
        codexVoiceStatusText = nil
        WatchHaptics.play(.click)
    }

    func submitCodexConversationDraft() {
        guard isCodexDraftStoreReady,
              !isCodexReplySubmitting,
              let draft = codexConversationDraft
        else {
            if !isCodexDraftStoreReady {
                codexVoiceStatusText = "受保护草稿尚未恢复，请解锁后重试"
                WatchHaptics.play(.failure)
            }
            return
        }
        guard !draft.isExpired(atEpochMilliseconds: Self.nowEpochMilliseconds) else {
            codexVoiceStatusText = "草稿授权已过期；内容已保留，请重说后发送"
            WatchHaptics.play(.failure)
            return
        }
        guard draft.target.kind == .existing,
              selectedCodexTarget == draft.target
        else {
            codexVoiceStatusText = "草稿目标已锁定且不匹配，未发送"
            WatchHaptics.play(.failure)
            return
        }
        guard session.activationState == .activated,
              session.isReachable,
              let message = WatchRemoteProtocol.codexConversationDraftSubmitMessage(
                  submissionID: draft.submissionID,
                  draftID: draft.draftID,
                  target: draft.target,
                  transcript: draft.text
              )
        else {
            codexVoiceStatusText = "私有连接暂不可用，草稿已保留"
            WatchHaptics.play(.failure)
            return
        }

        isCodexReplySubmitting = true
        codexReplyUsesInternet = false
        codexVoiceStatusText = "正在发送到 \(draft.target.displayTitle)…"
        codexReplySubmitID &+= 1
        let submitID = codexReplySubmitID
        codexReplySubmitTask?.cancel()
        codexReplySubmitTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(26))
            guard let self,
                  !Task.isCancelled,
                  isCodexReplySubmitting,
                  codexReplySubmitID == submitID,
                  codexConversationDraft == draft
            else { return }
            isCodexReplySubmitting = false
            codexReplySubmitTask = nil
            codexVoiceStatusText = "发送确认超时，草稿已保留且不会自动重发"
            WatchHaptics.play(.failure)
        }

        session.sendMessage(message, replyHandler: { [weak self] reply in
            Task { @MainActor in
                guard let self,
                      self.isCodexReplySubmitting,
                      self.codexReplySubmitID == submitID,
                      self.codexConversationDraft == draft
                else { return }
                self.codexReplySubmitTask?.cancel()
                self.codexReplySubmitTask = nil
                self.isCodexReplySubmitting = false
                guard let receipt = WatchRemoteProtocol.codexConversationDraftReceipt(
                    from: reply
                ),
                      receipt.submissionID == draft.submissionID,
                      receipt.draftID == draft.draftID,
                      receipt.accepted,
                      let resolvedTarget = receipt.resolvedTarget,
                      self.isValidResolvedTarget(resolvedTarget, for: draft.target)
                else {
                    self.codexVoiceStatusText = WatchRemoteProtocol
                        .codexConversationDraftReceipt(from: reply)?.detail?.nonEmpty
                        ?? "Codex 未接受，草稿已保留"
                    WatchHaptics.play(.failure)
                    return
                }
                self.codexConversationDraft = nil
                self.selectedCodexTarget = resolvedTarget
                self.persistCodexDrafts()
                self.codexVoiceStatusText = receipt.detail?.nonEmpty
                    ?? "已送达 \(resolvedTarget.displayTitle)"
                self.scheduleCodexConversationLeaseRefresh()
                WatchHaptics.play(.success)
            }
        }, errorHandler: { [weak self] _ in
            Task { @MainActor in
                guard let self,
                      self.isCodexReplySubmitting,
                      self.codexReplySubmitID == submitID,
                      self.codexConversationDraft == draft
                else { return }
                self.codexReplySubmitTask?.cancel()
                self.codexReplySubmitTask = nil
                self.isCodexReplySubmitting = false
                self.codexVoiceStatusText = "发送失败，草稿已保留且不会自动重发"
                WatchHaptics.play(.failure)
            }
        })
    }

    func discardCodexConversationDraft() {
        guard !isCodexReplySubmitting else {
            codexVoiceStatusText = "正在确认发送结果，暂时不能删除草稿"
            WatchHaptics.play(.failure)
            return
        }
        codexReplySubmitTask?.cancel()
        codexReplySubmitTask = nil
        codexReplySubmitID &+= 1
        codexConversationDraft = nil
        persistCodexDrafts()
        codexVoiceStatusText = nil
        scheduleCodexConversationLeaseRefresh()
        WatchHaptics.play(.click)
    }

    private func setVoicePressed(
        _ isPressed: Bool,
        intent: WatchVoiceIntent,
        codexTaskIdentity: WatchCodexTaskIdentity?,
        codexConversationTarget: WatchCodexConversationTarget?
    ) {
        issueText = nil
        if isPressed {
            guard !voiceGestureIsHeld,
                  !isVoiceStartPending,
                  !isVoiceActive,
                  !isVoiceFinalizing
            else { return }
            guard acceptsVoiceTarget(
                intent: intent,
                codexTaskIdentity: codexTaskIdentity,
                codexConversationTarget: codexConversationTarget
            )
            else { return }
            voiceIntent = intent
            voiceCodexTaskIdentity = codexTaskIdentity
            voiceCodexConversationTarget = codexConversationTarget
            if intent == .codexTask || intent == .codexConversation {
                codexVoiceStatusText = "正在准备原始录音"
            }
            voiceGestureIsHeld = true
            guard canStartVoice else {
                voiceGestureIsHeld = false
                issueText = directBridge.isReady
                    ? "按键已直连；语音仍需要 iPhone 私有链路"
                    : "语音需要先连接 iPhone 与 Mac"
                return
            }
            voiceRequestID &+= 1
            let requestID = voiceRequestID
            Task { @MainActor [weak self] in
                await self?.beginVoice(requestID: requestID)
            }
        } else {
            guard voiceGestureIsHeld || isVoiceActive || isVoiceStartPending else { return }
            let wasCodexVoice = voiceIntent == .codexTask || voiceIntent == .codexConversation
            let recordingHadStarted = isVoiceActive || isVoiceFinalizing
            voiceGestureIsHeld = false
            if isVoiceStartPending {
                cancelPendingVoiceStart(sendStopMessage: canSendVoiceStopForCurrentPath)
                if wasCodexVoice {
                    codexVoiceStatusText = "录音尚未开始，请按住直到开始震动"
                }
                return
            }
            voiceRequestID &+= 1
            endVoice(
                sendStopMessage: canSendVoiceStopForCurrentPath,
                submittingCodexCapture: true
            )
            if wasCodexVoice, !recordingHadStarted {
                codexVoiceStatusText = "录音尚未开始，请按住直到开始震动"
            }
        }
    }

    func updateFavorite(at index: Int, to command: WatchRemoteCommand) {
        guard favorites.indices.contains(index) else { return }
        var updated = favorites
        if let existingIndex = updated.firstIndex(of: command), existingIndex != index {
            updated.swapAt(index, existingIndex)
        } else {
            updated[index] = command
        }
        guard updated != favorites else { return }

        favorites = updated
        UserDefaults.standard.set(updated.map(\.rawValue), forKey: Self.favoritesDefaultsKey)
        if let message = WatchRemoteProtocol.favoritesUpdateMessage(updated) {
            sendControlMessage(message, reportsErrors: false)
        }
    }

    private func beginVoice(requestID: UInt64) async {
        let permitted = await audioCapture.requestPermission()
        guard voiceRequestID == requestID,
              voiceGestureIsHeld,
              canStartVoice,
              acceptsVoiceTarget(
                  intent: voiceIntent,
                  codexTaskIdentity: voiceCodexTaskIdentity,
                  codexConversationTarget: voiceCodexConversationTarget
              )
        else { return }
        guard permitted else {
            if voiceIntent == .codexTask || voiceIntent == .codexConversation {
                codexVoiceStatusText = "请在手表设置中允许麦克风访问"
            }
            voiceGestureIsHeld = false
            voiceIntent = .foregroundDictation
            voiceCodexTaskIdentity = nil
            voiceCodexConversationTarget = nil
            issueText = "请在手表设置中允许麦克风访问"
            return
        }

        requestVoiceStart(requestID: requestID)
    }

    private func requestVoiceStart(requestID: UInt64) {
        let usesInternet = voiceIntent == .codexConversation
            ? false
            : (!localIsReady && internetIsReady)
        let selectedStatus = usesInternet ? internetRemoteStatus : remoteStatus
        guard (usesInternet || localIsReady),
              let profileRevision = selectedStatus?.profileRevision,
              profileRevision >= 0,
              acceptsVoiceTarget(
                  intent: voiceIntent,
                  codexTaskIdentity: voiceCodexTaskIdentity,
                  codexConversationTarget: voiceCodexConversationTarget
              )
        else {
            handleCommunicationFailure()
            return
        }

        let streamID = UUID()
        let intent = voiceIntent
        let identity = voiceCodexTaskIdentity
        let conversationTarget = voiceCodexConversationTarget
        let startMessage = WatchRemoteProtocol.voiceStartMessage(
            streamID: streamID,
            profileRevision: profileRevision,
            intent: intent,
            codexTaskIdentity: identity,
            codexConversationTarget: conversationTarget
        )
        guard usesInternet || startMessage != nil else {
            voiceGestureIsHeld = false
            codexVoiceStatusText = "任务身份无效，请等待任务刷新"
            return
        }
        voiceStreamID = streamID
        voiceProfileRevision = profileRevision
        nextAudioSequence = 0
        audioAckTracker.start(streamID: streamID, profileRevision: profileRevision)
        voiceUsesInternet = usesInternet
        connectionPath = usesInternet ? .internet : .local
        isVoiceStartPending = true
        if usesInternet {
            cancelInternetStatusTask()
            cancelHealthyStatusRefresh()
        }
        voiceStartHandshake.begin(
            requestID: requestID,
            streamID: streamID,
            profileRevision: profileRevision
        )
        voiceStartTimeoutTask?.cancel()
        let replyTimeoutMilliseconds = usesInternet
            ? Self.internetVoiceStartReplyTimeoutMilliseconds
            : WatchRemoteProtocol.voiceStartReplyTimeoutMilliseconds
        voiceStartTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(
                replyTimeoutMilliseconds
            ))
            guard let self,
                  !Task.isCancelled,
                  voiceRequestID == requestID,
                  isVoiceStartPending,
                  voiceStartHandshake.isPending(
                      requestID: requestID,
                      streamID: streamID,
                      profileRevision: profileRevision
                  )
            else { return }
            if usesInternet {
                sendInternetVoiceStop(
                    streamID: streamID,
                    profileRevision: profileRevision,
                    intent: intent,
                    identity: identity,
                    finalSequence: nil
                )
            } else {
                sendControlMessage(
                    WatchRemoteProtocol.voiceStopMessage(
                        streamID: streamID,
                        profileRevision: profileRevision,
                        intent: intent,
                        codexTaskIdentity: identity,
                        codexConversationTarget: conversationTarget
                    ),
                    reportsErrors: false
                )
            }
            completeVoiceStart(
                requestID: requestID,
                streamID: streamID,
                profileRevision: profileRevision,
                expectedIntent: intent,
                expectedCodexTaskIdentity: identity,
                expectedCodexConversationTarget: conversationTarget,
                accepted: false,
                failureText: usesInternet ? "公网未确认语音请求" : "iPhone 未确认语音请求"
            )
        }

        if usesInternet {
            sendInternetVoiceStart(
                requestID: requestID,
                streamID: streamID,
                profileRevision: profileRevision,
                intent: intent,
                identity: identity
            )
            return
        }

        session.sendMessage(
            startMessage ?? [:],
            replyHandler: { [weak self] reply in
                let response = WatchRemoteProtocol.voiceStartReply(from: reply)
                let accepted = response?.streamID == streamID
                    && response?.profileRevision == profileRevision
                    && response?.intent == intent
                    && response?.codexTaskIdentity == identity
                    && response?.codexConversationTarget == conversationTarget
                    && response?.accepted == true
                Task { @MainActor in
                    self?.completeVoiceStart(
                        requestID: requestID,
                        streamID: streamID,
                        profileRevision: profileRevision,
                        expectedIntent: intent,
                        expectedCodexTaskIdentity: identity,
                        expectedCodexConversationTarget: conversationTarget,
                        accepted: accepted,
                        failureText: accepted ? nil : "Mac 语音当前忙"
                    )
                }
            },
            errorHandler: { [weak self] _ in
                Task { @MainActor in
                    self?.completeVoiceStart(
                        requestID: requestID,
                        streamID: streamID,
                        profileRevision: profileRevision,
                        expectedIntent: intent,
                        expectedCodexTaskIdentity: identity,
                        expectedCodexConversationTarget: conversationTarget,
                        accepted: false,
                        failureText: "与 iPhone 的连接已中断"
                    )
                }
            }
        )
    }

    private func sendInternetVoiceStart(
        requestID: UInt64,
        streamID: UUID,
        profileRevision: Int,
        intent: WatchVoiceIntent,
        identity: WatchCodexTaskIdentity?
    ) {
        guard let internetClient else { return }
        let operation = WristInternetRelayOperation(
            kind: .voiceStart,
            profileRevision: profileRevision,
            streamID: streamID,
            voiceIntent: intent,
            codexTaskIdentity: identity
        )
        let generation = internetProvisioningGeneration
        internetVoiceStartTask?.cancel()
        internetVoiceStartTaskStreamID = streamID
        internetVoiceStartTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if generation == internetProvisioningGeneration,
                   internetVoiceStartTaskStreamID == streamID {
                    internetVoiceStartTask = nil
                    internetVoiceStartTaskStreamID = nil
                }
            }
            do {
                let result = try await internetClient.send(operation)
                guard generation == internetProvisioningGeneration else { return }
                completeVoiceStart(
                    requestID: requestID,
                    streamID: streamID,
                    profileRevision: profileRevision,
                    expectedIntent: intent,
                    expectedCodexTaskIdentity: identity,
                    expectedCodexConversationTarget: nil,
                    accepted: result.accepted,
                    failureText: result.accepted ? nil : (result.detail ?? "Mac 语音当前忙")
                )
            } catch {
                guard generation == internetProvisioningGeneration else { return }
                completeVoiceStart(
                    requestID: requestID,
                    streamID: streamID,
                    profileRevision: profileRevision,
                    expectedIntent: intent,
                    expectedCodexTaskIdentity: identity,
                    expectedCodexConversationTarget: nil,
                    accepted: false,
                    failureText: error.localizedDescription
                )
            }
        }
    }

    private func sendInternetVoiceStop(
        streamID: UUID,
        profileRevision: Int,
        intent: WatchVoiceIntent,
        identity: WatchCodexTaskIdentity?,
        finalSequence: UInt64?,
        outcomeSessionID: String? = nil
    ) {
        guard let internetClient else {
            if let outcomeSessionID {
                scheduleVoiceOutcomeTimeout(
                    sessionID: outcomeSessionID,
                    pollsInternet: false
                )
            }
            return
        }
        let operation = WristInternetRelayOperation(
            kind: .voiceStop,
            profileRevision: profileRevision,
            streamID: streamID,
            voiceIntent: intent,
            codexTaskIdentity: identity,
            finalSequence: finalSequence
        )
        let generation = internetProvisioningGeneration
        let pendingStartTask = internetVoiceStartTaskStreamID == streamID
            ? internetVoiceStartTask
            : nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            await pendingStartTask?.value
            guard generation == internetProvisioningGeneration else { return }
            do {
                let result = try await internetClient.send(operation)
                guard generation == internetProvisioningGeneration else { return }
                if let status = result.status { applyInternetStatus(status) }
                if !result.accepted {
                    issueText = result.detail ?? "Mac 未确认语音结束"
                    WatchHaptics.play(.failure)
                }
                requestInternetStatus()
                if let outcomeSessionID {
                    scheduleVoiceOutcomeTimeout(
                        sessionID: outcomeSessionID,
                        pollsInternet: true
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                guard generation == internetProvisioningGeneration else { return }
                issueText = error.localizedDescription
                requestInternetStatus()
                if let outcomeSessionID {
                    scheduleVoiceOutcomeTimeout(
                        sessionID: outcomeSessionID,
                        pollsInternet: true
                    )
                }
            }
        }
    }

    private func setVoiceOwner(
        _ owner: WatchRemoteProtocol.VoiceOwner,
        usesInternet: Bool
    ) {
        if usesInternet, let status = internetRemoteStatus {
            internetRemoteStatus = WatchRemoteStatus(
                isMacConnected: status.isMacConnected,
                macName: status.macName,
                voiceOwner: owner,
                detail: status.detail,
                buttonTitles: status.buttonTitles,
                isActionProfileReady: status.isActionProfileReady,
                profileRevision: status.profileRevision
            )
        } else if !usesInternet {
            remoteStatus = WatchRemoteStatus(
                isMacConnected: remoteStatus.isMacConnected,
                macName: remoteStatus.macName,
                voiceOwner: owner,
                detail: remoteStatus.detail,
                buttonTitles: remoteStatus.buttonTitles,
                isActionProfileReady: remoteStatus.isActionProfileReady,
                profileRevision: remoteStatus.profileRevision
            )
        }
    }

    private func voicePathIsReady(profileRevision: Int) -> Bool {
        let status = voiceUsesInternet ? internetRemoteStatus : remoteStatus
        let transportIsAvailable = voiceUsesInternet
            ? internetClient != nil
            : (session.activationState == .activated && session.isReachable)
        return transportIsAvailable
            && status?.isMacConnected == true
            && status?.isActionProfileReady == true
            && status?.profileRevision == profileRevision
    }

    private func completeVoiceStart(
        requestID: UInt64,
        streamID: UUID,
        profileRevision: Int,
        expectedIntent: WatchVoiceIntent,
        expectedCodexTaskIdentity: WatchCodexTaskIdentity?,
        expectedCodexConversationTarget: WatchCodexConversationTarget?,
        accepted: Bool,
        failureText: String?
    ) {
        guard voiceRequestID == requestID,
              voiceStreamID == streamID,
              voiceProfileRevision == profileRevision,
              voiceIntent == expectedIntent,
              voiceCodexTaskIdentity == expectedCodexTaskIdentity,
              voiceCodexConversationTarget == expectedCodexConversationTarget,
              isVoiceStartPending,
              voiceStartHandshake.consumeCompletion(
                  requestID: requestID,
                  streamID: streamID,
                  profileRevision: profileRevision
              )
        else { return }
        voiceStartTimeoutTask?.cancel()
        voiceStartTimeoutTask = nil
        isVoiceStartPending = false

        guard accepted else {
            voiceGestureIsHeld = false
            clearVoiceStream()
            issueText = failureText ?? "暂时无法使用手表麦克风"
            if expectedIntent == .codexTask || expectedIntent == .codexConversation {
                codexVoiceStatusText = failureText ?? "暂时无法使用手表麦克风"
            }
            WatchHaptics.play(.failure)
            return
        }

        guard voiceGestureIsHeld,
              voicePathIsReady(profileRevision: profileRevision),
              acceptsVoiceTarget(
                  intent: expectedIntent,
                  codexTaskIdentity: expectedCodexTaskIdentity,
                  codexConversationTarget: expectedCodexConversationTarget
              )
        else {
            if voiceUsesInternet {
                sendInternetVoiceStop(
                    streamID: streamID,
                    profileRevision: profileRevision,
                    intent: expectedIntent,
                    identity: expectedCodexTaskIdentity,
                    finalSequence: nil
                )
            } else {
                sendControlMessage(
                    WatchRemoteProtocol.voiceStopMessage(
                        streamID: streamID,
                        profileRevision: profileRevision,
                        intent: expectedIntent,
                        codexTaskIdentity: expectedCodexTaskIdentity,
                        codexConversationTarget: expectedCodexConversationTarget
                    ),
                    reportsErrors: false
                )
            }
            clearVoiceStream()
            return
        }

        setVoiceOwner(.watch, usesInternet: voiceUsesInternet)
        do {
            audioMailbox.begin()
            try audioCapture.start { [weak self] packet in
                guard let self, self.audioMailbox.enqueue(packet) else { return }
                Task { @MainActor in
                    self.drainAudioMailbox()
                }
            }
            isVoiceActive = true
            if expectedIntent == .codexTask || expectedIntent == .codexConversation {
                codexVoiceStatusText = "正在录音…"
                scheduleCodexVoiceDurationLimit(
                    streamID: streamID,
                    intent: expectedIntent
                )
            }
            WatchHaptics.play(.start)
            guard voiceRequestID == requestID,
                  voiceGestureIsHeld,
                  voicePathIsReady(profileRevision: profileRevision)
            else {
                endVoice(sendStopMessage: canSendVoiceStopForCurrentPath)
                return
            }
            awaitingVoiceOutcomeSessionID = streamID.uuidString
            awaitingVoiceOutcomeUsesInternet = voiceUsesInternet
            awaitingVoiceOutcomeIdentity = expectedCodexTaskIdentity
            awaitingVoiceOutcomeConversationTarget = expectedCodexConversationTarget
        } catch {
            audioMailbox.clear()
            voiceGestureIsHeld = false
            isVoiceActive = false
            if voiceUsesInternet {
                sendInternetVoiceStop(
                    streamID: streamID,
                    profileRevision: profileRevision,
                    intent: expectedIntent,
                    identity: expectedCodexTaskIdentity,
                    finalSequence: nil
                )
            } else {
                sendControlMessage(
                    WatchRemoteProtocol.voiceStopMessage(
                        streamID: streamID,
                        profileRevision: profileRevision,
                        intent: expectedIntent,
                        codexTaskIdentity: expectedCodexTaskIdentity,
                        codexConversationTarget: expectedCodexConversationTarget
                    ),
                    reportsErrors: false
                )
            }
            clearVoiceStream()
            issueText = "暂时无法使用手表麦克风"
            if expectedIntent == .codexTask || expectedIntent == .codexConversation {
                codexVoiceStatusText = "麦克风启动失败，请重试"
            }
            WatchHaptics.play(.failure)
        }
    }

    private func drainAudioMailbox() {
        sendAudioPackets(audioMailbox.drain())
    }

    private func sendAudioPackets(_ packets: [Data]) {
        for packet in packets {
            sendAudioPacket(packet)
        }
    }

    private func sendAudioPacket(_ packet: Data) {
        guard isVoiceActive || isVoiceFinalizing,
              let streamID = voiceStreamID,
              let profileRevision = voiceProfileRevision,
              voicePathIsReady(profileRevision: profileRevision),
              (voiceUsesInternet ? internetRemoteStatus : remoteStatus)?.voiceOwner == .watch
        else {
            if isVoiceActive {
                endVoice(sendStopMessage: canSendVoiceStopForCurrentPath)
            } else if isVoiceFinalizing {
                if voiceUsesInternet {
                    failInternetVoiceTransport("公网语音尾包发送条件已失效")
                } else {
                    completeVoiceFinalization(
                        sendStopMessage: canSendVoiceStopForCurrentPath,
                        failureText: "语音尾包发送条件已失效"
                    )
                }
            }
            return
        }

        let sequence = nextAudioSequence
        nextAudioSequence &+= 1
        audioAckTracker.recordSent(sequence: sequence)
        if voiceUsesInternet {
            let expectedPacketByteCount = WatchRemoteProtocol.audioPacketSampleCount
                * MemoryLayout<Int16>.size
            guard packet.count == expectedPacketByteCount else {
                failInternetVoiceTransport("手表生成了无效的公网语音分片")
                return
            }
            if internetAudioBatchStartSequence == nil {
                internetAudioBatchStartSequence = sequence
            }
            guard internetAudioBatchStartSequence.map({
                $0 + UInt64(internetAudioBatch.count) == sequence
            }) == true else {
                failInternetVoiceTransport("公网语音分片顺序异常")
                return
            }
            guard WristInternetAudioBatchingPolicy.canBuffer(
                packetCount: internetAudioBatch.count + 1
            ) else {
                failInternetVoiceTransport("网络过慢，录音未完整发送，请缩短后重试")
                return
            }
            internetAudioBatch.append(packet)
            scheduleInternetAudioFlushIfNeeded(force: false)
            return
        }

        guard let envelope = WatchRemoteProtocol.audioEnvelopeData(
            streamID: streamID,
            profileRevision: profileRevision,
            sequence: sequence,
            pcm16Data: packet
        ) else {
            voiceGestureIsHeld = false
            issueText = "手表生成了无效的语音分片"
            endVoice(sendStopMessage: canSendVoiceStopForCurrentPath)
            return
        }
        session.sendMessageData(envelope, replyHandler: { [weak self] replyData in
            Task { @MainActor in
                self?.handleAudioAcknowledgement(
                    replyData,
                    expectedStreamID: streamID,
                    expectedProfileRevision: profileRevision,
                    expectedSequence: sequence
                )
            }
        }) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard self.voiceStreamID == streamID,
                      self.voiceProfileRevision == profileRevision
                else { return }
                if self.isVoiceFinalizing {
                    self.completeVoiceFinalization(
                        sendStopMessage: self.canSendVoiceStopForCurrentPath,
                        failureText: "iPhone 未确认语音尾包"
                    )
                } else {
                    self.handleCommunicationFailure()
                }
            }
        }
    }

    private func scheduleInternetAudioFlushIfNeeded(force: Bool) {
        if force { internetAudioFinalFlushRequested = true }
        guard internetAudioFlushTask == nil,
              WristInternetAudioBatchingPolicy.shouldFlush(
                  bufferedPacketCount: internetAudioBatch.count,
                  isFinal: internetAudioFinalFlushRequested
              ),
              let streamID = voiceStreamID,
              let profileRevision = voiceProfileRevision,
              let internetClient
        else { return }
        let generation = internetProvisioningGeneration
        internetAudioFlushTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await flushInternetAudioBatches(
                streamID: streamID,
                profileRevision: profileRevision,
                internetClient: internetClient,
                provisioningGeneration: generation
            )
        }
    }

    private func flushInternetAudioBatches(
        streamID: UUID,
        profileRevision: Int,
        internetClient: WristInternetRelayHTTPClient,
        provisioningGeneration: UInt64
    ) async {
        defer {
            if provisioningGeneration == internetProvisioningGeneration,
               voiceStreamID == streamID,
               voiceProfileRevision == profileRevision,
               voiceUsesInternet {
                internetAudioFlushTask = nil
                scheduleInternetAudioFlushIfNeeded(force: internetAudioFinalFlushRequested)
            }
        }
        while !Task.isCancelled,
              provisioningGeneration == internetProvisioningGeneration,
              voiceStreamID == streamID,
              voiceProfileRevision == profileRevision,
              voiceUsesInternet {
            let shouldFlush = WristInternetAudioBatchingPolicy.shouldFlush(
                bufferedPacketCount: internetAudioBatch.count,
                isFinal: internetAudioFinalFlushRequested
            )
            guard shouldFlush, let startSequence = internetAudioBatchStartSequence else { return }
            let packetCount = WristInternetAudioBatchingPolicy.nextPacketCount(
                bufferedPacketCount: internetAudioBatch.count
            )
            let packets = Array(internetAudioBatch.prefix(packetCount))
            internetAudioBatch.removeFirst(packetCount)
            internetAudioBatchStartSequence = internetAudioBatch.isEmpty
                ? nil
                : startSequence + UInt64(packetCount)

            var payload = Data(capacity: packets.reduce(0) { $0 + $1.count })
            for packet in packets { payload.append(packet) }
            let expectedLastSequence = startSequence + UInt64(packetCount - 1)
            let operation = WristInternetRelayOperation(
                kind: .audio,
                profileRevision: profileRevision,
                streamID: streamID,
                audioSequence: startSequence,
                pcm16Data: payload
            )
            do {
                let result = try await internetClient.send(operation)
                guard !Task.isCancelled,
                      provisioningGeneration == internetProvisioningGeneration,
                      voiceStreamID == streamID,
                      voiceProfileRevision == profileRevision,
                      voiceUsesInternet
                else { return }
                guard result.accepted,
                      let acknowledgement = result.audioAcknowledgement,
                      acknowledgement.streamID == streamID,
                      acknowledgement.profileRevision == profileRevision,
                      acknowledgement.sequence == expectedLastSequence
                else {
                    failInternetVoiceTransport(
                        result.detail ?? "Mac 拒绝了公网语音分片"
                    )
                    return
                }
                switch audioAckTracker.accept(acknowledgement) {
                case .finalized:
                    completeVoiceFinalization(sendStopMessage: true, failureText: nil)
                    return
                case .waiting:
                    break
                case .rejected:
                    failInternetVoiceTransport("Mac 返回了无效的公网语音确认")
                    return
                }
            } catch is CancellationError {
                return
            } catch {
                guard voiceStreamID == streamID,
                      provisioningGeneration == internetProvisioningGeneration,
                      voiceProfileRevision == profileRevision,
                      voiceUsesInternet
                else { return }
                failInternetVoiceTransport(
                    (error as? LocalizedError)?.errorDescription
                        ?? "公网语音分片发送失败"
                )
                return
            }
        }
    }

    private func failInternetVoiceTransport(_ failureText: String) {
        guard voiceUsesInternet else { return }
        let streamID = voiceStreamID
        let profileRevision = voiceProfileRevision
        let intent = voiceIntent
        let identity = voiceCodexTaskIdentity
        let acknowledgedSequence = audioAckTracker.contiguousThrough
        let shouldAwaitOutcome = streamID?.uuidString == awaitingVoiceOutcomeSessionID
        _ = audioCapture.stop()
        audioMailbox.clear()
        isVoiceActive = false
        isVoiceFinalizing = false
        voiceGestureIsHeld = false
        issueText = failureText
        if intent == .codexTask { codexVoiceStatusText = failureText }
        WatchHaptics.play(.failure)
        if let streamID, let profileRevision {
            sendInternetVoiceStop(
                streamID: streamID,
                profileRevision: profileRevision,
                intent: intent,
                identity: identity,
                finalSequence: acknowledgedSequence,
                outcomeSessionID: shouldAwaitOutcome ? streamID.uuidString : nil
            )
        }
        clearVoiceStream()
    }

    private func handleAudioAcknowledgement(
        _ data: Data,
        expectedStreamID: UUID,
        expectedProfileRevision: Int,
        expectedSequence: UInt64
    ) {
        guard voiceStreamID == expectedStreamID,
              voiceProfileRevision == expectedProfileRevision
        else { return }
        guard let acknowledgement = WatchRemoteProtocol.audioAcknowledgement(from: data),
              acknowledgement.streamID == expectedStreamID,
              acknowledgement.profileRevision == expectedProfileRevision,
              acknowledgement.sequence == expectedSequence
        else {
            if isVoiceFinalizing {
                completeVoiceFinalization(
                    sendStopMessage: canSendVoiceStopForCurrentPath,
                    failureText: "iPhone 返回了无效的语音确认"
                )
            } else if isVoiceActive {
                voiceGestureIsHeld = false
                issueText = "iPhone 返回了无效的语音确认"
                endVoice(sendStopMessage: canSendVoiceStopForCurrentPath)
            }
            return
        }
        switch audioAckTracker.accept(acknowledgement) {
        case .finalized:
            completeVoiceFinalization(sendStopMessage: true, failureText: nil)
        case .waiting:
            break
        case .rejected:
            if isVoiceActive {
                voiceGestureIsHeld = false
                issueText = "iPhone 拒绝了语音包，录音未完整发送"
                endVoice(sendStopMessage: canSendVoiceStopForCurrentPath)
            } else if isVoiceFinalizing {
                completeVoiceFinalization(
                    sendStopMessage: canSendVoiceStopForCurrentPath,
                    failureText: "iPhone 拒绝了语音包，录音未完整发送"
                )
            }
        }
    }

    private func endVoice(sendStopMessage: Bool, submittingCodexCapture: Bool = false) {
        if voiceIntent == .codexTask || voiceIntent == .codexConversation,
           !submittingCodexCapture || !sendStopMessage {
            abortCodexCapture(failureText: issueText)
            return
        }
        guard !isVoiceFinalizing else { return }
        voiceDurationLimitTask?.cancel()
        voiceDurationLimitTask = nil
        let wasActive = isVoiceActive
        let intent = voiceIntent
        let finalPacket = audioCapture.stop()
        isVoiceActive = false
        isVoiceFinalizing = wasActive
        let capturedPackets = audioMailbox.finishAndDrain(
            finalPacket: wasActive ? finalPacket : nil
        )
        if wasActive { sendAudioPackets(capturedPackets) }
        if wasActive, voiceUsesInternet {
            scheduleInternetAudioFlushIfNeeded(force: true)
        }
        let finalSequence = nextAudioSequence == 0 ? nil : nextAudioSequence - 1
        if wasActive {
            WatchHaptics.play(.stop)
        }
        if wasActive, intent == .codexTask || intent == .codexConversation {
            codexVoiceStatusText = "Codex 正在转写并发送，请稍候…"
        }
        guard wasActive, sendStopMessage else {
            completeVoiceFinalization(sendStopMessage: sendStopMessage, failureText: nil)
            return
        }

        switch audioAckTracker.beginFinalization(finalSequence: finalSequence) {
        case .finalized:
            completeVoiceFinalization(sendStopMessage: true, failureText: nil)
        case .waiting:
            voiceFinalAckTimeoutTask?.cancel()
            let timeoutMilliseconds = voiceUsesInternet
                ? WristInternetAudioBatchingPolicy.finalAckTimeoutMilliseconds(
                    sentPacketCount: nextAudioSequence,
                    contiguousAcknowledgement: audioAckTracker.contiguousThrough
                )
                : WatchRemoteProtocol.voiceFinalAckTimeoutMilliseconds
            voiceFinalAckTimeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(
                    timeoutMilliseconds
                ))
                guard let self, !Task.isCancelled, isVoiceFinalizing else { return }
                if voiceUsesInternet {
                    failInternetVoiceTransport("公网语音尾包确认超时，识别结果可能不完整")
                } else {
                    completeVoiceFinalization(
                        sendStopMessage: true,
                        failureText: "语音尾包确认超时，识别结果可能不完整"
                    )
                }
            }
        case .rejected:
            completeVoiceFinalization(
                sendStopMessage: true,
                failureText: "语音尾包确认失败"
            )
        }
    }

    private func completeVoiceFinalization(
        sendStopMessage: Bool,
        failureText: String?
    ) {
        if voiceIntent == .codexTask || voiceIntent == .codexConversation,
           failureText != nil || !sendStopMessage {
            abortCodexCapture(failureText: failureText)
            return
        }
        let streamID = voiceStreamID
        let profileRevision = voiceProfileRevision
        let intent = voiceIntent
        let identity = voiceCodexTaskIdentity
        let conversationTarget = voiceCodexConversationTarget
        let usesInternet = voiceUsesInternet
        let finalSequence = nextAudioSequence == 0 ? nil : nextAudioSequence - 1
        voiceFinalAckTimeoutTask?.cancel()
        voiceFinalAckTimeoutTask = nil
        isVoiceFinalizing = false
        if let failureText {
            issueText = failureText
            WatchHaptics.play(.failure)
        }
        if sendStopMessage, let streamID, let profileRevision {
            if usesInternet {
                sendInternetVoiceStop(
                    streamID: streamID,
                    profileRevision: profileRevision,
                    intent: intent,
                    identity: identity,
                    finalSequence: finalSequence,
                    outcomeSessionID: streamID.uuidString == awaitingVoiceOutcomeSessionID
                        ? streamID.uuidString
                        : nil
                )
            } else {
                sendControlMessage(
                    WatchRemoteProtocol.voiceStopMessage(
                        streamID: streamID,
                        profileRevision: profileRevision,
                        intent: intent,
                        codexTaskIdentity: identity,
                        codexConversationTarget: conversationTarget,
                        finalSequence: finalSequence
                    ),
                    reportsErrors: false
                )
            }
        }
        let shouldAwaitOutcome = streamID?.uuidString == awaitingVoiceOutcomeSessionID
        clearVoiceStream()
        if shouldAwaitOutcome, let streamID {
            if !usesInternet || !sendStopMessage {
                scheduleVoiceOutcomeTimeout(
                    sessionID: streamID.uuidString,
                    pollsInternet: usesInternet
                )
            }
        }
    }

    private func stopAllInteractions(
        sendReleaseMessages: Bool,
        preservingInternetButtons: Bool = false
    ) {
        if isCodexVoiceCaptureInProgress { abortCodexCapture() }
        let hadLocalVoiceInteraction = voiceGestureIsHeld
            || isVoiceActive
            || isVoiceFinalizing
            || isVoiceStartPending
            || audioCapture.isRunning
        voiceRequestID &+= 1
        voiceGestureIsHeld = false
        voiceStartTimeoutTask?.cancel()
        voiceStartTimeoutTask = nil
        voiceStartHandshake.invalidate()
        isVoiceStartPending = false

        let commands = heldCommandRevisions
        let internetCommands = heldCommandUsesInternet
        if preservingInternetButtons {
            for command in commands.keys where internetCommands[command] != true {
                heldCommandRevisions.removeValue(forKey: command)
                heldCommandUsesInternet.removeValue(forKey: command)
            }
        } else {
            heldCommandRevisions.removeAll()
            heldCommandUsesInternet.removeAll()
            cancelAllInternetButtonGestures()
        }
        for (command, revision) in commands {
            if internetCommands[command] == true {
                continue
            }
            if sendReleaseMessages {
                sendControlMessage(
                    WatchRemoteProtocol.buttonMessage(
                        command: command,
                        phase: .release,
                        profileRevision: revision
                    ),
                    reportsErrors: false
                )
            }
        }
        let shouldStopWatchVoice = hadLocalVoiceInteraction
            || effectiveRemoteStatus.voiceOwner == .watch
        if isVoiceFinalizing {
            completeVoiceFinalization(
                sendStopMessage: sendReleaseMessages
                    && shouldStopWatchVoice
                    && canSendVoiceStopForCurrentPath,
                failureText: nil
            )
        } else {
            endVoice(
                sendStopMessage: sendReleaseMessages
                    && shouldStopWatchVoice
                    && canSendVoiceStopForCurrentPath
            )
        }
    }

    private func cancelAllInternetButtonGestures() {
        internetSingleClickCommitTasks.values.forEach { $0.cancel() }
        internetLongPressCommitTasks.values.forEach { $0.cancel() }
        internetSingleClickCommitTasks.removeAll(keepingCapacity: false)
        internetLongPressCommitTasks.removeAll(keepingCapacity: false)
        internetButtonGestureResolver.reset()
    }

    private func scheduleVoiceOutcomeTimeout(
        sessionID: String,
        pollsInternet: Bool
    ) {
        voiceOutcomeTimeoutTask?.cancel()
        voiceOutcomeTimeoutTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let pollAttempts = pollsInternet
                ? WristInternetVoiceOutcomePollingPolicy.attemptCount
                : 80
            for _ in 0..<pollAttempts {
                try? await Task.sleep(for: .milliseconds(
                    pollsInternet
                        ? WristInternetVoiceOutcomePollingPolicy.intervalMilliseconds
                        : 750
                ))
                guard !Task.isCancelled,
                      awaitingVoiceOutcomeSessionID == sessionID
                else { return }
                if pollsInternet { requestInternetStatus() }
            }
            guard awaitingVoiceOutcomeSessionID == sessionID else { return }
            awaitingVoiceOutcomeSessionID = nil
            awaitingVoiceOutcomeIdentity = nil
            awaitingVoiceOutcomeConversationTarget = nil
            codexVoiceStatusText = "发送结果未确认；为避免重复，不会自动重发，请查看所选会话"
            WatchHaptics.play(.failure)
        }
    }

    private func sendControlMessage(
        _ message: [String: Any]?,
        reportsErrors: Bool = true
    ) {
        guard let message else {
            if reportsErrors { issueText = "请求身份无效，操作已取消" }
            return
        }
        guard session.activationState == .activated, session.isReachable else {
            if reportsErrors { handleCommunicationFailure() }
            return
        }
        session.sendMessage(message, replyHandler: nil) { [weak self] _ in
            guard reportsErrors else { return }
            Task { @MainActor in
                self?.handleCommunicationFailure()
            }
        }
    }

    private func handleCommunicationFailure() {
        let hadCodexVoice = isCodexVoiceInteractionInProgress
            || voiceIntent == .codexTask
            || voiceIntent == .codexConversation
        let preservesInternetVoice = voiceUsesInternet
            && (isVoiceStartPending || isVoiceActive || isVoiceFinalizing)
        let internetHeldCommands = heldCommandRevisions.filter { command, _ in
            heldCommandUsesInternet[command] == true
        }
        let preservesInternetButtons = !internetHeldCommands.isEmpty
            || !internetSingleClickCommitTasks.isEmpty
        if preservesInternetVoice {
            let localCommands = heldCommandUsesInternet.compactMap { command, usesInternet in
                usesInternet ? nil : command
            }
            for command in localCommands {
                heldCommandUsesInternet.removeValue(forKey: command)
                heldCommandRevisions.removeValue(forKey: command)
            }
        } else if preservesInternetButtons {
            stopAllInteractions(
                sendReleaseMessages: false,
                preservingInternetButtons: true
            )
        } else {
            stopAllInteractions(sendReleaseMessages: false)
        }
        statusRequestTimeoutTask?.cancel()
        statusRequestTimeoutTask = nil
        invalidateLiveStatus()
        phoneIsReachable = session.isReachable
        if preservesInternetVoice || preservesInternetButtons {
            connectionPath = .internet
            issueText = nil
        } else {
            issueText = "与 iPhone 的连接已中断"
        }
        if hadCodexVoice, !preservesInternetVoice {
            codexVoiceStatusText = "与 iPhone 的连接已中断，请重试"
        }
        requestInternetStatus()
        scheduleStatusRetryIfNeeded()
    }

    private func refreshReachability() {
        activationState = session.activationState
        let isReachable = session.activationState == .activated && session.isReachable
        if phoneIsReachable != isReachable {
            statusRequestTimeoutTask?.cancel()
            statusRequestTimeoutTask = nil
            invalidateLiveStatus()
            if !isReachable {
                invalidateCodexConversationRouteState(
                    detail: "与 iPhone 的私有连接已断开，草稿不会自动重发"
                )
            }
        }
        if phoneIsReachable,
           !isReachable,
           connectionPath != .internet,
           !voiceUsesInternet {
            stopAllInteractions(sendReleaseMessages: false)
        }
        phoneIsReachable = isReachable
        if isReachable {
            issueText = nil
        } else if internetIsReady {
            connectionPath = .internet
        } else {
            requestInternetStatus()
        }
    }

    private func sendVoiceStopForCurrentStream() {
        guard let voiceStreamID, let voiceProfileRevision else { return }
        if voiceIntent == .codexTask || voiceIntent == .codexConversation {
            abortCodexCapture()
            return
        }
        if voiceUsesInternet {
            sendInternetVoiceStop(
                streamID: voiceStreamID,
                profileRevision: voiceProfileRevision,
                intent: voiceIntent,
                identity: voiceCodexTaskIdentity,
                finalSequence: audioAckTracker.contiguousThrough
            )
        } else {
            sendControlMessage(
                WatchRemoteProtocol.voiceStopMessage(
                    streamID: voiceStreamID,
                    profileRevision: voiceProfileRevision,
                    intent: voiceIntent,
                    codexTaskIdentity: voiceCodexTaskIdentity,
                    codexConversationTarget: voiceCodexConversationTarget,
                    finalSequence: nextAudioSequence == 0 ? nil : nextAudioSequence - 1
                ),
                reportsErrors: false
            )
        }
    }

    private func cancelPendingVoiceStart(sendStopMessage: Bool) {
        guard isVoiceStartPending else { return }
        let requestID = voiceRequestID
        let streamID = voiceStreamID
        let profileRevision = voiceProfileRevision
        if sendStopMessage {
            sendVoiceStopForCurrentStream()
        }
        voiceStartTimeoutTask?.cancel()
        voiceStartTimeoutTask = nil
        if let streamID, let profileRevision {
            _ = voiceStartHandshake.cancel(
                requestID: requestID,
                streamID: streamID,
                profileRevision: profileRevision
            )
        } else {
            voiceStartHandshake.invalidate()
        }
        isVoiceStartPending = false
        voiceRequestID &+= 1
        clearVoiceStream()
    }

    private func invalidateLiveStatus() {
        cancelHealthyStatusRefresh()
        statusHandshake.invalidate()
        hasFreshStatus = false
    }

    private func applyFreshStatus(_ status: WatchRemoteStatus) {
        hasFreshStatus = statusHandshake.hasFreshStatus
        applyStatus(status)
        if localIsReady {
            if heldCommandRevisions.isEmpty,
               !isVoiceActive,
               !isVoiceStartPending,
               !isVoiceFinalizing {
                connectionPath = .local
            }
            cancelStatusRetry(resetAttempt: true)
            scheduleHealthyStatusRefreshIfNeeded()
            scheduleCodexConversationLeaseRefresh()
            if codexCatalogStartupGate.consumeReadyStatus(
                routeIsReady: privateCodexConversationRouteIsReady,
                sceneIsActive: isSceneActive
            ) {
                requestCodexConversationCatalog()
            }
        } else {
            invalidateCodexConversationRouteState(
                detail: status.isMacConnected
                    ? "Codex 私有通道尚未就绪"
                    : "Mac 私有通道未连接"
            )
            cancelHealthyStatusRefresh()
            requestInternetStatus()
            scheduleStatusRetryIfNeeded()
        }
    }

    private func cancelStatusRetry(resetAttempt: Bool) {
        statusRetryTask?.cancel()
        statusRetryTask = nil
        if resetAttempt { statusRetryCursor.reset() }
    }

    private func scheduleStatusRetryIfNeeded() {
        guard isSceneActive,
              !localIsReady,
              !internetIsReady,
              statusRetryTask == nil
        else { return }
        guard let delay = statusRetryCursor.nextDelay() else { return }
        statusRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled, isSceneActive else { return }
            statusRetryTask = nil
            if session.activationState != .activated {
                start()
                if session.activationState != .activated {
                    scheduleStatusRetryIfNeeded()
                }
            } else if session.isReachable {
                requestStatus()
            } else {
                refreshReachability()
                requestInternetStatus()
                scheduleStatusRetryIfNeeded()
            }
        }
    }

    private func cancelHealthyStatusRefresh() {
        healthyStatusRefreshTask?.cancel()
        healthyStatusRefreshTask = nil
    }

    private func cancelInternetStatusTask() {
        internetStatusTaskGeneration &+= 1
        internetStatusTask?.cancel()
        internetStatusTask = nil
    }

    private func scheduleHealthyStatusRefreshIfNeeded() {
        guard isSceneActive,
              localIsReady || internetIsReady,
              !hasInternetVoiceTransportWork,
              healthyStatusRefreshTask == nil
        else { return }
        healthyStatusRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(
                for: .seconds(WatchConnectivityRecoveryPolicy.healthyStatusRefreshInterval)
            )
            guard let self, !Task.isCancelled, isSceneActive,
                  localIsReady || internetIsReady else { return }
            healthyStatusRefreshTask = nil
            if connectionPath == .internet {
                requestInternetStatus()
            } else {
                requestStatus(preservingCurrentStatus: true)
            }
        }
    }

    private func clearVoiceStream() {
        voiceDurationLimitTask?.cancel()
        voiceDurationLimitTask = nil
        voiceFinalAckTimeoutTask?.cancel()
        voiceFinalAckTimeoutTask = nil
        isVoiceFinalizing = false
        audioMailbox.clear()
        audioAckTracker.clear()
        voiceStreamID = nil
        voiceProfileRevision = nil
        nextAudioSequence = 0
        internetAudioBatch.removeAll(keepingCapacity: false)
        internetAudioBatchStartSequence = nil
        internetAudioFlushTask?.cancel()
        internetAudioFlushTask = nil
        internetAudioFinalFlushRequested = false
        voiceUsesInternet = false
        voiceIntent = .foregroundDictation
        voiceCodexTaskIdentity = nil
        voiceCodexConversationTarget = nil
        reconcilePreferredConnectionPathIfIdle()
        Task { @MainActor [weak self] in self?.reconcileDeferredCodexCatalog() }
    }

    private func reconcileDeferredCodexCatalog() {
        guard codexCatalogMaintenance.mayResume(
                isSceneActive: isSceneActive,
                voiceIsBusy: isCodexVoiceInteractionInProgress
              ),
              let catalog = codexConversationCatalog else { return }
        applyCodexConversationCatalog(catalog)
    }

    private func scheduleCodexVoiceDurationLimit(
        streamID: UUID,
        intent: WatchVoiceIntent
    ) {
        voiceDurationLimitTask?.cancel()
        voiceDurationLimitTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(120))
            guard let self,
                  !Task.isCancelled,
                  self.voiceStreamID == streamID,
                  self.voiceIntent == intent,
                  self.isVoiceActive
            else { return }
            self.voiceDurationLimitTask = nil
            self.abortCodexCapture(failureText: "录音超过两分钟，已停止并丢弃；请分段重录")
        }
    }

    private func reconcilePreferredConnectionPathIfIdle() {
        guard heldCommandRevisions.isEmpty,
              directHeldCommands.isEmpty,
              directSingleClickTasks.isEmpty,
              directLongPressTasks.isEmpty,
              directSendTasks.isEmpty,
              !hasPendingInternetButtonInteraction,
              !isVoiceStartPending,
              !isVoiceActive,
              !isVoiceFinalizing
        else { return }
        if directBridge.isReady {
            connectionPath = .direct
        } else if localIsReady {
            connectionPath = .local
        } else if internetIsReady {
            connectionPath = .internet
        } else {
            connectionPath = .offline
        }
    }

    private var hasPendingInternetButtonInteraction: Bool {
        internetButtonTask != nil
            || !internetButtonQueue.isEmpty
            || !internetSingleClickCommitTasks.isEmpty
            || !internetLongPressCommitTasks.isEmpty
    }

    private func applyStatus(_ status: WatchRemoteStatus) {
        if connectionPath == .internet {
            remoteStatus = status
            return
        }
        let previousVoiceOwner = remoteStatus.voiceOwner
        let shouldResetInteractions = status.requiresInteractionReset(from: remoteStatus)
        if shouldResetInteractions {
            stopAllInteractions(sendReleaseMessages: session.isReachable)
        }
        remoteStatus = status
        if previousVoiceOwner == .watch,
                  status.voiceOwner != .watch,
                  (isVoiceActive || isVoiceFinalizing) {
            voiceRequestID &+= 1
            voiceGestureIsHeld = false
            if isVoiceFinalizing {
                completeVoiceFinalization(sendStopMessage: false, failureText: nil)
            } else {
                endVoice(sendStopMessage: false)
            }
            issueText = status.detail ?? "Mac 已结束手表语音"
        } else if status.voiceOwner == .watch,
                  !isVoiceActive,
                  !isVoiceFinalizing,
                  !voiceGestureIsHeld,
                  session.isReachable,
                  voiceStreamID != nil {
            sendVoiceStopForCurrentStream()
            clearVoiceStream()
        }
    }

    private func applyCodexTask(
        _ snapshot: WatchCodexTaskSnapshot,
        stateRevision: Int
    ) {
        guard CodexThreadIdentifier.isValid(snapshot.threadID),
              snapshot.revision >= 0,
              stateRevision >= 0,
              !snapshot.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        guard stateRevision >= lastAppliedCodexTaskRevision else { return }
        if stateRevision == lastAppliedCodexTaskRevision {
            guard codexTaskSnapshot == snapshot else { return }
            return
        }
        lastAppliedCodexTaskRevision = stateRevision

        let newIdentity = WatchCodexTaskIdentity(snapshot)
        let inFlightCodexIdentity = voiceCodexTaskIdentity ?? awaitingVoiceOutcomeIdentity
        if let inFlightCodexIdentity,
           inFlightCodexIdentity != newIdentity {
            voiceGestureIsHeld = false
            if isVoiceStartPending {
                cancelPendingVoiceStart(sendStopMessage: canSendVoiceStopForCurrentPath)
            } else if isVoiceActive {
                voiceRequestID &+= 1
                endVoice(sendStopMessage: canSendVoiceStopForCurrentPath)
            } else if isVoiceFinalizing {
                completeVoiceFinalization(
                    sendStopMessage: canSendVoiceStopForCurrentPath,
                    failureText: nil
                )
            }
            awaitingVoiceOutcomeSessionID = nil
            awaitingVoiceOutcomeIdentity = nil
            voiceOutcomeTimeoutTask?.cancel()
            voiceOutcomeTimeoutTask = nil
            codexVoiceStatusText = "任务已更新，旧录音已拒绝"
        }
        codexTaskSnapshot = snapshot
        if codexDraftIdentity != nil, codexDraftIdentity != newIdentity {
            codexVoiceStatusText = "任务已更新，旧草稿已保留但不会发送"
        }
        guard snapshot.state == .completed,
              let identity = newIdentity
        else { return }

        let notificationToken = Self.codexTurnNotificationToken(identity)
        var notifiedTurns = UserDefaults.standard.stringArray(
            forKey: Self.notifiedCodexTurnsKey
        )?.filter { $0.hasPrefix("v2:") } ?? []
        guard !notifiedTurns.contains(notificationToken) else { return }
        notifiedTurns.append(notificationToken)
        if notifiedTurns.count > Self.maxNotifiedCodexTurns {
            notifiedTurns.removeFirst(notifiedTurns.count - Self.maxNotifiedCodexTurns)
        }
        UserDefaults.standard.set(notifiedTurns, forKey: Self.notifiedCodexTurnsKey)
        if isSceneActive {
            WatchHaptics.play(.success)
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "Codex 任务完成"
        content.body = "任务已完成，打开 App 查看结果"
        content.sound = .default
        content.userInfo = [:]
        let request = UNNotificationRequest(
            identifier: "codex-\(UUID().uuidString)",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.2, repeats: false)
        )
        UNUserNotificationCenter.current().add(request)
    }

    private func applyVoiceOutcome(_ outcome: WatchVoiceOutcome) {
        guard outcome.sessionID == awaitingVoiceOutcomeSessionID else { return }
        let expectedIdentity = awaitingVoiceOutcomeIdentity
        let expectedConversationTarget = awaitingVoiceOutcomeConversationTarget
        let matchesExpectedTarget: Bool
        switch outcome.intent {
        case .foregroundDictation:
            matchesExpectedTarget = expectedIdentity == nil
                && expectedConversationTarget == nil
                && !outcome.hasCodexTaskIdentityFields
                && !outcome.hasCodexConversationDraftFields
        case .codexTask:
            matchesExpectedTarget = expectedIdentity != nil
                && expectedConversationTarget == nil
                && outcome.codexTaskIdentity == expectedIdentity
                && !outcome.hasCodexConversationDraftFields
        case .codexConversation:
            guard let expectedConversationTarget else {
                matchesExpectedTarget = false
                break
            }
            matchesExpectedTarget = expectedIdentity == nil
                && !outcome.hasCodexTaskIdentityFields
                && (outcome.kind != .draft
                    || outcome.codexConversationDraftLease?.target
                        == expectedConversationTarget)
        }
        guard matchesExpectedTarget
        else {
            awaitingVoiceOutcomeSessionID = nil
            awaitingVoiceOutcomeIdentity = nil
            awaitingVoiceOutcomeConversationTarget = nil
            voiceOutcomeTimeoutTask?.cancel()
            voiceOutcomeTimeoutTask = nil
            codexVoiceStatusText = "识别结果身份不匹配，已拒绝"
            WatchHaptics.play(.failure)
            return
        }
        if isVoiceActive,
           voiceStreamID?.uuidString == outcome.sessionID {
            voiceRequestID &+= 1
            voiceGestureIsHeld = false
            endVoice(
                sendStopMessage: voiceUsesInternet
                    ? false
                    : canSendVoiceStopForCurrentPath
            )
        }
        awaitingVoiceOutcomeSessionID = nil
        awaitingVoiceOutcomeIdentity = nil
        awaitingVoiceOutcomeConversationTarget = nil
        voiceOutcomeTimeoutTask?.cancel()
        voiceOutcomeTimeoutTask = nil
        switch outcome.kind {
        case .draft:
            let text = outcome.text?.trimmingCharacters(in: .whitespacesAndNewlines)
            switch outcome.intent {
            case .codexTask:
                guard let identity = outcome.codexTaskIdentity,
                      identity == WatchCodexTaskIdentity(codexTaskSnapshot),
                      let text,
                      !text.isEmpty
                else {
                    codexVoiceStatusText = "任务已更新，旧录音结果已拒绝"
                    WatchHaptics.play(.failure)
                    return
                }
                codexReplyDraft = text
                codexDraftIdentity = identity
                codexDraftSubmissionID = UUID()
            case .codexConversation:
                guard let lease = outcome.codexConversationDraftLease,
                      lease.target == selectedCodexTarget,
                      !lease.isExpired(atEpochMilliseconds: Self.nowEpochMilliseconds),
                      let text,
                      let draft = WatchCodexConversationDraft(
                          text: text,
                          draftID: lease.draftID,
                          target: lease.target,
                          submissionID: UUID(),
                          expiresAtEpochMilliseconds: lease.expiresAtEpochMilliseconds
                      )
                else {
                    codexVoiceStatusText = "草稿身份或目标不匹配，已拒绝"
                    WatchHaptics.play(.failure)
                    return
                }
                codexConversationDraft = draft
                selectedCodexTarget = draft.target
            case .foregroundDictation:
                codexVoiceStatusText = "识别结果类型无效，已拒绝"
                WatchHaptics.play(.failure)
                return
            }
            persistCodexDrafts()
            codexVoiceStatusText = "中文 · \(outcome.localeIdentifier)"
            WatchHaptics.play(.success)
        case .delivered:
            switch outcome.intent {
            case .codexTask:
                codexVoiceStatusText = outcome.detail ?? "已排入 Codex 任务，等待处理"
            case .codexConversation:
                codexVoiceStatusText = outcome.detail ?? "已排入所选任务，等待处理"
            case .foregroundDictation:
                codexVoiceStatusText = "已输入 · \(outcome.localeIdentifier)"
            }
            WatchHaptics.play(.success)
        case .failed:
            let detail = outcome.detail ?? "语音没有发送到 Codex"
            codexVoiceStatusText = detail
            issueText = detail
            WatchHaptics.play(.failure)
        }
    }

    private func clearCodexTask(stateRevision: Int) {
        guard stateRevision >= 0,
              stateRevision >= lastAppliedCodexTaskRevision
        else { return }
        if stateRevision == lastAppliedCodexTaskRevision {
            guard codexTaskSnapshot == nil else { return }
            return
        }
        lastAppliedCodexTaskRevision = stateRevision
        if voiceIntent == .codexTask {
            voiceGestureIsHeld = false
            if isVoiceStartPending {
                cancelPendingVoiceStart(sendStopMessage: canSendVoiceStopForCurrentPath)
            } else if isVoiceActive {
                voiceRequestID &+= 1
                endVoice(sendStopMessage: canSendVoiceStopForCurrentPath)
            } else if isVoiceFinalizing {
                completeVoiceFinalization(
                    sendStopMessage: canSendVoiceStopForCurrentPath,
                    failureText: nil
                )
            }
        }
        codexTaskSnapshot = nil
        if awaitingVoiceOutcomeIdentity != nil {
            awaitingVoiceOutcomeSessionID = nil
            awaitingVoiceOutcomeIdentity = nil
            voiceOutcomeTimeoutTask?.cancel()
            voiceOutcomeTimeoutTask = nil
        }
        if codexReplyDraft != nil {
            codexVoiceStatusText = "Codex 任务暂不可用，草稿已保留"
        }
    }

    private func restoreCodexDraft() {
        let defaults = UserDefaults.standard
        let legacyData = defaults.data(forKey: Self.persistedCodexDraftKey)
        var persisted: PersistedCodexDrafts
        switch WatchCodexDraftStore.load(PersistedCodexDrafts.self) {
        case let .loaded(value):
            persisted = value
            isCodexDraftStoreReady = true
        case .notFound:
            persisted = PersistedCodexDrafts(task: nil, conversation: nil)
            isCodexDraftStoreReady = true
        case .unavailable:
            isCodexDraftStoreReady = false
            codexVoiceStatusText = "受保护草稿暂不可读；请解锁 Apple Watch 后重试"
            return
        }
        if let legacyData,
           let legacy = try? JSONDecoder().decode(
               PersistedCodexTaskDraft.self,
               from: legacyData
           ),
           !legacy.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           persisted.task == nil {
            persisted.task = legacy
            if WatchCodexDraftStore.save(persisted) {
                defaults.removeObject(forKey: Self.persistedCodexDraftKey)
            } else {
                isCodexDraftStoreReady = false
                codexVoiceStatusText = "旧草稿无法写入受保护存储；已停止迁移以避免丢失"
                return
            }
        } else if legacyData != nil {
            defaults.removeObject(forKey: Self.persistedCodexDraftKey)
        }

        if let task = persisted.task,
           !task.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            codexReplyDraft = task.text
            codexDraftIdentity = task.identity
            codexDraftSubmissionID = task.submissionID
        }
        if let conversation = persisted.conversation {
            codexConversationDraft = conversation
            selectedCodexTarget = conversation.target
        }
        if persisted.task != nil || persisted.conversation != nil {
            codexVoiceStatusText = persisted.conversation?.isExpired(
                atEpochMilliseconds: Self.nowEpochMilliseconds
            ) == true
                ? "已恢复受保护草稿，但发送授权已过期"
                : "已恢复上次未确认发送的草稿"
        }
    }

    private func persistCodexDraft() {
        persistCodexDrafts()
    }

    private func persistCodexDrafts() {
        guard isCodexDraftStoreReady else {
            codexVoiceStatusText = "受保护草稿尚未恢复；为避免覆盖，当前不会写入"
            return
        }
        UserDefaults.standard.removeObject(forKey: Self.persistedCodexDraftKey)
        let task: PersistedCodexTaskDraft?
        if let text = codexReplyDraft,
           let identity = codexDraftIdentity,
           let submissionID = codexDraftSubmissionID {
            task = PersistedCodexTaskDraft(
                text: text,
                identity: identity,
                submissionID: submissionID
            )
        } else {
            task = nil
        }
        let persisted = PersistedCodexDrafts(
            task: task,
            conversation: codexConversationDraft
        )
        if persisted.task == nil, persisted.conversation == nil {
            if !WatchCodexDraftStore.delete() {
                isCodexDraftStoreReady = false
                codexVoiceStatusText = "无法安全更新草稿存储；请解锁后重试"
            }
        } else if !WatchCodexDraftStore.save(persisted) {
            isCodexDraftStoreReady = false
            codexVoiceStatusText = "无法安全保存草稿；请保持 App 打开"
        }
    }

    private func applyCodexConversationCatalog(_ catalog: WatchCodexConversationCatalog) {
        defer { scheduleCodexConversationLeaseRefresh() }
        switch WatchCodexConversationCatalogAcceptancePolicy.disposition(
            current: codexConversationCatalog,
            candidate: catalog
        ) {
        case .install:
            break
        case .unchanged:
            break // Reconcile a lease refresh deferred until voice completes.
        case .rejectRevisionRollback:
            codexVoiceStatusText = "已拒绝过期的会话目录"
            return
        case .rejectRevisionConflict:
            codexVoiceStatusText = "会话目录版本冲突，请重新连接私有链路"
            return
        }

        if let pending = pendingCodexConversationTarget,
           !catalog.entries.contains(where: { $0.target == pending && $0.canAcceptInput }) {
            codexConversationTargetTimeoutTask?.cancel()
            codexConversationTargetTimeoutTask = nil
            codexConversationTargetRequestID = nil
            pendingCodexConversationTarget = nil
            codexVoiceStatusText = "会话列表已更新，请重新选择发送目标"
        }

        let previousTarget = selectedCodexTarget
        codexConversationCatalog = catalog
        // Keep the visible destination bound to this capture/receipt. The
        // current catalog is reconciled again once the receipt is cleared.
        guard codexCatalogMaintenance.mayUpdateSelection(
            voiceIsBusy: isCodexVoiceInteractionInProgress
        ) else { return }
        guard codexConversationDraft == nil else {
            selectedCodexTarget = codexConversationDraft?.target
            return
        }
        guard let previousTarget else {
            if codexVoiceStatusText == nil, catalog.entries.isEmpty {
                codexVoiceStatusText = "Mac 暂无可用会话"
            }
            return
        }
        if catalog.entries.contains(where: { $0.target == previousTarget }) {
            selectedCodexTarget = previousTarget
            return
        }
        guard let replacement = catalog.entries.first(where: {
            Self.targetsSameDestination($0.target, previousTarget)
                && $0.canAcceptInput
        })?.target else {
            selectedCodexTarget = nil
            codexVoiceStatusText = "已选会话不再可用，请重新选择"
            return
        }
        // Renew only a capability for the already selected, exact thread and
        // workspace in this Mac epoch. No task creation, pin change or network
        // side effect is needed, and the delivery result must stay visible.
        selectedCodexTarget = WatchCodexConversationSelectionResolution.permitsLeaseRenewal(
            current: previousTarget, replacement: replacement,
            nowEpochMilliseconds: Self.nowEpochMilliseconds
        ) ? replacement : nil
    }

    private func invalidateCodexConversationRouteState(detail: String) {
        codexConversationCatalogRequestTimeoutTask?.cancel()
        codexConversationCatalogRequestTimeoutTask = nil
        codexConversationCatalogRequestID = nil
        isCodexConversationCatalogLoading = false
        codexConversationTargetTimeoutTask?.cancel()
        codexConversationTargetTimeoutTask = nil
        codexConversationTargetRequestID = nil
        pendingCodexConversationTarget = nil
        codexConversationLeaseRefreshTask?.cancel()
        codexConversationLeaseRefreshTask = nil
        codexConversationCatalog = nil
        selectedCodexTarget = codexConversationDraft?.target
        if codexConversationDraft != nil,
           isCodexReplySubmitting,
           !codexReplyUsesInternet {
            codexReplySubmitTask?.cancel()
            codexReplySubmitTask = nil
            codexReplySubmitID &+= 1
            isCodexReplySubmitting = false
        }
        codexVoiceStatusText = detail
    }

    private func scheduleCodexConversationLeaseRefresh() {
        codexConversationLeaseRefreshTask?.cancel()
        codexConversationLeaseRefreshTask = nil
        guard isSceneActive,
              privateCodexConversationRouteIsReady,
              codexConversationDraft == nil,
              !isCodexVoiceInteractionInProgress,
              let earliestExpiry = codexConversationCatalog?.entries
                .map(\.target.expiresAtEpochMilliseconds)
                .min()
        else { return }

        let refreshAt = earliestExpiry - 60_000
        let delayMilliseconds = max(refreshAt - Self.nowEpochMilliseconds, 1_000)
        codexConversationLeaseRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(delayMilliseconds))
            guard let self,
                  !Task.isCancelled,
                  isSceneActive,
                  privateCodexConversationRouteIsReady,
                  codexConversationDraft == nil,
                  !isCodexVoiceInteractionInProgress
            else { return }
            codexConversationLeaseRefreshTask = nil
            requestCodexConversationCatalog()
        }
    }

    private func isValidResolvedTarget(
        _ resolvedTarget: WatchCodexConversationTarget,
        for submittedTarget: WatchCodexConversationTarget
    ) -> Bool {
        submittedTarget.kind == .existing
            && resolvedTarget == submittedTarget
            && !resolvedTarget.isExpired(atEpochMilliseconds: Self.nowEpochMilliseconds)
    }

    private static func targetsSameDestination(
        _ lhs: WatchCodexConversationTarget,
        _ rhs: WatchCodexConversationTarget
    ) -> Bool {
        guard lhs.serverEpoch == rhs.serverEpoch, lhs.kind == rhs.kind else { return false }
        switch lhs.kind {
        case .existing:
            return lhs.threadID == rhs.threadID
        case .newConversation:
            return lhs.workspaceID == rhs.workspaceID
        }
    }

    private func applyApplicationContext(_ context: [String: Any]) {
        applyDirectBridgeConfiguration(context)
        if WatchRemoteProtocol.isInternetRelayProvisioningCleared(in: context) {
            removeInternetProvisioning()
        } else if let provisioning = WatchRemoteProtocol.internetRelayProvisioning(from: context) {
            applyInternetProvisioning(provisioning)
        }
        if let status = WatchRemoteProtocol.status(from: context) {
            applyStatus(status)
        }
        if let receivedFavorites = WatchRemoteProtocol.favorites(from: context) {
            favorites = receivedFavorites
            UserDefaults.standard.set(
                receivedFavorites.map(\.rawValue),
                forKey: Self.favoritesDefaultsKey
            )
        }
        if let update = WatchRemoteProtocol.codexTaskUpdate(from: context) {
            switch update {
            case let .snapshot(snapshot, stateRevision):
                applyCodexTask(snapshot, stateRevision: stateRevision)
            case let .cleared(stateRevision):
                clearCodexTask(stateRevision: stateRevision)
            }
        }
        if let outcome = WatchRemoteProtocol.voiceOutcome(from: context) {
            applyVoiceOutcome(outcome)
        }
        if let catalog = WatchRemoteProtocol.codexConversationCatalogSnapshot(
            from: context
        )?.catalog {
            applyCodexConversationCatalog(catalog)
        }
    }

    private func applyInternetProvisioning(
        _ provisioning: WristInternetRelayDeviceProvisioning
    ) {
        guard WristInternetRelayConfiguration.isEnabledForCurrentBuild else {
            removeInternetProvisioning()
            return
        }
        guard provisioning.isValid, provisioning != internetProvisioning else { return }
        guard WristInternetRelayKeychain.save(
            provisioning,
            account: Self.internetRelayKeychainAccount,
            service: Self.internetRelayKeychainService
        ) else {
            issueText = "无法安全保存公网遥控凭证"
            return
        }
        guard WatchInternetRelayClearMarker.setCleared(false).fullySucceeded else {
            _ = WatchInternetRelayClearMarker.setCleared(true)
            _ = WristInternetRelayKeychain.delete(
                account: Self.internetRelayKeychainAccount,
                service: Self.internetRelayKeychainService
            )
            issueText = "无法安全解除公网遥控撤销状态"
            return
        }

        internetProvisioningGeneration &+= 1
        internetVoiceStartTask?.cancel()
        internetVoiceStartTask = nil
        internetVoiceStartTaskStreamID = nil
        cancelInternetStatusTask()
        internetButtonTask?.cancel()
        internetButtonTask = nil
        internetButtonQueue.removeAll(keepingCapacity: false)
        cancelAllInternetButtonGestures()
        let internetHeldCommands = heldCommandUsesInternet.compactMap { command, usesInternet in
            usesInternet ? command : nil
        }
        for command in internetHeldCommands {
            heldCommandRevisions.removeValue(forKey: command)
            heldCommandUsesInternet.removeValue(forKey: command)
        }
        if voiceUsesInternet {
            voiceRequestID &+= 1
            voiceGestureIsHeld = false
            stopAllInteractions(sendReleaseMessages: false)
        }
        if codexReplyUsesInternet {
            codexReplySubmitTask?.cancel()
            codexReplySubmitTask = nil
            codexReplySubmitID &+= 1
            isCodexReplySubmitting = false
            codexReplyUsesInternet = false
            codexVoiceStatusText = "公网凭证已更新，草稿已保留，请重新发送"
        }
        internetProvisioning = provisioning
        internetClient = WristInternetRelayHTTPClient(provisioning: provisioning)
        internetRemoteStatus = nil
        internetButtonTriggers.removeAll(keepingCapacity: false)
        internetStatusReceivedAt = nil
        reconcilePreferredConnectionPathIfIdle()
        if isSceneActive { requestInternetStatus() }
    }

    private func removeInternetProvisioning() {
        let hadProvisioning = internetProvisioning != nil || internetClient != nil
        // Persist the non-sensitive revocation marker before touching the
        // credential. UserDefaults protects ordinary restarts; the separate
        // Keychain marker also survives an uninstall/reinstall that keeps the
        // credential Keychain item.
        let clearMarkerResult = WatchInternetRelayClearMarker.setCleared(true)
        internetProvisioningGeneration &+= 1
        internetVoiceStartTask?.cancel()
        internetVoiceStartTask = nil
        internetVoiceStartTaskStreamID = nil
        cancelInternetStatusTask()
        internetButtonTask?.cancel()
        internetButtonTask = nil
        internetButtonQueue.removeAll(keepingCapacity: false)
        cancelAllInternetButtonGestures()

        if voiceUsesInternet {
            voiceRequestID &+= 1
            voiceGestureIsHeld = false
            stopAllInteractions(sendReleaseMessages: false)
        }
        if awaitingVoiceOutcomeUsesInternet {
            voiceOutcomeTimeoutTask?.cancel()
            voiceOutcomeTimeoutTask = nil
            awaitingVoiceOutcomeSessionID = nil
            awaitingVoiceOutcomeIdentity = nil
            awaitingVoiceOutcomeConversationTarget = nil
        }

        if codexReplyUsesInternet {
            codexReplySubmitTask?.cancel()
            codexReplySubmitTask = nil
            codexReplySubmitID &+= 1
            isCodexReplySubmitting = false
            codexReplyUsesInternet = false
            codexVoiceStatusText = "公网 Relay 已移除，草稿仍保留"
        }

        internetProvisioning = nil
        internetClient = nil
        internetRemoteStatus = nil
        internetButtonTriggers.removeAll(keepingCapacity: false)
        internetStatusReceivedAt = nil
        let deletedProvisioning = WristInternetRelayKeychain.delete(
            account: Self.internetRelayKeychainAccount,
            service: Self.internetRelayKeychainService
        )
        reconcilePreferredConnectionPathIfIdle()
        if !clearMarkerResult.keychainSucceeded && !deletedProvisioning {
            issueText = "无法确认公网 Relay 凭证已撤销；当前会话已禁用该路径"
        } else if hadProvisioning, !localIsReady {
            issueText = "公网 Relay 已移除；请通过 iPhone 与私有网络连接 Mac"
        }
    }

    private static func persistedFavorites() -> [WatchRemoteCommand]? {
        guard let rawFavorites = UserDefaults.standard.stringArray(
            forKey: favoritesDefaultsKey
        ) else { return nil }
        return WatchRemoteProtocol.favorites(from: [
            WatchRemoteProtocol.Key.favorites.rawValue: rawFavorites,
        ])
    }

    private static func codexTurnNotificationToken(
        _ identity: WatchCodexTaskIdentity
    ) -> String {
        let canonical = "\(identity.threadID.utf8.count)#\(identity.threadID)"
            + "\(identity.turnID.utf8.count)#\(identity.turnID)"
        let digest = SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "v2:\(digest)"
    }

    private static let internetRelayKeychainAccount = "device-provisioning-v1"
    private static var nowEpochMilliseconds: Int64 {
        Int64((Date().timeIntervalSince1970 * 1_000).rounded())
    }

    private static var internetRelayKeychainService: String {
        "\(Bundle.main.bundleIdentifier ?? "dev.wristremote.watch").internet-relay"
    }
}

extension WatchSessionController: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.activationRequestInFlight = false
            self.activationState = activationState
            self.refreshReachability()
            if error != nil {
                self.issueText = "无法连接 iPhone"
                self.scheduleStatusRetryIfNeeded()
            } else if activationState == .activated {
                self.applyApplicationContext(session.receivedApplicationContext)
                self.requestStatus()
                self.requestCodexConversationCatalog()
            }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.refreshReachability()
            if self.phoneIsReachable {
                self.cancelStatusRetry(resetAttempt: true)
                self.requestStatus()
                self.requestCodexConversationCatalog()
            } else {
                self.scheduleStatusRetryIfNeeded()
            }
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any]
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if session.activationState == .activated,
               session.isReachable,
               let status = self.statusHandshake.acceptLivePush(message) {
                self.statusRequestTimeoutTask?.cancel()
                self.statusRequestTimeoutTask = nil
                self.issueText = nil
                self.applyFreshStatus(status)
            }
            if let receivedFavorites = WatchRemoteProtocol.favorites(from: message) {
                self.favorites = receivedFavorites
            }
            if let update = WatchRemoteProtocol.codexTaskUpdate(from: message) {
                switch update {
                case let .snapshot(snapshot, stateRevision):
                    self.applyCodexTask(snapshot, stateRevision: stateRevision)
                case let .cleared(stateRevision):
                    self.clearCodexTask(stateRevision: stateRevision)
                }
            }
            if let outcome = WatchRemoteProtocol.voiceOutcome(from: message) {
                self.applyVoiceOutcome(outcome)
            }
            if let catalog = WatchRemoteProtocol.codexConversationCatalogSnapshot(
                from: message
            )?.catalog {
                self.applyCodexConversationCatalog(catalog)
            }
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        Task { @MainActor [weak self] in
            self?.applyApplicationContext(applicationContext)
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveUserInfo userInfo: [String: Any]
    ) {
        Task { @MainActor [weak self] in
            self?.applyApplicationContext(userInfo)
        }
    }
}

extension WatchSessionController: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        completionHandler()
        Task { @MainActor [weak self] in
            self?.requestStatus()
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
