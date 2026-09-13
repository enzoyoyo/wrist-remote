import SwiftUI

struct WristRemoteHomeView: View {
    @ObservedObject var connection: WristBridgeConnection
    @ObservedObject var relay: WatchRelayController
    @ObservedObject var settings: WatchLayoutSettings
    @ObservedObject var profileStore: WatchActionProfileStore

    var body: some View {
        Form {
            Section {
                statusRow("Mac", detail: connection.isConnected ? connection.macName : connection.statusText,
                          image: "laptopcomputer", ready: connection.isConnected)
                statusRow("Apple Watch", detail: watchStatusDetail,
                          image: "applewatch", ready: relay.isWatchReachable)
                if let code = connection.displayedPairingCode {
                    LabeledContent("Mac 确认码") {
                        Text(code.map(String.init).joined(separator: " "))
                            .font(.system(.title3, design: .monospaced, weight: .semibold))
                    }
                }
                if connection.requiresServerTrustConfirmation { trustConfirmation }
                if let error = connection.pairingLinkError {
                    Text(error).font(.footnote).foregroundStyle(.secondary)
                        .accessibilityIdentifier("pairing-link-error")
                }
                if !connection.isConnected, !connection.guidanceText.isEmpty {
                    Text(connection.guidanceText)
                        .font(.footnote).foregroundStyle(.secondary)
                        .accessibilityIdentifier("connection-guidance")
                }
                if let error = relay.lastErrorText {
                    Text(error).font(.footnote).foregroundStyle(.secondary)
                }
                Button("重新连接", systemImage: "arrow.clockwise") {
                    relay.refreshStatus()
                    connection.restartDiscovery(reason: "wrist_remote_manual")
                }
                NavigationLink {
                    WristPairingHelpView(connection: connection)
                } label: {
                    Label("扫码或从链接连接", systemImage: "qrcode.viewfinder")
                        .frame(minHeight: 44)
                }
            } header: {
                Text("连接")
            } footer: {
                Text("打开 App 会自动尝试连接。仅实时转发，离线操作不会稍后补发。")
            }

            Section {
                NavigationLink {
                    WristPhoneRemoteView(connection: connection, profileStore: profileStore)
                } label: {
                    Label("打开手机遥控", systemImage: "iphone")
                        .frame(minHeight: 44)
                }
                .accessibilityIdentifier("open-phone-remote")
            } header: {
                Text("iPhone")
            } footer: {
                Text("12 键支持单击、双击与长按，与 Apple Watch 共用按键配置。")
            }

            Section {
                NavigationLink {
                    WatchCustomizationView(settings: settings, profileStore: profileStore,
                                           connection: connection, relay: relay)
                } label: {
                    Label("按键与手感", systemImage: "slider.horizontal.3")
                        .frame(minHeight: 44)
                }
                ForEach(Array(settings.favorites.enumerated()), id: \.offset) { index, command in
                    LabeledContent("收藏 \(index + 1)") {
                        Label(command.displayTitle, systemImage: command.systemImage)
                    }
                }
            } header: {
                Text("Apple Watch")
            } footer: {
                Text(mappingStatusDetail)
            }

            Section {
                NavigationLink {
                    WristPrivateNetworkView(connection: connection)
                } label: {
                    Label("私有网络", systemImage: "lock.shield")
                        .frame(minHeight: 44)
                }
                NavigationLink {
                    WristPairingMaintenanceView(connection: connection)
                } label: {
                    Label("配对管理", systemImage: "key")
                        .frame(minHeight: 44)
                }
            } header: {
                Text("设置")
            } footer: {
                Text("仅局域网或 Tailscale 私有直连，公共中继已禁用。")
            }

            Section("语音与隐私") {
                Text("发给 Codex：手表录音经私有桥交给 Mac，再由 Codex 处理。\n遥控器听写：在 Mac 本地转写后输入前台 App。")
                    .font(.subheadline).foregroundStyle(.secondary)
                Text("独立的 Apple Watch 配置，不读取或修改小米遥控器的按键映射。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("腕上遥控")
    }

    private var trustConfirmation: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("首次信任这台 Mac").font(.headline)
            Text("请核对六位码，并在 Mac 上批准同一个码。两边确认前不会同步任务、映射或遥控凭证。")
                .font(.footnote).foregroundStyle(.secondary)
            if let fingerprint = connection.displayedServerIdentityFingerprint {
                Text("身份指纹 \(fingerprint)…")
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            }
            HStack {
                Button("拒绝", role: .destructive) { connection.resolveServerTrust(false) }
                Spacer()
                Button("信任这台 Mac") { connection.resolveServerTrust(true) }
                    .buttonStyle(.borderedProminent)
            }.frame(minHeight: 44)
        }.padding(.vertical, 4)
    }

    private func statusRow(_ title: String, detail: String, image: String, ready: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: image).font(.title3).frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Image(systemName: ready ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(ready ? Color.accentColor : .secondary)
                .accessibilityLabel(ready ? "已连接" : detail)
        }.frame(minHeight: 48)
    }

    private var watchStatusDetail: String {
        if !relay.isWatchPaired { return "请先在系统 Watch App 配对" }
        if !relay.isWatchAppInstalled { return "请先安装手表 App" }
        return relay.isWatchReachable ? "实时可用" : "打开手表 App 后可用"
    }

    private var mappingStatusDetail: String {
        if relay.isActionProfileReady { return "按键配置已同步 · 版本 \(profileStore.revision)" }
        if !connection.isConnected { return "连接 Mac 后同步按键配置" }
        if !connection.supportsWatchActionProfiles { return "Mac 端需要更新" }
        return connection.watchActionProfileError ?? "正在同步按键配置"
    }
}

private struct WristPrivateNetworkView: View {
    @ObservedObject var connection: WristBridgeConnection
    @State private var isEnabled = false
    @State private var host = ""
    @State private var error: String?
    @State private var saved = false
    @FocusState private var isHostFocused: Bool

    var body: some View {
        Form {
            Section("当前路径") {
                Label(connection.directRouteStatusText, systemImage: "lock.shield")
            }
            Section {
                Toggle("Tailscale 私有直连", isOn: $isEnabled)
                TextField("Mac 的 Tailscale IP", text: $host)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.asciiCapable)
                    .focused($isHostFocused)
                    .disabled(!isEnabled)
                    .accessibilityIdentifier("private-network-host")
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
                Button("保存并重新连接") {
                    isHostFocused = false
                    error = connection.updatePrivateNetwork(isEnabled: isEnabled, host: host)?.localizedDescription
                    saved = error == nil
                }
                if saved {
                    Label("设置已保存，正在按可用路径连接", systemImage: "checkmark")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                Text("非局域网连接")
            } footer: {
                Text("iPhone 与 Mac 需加入同一个私有网络。只接受 100.x 或 fd7a… 的 Tailscale 地址，端口固定为 60927。")
            }
            Section("安全边界") {
                Text("先尝试局域网，未连上再尝试 Tailscale；不会抢占已建立的连接。")
                Text("不会开启 Funnel、公共中继或路由器端口映射。Mac 仍会验证配对身份并加密传输。")
            }.font(.subheadline).foregroundStyle(.secondary)
        }
        .navigationTitle("私有网络")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { isHostFocused = false }
            }
        }
        .onAppear {
            isEnabled = connection.isPrivateNetworkEnabled
            host = connection.privateNetworkHost
        }
        .onChange(of: host) { _, _ in saved = false }
        .onChange(of: isEnabled) { _, _ in saved = false }
    }
}

private struct WristPairingMaintenanceView: View {
    enum Operation: String, Identifiable {
        case forgetMac = "忘记已信任的 Mac？"
        case resetPhone = "重置此 iPhone 的配对身份？"
        var id: Self { self }
    }
    @ObservedObject var connection: WristBridgeConnection
    @State private var operation: Operation?
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                if let identity = connection.trustedMacIdentitySummary {
                    LabeledContent("已信任 Mac") {
                        Text("\(identity)…").font(.system(.caption, design: .monospaced))
                    }
                } else {
                    Text("尚未信任 Mac")
                }
                Text("普通断连只需返回首页重新连接，不需要重置身份。")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Section {
                if connection.hasTrustedMacIdentity {
                    Button("忘记已信任的 Mac", role: .destructive) { operation = .forgetMac }
                }
                Button("重置此 iPhone 身份", role: .destructive) { operation = .resetPhone }
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            } header: {
                Text("故障恢复")
            } footer: {
                Text("仅在重装 Bridge、身份钥匙串损坏或确实需要更换设备时使用。不修改按键映射，也不影响其他遥控器。")
            }
        }
        .navigationTitle("配对管理")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(operation?.rawValue ?? "", isPresented: Binding(
            get: { operation != nil }, set: { if !$0 { operation = nil } }
        ), titleVisibility: .visible, presenting: operation) { selected in
            Button("确认并重新配对", role: .destructive) {
                let succeeded = selected == .forgetMac
                    ? connection.forgetTrustedMacIdentity()
                    : connection.resetInstallationIdentity()
                error = succeeded ? nil : "无法安全更新钥匙串身份，请稍后重试"
                operation = nil
            }
            Button("取消", role: .cancel) { operation = nil }
        } message: { _ in
            Text("下次连接需要重新核对六位码，并在 iPhone 与 Mac 两端批准。")
        }
    }
}
