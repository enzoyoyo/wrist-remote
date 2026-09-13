import SwiftUI

struct WatchDirectConnectionView: View {
    @ObservedObject var controller: WatchSessionController

    var body: some View {
        Form {
            Section("当前遥控路径") {
                Label(controller.remoteConnectionPathText, systemImage: "laptopcomputer")
                    .accessibilityIdentifier("remote-connection-path")
                Text(controller.directBridgeStatusText)
                    .font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
                if let result = controller.directButtonOutcome {
                    Text(result)
                        .font(.footnote)
                        .accessibilityIdentifier("direct-button-result")
                }
            }
            Section {
                Toggle("直接连接 Mac", isOn: Binding(
                    get: { controller.directBridgeEnabled },
                    set: { controller.setDirectBridgeEnabled($0) }
                ))
                .accessibilityIdentifier("direct-bridge-enabled")
                Button("重新连接", systemImage: "arrow.clockwise") {
                    controller.reconnectRemoteControl()
                }
                .accessibilityIdentifier("direct-bridge-reconnect")
            } footer: {
                Text("首次先连接 iPhone 与 Mac 同步配置，再在 Mac 批准手表。关闭直连不影响经 iPhone 遥控。")
            }
            Section("语音") {
                Text(controller.remoteVoiceAvailabilityText)
                    .font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .navigationTitle("遥控连接")
        .navigationBarTitleDisplayMode(.inline)
    }
}
