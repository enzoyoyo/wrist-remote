import AppKit
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
    @Published private(set) var codexPinnedThreadID: String?
    @Published private(set) var isWaitingForNextCodexThread = false
    @Published private(set) var codexDeliveryStatus = "尚未从手表发送"
    @Published private(set) var internetRelayStatus: InternetRelayClient.Status = .stopped
    @Published var pairingRequest: PairingRequest?
    @Published var operationError: String?

    private let preferences: BridgePreferences
    private let server: WristRemoteServer
    private let actionEngine: WatchActionEngine
    private let gestureDispatcher: WatchGestureDispatcher
    private let speechTranscriber: WatchSpeechTranscriber
    private let codexCoordinator: CodexTaskCoordinator
    private let codexHookReceiver: CodexHookReceiver
    private let codexReplyRunner: CodexReplyRunner
    private let internetRelay: InternetRelayClient?
    private var hasStarted = false
    private var lastPublishedCodexRevision: Int64?
    private var codexTaskStateRevision: Int
    private struct ActiveVoiceContext {
        let sessionID: String
        let intent: WatchVoiceIntent
        let codexTaskIdentity: WatchCodexTaskIdentity?
        let isInternetRelay: Bool
    }
    private var activeVoiceContext: ActiveVoiceContext?
    private var lastInternetVoiceOutcome: WatchVoiceOutcome?
    private var internetVoiceNextSequence: UInt64 = 0
    private var internetVoiceWatchdog: Task<Void, Never>?

    init(
        preferences: BridgePreferences = BridgePreferences(),
        server: WristRemoteServer = WristRemoteServer(),
        actionEngine: WatchActionEngine? = nil,
        gestureDispatcher: WatchGestureDispatcher? = nil,
        speechTranscriber: WatchSpeechTranscriber? = nil
    ) {
        let codexCoordinator = CodexTaskCoordinator(
            pinnedThreadID: preferences.codexPinnedThreadID
        )
        let internetRelay = WristInternetRelayMacCredentialStore.loadOrCreate().map {
            InternetRelayClient(credentials: $0)
        }
        let codexTaskStateRevision = preferences.nextCodexTaskStateRevision()
        self.preferences = preferences
        self.server = server
        self.actionEngine = actionEngine ?? WatchActionEngine()
        self.gestureDispatcher = gestureDispatcher ?? WatchGestureDispatcher()
        self.speechTranscriber = speechTranscriber ?? WatchSpeechTranscriber()
        self.codexCoordinator = codexCoordinator
        self.internetRelay = internetRelay
        self.codexTaskStateRevision = codexTaskStateRevision
        codexPinnedThreadID = preferences.codexPinnedThreadID
        codexHookReceiver = CodexHookReceiver(coordinator: codexCoordinator)
        codexReplyRunner = CodexReplyRunner(
            coordinator: codexCoordinator,
            submissionLedger: .persistentDefault()
        )
        speechLocaleIdentifier = self.speechTranscriber.recognitionLocaleIdentifier ?? "zh-CN"
        applicationProfiles = preferences.applicationProfiles
        configureComponents()
        restorePersistedWatchProfile()
        configureCodexBridge()
    }

    var statusTitle: String {
        switch serverStatus {
        case .stopped: return "未启动"
        case .starting: return "正在启动"
        case .ready: return "等待 Wrist Remote"
        case let .connected(name): return "已连接 · \(name)"
        case .failed: return "启动失败"
        }
    }

    var statusDetail: String {
        switch serverStatus {
        case .stopped:
            return "服务未运行。"
        case .starting:
            return "正在发布独立的本地网络服务。"
        case .ready:
            return "只接受 Wrist Remote iPhone 与 Apple Watch。"
        case .connected:
            return "Apple Watch 按键按独立映射执行。"
        case let .failed(detail):
            return detail
        }
    }

    var internetRelayStatusTitle: String {
        switch internetRelayStatus {
        case .stopped: return "未启动"
        case .connecting: return "正在连接"
        case .connected: return "已连接"
        case .unavailable: return "正在重连"
        }
    }

    var internetRelayStatusDetail: String {
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
        server.updateSpeechLocaleIdentifier(speechLocaleIdentifier)
        server.updateInternetRelayProvisioning(
            internetRelay?.credentials.provisioning.encodedBase64()
        )
        server.start()
        internetRelay?.start()
        let coordinator = codexCoordinator
        Task { @MainActor [weak self] in
            await coordinator.setSnapshotObserver { [weak self] snapshot in
                Task { @MainActor in self?.publishCodexSnapshot(snapshot) }
            }
            self?.codexHookReceiver.start()
        }
    }

    func refreshSystemStatus() {
        isAccessibilityTrusted = WatchActionEngine.isAccessibilityTrusted
        speechAuthorization = WatchSpeechTranscriber.authorizationStatus
        launchAtLoginStatus = SMAppService.mainApp.status
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
        server.isIdentityTrusted = { [weak preferences] fingerprint in
            preferences?.trusts(fingerprint) ?? false
        }
        server.onIdentityApproved = { [weak preferences] fingerprint in
            preferences?.trust(fingerprint)
        }
        server.onApprovalRequested = { [weak self] name, code, fingerprint, completion in
            DispatchQueue.main.async {
                self?.pairingRequest = PairingRequest(
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
        server.onProfileReset = { [weak self] in
            DispatchQueue.main.async { self?.restorePersistedWatchProfile() }
        }
        server.onVoiceStart = { [weak self] sessionID, intent, codexTaskIdentity, completion in
            DispatchQueue.main.async {
                guard let self,
                      let sessionID,
                      UUID(uuidString: sessionID) != nil,
                      (intent == .foregroundDictation && codexTaskIdentity == nil)
                        || (intent == .codexTask && codexTaskIdentity != nil),
                      self.activeVoiceContext == nil,
                      self.speechTranscriber.state.acceptsNewSession
                else {
                    completion(false)
                    return
                }
                self.activeVoiceContext = ActiveVoiceContext(
                    sessionID: sessionID,
                    intent: intent,
                    codexTaskIdentity: codexTaskIdentity,
                    isInternetRelay: false
                )
                let started = self.speechTranscriber.start(
                    requiresAccessibility: intent == .foregroundDictation
                )
                if !started, case .failed = self.speechTranscriber.state {
                    // onStateChange publishes the exact failure and clears the context.
                }
                completion(started)
            }
        }
        server.onVoiceStop = { [weak self] in
            DispatchQueue.main.async { self?.speechTranscriber.stop() }
        }
        server.onAudio = { [weak self] samples in
            DispatchQueue.main.async { _ = self?.speechTranscriber.append(samples: samples) }
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
            switch context.intent {
            case .foregroundDictation:
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
            case .codexTask:
                guard let identity = context.codexTaskIdentity else {
                    finishVoiceWithFailure("语音结果缺少 Codex 任务身份，已拒绝。")
                    return
                }
                let outcome = WatchVoiceOutcome(
                    sessionID: context.sessionID,
                    intent: context.intent,
                    threadID: identity.threadID,
                    turnID: identity.turnID,
                    taskRevision: identity.revision,
                    kind: .draft,
                    text: text,
                    detail: nil,
                    localeIdentifier: speechLocaleIdentifier
                )
                if context.isInternetRelay { lastInternetVoiceOutcome = outcome }
                server.sendVoiceOutcome(outcome)
            }
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
        let replyRunner = codexReplyRunner
        server.onCodexReplySubmit = {
            [weak self] submissionID, identity, transcript, completion in
            Task {
                guard let snapshot = await coordinator.currentSnapshot(),
                      snapshot.threadID == identity.threadID,
                      snapshot.turnID == identity.turnID,
                      Int(exactly: snapshot.revision) == identity.revision,
                      snapshot.status == .completed
                else {
                    completion(false, "Codex 任务已经变化，请在手表刷新后重试。")
                    return
                }
                do {
                    let result = try await replyRunner.submit(CodexReplyRequest(
                        submissionID: submissionID,
                        threadID: identity.threadID,
                        turnID: identity.turnID,
                        cwd: snapshot.cwd,
                        transcript: transcript,
                        userConfirmed: true
                    ))
                    let detail: String
                    switch result.state {
                    case .delivered:
                        detail = "已送达当前 Codex 聊天"
                    case .queued:
                        detail = "已排入当前 Codex 聊天；Codex 空闲后自动发送"
                    }
                    await MainActor.run {
                        self?.codexDeliveryStatus = detail
                        self?.operationError = nil
                    }
                    completion(true, detail)
                } catch {
                    let detail = error.localizedDescription
                    await MainActor.run {
                        self?.codexDeliveryStatus = "最近一次发送失败"
                        self?.operationError = "Codex 回复失败：\(detail)"
                    }
                    completion(false, detail)
                }
            }
        }
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
            cwd: snapshot.cwd,
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
                  operation.profileRevision == gestureDispatcher.profile?.revision,
                  activeVoiceContext == nil,
                  speechTranscriber.state.acceptsNewSession,
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
                isInternetRelay: true
            )
            internetVoiceNextSequence = 0
            lastInternetVoiceOutcome = nil
            let started = speechTranscriber.start(
                requiresAccessibility: intent == .foregroundDictation
            )
            guard started else {
                activeVoiceContext = nil
                return internetResult(
                    operation,
                    accepted: false,
                    detail: "Mac 无法启动中文语音识别"
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
                      speechTranscriber.append(samples: samples)
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
            speechTranscriber.stop()
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
                let result = try await codexReplyRunner.submit(CodexReplyRequest(
                    submissionID: submissionID,
                    threadID: identity.threadID,
                    turnID: identity.turnID,
                    cwd: snapshot.cwd,
                    transcript: transcript,
                    userConfirmed: true
                ))
                let detail = result.state == .delivered
                    ? "已送达当前 Codex 聊天"
                    : "已排入当前 Codex 聊天；Codex 空闲后自动发送"
                codexDeliveryStatus = detail
                operationError = nil
                return internetResult(operation, accepted: true, detail: detail)
            } catch {
                let detail = error.localizedDescription
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
                  activeVoiceContext?.isInternetRelay == true,
                  activeVoiceContext?.sessionID == streamID.uuidString
            else { return }
            internetVoiceWatchdog = nil
            speechTranscriber.stop()
        }
    }

    private func finishAbandonedInternetInteractions() {
        guard activeVoiceContext?.isInternetRelay == true else { return }
        internetVoiceWatchdog?.cancel()
        internetVoiceWatchdog = nil
        speechTranscriber.stop()
    }

    private func finishVoiceWithFailure(_ detail: String) {
        guard let context = activeVoiceContext else { return }
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
            return
        }
    }

    @discardableResult
    private func installWatchProfile(
        _ candidate: WatchActionProfileWire
    ) -> WatchProfileRuntimeInstallResult {
        if let retryReason = WatchProfileRuntimeUpdatePolicy.retryReason(
            hasActiveVoiceSession: activeVoiceContext != nil
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
            if gestureDispatcher.profile == candidate { return .accepted }
            return gestureDispatcher.install(candidate) ? .accepted : .rejected
        case let .accept(profile):
            guard actionEngine.canInstall(profile),
                  gestureDispatcher.install(profile)
            else { return .rejected }
            preferences.watchActionProfile = profile
            return .accepted
        }
    }
}
