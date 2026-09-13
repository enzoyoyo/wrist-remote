import AVFoundation
import CryptoKit
import Foundation

/// Mac-owned, private staging for original Watch audio destined for Codex.
///
/// The Watch still streams bounded PCM packets over the authenticated WristRemote
/// session. The Bridge writes those packets to one owner-only WAV file and queues
/// that file through Codex app-server's native `localAudio` input. No transcript,
/// audio path, or audio bytes are written to WristRemote logs or ledgers.
@MainActor
final class WatchCodexAudioInbox {
    struct FinalizedRecording: Equatable, Sendable {
        let streamID: UUID
        let fileURL: URL
        let sha256Hex: String
        let sampleCount: Int
    }

    enum InboxError: Error, Equatable, LocalizedError {
        case busy
        case invalidStream
        case emptyRecording
        case recordingTooLong
        case storageUnavailable

        var errorDescription: String? {
            switch self {
            case .busy:
                return "已有一段 Codex 语音正在处理。"
            case .invalidStream:
                return "Codex 语音会话已经变化。"
            case .emptyRecording:
                return "没有录到可发送的语音。"
            case .recordingTooLong:
                return "录音已达到两分钟上限。"
            case .storageUnavailable:
                return "无法安全保存这段 Codex 语音。"
            }
        }
    }

    static let sampleRate = 16_000
    static let maximumDurationSeconds = 120
    static let maximumSampleCount = sampleRate * maximumDurationSeconds
    static let staleRecordingLifetime: TimeInterval = 24 * 60 * 60

    private final class ActiveRecording {
        let streamID: UUID
        let fileURL: URL
        var file: AVAudioFile?
        var sampleCount = 0

        init(streamID: UUID, fileURL: URL, file: AVAudioFile) {
            self.streamID = streamID
            self.fileURL = fileURL
            self.file = file
        }
    }

    private let directoryURL: URL
    private let fileManager: FileManager
    private let format = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: Double(sampleRate),
        channels: 1,
        interleaved: true
    )!
    private var active: ActiveRecording?

    init(
        directoryURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        if let directoryURL {
            self.directoryURL = directoryURL.standardizedFileURL
        } else {
            let applicationSupport = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? fileManager.temporaryDirectory
            let applicationIdentifier = Bundle.main.bundleIdentifier
                ?? "dev.wristremote.bridge"
            self.directoryURL = applicationSupport
                .appendingPathComponent(applicationIdentifier, isDirectory: true)
                .appendingPathComponent("CodexAudioInbox", isDirectory: true)
        }
        purgeStaleRecordings()
    }

    var acceptsNewSession: Bool { active == nil }

    @discardableResult
    func start(streamID: UUID) throws -> Bool {
        guard active == nil else { throw InboxError.busy }
        var createdFileURL: URL?
        do {
            try createPrivateDirectoryIfNeeded()
            let fileURL = directoryURL.appendingPathComponent(
                "watch-\(streamID.uuidString.lowercased()).wav",
                isDirectory: false
            )
            guard !fileManager.fileExists(atPath: fileURL.path) else {
                throw InboxError.storageUnavailable
            }
            createdFileURL = fileURL
            let file = try AVAudioFile(
                forWriting: fileURL,
                settings: format.settings,
                commonFormat: .pcmFormatInt16,
                interleaved: true
            )
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: fileURL.path
            )
            active = ActiveRecording(streamID: streamID, fileURL: fileURL, file: file)
            return true
        } catch let error as InboxError {
            if let createdFileURL { try? fileManager.removeItem(at: createdFileURL) }
            throw error
        } catch {
            if let createdFileURL { try? fileManager.removeItem(at: createdFileURL) }
            throw InboxError.storageUnavailable
        }
    }

    @discardableResult
    func append(samples: [Int16], streamID: UUID) -> Bool {
        guard !samples.isEmpty,
              let active,
              active.streamID == streamID,
              let file = active.file,
              active.sampleCount <= Self.maximumSampleCount - samples.count,
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(samples.count)
              ),
              let channel = buffer.int16ChannelData?.pointee
        else { return false }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            guard let baseAddress = source.baseAddress else { return }
            channel.update(from: baseAddress, count: samples.count)
        }
        do {
            try file.write(from: buffer)
            active.sampleCount += samples.count
            return true
        } catch {
            return false
        }
    }

    func finish(streamID: UUID) throws -> FinalizedRecording {
        guard let recording = active, recording.streamID == streamID else {
            throw InboxError.invalidStream
        }
        active = nil
        recording.file = nil
        guard recording.sampleCount > 0 else {
            try? fileManager.removeItem(at: recording.fileURL)
            throw InboxError.emptyRecording
        }
        guard recording.sampleCount <= Self.maximumSampleCount else {
            try? fileManager.removeItem(at: recording.fileURL)
            throw InboxError.recordingTooLong
        }
        do {
            let values = try recording.fileURL.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
            ])
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  (values.fileSize ?? 0) > 44
            else { throw InboxError.storageUnavailable }
            let data = try Data(contentsOf: recording.fileURL, options: .mappedIfSafe)
            let digest = SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }
                .joined()
            return FinalizedRecording(
                streamID: streamID,
                fileURL: recording.fileURL,
                sha256Hex: digest,
                sampleCount: recording.sampleCount
            )
        } catch let error as InboxError {
            try? fileManager.removeItem(at: recording.fileURL)
            throw error
        } catch {
            try? fileManager.removeItem(at: recording.fileURL)
            throw InboxError.storageUnavailable
        }
    }

    func cancel(streamID: UUID? = nil) {
        guard let recording = active,
              streamID == nil || recording.streamID == streamID
        else { return }
        active = nil
        recording.file = nil
        try? fileManager.removeItem(at: recording.fileURL)
    }

    func remove(_ recording: FinalizedRecording) {
        guard recording.fileURL.deletingLastPathComponent().standardizedFileURL
                == directoryURL,
              recording.fileURL.lastPathComponent
                == "watch-\(recording.streamID.uuidString.lowercased()).wav"
        else { return }
        try? fileManager.removeItem(at: recording.fileURL)
    }

    private func createPrivateDirectoryIfNeeded() throws {
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: directoryURL.path
        )
    }

    private func purgeStaleRecordings(now: Date = Date()) {
        guard (try? createPrivateDirectoryIfNeeded()) != nil,
              let files = try? fileManager.contentsOfDirectory(
                  at: directoryURL,
                  includingPropertiesForKeys: [
                      .contentModificationDateKey,
                      .isRegularFileKey,
                      .isSymbolicLinkKey,
                  ],
                  options: [.skipsHiddenFiles]
              )
        else { return }
        for file in files {
            guard file.pathExtension.lowercased() == "wav",
                  file.lastPathComponent.hasPrefix("watch-"),
                  let values = try? file.resourceValues(forKeys: [
                      .contentModificationDateKey,
                      .isRegularFileKey,
                      .isSymbolicLinkKey,
                  ]),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let modified = values.contentModificationDate,
                  now.timeIntervalSince(modified) >= Self.staleRecordingLifetime
            else { continue }
            try? fileManager.removeItem(at: file)
        }
    }
}
