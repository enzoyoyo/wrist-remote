import CryptoKit
import Foundation

/// A durable, privacy-minimizing idempotency ledger. It stores only a SHA-256
/// request fingerprint and queue receipt metadata, never the voice transcript.
actor CodexSubmissionLedger {
    enum BeginResult: Equatable, Sendable {
        case new
        case unknownAfterSideEffect
        case completed(CodexReplyResult)
    }

    private enum Stage: String, Codable {
        case prepared
        case queued
        case delivered
    }

    private struct Record: Codable {
        let fingerprint: String
        var stage: Stage
        var threadID: String?
        var queuedMessageID: UUID?
        var observedTurnID: String?
    }

    private let fileURL: URL?
    private var records: [UUID: Record] = [:]
    private var loadFailed = false

    /// In-memory by default so unit tests never write production state.
    init(fileURL: URL? = nil) {
        self.fileURL = fileURL
        guard let fileURL,
              FileManager.default.fileExists(atPath: fileURL.path)
        else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            records = try JSONDecoder().decode([UUID: Record].self, from: data)
        } catch {
            loadFailed = true
        }
    }

    static func persistentDefault() -> CodexSubmissionLedger {
        let root = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        let applicationIdentifier = Bundle.main.bundleIdentifier ?? "dev.wristremote.bridge"
        return CodexSubmissionLedger(fileURL: root
            .appendingPathComponent(applicationIdentifier, isDirectory: true)
            .appendingPathComponent("CodexSubmissionLedger.json", isDirectory: false))
    }

    func begin(_ request: CodexReplyRequest) throws -> BeginResult {
        guard !loadFailed else {
            throw CodexReplyRunnerError.idempotencyLedgerUnavailable
        }
        let fingerprint = Self.fingerprint(request)
        if let existing = records[request.submissionID] {
            guard existing.fingerprint == fingerprint else {
                throw CodexReplyRunnerError.submissionIDReuseMismatch
            }
            switch existing.stage {
            case .prepared:
                return .unknownAfterSideEffect
            case .queued, .delivered:
                guard let threadID = existing.threadID,
                      let queuedMessageID = existing.queuedMessageID
                else { throw CodexReplyRunnerError.idempotencyLedgerUnavailable }
                return .completed(CodexReplyResult(
                    submissionID: request.submissionID,
                    threadID: threadID,
                    queuedMessageID: queuedMessageID,
                    observedTurnID: existing.observedTurnID,
                    state: existing.stage == .delivered ? .delivered : .queued
                ))
            }
        }

        records[request.submissionID] = Record(
            fingerprint: fingerprint,
            stage: .prepared,
            threadID: nil,
            queuedMessageID: nil,
            observedTurnID: nil
        )
        do {
            try persist()
        } catch {
            records.removeValue(forKey: request.submissionID)
            throw CodexReplyRunnerError.idempotencyLedgerUnavailable
        }
        return .new
    }

    func complete(_ result: CodexReplyResult, request: CodexReplyRequest) throws {
        guard !loadFailed,
              let existing = records[request.submissionID],
              existing.fingerprint == Self.fingerprint(request)
        else { throw CodexReplyRunnerError.idempotencyLedgerUnavailable }
        records[request.submissionID] = Record(
            fingerprint: existing.fingerprint,
            stage: result.state == .delivered ? .delivered : .queued,
            threadID: result.threadID,
            queuedMessageID: result.queuedMessageID,
            observedTurnID: result.observedTurnID
        )
        try persist()
    }

    private func persist() throws {
        guard let fileURL else { return }
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(records)
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

    private static func fingerprint(_ request: CodexReplyRequest) -> String {
        let canonical = [
            request.threadID,
            request.turnID,
            request.cwd,
            request.transcript,
            request.userConfirmed ? "1" : "0",
        ].joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
