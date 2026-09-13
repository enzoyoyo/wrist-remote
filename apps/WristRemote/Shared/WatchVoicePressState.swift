import Foundation

/// One finger contact owns one recording. A delayed hold callback from an older
/// contact cannot start a new capture, and cancellation lasts until lift-off.
struct WatchVoicePressState: Equatable {
    enum Phase: Equatable { case idle, holding, recording, cancelled }
    private(set) var phase: Phase = .idle
    private(set) var generation: UInt64 = 0

    mutating func begin() -> UInt64? {
        guard phase == .idle else { return nil }
        generation &+= 1
        phase = .holding
        return generation
    }

    mutating func recognize(generation: UInt64, canStart: Bool) -> Bool {
        guard self.generation == generation, phase == .holding, canStart else { return false }
        phase = .recording
        return true
    }

    mutating func move(distance: Double) -> Bool {
        let threshold = phase == .holding ? 18.0 : 34.0
        guard phase == .holding || phase == .recording,
              !distance.isFinite || distance > threshold else { return false }
        let hadRecording = phase == .recording
        phase = .cancelled
        generation &+= 1
        return hadRecording
    }

    mutating func end() -> Bool {
        let shouldFinish = phase == .recording
        reset()
        return shouldFinish
    }

    mutating func reset() {
        generation &+= 1
        phase = .idle
    }
}
