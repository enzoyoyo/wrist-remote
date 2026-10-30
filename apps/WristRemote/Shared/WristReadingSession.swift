import Foundation

struct WristReadingSessionState: Codable, Equatable, Sendable {
    let id: UUID
    var title: String
    var page: Int
    var pageCount: Int
    var isPlaying: Bool
    var speed: Double

    var targetID: String { "reading-" + id.uuidString }
    var isValid: Bool {
        !title.isEmpty && title.count <= 80 && !title.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            && (1 ... 1_000).contains(pageCount) && (0 ..< pageCount).contains(page)
            && speed.isFinite && (0.5 ... 2).contains(speed)
    }
    static let actions: [WristControlCommand.Action] = [.previousPage, .nextPage, .sessionPlayPause, .sessionFaster, .sessionSlower]
    var target: WristControlTarget {
        .init(id: targetID, name: title, kind: .readingSession,
              detail: "第 \(page + 1) / \(pageCount) 段 · \(isPlaying ? "播放中" : "已暂停")",
              actions: Self.actions)
    }
    mutating func apply(_ action: WristControlCommand.Action) -> Bool {
        guard isValid else { return false }
        switch action {
        case .previousPage: page = max(0, page - 1)
        case .nextPage:
            page = min(pageCount - 1, page + 1)
            if page == pageCount - 1 { isPlaying = false }
        case .sessionPlayPause:
            if page == pageCount - 1 { isPlaying = false } else { isPlaying.toggle() }
        case .sessionFaster: speed = min(2, ((speed + 0.1) * 10).rounded() / 10)
        case .sessionSlower: speed = max(0.5, ((speed - 0.1) * 10).rounded() / 10)
        default: return false
        }
        return true
    }
}
