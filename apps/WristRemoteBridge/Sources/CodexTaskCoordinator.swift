import Foundation

enum CodexHookEvent: String, Codable, Hashable, Sendable {
    case userPromptSubmit = "UserPromptSubmit"
    case stop = "Stop"
}

enum CodexTaskStatus: String, Codable, Sendable {
    case running
    case completed
}

struct CodexHookPayload: Equatable, Sendable {
    let sessionID: String
    let turnID: String
    let event: CodexHookEvent
    let cwd: String
    let prompt: String?
    let lastAssistantMessage: String?

    static func decode(from data: Data) throws -> CodexHookPayload {
        let wire: WirePayload
        do {
            wire = try JSONDecoder().decode(WirePayload.self, from: data)
        } catch {
            throw CodexHookPayloadError.invalidJSON
        }

        guard let event = CodexHookEvent(rawValue: wire.hookEventName) else {
            throw CodexHookPayloadError.unsupportedEvent
        }
        let sessionID = try validatedIdentifier(wire.sessionID, field: "session_id")
        let turnID = try validatedIdentifier(wire.turnID, field: "turn_id")
        let cwd = try canonicalDirectoryPath(wire.cwd)

        return CodexHookPayload(
            sessionID: sessionID,
            turnID: turnID,
            event: event,
            cwd: cwd,
            prompt: wire.prompt,
            lastAssistantMessage: wire.lastAssistantMessage
        )
    }

    static func canonicalDirectoryPath(_ rawPath: String) throws -> String {
        guard !rawPath.isEmpty,
              rawPath.utf8.count <= 4_096,
              !rawPath.contains("\0"),
              (rawPath as NSString).isAbsolutePath
        else {
            throw CodexHookPayloadError.invalidField("cwd")
        }
        return URL(fileURLWithPath: rawPath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    private static func validatedIdentifier(_ rawValue: String, field: String) throws -> String {
        guard !rawValue.isEmpty,
              rawValue.utf8.count <= 128,
              rawValue == rawValue.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.contains("\0"),
              !rawValue.hasPrefix("-"),
              !rawValue.unicodeScalars.contains(where: {
                  CharacterSet.whitespacesAndNewlines.contains($0)
              })
        else {
            throw CodexHookPayloadError.invalidField(field)
        }
        return rawValue
    }

    private struct WirePayload: Decodable {
        let sessionID: String
        let turnID: String
        let hookEventName: String
        let cwd: String
        let prompt: String?
        let lastAssistantMessage: String?

        enum CodingKeys: String, CodingKey {
            case sessionID = "session_id"
            case turnID = "turn_id"
            case hookEventName = "hook_event_name"
            case cwd
            case prompt
            case lastAssistantMessage = "last_assistant_message"
        }
    }
}

enum CodexHookPayloadError: Error, Equatable, LocalizedError {
    case invalidJSON
    case unsupportedEvent
    case invalidField(String)

    var errorDescription: String? {
        switch self {
        case .invalidJSON:
            return "Hook payload is not valid JSON."
        case .unsupportedEvent:
            return "Hook event must be UserPromptSubmit or Stop."
        case let .invalidField(field):
            return "Hook payload has an invalid \(field) field."
        }
    }
}

struct CodexTaskSnapshot: Codable, Equatable, Sendable {
    let threadID: String
    let turnID: String
    let cwd: String
    let status: CodexTaskStatus
    let prompt: String?
    let lastAssistantMessage: String?
    let summary: String
    let updatedAt: Date
    let revision: Int64

    var sessionID: String { threadID }
}

enum CodexHookIngestDisposition: String, Codable, Sendable {
    case accepted
    case duplicate
    case ignoredOutOfOrder
}

struct CodexHookIngestResult: Equatable, Sendable {
    let disposition: CodexHookIngestDisposition
    let snapshot: CodexTaskSnapshot

    var didChange: Bool { disposition == .accepted }
}

enum CodexTaskSummary {
    static let characterLimit = 160

    static func make(from rawText: String?, fallback: String) -> String {
        let normalized = normalizedText(rawText)
        let source = normalized.isEmpty ? fallback : normalized
        guard source.count > characterLimit else { return source }
        return String(source.prefix(characterLimit - 1)) + "…"
    }

    private static func normalizedText(_ rawText: String?) -> String {
        guard let rawText else { return "" }
        return rawText
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}

actor CodexTaskCoordinator {
    typealias SnapshotObserver = @Sendable (CodexTaskSnapshot) -> Void

    private struct EventKey: Hashable {
        let sessionID: String
        let turnID: String
        let event: CodexHookEvent
    }

    private struct TaskKey: Hashable {
        let sessionID: String
        let turnID: String
    }

    private let now: @Sendable () -> Date
    private var observer: SnapshotObserver?
    private var snapshots: [TaskKey: CodexTaskSnapshot] = [:]
    private var currentTaskKey: TaskKey?
    private var rememberedEvents: Set<EventKey> = []
    private var lastIssuedRevision: Int64?
    private var pinnedThreadID: String?

    init(
        now: @escaping @Sendable () -> Date = { Date() },
        pinnedThreadID: String? = nil
    ) {
        self.now = now
        self.pinnedThreadID = pinnedThreadID.flatMap {
            CodexThreadIdentifier.isValid($0) ? $0 : nil
        }
    }

    func setSnapshotObserver(_ observer: SnapshotObserver?) {
        self.observer = observer
    }

    func ingest(jsonData: Data) throws -> CodexHookIngestResult {
        try ingest(CodexHookPayload.decode(from: jsonData))
    }

    func ingest(_ payload: CodexHookPayload) -> CodexHookIngestResult {
        let eventKey = EventKey(
            sessionID: payload.sessionID,
            turnID: payload.turnID,
            event: payload.event
        )
        let taskKey = TaskKey(sessionID: payload.sessionID, turnID: payload.turnID)

        if rememberedEvents.contains(eventKey), let existing = snapshots[taskKey] {
            return CodexHookIngestResult(disposition: .duplicate, snapshot: existing)
        }
        rememberedEvents.insert(eventKey)

        let previous = snapshots[taskKey]
        if payload.event == .userPromptSubmit,
           let previous,
           previous.status == .completed {
            return CodexHookIngestResult(
                disposition: .ignoredOutOfOrder,
                snapshot: previous
            )
        }

        let eventDate = now()
        let snapshot = makeSnapshot(
            for: payload,
            previous: previous,
            updatedAt: eventDate,
            revision: nextRevision(for: eventDate)
        )
        snapshots[taskKey] = snapshot

        if pinnedThreadID == nil {
            pinnedThreadID = payload.sessionID
        }
        let isPinnedThread = payload.sessionID == pinnedThreadID
        let shouldBecomeCurrent: Bool
        switch payload.event {
        case .userPromptSubmit:
            shouldBecomeCurrent = isPinnedThread
        case .stop:
            shouldBecomeCurrent = isPinnedThread
                && (currentTaskKey == nil || currentTaskKey == taskKey)
        }
        if shouldBecomeCurrent {
            currentTaskKey = taskKey
            observer?(snapshot)
        }
        return CodexHookIngestResult(disposition: .accepted, snapshot: snapshot)
    }

    func currentSnapshot() -> CodexTaskSnapshot? {
        guard let currentTaskKey else { return nil }
        return snapshots[currentTaskKey]
    }

    func currentPinnedThreadID() -> String? {
        pinnedThreadID
    }

    /// Switching is deliberately two-step: after the user asks to switch,
    /// the next root Codex hook becomes the new pinned conversation. Existing
    /// background sessions can no longer take over implicitly.
    func followNextThread() {
        pinnedThreadID = nil
        currentTaskKey = nil
    }

    func snapshot(threadID: String, turnID: String) -> CodexTaskSnapshot? {
        snapshots[TaskKey(sessionID: threadID, turnID: turnID)]
    }

    func newestSnapshot(
        threadID: String,
        prompt: String,
        afterRevision: Int64
    ) -> CodexTaskSnapshot? {
        let expectedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return snapshots.values
            .filter { snapshot in
                snapshot.threadID == threadID
                    && snapshot.revision > afterRevision
                    && snapshot.prompt?.trimmingCharacters(in: .whitespacesAndNewlines)
                        == expectedPrompt
            }
            .max { $0.revision < $1.revision }
    }

    func exactCurrentCompletedSnapshot(
        threadID: String,
        turnID: String,
        cwd: String
    ) -> CodexTaskSnapshot? {
        guard let canonicalCWD = try? CodexHookPayload.canonicalDirectoryPath(cwd),
              let snapshot = currentSnapshot(),
              snapshot.status == .completed,
              snapshot.threadID == threadID,
              snapshot.turnID == turnID,
              snapshot.cwd == canonicalCWD
        else { return nil }
        return snapshot
    }

    private func makeSnapshot(
        for payload: CodexHookPayload,
        previous: CodexTaskSnapshot?,
        updatedAt: Date,
        revision: Int64
    ) -> CodexTaskSnapshot {
        let status: CodexTaskStatus = payload.event == .stop ? .completed : .running
        let prompt = payload.prompt ?? previous?.prompt
        let lastMessage = payload.lastAssistantMessage ?? previous?.lastAssistantMessage
        let summarySource = status == .completed ? lastMessage : prompt
        let fallback = status == .completed ? "Codex 任务已完成" : "Codex 正在执行任务"
        return CodexTaskSnapshot(
            threadID: payload.sessionID,
            turnID: payload.turnID,
            cwd: payload.cwd,
            status: status,
            prompt: prompt,
            lastAssistantMessage: lastMessage,
            summary: CodexTaskSummary.make(from: summarySource, fallback: fallback),
            updatedAt: updatedAt,
            revision: revision
        )
    }

    private func nextRevision(for date: Date) -> Int64 {
        let previousRevision = lastIssuedRevision ?? revisionBase(for: date)
        precondition(previousRevision < Int64.max, "Codex task revision overflow")
        let revision = previousRevision + 1
        lastIssuedRevision = revision
        return revision
    }

    private func revisionBase(for date: Date) -> Int64 {
        let rawMilliseconds = (date.timeIntervalSince1970 * 1_000).rounded(.down)
        guard rawMilliseconds.isFinite else { return 0 }

        let maximumMilliseconds = Int64.max / 1_000
        let minimumMilliseconds = Int64.min / 1_000
        if rawMilliseconds >= Double(maximumMilliseconds) {
            return maximumMilliseconds * 1_000
        }
        if rawMilliseconds <= Double(minimumMilliseconds) {
            return minimumMilliseconds * 1_000
        }
        return Int64(rawMilliseconds) * 1_000
    }
}
