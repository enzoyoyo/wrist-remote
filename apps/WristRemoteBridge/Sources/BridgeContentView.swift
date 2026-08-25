import ServiceManagement
import Speech
import SwiftUI

struct BridgeContentView: View {
    @ObservedObject var model: BridgeAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            Form {
                Section("连接") {
                    LabeledContent("状态") {
                        HStack(spacing: 7) {
                            Circle()
                                .fill(statusColor)
                                .frame(width: 8, height: 8)
                            Text(model.statusTitle)
                        }
                    }
                    Text(model.statusDetail)
                        .foregroundStyle(.secondary)
                        .font(.callout)
                    LabeledContent("公网控制") {
                        HStack(spacing: 7) {
                            Circle()
                                .fill(model.isInternetRelayConnected ? Color.green : Color.secondary)
                                .frame(width: 8, height: 8)
                            Text(model.internetRelayStatusTitle)
                        }
                    }
                    Text(model.internetRelayStatusDetail)
                        .foregroundStyle(.secondary)
                        .font(.callout)
                    LabeledContent("Codex 任务同步") {
                        Text(model.codexHookStatusTitle)
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("锁定的 Codex 聊天") {
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

                Section("系统权限") {
                    permissionRow(
                        title: "辅助功能",
                        value: model.isAccessibilityTrusted ? "已允许" : "需要允许",
                        buttonTitle: "打开系统设置",
                        action: model.requestAccessibility
                    )
                    permissionRow(
                        title: "语音识别",
                        value: model.speechAuthorizationTitle,
                        buttonTitle: "请求权限",
                        action: model.requestSpeechAuthorization
                    )
                    LabeledContent("实际识别语言") {
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
        .alert(
            "连接 Wrist Remote",
            isPresented: Binding(
                get: { model.pairingRequest != nil },
                set: { if !$0 { model.resolvePairing(false) } }
            ),
            presenting: model.pairingRequest
        ) { _ in
            Button("拒绝", role: .cancel) { model.resolvePairing(false) }
            Button("允许") { model.resolvePairing(true) }
        } message: { request in
            Text("\(request.deviceName) 的确认码是 \(request.pairingCode)。请与 iPhone 上显示的六位数字核对。")
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
            Text("独立服务 Apple Watch；不读取、不覆盖其他遥控器或输入工具配置。")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
    }

    private var statusColor: Color {
        switch model.serverStatus {
        case .connected: return .green
        case .ready: return .blue
        case .failed: return .red
        case .stopped, .starting: return .secondary
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
