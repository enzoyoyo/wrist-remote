import SwiftUI
import WatchKit

extension Color {
    static let wristRemoteAccent = Color.cyan
}

struct WatchRemoteRootView: View {
    @ObservedObject var controller: WatchSessionController

    var body: some View {
        NavigationStack {
            WatchCodexConversationHomeView(controller: controller)
                .navigationTitle("Codex")
                .navigationBarTitleDisplayMode(.inline)
        }
        .background(Color.black.ignoresSafeArea())
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

struct RemoteDeckView: View {
    @ObservedObject var controller: WatchSessionController
    @State private var selectedPage = RemoteDeckPage.direction

    var body: some View {
        selectedRemotePage
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            ToolbarItem(placement: .bottomBar) {
                NavigationLink {
                    WatchDirectConnectionView(controller: controller)
                } label: {
                    Label(controller.remoteConnectionPathText, systemImage: "link")
                }
                .accessibilityIdentifier("remote-connection-settings")
                .accessibilityLabel("连接状态：\(controller.remoteConnectionPathText)")
                .accessibilityValue(controller.directButtonOutcome ?? controller.statusDetail)
                .accessibilityHint("查看连接与执行结果，或重新连接；不会触发遥控动作")
            }
        }
    }

    @ViewBuilder
    private var selectedRemotePage: some View {
        // Page selection remains explicit so a swipe that begins on a remote
        // button can never also become a remote press.
        switch selectedPage {
        case .direction:
            DirectionRemotePage(controller: controller)
        case .controls:
            FunctionRemotePage(controller: controller)
        case .favorites:
            FavoritesRemotePage(controller: controller)
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
                        .font(.caption.weight(.medium))
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
                    .font(.caption.weight(.semibold))
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
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .accessibilityHint("调整四个收藏按钮与遥控、语音和会话的触觉反馈")
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
                                .font(.caption)
                            Spacer()
                            Label(command.accessibilityTitle, systemImage: command.systemImage)
                                .font(.caption.weight(.semibold))
                        }
                    }
                }
            }

            Section("手感") {
                Toggle("触觉反馈", isOn: $hapticsEnabled)
                    .font(.caption.weight(.semibold))
                    .onChange(of: hapticsEnabled) { oldValue, newValue in
                        guard !oldValue, newValue else { return }
                        WatchHaptics.play(.click)
                    }

                Text("用于遥控按键、语音与会话操作")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
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
                        .font(.caption.weight(.medium))
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
                .font(.caption.weight(.semibold))
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
