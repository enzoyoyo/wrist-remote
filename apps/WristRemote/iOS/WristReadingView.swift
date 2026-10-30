import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class WristReadingController: ObservableObject {
    @Published var title = "我的提词"
    @Published var text = "把要讲的内容放在这里。\n\n每段之间空一行，手表可以切换段落。\n\n开始会话后，保持此页面打开。"
    @Published private(set) var state: WristReadingSessionState?
    @Published private(set) var pages: [String] = []
    @Published private(set) var detail: String?
    struct Dependencies {
        var isConnected: () -> Bool
        var publish: (WristReadingSessionState?) -> Void
        var setReceiver: (((WristControlCommand) -> WristControlReceipt)?) -> Void
    }
    private let dependencies: Dependencies
    private var heartbeat: Task<Void, Never>?
    private var gate = WristControlReplayGate()
    private var lastAdvance = Date()

    init(dependencies: Dependencies) { self.dependencies = dependencies }
    convenience init(connection: WristBridgeConnection) {
        self.init(dependencies: .init(
            isConnected: { connection.isConnected },
            publish: { connection.publishReadingSession($0) },
            setReceiver: { connection.onReadingControl = $0 }))
    }
    func start() {
        guard dependencies.isConnected() else { detail = "请先连接 Mac"; return }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty, cleanTitle.count <= 80, text.utf8.count <= 200_000 else {
            detail = "标题限 80 字，正文限 200 KB"; return
        }
        let normalizedText = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let paragraphs = normalizedText.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !paragraphs.isEmpty, paragraphs.count <= 1_000 else { detail = "请输入 1 至 1000 段文字"; return }
        pages = paragraphs
        let state = WristReadingSessionState(id: UUID(), title: cleanTitle, page: 0, pageCount: pages.count, isPlaying: false, speed: 1)
        guard state.isValid else { detail = "标题包含无效字符"; return }
        self.state = state; detail = nil; lastAdvance = Date()
        dependencies.setReceiver { [weak self] command in self?.receive(command) ?? .init(id: command.id, accepted: false, detail: "会话已结束") }
        dependencies.publish(state)
        heartbeat?.cancel()
        heartbeat = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled, var state = self.state else { return }
                guard dependencies.isConnected() else { self.stop(); self.detail = "Mac 连接中断，会话已停止"; return }
                if state.isPlaying, Date().timeIntervalSince(self.lastAdvance) >= 6 / state.speed {
                    _ = state.apply(.nextPage); self.state = state; self.lastAdvance = Date()
                }
                dependencies.publish(self.state)
            }
        }
    }

    func stop() {
        heartbeat?.cancel(); heartbeat = nil
        state = nil; dependencies.setReceiver(nil)
        dependencies.publish(nil)
    }
    func local(_ action: WristControlCommand.Action) {
        guard var state else { return }; _ = state.apply(action)
        self.state = state; lastAdvance = Date(); dependencies.publish(state)
    }
    private func receive(_ command: WristControlCommand) -> WristControlReceipt {
        guard var state, command.targetID == state.targetID,
              gate.accept(command, now: Int64(Date().timeIntervalSince1970 * 1_000)), state.apply(command.action) else {
            return .init(id: command.id, accepted: false, detail: "会话已变化或操作过期")
        }
        self.state = state; lastAdvance = Date(); dependencies.publish(state)
        return .init(id: command.id, accepted: true, detail: "阅读设备已确认 · 第 \(state.page + 1) 段")
    }
    func importText(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
            guard size <= 200_000 else { detail = "文件超过 200 KB"; return }
            text = try String(contentsOf: url, encoding: .utf8)
            title = String(url.deletingPathExtension().lastPathComponent.prefix(80))
        } catch { detail = "无法读取 UTF-8 文本文件" }
    }
}

struct WristReadingView: View {
    @StateObject private var reader: WristReadingController
    @Environment(\.scenePhase) private var scenePhase
    @State private var importing = false
    @State private var mirrored = false
    init(connection: WristBridgeConnection) { _reader = StateObject(wrappedValue: WristReadingController(connection: connection)) }
    init(reader: WristReadingController) { _reader = StateObject(wrappedValue: reader) }

    var body: some View {
        Group {
            if let state = reader.state {
                VStack(spacing: 20) {
                    HStack {
                        Text(state.title).font(.headline)
                        Spacer()
                        Text("\(state.page + 1) / \(state.pageCount)").monospacedDigit()
                    }
                    ScrollView {
                        Text(reader.pages[state.page])
                            .font(.system(size: 42, weight: .medium, design: .rounded))
                            .lineSpacing(14).frame(maxWidth: 900, alignment: .leading)
                            .padding(20)
                            .scaleEffect(x: mirrored ? -1 : 1, y: 1)
                    }
                    HStack(spacing: 28) {
                        Button { reader.local(.previousPage) } label: { Image(systemName: "backward.end") }.accessibilityLabel("上一段").accessibilityIdentifier("reading-previous")
                        Button { reader.local(.sessionPlayPause) } label: { Image(systemName: state.isPlaying ? "pause.fill" : "play.fill") }.accessibilityLabel(state.isPlaying ? "暂停" : "播放").accessibilityIdentifier("reading-play")
                        Button { reader.local(.nextPage) } label: { Image(systemName: "forward.end") }.accessibilityLabel("下一段").accessibilityIdentifier("reading-next")
                        Text(String(format: "%.1f×", state.speed)).monospacedDigit()
                    }.font(.title2).buttonStyle(.bordered).controlSize(.large)
                    Toggle("镜像提词", isOn: $mirrored).frame(maxWidth: 280)
                    Button("结束会话", role: .destructive) { reader.stop() }.padding(.top, 4)
                }.padding(24).background(Color(red: 0.035, green: 0.055, blue: 0.09))
            } else {
                Form {
                    Section("准备内容") {
                        TextField("会话名称", text: $reader.title)
                        TextEditor(text: $reader.text).frame(minHeight: 250)
                        Button("导入文本文件") { importing = true }
                    }
                    Section {
                        Button("开始会话") { reader.start() }.accessibilityIdentifier("reading-start")
                        if let detail = reader.detail { Text(detail).foregroundStyle(.secondary) }
                    } footer: {
                        Text("每个空行分隔一段。开始后，在手表的设备列表中选择此会话。离开页面或断线会结束控制；不会操作其他 App。")
                    }
                }
            }
        }
        .navigationTitle("提词与阅读")
        .preferredColorScheme(.dark)
        .tint(Color(red: 0.89, green: 0.73, blue: 0.43))
        .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText]) { result in
            if case let .success(url) = result { reader.importText(url) }
        }
        .onDisappear { reader.stop() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { reader.stop() } }
    }
}
