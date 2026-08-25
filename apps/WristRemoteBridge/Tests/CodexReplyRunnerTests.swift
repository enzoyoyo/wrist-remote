import Foundation
import XCTest
@testable import WristRemoteBridge

final class CodexReplyRunnerTests: XCTestCase {
    private let threadID = "11111111-1111-4111-8111-111111111111"
    private let turnID = "22222222-2222-4222-8222-222222222222"
    private let queuedMessageID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!

    func testConfirmedReplyUsesExactThreadQueueInvocationWithoutShellOrStdin() async throws {
        let coordinator = try await completedCoordinator()
        let recorder = CodexInvocationRecorder(output: successfulOutput)
        let runner = CodexReplyRunner(
            coordinator: coordinator,
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            execute: { invocation in try await recorder.execute(invocation) },
            openThread: { _ in false }
        )

        let request = validRequest(transcript: "示例回复")
        let result = try await runner.submit(request)
        let recordedInvocation = await recorder.lastInvocation()
        let invocation = try XCTUnwrap(recordedInvocation)

        XCTAssertEqual(result.submissionID, request.submissionID)
        XCTAssertEqual(result.threadID, threadID)
        XCTAssertEqual(result.queuedMessageID, queuedMessageID)
        XCTAssertNil(result.observedTurnID)
        XCTAssertEqual(result.state, .queued)
        XCTAssertEqual(invocation.executableURL.path, "/usr/bin/true")
        XCTAssertEqual(invocation.arguments, [
            "queue",
            "--thread", threadID,
            "--message", "示例回复",
        ])
        XCTAssertTrue(invocation.standardInput.isEmpty)
        XCTAssertEqual(
            invocation.currentDirectoryURL.path,
            try CodexHookPayload.canonicalDirectoryPath(testCWD)
        )
    }

    func testQueueReceiptNeverClaimsDeliveredFromAnAmbiguousPromptHook() async throws {
        let coordinator = try await completedCoordinator()
        let transcript = "来自示例设备的消息"
        let nextTurnID = "44444444-4444-4444-8444-444444444444"
        let runner = CodexReplyRunner(
            coordinator: coordinator,
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            execute: { _ in self.successfulOutput },
            openThread: { [testCWD, threadID] openedThreadID in
                guard openedThreadID == threadID else { return false }
                _ = await coordinator.ingest(CodexHookPayload(
                    sessionID: threadID,
                    turnID: nextTurnID,
                    event: .userPromptSubmit,
                    cwd: testCWD,
                    prompt: transcript,
                    lastAssistantMessage: nil
                ))
                return true
            }
        )

        let result = try await runner.submit(validRequest(transcript: transcript))
        XCTAssertEqual(result.state, .queued)
        XCTAssertNil(result.observedTurnID)
    }

    func testRejectsUnconfirmedOrNonCurrentTaskBeforeExecuting() async throws {
        let coordinator = try await completedCoordinator()
        let recorder = CodexInvocationRecorder(output: successfulOutput)
        let runner = CodexReplyRunner(
            coordinator: coordinator,
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            execute: { invocation in try await recorder.execute(invocation) },
            openThread: { _ in false }
        )

        let confirmed = validRequest(transcript: "不要发送")
        let unconfirmed = CodexReplyRequest(
            submissionID: confirmed.submissionID,
            threadID: confirmed.threadID,
            turnID: confirmed.turnID,
            cwd: confirmed.cwd,
            transcript: confirmed.transcript,
            userConfirmed: false
        )
        await assertRunnerError(.confirmationRequired) {
            try await runner.submit(unconfirmed)
        }

        let wrongThread = CodexReplyRequest(
            submissionID: UUID(),
            threadID: "55555555-5555-4555-8555-555555555555",
            turnID: turnID,
            cwd: testCWD,
            transcript: "继续",
            userConfirmed: true
        )
        await assertRunnerError(.taskIsNotExactCurrentCompletion) {
            try await runner.submit(wrongThread)
        }
        let recordedInvocation = await recorder.lastInvocation()
        XCTAssertNil(recordedInvocation)
    }

    func testOnlyOneReplyCanQueueAtATime() async throws {
        let coordinator = try await completedCoordinator()
        let gate = CodexBlockingExecutor(output: successfulOutput)
        let runner = CodexReplyRunner(
            coordinator: coordinator,
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            execute: { invocation in try await gate.execute(invocation) },
            openThread: { _ in false }
        )
        let first = Task { try await runner.submit(validRequest(transcript: "第一个回复")) }
        await gate.waitUntilStarted()

        await assertRunnerError(.alreadyRunning) {
            try await runner.submit(self.validRequest(transcript: "第二个回复"))
        }

        await gate.release()
        _ = try await first.value
        let invocationCount = await gate.invocationCount()
        XCTAssertEqual(invocationCount, 1)
    }

    func testRetryWithSameSubmissionIDReturnsCachedReceiptWithoutDuplicateQueue() async throws {
        let coordinator = try await completedCoordinator()
        let recorder = CodexInvocationRecorder(output: successfulOutput)
        let runner = CodexReplyRunner(
            coordinator: coordinator,
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            execute: { invocation in try await recorder.execute(invocation) },
            openThread: { _ in false }
        )
        let submissionID = UUID()
        let request = CodexReplyRequest(
            submissionID: submissionID,
            threadID: threadID,
            turnID: turnID,
            cwd: testCWD,
            transcript: "只发送一次",
            userConfirmed: true
        )

        let first = try await runner.submit(request)
        let second = try await runner.submit(request)

        XCTAssertEqual(first, second)
        let invocationCount = await recorder.invocationCount()
        XCTAssertEqual(invocationCount, 1)

        let mismatched = CodexReplyRequest(
            submissionID: submissionID,
            threadID: threadID,
            turnID: turnID,
            cwd: testCWD,
            transcript: "不同内容",
            userConfirmed: true
        )
        await assertRunnerError(.submissionIDReuseMismatch) {
            try await runner.submit(mismatched)
        }
    }

    func testRejectsNonzeroExitMalformedConfirmationAndWrongThread() async throws {
        let coordinator = try await completedCoordinator()
        let failed = CodexReplyRunner(
            coordinator: coordinator,
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            execute: { _ in CodexProcessOutput(
                terminationStatus: 7,
                standardOutput: Data(),
                standardError: Data("failure".utf8)
            ) },
            openThread: { _ in false }
        )
        await assertRunnerError(.processFailed(7, "failure")) {
            try await failed.submit(self.validRequest(transcript: "继续"))
        }

        let malformed = CodexReplyRunner(
            coordinator: coordinator,
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            execute: { _ in CodexProcessOutput(
                terminationStatus: 0,
                standardOutput: Data("not a queue receipt\n".utf8),
                standardError: Data()
            ) },
            openThread: { _ in false }
        )
        await assertRunnerError(.invalidProcessOutput) {
            try await malformed.submit(self.validRequest(transcript: "继续"))
        }

        let otherThreadID = "66666666-6666-4666-8666-666666666666"
        let wrongThread = CodexReplyRunner(
            coordinator: coordinator,
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            execute: { _ in CodexProcessOutput(
                terminationStatus: 0,
                standardOutput: Data(
                    "Queued message \(self.queuedMessageID.uuidString) for thread \(otherThreadID).\n".utf8
                ),
                standardError: Data()
            ) },
            openThread: { _ in false }
        )
        await assertRunnerError(.queuedWrongThread) {
            try await wrongThread.submit(self.validRequest(transcript: "继续"))
        }
    }

    func testPreparedSubmissionFailsClosedAfterUncertainSideEffect() async throws {
        let coordinator = try await completedCoordinator()
        let runner = CodexReplyRunner(
            coordinator: coordinator,
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            execute: { _ in CodexProcessOutput(
                terminationStatus: 0,
                standardOutput: Data("receipt format changed".utf8),
                standardError: Data()
            ) },
            openThread: { _ in false }
        )
        let request = validRequest(transcript: "不允许重复")
        await assertRunnerError(.invalidProcessOutput) {
            try await runner.submit(request)
        }
        await assertRunnerError(.submissionOutcomeUnknown) {
            try await runner.submit(request)
        }
    }

    func testPersistentLedgerSurvivesRunnerRestartWithoutDuplicateQueue() async throws {
        let coordinator = try await completedCoordinator()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledgerURL = directory.appendingPathComponent("ledger.json")
        let recorder = CodexInvocationRecorder(output: successfulOutput)
        let request = validRequest(transcript: "跨重启只发送一次")

        let firstRunner = CodexReplyRunner(
            coordinator: coordinator,
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            submissionLedger: CodexSubmissionLedger(fileURL: ledgerURL),
            execute: { invocation in try await recorder.execute(invocation) },
            openThread: { _ in false }
        )
        let first = try await firstRunner.submit(request)

        let secondRunner = CodexReplyRunner(
            coordinator: coordinator,
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            submissionLedger: CodexSubmissionLedger(fileURL: ledgerURL),
            execute: { invocation in try await recorder.execute(invocation) },
            openThread: { _ in false }
        )
        let second = try await secondRunner.submit(request)
        XCTAssertEqual(first, second)
        let invocationCount = await recorder.invocationCount()
        XCTAssertEqual(invocationCount, 1)
    }

    func testQueueParserAllowsDiagnosticsBeforeExactReceipt() async throws {
        let coordinator = try await completedCoordinator()
        let runner = CodexReplyRunner(
            coordinator: coordinator,
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            execute: { _ in CodexProcessOutput(
                terminationStatus: 0,
                standardOutput: Data((
                    "diagnostic line\n" +
                    "Queued message \(self.queuedMessageID.uuidString) for thread \(self.threadID).\n"
                ).utf8),
                standardError: Data()
            ) },
            openThread: { _ in false }
        )
        let result = try await runner.submit(validRequest(transcript: "兼容诊断行"))
        XCTAssertEqual(result.state, .queued)
    }

    private var successfulOutput: CodexProcessOutput {
        CodexProcessOutput(
            terminationStatus: 0,
            standardOutput: Data(
                "Queued message \(queuedMessageID.uuidString) for thread \(threadID).\n".utf8
            ),
            standardError: Data()
        )
    }

    private var testCWD: String { FileManager.default.temporaryDirectory.path }

    private func completedCoordinator() async throws -> CodexTaskCoordinator {
        let coordinator = CodexTaskCoordinator()
        _ = try await coordinator.ingest(jsonData: hookData(event: .userPromptSubmit))
        _ = try await coordinator.ingest(jsonData: hookData(event: .stop))
        return coordinator
    }

    private func validRequest(transcript: String) -> CodexReplyRequest {
        CodexReplyRequest(
            submissionID: UUID(),
            threadID: threadID,
            turnID: turnID,
            cwd: testCWD,
            transcript: transcript,
            userConfirmed: true
        )
    }

    private func hookData(event: CodexHookEvent) -> Data {
        var payload: [String: Any] = [
            "session_id": threadID,
            "turn_id": turnID,
            "hook_event_name": event.rawValue,
            "cwd": testCWD,
        ]
        if event == .userPromptSubmit { payload["prompt"] = "初始任务" }
        if event == .stop { payload["last_assistant_message"] = "已完成" }
        return try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }

    private func assertRunnerError(
        _ expected: CodexReplyRunnerError,
        operation: () async throws -> CodexReplyResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? CodexReplyRunnerError, expected, file: file, line: line)
        }
    }
}

private actor CodexInvocationRecorder {
    private let output: CodexProcessOutput
    private var invocation: CodexProcessInvocation?

    init(output: CodexProcessOutput) { self.output = output }

    func execute(_ invocation: CodexProcessInvocation) throws -> CodexProcessOutput {
        self.invocation = invocation
        return output
    }

    func lastInvocation() -> CodexProcessInvocation? { invocation }
    func invocationCount() -> Int { invocation == nil ? 0 : 1 }
}

private actor CodexBlockingExecutor {
    private let output: CodexProcessOutput
    private var started = false
    private var count = 0
    private var continuation: CheckedContinuation<CodexProcessOutput, Never>?

    init(output: CodexProcessOutput) { self.output = output }

    func execute(_ invocation: CodexProcessInvocation) async throws -> CodexProcessOutput {
        _ = invocation
        started = true
        count += 1
        return await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilStarted() async {
        while !started { await Task.yield() }
    }

    func release() {
        continuation?.resume(returning: output)
        continuation = nil
    }

    func invocationCount() -> Int { count }
}
