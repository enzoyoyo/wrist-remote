import Foundation
@preconcurrency import WatchConnectivity
import WatchKit
import UserNotifications

enum WatchRemoteConnectionPath: Equatable {
    case local
    case internet
    case offline
}

@MainActor
final class WatchSessionController: NSObject, ObservableObject {
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
    @Published private(set) var codexVoiceStatusText: String?
    @Published private(set) var isCodexReplySubmitting = false
    @Published private(set) var connectionPath: WatchRemoteConnectionPath = .offline

    private let session: WCSession
    private let audioCapture: WatchAudioCapture
    private let audioMailbox = WatchRemoteAudioMailbox()
    private var heldCommandRevisions: [WatchRemoteCommand: Int] = [:]
    private var heldCommandUsesInternet: [WatchRemoteCommand: Bool] = [:]
    private var voiceGestureIsHeld = false
    private var voiceRequestID: UInt64 = 0
    private var voiceStartTimeoutTask: Task<Void, Never>?
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
    private var awaitingVoiceOutcomeSessionID: String?
    private var awaitingVoiceOutcomeIdentity: WatchCodexTaskIdentity?
    private var codexDraftIdentity: WatchCodexTaskIdentity?
    private var codexDraftSubmissionID: UUID?
    private var codexReplySubmitTask: Task<Void, Never>?
    private var codexReplySubmitID: UInt64 = 0
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

    private struct PersistedCodexDraft: Codable {
        let text: String
        let identity: WatchCodexTaskIdentity
        let submissionID: UUID
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
        let storedProvisioning = WristInternetRelayKeychain.load(
            WristInternetRelayDeviceProvisioning.self,
            account: Self.internetRelayKeychainAccount,
            service: Self.internetRelayKeychainService
        )
        internetProvisioning = storedProvisioning
        internetClient = storedProvisioning.map {
            WristInternetRelayHTTPClient(provisioning: $0)
        }
        favorites = initialFavorites
            ?? Self.persistedFavorites()
            ?? WatchRemoteCommand.defaultFavorites
        super.init()
        restoreCodexDraft()
    }

    var isReady: Bool {
        localIsReady || internetIsReady
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
        isReady
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
        guard codexReplyDraft == nil,
              codexTaskSnapshot?.state == .completed,
              WatchCodexTaskIdentity(codexTaskSnapshot) != nil
        else { return false }
        return canStartVoice
    }

    var isCodexVoiceInteractionInProgress: Bool {
        (voiceIntent == .codexTask
            && (voiceGestureIsHeld || isVoiceStartPending || isVoiceActive || isVoiceFinalizing))
            || awaitingVoiceOutcomeIdentity != nil
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

    var statusText: String {
        if voiceUsesInternet,
           (isVoiceStartPending || isVoiceActive || isVoiceFinalizing),
           internetRemoteStatus != nil {
            return "互联网 · \(effectiveRemoteStatus.macName)"
        }
        if localIsReady { return "局域网 · \(remoteStatus.macName)" }
        if internetIsReady { return "互联网 · \(effectiveRemoteStatus.macName)" }
        if internetStatusTask != nil { return "正在连接互联网" }
        if activationState != .activated { return "正在连接 iPhone" }
        if !phoneIsReachable, internetProvisioning == nil { return "iPhone 未连接" }
        if !hasFreshStatus { return "正在同步实时状态" }
        if !remoteStatus.isMacConnected { return "Mac 未连接" }
        if !remoteStatus.isActionProfileReady { return "独立映射未就绪" }
        return "暂时离线"
    }

    var statusDetail: String {
        if let issueText { return issueText }
        if let detail = effectiveRemoteStatus.detail, !detail.isEmpty {
            return detail
        }
        return isReady ? "按住语音键说话" : "请保持 Mac 开机并连接网络"
    }

    func title(for command: WatchRemoteCommand) -> String? {
        effectiveRemoteStatus.buttonTitles[command]
    }

    func start() {
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
        isSceneActive = true
        cancelHealthyStatusRefresh()
        cancelStatusRetry(resetAttempt: true)
        if internetProvisioning == nil,
           let recoveredProvisioning = WristInternetRelayKeychain.load(
               WristInternetRelayDeviceProvisioning.self,
               account: Self.internetRelayKeychainAccount,
               service: Self.internetRelayKeychainService
           ), recoveredProvisioning.isValid {
            applyInternetProvisioning(recoveredProvisioning)
        }
        start()
        requestStatus()
    }

    func sceneDidBecomeInactive() {
        isSceneActive = false
        cancelHealthyStatusRefresh()
        cancelStatusRetry(resetAttempt: false)
        statusRequestTimeoutTask?.cancel()
        statusRequestTimeoutTask = nil
        invalidateLiveStatus()
        if isCodexVoiceInteractionInProgress {
            cancelCodexVoiceGesture()
        }
        stopAllInteractions(sendReleaseMessages: session.isReachable || internetClient != nil)
    }

    func requestStatus(preservingCurrentStatus: Bool = false) {
        cancelHealthyStatusRefresh()
        guard session.activationState == .activated, session.isReachable else {
            invalidateLiveStatus()
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

    private func requestInternetStatus() {
        guard isSceneActive,
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
            codexTaskIdentity: nil
        )
    }

    func setCodexVoicePressed(_ isPressed: Bool) {
        if isPressed {
            guard canStartCodexVoice,
                  let identity = WatchCodexTaskIdentity(codexTaskSnapshot)
            else {
                codexVoiceStatusText = "任务完成后才能语音追问"
                return
            }
            setVoicePressed(true, intent: .codexTask, codexTaskIdentity: identity)
        } else {
            guard voiceIntent == .codexTask else { return }
            setVoicePressed(
                false,
                intent: .codexTask,
                codexTaskIdentity: voiceCodexTaskIdentity
            )
        }
    }

    func cancelCodexVoiceGesture() {
        guard isCodexVoiceInteractionInProgress else { return }
        if voiceIntent == .codexTask {
            setCodexVoicePressed(false)
        }
        voiceOutcomeTimeoutTask?.cancel()
        voiceOutcomeTimeoutTask = nil
        awaitingVoiceOutcomeSessionID = nil
        awaitingVoiceOutcomeIdentity = nil
        codexVoiceStatusText = "本次语音已取消"
        WatchHaptics.play(.click)
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

    private func setVoicePressed(
        _ isPressed: Bool,
        intent: WatchVoiceIntent,
        codexTaskIdentity: WatchCodexTaskIdentity?
    ) {
        issueText = nil
        if isPressed {
            guard !voiceGestureIsHeld,
                  !isVoiceStartPending,
                  !isVoiceActive,
                  !isVoiceFinalizing
            else { return }
            guard (intent == .foregroundDictation && codexTaskIdentity == nil)
                    || (intent == .codexTask
                        && codexTaskIdentity == WatchCodexTaskIdentity(codexTaskSnapshot))
            else { return }
            voiceIntent = intent
            voiceCodexTaskIdentity = codexTaskIdentity
            if intent == .codexTask { codexVoiceStatusText = "正在准备中文识别" }
            voiceGestureIsHeld = true
            guard canStartVoice else {
                voiceGestureIsHeld = false
                issueText = "语音需要先连接 Mac"
                return
            }
            WatchHaptics.play(.click)
            voiceRequestID &+= 1
            let requestID = voiceRequestID
            Task { @MainActor [weak self] in
                await self?.beginVoice(requestID: requestID)
            }
        } else {
            guard voiceGestureIsHeld || isVoiceActive || isVoiceStartPending else { return }
            voiceGestureIsHeld = false
            if isVoiceStartPending {
                cancelPendingVoiceStart(sendStopMessage: canSendVoiceStopForCurrentPath)
                return
            }
            voiceRequestID &+= 1
            endVoice(sendStopMessage: canSendVoiceStopForCurrentPath)
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
              (voiceIntent == .foregroundDictation
                  || voiceCodexTaskIdentity == WatchCodexTaskIdentity(codexTaskSnapshot))
        else { return }
        guard permitted else {
            if voiceIntent == .codexTask {
                codexVoiceStatusText = "请在手表设置中允许麦克风访问"
            }
            voiceGestureIsHeld = false
            voiceIntent = .foregroundDictation
            voiceCodexTaskIdentity = nil
            issueText = "请在手表设置中允许麦克风访问"
            return
        }

        requestVoiceStart(requestID: requestID)
    }

    private func requestVoiceStart(requestID: UInt64) {
        let usesInternet = !localIsReady && internetIsReady
        let selectedStatus = usesInternet ? internetRemoteStatus : remoteStatus
        guard (usesInternet || localIsReady),
              let profileRevision = selectedStatus?.profileRevision,
              profileRevision >= 0,
              (voiceIntent == .foregroundDictation
                  || voiceCodexTaskIdentity == WatchCodexTaskIdentity(codexTaskSnapshot))
        else {
            handleCommunicationFailure()
            return
        }

        let streamID = UUID()
        let intent = voiceIntent
        let identity = voiceCodexTaskIdentity
        let startMessage = WatchRemoteProtocol.voiceStartMessage(
            streamID: streamID,
            profileRevision: profileRevision,
            intent: intent,
            codexTaskIdentity: identity
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
                        codexTaskIdentity: identity
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
                    && response?.accepted == true
                Task { @MainActor in
                    self?.completeVoiceStart(
                        requestID: requestID,
                        streamID: streamID,
                        profileRevision: profileRevision,
                        expectedIntent: intent,
                        expectedCodexTaskIdentity: identity,
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
        accepted: Bool,
        failureText: String?
    ) {
        guard voiceRequestID == requestID,
              voiceStreamID == streamID,
              voiceProfileRevision == profileRevision,
              voiceIntent == expectedIntent,
              voiceCodexTaskIdentity == expectedCodexTaskIdentity,
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
            if expectedIntent == .codexTask {
                codexVoiceStatusText = failureText ?? "暂时无法使用手表麦克风"
            }
            WatchHaptics.play(.failure)
            return
        }

        guard voiceGestureIsHeld,
              voicePathIsReady(profileRevision: profileRevision),
              (expectedIntent == .foregroundDictation
                  || expectedCodexTaskIdentity == WatchCodexTaskIdentity(codexTaskSnapshot))
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
                        codexTaskIdentity: expectedCodexTaskIdentity
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
            if expectedIntent == .codexTask { codexVoiceStatusText = "正在听中文…" }
            WatchHaptics.play(.start)
            guard voiceRequestID == requestID,
                  voiceGestureIsHeld,
                  voicePathIsReady(profileRevision: profileRevision)
            else {
                endVoice(sendStopMessage: canSendVoiceStopForCurrentPath)
                return
            }
            awaitingVoiceOutcomeSessionID = streamID.uuidString
            awaitingVoiceOutcomeIdentity = expectedCodexTaskIdentity
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
                        codexTaskIdentity: expectedCodexTaskIdentity
                    ),
                    reportsErrors: false
                )
            }
            clearVoiceStream()
            issueText = "暂时无法使用手表麦克风"
            if expectedIntent == .codexTask {
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

    private func endVoice(sendStopMessage: Bool) {
        guard !isVoiceFinalizing else { return }
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
        if wasActive, intent == .codexTask {
            codexVoiceStatusText = "正在识别中文…"
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
        let streamID = voiceStreamID
        let profileRevision = voiceProfileRevision
        let intent = voiceIntent
        let identity = voiceCodexTaskIdentity
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
                : 13
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
            codexVoiceStatusText = "中文识别确认超时，请重试"
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
        let hadCodexVoice = isCodexVoiceInteractionInProgress || voiceIntent == .codexTask
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
        } else {
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
              !isReady,
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
              isReady,
              !hasInternetVoiceTransportWork,
              healthyStatusRefreshTask == nil
        else { return }
        healthyStatusRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(
                for: .seconds(WatchConnectivityRecoveryPolicy.healthyStatusRefreshInterval)
            )
            guard let self, !Task.isCancelled, isSceneActive, isReady else { return }
            healthyStatusRefreshTask = nil
            if connectionPath == .internet {
                requestInternetStatus()
            } else {
                requestStatus(preservingCurrentStatus: true)
            }
        }
    }

    private func clearVoiceStream() {
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
        reconcilePreferredConnectionPathIfIdle()
    }

    private func reconcilePreferredConnectionPathIfIdle() {
        guard heldCommandRevisions.isEmpty,
              !hasPendingInternetButtonInteraction,
              !isVoiceStartPending,
              !isVoiceActive,
              !isVoiceFinalizing
        else { return }
        if localIsReady {
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
        ) ?? []
        guard !notifiedTurns.contains(notificationToken) else { return }
        notifiedTurns.append(notificationToken)
        if notifiedTurns.count > Self.maxNotifiedCodexTurns {
            notifiedTurns.removeFirst(notifiedTurns.count - Self.maxNotifiedCodexTurns)
        }
        UserDefaults.standard.set(notifiedTurns, forKey: Self.notifiedCodexTurnsKey)
        WatchHaptics.play(.success)

        let content = UNMutableNotificationContent()
        content.title = "Codex 任务完成"
        content.body = snapshot.summary?.trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty ?? snapshot.title
        content.sound = .default
        content.userInfo = [
            "threadID": identity.threadID,
            "turnID": identity.turnID,
            "taskRevision": identity.revision,
        ]
        let request = UNNotificationRequest(
            identifier: "codex-\(notificationToken)",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.2, repeats: false)
        )
        UNUserNotificationCenter.current().add(request)
    }

    private func applyVoiceOutcome(_ outcome: WatchVoiceOutcome) {
        guard outcome.sessionID == awaitingVoiceOutcomeSessionID else { return }
        let expectedIdentity = awaitingVoiceOutcomeIdentity
        guard (outcome.intent == .foregroundDictation
                && expectedIdentity == nil
                && outcome.codexTaskIdentity == nil
                && !outcome.hasCodexTaskIdentityFields)
                || (outcome.intent == .codexTask
                    && expectedIdentity != nil
                    && outcome.codexTaskIdentity == expectedIdentity)
        else {
            awaitingVoiceOutcomeSessionID = nil
            awaitingVoiceOutcomeIdentity = nil
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
        voiceOutcomeTimeoutTask?.cancel()
        voiceOutcomeTimeoutTask = nil
        switch outcome.kind {
        case .draft:
            guard outcome.intent == .codexTask,
                  let identity = outcome.codexTaskIdentity,
                  identity == WatchCodexTaskIdentity(codexTaskSnapshot),
                  let text = outcome.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty
            else {
                codexVoiceStatusText = "任务已更新，旧录音结果已拒绝"
                WatchHaptics.play(.failure)
                return
            }
            codexReplyDraft = text
            codexDraftIdentity = identity
            codexDraftSubmissionID = UUID()
            persistCodexDraft()
            codexVoiceStatusText = "中文 · \(outcome.localeIdentifier)"
            WatchHaptics.play(.success)
        case .delivered:
            codexVoiceStatusText = outcome.intent == .codexTask
                ? "已发送给 Codex"
                : "已输入 · \(outcome.localeIdentifier)"
            WatchHaptics.play(.success)
        case .failed:
            let detail = outcome.detail ?? "中文识别没有结果"
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
        awaitingVoiceOutcomeSessionID = nil
        awaitingVoiceOutcomeIdentity = nil
        voiceOutcomeTimeoutTask?.cancel()
        voiceOutcomeTimeoutTask = nil
        if codexReplyDraft != nil {
            codexVoiceStatusText = "Codex 任务暂不可用，草稿已保留"
        }
    }

    private func restoreCodexDraft() {
        guard let data = UserDefaults.standard.data(forKey: Self.persistedCodexDraftKey),
              let persisted = try? JSONDecoder().decode(PersistedCodexDraft.self, from: data),
              !persisted.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        codexReplyDraft = persisted.text
        codexDraftIdentity = persisted.identity
        codexDraftSubmissionID = persisted.submissionID
        codexVoiceStatusText = "已恢复上次未确认发送的草稿"
    }

    private func persistCodexDraft() {
        guard let text = codexReplyDraft,
              let identity = codexDraftIdentity,
              let submissionID = codexDraftSubmissionID,
              let data = try? JSONEncoder().encode(PersistedCodexDraft(
                  text: text,
                  identity: identity,
                  submissionID: submissionID
              ))
        else {
            UserDefaults.standard.removeObject(forKey: Self.persistedCodexDraftKey)
            return
        }
        UserDefaults.standard.set(data, forKey: Self.persistedCodexDraftKey)
    }

    private func applyApplicationContext(_ context: [String: Any]) {
        if let provisioning = WatchRemoteProtocol.internetRelayProvisioning(from: context) {
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
    }

    private func applyInternetProvisioning(
        _ provisioning: WristInternetRelayDeviceProvisioning
    ) {
        guard provisioning.isValid, provisioning != internetProvisioning else { return }
        guard WristInternetRelayKeychain.save(
            provisioning,
            account: Self.internetRelayKeychainAccount,
            service: Self.internetRelayKeychainService
        ) else {
            issueText = "无法安全保存公网遥控凭证"
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
        "\(identity.threadID.utf8.count)#\(identity.threadID)"
            + "\(identity.turnID.utf8.count)#\(identity.turnID)"
    }

    private static let internetRelayKeychainAccount = "device-provisioning-v1"
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
