import Combine
import Foundation
@preconcurrency import WatchConnectivity
import UIKit

@MainActor
final class WatchRelayController: NSObject, ObservableObject {
    enum InternetProfileSyncState: Equatable {
        case unavailable
        case configured
        case syncing(Int)
        case verifying(Int)
        case ready(Int)
        case failed(String)
    }

    enum ProfileSyncRoute: Equatable {
        case none
        case local
        case internetUpdate
        case internetVerification
    }

    @Published private(set) var activationState: WCSessionActivationState = .notActivated
    @Published private(set) var isWatchPaired = false
    @Published private(set) var isWatchAppInstalled = false
    @Published private(set) var isWatchReachable = false
    @Published private(set) var isActionProfileReady = false
    @Published private(set) var internetProfileSyncState: InternetProfileSyncState = .unavailable
    @Published private(set) var lastErrorText: String?

    private let connection: WristBridgeConnection
    private let layoutSettings: WatchLayoutSettings
    private let actionProfileStore: WatchActionProfileStore
    private let session: WCSession?
    private var cancellables: Set<AnyCancellable> = []
    private var heldCommandRevisions: [WatchRemoteCommand: Int] = [:]
    private var releaseWatchdogs: [WatchRemoteCommand: Task<Void, Never>] = [:]
    private var voiceInactivityWatchdog: Task<Void, Never>?
    private var voiceStopDrainTask: Task<Void, Never>?
    private var pendingVoiceStop: (
        streamID: UUID,
        profileRevision: Int,
        finalSequence: UInt64?
    )?
    private var audioStreamGate = WatchRemoteAudioStreamGate()
    private var voiceRelayReservation = WatchRemoteVoiceRelayReservation()
    private var activeVoiceIntent: WatchVoiceIntent = .foregroundDictation
    private var activeVoiceCodexTaskIdentity: WatchCodexTaskIdentity?
    private var liveStatusReplyTask: Task<Void, Never>?
    private var liveStatusRequestID: UUID?
    private var liveStatusReplyHandler: (([String: Any]) -> Void)?
    private var liveStatusBackgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var activationRequestInFlight = false
    private var lastTransferredCodexCompletion: String?
    private var internetRelayClient: WristInternetRelayHTTPClient?
    private var internetProfileSyncTask: Task<Void, Never>?
    private var internetProfileRetryTask: Task<Void, Never>?
    private var internetProfileRetryCount = 0
    private var internetReadyRevision: Int?
    private var internetFailedRevision: Int?
    private var internetProvisioningGeneration = 0
    private var isSceneActive = false

    init(
        connection: WristBridgeConnection,
        layoutSettings: WatchLayoutSettings,
        actionProfileStore: WatchActionProfileStore,
        session: WCSession? = WCSession.isSupported() ? .default : nil
    ) {
        self.connection = connection
        self.layoutSettings = layoutSettings
        self.actionProfileStore = actionProfileStore
        self.session = session
        super.init()
        observeState()
    }

    func activate() {
        guard let session else {
            lastErrorText = "此 iPhone 不支持 Apple Watch 通信"
            return
        }
        session.delegate = self
        updateWatchProperties(from: session)
        if session.activationState == .activated {
            refreshStatus()
            return
        }
        let shouldActivate = WatchConnectivityRecoveryPolicy.shouldRequestActivation(
            isActivated: false,
            isInactive: session.activationState == .inactive,
            requestInFlight: activationRequestInFlight
        )
        if shouldActivate {
            activationRequestInFlight = true
            session.activate()
        }
    }

    func sceneDidBecomeActive() {
        isSceneActive = true
        internetProfileRetryTask?.cancel()
        internetProfileRetryTask = nil
        internetProfileRetryCount = 0
        internetFailedRevision = nil
        activate()
        syncWatchActionProfileIfPossible()
        publishStatus()
    }

    func sceneDidBecomeInactive() {
        isSceneActive = false
        internetProfileSyncTask?.cancel()
        internetProfileSyncTask = nil
        internetProfileRetryTask?.cancel()
        internetProfileRetryTask = nil
        internetFailedRevision = nil
        if internetRelayClient != nil { internetProfileSyncState = .configured }
    }

    func refreshStatus() {
        guard let session else { return }
        internetProfileRetryTask?.cancel()
        internetProfileRetryTask = nil
        internetProfileRetryCount = 0
        internetFailedRevision = nil
        updateWatchProperties(from: session)
        syncWatchActionProfileIfPossible()
        publishStatus()
    }

    private func observeState() {
        connection.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                if !connection.isConnected {
                    finishAllWatchInteractions(sendReleases: false)
                } else {
                    completeLiveStatusReplyIfNeeded()
                }
                internetProfileRetryTask?.cancel()
                internetProfileRetryTask = nil
                internetProfileRetryCount = 0
                internetFailedRevision = nil
                updateActionProfileReadiness()
                syncWatchActionProfileIfPossible()
                publishStatus()
            }
            .store(in: &cancellables)

        connection.$macName
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.publishStatus() }
            .store(in: &cancellables)

        connection.$voiceOwner
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.publishStatus() }
            .store(in: &cancellables)

        connection.$supportsWatchActionProfiles
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.syncWatchActionProfileIfPossible()
                self?.updateActionProfileReadiness()
                self?.publishStatus()
            }
            .store(in: &cancellables)

        connection.$acceptedWatchProfileRevision
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                updateActionProfileReadiness()
                if connection.acceptedWatchProfileRevision == actionProfileStore.revision {
                    syncWatchActionProfileIfPossible()
                }
                publishStatus()
            }
            .store(in: &cancellables)

        connection.$watchApplicationTitles
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.publishStatus() }
            .store(in: &cancellables)

        connection.$watchActionProfileError
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateActionProfileReadiness()
                self?.publishStatus()
            }
            .store(in: &cancellables)

        connection.$internetRelayProvisioning
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] provisioning in
                self?.applyInternetRelayProvisioning(provisioning)
            }
            .store(in: &cancellables)

        connection.$codexTaskSnapshot
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshot in
                guard let self else { return }
                if audioStreamGate.activeStreamID != nil,
                   connection.voiceOwner != .watch {
                    finishAllWatchInteractions(sendReleases: false)
                }
                publishStatus()
                transferCodexCompletionIfNeeded(snapshot)
            }
            .store(in: &cancellables)

        connection.$lastVoiceOutcome
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.publishStatus() }
            .store(in: &cancellables)

        layoutSettings.$favorites
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.publishStatus() }
            .store(in: &cancellables)

        actionProfileStore.$profile
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                finishAllWatchInteractions(sendReleases: true)
                internetProfileRetryTask?.cancel()
                internetProfileRetryTask = nil
                internetProfileRetryCount = 0
                internetFailedRevision = nil
                if internetReadyRevision != actionProfileStore.revision {
                    internetReadyRevision = nil
                }
                updateActionProfileReadiness()
                syncWatchActionProfileIfPossible()
                publishStatus()
            }
            .store(in: &cancellables)
    }

    private func syncWatchActionProfileIfPossible() {
        let desiredRevision = actionProfileStore.revision
        let route = Self.profileSyncRoute(
            localChannelAvailable: connection.isConnected
                && connection.supportsWatchActionProfiles,
            localAcceptedRevision: connection.acceptedWatchProfileRevision,
            internetProvisioned: internetRelayClient != nil,
            internetAcceptedRevision: internetReadyRevision,
            failedInternetRevision: internetFailedRevision,
            desiredRevision: desiredRevision,
            internetRequestInFlight: internetProfileSyncTask != nil
        )

        switch route {
        case .none:
            updateActionProfileReadiness()
        case .local:
            _ = connection.syncWatchActionProfile(actionProfileStore.profile)
            updateActionProfileReadiness()
        case .internetUpdate:
            startInternetProfileRequest(
                WristInternetRelayOperation(
                    kind: .profileUpdate,
                    profileRevision: desiredRevision,
                    watchProfile: actionProfileStore.profile
                ),
                expectedRevision: desiredRevision,
                state: .syncing(desiredRevision)
            )
        case .internetVerification:
            startInternetProfileRequest(
                WristInternetRelayOperation(kind: .status),
                expectedRevision: desiredRevision,
                state: .verifying(desiredRevision)
            )
        }
    }

    nonisolated static func profileSyncRoute(
        localChannelAvailable: Bool,
        localAcceptedRevision: Int?,
        internetProvisioned: Bool,
        internetAcceptedRevision: Int?,
        failedInternetRevision: Int?,
        desiredRevision: Int,
        internetRequestInFlight: Bool
    ) -> ProfileSyncRoute {
        guard !internetRequestInFlight else { return .none }
        if localChannelAvailable {
            if localAcceptedRevision != desiredRevision { return .local }
            guard internetProvisioned,
                  internetAcceptedRevision != desiredRevision,
                  failedInternetRevision != desiredRevision
            else { return .none }
            return .internetVerification
        }
        guard internetProvisioned,
              internetAcceptedRevision != desiredRevision,
              failedInternetRevision != desiredRevision
        else { return .none }
        return .internetUpdate
    }

    nonisolated static func acceptedInternetProfileRevision(
        from result: WristInternetRelayResult,
        expectedRevision: Int
    ) -> Int? {
        guard result.accepted,
              result.status?.profileRevision == expectedRevision
        else { return nil }
        return expectedRevision
    }

    nonisolated static func profileBusyRetryDelayMilliseconds(
        reason: WatchProfileUpdateRetryReason?,
        failureCount: Int
    ) -> Int? {
        guard reason == .voiceActive else { return nil }
        return WatchProfileBusyRetryPolicy.delayMilliseconds(
            afterFailureCount: failureCount
        )
    }

    nonisolated static func busyResultMatchesCurrentProfile(
        expectedRevision: Int,
        currentRevision: Int
    ) -> Bool {
        expectedRevision == currentRevision
    }

    private func applyInternetRelayProvisioning(
        _ provisioning: WristInternetRelayDeviceProvisioning?
    ) {
        internetProfileSyncTask?.cancel()
        internetProfileSyncTask = nil
        internetProfileRetryTask?.cancel()
        internetProfileRetryTask = nil
        internetProfileRetryCount = 0
        internetProvisioningGeneration &+= 1
        internetReadyRevision = nil
        internetFailedRevision = nil

        guard let provisioning, provisioning.isValid else {
            internetRelayClient = nil
            internetProfileSyncState = .unavailable
            publishStatus()
            return
        }

        internetRelayClient = WristInternetRelayHTTPClient(provisioning: provisioning)
        internetProfileSyncState = .configured
        syncWatchActionProfileIfPossible()
        publishStatus()
    }

    private func startInternetProfileRequest(
        _ operation: WristInternetRelayOperation,
        expectedRevision: Int,
        state: InternetProfileSyncState
    ) {
        guard isSceneActive,
              let client = internetRelayClient,
              internetProfileSyncTask == nil
        else { return }
        let generation = internetProvisioningGeneration
        internetProfileSyncState = state
        internetProfileSyncTask = Task { @MainActor [weak self] in
            do {
                let result = try await client.send(operation)
                guard !Task.isCancelled else { return }
                self?.completeInternetProfileRequest(
                    result: result,
                    expectedRevision: expectedRevision,
                    generation: generation
                )
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self?.completeInternetProfileRequest(
                    errorText: (error as? LocalizedError)?.errorDescription
                        ?? "公网映射同步失败",
                    expectedRevision: expectedRevision,
                    generation: generation
                )
            }
        }
    }

    private func completeInternetProfileRequest(
        result: WristInternetRelayResult,
        expectedRevision: Int,
        generation: Int
    ) {
        guard generation == internetProvisioningGeneration else { return }
        internetProfileSyncTask = nil
        if let revision = Self.acceptedInternetProfileRevision(
            from: result,
            expectedRevision: expectedRevision
        ) {
            internetReadyRevision = revision
            internetProfileRetryTask?.cancel()
            internetProfileRetryTask = nil
            internetProfileRetryCount = 0
            internetFailedRevision = nil
            internetProfileSyncState = .ready(revision)
        } else {
            if result.profileUpdateRetryReason == .voiceActive {
                guard Self.busyResultMatchesCurrentProfile(
                    expectedRevision: expectedRevision,
                    currentRevision: actionProfileStore.revision
                ) else {
                    internetProfileRetryTask?.cancel()
                    internetProfileRetryTask = nil
                    internetProfileRetryCount = 0
                    internetFailedRevision = nil
                    internetProfileSyncState = .configured
                    publishStatus()
                    syncWatchActionProfileIfPossible()
                    return
                }
                guard WatchProfileBusyRetryPolicy.shouldSchedule(
                    isForeground: isSceneActive,
                    hasValidConnection: internetRelayClient != nil
                ) else {
                    parkInternetProfileRetry(
                        detail: "语音进行中，回到前台后将自动重试公网映射",
                        expectedRevision: expectedRevision,
                        generation: generation
                    )
                    return
                }
                if let delayMilliseconds = Self.profileBusyRetryDelayMilliseconds(
                    reason: result.profileUpdateRetryReason,
                    failureCount: internetProfileRetryCount
                ) {
                    scheduleInternetProfileRetry(
                        expectedRevision: expectedRevision,
                        generation: generation,
                        delayMilliseconds: delayMilliseconds,
                        detail: result.detail
                    )
                } else {
                    parkInternetProfileRetry(
                        detail: "语音持续占用，公网映射保持不变；再次进入前台后自动重试",
                        expectedRevision: expectedRevision,
                        generation: generation
                    )
                }
                return
            }
            completeInternetProfileRequest(
                errorText: result.detail ?? "Mac 尚未确认当前公网映射版本",
                expectedRevision: expectedRevision,
                generation: generation
            )
            return
        }
        publishStatus()
        syncWatchActionProfileIfPossible()
    }

    private func completeInternetProfileRequest(
        errorText: String,
        expectedRevision: Int,
        generation: Int
    ) {
        guard generation == internetProvisioningGeneration else { return }
        internetProfileSyncTask = nil
        internetProfileRetryTask?.cancel()
        internetProfileRetryTask = nil
        internetProfileRetryCount = 0
        if expectedRevision == actionProfileStore.revision {
            internetReadyRevision = nil
            internetFailedRevision = expectedRevision
            internetProfileSyncState = .failed(errorText)
        }
        publishStatus()
        syncWatchActionProfileIfPossible()
    }

    private func scheduleInternetProfileRetry(
        expectedRevision: Int,
        generation: Int,
        delayMilliseconds: Int,
        detail: String?
    ) {
        guard generation == internetProvisioningGeneration,
              WatchProfileBusyRetryPolicy.shouldSchedule(
                isForeground: isSceneActive,
                hasValidConnection: internetRelayClient != nil
              ),
              expectedRevision == actionProfileStore.revision
        else { return }
        internetProfileSyncTask = nil
        internetReadyRevision = nil
        internetFailedRevision = expectedRevision
        internetProfileSyncState = .failed(
            detail ?? "语音进行中，结束后将自动重试公网映射"
        )
        internetProfileRetryCount += 1
        internetProfileRetryTask?.cancel()
        internetProfileRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(delayMilliseconds))
            guard let self,
                  !Task.isCancelled,
                  isSceneActive,
                  internetRelayClient != nil,
                  generation == internetProvisioningGeneration,
                  expectedRevision == actionProfileStore.revision
            else { return }
            internetProfileRetryTask = nil
            internetFailedRevision = nil
            syncWatchActionProfileIfPossible()
        }
        publishStatus()
    }

    private func parkInternetProfileRetry(
        detail: String,
        expectedRevision: Int,
        generation: Int
    ) {
        guard generation == internetProvisioningGeneration else { return }
        internetProfileSyncTask = nil
        internetProfileRetryTask?.cancel()
        internetProfileRetryTask = nil
        internetFailedRevision = nil
        if expectedRevision == actionProfileStore.revision {
            internetProfileSyncState = .failed(detail)
        }
        publishStatus()
    }

    var isInternetRelayProvisioned: Bool {
        internetRelayClient != nil
    }

    var isInternetProfileReady: Bool {
        internetReadyRevision == actionProfileStore.revision
    }

    var internetRelayStatusDetail: String {
        switch internetProfileSyncState {
        case .unavailable:
            return "等待 Mac 安全下发凭证"
        case .configured:
            return "凭证已保存，正在准备同步"
        case let .syncing(revision):
            return "正在通过互联网同步版本 \(revision)"
        case let .verifying(revision):
            return "正在确认互联网版本 \(revision)"
        case let .ready(revision):
            return "版本 \(revision) 已确认"
        case let .failed(detail):
            return detail
        }
    }

    private func updateActionProfileReadiness() {
        let nextReadiness = connection.isWatchActionProfileReady(
            revision: actionProfileStore.revision
        )
        if Self.shouldClearInteractions(
            wasReady: isActionProfileReady,
            isReady: nextReadiness
        ) {
            finishAllWatchInteractions(sendReleases: false)
        }
        isActionProfileReady = nextReadiness
    }

    nonisolated static func shouldClearInteractions(
        wasReady: Bool,
        isReady: Bool
    ) -> Bool {
        wasReady && !isReady
    }

    @discardableResult
    private func handleControlMessage(_ message: [String: Any]) -> Bool? {
        guard protocolVersion(in: message) == WatchRemoteProtocol.version,
              let rawKind = message[WatchRemoteProtocol.Key.kind.rawValue] as? String,
              let kind = WatchRemoteProtocol.Kind(rawValue: rawKind)
        else { return nil }

        switch kind {
        case .buttonEvent:
            guard let event = Self.validatedButtonEvent(
                from: message,
                currentProfileRevision: actionProfileStore.revision,
                acceptedProfileRevision: connection.acceptedWatchProfileRevision
            )
            else { return nil }
            handleButton(
                event.command,
                phase: event.phase,
                profileRevision: event.profileRevision
            )
            return nil

        case .voiceStart:
            // Voice start requires an acknowledgement from the Mac. It is
            // handled by the reply-bearing WCSession delegate below so audio
            // cannot flow before the matching Mac session is ready.
            return false

        case .voiceStop:
            guard let event = Self.validatedVoiceEvent(
                from: message,
                kind: .voiceStop,
                currentProfileRevision: actionProfileStore.revision,
                acceptedProfileRevision: connection.acceptedWatchProfileRevision
                  )
            else { return nil }
            let matchesPendingReservation = voiceRelayReservation.pendingStreamID == event.streamID
                && voiceRelayReservation.pendingProfileRevision == event.profileRevision
            voiceRelayReservation.stop(
                streamID: event.streamID,
                profileRevision: event.profileRevision
            )
            if matchesPendingReservation {
                connection.endRelayedVoice(
                    sessionID: event.streamID.uuidString,
                    profileRevision: event.profileRevision
                )
                return nil
            }
            guard event.intent == activeVoiceIntent,
                  event.codexTaskIdentity == activeVoiceCodexTaskIdentity
            else { return nil }
            requestVoiceStopAfterDrain(
                streamID: event.streamID,
                profileRevision: event.profileRevision,
                finalSequence: event.finalSequence
            )
            return nil

        case .requestStatus:
            publishStatus()
            return nil

        case .favoritesUpdate:
            guard let favorites = WatchRemoteProtocol.favorites(from: message) else { return nil }
            layoutSettings.replaceFavorites(favorites)
            publishStatus()
            return nil

        case .codexReplySubmit:
            // A submission without WCSession's reply handler cannot provide a
            // loss-safe acknowledgement, so it is intentionally ignored.
            lastErrorText = "Codex 回复缺少确认通道，草稿未发送"
            return false

        case .status, .codexTaskSnapshot, .voiceOutcome:
            return nil
        }
    }

    nonisolated static func validatedButtonEvent(
        from message: [String: Any],
        currentProfileRevision: Int,
        acceptedProfileRevision: Int?
    ) -> (
        command: WatchRemoteCommand,
        phase: WatchRemoteProtocol.ButtonPhase,
        profileRevision: Int
    )? {
        guard let event = WatchRemoteProtocol.buttonEvent(from: message),
              event.profileRevision == currentProfileRevision,
              event.profileRevision == acceptedProfileRevision
        else { return nil }
        return event
    }

    nonisolated static func validatedVoiceEvent(
        from message: [String: Any],
        kind: WatchRemoteProtocol.Kind,
        currentProfileRevision: Int,
        acceptedProfileRevision: Int?
    ) -> (
        streamID: UUID,
        profileRevision: Int,
        intent: WatchVoiceIntent,
        codexTaskIdentity: WatchCodexTaskIdentity?,
        finalSequence: UInt64?
    )? {
        guard let event = WatchRemoteProtocol.voiceEvent(from: message, kind: kind),
              event.profileRevision == currentProfileRevision,
              event.profileRevision == acceptedProfileRevision
        else { return nil }
        return event
    }

    private func reserveVoiceStart(
        _ message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) -> (
        streamID: UUID,
        profileRevision: Int,
        intent: WatchVoiceIntent,
        codexTaskIdentity: WatchCodexTaskIdentity?
    )? {
        guard protocolVersion(in: message) == WatchRemoteProtocol.version,
              WatchRemoteProtocol.kind(from: message) == .voiceStart,
              let event = Self.validatedVoiceEvent(
                  from: message,
                  kind: .voiceStart,
                  currentProfileRevision: actionProfileStore.revision,
                  acceptedProfileRevision: connection.acceptedWatchProfileRevision
              ),
              (event.intent == .foregroundDictation
                    || event.codexTaskIdentity == WatchCodexTaskIdentity(
                        connection.codexTaskSnapshot
                    ))
        else {
            replyHandler(WatchRemoteProtocol.voiceStartReply(
                accepted: false,
                streamID: UUID(),
                profileRevision: 0
            ) ?? [:])
            return nil
        }

        guard isWatchReachable,
              isActionProfileReady,
              audioStreamGate.activeStreamID == nil,
              voiceRelayReservation.reserve(
                  streamID: event.streamID,
                  profileRevision: event.profileRevision
              )
        else {
            replyHandler(WatchRemoteProtocol.voiceStartReply(
                accepted: false,
                streamID: event.streamID,
                profileRevision: event.profileRevision,
                intent: event.intent,
                codexTaskIdentity: event.codexTaskIdentity
            ) ?? [:])
            return nil
        }
        return (
            event.streamID,
            event.profileRevision,
            event.intent,
            event.codexTaskIdentity
        )
    }

    private func completeReservedVoiceStart(
        streamID: UUID,
        profileRevision: Int,
        intent: WatchVoiceIntent,
        codexTaskIdentity: WatchCodexTaskIdentity?,
        replyHandler: @escaping ([String: Any]) -> Void
    ) async {
        guard voiceRelayReservation.pendingStreamID == streamID,
              voiceRelayReservation.pendingProfileRevision == profileRevision
        else {
            replyHandler(WatchRemoteProtocol.voiceStartReply(
                accepted: false,
                streamID: streamID,
                profileRevision: profileRevision,
                intent: intent,
                codexTaskIdentity: codexTaskIdentity
            ) ?? [:])
            return
        }
        let sessionID = streamID.uuidString
        let acceptedByMac = await connection.beginRelayedVoice(
            sessionID: sessionID,
            profileRevision: profileRevision,
            intent: intent,
            codexTaskIdentity: codexTaskIdentity
        )
        let isStillPending = voiceRelayReservation.consumeCompletion(
            streamID: streamID,
            profileRevision: profileRevision
        )

        let accepted = acceptedByMac
            && isStillPending
            && isWatchReachable
            && actionProfileStore.revision == profileRevision
            && connection.acceptedWatchProfileRevision == profileRevision
            && (intent == .foregroundDictation
                || codexTaskIdentity == WatchCodexTaskIdentity(
                    connection.codexTaskSnapshot
                ))
        if accepted {
            lastErrorText = nil
            audioStreamGate.start(
                streamID: streamID,
                profileRevision: profileRevision
            )
            activeVoiceIntent = intent
            activeVoiceCodexTaskIdentity = codexTaskIdentity
            scheduleVoiceInactivityWatchdog(
                streamID: streamID,
                profileRevision: profileRevision
            )
        } else {
            if acceptedByMac {
                connection.endRelayedVoice(
                    sessionID: sessionID,
                    profileRevision: profileRevision
                )
            }
            if isStillPending {
                if !connection.isConnected {
                    lastErrorText = "Mac 尚未连接，语音未发送"
                } else {
                    lastErrorText = "Mac 未接受手表语音"
                }
            }
        }

        publishStatus()
        replyHandler(WatchRemoteProtocol.voiceStartReply(
            accepted: accepted,
            streamID: streamID,
            profileRevision: profileRevision,
            intent: intent,
            codexTaskIdentity: codexTaskIdentity
        ) ?? [:])
    }

    private func handleButton(
        _ command: WatchRemoteCommand,
        phase: WatchRemoteProtocol.ButtonPhase,
        profileRevision: Int
    ) {
        guard isWatchReachable,
              connection.isConnected,
              isActionProfileReady
        else { return }

        switch phase {
        case .press:
            if let revision = heldCommandRevisions[command] {
                scheduleReleaseWatchdog(for: command, revision: revision)
                return
            }
            guard connection.sendWatchButtonEvent(
                command.remoteCommand,
                phase: .press,
                profileRevision: profileRevision
            ) else { return }
            heldCommandRevisions[command] = profileRevision
            scheduleReleaseWatchdog(for: command, revision: profileRevision)

        case .release:
            guard let revision = heldCommandRevisions[command],
                  revision == profileRevision
            else { return }
            heldCommandRevisions.removeValue(forKey: command)
            releaseWatchdogs.removeValue(forKey: command)?.cancel()
            _ = connection.sendWatchButtonEvent(
                command.remoteCommand,
                phase: .release,
                profileRevision: revision
            )
        }
    }

    private func scheduleReleaseWatchdog(
        for command: WatchRemoteCommand,
        revision: Int
    ) {
        releaseWatchdogs.removeValue(forKey: command)?.cancel()
        releaseWatchdogs[command] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self,
                  !Task.isCancelled,
                  heldCommandRevisions[command] == revision
            else { return }
            heldCommandRevisions.removeValue(forKey: command)
            releaseWatchdogs[command] = nil
            guard connection.isConnected else { return }
            _ = connection.sendWatchButtonEvent(
                command.remoteCommand,
                phase: .release,
                profileRevision: revision
            )
        }
    }

    private func handleAudioPacket(_ data: Data) -> Data? {
        guard let envelope = WatchRemoteProtocol.audioEnvelope(from: data) else {
            lastErrorText = "收到无法解析的手表语音包"
            publishStatus()
            return nil
        }
        guard isWatchReachable,
              connection.voiceOwner == .watch,
              envelope.profileRevision == actionProfileStore.revision,
              envelope.profileRevision == connection.acceptedWatchProfileRevision
        else {
            return WatchRemoteProtocol.audioAckData(
                streamID: envelope.streamID,
                profileRevision: envelope.profileRevision,
                sequence: envelope.sequence,
                accepted: false,
                contiguousThrough: audioStreamGate.contiguousThrough
            )
        }
        let insertion = audioStreamGate.insert(envelope)
        guard insertion.accepted else {
            return WatchRemoteProtocol.audioAckData(
                streamID: envelope.streamID,
                profileRevision: envelope.profileRevision,
                sequence: envelope.sequence,
                accepted: false,
                contiguousThrough: insertion.contiguousThrough
            )
        }
        scheduleVoiceInactivityWatchdog(
            streamID: envelope.streamID,
            profileRevision: envelope.profileRevision
        )
        for readyEnvelope in insertion.readyEnvelopes {
            connection.sendRelayedVoicePCM(
                readyEnvelope.pcm16Data,
                sessionID: readyEnvelope.streamID.uuidString,
                profileRevision: readyEnvelope.profileRevision
            )
        }
        finishPendingVoiceStopIfDrained()
        return WatchRemoteProtocol.audioAckData(
            streamID: envelope.streamID,
            profileRevision: envelope.profileRevision,
            sequence: envelope.sequence,
            accepted: true,
            contiguousThrough: insertion.contiguousThrough
        )
    }

    private func requestVoiceStopAfterDrain(
        streamID: UUID,
        profileRevision: Int,
        finalSequence: UInt64?
    ) {
        pendingVoiceStop = (streamID, profileRevision, finalSequence)
        if finishPendingVoiceStopIfDrained() { return }
        voiceStopDrainTask?.cancel()
        voiceStopDrainTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(
                WatchRemoteProtocol.voiceFinalAckTimeoutMilliseconds
            ))
            guard let self, !Task.isCancelled else { return }
            finishPendingVoiceStop(
                force: true,
                failureText: "手表语音尾包未完整到达，识别结果可能不完整"
            )
        }
    }

    @discardableResult
    private func finishPendingVoiceStopIfDrained() -> Bool {
        guard let pendingVoiceStop else { return false }
        let isDrained = pendingVoiceStop.finalSequence == nil
            || audioStreamGate.lastAcceptedSequence.map {
                $0 >= pendingVoiceStop.finalSequence!
            } == true
            || audioStreamGate.activeStreamID == nil
        guard isDrained else { return false }
        finishPendingVoiceStop(force: false, failureText: nil)
        return true
    }

    private func finishPendingVoiceStop(force: Bool, failureText: String?) {
        guard let stop = pendingVoiceStop else { return }
        if !force,
           let finalSequence = stop.finalSequence,
           audioStreamGate.activeStreamID != nil,
           (audioStreamGate.lastAcceptedSequence ?? 0) < finalSequence {
            return
        }
        pendingVoiceStop = nil
        voiceStopDrainTask?.cancel()
        voiceStopDrainTask = nil
        let wasActive = audioStreamGate.stop(
            streamID: stop.streamID,
            profileRevision: stop.profileRevision
        )
        if wasActive {
            voiceInactivityWatchdog?.cancel()
            voiceInactivityWatchdog = nil
            activeVoiceIntent = .foregroundDictation
            activeVoiceCodexTaskIdentity = nil
        }
        if let failureText {
            lastErrorText = failureText
        }
        connection.endRelayedVoice(
            sessionID: stop.streamID.uuidString,
            profileRevision: stop.profileRevision
        )
        publishStatus()
    }

    private func scheduleVoiceInactivityWatchdog(
        streamID: UUID,
        profileRevision: Int
    ) {
        voiceInactivityWatchdog?.cancel()
        voiceInactivityWatchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self,
                  !Task.isCancelled,
                  connection.voiceOwner == .watch,
                  audioStreamGate.activeStreamID == streamID,
                  audioStreamGate.activeProfileRevision == profileRevision
            else { return }
            guard pendingVoiceStop == nil else { return }
            voiceInactivityWatchdog = nil
            guard audioStreamGate.stop(
                streamID: streamID,
                profileRevision: profileRevision
            ) else { return }
            activeVoiceIntent = .foregroundDictation
            activeVoiceCodexTaskIdentity = nil
            connection.endRelayedVoice(
                sessionID: streamID.uuidString,
                profileRevision: profileRevision
            )
            publishStatus()
        }
    }

    private func finishAllWatchInteractions(sendReleases: Bool) {
        for task in releaseWatchdogs.values {
            task.cancel()
        }
        releaseWatchdogs.removeAll()
        voiceInactivityWatchdog?.cancel()
        voiceInactivityWatchdog = nil
        voiceStopDrainTask?.cancel()
        voiceStopDrainTask = nil
        pendingVoiceStop = nil
        let activeVoiceStreamID = audioStreamGate.activeStreamID
        let activeVoiceProfileRevision = audioStreamGate.activeProfileRevision
        let pendingVoiceStreamID = voiceRelayReservation.pendingStreamID
        let pendingVoiceProfileRevision = voiceRelayReservation.pendingProfileRevision
        audioStreamGate.clear()
        voiceRelayReservation.clear()
        activeVoiceIntent = .foregroundDictation
        activeVoiceCodexTaskIdentity = nil

        let commands = heldCommandRevisions
        heldCommandRevisions.removeAll()
        if sendReleases, connection.isConnected {
            for (command, revision) in commands {
                _ = connection.sendWatchButtonEvent(
                    command.remoteCommand,
                    phase: .release,
                    profileRevision: revision
                )
            }
        }
        let streams = [
            activeVoiceStreamID.flatMap { streamID in
                activeVoiceProfileRevision.map { (streamID, $0) }
            },
            pendingVoiceStreamID.flatMap { streamID in
                pendingVoiceProfileRevision.map { (streamID, $0) }
            },
        ].compactMap { $0 }
        for (streamID, revision) in streams {
            connection.endRelayedVoice(
                sessionID: streamID.uuidString,
                profileRevision: revision
            )
        }
    }

    private func publishStatus() {
        guard let session, session.activationState == .activated else { return }
        let status = currentStatus
        let context = WatchRemoteProtocol.applicationContext(
            status: status,
            favorites: layoutSettings.favorites,
            codexTask: connection.codexTaskSnapshot,
            codexTaskStateRevision: connection.codexTaskStateRevision,
            voiceOutcome: connection.lastVoiceOutcome,
            internetRelayProvisioning: connection.internetRelayProvisioning
        )
        do {
            try session.updateApplicationContext(context)
        } catch {
            lastErrorText = "暂时无法同步 Apple Watch 布局"
        }

        guard session.isReachable else { return }
        session.sendMessage(
            WatchRemoteProtocol.statusMessage(status),
            replyHandler: nil
        ) { [weak self] _ in
            Task { @MainActor in
                self?.updateWatchProperties(from: session)
            }
        }
        let taskMessage = connection.codexTaskSnapshot.flatMap { snapshot in
            WatchRemoteProtocol.codexTaskMessage(
                snapshot,
                stateRevision: connection.codexTaskStateRevision
            )
        } ?? WatchRemoteProtocol.codexTaskClearedMessage(
            stateRevision: connection.codexTaskStateRevision
        )
        session.sendMessage(taskMessage, replyHandler: nil, errorHandler: nil)
        if let outcome = connection.lastVoiceOutcome,
           let message = WatchRemoteProtocol.voiceOutcomeMessage(outcome) {
            session.sendMessage(message, replyHandler: nil, errorHandler: nil)
        }
    }

    private func transferCodexCompletionIfNeeded(_ snapshot: WatchCodexTaskSnapshot?) {
        guard let session,
              session.activationState == .activated,
              let snapshot,
              snapshot.state == .completed,
              let message = WatchRemoteProtocol.codexTaskMessage(
                snapshot,
                stateRevision: connection.codexTaskStateRevision
              )
        else { return }
        guard let identity = WatchCodexTaskIdentity(snapshot) else { return }
        let token = "\(identity.threadID.utf8.count)#\(identity.threadID)"
            + "\(identity.turnID.utf8.count)#\(identity.turnID)"
        guard token != lastTransferredCodexCompletion else { return }
        lastTransferredCodexCompletion = token
        session.transferUserInfo(message)
    }

    private var currentStatus: WatchRemoteStatus {
        let owner: WatchRemoteProtocol.VoiceOwner
        switch connection.voiceOwner {
        case .watch: owner = .watch
        case nil: owner = .none
        }

        let titles = Dictionary(
            uniqueKeysWithValues: WatchRemoteCommand.allCases.map { command in
                (
                    command,
                    actionProfileStore.title(
                        for: command,
                        applicationTitles: connection.watchApplicationTitles
                    )
                )
            }
        )

        let detail: String?
        if let lastErrorText, !lastErrorText.isEmpty {
            detail = lastErrorText
        } else if connection.hasIssue {
            detail = connection.guidanceText
        } else if connection.isConnected, !connection.supportsWatchActionProfiles {
            detail = "Mac 端需要更新，Apple Watch 不会使用其他设备的映射"
        } else if let error = connection.watchActionProfileError {
            detail = error
        } else if connection.isConnected, !isActionProfileReady {
            detail = "正在同步 Apple Watch 独立映射"
        } else {
            detail = nil
        }

        return WatchRemoteStatus(
            isMacConnected: connection.isConnected,
            macName: connection.macName,
            voiceOwner: owner,
            detail: detail,
            buttonTitles: titles,
            isActionProfileReady: isActionProfileReady,
            profileRevision: isActionProfileReady
                ? connection.acceptedWatchProfileRevision
                : nil
        )
    }

    private func updateWatchProperties(from session: WCSession) {
        activationState = session.activationState
        isWatchPaired = session.isPaired
        isWatchAppInstalled = session.isWatchAppInstalled
        let reachable = session.activationState == .activated && session.isReachable
        if isWatchReachable && !reachable {
            finishAllWatchInteractions(sendReleases: true)
        }
        isWatchReachable = reachable
    }

    private func beginLiveStatusReply(
        requestID: UUID,
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        completeLiveStatusReplyIfNeeded()
        liveStatusRequestID = requestID
        liveStatusReplyHandler = replyHandler

        liveStatusBackgroundTaskID = UIApplication.shared.beginBackgroundTask(
            withName: "WristRemote.LiveStatus"
        ) { [weak self] in
            Task { @MainActor in
                self?.completeLiveStatusReplyIfNeeded(expectedRequestID: requestID)
            }
        }

        liveStatusReplyTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await connection.prepareForWatchStatusRequest()
            guard !Task.isCancelled else { return }
            let clock = ContinuousClock()
            let deadline = clock.now + .milliseconds(4_500)
            while !Task.isCancelled,
                  !connection.isConnected,
                  clock.now < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard !Task.isCancelled else { return }
            completeLiveStatusReplyIfNeeded()
        }
    }

    private func completeLiveStatusReplyIfNeeded(expectedRequestID: UUID? = nil) {
        guard let requestID = liveStatusRequestID,
              let replyHandler = liveStatusReplyHandler
        else { return }
        if let expectedRequestID, expectedRequestID != requestID { return }

        liveStatusReplyTask?.cancel()
        liveStatusReplyTask = nil
        liveStatusRequestID = nil
        liveStatusReplyHandler = nil
        replyHandler(WatchRemoteProtocol.statusReplyMessage(
            currentStatus,
            requestID: requestID
        ))

        if liveStatusBackgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(liveStatusBackgroundTaskID)
            liveStatusBackgroundTaskID = .invalid
        }
    }

    private func protocolVersion(in message: [String: Any]) -> Int? {
        let key = WatchRemoteProtocol.Key.protocolVersion.rawValue
        if let value = message[key] as? Int { return value }
        return (message[key] as? NSNumber)?.intValue
    }
}

extension WatchRelayController: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.activationRequestInFlight = false
            self.activationState = activationState
            self.lastErrorText = error == nil ? nil : "Apple Watch 通信启动失败"
            self.updateWatchProperties(from: session)
            self.publishStatus()
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
        DispatchQueue.main.async { [weak self] in
            self?.updateWatchProperties(from: session)
            self?.finishAllWatchInteractions(sendReleases: true)
        }
    }

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.activationRequestInFlight = false
            self.updateWatchProperties(from: session)
            self.activate()
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async { [weak self] in
            self?.updateWatchProperties(from: session)
            self?.publishStatus()
        }
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        DispatchQueue.main.async { [weak self] in
            self?.updateWatchProperties(from: session)
            self?.publishStatus()
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        // WCSession delivers messages serially. Dispatching each callback to the
        // main queue preserves that order before forwarding to WristBridgeConnection.
        DispatchQueue.main.async { [weak self] in
            self?.updateWatchProperties(from: session)
            _ = self?.handleControlMessage(message)
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                replyHandler([:])
                return
            }
            self.updateWatchProperties(from: session)
            switch WatchRemoteProtocol.kind(from: message) {
            case .requestStatus:
                guard let requestID = WatchRemoteProtocol.requestID(from: message) else {
                    replyHandler(WatchRemoteProtocol.statusMessage(self.currentStatus))
                    return
                }
                self.beginLiveStatusReply(
                    requestID: requestID,
                    replyHandler: replyHandler
                )

            case .voiceStart:
                // Reserve synchronously in this ordered main-queue callback.
                // A following voiceStop can then cancel the exact stream even
                // before the asynchronous Mac acknowledgement task starts.
                guard let event = self.reserveVoiceStart(
                    message,
                    replyHandler: replyHandler
                ) else { return }
                Task { @MainActor in
                    await self.completeReservedVoiceStart(
                        streamID: event.streamID,
                        profileRevision: event.profileRevision,
                        intent: event.intent,
                        codexTaskIdentity: event.codexTaskIdentity,
                        replyHandler: replyHandler
                    )
                }

            case .codexReplySubmit:
                guard let reply = WatchRemoteProtocol.codexReplySubmit(from: message) else {
                    replyHandler([:])
                    return
                }
                let started = self.connection.submitCodexReply(
                    codexTaskIdentity: reply.codexTaskIdentity,
                    submissionID: reply.submissionID,
                    transcript: reply.transcript
                ) { [weak self] receipt in
                    guard let self else {
                        replyHandler([:])
                        return
                    }
                    self.lastErrorText = receipt.accepted ? nil : receipt.detail
                    replyHandler(WatchRemoteProtocol.codexReplyAckMessage(
                        accepted: receipt.accepted,
                        codexTaskIdentity: receipt.codexTaskIdentity,
                        submissionID: receipt.submissionID,
                        detail: receipt.detail
                    ))
                }
                guard started else {
                    self.lastErrorText = "Codex 任务已变化，草稿未发送"
                    replyHandler(WatchRemoteProtocol.codexReplyAckMessage(
                        accepted: false,
                        codexTaskIdentity: reply.codexTaskIdentity,
                        submissionID: reply.submissionID,
                        detail: "任务已更新，草稿已保留"
                    ))
                    return
                }

            default:
                _ = self.handleControlMessage(message)
                replyHandler([:])
            }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
        DispatchQueue.main.async { [weak self] in
            self?.updateWatchProperties(from: session)
            self?.lastErrorText = "手表语音包缺少确认通道"
            self?.publishStatus()
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessageData messageData: Data,
        replyHandler: @escaping (Data) -> Void
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                replyHandler(Data())
                return
            }
            self.updateWatchProperties(from: session)
            replyHandler(self.handleAudioPacket(messageData) ?? Data())
        }
    }
}

private extension WatchRemoteCommand {
    var remoteCommand: WristBridgeCommand {
        switch self {
        case .power: return .power
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        case .ok: return .confirm
        case .back: return .back
        case .home: return .home
        case .menu: return .menu
        case .tv: return .television
        case .volumeUp: return .volumeUp
        case .volumeDown: return .volumeDown
        }
    }
}
