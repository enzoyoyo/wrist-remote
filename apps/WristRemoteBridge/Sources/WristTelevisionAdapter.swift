import Foundation

struct WristTelevisionConfiguration: Codable, Equatable {
    var id = UUID()
    var name: String
    var address: String
    var executablePath: String

    var isValid: Bool {
        let pieces = address.split(separator: ":", omittingEmptySubsequences: false)
        guard pieces.count == 2, let port = UInt16(pieces[1]), port > 0,
              WristDirectBridgeConfiguration.isPrivateLiteral(String(pieces[0])),
              !pieces[0].contains(":"), !name.trimmingCharacters(in: .whitespaces).isEmpty,
              name.count <= 64, executablePath.hasPrefix("/"), executablePath.count < 1024 else { return false }
        return true
    }
}

struct WristProcessResult: Equatable, Sendable { let status: Int32; let output: String }

enum WristTVCommandPolicy {
    static func keyCode(_ action: WristControlCommand.Action) -> Int? {
        switch action {
        case .up: 19
        case .down: 20
        case .left: 21
        case .right: 22
        case .select: 23
        case .back: 4
        case .home: 3
        case .playPause: 85
        case .volumeUp: 24
        case .volumeDown: 25
        case .mute: 164
        case .nextTrack: 87
        case .previousTrack: 88
        default: nil
        }
    }
    static let actions = WristControlCommand.Action.allCases.filter { keyCode($0) != nil }
}

/// One bounded child with argument arrays; arbitrary shell commands are never accepted.
private final class WristProcessCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var tooLarge = false
    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        if data.count + chunk.count > 65_536 { tooLarge = true }
        data.append(chunk.prefix(max(0, 65_536 - data.count)))
    }
    func result(status: Int32) -> WristProcessResult {
        lock.lock(); defer { lock.unlock() }
        return .init(status: tooLarge ? -2 : status, output: String(data: data, encoding: .utf8) ?? "")
    }
}

enum WristBoundedProcess {
    static func run(path: String, arguments: [String]) async throws -> WristProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process(); let pipe = Pipe(); let capture = WristProcessCapture()
            process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments
            process.standardOutput = pipe; process.standardError = pipe
            process.standardInput = FileHandle.nullDevice
            pipe.fileHandleForReading.readabilityHandler = { handle in capture.append(handle.availableData) }
            let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
            process.terminationHandler = { child in
                timeout.cancel()
                pipe.fileHandleForReading.readabilityHandler = nil
                capture.append(pipe.fileHandleForReading.readDataToEndOfFile())
                continuation.resume(returning: capture.result(status: child.terminationStatus))
            }
            do {
                try process.run()
                DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: timeout)
            } catch {
                process.terminationHandler = nil
                pipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }
}

@MainActor
final class WristTelevisionAdapter: ObservableObject {
    typealias Runner = (String, [String]) async throws -> WristProcessResult
    @Published private(set) var status = "尚未连接电视"
    @Published private(set) var configuration: WristTelevisionConfiguration?
    @Published private(set) var isConnected = false
    @Published private(set) var isBusy = false
    var onChange: (() -> Void)?
    private let runner: Runner
    private var generation = 0

    init(runner: @escaping Runner = WristBoundedProcess.run) { self.runner = runner }

    var target: WristControlTarget? {
        guard let configuration, isConnected else { return nil }
        return .init(id: "tv-" + configuration.id.uuidString, name: configuration.name, kind: .television,
                     detail: "Android TV · 已授权连接", actions: WristTVCommandPolicy.actions)
    }

    func connect(_ configuration: WristTelevisionConfiguration) async {
        guard !isBusy else { return }
        guard configuration.isValid else {
            disconnect()
            status = "请输入局域网地址与端口，并选择 adb 程序"
            onChange?()
            return
        }
        generation += 1; let ticket = generation
        self.configuration = configuration; isConnected = false; isBusy = true
        status = "正在连接电视"; onChange?()
        defer { if generation == ticket { isBusy = false }; onChange?() }
        do {
            let connected = try await runner(configuration.executablePath, ["connect", configuration.address])
            guard generation == ticket else { return }
            guard connected.status == 0 else { status = "电视连接失败，请检查网络与电视授权"; return }
            let state = try await runner(configuration.executablePath, ["-s", configuration.address, "get-state"])
            guard generation == ticket else { return }
            isConnected = state.status == 0 && state.output.trimmingCharacters(in: .whitespacesAndNewlines) == "device"
            status = isConnected ? "电视已连接" : "电视尚未授权或离线，请在电视确认"
        } catch { if generation == ticket { status = "电视连接失败，请检查 adb 和网络" } }
    }

    func disconnect() {
        generation += 1; isConnected = false; isBusy = false
        configuration = nil; status = "电视控制已停用"; onChange?()
    }

    func perform(_ command: WristControlCommand) async -> WristControlReceipt {
        guard !isBusy, let configuration, let target, command.targetID == target.id,
              command.isValid(now: Int64(Date().timeIntervalSince1970 * 1_000)),
              let code = WristTVCommandPolicy.keyCode(command.action) else {
            return .init(id: command.id, accepted: false, detail: "电视不可用或操作不支持")
        }
        let ticket = generation; isBusy = true
        defer { if generation == ticket { isBusy = false } }
        do {
            let result = try await runner(configuration.executablePath, ["-s", configuration.address, "shell", "input", "keyevent", String(code)])
            guard generation == ticket else { return .init(id: command.id, accepted: false, detail: "设备已切换，结果未确认") }
            if result.status != 0 { isConnected = false; status = "电视连接中断，请重新连接"; onChange?() }
            return .init(id: command.id, accepted: result.status == 0,
                         detail: result.status == 0 ? "按键已提交电视；请以画面为准" : status)
        } catch {
            if generation == ticket { isConnected = false; status = "电视连接中断"; onChange?() }
            return .init(id: command.id, accepted: false, detail: "电视结果未确认，不会重发")
        }
    }
}
