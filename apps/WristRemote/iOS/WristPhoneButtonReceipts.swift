import Foundation

struct WristPhoneButtonReceipt: Equatable {
    enum Outcome: Equatable {
        case executed
        case rejected
        case unconfirmed
    }

    let requestID: UUID
    let outcome: Outcome
    let detail: String

    var accepted: Bool { outcome == .executed }
}

/// Exactly one terminal receipt for each locally issued request. Late, unknown,
/// malformed and duplicate replies never become an "executed" UI state.
struct WristPhoneButtonReceiptLedger {
    static let timeoutMilliseconds: Int64 = 5_000
    private var pending: [UUID: Int64] = [:]

    var pendingIDs: [UUID] { Array(pending.keys) }

    mutating func begin(id: UUID, nowEpochMilliseconds: Int64) -> Bool {
        guard pending[id] == nil, pending.count < 32, nowEpochMilliseconds > 0 else {
            return false
        }
        pending[id] = nowEpochMilliseconds
        return true
    }

    mutating func resolve(
        _ message: WristBridgeWireMessage,
        nowEpochMilliseconds: Int64
    ) -> WristPhoneButtonReceipt? {
        guard message.type == "buttonTriggerResult",
              let rawID = message.requestID, let id = UUID(uuidString: rawID),
              id.uuidString == rawID,
              let issued = pending[id], let accepted = message.accepted,
              nowEpochMilliseconds >= issued
        else { return nil }
        if nowEpochMilliseconds - issued >= Self.timeoutMilliseconds {
            return expire(id: id, nowEpochMilliseconds: nowEpochMilliseconds)
        }
        pending.removeValue(forKey: id)
        let suppliedDetail = message.detail?.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = suppliedDetail.flatMap { $0.isEmpty ? nil : String($0.prefix(240)) }
        return WristPhoneButtonReceipt(
            requestID: id,
            outcome: accepted ? .executed : .rejected,
            detail: detail ?? (accepted ? "Mac 已执行" : "Mac 未执行此操作")
        )
    }

    mutating func expire(id: UUID, nowEpochMilliseconds: Int64) -> WristPhoneButtonReceipt? {
        guard let issued = pending[id], nowEpochMilliseconds >= issued,
              nowEpochMilliseconds - issued >= Self.timeoutMilliseconds
        else { return nil }
        pending.removeValue(forKey: id)
        return WristPhoneButtonReceipt(
            requestID: id, outcome: .unconfirmed,
            detail: "未收到 Mac 回执，执行结果未知。请查看 Mac；不会自动重发。"
        )
    }

    mutating func disconnect() -> [WristPhoneButtonReceipt] {
        let receipts = pending.keys.map {
            WristPhoneButtonReceipt(
                requestID: $0, outcome: .unconfirmed,
                detail: "连接已中断，执行结果未知。请查看 Mac；不会自动重发。"
            )
        }
        pending.removeAll()
        return receipts
    }
}
