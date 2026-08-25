import SwiftUI

struct WristRemoteHomeView: View {
    @ObservedObject var connection: WristBridgeConnection
    @ObservedObject var relay: WatchRelayController
    @ObservedObject var settings: WatchLayoutSettings
    @ObservedObject var profileStore: WatchActionProfileStore

    var body: some View {
        Form {
            Section("连接") {
                statusRow(
                    title: "Mac",
                    detail: macStatusDetail,
                    systemImage: "laptopcomputer",
                    isReady: connection.isConnected
                )

                statusRow(
                    title: "Apple Watch",
                    detail: watchStatusDetail,
                    systemImage: "applewatch",
                    isReady: relay.isWatchReachable
                )

                statusRow(
                    title: "独立映射",
                    detail: mappingStatusDetail,
                    systemImage: "switch.2",
                    isReady: relay.isActionProfileReady || relay.isInternetProfileReady
                )

                statusRow(
                    title: "互联网",
                    detail: relay.internetRelayStatusDetail,
                    systemImage: "network",
                    isReady: relay.isInternetProfileReady
                )

                if let pairingCode = connection.displayedPairingCode {
                    LabeledContent("Mac 确认码") {
                        Text(pairingCode.map(String.init).joined(separator: " "))
                            .font(.system(.body, design: .monospaced, weight: .semibold))
                    }
                }

                if let errorText = relay.lastErrorText {
                    Text(errorText)
                        .foregroundStyle(.secondary)
                }

                Button("重新连接 Mac") {
                    relay.refreshStatus()
                    connection.restartDiscovery(reason: "wrist_remote_manual")
                }
            }

            Section("语音") {
                LabeledContent("当前来源", value: voiceOwnerText)
                Text("语音只使用 Apple Watch 麦克风，并由独立 Mac 桥转写。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                NavigationLink {
                    WatchCustomizationView(
                        settings: settings,
                        profileStore: profileStore,
                        connection: connection,
                        relay: relay
                    )
                } label: {
                    Label("自定义 Apple Watch", systemImage: "slider.horizontal.3")
                }

                ForEach(Array(settings.favorites.enumerated()), id: \.offset) { index, command in
                    LabeledContent("快捷键 \(index + 1)") {
                        Label(command.displayTitle, systemImage: command.systemImage)
                    }
                }
            } header: {
                Text("收藏键")
            } footer: {
                Text("只有实时可达时才转发控制和语音；离线操作不会在稍后补发。")
            }

            Section("与现有遥控器共存") {
                Text("腕上遥控使用单独的 12 键配置，只发送标记为 Apple Watch 的控制事件；不读取、不修改，也不占用其他输入设备的按键映射。")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("腕上遥控")
    }

    @ViewBuilder
    private func statusRow(
        title: String,
        detail: String,
        systemImage: String,
        isReady: Bool
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: isReady ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isReady ? Color.accentColor : Color.secondary)
                .accessibilityLabel(isReady ? "已连接" : "未连接")
        }
        .frame(minHeight: 44)
    }

    private var macStatusDetail: String {
        connection.isConnected ? connection.macName : connection.statusText
    }

    private var watchStatusDetail: String {
        if !relay.isWatchPaired { return "未配对" }
        if !relay.isWatchAppInstalled { return "Apple Watch App 未安装" }
        return relay.isWatchReachable ? "实时可用" : "打开手表 App 后可用"
    }

    private var mappingStatusDetail: String {
        if relay.isActionProfileReady {
            return "局域网版本 \(profileStore.revision) 已确认"
        }
        if relay.isInternetProfileReady {
            return "互联网版本 \(profileStore.revision) 已确认"
        }
        if !connection.isConnected { return "等待 Mac 连接或互联网确认" }
        if !connection.supportsWatchActionProfiles { return "Mac 端需要更新" }
        return connection.watchActionProfileError ?? "正在同步版本 \(profileStore.revision)"
    }

    private var voiceOwnerText: String {
        switch connection.voiceOwner {
        case .watch: return "Apple Watch"
        case nil: return "空闲"
        }
    }
}
