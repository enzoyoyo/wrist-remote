import Foundation

/// Discrete, bounded operations. No shell text, held keys, or gesture replay.
struct WristControlCommand: Codable, Equatable, Sendable {
    enum Action: String, Codable, CaseIterable, Sendable {
        case pointer, click, secondaryClick, scroll
        case volumeUp, volumeDown, mute, playPause, previousTrack, nextTrack
        case previousPage, nextPage, presentationStart, presentationStop
        case up, down, left, right, select, back, home
        case sessionPlayPause, sessionFaster, sessionSlower
    }
    let id: UUID
    let targetID: String
    let action: Action
    let x: Double
    let y: Double
    let issuedAt: Int64

    init(id: UUID = UUID(), targetID: String = "mac", action: Action,
         x: Double = 0, y: Double = 0,
         issuedAt: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)) {
        self.id = id; self.targetID = targetID; self.action = action
        self.x = x; self.y = y; self.issuedAt = issuedAt
    }

    func isValid(now: Int64) -> Bool {
        guard !targetID.isEmpty, targetID.utf8.count <= 80,
              targetID.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "-:".unicodeScalars.contains($0) }),
              x.isFinite, y.isFinite, abs(x) <= 400, abs(y) <= 400,
              issuedAt > 0, issuedAt <= now, now - issuedAt <= 1_500
        else { return false }
        return action == .pointer || action == .scroll || (x == 0 && y == 0)
    }
}

struct WristControlTarget: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case mac, television, readingSession }
    let id: String
    let name: String
    let kind: Kind
    let detail: String
    let actions: [WristControlCommand.Action]
}

struct WristControlReceipt: Codable, Equatable, Sendable {
    let id: UUID
    let accepted: Bool
    let detail: String
}

/// Coalesce only fresh pointer deltas while one request is in flight.
struct WristPointerBuffer {
    private var x = 0.0
    private var y = 0.0
    private var lastUpdate: Date?

    mutating func add(x: Double, y: Double, now: Date = Date()) {
        guard x.isFinite, y.isFinite else { return }
        if let lastUpdate, now < lastUpdate || now.timeIntervalSince(lastUpdate) > 0.3 { clear() }
        self.x = min(400, max(-400, self.x + x))
        self.y = min(400, max(-400, self.y + y))
        lastUpdate = now
    }

    mutating func take(now: Date = Date()) -> (Double, Double)? {
        defer { clear() }
        guard let lastUpdate, now >= lastUpdate,
              now.timeIntervalSince(lastUpdate) <= 0.3,
              x != 0 || y != 0 else { return nil }
        return (x, y)
    }

    mutating func clear() { x = 0; y = 0; lastUpdate = nil }
}

enum WristControlFlightPolicy {
    static func mayStart(action: WristControlCommand.Action, direct: Bool, inFlight: Int, clickWaiting: Bool) -> Bool {
        guard inFlight >= 0 else { return false }
        if action == .pointer { return !clickWaiting && inFlight < (direct ? 1 : 3) }
        return inFlight == 0
    }
}

struct WristControlReplayGate {
    private var seen: [UUID: Int64] = [:]
    mutating func accept(_ command: WristControlCommand, now: Int64) -> Bool {
        seen = seen.filter { now < $0.value || now - $0.value < 10_000 }
        guard command.isValid(now: now), seen[command.id] == nil, seen.count < 512 else { return false }
        seen[command.id] = now
        return true
    }
}
