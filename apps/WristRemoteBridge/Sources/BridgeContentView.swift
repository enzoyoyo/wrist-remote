import ServiceManagement
import Speech
import SwiftUI

struct BridgeContentView: View {
    @ObservedObject var model: BridgeAppModel
    @State private var pairingSheet: BridgePairingDevice?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            Form {
                Section("iPhone 与 Apple Watch") {
                    connectionRow(
                        title: "iPhone",
                        symbol: "iphone",
                        detail: "扫码连接 Mac，手机也能直接遥控。",
                        clients: model.connectedClients.filter { $0.transport == "TCP" },
                        device: .iphone
                    )
                    connectionRow(
                        title: "Apple Watch",
                        symbol: "applewatch",
                        detail: "先用 iPhone 完成设置，之后在同一局域网内直连 Mac。",
                        clients: model.connectedClients.filter { $0.transport == "HTTP" },
                        device: .watch
                    )
                    Text("12 个按键，支持单击、双击、长按。映射在 iPhone 中设置；Watch 直连提供按键遥控，语音仍需 iPhone 中转。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Section("服务状态") {
                    LabeledContent("状态") {
                        HStack(spacing: 7) {
                            Circle()
                                .fill(statusColor)
                                .frame(width: 8, height: 8)
                            if case .loadingIdentity = model.serverStatus {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text(model.statusTitle)
                            if model.canRetryServerIdentity {
                                Button("重试读取") {
                                    model.retryServerIdentity()
                                }
                            }
                        }
                    }
                    Text(model.statusDetail)
                        .foregroundStyle(.secondary)
                        .font(.callout)
                    LabeledContent("Watch 直连服务") {
                        Text(model.directBridgeConfiguration == nil ? "暂不可用" : "可配对")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Codex") {
                    LabeledContent("任务同步") {
                        Text(model.codexHookStatusTitle)
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("锁定的聊天") {
                        HStack(spacing: 10) {
                            Text(codexThreadLabel)
                                .foregroundStyle(.secondary)
                            Button("切换到下一条聊天") {
                                model.followNextCodexThread()
                            }
                            .disabled(model.isWaitingForNextCodexThread)
                        }
                    }
                    LabeledContent("当前聊天投递") {
                        Text(model.codexDeliveryStatus)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("私有网络") {
                    LabeledContent("Tailscale 连接") {
                        HStack(spacing: 7) {
                            Circle()
                                .fill(tailnetStatusColor)
                                .frame(width: 8, height: 8)
                            Text(model.tailnetStatusTitle)
                        }
                    }
                    Text(model.tailnetStatusDetail)
                        .foregroundStyle(.secondary)
                        .font(.callout)
                    Toggle(
                        "允许 Tailscale 私有网络连接",
                        isOn: Binding(
                            get: { model.tailnetAccessEnabled },
                            set: model.setTailnetAccessEnabled
                        )
                    )
                    Text("用于 iPhone 私有网络连接。Watch 直连当前仅使用局域网；不会开启 Funnel、端口映射或公网监听。")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                    LabeledContent("公网控制", value: model.internetRelayStatusTitle)
                }

                Section("系统权限") {
                    permissionRow(
                        title: "辅助功能",
                        value: model.isAccessibilityTrusted ? "已允许" : "需要允许",
                        buttonTitle: "打开系统设置",
                        action: model.requestAccessibility
                    )
                    permissionRow(
                        title: "前台文字听写",
                        value: model.speechAuthorizationTitle,
                        buttonTitle: "请求权限",
                        action: model.requestSpeechAuthorization
                    )
                    Text("这个权限只供“把文字输入当前文本框”的传统遥控功能使用。Codex 语音使用已登录账号的 Codex 转写服务，再把文字发到所选任务；不使用 Mac 听写权限。")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                    LabeledContent("前台听写语言") {
                        Text(model.speechLocaleIdentifier)
                            .foregroundStyle(.secondary)
                    }
                    Toggle(
                        "登录时启动",
                        isOn: Binding(
                            get: { model.launchAtLoginEnabled },
                            set: model.setLaunchAtLogin
                        )
                    )
                }

                Section("Apple Watch 自定义 App") {
                    if model.applicationProfiles.isEmpty {
                        Text("尚未添加。只在这里添加的 App 才会出现在 Wrist Remote 映射中。")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.applicationProfiles) { profile in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(profile.title)
                                    Text(profile.bundleIdentifier)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("移除", role: .destructive) {
                                    model.removeApplication(id: profile.id)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                    Button("添加 App…", action: model.addApplication)
                }

                if !model.lastTranscription.isEmpty {
                    Section("最近一次语音") {
                        Text(model.lastTranscription)
                            .textSelection(.enabled)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(minWidth: 620, minHeight: 560)
        .sheet(item: $pairingSheet) { device in
            BridgePairingSheet(model: model, device: device)
        }
        .alert(
            "连接 Wrist Remote",
            isPresented: Binding(
                get: { model.pairingRequest != nil && pairingSheet == nil },
                set: { if !$0 { model.resolvePairing(false) } }
            ),
            presenting: model.pairingRequest
        ) { _ in
            Button("拒绝", role: .cancel) { model.resolvePairing(false) }
            Button("允许") { model.resolvePairing(true) }
        } message: { request in
            Text("\(request.deviceName) 的确认码是 \(request.pairingCode)。请与设备上显示的六位数字核对；只有一致时才允许。")
        }
        .alert(
            "操作未完成",
            isPresented: Binding(
                get: { model.operationError != nil },
                set: { if !$0 { model.operationError = nil } }
            )
        ) {
            Button("知道了") { model.operationError = nil }
        } message: {
            Text(model.operationError ?? "")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("腕上遥控桥")
                .font(.title2.weight(.semibold))
            Text("用 iPhone 或 Apple Watch 遥控这台 Mac。与其他遥控器、输入工具的配置相互独立。")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
    }

    private func connectionRow(
        title: String,
        symbol: String,
        detail: String,
        clients: [WristRemoteClientSnapshot],
        device: BridgePairingDevice
    ) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .frame(width: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
                Text(clients.isEmpty ? "未连接" : "已连接 · " + clients.map(\.name).joined(separator: "、"))
                    .font(.caption)
                    .foregroundStyle(clients.isEmpty ? Color.secondary : Color.primary)
                    .accessibilityIdentifier(device == .iphone ? "iphoneConnectionStatus" : "watchConnectionStatus")
            }
            Spacer(minLength: 12)
            Button(device == .iphone ? "连接 iPhone…" : "连接 Apple Watch…") {
                pairingSheet = device
            }
            .accessibilityIdentifier(device == .iphone ? "pairIPhone" : "pairAppleWatch")
        }
        .padding(.vertical, 6)
    }

    private var statusColor: Color {
        switch model.serverStatus {
        case .connected: return .green
        case .ready: return .blue
        case .identityUnavailable, .failed: return .red
        case .loadingIdentity: return .blue
        case .stopped, .starting: return .secondary
        }
    }

    private var tailnetStatusColor: Color {
        switch model.tailnetStatus {
        case .ready: return .green
        case .starting, .waiting: return .blue
        case .failed: return .orange
        case .disabled: return .secondary
        }
    }

    private var codexThreadLabel: String {
        if model.isWaitingForNextCodexThread { return "等待下一条任务" }
        guard let threadID = model.codexPinnedThreadID else { return "等待当前任务" }
        return String(threadID.prefix(8)) + "…"
    }

    @ViewBuilder
    private func permissionRow(
        title: String,
        value: String,
        buttonTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        LabeledContent(title) {
            HStack(spacing: 12) {
                Text(value).foregroundStyle(.secondary)
                Button(buttonTitle, action: action)
            }
        }
    }
}
