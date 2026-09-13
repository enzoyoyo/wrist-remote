import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

enum BridgePairingDevice: String, Identifiable {
    case iphone
    case watch
    var id: Self { self }
}

enum BridgePhonePairingLink {
    static func make(configuration: WristDirectBridgeConfiguration?) -> URL? {
        guard let configuration, configuration.validated() != nil,
              let endpoint = URLComponents(string: configuration.endpoint),
              let host = endpoint.host
        else { return nil }
        var result = URLComponents()
        result.scheme = "wristremote"
        result.host = "pair"
        result.queryItems = [
            URLQueryItem(name: "version", value: "1"),
            URLQueryItem(name: "host", value: host),
            URLQueryItem(name: "port", value: "60927"),
            URLQueryItem(name: "identity", value: configuration.serverIdentityPublicKey),
            URLQueryItem(name: "name", value: configuration.serverName),
        ]
        return result.url
    }

    static func qrImage(for url: URL) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let image = CIContext().createCGImage(output, from: output.extent)
        else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}

struct BridgePairingSheet: View {
    @ObservedObject var model: BridgeAppModel
    let device: BridgePairingDevice
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    private var link: URL? { BridgePhonePairingLink.make(configuration: model.directBridgeConfiguration) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(device == .iphone ? "连接 iPhone" : "连接 Apple Watch")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            if let link, let qrImage = BridgePhonePairingLink.qrImage(for: link) {
                HStack(alignment: .top, spacing: 24) {
                    Image(nsImage: qrImage)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 208, height: 208)
                        .padding(12)
                        .background(.white)
                        .accessibilityLabel("用 iPhone 相机扫描的配对二维码")
                    VStack(alignment: .leading, spacing: 14) {
                        Text("1. iPhone 与 Mac 连接同一局域网，并安装新版 Wrist Remote。")
                        Text("2. 用 iPhone 相机扫码，打开 Wrist Remote。也可在 App 中自动发现这台 Mac。")
                        Text("3. 核对两端六位确认码，在 Mac 上允许连接。")
                        Button(copied ? "已复制配对链接" : "复制配对链接") {
                            NSPasteboard.general.clearContents()
                            copied = NSPasteboard.general.setString(link.absoluteString, forType: .string)
                        }
                    }
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                }
                if let configuration = model.directBridgeConfiguration {
                    Text(configuration.serverName)
                        .font(.headline)
                    Text(URLComponents(string: configuration.endpoint)?.host ?? "")
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            } else {
                Text("正在等待可用的局域网连接。")
                    .font(.headline)
                Text("请让 Mac 接入 Wi-Fi 或有线局域网，并保持腕上遥控桥运行。服务准备好后，二维码会自动出现。")
                    .foregroundStyle(.secondary)
            }

            if device == .watch {
                Divider()
                Text("iPhone 连接成功后，打开 Watch 上的 Wrist Remote，启用“直接连接 Mac”。首次直连需再核对一次确认码。")
                    .fixedSize(horizontal: false, vertical: true)
                Text("按键直连不要求 iPhone App 保持前台。Watch 需能访问同一局域网；语音仍使用 iPhone 中转。")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let request = model.pairingRequest {
                Divider()
                Text("\(request.deviceName) 正在请求配对")
                    .font(.headline)
                HStack {
                    Text(request.pairingCode).font(.title.monospacedDigit())
                    Spacer()
                    Button("拒绝", role: .cancel) { model.resolvePairing(false) }
                    Button("确认码一致，允许连接") { model.resolvePairing(true) }
                }
                Text("请与设备上显示的六位数字核对，只有一致时才允许。")
                    .font(.callout)
            }
            Text("二维码只含 Mac 地址和公开身份；扫描不会自动授权，也不会改变其他遥控器或音频设置。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(width: 610)
        .onChange(of: link) { _ in copied = false }
    }
}
