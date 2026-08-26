import SwiftUI
import WatchKit

extension Color {
    static let wristRemoteAccent = Color(
        red: 0,
        green: 47.0 / 255.0,
        blue: 167.0 / 255.0
    )
}

struct WatchRemoteRootView: View {
    @ObservedObject var controller: WatchSessionController

    var body: some View {
        NavigationStack {
            CodexTaskHomeView(controller: controller)
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
        }
        .background(Color.black.ignoresSafeArea())
    }
}

private struct CodexTaskHomeView: View {
    @ObservedObject var controller: WatchSessionController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !controller.isReady {
                    CompactConnectionIssue(controller: controller)
                } else {
                    CompactConnectionPath(controller: controller)
                }

                if let task = controller.codexTaskSnapshot {
                    CodexTaskSummary(task: task)
                        .id("\(task.threadID)-\(task.revision)")
                        .transition(
                            reduceMotion
                                ? .opacity
                                : .move(edge: .bottom).combined(with: .opacity)
                        )
                } else {
                    CodexTaskEmptyState()
                }

                if let draft = normalizedDraft {
                    CodexReplyDraftView(
                        draft: draft,
                        isSubmitting: controller.isCodexReplySubmitting,
                        submit: controller.submitCodexReply,
                        discard: controller.discardCodexReply
                    )
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .move(edge: .bottom).combined(with: .opacity)
                    )
                } else {
                    CodexVoiceInputView(controller: controller)
                }

                Divider()

                NavigationLink {
                    RemoteDeckView(controller: controller)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "appletvremote.gen1.fill")
                            .foregroundStyle(Color.wristRemoteAccent)
                        Text("遥控器")
                            .font(.body.weight(.semibold))
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("打开独立的方向、功能和收藏遥控页面")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .background(Color.black)
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.18),
            value: controller.codexTaskSnapshot?.revision
        )
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.18),
            value: normalizedDraft
        )
    }

    private var normalizedDraft: String? {
        guard let draft = controller.codexReplyDraft?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !draft.isEmpty
        else { return nil }
        return draft
    }
}

private struct CodexTaskSummary: View {
    let task: WatchCodexTaskSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Codex")
                    .font(.headline)
                Spacer(minLength: 4)
                stateLabel
            }

            Text(task.title)
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("当前任务：\(task.title)")

            if task.state == .completed {
                VStack(alignment: .leading, spacing: 4) {
                    Text("结果摘要")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(completedSummary)
                        .font(.footnote)
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if task.state == .failed, let summary = normalizedSummary {
                Text(summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var stateLabel: some View {
        switch task.state {
        case .running:
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.mini)
                    .tint(Color.wristRemoteAccent)
                Text("执行中")
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.wristRemoteAccent)
            .accessibilityElement(children: .combine)
        case .completed:
            Label("已完成", systemImage: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.wristRemoteAccent)
        case .failed:
            Label("未完成", systemImage: "exclamationmark.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }

    private var normalizedSummary: String? {
        guard let summary = task.summary?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !summary.isEmpty
        else { return nil }
        return summary
    }

    private var completedSummary: String {
        normalizedSummary ?? "任务已完成，摘要正在同步。"
    }
}

private struct CodexTaskEmptyState: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Codex")
                .font(.headline)
            Text("等待当前任务")
                .font(.body.weight(.semibold))
            Text("Mac 上开始执行后，任务和结果会在这里同步。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct CodexVoiceInputView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var controller: WatchSessionController
    @State private var gestureInProgress = false
    @State private var gestureCancelled = false
    @State private var didBeginVoice = false
    @State private var holdTask: Task<Void, Never>?

    private let holdDelayMilliseconds = 180
    private let movementTolerance: CGFloat = 18

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(Color.wristRemoteAccent)
                    .frame(width: 58, height: 58)
                Image(systemName: microphoneSymbol)
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .scaleEffect(
                !reduceMotion && (gestureInProgress || controller.isCodexVoiceRecording)
                    ? 0.94 : 1
            )
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.12),
                value: gestureInProgress
            )
            .contentShape(Circle())
            .simultaneousGesture(holdGesture)
            .allowsHitTesting(
                controller.canStartCodexVoice || controller.isCodexVoiceInteractionInProgress
            )
            .opacity(
                controller.canStartCodexVoice || controller.isCodexVoiceInteractionInProgress
                    ? 1 : 0.42
            )
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Codex 中文语音")
            .accessibilityValue(controller.isCodexVoiceRecording ? "正在录音" : voiceStatusText)
            .accessibilityHint("按住并等待震动后说中文，松开生成草稿")
            .accessibilityAction {
                controller.isCodexVoiceInteractionInProgress ? endVoice() : beginVoice()
            }
            .accessibilityAction(named: Text("开始中文语音")) {
                beginVoice()
            }
            .accessibilityAction(named: Text("结束中文语音")) {
                endVoice()
            }

            Text(visibleStatusText)
                .font(.footnote)
                .foregroundStyle(
                    controller.isCodexVoiceRecording ? Color.wristRemoteAccent : Color.secondary
                )
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
        .onDisappear {
            cancelGesture()
            controller.cancelCodexVoiceGesture()
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase != .active else { return }
            cancelGesture()
            controller.cancelCodexVoiceGesture()
        }
    }

    private var microphoneSymbol: String {
        if controller.isCodexVoiceRecording { return "waveform" }
        if controller.isCodexVoicePreparing { return "ellipsis" }
        return "mic.fill"
    }

    private var visibleStatusText: String {
        if controller.isCodexVoiceRecording { return "正在听中文…" }
        if controller.isCodexVoicePreparing { return "正在准备麦克风…" }
        return voiceStatusText
    }

    private var voiceStatusText: String {
        if let status = controller.codexVoiceStatusText?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !status.isEmpty {
            return status
        }
        return "按住，震动后说中文"
    }

    private var holdGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard controller.canStartCodexVoice || gestureInProgress else { return }
                if !gestureInProgress {
                    gestureInProgress = true
                    gestureCancelled = false
                    didBeginVoice = false
                    holdTask?.cancel()
                    holdTask = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(holdDelayMilliseconds))
                        guard !Task.isCancelled,
                              gestureInProgress,
                              !gestureCancelled,
                              controller.canStartCodexVoice
                        else { return }
                        didBeginVoice = true
                        controller.setCodexVoicePressed(true)
                    }
                }
                let distance = hypot(value.translation.width, value.translation.height)
                if distance > movementTolerance {
                    gestureCancelled = true
                    holdTask?.cancel()
                    holdTask = nil
                    if didBeginVoice { controller.cancelCodexVoiceGesture() }
                }
            }
            .onEnded { _ in
                holdTask?.cancel()
                holdTask = nil
                if didBeginVoice, !gestureCancelled {
                    controller.setCodexVoicePressed(false)
                }
                resetGestureState()
            }
    }

    private func beginVoice() {
        guard controller.canStartCodexVoice else { return }
        controller.setCodexVoicePressed(true)
    }

    private func endVoice() {
        controller.setCodexVoicePressed(false)
    }

    private func cancelGesture() {
        holdTask?.cancel()
        holdTask = nil
        if didBeginVoice { controller.cancelCodexVoiceGesture() }
        resetGestureState()
    }

    private func resetGestureState() {
        gestureInProgress = false
        gestureCancelled = false
        didBeginVoice = false
    }
}

private struct CodexReplyDraftView: View {
    let draft: String
    let isSubmitting: Bool
    let submit: () -> Void
    let discard: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("发送前确认")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(draft)
                .font(.footnote)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("语音草稿：\(draft)")

            HStack(spacing: 8) {
                Button(action: discard) {
                    Label("重说", systemImage: "xmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(Color.secondary)
                .disabled(isSubmitting)

                Button(action: submit) {
                    Label("发送", systemImage: "arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSubmitting)
            }
        }
    }
}

private struct CompactConnectionIssue: View {
    @ObservedObject var controller: WatchSessionController

    var body: some View {
        Button {
            controller.requestStatus()
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle")
                        .foregroundStyle(.secondary)
                    Text(controller.statusText)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                Text(controller.statusDetail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("连接状态：\(controller.statusText)")
        .accessibilityValue(controller.statusDetail)
        .accessibilityHint("轻点刷新连接状态")
    }
}

private struct CompactConnectionPath: View {
    @ObservedObject var controller: WatchSessionController

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(Color.green)
                .frame(width: 5, height: 5)
            Text(controller.statusText)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("当前连接：\(controller.statusText)")
    }
}

private enum RemoteDeckPage: Int, CaseIterable, Identifiable {
    case direction
    case controls
    case favorites

    var id: Self { self }

    var title: String {
        switch self {
        case .direction: return "方向"
        case .controls: return "功能"
        case .favorites: return "收藏"
        }
    }

    var systemImage: String {
        switch self {
        case .direction: return "circle.grid.cross"
        case .controls: return "rectangle.grid.3x2"
        case .favorites: return "star.fill"
        }
    }
}

private struct RemoteDeckView: View {
    @ObservedObject var controller: WatchSessionController
    @State private var selectedPage = RemoteDeckPage.direction

    var body: some View {
        VStack(spacing: 6) {
            if !controller.isReady {
                CompactConnectionIssue(controller: controller)
            }

            // Page selection is explicit so a swipe that begins on a remote
            // button can never also become a remote press.
            Group {
                switch selectedPage {
                case .direction:
                    DirectionRemotePage(controller: controller)
                case .controls:
                    FunctionRemotePage(controller: controller)
                case .favorites:
                    FavoritesRemotePage(controller: controller)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.black)
        .navigationTitle(selectedPage.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    RemoteDeckPageSelectionView(selectedPage: $selectedPage)
                } label: {
                    Image(systemName: "rectangle.3.group")
                }
                .accessibilityIdentifier("remote-page-picker")
                .accessibilityLabel("选择遥控页")
                .accessibilityValue(selectedPage.title)
                .accessibilityHint("选择方向、功能或收藏页面，不会触发遥控按键")
            }
        }
    }
}

private struct RemoteDeckPageSelectionView: View {
    @Binding var selectedPage: RemoteDeckPage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List(RemoteDeckPage.allCases) { page in
            Button {
                if page != selectedPage {
                    WatchHaptics.play(
                        page.rawValue > selectedPage.rawValue ? .directionDown : .directionUp
                    )
                    selectedPage = page
                }
                dismiss()
            } label: {
                HStack {
                    Label(page.title, systemImage: page.systemImage)
                    Spacer()
                    if page == selectedPage {
                        Image(systemName: "checkmark")
                            .foregroundStyle(Color.wristRemoteAccent)
                    }
                }
            }
            .accessibilityLabel("\(page.title)页")
        }
        .navigationTitle("选择页面")
    }
}

private struct DirectionRemotePage: View {
    @ObservedObject var controller: WatchSessionController

    var body: some View {
        GeometryReader { proxy in
            let spacing: CGFloat = 8
            let widthBound = (proxy.size.width - spacing * 2) / 3
            let heightBound = (proxy.size.height - spacing * 2) / 3
            let buttonSize = min(58, max(44, min(widthBound, heightBound)))
            VStack(spacing: spacing) {
                DirectionButton(command: .up, controller: controller)
                    .frame(width: buttonSize, height: buttonSize)

                HStack(spacing: spacing) {
                    DirectionButton(command: .left, controller: controller)
                        .frame(width: buttonSize, height: buttonSize)
                    DirectionButton(command: .ok, controller: controller, isConfirm: true)
                        .frame(width: buttonSize, height: buttonSize)
                    DirectionButton(command: .right, controller: controller)
                        .frame(width: buttonSize, height: buttonSize)
                }
                .frame(height: buttonSize)

                DirectionButton(command: .down, controller: controller)
                    .frame(width: buttonSize, height: buttonSize)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("方向盘")
    }
}

private struct DirectionButton: View {
    let command: WatchRemoteCommand
    @ObservedObject var controller: WatchSessionController
    var isConfirm = false

    var body: some View {
        RemotePressButton(
            isEnabled: controller.isReady,
            accessibilityLabel: command.accessibilityTitle,
            accessibilityHint: controller.title(for: command)
        ) { isPressed in
            controller.setButton(command, isPressed: isPressed)
        } activate: {
            controller.activateButton(command)
        } label: {
            VStack(spacing: 1) {
                Image(systemName: command.systemImage)
                    .font(.system(size: isConfirm ? 17 : 19, weight: .semibold))
                if let title = controller.title(for: command) {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                isConfirm
                    ? Color.wristRemoteAccent.opacity(0.24)
                    : Color.secondary.opacity(0.18)
            )
            .clipShape(Circle())
        }
    }
}

private struct FunctionRemotePage: View {
    @ObservedObject var controller: WatchSessionController

    var body: some View {
        GeometryReader { proxy in
            let spacing: CGFloat = 8
            let rowHeight = min(
                58,
                max(44, (proxy.size.height - spacing * 2) / 3)
            )
            VStack(spacing: spacing) {
                HStack(spacing: spacing) {
                    FunctionButton(command: .power, controller: controller)
                    FunctionButton(command: .back, controller: controller)
                    FunctionButton(command: .home, controller: controller)
                }
                .frame(height: rowHeight)

                HStack(spacing: spacing) {
                    FunctionButton(command: .menu, controller: controller)
                    FunctionButton(command: .tv, controller: controller)
                    VoiceRemoteButton(controller: controller)
                }
                .frame(height: rowHeight)

                HStack(spacing: spacing) {
                    FunctionButton(command: .volumeDown, controller: controller)
                    FunctionButton(command: .volumeUp, controller: controller)
                }
                .frame(height: rowHeight)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("功能键")
    }
}

private struct FunctionButton: View {
    let command: WatchRemoteCommand
    @ObservedObject var controller: WatchSessionController

    var body: some View {
        RemotePressButton(
            isEnabled: controller.isReady,
            accessibilityLabel: command.accessibilityTitle,
            accessibilityHint: controller.title(for: command)
        ) { isPressed in
            controller.setButton(command, isPressed: isPressed)
        } activate: {
            controller.activateButton(command)
        } label: {
            RemoteButtonLabel(
                command: command,
                customTitle: controller.title(for: command)
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct VoiceRemoteButton: View {
    @ObservedObject var controller: WatchSessionController
    @State private var accessibilityVoiceHeld = false

    var body: some View {
        RemotePressButton(
            // Keep the press surface enabled while a voice gesture is pending or
            // active. Disabling it mid-press can make SwiftUI drop the real release.
            isEnabled: controller.isVoiceControlEnabled,
            accessibilityLabel: "语音",
            accessibilityHint: "直接触控时按住说话；VoiceOver 可分别开始和结束"
        ) { isPressed in
            controller.setVoicePressed(isPressed)
        } activate: {
            accessibilityVoiceHeld ? endAccessibilityVoice() : beginAccessibilityVoice()
        } label: {
            VStack(spacing: 2) {
                Image(systemName: controller.isVoiceActive ? "waveform" : "mic.fill")
                    .font(.system(size: 17, weight: .semibold))
                Text(controller.isVoiceActive ? "正在说话" : "语音")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                controller.isVoiceActive
                    ? Color.wristRemoteAccent.opacity(0.35)
                    : Color.secondary.opacity(0.18)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .accessibilityAction(named: Text("开始语音")) {
            beginAccessibilityVoice()
        }
        .accessibilityAction(named: Text("结束语音")) {
            endAccessibilityVoice()
        }
        .onDisappear {
            endAccessibilityVoice()
        }
    }

    private func beginAccessibilityVoice() {
        guard !accessibilityVoiceHeld, controller.isVoiceControlEnabled else { return }
        accessibilityVoiceHeld = true
        controller.setVoicePressed(true)
    }

    private func endAccessibilityVoice() {
        guard accessibilityVoiceHeld else { return }
        accessibilityVoiceHeld = false
        controller.setVoicePressed(false)
    }
}

private struct FavoritesRemotePage: View {
    @ObservedObject var controller: WatchSessionController

    var body: some View {
        VStack(spacing: 8) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(controller.favorites) { command in
                    FunctionButton(command: command, controller: controller)
                        .frame(height: 52)
                }
            }

            NavigationLink {
                FavoriteEditorView(controller: controller)
            } label: {
                Label("收藏与手感", systemImage: "slider.horizontal.3")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .accessibilityHint("调整四个收藏按钮与按键震动")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("收藏键")
    }
}

private struct FavoriteEditorView: View {
    @ObservedObject var controller: WatchSessionController
    @AppStorage(WatchHaptics.isEnabledDefaultsKey) private var hapticsEnabled = true

    var body: some View {
        List {
            Section("收藏位置") {
                ForEach(Array(controller.favorites.enumerated()), id: \.offset) { index, command in
                    NavigationLink {
                        FavoriteCommandSelectionView(controller: controller, index: index)
                    } label: {
                        HStack {
                            Text("位置 \(index + 1)")
                                .font(.system(size: 12))
                            Spacer()
                            Label(command.accessibilityTitle, systemImage: command.systemImage)
                                .font(.system(size: 12, weight: .semibold))
                        }
                    }
                }
            }

            Section("手感") {
                Toggle("按键震动", isOn: $hapticsEnabled)
                    .font(.system(size: 12, weight: .semibold))
                    .onChange(of: hapticsEnabled) { oldValue, newValue in
                        guard !oldValue, newValue else { return }
                        WatchHaptics.play(.click)
                    }
            }
        }
        .navigationTitle("收藏与手感")
    }
}

private struct FavoriteCommandSelectionView: View {
    @ObservedObject var controller: WatchSessionController
    let index: Int
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List(WatchRemoteCommand.allCases) { command in
            Button {
                controller.updateFavorite(at: index, to: command)
                WatchHaptics.play(.click)
                dismiss()
            } label: {
                HStack {
                    Label(command.accessibilityTitle, systemImage: command.systemImage)
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    if controller.favorites[index] == command {
                        Image(systemName: "checkmark")
                            .foregroundStyle(Color.wristRemoteAccent)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("将位置 \(index + 1) 设为\(command.accessibilityTitle)")
        }
        .navigationTitle("选择按键")
    }
}

private struct RemoteButtonLabel: View {
    let command: WatchRemoteCommand
    let customTitle: String?

    var body: some View {
        VStack(spacing: 1) {
            Image(systemName: command.systemImage)
                .font(.system(size: 17, weight: .semibold))
            Text(customTitle ?? command.shortTitle)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.secondary.opacity(0.18))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct RemotePressButton<Label: View>: View {
    let isEnabled: Bool
    let accessibilityLabel: String
    let accessibilityHint: String?
    let onPressChanged: (Bool) -> Void
    let activate: () -> Void
    @ViewBuilder let label: Label

    init(
        isEnabled: Bool,
        accessibilityLabel: String,
        accessibilityHint: String? = nil,
        onPressChanged: @escaping (Bool) -> Void,
        activate: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) {
        self.isEnabled = isEnabled
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityHint = accessibilityHint
        self.onPressChanged = onPressChanged
        self.activate = activate
        self.label = label()
    }

    var body: some View {
        Button(action: {}) {
            label
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .buttonStyle(RemotePressTrackingStyle(onPressChanged: onPressChanged))
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint ?? "使用 Apple Watch 独立按键映射")
        .accessibilityAction {
            activate()
        }
    }
}

private struct RemotePressTrackingStyle: ButtonStyle {
    let onPressChanged: (Bool) -> Void

    func makeBody(configuration: Configuration) -> some View {
        RemotePressTrackingBody(
            label: configuration.label,
            isPressed: configuration.isPressed,
            onPressChanged: onPressChanged
        )
    }
}

private struct RemotePressTrackingBody<Label: View>: View {
    let label: Label
    let isPressed: Bool
    let onPressChanged: (Bool) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var reportedPressed = false

    var body: some View {
        label
            .scaleEffect(!reduceMotion && isPressed ? 0.96 : 1)
            .opacity(isPressed ? 0.76 : 1)
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.08),
                value: isPressed
            )
            .onChange(of: isPressed) { _, newValue in
                guard reportedPressed != newValue else { return }
                reportedPressed = newValue
                onPressChanged(newValue)
            }
            .onDisappear {
                guard reportedPressed else { return }
                reportedPressed = false
                onPressChanged(false)
            }
    }
}

private extension WatchRemoteCommand {
    var shortTitle: String {
        switch self {
        case .power: return "电源"
        case .up: return "上"
        case .down: return "下"
        case .left: return "左"
        case .right: return "右"
        case .ok: return "确定"
        case .back: return "返回"
        case .home: return "主页"
        case .menu: return "菜单"
        case .tv: return "TV"
        case .volumeUp: return "音量+"
        case .volumeDown: return "音量−"
        }
    }

    var accessibilityTitle: String {
        switch self {
        case .power: return "电源键"
        case .up: return "上键"
        case .down: return "下键"
        case .left: return "左键"
        case .right: return "右键"
        case .ok: return "确定键"
        case .back: return "返回键"
        case .home: return "主页键"
        case .menu: return "菜单键"
        case .tv: return "TV 键"
        case .volumeUp: return "音量加键"
        case .volumeDown: return "音量减键"
        }
    }

    var systemImage: String {
        switch self {
        case .power: return "power"
        case .up: return "chevron.up"
        case .down: return "chevron.down"
        case .left: return "chevron.left"
        case .right: return "chevron.right"
        case .ok: return "circle.inset.filled"
        case .back: return "arrow.uturn.backward"
        case .home: return "house.fill"
        case .menu: return "line.3.horizontal"
        case .tv: return "tv"
        case .volumeUp: return "speaker.plus.fill"
        case .volumeDown: return "speaker.minus.fill"
        }
    }
}

#Preview("已连接") {
    WatchRemoteRootView(controller: WatchSessionController(
        initialStatus: WatchRemoteStatus(
            isMacConnected: true,
            macName: "Developer Mac",
            voiceOwner: .none,
            detail: nil,
            buttonTitles: [.home: "显示桌面", .tv: "切换窗口"],
            isActionProfileReady: true,
            profileRevision: 1
        ),
        initialFavorites: WatchRemoteCommand.defaultFavorites
    ))
}

#Preview("未连接") {
    WatchRemoteRootView(controller: WatchSessionController())
}
