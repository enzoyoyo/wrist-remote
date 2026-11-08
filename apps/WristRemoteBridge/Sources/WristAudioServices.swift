import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

@MainActor
final class WristRecordingLibrary {
    enum RecordingError: LocalizedError {
        case busy, invalidSession, empty, storageUnavailable
        var errorDescription: String? {
            switch self {
            case .busy: "已有录音正在保存"
            case .invalidSession: "录音会话已变化"
            case .empty: "没有录到声音"
            case .storageUnavailable: "无法保存 AAC 录音"
            }
        }
    }
    static let sampleRate = 16_000
    static let bitRate = 16_000
    private static let maximumSamples = sampleRate * 120
    let directory: URL
    private var activeID: UUID?
    private var activeURL: URL?
    private var file: AVAudioFile?
    private var sampleCount = 0
    private let format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 1)!

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "dev.wristremote.bridge")
            .appendingPathComponent("Recordings", isDirectory: true)
    }

    /// Encode each received packet directly. No uncompressed file is created.
    func start(id: UUID) throws -> Bool {
        guard activeID == nil else { throw RecordingError.busy }
        let manager = FileManager.default
        let url = directory.appendingPathComponent(".Wrist-\(id.uuidString).partial.m4a")
        var createdFile = false
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let values = try directory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard values.isDirectory == true, values.isSymbolicLink != true,
                  !manager.fileExists(atPath: url.path) else { throw RecordingError.storageUnavailable }
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: Double(Self.sampleRate),
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: Self.bitRate,
                AVEncoderBitRateStrategyKey: AVAudioBitRateStrategy_Constant,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
            file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            createdFile = true
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            activeID = id; activeURL = url; sampleCount = 0
            return true
        } catch {
            file = nil
            if createdFile { try? manager.removeItem(at: url) }
            throw RecordingError.storageUnavailable
        }
    }

    func append(_ samples: [Int16], id: UUID) -> Bool {
        guard activeID == id, let file, !samples.isEmpty,
              samples.count <= Self.maximumSamples - sampleCount,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?.pointee else { return false }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for (index, sample) in samples.enumerated() { channel[index] = Float(sample) / 32768 }
        do { try file.write(from: buffer); sampleCount += samples.count; return true }
        catch { cancel(id: id); return false }
    }

    func finish(id: UUID) throws -> URL {
        guard activeID == id, let source = activeURL else { throw RecordingError.invalidSession }
        file = nil // Finalizes AAC frames and the M4A container before publication.
        activeID = nil; activeURL = nil
        guard sampleCount > 0 else {
            try? FileManager.default.removeItem(at: source)
            throw RecordingError.empty
        }
        let formatter = DateFormatter(); formatter.dateFormat = "yyyyMMdd-HHmmss"
        let destination = directory.appendingPathComponent("Wrist-\(formatter.string(from: Date()))-\(id.uuidString.prefix(8)).m4a")
        do {
            try FileManager.default.moveItem(at: source, to: destination)
            return destination
        } catch {
            // Preserve the already compressed file for recovery if the rename fails.
            throw RecordingError.storageUnavailable
        }
    }

    func cancel(id: UUID) {
        guard activeID == id else { return }
        file = nil
        if let activeURL { try? FileManager.default.removeItem(at: activeURL) }
        activeID = nil; activeURL = nil; sampleCount = 0
    }
}

struct WristAudioOutputDevice: Equatable, Identifiable {
    let id: String
    let name: String
    let deviceID: AudioDeviceID
    let hasInput: Bool

    /// BlackHole 2ch carries the existing remote's microphone chain, so Watch
    /// audio must never be written into it, whatever the saved selection says.
    var isProtectedSharedDevice: Bool { id == "BlackHole2ch_UID" || name == "BlackHole 2ch" }

    /// Devices a user may pick for Watch audio; protected shared devices are hidden.
    static func selectableOutputs() -> [Self] { virtualOutputs().filter { !$0.isProtectedSharedDevice && $0.hasInput } }

    static func virtualOutputs() -> [Self] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var transportAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var transport: UInt32 = 0; var transportSize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(id, &transportAddress, 0, nil, &transportSize, &transport) == noErr,
                  transport == kAudioDeviceTransportTypeVirtual else { return nil }
            var streamsAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            var streamsSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streamsAddress, 0, nil, &streamsSize) == noErr, streamsSize > 0,
                  let uid = stringProperty(id, selector: kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(id, selector: kAudioObjectPropertyName) else { return nil }
            var inputAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var inputSize: UInt32 = 0
            let hasInput = AudioObjectGetPropertyDataSize(id, &inputAddress, 0, nil, &inputSize) == noErr && inputSize > 0
            return .init(id: uid, name: name, deviceID: id, hasInput: hasInput)
        }
    }

    private static func stringProperty(_ id: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let result = UnsafeMutablePointer<CFString?>.allocate(capacity: 1)
        result.initialize(to: nil)
        defer { result.deinitialize(count: 1); result.deallocate() }
        var size = UInt32(MemoryLayout<CFString?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, result) == noErr else { return nil }
        return result.pointee as String?
    }
}

/// Bounds latency instead of playing old speech after network congestion.
final class WristAudioBacklog: @unchecked Sendable {
    private let lock = NSLock()
    private var frames = 0
    private var generation = UUID()
    let maximumFrames: Int
    init(maximumFrames: Int = 8_000) { self.maximumFrames = maximumFrames }
    func reserve(_ count: Int) -> UUID? {
        lock.lock(); defer { lock.unlock() }
        guard count > 0, count <= maximumFrames, frames <= maximumFrames - count else { return nil }
        frames += count; return generation
    }
    func complete(_ count: Int, generation: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard self.generation == generation else { return }
        frames = max(0, frames - count)
    }
    var pendingFrames: Int { lock.lock(); defer { lock.unlock() }; return frames }
    func reset() { lock.lock(); defer { lock.unlock() }; frames = 0; generation = UUID() }
}

@MainActor
final class WristLiveAudioOutput {
    enum OutputError: LocalizedError {
        case missingDevice, unavailable, routeChanged, protectedDevice
        var errorDescription: String? {
            switch self {
            case .protectedDevice: "BlackHole 2ch 由现有遥控使用，已拒绝输出；请选择其他独立虚拟设备"
            case .missingDevice: "请先在 Mac 选择虚拟音频输出设备"
            case .unavailable: "虚拟音频输出无法启动"
            case .routeChanged: "音频设备已变化，无线麦已停止"
            }
        }
    }
    var onFailure: ((String) -> Void)?
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private let backlog = WristAudioBacklog()
    private var configurationObserver: NSObjectProtocol?
    private var outputUID: String?
    private var idleTask: Task<Void, Never>?
    private var lastPacket = Date.distantPast
    private var totalSamples = 0

    func start(deviceUID: String) throws {
        stop()
        guard let device = WristAudioOutputDevice.virtualOutputs().first(where: { $0.id == deviceUID }) else { throw OutputError.missingDevice }
        guard !device.isProtectedSharedDevice else { throw OutputError.protectedDevice }
        guard device.hasInput else { throw OutputError.missingDevice }
        let engine = AVAudioEngine()
        guard let unit = engine.outputNode.audioUnit else { throw OutputError.unavailable }
        var id = device.deviceID
        guard AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr else { throw OutputError.unavailable }
        let player = AVAudioPlayerNode()
        engine.attach(player)
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.prepare()
        do { try engine.start() } catch { engine.stop(); throw OutputError.unavailable }
        player.play()
        self.engine = engine; self.player = player; outputUID = deviceUID
        lastPacket = Date(); totalSamples = 0
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.fail(OutputError.routeChanged.localizedDescription) }
        }
        idleTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled, self.engine != nil else { return }
                if Date().timeIntervalSince(self.lastPacket) > 3 {
                    self.fail("三秒未收到音频，无线麦已停止"); return
                }
                if !WristAudioOutputDevice.virtualOutputs().contains(where: { $0.id == self.outputUID }) {
                    self.fail(OutputError.routeChanged.localizedDescription); return
                }
            }
        }
    }

    func append(_ samples: [Int16]) -> Bool {
        guard let player, let engine, engine.isRunning,
              totalSamples <= 16_000 * 120 - samples.count,
              let ticket = backlog.reserve(samples.count),
              let buffer = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?.pointee else { return false }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for (index, sample) in samples.enumerated() { channel[index] = Float(sample) / 32768 }
        let count = samples.count; let budget = backlog
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in budget.complete(count, generation: ticket) }
        totalSamples += count; lastPacket = Date()
        return true
    }

    /// Wait for queued samples to reach the selected audio device before closing it.
    func drain() async -> Bool {
        let deadline = Date().addingTimeInterval(1.5)
        while backlog.pendingFrames > 0 && Date() < deadline && !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return !Task.isCancelled && backlog.pendingFrames == 0 && engine?.isRunning == true
    }

    func stop() {
        idleTask?.cancel(); idleTask = nil
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        player?.stop(); engine?.stop(); player = nil; engine = nil; outputUID = nil
        backlog.reset()
    }

    private func fail(_ detail: String) { guard engine != nil else { return }; stop(); onFailure?(detail) }
}


enum WristNativeDictationError: LocalizedError {
    case configuration, shortcut
    var errorDescription: String? {
        switch self {
        case .configuration: "请先配置独立虚拟音频设备与快捷键，并将 Codex 放在前台"
        case .shortcut: "无法发送快捷键，请检查辅助功能权限"
        }
    }
}

struct WristNativeDictationPolicy {
    // The toggle shortcut does not acknowledge Codex listening state. Keep the
    // experimental path disabled until safe start and stop are verifiable.
    static let releaseEnabled = false
    static func permits(device: WristAudioOutputDevice?, wirelessOutputUID: String, shortcutConfigured: Bool, codexFrontmost: Bool) -> Bool {
        guard releaseEnabled, let device, shortcutConfigured, codexFrontmost, !device.id.isEmpty,
              device.id != wirelessOutputUID, device.hasInput, !device.isProtectedSharedDevice else { return false }
        return true
    }
}
