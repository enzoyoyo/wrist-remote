import SwiftUI

struct CodexConversationVoiceButton: View {
    @ObservedObject var controller: WatchSessionController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(WatchHaptics.isEnabledDefaultsKey) private var hapticsEnabled = true
    @State private var pressState = WatchVoicePressState()
    @State private var holdTask: Task<Void, Never>?
    @GestureState private var fingerIsDown = false
    @State private var localHint: String?
    @State private var showsStatus = false

    private var isGestureHeld: Bool {
        pressState.phase == .holding || pressState.phase == .recording
    }

    var body: some View {
        VStack(spacing: 3) {
            Group {
                HStack(spacing: 10) {
                    Image(systemName: microphoneSymbol)
                        .font(.title3.weight(.semibold))

                    VStack(alignment: .leading, spacing: 1) {
                        Text(buttonTitle)
                            .font(.body.weight(.semibold))
                        Text(compactHint)
                            .font(.caption2)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)
                }
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                .padding(.horizontal, 12)
                .background(Color.wristRemoteAccent)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .scaleEffect(!reduceMotion && isGestureHeld ? 0.98 : 1)
                .animation(
                    reduceMotion ? nil : .easeOut(duration: 0.1),
                    value: isGestureHeld
                )
                .contentShape(Rectangle())
            }
            .opacity(isControlEnabled ? 1 : 0.42)
            .gesture(holdGesture)
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("codex-voice-control")
            .accessibilityLabel("Codex 中文语音")
            .accessibilityValue(accessibilityValue)
            .accessibilityHint(accessibilityHint)
            .accessibilityAction {
                toggleAccessibilityVoice()
            }
            .accessibilityAction(named: Text("开始中文语音")) {
                beginAccessibilityVoice()
            }
            .accessibilityAction(named: Text("结束中文语音")) {
                endAccessibilityVoice()
            }
            .accessibilityAction(named: Text("取消中文语音")) {
                cancelAccessibilityVoice()
            }
            .accessibilityAction(named: Text("状态详情")) { showsStatus = true }

            if isInteractionInProgress, pressState.phase == .idle {
                Button("取消录音", role: .cancel, action: cancelAccessibilityVoice)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("codex-voice-cancel")
            }
        }
        .alert("语音状态", isPresented: $showsStatus) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(statusText)
        }
        .onDisappear(perform: cancelInteraction)
        .onChange(of: controller.codexVoiceStatusText) { _, _ in localHint = nil }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase != .active else { return }
            cancelInteraction()
        }
        .onChange(of: fingerIsDown) { _, isDown in
            // GestureState also resets when the system cancels a recognizer
            // without delivering onEnded. Never leave the microphone running.
            if !isDown, pressState.phase != .idle {
                // Allow a normal onEnded to finish first. A recognizer
                // cancellation has no onEnded and still tears down next turn.
                let generation = pressState.generation
                Task { @MainActor in
                    await Task.yield()
                    guard !fingerIsDown, pressState.generation == generation,
                          pressState.phase != .idle else { return }
                    cancelInteraction()
                }
            }
        }
    }

    private var isInteractionInProgress: Bool {
        controller.isCodexConversationVoicePreparing
            || controller.isCodexConversationVoiceRecording
    }

    private var isControlEnabled: Bool {
        controller.canStartCodexConversationVoice || isInteractionInProgress || isGestureHeld
    }

    private var microphoneSymbol: String {
        if controller.isCodexConversationVoiceRecording { return "waveform" }
        if controller.isCodexConversationVoicePreparing { return "ellipsis" }
        return "mic.fill"
    }

    private var buttonTitle: String {
        if controller.isCodexConversationVoiceRecording { return "正在听" }
        if controller.isCodexConversationVoicePreparing { return "正在准备" }
        if controller.isCodexVoiceInteractionInProgress { return "正在发送" }
        return "按住说话"
    }

    private var buttonDetail: String {
        if controller.isCodexConversationVoiceRecording { return "松开立即发送" }
        if controller.isCodexVoiceInteractionInProgress { return "等待 Mac 确认" }
        return hapticsEnabled ? "震动后开始说" : "显示正在听后说"
    }

    private var statusText: String {
        if isInteractionInProgress { return buttonDetail }
        if let status = controller.codexVoiceStatusText?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !status.isEmpty {
            return status
        }
        if let localHint { return localHint }
        if controller.selectedCodexTarget == nil { return "先选择发送目标" }
        return readyToSpeakHint
    }

    private var readyToSpeakHint: String {
        hapticsEnabled ? "请按住直到震动" : "请按住到显示“正在听”"
    }

    private var compactHint: String {
        if controller.isCodexConversationVoiceRecording { return "松开发送" }
        if controller.isCodexConversationVoicePreparing { return "请继续按住" }
        if controller.isCodexVoiceInteractionInProgress { return "等待确认" }
        if pressState.phase == .cancelled { return "本次已取消" }
        if controller.selectedCodexTarget == nil { return "先选择会话" }
        if !controller.canStartCodexConversationVoice { return "尚未就绪" }
        return hapticsEnabled ? "震动后说话" : "显示正在听后说"
    }

    private var accessibilityHint: String {
        let startCue = hapticsEnabled ? "等待开始震动" : "等待显示正在听"
        return "按住并\(startCue)后说话，松开后由 Codex 转写并发送到所选任务；移开可取消。VoiceOver 可用开始、结束与取消语音动作"
    }

    private var accessibilityValue: String {
        if controller.isCodexConversationVoiceRecording { return "正在录音" }
        if controller.isCodexConversationVoicePreparing { return "正在准备麦克风" }
        if !controller.canStartCodexConversationVoice { return statusText }
        return "可以开始"
    }

    private var holdGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($fingerIsDown) { _, state, _ in state = true }
            .onChanged { value in
                if pressState.phase == .idle { beginHold() }
                let distance = hypot(value.translation.width, value.translation.height)
                if pressState.move(distance: Double(distance)) {
                    controller.cancelCodexConversationVoice()
                }
                if pressState.phase == .cancelled {
                    holdTask?.cancel()
                    localHint = "本次录音已丢弃"
                }
            }
            .onEnded { _ in
                holdTask?.cancel()
                let wasCancelled = pressState.phase == .cancelled
                if pressState.end() {
                    controller.setCodexConversationVoicePressed(false)
                    localHint = nil
                } else if !wasCancelled {
                    localHint = readyToSpeakHint
                }
            }
    }

    private func beginHold() {
        guard controller.canStartCodexConversationVoice,
              let generation = pressState.begin() else { return }
        localHint = nil
        holdTask?.cancel()
        holdTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled,
                  pressState.recognize(
                      generation: generation,
                      canStart: controller.canStartCodexConversationVoice
                  ) else { return }
            controller.setCodexConversationVoicePressed(true)
        }
    }

    private func toggleAccessibilityVoice() {
        isInteractionInProgress ? endAccessibilityVoice() : beginAccessibilityVoice()
    }

    private func beginAccessibilityVoice() {
        guard controller.canStartCodexConversationVoice else {
            localHint = statusText
            return
        }
        localHint = nil
        controller.setCodexConversationVoicePressed(true)
    }

    private func endAccessibilityVoice() {
        guard isInteractionInProgress else { return }
        controller.setCodexConversationVoicePressed(false)
    }

    private func cancelAccessibilityVoice() {
        localHint = "已取消"
        controller.cancelCodexConversationVoice()
        resetGestureState()
    }

    private func cancelInteraction() {
        if pressState.phase == .recording || isInteractionInProgress {
            controller.cancelCodexConversationVoice()
        }
        resetGestureState()
    }

    private func resetGestureState() {
        holdTask?.cancel()
        holdTask = nil
        pressState.reset()
    }
}
