import SwiftUI
import UIKit

struct WristPhoneRemoteView: View {
    @ObservedObject var connection: WristBridgeConnection
    @ObservedObject var profileStore: WatchActionProfileStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var lastRequestToken: UUID?
    @State private var resultTitle = "尚未发送操作"
    @State private var resultDetail = "单击、双击或长按按键，执行相应映射。"
    @State private var waitingForReceipt = false

    private let commands: [WatchRemoteCommand] = [
        .power, .up, .menu,
        .left, .ok, .right,
        .back, .down, .home,
        .volumeDown, .tv, .volumeUp,
    ]

    private var isReady: Bool {
        scenePhase == .active && connection.isPhoneRemoteReady(revision: profileStore.revision)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 5) {
                    Label(connection.isConnected ? connection.macName : "Mac 未连接",
                          systemImage: "laptopcomputer")
                        .font(.headline)
                    Text(connectionStatus)
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10),
                                         count: dynamicTypeSize.isAccessibilitySize ? 2 : 3),
                          spacing: 10) {
                    ForEach(commands) { command in
                        WristPhoneRemoteKey(
                            title: command.displayTitle,
                            subtitle: profileStore.title(
                                for: command, applicationTitles: connection.watchApplicationTitles
                            ),
                            symbol: command.systemImage,
                            isEnabled: isReady && hasBinding(command),
                            supportsDoubleClick: bindingEnabled(command, .doubleClick),
                            supportsLongPress: bindingEnabled(command, .longPress),
                            identifier: "phone-remote-\(command.rawValue)",
                            onTrigger: { trigger in commit(command, trigger: trigger) }
                        )
                        .frame(minHeight: dynamicTypeSize.isAccessibilitySize ? 148 : 102)
                        .disabled(!isReady || !hasBinding(command))
                        .id("\(command.rawValue)-\(profileStore.revision)-\(isReady)")
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        if waitingForReceipt { ProgressView().controlSize(.small) }
                        Text(resultTitle).font(.headline)
                    }
                    Text(resultDetail).font(.subheadline).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("phone-remote-receipt")

                Divider()
                Text("与 Apple Watch 共用 12 键、36 个动作槽。未设置的双击或长按不会触发额外动作；需要辅助功能权限的操作，请在 Mac 的腕上遥控桥中授权。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .padding()
        }
        .navigationTitle("手机遥控")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            // The network request is not cancelled or retransmitted: its receipt
            // must still settle even if this screen is no longer being shown.
            lastRequestToken = nil
        }
    }

    private var connectionStatus: String {
        if !connection.isConnected { return "返回首页连接 Mac 后即可遥控。离线操作不会补发。" }
        if !connection.supportsPhoneButtonTriggers { return "请更新 Mac 端腕上遥控桥以启用手机遥控。" }
        if !connection.isWatchActionProfileReady(revision: profileStore.revision) {
            return connection.watchActionProfileError ?? "正在等待 Mac 确认按键配置…"
        }
        return "\(connection.directRouteStatusText) · 配置版本 \(profileStore.revision)"
    }

    private func bindingEnabled(_ command: WatchRemoteCommand, _ trigger: WatchActionTrigger) -> Bool {
        profileStore.binding(for: command, trigger: trigger).action != .disabled
    }

    private func hasBinding(_ command: WatchRemoteCommand) -> Bool {
        WatchActionTrigger.allCases.contains { bindingEnabled(command, $0) }
    }

    private func commit(_ command: WatchRemoteCommand, trigger: WatchActionTrigger) {
        guard isReady else { return }
        guard bindingEnabled(command, trigger) else {
            lastRequestToken = nil
            waitingForReceipt = false
            resultTitle = "\(command.displayTitle) · \(trigger.displayTitle)未设置"
            resultDetail = "可在首页的“按键与手感”中设置这个动作。"
            return
        }
        let token = UUID()
        let revision = profileStore.revision
        lastRequestToken = token
        resultTitle = "\(command.displayTitle) · \(trigger.displayTitle)等待回执"
        resultDetail = "已发送请求，正在等待 Mac 确认。"
        waitingForReceipt = true
        Task { @MainActor in
            let receipt = await connection.sendPhoneButtonTrigger(
                command.remoteCommand, trigger: trigger, profileRevision: revision
            )
            guard lastRequestToken == token else { return }
            waitingForReceipt = false
            switch receipt.outcome {
            case .executed: resultTitle = "\(command.displayTitle) · \(trigger.displayTitle)已执行"
            case .rejected: resultTitle = "\(command.displayTitle) · \(trigger.displayTitle)未执行"
            case .unconfirmed: resultTitle = "\(command.displayTitle) · 执行结果未知"
            }
            resultDetail = receipt.detail
        }
    }
}

/// Native recognizers resolve the gesture before networking. Requiring failures
/// prevents a long press or double tap from also sending a single-click action.
private struct WristPhoneRemoteKey: UIViewRepresentable {
    let title: String
    let subtitle: String
    let symbol: String
    let isEnabled: Bool
    let supportsDoubleClick: Bool
    let supportsLongPress: Bool
    let identifier: String
    let onTrigger: (WatchActionTrigger) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> AccessibleButton {
        let button = AccessibleButton(type: .system)
        button.configuration = .tinted()
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        context.coordinator.install(on: button)
        return button
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: AccessibleButton,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width, width.isFinite else { return nil }
        // A long shortcut name must never expand its grid column. UIKit may
        // measure a wider intrinsic size, but SwiftUI owns this button's width.
        let fitted = uiView.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        return CGSize(width: width, height: max(proposal.height ?? 0, fitted.height))
    }

    func updateUIView(_ button: AccessibleButton, context: Context) {
        var configuration = isEnabled ? UIButton.Configuration.tinted() : .gray()
        if !isEnabled {
            configuration.baseForegroundColor = .secondaryLabel
            configuration.background.backgroundColor = .secondarySystemFill
        }
        configuration.title = title
        configuration.subtitle = subtitle
        configuration.image = UIImage(systemName: symbol)
        configuration.imagePlacement = .top
        configuration.imagePadding = 8
        configuration.titlePadding = 5
        configuration.titleAlignment = .center
        configuration.titleLineBreakMode = .byWordWrapping
        configuration.subtitleLineBreakMode = .byTruncatingTail
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 6,
                                                               bottom: 12, trailing: 6)
        button.configuration = configuration
        button.isEnabled = isEnabled
        button.isUserInteractionEnabled = isEnabled
        button.accessibilityLabel = "\(title)，单击：\(subtitle)"
        button.accessibilityHint = "支持已设置的单击、双击和长按动作"
        button.accessibilityIdentifier = identifier
        context.coordinator.onTrigger = onTrigger
        button.onAccessibilityActivate = { onTrigger(.singleClick) }
        context.coordinator.doubleTap.isEnabled = isEnabled && supportsDoubleClick
        context.coordinator.longPress.isEnabled = isEnabled && supportsLongPress
        context.coordinator.singleTap.isEnabled = isEnabled
        var actions: [UIAccessibilityCustomAction] = []
        if supportsDoubleClick {
            actions.append(UIAccessibilityCustomAction(name: "双击动作") { _ in
                guard isEnabled else { return false }
                onTrigger(.doubleClick)
                return true
            })
        }
        if supportsLongPress {
            actions.append(UIAccessibilityCustomAction(name: "长按动作") { _ in
                guard isEnabled else { return false }
                onTrigger(.longPress)
                return true
            })
        }
        button.accessibilityCustomActions = actions
    }

    final class AccessibleButton: UIButton {
        var onAccessibilityActivate: (() -> Void)?

        override func accessibilityActivate() -> Bool {
            guard isEnabled, let onAccessibilityActivate else { return false }
            onAccessibilityActivate()
            return true
        }
    }

    final class Coordinator: NSObject {
        var onTrigger: ((WatchActionTrigger) -> Void)?
        let singleTap = UITapGestureRecognizer()
        let doubleTap = UITapGestureRecognizer()
        let longPress = UILongPressGestureRecognizer()

        func install(on button: UIButton) {
            singleTap.addTarget(self, action: #selector(singleRecognized))
            doubleTap.addTarget(self, action: #selector(doubleRecognized))
            doubleTap.numberOfTapsRequired = 2
            longPress.addTarget(self, action: #selector(longRecognized))
            longPress.minimumPressDuration = 0.6
            singleTap.cancelsTouchesInView = true
            doubleTap.cancelsTouchesInView = true
            longPress.cancelsTouchesInView = true
            singleTap.delaysTouchesEnded = true
            doubleTap.delaysTouchesEnded = true
            singleTap.require(toFail: doubleTap)
            singleTap.require(toFail: longPress)
            doubleTap.require(toFail: longPress)
            button.addGestureRecognizer(singleTap)
            button.addGestureRecognizer(doubleTap)
            button.addGestureRecognizer(longPress)
        }

        @objc private func singleRecognized() { onTrigger?(.singleClick) }
        @objc private func doubleRecognized() { onTrigger?(.doubleClick) }
        @objc private func longRecognized() {
            guard longPress.state == .began else { return }
            onTrigger?(.longPress)
        }
    }
}
