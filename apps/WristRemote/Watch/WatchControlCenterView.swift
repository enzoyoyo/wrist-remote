import SwiftUI
import WatchKit

private enum ControlMode: String, CaseIterable, Identifiable {
    case touch = "触控板", media = "媒体", voice = "语音输入", recording = "保存录音", microphone = "无线麦", codexNative = "Codex 听写", presentation = "演示", television = "电视", reading = "提词与阅读"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .touch: "rectangle.and.hand.point.up.left"
        case .media: "playpause"
        case .voice: "mic"
        case .recording: "waveform"
        case .microphone: "mic.and.signal.meter"
        case .codexNative: "text.bubble"
        case .presentation: "play.rectangle"
        case .television: "tv"
        case .reading: "text.book.closed"
        }
    }
}

struct WatchControlCenterView: View {
    @ObservedObject var controller: WatchSessionController
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var mode: ControlMode = .touch
    @State private var showingModes = false
    @State private var showingDevices = false
    @State private var crown = 0.0
    @State private var previousCrown = 0.0
    @State private var dragTranslation = CGSize.zero
    @FocusState private var crownFocused: Bool
    private var usesCompactNavigation: Bool { ![.touch, .presentation].contains(mode) }

    private var targetName: String { controller.selectedControlTarget?.name ?? "Mac" }
    private var modeMatchesTarget: Bool {
        guard let target = controller.selectedControlTarget else { return false }
        switch mode {
        case .television: return target.kind == .television
        case .reading: return target.kind == .readingSession
        default: return target.kind == .mac
        }
    }
    private var connectionText: String {
        if controller.isVoiceActive { return "● 正在录音" }
        if controller.isAudioModePreparing { return "正在准备录音" }
        if controller.isAudioModeFinishing { return "正在确认录音结果" }
        if [.voice, .recording, .microphone, .codexNative].contains(mode), !controller.canStartPrivateAudio {
            return "语音链路未就绪"
        }
        if controller.controlFailed { return "操作未完成 · 查看更多" }
        if controller.canSendControl && !modeMatchesTarget { return "请先选择对应设备" }
        return controller.canSendControl ? controller.remoteConnectionPathText : "未连接"
    }

    var body: some View {
        VStack(spacing: 5) {
            HStack {
                Text(connectionText)
                    .font(.caption2)
                    .foregroundStyle(controller.isVoiceActive ? Color.orange : Color.wristRemoteMuted)
                    .lineLimit(2)
                    .accessibilityIdentifier("control-connection-state")
                if usesCompactNavigation {
                    Spacer(minLength: 4)
                    Button { showingModes = true } label: { Image(systemName: "square.grid.2x2") }
                        .buttonStyle(.plain)
                        .accessibilityLabel("控制模式：\(mode.rawValue)")
                        .accessibilityIdentifier("control-mode-picker")
                        .disabled(controller.isVoiceActive || controller.isVoiceStartPending)
                }
            }

            Group {
                if mode == .touch { touchpad }
                else if usesCompactNavigation || !typeSize.isAccessibilitySize { mainControl }
                else { ScrollView { mainControl.padding(.bottom, 3) } }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)

            if !usesCompactNavigation { HStack(spacing: 7) {
                Button { showingModes = true } label: {
                    Group {
                        if typeSize.isAccessibilitySize { Image(systemName: "square.grid.2x2") }
                        else { Label("模式", systemImage: "square.grid.2x2") }
                    }
                        .font(.caption).frame(maxWidth: .infinity, minHeight: 40)
                        .background(Color.wristRemoteSurface, in: Capsule())
                }
                .accessibilityLabel("控制模式：\(mode.rawValue)")
                .accessibilityIdentifier("control-mode-picker")
                .disabled(controller.isVoiceActive || controller.isVoiceStartPending)
                NavigationLink {
                    morePage
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: controller.controlFailed ? "exclamationmark.circle" : "ellipsis")
                        if !typeSize.isAccessibilitySize { Text("更多") }
                    }.font(.caption).frame(maxWidth: .infinity, minHeight: 40)
                        .background(Color.wristRemoteSurface, in: Capsule())
                }
                .accessibilityLabel("更多功能")
                .accessibilityIdentifier("control-more")
            }
            .buttonStyle(.plain) }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 4)
        .background(Color.wristRemoteBackground.ignoresSafeArea())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { showingDevices = true } label: {
                    HStack(spacing: 3) {
                        Text(targetName).font(.caption2).lineLimit(1)
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(Color.wristRemoteAccent)
                    .frame(minHeight: 30)
                }
                    .buttonStyle(.plain)
                    .accessibilityLabel("选择设备")
                    .accessibilityIdentifier("control-device-picker")
                    .disabled(controller.isVoiceActive || controller.isVoiceStartPending)
            }
        }
        .focusable()
        .focused($crownFocused)
        .digitalCrownRotation($crown, from: -10_000, through: 10_000, by: 1,
                              sensitivity: .medium, isContinuous: true, isHapticFeedbackEnabled: false)
        .onChange(of: crown) { _, value in
            let delta = value - previousCrown
            previousCrown = value
            guard modeMatchesTarget, abs(delta) >= 1, abs(delta) < 20 else { return }
            switch mode {
            case .touch: controller.sendControl(.scroll, y: delta * -12)
            case .media, .television: controller.sendControl(delta > 0 ? .volumeUp : .volumeDown)
            case .reading: controller.sendControl(delta > 0 ? .sessionFaster : .sessionSlower)
            default: break
            }
        }
        .task {
            crownFocused = true
            while !Task.isCancelled {
                controller.refreshControlTargets()
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .onDisappear { dragTranslation = .zero }
        .sheet(isPresented: $showingModes) { modePicker }
        .sheet(isPresented: $showingDevices) { devicePicker }
    }

    @ViewBuilder private var mainControl: some View {
        switch mode {
        case .touch: touchpad
        case .media: media
        case .voice, .recording, .microphone, .codexNative: voice
        case .presentation: presentation
        case .television: television
        case .reading: reading
        }
    }

    private var touchpad: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 22).fill(Color.wristRemoteSurface)
                Canvas { context, size in
                    let spacing: CGFloat = 17
                    for x in stride(from: spacing / 2, through: size.width, by: spacing) {
                        for y in stride(from: spacing / 2, through: size.height, by: spacing) {
                            context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1.5, height: 1.5)),
                                         with: .color(Color.wristRemoteAccent.opacity(0.3)))
                        }
                    }
                }.clipShape(RoundedRectangle(cornerRadius: 22))
                VStack(spacing: 6) {
                    Image(systemName: "cursorarrow.rays").font(.system(size: 25, weight: .light))
                        .foregroundStyle(Color.wristRemoteAccent)
                    if !typeSize.isAccessibilitySize {
                        Text("滑动 · 轻点").font(.caption2).foregroundStyle(Color.wristRemoteMuted)
                    }
                }
            }
            .frame(minHeight: typeSize.isAccessibilitySize ? 40 : 64)
            .contentShape(RoundedRectangle(cornerRadius: 22))
            .gesture(TapGesture().exclusively(before: DragGesture(minimumDistance: 3)
                .onChanged { drag in
                        guard modeMatchesTarget else { return }
                        let x = min(400, max(-400, Double(drag.translation.width - dragTranslation.width) * 2.2))
                        let y = min(400, max(-400, Double(drag.translation.height - dragTranslation.height) * 2.2))
                        dragTranslation = drag.translation
                        controller.sendControl(.pointer, x: x, y: y)
                }).onEnded { value in
                    if case .first = value, modeMatchesTarget { controller.sendControl(.click) }
                    dragTranslation = .zero
                })
            .accessibilityLabel("触控板")
            .accessibilityHint("滑动移动 Mac 指针，轻点点击，转动表冠滚动")
            .accessibilityIdentifier("control-touchpad")
            .accessibilityAction(named: "点击") { if modeMatchesTarget { controller.sendControl(.click) } }
            .accessibilityAction(named: "右键") { if modeMatchesTarget { controller.sendControl(.secondaryClick) } }
            HStack {
                Text("表冠滚动").font(.caption2).foregroundStyle(Color.wristRemoteMuted)
                Spacer()
                Button("右键") { controller.sendControl(.secondaryClick) }
                    .font(.caption2).buttonStyle(.plain).frame(minWidth: 44, minHeight: 30)
                    .disabled(!controller.canSendControl || !modeMatchesTarget)
            }
        }
    }

    private var media: some View {
        GeometryReader { geometry in
            VStack(spacing: 5) {
                Text("表冠调音量").font(.caption2).foregroundStyle(Color.wristRemoteMuted)
                Spacer(minLength: 0)
                HStack(spacing: 5) {
                    controlButton("上一首", icon: "backward.end.fill", action: .previousTrack, height: min(44, max(30, geometry.size.height / 3)))
                    controlButton("播放或暂停", icon: "playpause.fill", action: .playPause, primary: true, height: min(52, max(30, geometry.size.height / 3)))
                    controlButton("下一首", icon: "forward.end.fill", action: .nextTrack, height: min(44, max(30, geometry.size.height / 3)))
                }
                Spacer(minLength: 0)
                controlButton("静音", icon: "speaker.slash", action: .mute, height: min(36, max(26, geometry.size.height / 4)))
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // Normal type sizes fit the first screen; accessibility sizes scroll instead.
    @ViewBuilder private var voice: some View {
        if typeSize.isAccessibilitySize { voiceStack(buttonHeight: 44) }
        else {
            GeometryReader { geometry in
                voiceStack(buttonHeight: min(60, max(44, geometry.size.height - 42)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func voiceStack(buttonHeight: CGFloat) -> some View {
        VStack(spacing: 5) {
            Button {
                controller.setAudioModePressed(!(controller.isVoiceActive || controller.isAudioModePreparing), intent: mode == .recording ? .recording : mode == .microphone ? .wirelessMicrophone : mode == .codexNative ? .codexNativeDictation : .foregroundDictation)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: controller.isVoiceActive || controller.isAudioModePreparing ? "stop.fill" : controller.isAudioModeFinishing ? "hourglass" : "mic.fill")
                        .font(.system(size: 23, weight: .medium))
                    Text(controller.isVoiceActive || controller.isAudioModePreparing ? "停止" : controller.isAudioModeFinishing ? "确认中" : typeSize.isAccessibilitySize ? "开始" : mode == .voice ? "开始说话" : "开始采音")
                        .font(.caption)
                }
                .frame(maxWidth: .infinity, minHeight: buttonHeight, maxHeight: buttonHeight)
                .foregroundStyle(Color.wristRemoteBackground)
                .background(Color.wristRemoteAccent, in: RoundedRectangle(cornerRadius: 22))
            }
            .buttonStyle(.plain)
            .disabled(mode == .codexNative || !(controller.canStartPrivateAudio || controller.isVoiceActive || controller.isAudioModePreparing))
            .accessibilityIdentifier("control-voice-toggle")
            Text(controller.privateAudioStatusText ?? (mode == .voice ? "输入 Mac 当前文本框" : mode == .recording ? "停止后保存到 Mac" : mode == .codexNative ? "此功能暂不可用" : "前台采音 · Mac 选择虚拟输出"))
                .font(.caption2).foregroundStyle(Color.wristRemoteMuted).lineLimit(2)
                .minimumScaleFactor(0.85).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("control-audio-status")
        }
    }

    @ViewBuilder private var presentation: some View {
        if typeSize.isAccessibilitySize { presentationStack(pageHeight: 40, sessionHeight: 40, showsHint: false) }
        else {
            GeometryReader { geometry in
                let showsHint = geometry.size.height >= 96
                let rows = geometry.size.height - (showsHint ? 22 : 0) - 5
                let pageHeight = min(52, max(30, rows * 0.55))
                presentationStack(pageHeight: pageHeight, sessionHeight: min(44, max(28, rows - pageHeight)), showsHint: showsHint)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func presentationStack(pageHeight: CGFloat, sessionHeight: CGFloat, showsHint: Bool) -> some View {
        VStack(spacing: 5) {
            HStack(spacing: 5) {
                controlButton("上一页", icon: "chevron.left", action: .previousPage, height: pageHeight)
                controlButton("下一页", icon: "chevron.right", action: .nextPage, primary: true, height: pageHeight)
            }
            HStack(spacing: 5) {
                controlButton("开始 Keynote", icon: "play.rectangle", action: .presentationStart, height: sessionHeight)
                controlButton("退出演示", icon: "xmark", action: .presentationStop, height: sessionHeight)
            }
            if showsHint {
                Text("操作 Mac 当前前台应用").font(.caption2).foregroundStyle(Color.wristRemoteMuted).lineLimit(1)
            }
        }
    }

    private var television: some View {
        GeometryReader { geometry in
            let height = max(22, (geometry.size.height - 9) / 4)
            VStack(spacing: 3) {
                controlButton("上", icon: "chevron.up", action: .up, height: height).frame(maxWidth: .infinity).padding(.horizontal, geometry.size.width * 0.25)
                HStack(spacing: 4) {
                    controlButton("左", icon: "chevron.left", action: .left, height: height)
                    controlButton("确认", icon: "", action: .select, primary: true, height: height)
                    controlButton("右", icon: "chevron.right", action: .right, height: height)
                }
                controlButton("下", icon: "chevron.down", action: .down, height: height).frame(maxWidth: .infinity).padding(.horizontal, geometry.size.width * 0.25)
                HStack(spacing: 4) {
                    controlButton("返回", icon: "arrow.uturn.backward", action: .back, height: height)
                    controlButton("播放或暂停", icon: "playpause", action: .playPause, height: height)
                }
            }
        }
    }

    private var reading: some View {
        GeometryReader { geometry in
            VStack(spacing: 4) {
                if !typeSize.isAccessibilitySize {
                    Text("提词会话").font(.caption2).foregroundStyle(Color.wristRemoteMuted)
                }
                Text(controller.selectedControlTarget?.kind == .readingSession ? targetName : "选择阅读会话")
                    .font(.headline).lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    controlButton("上一段", icon: "chevron.left", action: .previousPage, height: min(44, max(28, geometry.size.height / 3)))
                    controlButton("播放或暂停", icon: "playpause", action: .sessionPlayPause, primary: true, height: min(44, max(28, geometry.size.height / 3)))
                    controlButton("下一段", icon: "chevron.right", action: .nextPage, height: min(44, max(28, geometry.size.height / 3)))
                }
                if !typeSize.isAccessibilitySize {
                    Text("表冠调速").font(.caption2).foregroundStyle(Color.wristRemoteMuted)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityHint("转动表冠调整提词速度")
        }
    }

    private func controlButton(_ title: String, icon: String, action: WristControlCommand.Action, primary: Bool = false, height: CGFloat = 40) -> some View {
        Button { controller.sendControl(action) } label: {
            Group {
                if icon.isEmpty { Text("OK").font(.system(size: 18, weight: .semibold)) }
                else { Image(systemName: icon).font(.system(size: 19, weight: .medium)) }
            }
                .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
                .foregroundStyle(primary ? Color.wristRemoteBackground : Color.primary)
                .background(primary ? Color.wristRemoteAccent : Color.wristRemoteSurface, in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .disabled(!controller.canSendControl || !modeMatchesTarget || controller.selectedControlTarget?.actions.contains(action) != true)
    }

    private var modePicker: some View {
        NavigationStack {
            List {
                if mode == .television {
                    Button("电视主页") { controller.sendControl(.home); showingModes = false }
                        .disabled(!controller.canSendControl || !modeMatchesTarget)
                }
                ForEach(ControlMode.allCases) { item in
                    Button {
                        mode = item; showingModes = false
                        WatchHaptics.play(.click)
                    } label: {
                        Label(item.rawValue, systemImage: item.icon).padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("控制模式")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { showingModes = false } } }
        }
    }

    private var devicePicker: some View {
        NavigationStack {
            List {
                if controller.controlTargets.isEmpty {
                    Text("还没有连接的设备").font(.headline)
                    Text("先在 iPhone 配对 Mac，或打开直连设置。").font(.caption)
                }
                ForEach(controller.controlTargets) { target in
                    Button {
                        controller.selectControlTarget(target.id)
                        mode = target.kind == .television ? .television : target.kind == .readingSession ? .reading : .touch
                        showingDevices = false
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(target.name)
                            Text(target.detail).font(.caption2).foregroundStyle(Color.wristRemoteMuted)
                        }
                    }
                }
                NavigationLink("连接设置") { WatchDirectConnectionView(controller: controller) }
            }
            .navigationTitle("设备")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { showingDevices = false } } }
        }
        .task { controller.refreshControlTargets() }
    }

    private var morePage: some View {
        List {
            if let outcome = controller.controlOutcome { Text(outcome).font(.caption) }
            NavigationLink("自定义遥控") { RemoteDeckView(controller: controller) }
            NavigationLink("Codex") { WatchCodexConversationHomeView(controller: controller).navigationTitle("Codex") }
            NavigationLink("连接设置") { WatchDirectConnectionView(controller: controller) }
        }.navigationTitle("更多")
    }
}
