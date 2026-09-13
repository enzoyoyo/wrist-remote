import AppKit
import CryptoKit
import Foundation
import ServiceManagement
import Speech
import UniformTypeIdentifiers

@MainActor
final class BridgeAppModel: ObservableObject {
    struct PairingRequest: Identifiable {
        let id = UUID()
        let deviceName: String
        let pairingCode: String
        let fingerprint: String?
        let completion: (Bool) -> Void
    }

    @Published private(set) var serverStatus: WristRemoteServer.Status = .stopped
    @Published private(set) var isAccessibilityTrusted = WatchActionEngine.isAccessibilityTrusted
    @Published private(set) var speechAuthorization = WatchSpeechTranscriber.authorizationStatus
    @Published private(set) var launchAtLoginStatus = SMAppService.mainApp.status
    @Published private(set) var applicationProfiles: [BridgeApplicationProfile]
    @Published private(set) var speechState: WatchSpeechTranscriber.State = .idle
    @Published private(set) var lastTranscription = ""
    @Published private(set) var speechLocaleIdentifier = "zh-CN"
    @Published private(set) var codexHookState: CodexHookReceiver.State = .stopped
    @Published private(set) var codexTaskSnapshot: WatchCodexTaskSnapshot?
    @Published private(set) var codexConversationCatalog: WatchCodexConversationCatalog?
    @Published private(set) var codexPinnedThreadID: String?
    @Published private(set) var isWaitingForNextCodexThread = false
    @Published private(set) var codexDeliveryStatus = "尚未从手表发送"
    @Published private(set) var internetRelayStatus: InternetRelayClient.Status = .stopped
    @Published private(set) var tailnetStatus: WristRemoteServer.TailnetStatus = .disabled
    @Published private(set) var tailnetAccessEnabled: Bool
    @Published private(set) var directBridgeConfiguration: WristDirectBridgeConfiguration?
    @Published private(set) var connectedClients: [WristRemoteClientSnapshot] = []
    @Published var pairingRequest: PairingRequest?
    @Published var operationError: String?

    private let preferences: BridgePreferences
    private let server: WristRemoteServer
    private let actionEngine: WatchActionEngine
    private let gestureDispatcher: WatchGestureDispatcher
    private let speechTranscriber: WatchSpeechTranscriber
    private let codexAudioInbox: WatchCodexAudioInbox
    private let codexCoordinator: CodexTaskCoordinator
    private let codexHookReceiver: CodexHookReceiver
    private let codexAppServerClient: CodexAppServerClient
    private let codexConversationAuthority: CodexConversationAuthority
    private let codexConversationTargetCoordinator: CodexConversationTargetCoordinator
    private let codexConversationLedger: CodexConversationIdempotencyLedger
    private let codexConversationFingerprintKey: SymmetricKey?
    private var codexConversationService: CodexConversationService?
    private var codexConversationWorkspaceIDByPath: [String: String] = [:]
    private var codexConversationRefreshTask: Task<Void, Never>?
    private var codexConversationRefreshCompletions: [
        (WatchCodexConversationCatalog?, String?) -> Void
    ] = []
    private let internetRelay: InternetRelayClient?
    private var hasStarted = false
    private var lastPublishedCodexRevision: Int64?
    private var codexTaskStateRevision: Int
    private struct ActiveVoiceContext {
        let sessionID: String
        let intent: WatchVoiceIntent
        let codexTaskIdentity: WatchCodexTaskIdentity?
        let codexConversationTarget: WatchCodexConversationTarget?
        let isInternetRelay: Bool
    }
    private var activeVoiceContext: ActiveVoiceContext?
    private var codexVoiceSubmissionTask: Task<Void, Never>?
    private var voiceStartReservation = BridgeVoiceStartReservation()
    private var lastInternetVoiceOutcome: WatchVoiceOutcome?
    private var internetVoiceNextSequence: UInt64 = 0
    private var internetVoiceWatchdog: Task<Void, Never>?

    init(
        preferences: BridgePreferences = BridgePreferences(),
        server: WristRemoteServer = WristRemoteServer(),
        actionEngine: WatchActionEngine? = nil,
        gestureDispatcher: WatchGestureDispatcher? = nil,
        speechTranscriber: WatchSpeechTranscriber? = nil,
        codexAudioInbox: WatchCodexAudioInbox? = nil
    ) {
        let codexCoordinator = CodexTaskCoordinator(
            pinnedThreadID: preferences.codexPinnedThreadID
        )
        let internetRelay = WristInternetRelayMacCredentialStore.loadOrCreate().map {
            InternetRelayClient(credentials: $0)
        }
        let codexTaskStateRevision = preferences.nextCodexTaskStateRevision()
        let codexAppServerClient = CodexAppServerClient(
            executableURL: CodexExecutableLocator.defaultExecutableURL
        )
        let codexConversationAuthority = CodexConversationAuthority(
            workspaceIdentityStore: .persistentDefault()
        )
        let codexConversationLedger = CodexConversationIdempotencyLedger.persistentDefault()
        let codexConversationFingerprintKey = CodexConversationFingerprintKeyStore.loadOrCreate()
        self.preferences = preferences
        self.server = server
        self.actionEngine = actionEngine ?? WatchActionEngine()
        self.gestureDispatcher = gestureDispatcher ?? WatchGestureDispatcher()
        self.speechTranscriber = speechTranscriber ?? WatchSpeechTranscriber()
        self.codexAudioInbox = codexAudioInbox ?? WatchCodexAudioInbox()
        self.codexCoordinator = codexCoordinator
        self.codexAppServerClient = codexAppServerClient
        self.codexConversationAuthority = codexConversationAuthority
        self.codexConversationTargetCoordinator = CodexConversationTargetCoordinator(
            authority: codexConversationAuthority,
            appServerClient: codexAppServerClient
        )
        self.codexConversationLedger = codexConversationLedger
        self.codexConversationFingerprintKey = codexConversationFingerprintKey
        self.codexConversationService = codexConversationFingerprintKey.flatMap { key in
            try? CodexConversationService(
                client: codexAppServerClient,
                workspaces: [],
                fingerprintKey: key,
                ledger: codexConversationLedger
            )
        }
        self.internetRelay = internetRelay
        self.codexTaskStateRevision = codexTaskStateRevision
        codexPinnedThreadID = preferences.codexPinnedThreadID
        codexHookReceiver = CodexHookReceiver(coordinator: codexCoordinator)
        speechLocaleIdentifier = self.speechTranscriber.recognitionLocaleIdentifier ?? "zh-CN"
        applicationProfiles = preferences.applicationProfiles
        tailnetAccessEnabled = preferences.tailnetAccessEnabled
        configureComponents()
        restorePersistedWatchProfile()
        configureCodexBridge()
    }

    var statusTitle: String {
        switch serverStatus {
        case .stopped: return "未启动"
        case .loadingIdentity: return "正在读取安全身份"
        case .starting: return "正在启动"
        case .ready: return "等待 Wrist Remote"
        case let .connected(name): return "已连接 · \(name)"
        case .identityUnavailable: return "安全身份不可用"
        case .failed: return "启动失败"
        }
    }

    var statusDetail: String {
        switch serverStatus {
        case .stopped:
            return "服务未运行。"
        case .loadingIdentity:
            return "正在后台读取这台 Mac 的长期配对身份；确认完成前不会开放任何监听器。"
        case .starting:
            return "正在发布独立的本地网络服务。"
        case .ready:
            return "只接受 Wrist Remote iPhone 与 Apple Watch。"
        case .connected:
            return "手机与 Apple Watch 共用独立映射；仅接受已配对设备。"
        case let .identityUnavailable(detail):
            return detail
        case let .failed(detail):
            return detail
        }
    }

    var canRetryServerIdentity: Bool {
        if case .identityUnavailable = serverStatus { return true }
        return false
    }

    var internetRelayStatusTitle: String {
        guard WristInternetRelayConfiguration.isEnabledForCurrentBuild else {
            return "已禁用"
        }
        switch internetRelayStatus {
        case .stopped: return "未启动"
        case .connecting: return "正在连接"
        case .connected: return "已连接"
        case .unavailable: return "正在重连"
        }
    }

    var internetRelayStatusDetail: String {
        guard WristInternetRelayConfiguration.isEnabledForCurrentBuild else {
            return "当前构建仅使用局域网/Tailscale，历史公网凭据已清除"
        }
        switch internetRelayStatus {
        case .stopped: return "公网备用链路未运行"
        case .connecting: return "正在建立加密出站连接"
        case .connected: return "局域网不可用时可通过互联网控制"
        case let .unavailable(detail): return detail
        }
    }

    var isInternetRelayConnected: Bool {
        if case .connected = internetRelayStatus { return true }
        return false
    }

    var tailnetStatusTitle: String {
        switch tailnetStatus {
        case .disabled: return "未启用"
        case .waiting: return "等待 Tailscale"
        case .starting: return "正在监听"
        case .ready: return "私有监听已就绪"
        case .failed: return "正在恢复"
        }
    }

    var tailnetStatusDetail: String {
        switch tailnetStatus {
        case .disabled:
            return "默认关闭；不会监听任何隧道地址。"
        case .waiting:
            return "未发现 Tailscale 隧道地址；局域网服务仍正常。"
        case .starting:
            return "只在 Tailscale 隧道地址的 60927 端口启动独立监听。"
        case .ready:
            return "只接受 Tailnet 来源，并继续要求 Wrist Remote 配对与会话加密。"
        case let .failed(detail):
            return "私有监听暂不可用：\(detail)"
        }
    }

    var speechAuthorizationTitle: String {
        switch speechAuthorization {
        case .authorized: return "已允许"
        case .denied: return "已拒绝"
        case .restricted: return "受系统限制"
        case .notDetermined: return "尚未请求"
        @unknown default: return "未知"
        }
    }

    var launchAtLoginEnabled: Bool {
        launchAtLoginStatus == .enabled
    }

    var codexHookStatusTitle: String {
        switch codexHookState {
        case .stopped: return "未启动"
        case .starting: return "正在启动"
        case .ready: return "任务 Hook 已监听"
        case .failed: return "Hook 监听失败"
        }
    }

    func start() {
        guard !hasStarted else {
            refreshSystemStatus()
            return
        }
        hasStarted = true
        refreshSystemStatus()
        publishApplicationTitles()
        server.updateCodexTask(
            codexTaskSnapshot,
            stateRevision: codexTaskStateRevision
        )
        server.updateCodexConversationCatalog(codexConversationCatalog)
        server.updateSpeechLocaleIdentifier(speechLocaleIdentifier)
        server.updateInternetRelayProvisioning(
            internetRelay?.credentials.provisioning.encodedBase64()
        )
        server.start(tailnetAccessEnabled: tailnetAccessEnabled)
        internetRelay?.start()
        let coordinator = codexCoordinator
        Task { @MainActor [weak self] in
            await coordinator.setSnapshotObserver { [weak self] snapshot in
                Task { @MainActor in self?.publishCodexSnapshot(snapshot) }
            }
            self?.codexHookReceiver.start()
            self?.refreshCodexConversationCatalog()
        }
    }

    func refreshSystemStatus() {
        isAccessibilityTrusted = WatchActionEngine.isAccessibilityTrusted
        speechAuthorization = WatchSpeechTranscriber.authorizationStatus
        launchAtLoginStatus = SMAppService.mainApp.status
    }

    func retryServerIdentity() {
        server.start(tailnetAccessEnabled: tailnetAccessEnabled)
    }

    func requestAccessibility() {
        _ = WatchActionEngine.requestAccessibilityAccess()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.refreshSystemStatus()
        }
    }

    func requestSpeechAuthorization() {
        WatchSpeechTranscriber.requestAuthorization { [weak self] status in
            self?.speechAuthorization = status
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            operationError = nil
        } catch {
            operationError = "无法更新登录时启动：\(error.localizedDescription)"
        }
        launchAtLoginStatus = SMAppService.mainApp.status
    }

    func setTailnetAccessEnabled(_ enabled: Bool) {
        preferences.tailnetAccessEnabled = enabled
        tailnetAccessEnabled = enabled
        server.setTailnetAccessEnabled(enabled)
    }

    func followNextCodexThread() {
        let coordinator = codexCoordinator
        Task { @MainActor [weak self] in
            await coordinator.followNextThread()
            guard let self else { return }
            preferences.codexPinnedThreadID = nil
            codexPinnedThreadID = nil
            isWaitingForNextCodexThread = true
            codexTaskSnapshot = nil
            codexTaskStateRevision = preferences.nextCodexTaskStateRevision()
            server.updateCodexTask(
                nil,
                stateRevision: codexTaskStateRevision
            )
        }
    }

    func resolvePairing(_ allowed: Bool) {
        guard let request = pairingRequest else { return }
        pairingRequest = nil
        request.completion(allowed)
    }

    func addApplication() {
        let panel = NSOpenPanel()
        panel.title = "选择供 Apple Watch 打开的 App"
        panel.prompt = "添加"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        guard panel.runModal() == .OK,
              let url = panel.url,
              let bundle = Bundle(url: url),
              let bundleIdentifier = bundle.bundleIdentifier
        else { return }

        let title = FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
        if let existingIndex = applicationProfiles.firstIndex(
            where: { $0.bundleIdentifier == bundleIdentifier }
        ) {
            applicationProfiles[existingIndex].title = title
            applicationProfiles[existingIndex].applicationPath = url.path
        } else {
            applicationProfiles.append(BridgeApplicationProfile(
                title: title,
                bundleIdentifier: bundleIdentifier,
                applicationPath: url.path
            ))
        }
        persistApplicationsAndInvalidateProfiles()
    }

    func removeApplication(id: UUID) {
        applicationProfiles.removeAll { $0.id == id }
        persistApplicationsAndInvalidateProfiles()
    }

    private func configureComponents() {
        actionEngine.updateApplicationProfiles(applicationProfiles)
        gestureDispatcher.onBinding = { [weak self] binding in
            guard let self else { return false }
            let succeeded = actionEngine.perform(binding)
            if !succeeded {
                operationError = "当前无法执行 \(binding.action.rawValue)。"
            } else {
                operationError = nil
            }
            return succeeded
        }

        internetRelay?.onStatus = { [weak self] status in
            self?.internetRelayStatus = status
            if case .connected = status { return }
            self?.finishAbandonedInternetInteractions()
        }
        internetRelay?.onOperation = { [weak self] operation in
            guard let self else {
                return WristInternetRelayResult(
                    operationID: operation.operationID,
                    accepted: false,
                    detail: "腕上遥控桥已停止"
                )
            }
            return await self.handleInternetOperation(operation)
        }

        server.onStatus = { [weak self] status in
            self?.serverStatus = status
        }
        server.onTailnetStatus = { [weak self] status in
            self?.tailnetStatus = status
        }
        server.onDirectBridgeConfiguration = { [weak self] configuration in
            DispatchQueue.main.async { self?.directBridgeConfiguration = configuration }
        }
        server.onClientSnapshots = { [weak self] clients in
            DispatchQueue.main.async { self?.connectedClients = clients }
        }
        server.isIdentityTrusted = { [weak preferences] fingerprint in
            preferences?.trusts(fingerprint) ?? false
        }
        server.onIdentityApproved = { [weak preferences] fingerprint in
            preferences?.trust(fingerprint) ?? false
        }
        server.onApprovalRequested = { [weak self] name, code, fingerprint, completion in
            DispatchQueue.main.async {
                guard let self, self.pairingRequest == nil else {
                    completion(false)
                    return
                }
                self.pairingRequest = PairingRequest(
                    deviceName: name,
                    pairingCode: code,
                    fingerprint: fingerprint,
                    completion: completion
                )
            }
        }
        server.onApprovalCancelled = { [weak self] in
            DispatchQueue.main.async { self?.pairingRequest = nil }
        }
        server.onWatchProfileUpdate = { [weak self] profile, completion in
            DispatchQueue.main.async {
                completion(self?.installWatchProfile(profile) ?? .rejected)
            }
        }
        server.onWatchButtonEvent = { [weak self] button, phase, completion in
            DispatchQueue.main.async {
                completion(self?.gestureDispatcher.handle(phase, button: button) ?? false)
            }
        }
        server.onWatchButtonCancel = { [weak self] button in
            DispatchQueue.main.async { self?.gestureDispatcher.cancel(button) }
        }
        server.onWatchButtonTrigger = { [weak self] button, trigger, revision, issuedAt, completion in
            DispatchQueue.main.async {
                let now = Int64(Date().timeIntervalSince1970 * 1_000)
                guard let self, self.gestureDispatcher.profile?.revision == revision,
                      issuedAt > 0, issuedAt <= now,
                      now - issuedAt <= WristDirectBridgeProtocol.buttonCommitLifetimeMilliseconds
                else {
                    completion(false)
                    return
                }
                completion(self.gestureDispatcher.trigger(trigger, button: button))
            }
        }
        server.onProfileReset = { [weak self] in
            DispatchQueue.main.async { self?.restorePersistedWatchProfile() }
        }
        server.onVoiceStart = {
            [weak self] sessionID, intent, codexTaskIdentity, codexConversationTarget, completion in
            // Enqueue reservation and cancel on the same serial actor queue.
            // Do not defer the reservation itself to a freely scheduled Task.
            DispatchQueue.main.async {
                guard let self,
                      let sessionID,
                      UUID(uuidString: sessionID)?.uuidString == sessionID,
                      self.activeVoiceContext == nil,
                      let ticket = self.voiceStartReservation.reserve(sessionID: sessionID)
                else {
                    completion(false)
                    return
                }
                Task { @MainActor in
                    defer { self.voiceStartReservation.discard(ticket) }
                    switch intent {
                    case .foregroundDictation:
                        guard codexTaskIdentity == nil, codexConversationTarget == nil else {
                            completion(false)
                            return
                        }
                    case .codexTask:
                        guard codexConversationTarget == nil,
                              codexTaskIdentity == WatchCodexTaskIdentity(self.codexTaskSnapshot)
                        else {
                            completion(false)
                            return
                        }
                    case .codexConversation:
                        guard codexTaskIdentity == nil,
                              let codexConversationTarget,
                              codexConversationTarget.kind == .existing
                        else {
                            completion(false)
                            return
                        }
                        do {
                            _ = try await self.codexConversationAuthority.resolveSelection(
                                codexConversationTarget
                            )
                        } catch {
                            completion(false)
                            return
                        }
                    }
                    guard self.voiceStartReservation.consume(ticket),
                          self.activeVoiceContext == nil else {
                        completion(false)
                        return
                    }
                    self.activeVoiceContext = ActiveVoiceContext(
                        sessionID: sessionID,
                        intent: intent,
                        codexTaskIdentity: codexTaskIdentity,
                        codexConversationTarget: codexConversationTarget,
                        isInternetRelay: false
                    )
                    let started: Bool
                    switch intent {
                    case .foregroundDictation:
                        guard self.speechTranscriber.state.acceptsNewSession else {
                            self.activeVoiceContext = nil
                            completion(false)
                            return
                        }
                        started = self.speechTranscriber.start(requiresAccessibility: true)
                    case .codexTask, .codexConversation:
                        guard self.codexAudioInbox.acceptsNewSession,
                              let streamID = UUID(uuidString: sessionID)
                        else {
                            self.activeVoiceContext = nil
                            completion(false)
                            return
                        }
                        do {
                            started = try self.codexAudioInbox.start(streamID: streamID)
                            self.speechState = .listening
                            self.lastTranscription = ""
                        } catch {
                            let detail = error.localizedDescription
                            self.operationError = detail
                            self.speechState = .failed(detail)
                            started = false
                        }
                    }
                    if !started {
                        // The matching state callback publishes an exact failure when available.
                        if self.activeVoiceContext?.sessionID == sessionID {
                            self.activeVoiceContext = nil
                        }
                    }
                    completion(started)
                }
            }
        }
        server.onVoiceStop = { [weak self] sessionID in
            DispatchQueue.main.async {
                guard let self, let sessionID else { return }
                self.voiceStartReservation.cancel(sessionID: sessionID)
                guard self.activeVoiceContext?.sessionID == sessionID,
                      self.activeVoiceContext?.isInternetRelay == false else { return }
                self.stopActiveVoiceSession()
            }
        }
        server.onVoiceCancel = { [weak self] sessionID in
            DispatchQueue.main.async {
                guard let self, let sessionID else { return }
                self.voiceStartReservation.cancel(sessionID: sessionID)
                guard self.activeVoiceContext?.sessionID == sessionID,
                      self.activeVoiceContext?.isInternetRelay == false else { return }
                self.cancelActiveVoiceSession()
            }
        }
        server.onAudio = { [weak self] sessionID, samples in
            if Thread.isMainThread {
                return MainActor.assumeIsolated {
                    self?.appendPrivateVoiceSamples(samples, sessionID: sessionID) ?? false
                }
            }
            return DispatchQueue.main.sync {
                self?.appendPrivateVoiceSamples(samples, sessionID: sessionID) ?? false
            }
        }

        speechTranscriber.onStateChange = { [weak self] state in
            guard let self else { return }
            speechState = state
            if case let .failed(detail) = state {
                operationError = detail
                finishVoiceWithFailure(detail)
            }
        }
        speechTranscriber.onFinalText = { [weak self] text in
            guard let self else { return }
            lastTranscription = text
            guard let context = activeVoiceContext else { return }
            guard context.intent == .foregroundDictation else {
                finishVoiceWithFailure("语音识别路径不匹配，已拒绝。")
                return
            }
            let delivered = BridgeTextInjector.insert(text)
            let detail = delivered ? nil : "识别完成，但辅助功能权限不足，无法输入文字。"
            if let detail { operationError = detail }
            let outcome = WatchVoiceOutcome(
                sessionID: context.sessionID,
                intent: context.intent,
                threadID: nil,
                kind: delivered ? .delivered : .failed,
                text: delivered ? text : nil,
                detail: detail,
                localeIdentifier: speechLocaleIdentifier
            )
            if context.isInternetRelay { lastInternetVoiceOutcome = outcome }
            server.sendVoiceOutcome(outcome)
            internetVoiceWatchdog?.cancel()
            internetVoiceWatchdog = nil
            activeVoiceContext = nil
        }

    }

    private func configureCodexBridge() {
        codexHookReceiver.onStateChange = { [weak self] state in
            self?.codexHookState = state
            if case let .failed(detail) = state {
                self?.operationError = "无法接收 Codex 任务状态：\(detail)"
            }
        }

        let coordinator = codexCoordinator
        server.onCodexReplySubmit = {
            [weak self] submissionID, identity, transcript, completion in
            Task {
                guard let self,
                      let snapshot = await coordinator.currentSnapshot(),
                      snapshot.threadID == identity.threadID,
                      snapshot.turnID == identity.turnID,
                      Int(exactly: snapshot.revision) == identity.revision,
                      snapshot.status == .completed
                else {
                    completion(false, "Codex 任务已经变化，请在手表刷新后重试。")
                    return
                }
                do {
                    guard let service = self.codexConversationService else {
                        throw CodexConversationServiceError.idempotencyLedgerUnavailable
                    }
                    _ = try await service.submit(CodexExistingConversationSubmission(
                        submissionID: submissionID,
                        threadID: identity.threadID,
                        message: transcript
                    ))
                    let detail = "已排入当前 Codex 聊天"
                    await MainActor.run {
                        self.codexDeliveryStatus = detail
                        self.operationError = nil
                    }
                    completion(true, detail)
                } catch {
                    let detail = Self.safeCodexConversationError(error)
                    await MainActor.run {
                        self.codexDeliveryStatus = "最近一次发送失败"
                        self.operationError = "Codex 回复失败：\(detail)"
                    }
                    completion(false, detail)
                }
            }
        }

        server.onCodexConversationCatalogRequest = { [weak self] _, completion in
            Task { @MainActor in
                guard let self else {
                    completion(nil, "腕上遥控桥已停止")
                    return
                }
                self.refreshCodexConversationCatalog(completion: completion)
            }
        }

        server.onCodexConversationTargetSelect = { [weak self] requestID, target, completion in
            Task { @MainActor in
                guard let self else {
                    completion(false, nil, "腕上遥控桥已停止")
                    return
                }
                do {
                    let selected = try await CodexConversationTargetSelectionRouter.select(
                        requestID: requestID,
                        target: target,
                        coordinate: { request in
                            try await self.codexConversationTargetCoordinator.select(request)
                        },
                        isCreatedTargetInstalled: { selected in
                            self.codexConversationCatalog?.entries.contains(where: {
                                $0.target == selected
                            }) == true
                        },
                        installCreatedTarget: { selected in
                            self.installImmediatelyCreatedConversationTarget(selected)
                        }
                    )
                    completion(true, selected, nil)
                } catch {
                    completion(false, nil, Self.safeCodexConversationError(error))
                }
            }
        }

        server.onCodexConversationDraftSubmit = {
            [weak self] submissionID, draftID, target, transcript, completion in
            Task { @MainActor in
                guard let self else {
                    completion(false, nil, "腕上遥控桥已停止")
                    return
                }
                do {
                    let resolved = try await self.codexConversationAuthority
                        .resolveDraftSubmission(
                            draftID: draftID,
                            target: target,
                            transcript: transcript,
                            submissionID: submissionID
                        )
                    guard let service = self.codexConversationService else {
                        throw CodexConversationServiceError.idempotencyLedgerUnavailable
                    }

                    guard resolved.target == target,
                          let threadID = resolved.threadID,
                          threadID == target.threadID
                    else {
                        throw CodexConversationAuthorityError.invalidTarget
                    }
                    _ = try await service.submit(CodexExistingConversationSubmission(
                        submissionID: submissionID,
                        threadID: threadID,
                        message: transcript
                    ))
                    self.codexDeliveryStatus = "已排入所选 Codex 会话"
                    self.operationError = nil
                    completion(true, target, "已排入所选 Codex 会话")
                } catch {
                    let detail = Self.safeCodexConversationError(error)
                    self.codexDeliveryStatus = "最近一次发送失败"
                    self.operationError = "Codex 发送失败：\(detail)"
                    completion(false, nil, detail)
                }
            }
        }
    }

    private func refreshCodexConversationCatalog(
        completion: ((WatchCodexConversationCatalog?, String?) -> Void)? = nil
    ) {
        if let completion {
            codexConversationRefreshCompletions.append(completion)
        }
        guard codexConversationRefreshTask == nil else { return }

        codexConversationRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await self.codexAppServerClient.listThreadSnapshot(limit: 12)
                let catalog = try await self.installCodexConversationCatalog(snapshot)
                self.finishCodexConversationCatalogRefresh(catalog: catalog, error: nil)
            } catch {
                self.finishCodexConversationCatalogRefresh(
                    catalog: nil,
                    error: Self.safeCodexConversationError(error)
                )
            }
        }
    }

    private func finishCodexConversationCatalogRefresh(
        catalog: WatchCodexConversationCatalog?,
        error: String?
    ) {
        codexConversationRefreshTask = nil
        let completions = codexConversationRefreshCompletions
        codexConversationRefreshCompletions.removeAll(keepingCapacity: true)
        completions.forEach { $0(catalog, error) }
    }

    private func installCodexConversationCatalog(
        _ snapshot: CodexConversationCatalogSnapshot,
        additionalTarget: CodexConversationLocalTarget? = nil
    ) async throws -> WatchCodexConversationCatalog {
        var targetsByThreadID: [String: CodexConversationLocalTarget] = [:]
        for target in snapshot.localTargets {
            let threadID = target.conversation.threadID.lowercased()
            guard targetsByThreadID[threadID] == nil else {
                throw CodexAppServerClientError.invalidProtocolResponse
            }
            targetsByThreadID[threadID] = target
        }
        if let additionalTarget {
            targetsByThreadID[additionalTarget.conversation.threadID.lowercased()] = additionalTarget
        }
        let localTargets = targetsByThreadID.values.sorted {
            $0.conversation.updatedAtEpochSeconds > $1.conversation.updatedAtEpochSeconds
        }

        let provisioner = CodexWorkspaceProvisioner()
        let standaloneRoot = try provisioner.prepareStandaloneRoot()
        var workspaceLabelsByPath: [String: String] = [:]
        for target in localTargets {
            guard !provisioner.isStandaloneTaskDirectory(target.directoryURL) else { continue }
            let path = Self.canonicalWorkspacePath(target.directoryURL.path)
            workspaceLabelsByPath[path] = target.conversation.workspaceLabel
        }
        if let current = await codexCoordinator.currentSnapshot(),
           (current.cwd as NSString).isAbsolutePath {
            let path = Self.canonicalWorkspacePath(current.cwd)
            if workspaceLabelsByPath[path] == nil,
               !provisioner.isStandaloneTaskDirectory(URL(fileURLWithPath: path)) {
                workspaceLabelsByPath[path] = Self.workspaceLabel(for: path)
            }
        }

        guard let codexConversationFingerprintKey else {
            throw CodexConversationServiceError.idempotencyLedgerUnavailable
        }
        let standalone = CodexWorkspaceDescriptor(
            id: WatchCodexConversationTarget.standaloneWorkspaceID,
            displayName: "全新空白任务",
            directoryURL: standaloneRoot
        )
        let descriptors = [standalone] + workspaceLabelsByPath.keys.sorted().map { path in
            CodexWorkspaceDescriptor(
                id: Self.workspaceID(
                    for: path,
                    fingerprintKey: codexConversationFingerprintKey
                ),
                displayName: workspaceLabelsByPath[path] ?? Self.workspaceLabel(for: path),
                directoryURL: URL(fileURLWithPath: path, isDirectory: true)
            )
        }
        let workspaceIDByPath = Dictionary(
            uniqueKeysWithValues: descriptors.map {
                (Self.canonicalWorkspacePath($0.directoryURL.path), $0.id)
            }
        )
        let service = try CodexConversationService(
            client: codexAppServerClient,
            // Standalone creation must go through the provisioning coordinator,
            // never the legacy create-and-send path using the collection root.
            workspaces: descriptors.filter { $0.id != standalone.id },
            fingerprintKey: codexConversationFingerprintKey,
            ledger: codexConversationLedger
        )
        let existingSeeds = localTargets.map { localTarget in
            let conversation = localTarget.conversation
            let seconds = max(conversation.updatedAtEpochSeconds, 0)
            let milliseconds = seconds > Int64.max / 1_000
                ? Int64.max
                : seconds * 1_000
            let canonicalPath = Self.canonicalWorkspacePath(localTarget.directoryURL.path)
            let isStandalone = provisioner.isStandaloneTaskDirectory(localTarget.directoryURL)
            return CodexConversationCatalogSeed(
                threadID: conversation.threadID,
                cwd: canonicalPath,
                title: conversation.title,
                workspaceLabel: isStandalone ? "独立任务" : conversation.workspaceLabel,
                state: Self.watchConversationState(conversation.status),
                updatedAtEpochMilliseconds: milliseconds,
                canAcceptInput: conversation.canAcceptDirectInput
                    ?? (conversation.status != .unavailable),
                workspaceID: isStandalone
                    ? WatchCodexConversationTarget.standaloneWorkspaceID
                    : workspaceIDByPath[canonicalPath]
            )
        }
        let workspaceSeeds = descriptors.map {
            CodexConversationWorkspaceSeed(
                cwd: $0.directoryURL.path,
                workspaceLabel: $0.displayName,
                workspaceID: $0.id
            )
        }
        let catalog = try await codexConversationAuthority.makeCatalog(
            existing: existingSeeds,
            newConversationWorkspaces: workspaceSeeds,
            hasMore: snapshot.catalog.hasMore
        )

        codexConversationService = service
        codexConversationWorkspaceIDByPath = workspaceIDByPath
        codexConversationCatalog = catalog
        server.updateCodexConversationCatalog(catalog)
        return catalog
    }

    private func publishCatalogAfterCreatingConversation(
        result: CodexConversationStartAndQueueResult,
        directoryPath: String,
        workspaceID: String
    ) async throws -> WatchCodexConversationTarget {
        let canonicalDirectory = Self.canonicalWorkspacePath(directoryPath)
        let additionalTarget = CodexConversationLocalTarget(
            conversation: result.conversation,
            directoryURL: URL(
                fileURLWithPath: canonicalDirectory,
                isDirectory: true
            )
        )
        let immediateTarget = try await codexConversationAuthority.registerCreatedConversation(
            threadID: result.receipt.threadID,
            title: result.conversation.title,
            workspaceID: workspaceID,
            workspaceLabel: result.conversation.workspaceLabel,
            cwd: canonicalDirectory
        )

        // Acknowledgement above reflects the completed queue side effect.
        // Refresh the browse catalog independently so a slow/failing list
        // request cannot make the Watch retry an already delivered message.
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await self.codexAppServerClient.listThreadSnapshot(limit: 12)
                _ = try await self.installCodexConversationCatalog(
                    snapshot,
                    additionalTarget: additionalTarget
                )
            } catch {
                // The immediate target remains valid for the receipt. A later
                // explicit refresh can repopulate the browse catalog.
            }
        }
        return immediateTarget
    }

    private func installImmediatelyCreatedConversationTarget(
        _ target: WatchCodexConversationTarget
    ) {
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        guard let updated = codexConversationCatalog?
            .installingImmediatelyCreatedConversation(
                target,
                nowEpochMilliseconds: now
            )
        else { return }
        codexConversationCatalog = updated
        server.updateCodexConversationCatalog(updated)
    }

    private static func watchConversationState(
        _ state: CodexConversationRuntimeStatus
    ) -> WatchCodexConversationState {
        switch state {
        case .idle: return .idle
        case .running: return .running
        case .unavailable: return .unavailable
        }
    }

    private static func canonicalWorkspacePath(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    private static func workspaceID(
        for canonicalPath: String,
        fingerprintKey: SymmetricKey
    ) -> String {
        let digest = HMAC<SHA256>.authenticationCode(
            for: Data("wrist-remote-workspace-v1\0\(canonicalPath)".utf8),
            using: fingerprintKey
        )
            .map { String(format: "%02x", $0) }
            .joined()
        return "workspace-\(digest.prefix(24))"
    }

    private static func workspaceLabel(for canonicalPath: String) -> String {
        let candidate = URL(fileURLWithPath: canonicalPath, isDirectory: true).lastPathComponent
        let normalized = candidate
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return normalized.isEmpty ? "Mac 工作区" : String(normalized.prefix(60))
    }

    private static func safeCodexConversationError(_ error: Error) -> String {
        let raw = (error as? LocalizedError)?.errorDescription
            ?? "Codex 本地服务暂不可用，请稍后重试。"
        let normalized = raw
            .unicodeScalars
            .map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }
            .joined()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        let fallback = normalized.isEmpty
            ? "Codex 本地服务暂不可用，请稍后重试。"
            : normalized
        return String(fallback.prefix(240))
    }

    private func publishCodexSnapshot(_ snapshot: CodexTaskSnapshot) {
        if let lastPublishedCodexRevision {
            guard snapshot.revision > lastPublishedCodexRevision else { return }
        }
        lastPublishedCodexRevision = snapshot.revision
        preferences.codexPinnedThreadID = snapshot.threadID
        codexPinnedThreadID = snapshot.threadID
        isWaitingForNextCodexThread = false
        let milliseconds = Int64((snapshot.updatedAt.timeIntervalSince1970 * 1_000).rounded())
        guard let watchRevision = Int(exactly: snapshot.revision) else {
            operationError = "Codex 任务版本号超出手表端可接收范围。"
            return
        }
        let title = Self.codexTaskTitle(snapshot.prompt)
        let watchSnapshot = WatchCodexTaskSnapshot(
            threadID: snapshot.threadID,
            turnID: snapshot.turnID,
            workspaceLabel: Self.workspaceLabel(
                for: Self.canonicalWorkspacePath(snapshot.cwd)
            ),
            title: title,
            summary: snapshot.status == .completed ? snapshot.summary : nil,
            state: snapshot.status == .completed ? .completed : .running,
            revision: watchRevision,
            updatedAtEpochMilliseconds: milliseconds
        )
        codexTaskSnapshot = watchSnapshot
        codexTaskStateRevision = preferences.nextCodexTaskStateRevision()
        server.updateCodexTask(
            watchSnapshot,
            stateRevision: codexTaskStateRevision
        )
    }

    private static func codexTaskTitle(_ prompt: String?) -> String {
        let normalized = prompt?
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ") ?? ""
        guard !normalized.isEmpty else { return "Codex 当前任务" }
        let limit = 72
        return normalized.count <= limit
            ? normalized
            : String(normalized.prefix(limit - 1)) + "…"
    }

    private func handleInternetOperation(
        _ operation: WristInternetRelayOperation
    ) async -> WristInternetRelayResult {
        guard operation.validated() != nil else {
            return internetResult(operation, accepted: false, detail: "公网请求格式无效")
        }

        switch operation.kind {
        case .status:
            return internetResult(
                operation,
                accepted: true,
                status: currentInternetStatus
            )

        case .profileUpdate:
            guard let profile = operation.watchProfile,
                  operation.profileRevision == profile.revision
            else {
                return internetResult(
                    operation,
                    accepted: false,
                    detail: "独立映射无效、版本过期、内容冲突或引用了不存在的 App"
                )
            }
            switch installWatchProfile(profile) {
            case .accepted:
                return internetResult(
                    operation,
                    accepted: true,
                    status: currentInternetStatus
                )
            case .rejected:
                return internetResult(
                    operation,
                    accepted: false,
                    detail: "独立映射无效、版本过期、内容冲突或引用了不存在的 App"
                )
            case let .retryable(reason):
                return internetResult(
                    operation,
                    accepted: false,
                    detail: "语音进行中，独立映射保持不变；结束语音后将自动重试",
                    status: currentInternetStatus,
                    profileUpdateRetryReason: reason
                )
            }

        case .buttonEvent:
            guard operation.hasFreshButtonCommit(),
                  let command = operation.command,
                  let button = WristRemoteButton(rawValue: command.wireButtonID),
                  let rawTrigger = operation.buttonTrigger?.rawValue,
                  let trigger = WristRemoteTrigger(rawValue: rawTrigger),
                  operation.profileRevision == gestureDispatcher.profile?.revision
            else {
                return internetResult(
                    operation,
                    accepted: false,
                    detail: "公网按键已过期，或独立映射版本已变化"
                )
            }
            let accepted = gestureDispatcher.trigger(trigger, button: button)
            return internetResult(
                operation,
                accepted: accepted,
                detail: accepted ? nil : "该按键动作当前不可用"
            )

        case .voiceStart:
            guard let streamID = operation.streamID,
                  let intent = operation.voiceIntent,
                  intent != .codexConversation,
                  operation.profileRevision == gestureDispatcher.profile?.revision,
                  activeVoiceContext == nil,
                  (intent == .foregroundDictation
                    ? speechTranscriber.state.acceptsNewSession
                    : codexAudioInbox.acceptsNewSession),
                  intent == .foregroundDictation
                    ? operation.codexTaskIdentity == nil
                    : operation.codexTaskIdentity == WatchCodexTaskIdentity(codexTaskSnapshot)
            else {
                return internetResult(
                    operation,
                    accepted: false,
                    detail: "Mac 语音当前忙或任务已变化"
                )
            }
            activeVoiceContext = ActiveVoiceContext(
                sessionID: streamID.uuidString,
                intent: intent,
                codexTaskIdentity: operation.codexTaskIdentity,
                codexConversationTarget: nil,
                isInternetRelay: true
            )
            internetVoiceNextSequence = 0
            lastInternetVoiceOutcome = nil
            let started: Bool
            switch intent {
            case .foregroundDictation:
                started = speechTranscriber.start(requiresAccessibility: true)
            case .codexTask:
                do {
                    started = try codexAudioInbox.start(streamID: streamID)
                    speechState = .listening
                    lastTranscription = ""
                } catch {
                    let detail = error.localizedDescription
                    operationError = detail
                    speechState = .failed(detail)
                    started = false
                }
            case .codexConversation:
                started = false
            }
            guard started else {
                activeVoiceContext = nil
                return internetResult(
                    operation,
                    accepted: false,
                    detail: intent == .foregroundDictation
                        ? "Mac 无法启动中文语音识别"
                        : "Mac 无法安全接收 Codex 原始录音"
                )
            }
            scheduleInternetVoiceWatchdog(streamID: streamID)
            return internetResult(operation, accepted: true)

        case .audio:
            guard let streamID = operation.streamID,
                  let startSequence = operation.audioSequence,
                  let data = operation.pcm16Data,
                  let context = activeVoiceContext,
                  context.isInternetRelay,
                  context.sessionID == streamID.uuidString,
                  operation.profileRevision == gestureDispatcher.profile?.revision,
                  startSequence == internetVoiceNextSequence,
                  data.count.isMultiple(
                    of: WatchRemoteProtocol.audioPacketSampleCount
                        * MemoryLayout<Int16>.size
                  )
            else {
                return internetResult(
                    operation,
                    accepted: false,
                    detail: "语音分片过期、乱序或会话不匹配"
                )
            }
            let packetByteCount = WatchRemoteProtocol.audioPacketSampleCount
                * MemoryLayout<Int16>.size
            let packetCount = data.count / packetByteCount
            guard packetCount > 0, packetCount <= 10 else {
                return internetResult(operation, accepted: false, detail: "语音分片大小无效")
            }
            for offset in stride(from: 0, to: data.count, by: packetByteCount) {
                let packet = data.subdata(in: offset..<(offset + packetByteCount))
                guard let samples = WatchRemoteProtocol.decodePCM16(packet),
                      appendToActiveVoiceSession(samples)
                else {
                    return internetResult(operation, accepted: false, detail: "Mac 未接受语音分片")
                }
            }
            let lastSequence = startSequence + UInt64(packetCount - 1)
            internetVoiceNextSequence = lastSequence + 1
            scheduleInternetVoiceWatchdog(streamID: streamID)
            return WristInternetRelayResult(
                operationID: operation.operationID,
                accepted: true,
                audioAcknowledgement: WatchRemoteAudioAcknowledgement(
                    protocolVersion: WatchRemoteProtocol.version,
                    streamID: streamID,
                    profileRevision: operation.profileRevision ?? 0,
                    sequence: lastSequence,
                    accepted: true,
                    contiguousThrough: lastSequence
                )
            )

        case .voiceStop:
            guard let streamID = operation.streamID,
                  let context = activeVoiceContext,
                  context.isInternetRelay,
                  context.sessionID == streamID.uuidString,
                  operation.profileRevision == gestureDispatcher.profile?.revision,
                  operation.finalSequence.map({ $0 < internetVoiceNextSequence }) != false
            else {
                return internetResult(
                    operation,
                    accepted: false,
                    detail: "语音会话或尾包状态不匹配"
                )
            }
            internetVoiceWatchdog?.cancel()
            internetVoiceWatchdog = nil
            stopActiveVoiceSession()
            return internetResult(operation, accepted: true)

        case .codexReplySubmit:
            guard let identity = operation.codexTaskIdentity,
                  let submissionID = operation.submissionID,
                  let transcript = operation.transcript,
                  let snapshot = await codexCoordinator.currentSnapshot(),
                  snapshot.threadID == identity.threadID,
                  snapshot.turnID == identity.turnID,
                  Int(exactly: snapshot.revision) == identity.revision,
                  snapshot.status == .completed
            else {
                return internetResult(
                    operation,
                    accepted: false,
                    detail: "Codex 任务已经变化，请刷新后重试"
                )
            }
            do {
                guard let service = codexConversationService else {
                    throw CodexConversationServiceError.idempotencyLedgerUnavailable
                }
                _ = try await service.submit(CodexExistingConversationSubmission(
                    submissionID: submissionID,
                    threadID: identity.threadID,
                    message: transcript
                ))
                let detail = "已排入当前 Codex 聊天"
                codexDeliveryStatus = detail
                operationError = nil
                return internetResult(operation, accepted: true, detail: detail)
            } catch {
                let detail = Self.safeCodexConversationError(error)
                codexDeliveryStatus = "最近一次发送失败"
                operationError = "Codex 回复失败：\(detail)"
                return internetResult(operation, accepted: false, detail: detail)
            }
        }
    }

    private func internetResult(
        _ operation: WristInternetRelayOperation,
        accepted: Bool,
        detail: String? = nil,
        status: WristInternetRelayStatus? = nil,
        profileUpdateRetryReason: WatchProfileUpdateRetryReason? = nil
    ) -> WristInternetRelayResult {
        WristInternetRelayResult(
            operationID: operation.operationID,
            accepted: accepted,
            detail: detail.map { String($0.prefix(300)) },
            status: status,
            profileUpdateRetryReason: profileUpdateRetryReason
        )
    }

    private var currentInternetStatus: WristInternetRelayStatus {
        let profile = gestureDispatcher.profile
        let titles = Dictionary(uniqueKeysWithValues: WatchRemoteCommand.allCases.map { command in
            let binding = profile?.bindings[command.wireButtonID]?[WristRemoteTrigger.singleClick.rawValue]
            return (command.rawValue, internetButtonTitle(binding))
        })
        let triggers: [String: [WristInternetRelayButtonTrigger]] = Dictionary(
            uniqueKeysWithValues: WatchRemoteCommand.allCases.map { command in
            let enabled: [WristInternetRelayButtonTrigger] = WristRemoteTrigger.allCases.compactMap { trigger in
                guard let binding = profile?.bindings[command.wireButtonID]?[trigger.rawValue],
                      binding.action != .disabled
                else { return nil }
                return WristInternetRelayButtonTrigger(rawValue: trigger.rawValue)
            }
            return (command.rawValue, enabled)
        })
        return WristInternetRelayStatus(
            macName: Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
            profileRevision: profile?.revision,
            buttonTitles: titles,
            buttonTriggers: triggers,
            voiceOwner: activeVoiceContext == nil ? .none : .watch,
            codexTask: codexTaskSnapshot,
            codexTaskStateRevision: codexTaskStateRevision,
            voiceOutcome: lastInternetVoiceOutcome,
            speechLocaleIdentifier: speechLocaleIdentifier
        )
    }

    private func internetButtonTitle(_ binding: WatchActionBindingWire?) -> String {
        guard let binding else { return "未设置" }
        if binding.action == .customShortcut {
            return binding.shortcut?.keyLabel ?? "自定义快捷键"
        }
        if binding.action == .openCustomApplication,
           let rawID = binding.applicationProfileID,
           let id = UUID(uuidString: rawID),
           let title = applicationProfiles.first(where: { $0.id == id })?.title {
            return title
        }
        switch binding.action {
        case .disabled: return "未设置"
        case .escape: return "Escape"
        case .returnKey: return "Return"
        case .commandReturn: return "Command-Return"
        case .shiftReturn: return "Shift-Return"
        case .commandCopy: return "复制"
        case .commandPaste: return "粘贴"
        case .commandQuit: return "退出 App"
        case .arrowUp: return "上箭头"
        case .arrowDown: return "下箭头"
        case .arrowLeft: return "左箭头"
        case .arrowRight: return "右箭头"
        case .deleteBackward: return "退格删除"
        case .showDesktop: return "显示桌面"
        case .contextMenu: return "上下文菜单"
        case .appSwitcher: return "切换 App"
        case .volumeUp: return "系统音量加"
        case .volumeDown: return "系统音量减"
        case .volumeMute: return "系统静音"
        case .playPause: return "播放暂停"
        case .previousCommandLeft: return "上一个"
        case .nextCommandRight: return "下一个"
        case .customShortcut: return "自定义快捷键"
        case .openCustomApplication: return "Mac App"
        }
    }

    private func scheduleInternetVoiceWatchdog(streamID: UUID) {
        internetVoiceWatchdog?.cancel()
        internetVoiceWatchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(
                WristInternetVoiceLeasePolicy.timeoutMilliseconds
            ))
            guard let self,
                  !Task.isCancelled,
                  let context = activeVoiceContext,
                  context.isInternetRelay,
                  context.sessionID == streamID.uuidString
            else { return }
            internetVoiceWatchdog = nil
            finishVoiceWithFailure(
                context.intent == .foregroundDictation
                    ? "语音连接超时，未输入。"
                    : "Codex 原始录音连接超时，未发送。"
            )
        }
    }

    private func finishAbandonedInternetInteractions() {
        guard let context = activeVoiceContext, context.isInternetRelay else { return }
        internetVoiceWatchdog?.cancel()
        internetVoiceWatchdog = nil
        finishVoiceWithFailure(
            context.intent == .foregroundDictation
                ? "语音连接已中断，未输入。"
                : "Codex 原始录音连接已中断，未发送。"
        )
    }

    @discardableResult
    private func appendPrivateVoiceSamples(_ samples: [Int16], sessionID: String?) -> Bool {
        guard let sessionID, activeVoiceContext?.sessionID == sessionID,
              activeVoiceContext?.isInternetRelay == false else { return false }
        return appendToActiveVoiceSession(samples)
    }

    @discardableResult
    private func appendToActiveVoiceSession(_ samples: [Int16]) -> Bool {
        guard let context = activeVoiceContext else { return false }
        switch context.intent {
        case .foregroundDictation:
            return speechTranscriber.append(samples: samples)
        case .codexTask, .codexConversation:
            guard let streamID = UUID(uuidString: context.sessionID) else {
                finishVoiceWithFailure("Codex 原始录音会话无效，已停止。")
                return false
            }
            let accepted = codexAudioInbox.append(samples: samples, streamID: streamID)
            if !accepted {
                finishVoiceWithFailure("Mac 未能安全保存 Codex 原始录音，已停止发送。")
            }
            return accepted
        }
    }

    private func stopActiveVoiceSession() {
        guard let context = activeVoiceContext else { return }
        switch context.intent {
        case .foregroundDictation:
            speechTranscriber.stop()
        case .codexTask, .codexConversation:
            guard let streamID = UUID(uuidString: context.sessionID) else {
                finishVoiceWithFailure("Codex 原始录音会话无效，已停止。")
                return
            }
            speechState = .finalizing
            do {
                let recording = try codexAudioInbox.finish(streamID: streamID)
                submitCapturedCodexVoice(recording, context: context)
            } catch {
                finishVoiceWithFailure(error.localizedDescription)
            }
        }
    }

    /// Cancels forced resets and disconnects without turning a partial
    /// recording into a Codex message. The server owns any user-visible reason
    /// for these cancellations, so this cleanup deliberately emits no outcome.
    private func cancelActiveVoiceSession() {
        voiceStartReservation.cancel()
        codexVoiceSubmissionTask?.cancel()
        codexVoiceSubmissionTask = nil
        guard let context = activeVoiceContext else { return }
        switch context.intent {
        case .foregroundDictation:
            speechTranscriber.cancel()
        case .codexTask, .codexConversation:
            if let streamID = UUID(uuidString: context.sessionID) {
                codexAudioInbox.cancel(streamID: streamID)
            }
        }
        internetVoiceWatchdog?.cancel()
        internetVoiceWatchdog = nil
        speechState = .idle
        activeVoiceContext = nil
    }

    /// Transcribes one Watch recording with Codex and queues text to its exact
    /// Codex destination. The Watch stream UUID is reused as the durable
    /// submission identity, so a late duplicate callback cannot create a
    /// second message. The recording is removed after Codex app-server returns;
    /// no transcript, path, or audio bytes enter Bridge logs or ledgers.
    private func submitCapturedCodexVoice(
        _ recording: WatchCodexAudioInbox.FinalizedRecording,
        context: ActiveVoiceContext
    ) {
        guard activeVoiceContext?.sessionID == context.sessionID,
              let submissionID = UUID(uuidString: context.sessionID),
              recording.streamID == submissionID
        else {
            codexAudioInbox.remove(recording)
            return
        }

        internetVoiceWatchdog?.cancel()
        internetVoiceWatchdog = nil
        let coordinator = codexCoordinator
        let audioInbox = codexAudioInbox
        codexDeliveryStatus = "Codex 正在转写，尚未发送任务"
        codexVoiceSubmissionTask = Task { @MainActor [weak self, audioInbox] in
            defer { audioInbox.remove(recording) }
            guard let self else { return }
            guard self.activeVoiceContext?.sessionID == context.sessionID else { return }
            do {
                guard let service = self.codexConversationService else {
                    throw CodexConversationServiceError.idempotencyLedgerUnavailable
                }

                let outcome: WatchVoiceOutcome
                switch context.intent {
                case .foregroundDictation:
                    self.finishVoiceWithFailure("语音识别路径不匹配，已拒绝。")
                    return

                case .codexTask:
                    guard let identity = context.codexTaskIdentity,
                          let snapshot = await coordinator.currentSnapshot(),
                          snapshot.threadID == identity.threadID,
                          snapshot.turnID == identity.turnID,
                          Int(exactly: snapshot.revision) == identity.revision,
                          snapshot.status == .completed
                    else {
                        if self.activeVoiceContext?.sessionID == context.sessionID {
                            self.finishVoiceWithFailure(
                                "Codex 任务已经变化，语音没有发送；请刷新后重试。"
                            )
                        }
                        return
                    }
                    guard self.activeVoiceContext?.sessionID == context.sessionID else { return }
                    _ = try await service.submitAudio(CodexExistingConversationAudioSubmission(
                        submissionID: submissionID,
                        threadID: identity.threadID,
                        fileURL: recording.fileURL,
                        sha256Hex: recording.sha256Hex
                    ), validateBeforeQueue: { @MainActor [weak self] in
                        guard let self, self.activeVoiceContext?.sessionID == context.sessionID,
                              let latest = await coordinator.currentSnapshot(),
                              latest.threadID == identity.threadID,
                              latest.turnID == identity.turnID,
                              Int(exactly: latest.revision) == identity.revision,
                              latest.status == .completed
                        else { throw CodexNativeVoiceError.targetChanged }
                    })
                    outcome = WatchVoiceOutcome(
                        sessionID: context.sessionID,
                        intent: .codexTask,
                        threadID: identity.threadID,
                        turnID: identity.turnID,
                        taskRevision: identity.revision,
                        kind: .delivered,
                        text: nil,
                        detail: "已转写并排入当前 Codex 任务，等待处理",
                        localeIdentifier: self.speechLocaleIdentifier
                    )
                    self.codexDeliveryStatus = "已转写并排入当前 Codex 任务"

                case .codexConversation:
                    guard let target = context.codexConversationTarget else {
                        self.finishVoiceWithFailure(
                            "语音结果缺少已选 Codex 会话，已拒绝。"
                        )
                        return
                    }
                    let resolved = try await self.codexConversationAuthority
                        .resolveActiveRecording(target)
                    guard self.activeVoiceContext?.sessionID == context.sessionID else { return }
                    guard target.kind == .existing,
                          let threadID = resolved.threadID
                    else {
                        self.finishVoiceWithFailure(
                            "新任务尚未独立创建，请重新选择“新建任务”。"
                        )
                        return
                    }
                    _ = try await service.submitAudio(CodexExistingConversationAudioSubmission(
                        submissionID: submissionID,
                        threadID: threadID,
                        fileURL: recording.fileURL,
                        sha256Hex: recording.sha256Hex
                    ), validateBeforeQueue: { @MainActor [weak self] in
                        guard let self, self.activeVoiceContext?.sessionID == context.sessionID else {
                            throw CodexNativeVoiceError.targetChanged
                        }
                        do {
                            let latest = try await self.codexConversationAuthority.resolveActiveRecording(target)
                            guard latest.threadID == threadID,
                                  self.activeVoiceContext?.sessionID == context.sessionID else {
                                throw CodexNativeVoiceError.targetChanged
                            }
                        } catch { throw CodexNativeVoiceError.targetChanged }
                    })
                    outcome = WatchVoiceOutcome(
                        sessionID: context.sessionID,
                        intent: .codexConversation,
                        threadID: nil,
                        kind: .delivered,
                        text: nil,
                        detail: "已转写并排入所选任务，等待 Codex 处理",
                        localeIdentifier: self.speechLocaleIdentifier
                    )
                    self.codexDeliveryStatus = "已转写并排入所选 Codex 任务"
                }

                guard self.activeVoiceContext?.sessionID == context.sessionID else { return }
                self.operationError = nil
                self.speechState = .idle
                if context.isInternetRelay { self.lastInternetVoiceOutcome = outcome }
                self.server.sendVoiceOutcome(outcome)
                self.activeVoiceContext = nil
                self.codexVoiceSubmissionTask = nil
            } catch {
                guard self.activeVoiceContext?.sessionID == context.sessionID else { return }
                let detail = Self.safeCodexConversationError(error)
                self.codexDeliveryStatus = error is CodexNativeVoiceError
                    ? "本次语音未发送" : "最近一次发送结果未确认"
                self.operationError = detail
                self.finishVoiceWithFailure(detail)
            }
        }
    }

    private func finishVoiceWithFailure(_ detail: String) {
        codexVoiceSubmissionTask?.cancel()
        codexVoiceSubmissionTask = nil
        guard let context = activeVoiceContext else { return }
        switch context.intent {
        case .foregroundDictation:
            speechTranscriber.cancel()
        case .codexTask, .codexConversation:
            if let streamID = UUID(uuidString: context.sessionID) {
                codexAudioInbox.cancel(streamID: streamID)
            }
        }
        speechState = .failed(detail)
        let outcome = WatchVoiceOutcome(
            sessionID: context.sessionID,
            intent: context.intent,
            threadID: context.codexTaskIdentity?.threadID,
            turnID: context.codexTaskIdentity?.turnID,
            taskRevision: context.codexTaskIdentity?.revision,
            kind: .failed,
            text: nil,
            detail: detail,
            localeIdentifier: speechLocaleIdentifier
        )
        if context.isInternetRelay { lastInternetVoiceOutcome = outcome }
        server.sendVoiceOutcome(outcome)
        internetVoiceWatchdog?.cancel()
        internetVoiceWatchdog = nil
        activeVoiceContext = nil
    }

    private func persistApplicationsAndInvalidateProfiles() {
        applicationProfiles = BridgePreferences.normalizedProfiles(applicationProfiles)
        preferences.applicationProfiles = applicationProfiles
        actionEngine.updateApplicationProfiles(applicationProfiles)
        publishApplicationTitles()
        server.invalidateProfiles(detail: "独立 App 清单已变化，请重新同步映射。")
    }

    private func publishApplicationTitles() {
        let titles = Dictionary(uniqueKeysWithValues: applicationProfiles.map {
            ($0.id.uuidString, $0.title)
        })
        server.updateApplicationTitles(titles)
    }

    private func restorePersistedWatchProfile() {
        guard let profile = preferences.watchActionProfile,
              actionEngine.canInstall(profile),
              gestureDispatcher.install(profile)
        else {
            gestureDispatcher.reset()
            server.updateWatchProfile(nil)
            return
        }
        server.updateWatchProfile(profile)
    }

    @discardableResult
    private func installWatchProfile(
        _ candidate: WatchActionProfileWire
    ) -> WatchProfileRuntimeInstallResult {
        if let retryReason = WatchProfileRuntimeUpdatePolicy.retryReason(
            hasActiveVoiceSession: activeVoiceContext != nil || voiceStartReservation.pending != nil
        ) {
            return .retryable(retryReason)
        }
        switch WatchPersistedProfileGate.decide(
            candidate: candidate,
            current: preferences.watchActionProfile
        ) {
        case .reject:
            return .rejected
        case .alreadyReady:
            guard actionEngine.canInstall(candidate) else { return .rejected }
            guard gestureDispatcher.profile == candidate || gestureDispatcher.install(candidate)
            else { return .rejected }
            server.updateWatchProfile(candidate)
            return .accepted
        case let .accept(profile):
            guard actionEngine.canInstall(profile),
                  gestureDispatcher.install(profile)
            else { return .rejected }
            preferences.watchActionProfile = profile
            server.updateWatchProfile(profile)
            return .accepted
        }
    }
}
