import Foundation
import XCTest
@testable import WristRemoteBridge

final class CodexTaskCoordinatorTests: XCTestCase {
    private let threadID = "11111111-1111-4111-8111-111111111111"
    private let turnID = "22222222-2222-4222-8222-222222222222"
    private let fixedDate = Date(timeIntervalSince1970: 1_787_500_000)

    func testDecodesDocumentedSnakeCaseFields() throws {
        var wire = basePayload
        wire["session_id"] = "thr_123"
        wire["turn_id"] = "turn_456"
        wire["hook_event_name"] = CodexHookEvent.stop.rawValue
        wire["prompt"] = "请完成测试"
        wire["last_assistant_message"] = "测试已完成"
        let data = json(wire)
        let payload = try CodexHookPayload.decode(from: data)

        XCTAssertEqual(payload.sessionID, "thr_123")
        XCTAssertEqual(payload.turnID, "turn_456")
        XCTAssertEqual(payload.event, .stop)
        XCTAssertEqual(payload.cwd, canonicalTestCWD)
        XCTAssertEqual(payload.prompt, "请完成测试")
        XCTAssertEqual(payload.lastAssistantMessage, "测试已完成")
    }

    func testRejectsUnknownEventAndMissingTurnID() throws {
        var unknown = basePayload
        unknown["hook_event_name"] = "Notification"
        XCTAssertThrowsError(try CodexHookPayload.decode(from: json(unknown))) { error in
            XCTAssertEqual(error as? CodexHookPayloadError, .unsupportedEvent)
        }

        var missingTurn = basePayload
        missingTurn.removeValue(forKey: "turn_id")
        XCTAssertThrowsError(try CodexHookPayload.decode(from: json(missingTurn))) { error in
            XCTAssertEqual(error as? CodexHookPayloadError, .invalidJSON)
        }
    }

    func testTransitionsRunningToCompletedAndDeduplicatesBySessionTurnEvent() async throws {
        let coordinator = CodexTaskCoordinator(now: { [fixedDate] in fixedDate })
        let running = try await coordinator.ingest(jsonData: hookData(
            event: .userPromptSubmit,
            prompt: "  Example   task\nname  "
        ))
        XCTAssertEqual(running.disposition, .accepted)
        XCTAssertEqual(running.snapshot.status, .running)
        XCTAssertEqual(running.snapshot.summary, "Example task name")
        XCTAssertEqual(running.snapshot.updatedAt, fixedDate)
        XCTAssertGreaterThan(running.snapshot.revision, 0)

        let duplicate = try await coordinator.ingest(jsonData: hookData(
            event: .userPromptSubmit,
            prompt: "Duplicate content must not overwrite"
        ))
        XCTAssertEqual(duplicate.disposition, .duplicate)
        XCTAssertEqual(duplicate.snapshot.prompt, "  Example   task\nname  ")
        XCTAssertEqual(duplicate.snapshot.revision, running.snapshot.revision)

        let completed = try await coordinator.ingest(jsonData: hookData(
            event: .stop,
            lastAssistantMessage: " Example result.\n\nDone. "
        ))
        XCTAssertEqual(completed.disposition, .accepted)
        XCTAssertEqual(completed.snapshot.status, .completed)
        XCTAssertEqual(completed.snapshot.summary, "Example result. Done.")
        XCTAssertEqual(completed.snapshot.prompt, running.snapshot.prompt)
        XCTAssertEqual(completed.snapshot.revision, running.snapshot.revision + 1)

        let current = await coordinator.currentSnapshot()
        XCTAssertEqual(current, completed.snapshot)
        let exact = await coordinator.exactCurrentCompletedSnapshot(
            threadID: threadID,
            turnID: turnID,
            cwd: testCWD
        )
        XCTAssertEqual(exact, completed.snapshot)
    }

    func testCompletedTurnCannotRegressToRunning() async throws {
        let coordinator = CodexTaskCoordinator(now: { [fixedDate] in fixedDate })
        let recorder = SnapshotRecorder()
        await coordinator.setSnapshotObserver { recorder.append($0) }
        let completed = try await coordinator.ingest(jsonData: hookData(
            event: .stop,
            lastAssistantMessage: "完成"
        ))
        let latePrompt = try await coordinator.ingest(jsonData: hookData(
            event: .userPromptSubmit,
            prompt: "迟到的开始事件"
        ))

        XCTAssertEqual(completed.snapshot.status, .completed)
        XCTAssertEqual(latePrompt.disposition, .ignoredOutOfOrder)
        XCTAssertEqual(latePrompt.snapshot.status, .completed)
        XCTAssertEqual(latePrompt.snapshot.revision, completed.snapshot.revision)
        let current = await coordinator.currentSnapshot()
        XCTAssertEqual(current?.status, .completed)
        XCTAssertEqual(recorder.values, [completed.snapshot])

        let nextAccepted = try await coordinator.ingest(jsonData: hookData(
            sessionID: "next-session",
            turnID: "next-turn",
            event: .userPromptSubmit,
            prompt: "新任务"
        ))
        XCTAssertEqual(nextAccepted.snapshot.revision, completed.snapshot.revision + 1)
        XCTAssertEqual(recorder.values, [completed.snapshot])
        let currentAfterCandidate = await coordinator.currentSnapshot()
        XCTAssertEqual(currentAfterCandidate, completed.snapshot)
    }

    func testPinnedThreadCannotBeTakenOverByAnotherRootSession() async throws {
        let coordinator = CodexTaskCoordinator(now: { [fixedDate] in fixedDate })
        let recorder = SnapshotRecorder()
        await coordinator.setSnapshotObserver { recorder.append($0) }

        let firstSessionID = "session-a"
        let firstTurnID = "turn-a"
        let secondSessionID = "session-b"
        let secondTurnID = "turn-b"

        _ = try await coordinator.ingest(jsonData: hookData(
            sessionID: firstSessionID,
            turnID: firstTurnID,
            event: .userPromptSubmit,
            prompt: "任务 A"
        ))
        let secondRunning = try await coordinator.ingest(jsonData: hookData(
            sessionID: secondSessionID,
            turnID: secondTurnID,
            event: .userPromptSubmit,
            prompt: "任务 B"
        ))
        let firstCompleted = try await coordinator.ingest(jsonData: hookData(
            sessionID: firstSessionID,
            turnID: firstTurnID,
            event: .stop,
            lastAssistantMessage: "任务 A 完成"
        ))

        XCTAssertEqual(firstCompleted.disposition, .accepted)
        XCTAssertEqual(firstCompleted.snapshot.status, .completed)
        XCTAssertEqual(secondRunning.snapshot.revision + 1, firstCompleted.snapshot.revision)
        let currentAfterOlderStop = await coordinator.currentSnapshot()
        let storedFirst = await coordinator.snapshot(
            threadID: firstSessionID,
            turnID: firstTurnID
        )
        let firstExactCompleted = await coordinator.exactCurrentCompletedSnapshot(
            threadID: firstSessionID,
            turnID: firstTurnID,
            cwd: testCWD
        )
        XCTAssertEqual(currentAfterOlderStop, firstCompleted.snapshot)
        XCTAssertEqual(storedFirst, firstCompleted.snapshot)
        XCTAssertEqual(firstExactCompleted, firstCompleted.snapshot)
        let publicationsBeforeCurrentStop = recorder.values
        XCTAssertEqual(publicationsBeforeCurrentStop.count, 2)
        XCTAssertEqual(publicationsBeforeCurrentStop[0].threadID, firstSessionID)
        XCTAssertEqual(publicationsBeforeCurrentStop[0].turnID, firstTurnID)
        XCTAssertEqual(publicationsBeforeCurrentStop[0].status, .running)
        XCTAssertEqual(publicationsBeforeCurrentStop[1].threadID, firstSessionID)
        XCTAssertEqual(publicationsBeforeCurrentStop[1].turnID, firstTurnID)
        XCTAssertEqual(publicationsBeforeCurrentStop[1].status, .completed)

        let secondCompleted = try await coordinator.ingest(jsonData: hookData(
            sessionID: secondSessionID,
            turnID: secondTurnID,
            event: .stop,
            lastAssistantMessage: "任务 B 完成"
        ))

        let currentAfterCurrentStop = await coordinator.currentSnapshot()
        let secondExactCompleted = await coordinator.exactCurrentCompletedSnapshot(
            threadID: secondSessionID,
            turnID: secondTurnID,
            cwd: testCWD
        )
        XCTAssertEqual(currentAfterCurrentStop, firstCompleted.snapshot)
        XCTAssertNil(secondExactCompleted)
        XCTAssertEqual(secondCompleted.snapshot.revision, firstCompleted.snapshot.revision + 1)
        XCTAssertEqual(recorder.values.count, 2)
        XCTAssertEqual(recorder.values.last, firstCompleted.snapshot)

        await coordinator.followNextThread()
        let selected = try await coordinator.ingest(jsonData: hookData(
            sessionID: secondSessionID,
            turnID: "turn-b-next",
            event: .userPromptSubmit,
            prompt: "明确切换后的任务 B"
        ))
        let selectedThreadID = await coordinator.currentPinnedThreadID()
        let selectedCurrent = await coordinator.currentSnapshot()
        XCTAssertEqual(selectedThreadID, secondSessionID)
        XCTAssertEqual(selectedCurrent, selected.snapshot)
        XCTAssertEqual(recorder.values.last, selected.snapshot)
    }

    func testOlderStopDoesNotTakeCurrentBackAcrossTurnsInSameSession() async throws {
        let coordinator = CodexTaskCoordinator(now: { [fixedDate] in fixedDate })
        let recorder = SnapshotRecorder()
        await coordinator.setSnapshotObserver { recorder.append($0) }

        let firstTurnID = "turn-a"
        let secondTurnID = "turn-b"
        _ = try await coordinator.ingest(jsonData: hookData(
            sessionID: threadID,
            turnID: firstTurnID,
            event: .userPromptSubmit,
            prompt: "第一轮"
        ))
        let secondRunning = try await coordinator.ingest(jsonData: hookData(
            sessionID: threadID,
            turnID: secondTurnID,
            event: .userPromptSubmit,
            prompt: "第二轮"
        ))
        let firstCompleted = try await coordinator.ingest(jsonData: hookData(
            sessionID: threadID,
            turnID: firstTurnID,
            event: .stop,
            lastAssistantMessage: "第一轮完成"
        ))

        XCTAssertEqual(firstCompleted.snapshot.status, .completed)
        XCTAssertEqual(firstCompleted.snapshot.revision, secondRunning.snapshot.revision + 1)
        let currentAfterOlderStop = await coordinator.currentSnapshot()
        XCTAssertEqual(currentAfterOlderStop, secondRunning.snapshot)
        XCTAssertEqual(recorder.values.map(\.turnID), [firstTurnID, secondTurnID])
    }

    func testAcceptedEventsInSameMillisecondReceiveStrictlyIncreasingRevisions() async throws {
        let coordinator = CodexTaskCoordinator(now: { [fixedDate] in fixedDate })
        let first = try await coordinator.ingest(jsonData: hookData(
            sessionID: "session-a",
            turnID: "turn-a",
            event: .userPromptSubmit
        ))
        let second = try await coordinator.ingest(jsonData: hookData(
            sessionID: "session-b",
            turnID: "turn-b",
            event: .userPromptSubmit
        ))
        let third = try await coordinator.ingest(jsonData: hookData(
            sessionID: "session-a",
            turnID: "turn-a",
            event: .stop
        ))

        XCTAssertEqual(second.snapshot.revision, first.snapshot.revision + 1)
        XCTAssertEqual(third.snapshot.revision, second.snapshot.revision + 1)
    }

    func testLaterProcessTimestampBaseExceedsEarlierProcessRevision() async throws {
        let earlier = CodexTaskCoordinator(now: { [fixedDate] in fixedDate })
        let laterDate = fixedDate.addingTimeInterval(0.001)
        let later = CodexTaskCoordinator(now: { laterDate })

        let earlierSnapshot = try await earlier.ingest(jsonData: hookData(
            event: .userPromptSubmit
        )).snapshot
        let laterSnapshot = try await later.ingest(jsonData: hookData(
            event: .userPromptSubmit
        )).snapshot

        XCTAssertGreaterThan(laterSnapshot.revision, earlierSnapshot.revision)
    }

    func testSummaryTruncationIsDeterministicAndPreservesGraphemeClusters() {
        let family = "👨‍👩‍👧‍👦"
        let source = String(repeating: "界", count: 159) + family + "尾"
        let first = CodexTaskSummary.make(from: source, fallback: "fallback")
        let second = CodexTaskSummary.make(from: source, fallback: "fallback")

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, CodexTaskSummary.characterLimit)
        XCTAssertTrue(first.hasSuffix("…"))
        XCTAssertFalse(first.contains(family))
    }

    private var testCWD: String {
        FileManager.default.temporaryDirectory.path
    }

    private var canonicalTestCWD: String {
        try! CodexHookPayload.canonicalDirectoryPath(testCWD)
    }

    private var basePayload: [String: Any] {
        [
            "session_id": threadID,
            "turn_id": turnID,
            "hook_event_name": CodexHookEvent.userPromptSubmit.rawValue,
            "cwd": testCWD,
        ]
    }

    private func hookData(
        sessionID: String? = nil,
        turnID: String? = nil,
        event: CodexHookEvent,
        prompt: String? = nil,
        lastAssistantMessage: String? = nil
    ) -> Data {
        var payload = basePayload
        if let sessionID { payload["session_id"] = sessionID }
        if let turnID { payload["turn_id"] = turnID }
        payload["hook_event_name"] = event.rawValue
        if let prompt { payload["prompt"] = prompt }
        if let lastAssistantMessage {
            payload["last_assistant_message"] = lastAssistantMessage
        }
        return json(payload)
    }

    private func json(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

private final class SnapshotRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [CodexTaskSnapshot] = []

    var values: [CodexTaskSnapshot] {
        lock.lock()
        defer { lock.unlock() }
        return snapshots
    }

    func append(_ snapshot: CodexTaskSnapshot) {
        lock.lock()
        defer { lock.unlock() }
        snapshots.append(snapshot)
    }
}
