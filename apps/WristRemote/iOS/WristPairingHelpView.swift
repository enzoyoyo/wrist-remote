import SwiftUI

struct WristPairingHelpView: View {
    @ObservedObject var connection: WristBridgeConnection
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var didImport = false
    @State private var inputError: String?
    @FocusState private var isLinkFocused: Bool

    var body: some View {
        Form {
            Section("扫码连接") {
                Text("在 Mac 的腕上遥控桥中点“连接 iPhone”，用 iPhone 系统相机扫描二维码，再打开 Wrist Remote。")
                Text("iPhone 与 Mac 需连接同一局域网，或同一 Tailscale 私有网络。首次连接仍需核对两端六位确认码。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                TextField("wristremote://pair?…", text: $link, axis: .vertical)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($isLinkFocused)
                    .accessibilityIdentifier("pairing-link-input")
                Button("从链接连接") {
                    isLinkFocused = false
                    inputError = nil
                    if let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)) {
                        didImport = connection.importPairingLink(url)
                        if didImport { dismiss() }
                    } else {
                        didImport = false
                        inputError = WristPairingLinkError.invalidLink.localizedDescription
                    }
                }
                .disabled(link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("pairing-link-connect")
                if let error = inputError ?? connection.pairingLinkError {
                    Text(error).font(.footnote).foregroundStyle(.secondary)
                }
                if didImport {
                    Text("链接已验证，正在连接。返回首页核对两端确认码。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                Text("也可粘贴 Mac 的配对链接")
            } footer: {
                Text("链接只包含 Mac 私有地址和公开身份，不含密码或密钥。未通过身份验证前不会传递遥控配置。")
            }
        }
        .navigationTitle("连接 iPhone")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { isLinkFocused = false }
            }
        }
        .onChange(of: link) { _, _ in didImport = false }
    }
}
