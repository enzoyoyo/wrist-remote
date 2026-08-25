import AVFoundation
import Foundation

final class WatchAudioCapture {
    enum CaptureError: Error {
        case permissionDenied
        case inputUnavailable
    }

    private let engine = AVAudioEngine()
    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!
    private let converterLock = NSLock()
    private let packetLock = NSLock()
    private var converter: AVAudioConverter?
    private var packetHandler: ((Data) -> Void)?
    private var pendingSamples: [Int16] = []
    private var tapInstalled = false
    private(set) var isRunning = false

    @MainActor
    func requestPermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await AVAudioApplication.requestRecordPermission()
        @unknown default:
            return false
        }
    }

    @MainActor
    func start(onPacket: @escaping (Data) -> Void) throws {
        guard !isRunning else { return }
        guard AVAudioApplication.shared.recordPermission == .granted else {
            throw CaptureError.permissionDenied
        }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement)
            try session.setActive(true)
            resetPipeline()
            setPacketHandler(onPacket)
            try preparePipeline()
            engine.prepare()
            try engine.start()
            isRunning = true
        } catch {
            clearPacketState()
            resetPipeline()
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw error
        }
    }

    @MainActor
    func stop() -> Data? {
        resetPipeline()
        let finalPacket = takePaddedFinalPacket()
        clearPacketState()
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
        return finalPacket
    }

    @MainActor
    private func preparePipeline() throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0,
              inputFormat.channelCount > 0,
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else {
            throw CaptureError.inputUnavailable
        }

        converterLock.lock()
        self.converter = converter
        converterLock.unlock()

        input.installTap(onBus: 0, bufferSize: 480, format: inputFormat) { [weak self] buffer, _ in
            self?.convertAndPublish(buffer)
        }
        tapInstalled = true
    }

    @MainActor
    private func resetPipeline() {
        engine.stop()
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.reset()

        converterLock.lock()
        converter = nil
        converterLock.unlock()
        isRunning = false
    }

    private func convertAndPublish(_ inputBuffer: AVAudioPCMBuffer) {
        converterLock.lock()
        guard let converter else {
            converterLock.unlock()
            return
        }

        let ratio = outputFormat.sampleRate / inputBuffer.format.sampleRate
        let capacity = max(
            1,
            AVAudioFrameCount(ceil(Double(inputBuffer.frameLength) * ratio))
        )
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: capacity
        ) else {
            converterLock.unlock()
            return
        }

        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
            guard !suppliedInput else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return inputBuffer
        }

        let samples: [Int16]?
        if status != .error,
           conversionError == nil,
           outputBuffer.frameLength > 0,
           let channel = outputBuffer.int16ChannelData?[0] {
            samples = Array(UnsafeBufferPointer(
                start: channel,
                count: Int(outputBuffer.frameLength)
            ))
        } else {
            samples = nil
        }
        if let samples {
            appendAndPublish(samples)
        }
        converterLock.unlock()
    }

    private func appendAndPublish(_ samples: [Int16]) {
        packetLock.lock()
        pendingSamples.append(contentsOf: samples)
        let handler = packetHandler
        var packets: [Data] = []
        while pendingSamples.count >= WatchRemoteProtocol.audioPacketSampleCount {
            let packetSamples = Array(
                pendingSamples.prefix(WatchRemoteProtocol.audioPacketSampleCount)
            )
            pendingSamples.removeFirst(WatchRemoteProtocol.audioPacketSampleCount)
            packets.append(WatchRemoteProtocol.pcm16Data(samples: packetSamples))
        }
        packetLock.unlock()

        guard let handler else { return }
        for packet in packets {
            handler(packet)
        }
    }

    private func setPacketHandler(_ handler: @escaping (Data) -> Void) {
        packetLock.lock()
        packetHandler = handler
        pendingSamples.removeAll(keepingCapacity: true)
        packetLock.unlock()
    }

    private func clearPacketState() {
        packetLock.lock()
        packetHandler = nil
        pendingSamples.removeAll(keepingCapacity: false)
        packetLock.unlock()
    }

    private func takePaddedFinalPacket() -> Data? {
        packetLock.lock()
        defer {
            pendingSamples.removeAll(keepingCapacity: false)
            packetLock.unlock()
        }
        guard !pendingSamples.isEmpty else { return nil }
        if pendingSamples.count < WatchRemoteProtocol.audioPacketSampleCount {
            pendingSamples.append(contentsOf: repeatElement(
                0,
                count: WatchRemoteProtocol.audioPacketSampleCount - pendingSamples.count
            ))
        }
        return WatchRemoteProtocol.pcm16Data(samples: Array(
            pendingSamples.prefix(WatchRemoteProtocol.audioPacketSampleCount)
        ))
    }
}
