import AppKit
import SwiftUI

private enum BridgePanel: String, CaseIterable, Identifiable {
    case overview = "控制中心", audio = "语音与录音", television = "电视", reading = "提词与阅读", settings = "连接与设置"
    var id: Self { self }
    var icon: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .audio: "waveform"
        case .television: "tv"
        case .reading: "text.book.closed"
        case .settings: "slider.horizontal.3"
        }
    }
}
private enum BridgePalette {
    static let background = Color(red: 0.035, green: 0.055, blue: 0.09)
    static let surface = Color(red: 0.075, green: 0.105, blue: 0.155)
    static let gold = Color(red: 0.89, green: 0.73, blue: 0.43)
}

struct BridgeContentView: View {
    @ObservedObject var model: BridgeAppModel
    @State private var panel: BridgePanel = .overview

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "applewatch").font(.system(size: 34, weight: .light)).foregroundStyle(BridgePalette.gold)
                    Text("Wrist Remote").font(.title3.weight(.semibold))
                    Text("腕上控制中心").font(.callout).foregroundStyle(.secondary)
                }.padding(.top, 26)
                VStack(spacing: 7) {
                    ForEach(BridgePanel.allCases) { item in
                        Button { panel = item } label: {
                            Label(item.rawValue, systemImage: item.icon)
                                .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
                                .padding(.horizontal, 12)
                                .foregroundStyle(panel == item ? BridgePalette.gold : Color.primary)
                                .background(panel == item ? BridgePalette.surface : .clear, in: RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(.plain)
                    }
                }
                Spacer()
                Label(model.statusTitle, systemImage: "link").font(.caption).foregroundStyle(.secondary)
                Text("\(model.connectedClients.count) 台设备已连接").font(.caption).foregroundStyle(.secondary)
            }.padding(20).frame(width: 210)
            Divider().overlay(BridgePalette.surface)
            Group {
                switch panel {
                case .overview: overview
                case .audio: audio
                case .television: BridgeTelevisionView(adapter: model.television)
                case .reading: reading
                case .settings: BridgeConnectionSettingsView(model: model)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 920, idealWidth: 1000, minHeight: 670, idealHeight: 720)
        .background(BridgePalette.background)
        .preferredColorScheme(.dark)
        .tint(BridgePalette.gold)
    }

    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("抬腕，接着做。").font(.system(size: 34, weight: .light))
                    Text("移动指针、切换画面，把声音送到电脑。").font(.title3).foregroundStyle(.secondary)
                }
                HStack(alignment: .top, spacing: 18) {
                    feature("电脑控制", icon: "cursorarrow.motionlines", detail: "触控、滚动、媒体与演示\n在手表选择模式即可操作。")
                    feature("语音与录音", icon: "mic", detail: "输入文字、保存录音、无线麦\n三种模式独立选择。")
                }
                VStack(alignment: .leading, spacing: 14) {
                    Text("连接状态").font(.headline)
                    if model.connectedClients.isEmpty {
                        Label("等待 iPhone 或 Apple Watch", systemImage: "link.badge.plus")
                        Text("在「连接与设置」打开配对入口，完成一次设备确认。").foregroundStyle(.secondary)
                    } else {
                        ForEach(model.connectedClients) { client in
                            Label(client.name, systemImage: client.transport == "HTTP" ? "applewatch" : "iphone")
                        }
                    }
                    Divider()
                    Label(model.isAccessibilityTrusted ? "电脑控制权限已开启" : "电脑控制需要辅助功能权限",
                          systemImage: model.isAccessibilityTrusted ? "checkmark.circle" : "hand.raised")
                    if !model.isAccessibilityTrusted { Button("开启辅助功能权限", action: model.requestAccessibility) }
                }.padding(22).frame(maxWidth: .infinity, alignment: .leading).background(BridgePalette.surface, in: RoundedRectangle(cornerRadius: 18))
                HStack {
                    Button("配对与设置") { panel = .settings }.buttonStyle(.borderedProminent)
                    Button("设置语音") { panel = .audio }.buttonStyle(.bordered)
                }.controlSize(.large)
                Text("手表显示实际连接与录音状态。失联时操作停止，恢复后由你重新操作。")
                    .font(.callout).foregroundStyle(.secondary)
            }.padding(34)
        }
    }

    private func feature(_ title: String, icon: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            Image(systemName: icon).font(.system(size: 28, weight: .light)).foregroundStyle(BridgePalette.gold)
            Text(title).font(.title2.weight(.medium))
            Text(detail).font(.callout).foregroundStyle(.secondary).lineSpacing(5)
        }.padding(22).frame(maxWidth: .infinity, minHeight: 170, alignment: .leading)
            .background(BridgePalette.surface, in: RoundedRectangle(cornerRadius: 18))
    }

    private var noIndependentDeviceNote: some View {
        Text("本机没有可用的独立虚拟音频设备，此功能暂不可用。BlackHole 2ch 由现有遥控使用，已排除。")
            .font(.callout).foregroundStyle(BridgePalette.gold)
    }

    /// A saved device that is no longer offered reads as unselected instead of a blank picker.
    private func offeredDevice(_ selection: Binding<String>) -> Binding<String> {
        Binding(
            get: { model.audioOutputDevices.contains { $0.id == selection.wrappedValue } ? selection.wrappedValue : "" },
            set: { selection.wrappedValue = $0 }
        )
    }

    private var audio: some View {
        Form {
            Section {
                Text("声音，分三种用。").font(.system(size: 28, weight: .light))
                Text(model.audioModeStatus).foregroundStyle(.secondary)
            }
            Section("语音输入") {
                Text("手表选「语音输入」，开始说话，停止后输入 Mac 当前文本框。需要语音识别与辅助功能权限。")
                Button("允许语音识别", action: model.requestSpeechAuthorization)
            }
            Section("Codex 原生听写") {
                Text("此功能尚未完成，当前版本不可用。")
                    .foregroundStyle(.secondary)
            }
            Section("保存录音") {
                Text("手表选「保存录音」，以单声道 AAC（M4A）边收边存，16 kbps，每分钟约 150 KB。每段最多 115 秒，到时自动保存。音频只留在本机。")
                Button("打开录音文件夹", action: model.showRecordings)
                if let url = model.lastSavedRecording { Text(url.lastPathComponent).font(.caption).textSelection(.enabled) }
            }
            Section("无线麦输出") {
                Picker("虚拟音频设备", selection: offeredDevice($model.selectedAudioOutputUID)) {
                    Text("请选择").tag("")
                    ForEach(model.audioOutputDevices) { device in Text(device.name).tag(device.id) }
                }
                if model.audioOutputDevices.isEmpty { noIndependentDeviceNote }
                Button("刷新设备", action: model.refreshAudioOutputs)
                Text("在会议或录制软件中，把同一个虚拟设备选为麦克风输入。这里仅改变本 App 的输出，不更改系统默认声音设备。")
                    .foregroundStyle(.secondary)
                Text("前台测试模式：经 iPhone 传输，115 秒自动停止。息屏、断线或积压会停止，实际延迟与收音需真机确认。")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).scrollContentBackground(.hidden).task { model.refreshAudioOutputs() }
    }

    private var reading: some View {
        VStack(alignment: .leading, spacing: 24) {
            Image(systemName: "text.book.closed").font(.system(size: 42, weight: .light)).foregroundStyle(BridgePalette.gold)
            Text("把内容放在 iPad，\n把节奏留在手腕。").font(.system(size: 30, weight: .light))
            Text("1. 在 iPad 安装同一伴侣 App，并配对这台 Mac。\n2. 打开「提词与阅读会话」，粘贴或导入文本。\n3. 开始会话后，在手表设备列表选中它。")
                .font(.body).lineSpacing(12)
            Text("手表可切段、暂停与调速，iPad 支持镜像提词。会话离开前台即停止，不会替其他 App 接收操作。")
                .foregroundStyle(.secondary)
            Spacer()
        }.padding(40).frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct BridgeTelevisionView: View {
    @ObservedObject var adapter: WristTelevisionAdapter
    @State private var name = "客厅电视"
    @State private var address = ""
    @State private var executable = ""
    var body: some View {
        Form {
            Section {
                Text("电视遥控").font(.system(size: 28, weight: .light))
                Text(adapter.status).foregroundStyle(.secondary)
            }
            Section("Android / Google TV") {
                TextField("设备名称", text: $name)
                TextField("局域网地址与端口", text: $address, prompt: Text("192.168.x.x:5555"))
                HStack {
                    Text(executable.isEmpty ? "选择本机 adb 程序" : URL(fileURLWithPath: executable).lastPathComponent)
                    Spacer()
                    Button("选择程序…") {
                        let picker = NSOpenPanel(); picker.canChooseDirectories = false; picker.allowsMultipleSelection = false
                        if picker.runModal() == .OK, let path = picker.url?.path { executable = path }
                    }
                }
                HStack {
                    Button("连接电视") {
                        Task { await adapter.connect(.init(name: name, address: address, executablePath: executable)) }
                    }.disabled(adapter.isBusy)
                    Button("停用") { adapter.disconnect() }
                }
                Text("需要电视开启网络调试，并在电视上允许这台 Mac。连接后，手表设备列表会出现电视；方向、确认、返回、播放和音量均为固定按键。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("其他电视") {
                Text("Apple TV 当前尚未接入。请使用其系统遥控器；这里不会把未配对设备显示为可控制。")
                    .foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).scrollContentBackground(.hidden)
            .onAppear {
                if let configuration = adapter.configuration {
                    name = configuration.name
                    address = configuration.address
                    executable = configuration.executablePath
                }
            }
    }
}
