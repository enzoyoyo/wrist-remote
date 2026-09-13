import AVFoundation
import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import WristRemoteBridge

final class CodexAppServerClientTests: XCTestCase {
    private let threadID = "11111111-1111-4111-8111-111111111111"
    private let fingerprintKey = SymmetricKey(data: Data(repeating: 0xA5, count: 32))

    func testValidAudioSizedNotificationsDoNotDestroyCatalogConnection() async throws {
        let notification = try jsonString([
            "method": "item/completed",
            "params": ["item": ["type": "userMessage", "audio": String(repeating: "A", count: 400_586)]],
        ])
        let fixture = try FakeCodexAppServer(behavior: """
        record_line
        printf '%s\\n' '{"id":1,"result":{}}'
        record_line
        record_line
        printf '%s\\n' \(shellQuote(notification))
        printf '%s\\n' \(shellQuote(notification))
        printf '%s\\n' \(shellQuote(notification))
        printf '%s\\n' '{"id":2,"result":{"data":[]}}'
        record_line
        printf '%s\\n' '{"id":3,"result":{"data":[]}}'
        record_line
        """)
        defer { fixture.remove() }
        let client = CodexAppServerClient(executableURL: fixture.executableURL)
        let first = try await client.listThreads()
        let second = try await client.listThreads()
        XCTAssertTrue(first.conversations.isEmpty)
        XCTAssertTrue(second.conversations.isEmpty)
        XCTAssertEqual(fixture.launchCount(), 1)
    }

    func testBusinessRejectionKeepsHealthySessionForNextRead() async throws {
        let fixture = try FakeCodexAppServer(behavior: """
        record_line
        printf '%s\\n' '{"id":1,"result":{}}'
        record_line
        record_line
        printf '%s\\n' '{"id":2,"error":{"code":-32600,"message":"business rejection"}}'
        record_line
        printf '%s\\n' '{"id":3,"result":{"data":[]}}'
        record_line
        """)
        defer { fixture.remove() }
        let client = CodexAppServerClient(executableURL: fixture.executableURL)
        await assertClientError(.serverRejected) { try await client.listThreads() }
        let catalog = try await client.listThreads()
        XCTAssertTrue(catalog.conversations.isEmpty)
        XCTAssertEqual(fixture.launchCount(), 1)
    }

    func testNewEmptyThreadSurvivesCatalogRefreshOnlyWhileStillLoaded() async throws {
        let workspacePath = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .resolvingSymlinksInPath().path
        let fixture = try FakeCodexAppServer(behavior: """
        record_line
        printf '%s\\n' '{"id":1,"result":{}}'
        record_line
        record_line
        printf '%s\\n' '{"id":2,"result":{"thread":{"id":"\(threadID)","cwd":"\(workspacePath)","projectId":null,"turns":[],"preview":"","status":{"type":"idle"},"canAcceptDirectInput":true,"updatedAt":1000}}}'
        record_line
        printf '%s\\n' '{"id":3,"result":{"data":[]}}'
        record_line
        printf '%s\\n' '{"id":4,"result":{"data":["\(threadID)"]}}'
        record_line
        printf '%s\\n' '{"id":5,"result":{"data":[]}}'
        record_line
        printf '%s\\n' '{"id":6,"result":{"data":["\(threadID)"]}}'
        record_line
        printf '%s\\n' '{"id":7,"result":{"data":[]}}'
        record_line
        printf '%s\\n' '{"id":8,"result":{"data":[]}}'
        """)
        defer { fixture.remove() }
        let client = CodexAppServerClient(executableURL: fixture.executableURL)
        let created = try await client.startThread(in: .init(
            id: "workspace-empty", displayName: "全新空白任务",
            directoryURL: URL(fileURLWithPath: "/tmp", isDirectory: true)
        ))
        let first = try await client.listThreadSnapshot()
        XCTAssertEqual(first.catalog.conversations, [created.conversation])
        guard first.localTargets.count == 1 else {
            return XCTFail("A loaded, verified empty task must not vanish before its first voice input")
        }
        let second = try await client.listThreadSnapshot()
        XCTAssertEqual(second.localTargets, first.localTargets)
        let unloaded = try await client.listThreadSnapshot()
        XCTAssertTrue(unloaded.localTargets.isEmpty, "Do not resurrect a closed unpersisted task")
        let methods = try fixture.inputObjects().compactMap { $0["method"] as? String }
        XCTAssertEqual(methods.filter { $0 == "thread/start" }.count, 1)
        XCTAssertEqual(methods.filter { $0 == "thread/loaded/list" }.count, 3)
        XCTAssertFalse(methods.contains("turn/start"))
        XCTAssertFalse(methods.contains("thread/queue/add"))
    }

    func testCatalogUsesExperimentalStdioHandshakeAndRedactsLocalPaths() async throws {
        let rawWorkspacePath = "/example/workspaces/customer-a"
        let listResponse = try jsonString([
            "id": 2,
            "result": [
                "data": [[
                    "id": threadID,
                    "name": "  Alpha\nThread  ",
                    "cwd": rawWorkspacePath,
                    "path": "/example/codex/private-rollout.jsonl",
                    "status": ["type": "active"],
                    "canAcceptDirectInput": true,
                    "updatedAt": 1234,
                ]],
                "nextCursor": "opaque-cursor",
            ],
        ])
        let fixture = try FakeCodexAppServer(behavior: """
        record_line
        printf '%s\n' '{"id":1,"result":{}}'
        record_line
        record_line
        printf '%s\n' \(shellQuote(listResponse))
        """)
        defer { fixture.remove() }

        let client = CodexAppServerClient(executableURL: fixture.executableURL)
        let snapshot = try await client.listThreadSnapshot()
        let catalog = snapshot.catalog

        XCTAssertEqual(fixture.arguments(), ["app-server", "--listen", "stdio://"])
        let input = try fixture.inputObjects()
        XCTAssertEqual(input.count, 3)
        XCTAssertEqual(input[0]["method"] as? String, "initialize")
        let initializeParams = try XCTUnwrap(input[0]["params"] as? [String: Any])
        let capabilities = try XCTUnwrap(initializeParams["capabilities"] as? [String: Any])
        XCTAssertEqual(capabilities["experimentalApi"] as? Bool, true)
        XCTAssertEqual(input[1]["method"] as? String, "initialized")
        XCTAssertEqual(input[2]["method"] as? String, "thread/list")
        let listParams = try XCTUnwrap(input[2]["params"] as? [String: Any])
        XCTAssertEqual((listParams["limit"] as? NSNumber)?.intValue, 12)
        XCTAssertEqual(listParams["archived"] as? Bool, false)
        XCTAssertEqual(listParams["sortKey"] as? String, "updated_at")
        XCTAssertEqual(listParams["sortDirection"] as? String, "desc")
        XCTAssertEqual(listParams["useStateDbOnly"] as? Bool, true)

        XCTAssertEqual(catalog.conversations.count, 1)
        XCTAssertEqual(catalog.conversations[0].title, "Alpha Thread")
        XCTAssertEqual(catalog.conversations[0].workspaceLabel, "customer-a")
        XCTAssertEqual(catalog.conversations[0].status, .running)
        XCTAssertEqual(catalog.conversations[0].canAcceptDirectInput, true)
        XCTAssertTrue(catalog.hasMore)
        XCTAssertEqual(snapshot.localTargets.first?.directoryURL.path, rawWorkspacePath)
        let encodedCatalog = try JSONEncoder().encode(catalog)
        XCTAssertFalse(String(decoding: encodedCatalog, as: UTF8.self).contains(rawWorkspacePath))
        XCTAssertFalse(String(describing: catalog).contains("private-rollout"))
    }

    func testQueueMessageIsJSONStdinOnlyAndServerErrorsAreRedacted() async throws {
        let submissionID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        let transcript = "中文语音；$(must-not-run)"
        let queueResponse = try jsonString([
            "id": 2,
            "result": [
                "queuedSubmission": [
                    "id": "queue-receipt-1",
                    "clientUserMessageId": submissionID.uuidString.lowercased(),
                    "input": [["type": "text", "text": transcript]],
                ],
            ],
        ])
        let fixture = try FakeCodexAppServer(behavior: """
        record_line
        printf '%s\n' '{"id":1,"result":{}}'
        record_line
        record_line
        printf '%s\n' \(shellQuote(queueResponse))
        """)
        defer { fixture.remove() }

        let client = CodexAppServerClient(executableURL: fixture.executableURL)
        let receipt = try await client.queueMessage(
            threadID: threadID,
            message: transcript,
            submissionID: submissionID
        )

        XCTAssertEqual(receipt.queuedSubmissionID, "queue-receipt-1")
        XCTAssertFalse(fixture.arguments().joined(separator: " ").contains(transcript))
        let queueRequest = try XCTUnwrap(try fixture.inputObjects().last)
        XCTAssertEqual(queueRequest["method"] as? String, "thread/queue/add")
        let params = try XCTUnwrap(queueRequest["params"] as? [String: Any])
        XCTAssertEqual(params["threadId"] as? String, threadID)
        XCTAssertEqual(params["clientUserMessageId"] as? String, submissionID.uuidString.lowercased())
        let input = try XCTUnwrap(params["input"] as? [[String: Any]])
        XCTAssertEqual(input.first?["text"] as? String, transcript)
    }

    @MainActor
    func testWatchAudioUsesNativeTranscriptionThenQueuesOnlyText() async throws {
        let submissionID = UUID(uuidString: "29292929-2929-4929-8929-292929292929")!
        let streamID = UUID(uuidString: "30303030-3030-4030-8030-303030303030")!
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let inbox = WatchCodexAudioInbox(directoryURL: directoryURL)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        try inbox.start(streamID: streamID)
        XCTAssertTrue(inbox.append(samples: Array(repeating: 120, count: 960), streamID: streamID))
        let recording = try inbox.finish(streamID: streamID)
        let audioFile = try AVAudioFile(forReading: recording.fileURL)
        XCTAssertEqual(audioFile.fileFormat.sampleRate, 16_000)
        XCTAssertEqual(audioFile.fileFormat.channelCount, 1)
        XCTAssertEqual(audioFile.length, 960)
        XCTAssertEqual(recording.sampleCount, 960)

        let queueResponse = try jsonString([
            "id": 3,
            "result": [
                "queuedSubmission": [
                    "id": "queue-receipt-audio",
                    "clientUserMessageId": submissionID.uuidString.lowercased(),
                    "input": [["type": "text", "text": "测试语音"]],
                ],
            ],
        ])
        let fixture = try FakeCodexAppServer(behavior: """
        record_line
        printf '%s\n' '{"id":1,"result":{}}'
        record_line
        record_line
        printf '%s\n' '{"id":2,"result":{"authMethod":"chatgpt","authToken":"fake-test-only-token"}}'
        record_line
        printf '%s\n' \(shellQuote(queueResponse))
        """)
        defer { fixture.remove() }

        let transport = StubCodexVoiceTransport(text: "测试语音")
        let client = CodexAppServerClient(
            executableURL: fixture.executableURL,
            voiceTranscriber: CodexNativeVoiceTranscriber(transport: transport)
        )
        let receipt = try await client.queueLocalAudio(
            threadID: threadID,
            fileURL: recording.fileURL,
            submissionID: submissionID
        )

        XCTAssertEqual(receipt.queuedSubmissionID, "queue-receipt-audio")
        XCTAssertFalse(fixture.arguments().joined(separator: " ").contains(recording.fileURL.path))
        let queueRequest = try XCTUnwrap(try fixture.inputObjects().last)
        XCTAssertEqual(queueRequest["method"] as? String, "thread/queue/add")
        let params = try XCTUnwrap(queueRequest["params"] as? [String: Any])
        XCTAssertEqual(params["threadId"] as? String, threadID)
        XCTAssertEqual(params["clientUserMessageId"] as? String, submissionID.uuidString.lowercased())
        let input = try XCTUnwrap(params["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 1)
        XCTAssertEqual(input[0]["type"] as? String, "text")
        XCTAssertEqual(input[0]["text"] as? String, "测试语音")
        XCTAssertNil(input[0]["path"])
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertFalse(try String(contentsOf: fixture.inputURL).contains(recording.fileURL.path))

        let attributes = try FileManager.default.attributesOfItem(atPath: recording.fileURL.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)
        inbox.remove(recording)
        XCTAssertFalse(FileManager.default.fileExists(atPath: recording.fileURL.path))
    }

    @MainActor
    func testCancellingCodexAudioSessionDeletesItsPrivateRecording() throws {
        let streamID = UUID(uuidString: "34343434-3434-4434-8434-343434343434")!
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let inbox = WatchCodexAudioInbox(directoryURL: directoryURL)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        try inbox.start(streamID: streamID)
        XCTAssertTrue(inbox.append(samples: Array(repeating: 42, count: 960), streamID: streamID))
        let recordingURL = directoryURL.appendingPathComponent(
            "watch-\(streamID.uuidString.lowercased()).wav"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: recordingURL.path))

        inbox.cancel(streamID: streamID)

        XCTAssertTrue(inbox.acceptsNewSession)
        XCTAssertFalse(FileManager.default.fileExists(atPath: recordingURL.path))
    }

    @MainActor
    func testOriginalWatchAudioSubmissionIsIdempotentWithoutPersistingItsPath() async throws {
        let submissionID = UUID(uuidString: "31313131-3131-4131-8131-313131313131")!
        let streamID = UUID(uuidString: "32323232-3232-4232-8232-323232323232")!
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let ledgerURL = directoryURL.appendingPathComponent("ledger.json")
        let inbox = WatchCodexAudioInbox(directoryURL: directoryURL.appendingPathComponent("audio"))
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        try inbox.start(streamID: streamID)
        XCTAssertTrue(inbox.append(samples: Array(repeating: -240, count: 1_440), streamID: streamID))
        let recording = try inbox.finish(streamID: streamID)

        let queueResponse = try jsonString([
            "id": 3,
            "result": [
                "queuedSubmission": [
                    "id": "queue-receipt-audio-idempotent",
                    "clientUserMessageId": submissionID.uuidString.lowercased(),
                    "input": [["type": "text", "text": "测试语音"]],
                ],
            ],
        ])
        let fixture = try FakeCodexAppServer(behavior: """
        record_line
        printf '%s\n' '{"id":1,"result":{}}'
        record_line
        record_line
        printf '%s\n' '{"id":2,"result":{"authMethod":"chatgpt","authToken":"fake-test-only-token"}}'
        record_line
        printf '%s\n' \(shellQuote(queueResponse))
        """)
        defer { fixture.remove() }

        let transport = StubCodexVoiceTransport(text: "测试语音")
        let service = try CodexConversationService(
            client: CodexAppServerClient(
                executableURL: fixture.executableURL,
                voiceTranscriber: CodexNativeVoiceTranscriber(transport: transport)
            ),
            workspaces: [],
            fingerprintKey: fingerprintKey,
            ledger: CodexConversationIdempotencyLedger(fileURL: ledgerURL)
        )
        let request = CodexExistingConversationAudioSubmission(
            submissionID: submissionID,
            threadID: threadID,
            fileURL: recording.fileURL,
            sha256Hex: recording.sha256Hex
        )
        let first = try await service.submitAudio(request)
        let second = try await service.submitAudio(request)

        XCTAssertEqual(first, second)
        XCTAssertEqual(fixture.launchCount(), 1)
        let ledgerContents = try String(contentsOf: ledgerURL, encoding: .utf8)
        XCTAssertFalse(ledgerContents.contains(recording.fileURL.path))
        XCTAssertFalse(ledgerContents.contains(recording.sha256Hex))
        XCTAssertFalse(ledgerContents.contains("测试语音"))
        XCTAssertFalse(ledgerContents.contains("fake-test-only-token"))
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        inbox.remove(recording)
    }

    @MainActor
    func testPostTranscriptionTargetChangePreventsQueueAndKeepsCatalogSession() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let inbox = WatchCodexAudioInbox(directoryURL: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        try inbox.start(streamID: id)
        XCTAssertTrue(inbox.append(samples: Array(repeating: 10, count: 960), streamID: id))
        let recording = try inbox.finish(streamID: id)
        let fixture = try FakeCodexAppServer(behavior: """
        record_line
        printf '%s\n' '{"id":1,"result":{}}'
        record_line
        record_line
        printf '%s\n' '{"id":2,"result":{"authMethod":"chatgpt","authToken":"fake-test-only-token"}}'
        record_line
        printf '%s\n' '{"id":3,"result":{"data":[]}}'
        record_line
        """)
        defer { fixture.remove() }
        let transport = StubCodexVoiceTransport()
        let client = CodexAppServerClient(
            executableURL: fixture.executableURL,
            voiceTranscriber: .init(transport: transport)
        )
        do {
            _ = try await client.queueLocalAudio(
                threadID: threadID, fileURL: recording.fileURL, submissionID: id,
                validateBeforeQueue: { throw CodexNativeVoiceError.targetChanged }
            )
            XCTFail("A changed target must never receive transcribed text")
        } catch { XCTAssertEqual(error as? CodexNativeVoiceError, .targetChanged) }
        _ = try await client.listThreads()
        XCTAssertEqual(fixture.launchCount(), 1)
        XCTAssertFalse(try fixture.inputObjects().contains { $0["method"] as? String == "thread/queue/add" })
    }

    @MainActor
    func testNativeTranscriptionFailureIsNotReportedAsDeliveredOrUnknown() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let inbox = WatchCodexAudioInbox(directoryURL: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        try inbox.start(streamID: id)
        XCTAssertTrue(inbox.append(samples: Array(repeating: 10, count: 960), streamID: id))
        let recording = try inbox.finish(streamID: id)
        let fixture = try FakeCodexAppServer(behavior: """
        record_line
        printf '%s\n' '{"id":1,"result":{}}'
        record_line
        record_line
        printf '%s\n' '{"id":2,"result":{"authMethod":"chatgpt","authToken":"fake-test-only-token"}}'
        record_line
        """)
        defer { fixture.remove() }
        let service = try CodexConversationService(
            client: CodexAppServerClient(
                executableURL: fixture.executableURL,
                voiceTranscriber: .init(transport: StubCodexVoiceTransport(status: 429))
            ), workspaces: [], fingerprintKey: fingerprintKey
        )
        do {
            _ = try await service.submitAudio(.init(
                submissionID: id, threadID: threadID,
                fileURL: recording.fileURL, sha256Hex: recording.sha256Hex
            ))
            XCTFail("A transcription failure must not produce a delivery receipt")
        } catch { XCTAssertEqual(error as? CodexNativeVoiceError, .rateLimited) }
        XCTAssertFalse(try fixture.inputObjects().contains { $0["method"] as? String == "thread/queue/add" })
    }

    @MainActor
    func testTranscriptValidationFailureIsKnownNotSentBeforeQueue() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let inbox = WatchCodexAudioInbox(directoryURL: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        try inbox.start(streamID: id)
        XCTAssertTrue(inbox.append(samples: Array(repeating: 10, count: 960), streamID: id))
        let recording = try inbox.finish(streamID: id)
        let fixture = try FakeCodexAppServer(behavior: """
        record_line
        printf '%s\n' '{"id":1,"result":{}}'
        record_line
        record_line
        printf '%s\n' '{"id":2,"result":{"authMethod":"chatgpt","authToken":"fake-test-only-token"}}'
        record_line
        """)
        defer { fixture.remove() }
        var limits = CodexAppServerClient.Limits()
        limits.maximumMessageBytes = 3
        let service = try CodexConversationService(
            client: CodexAppServerClient(
                executableURL: fixture.executableURL, limits: limits,
                voiceTranscriber: .init(transport: StubCodexVoiceTransport(text: "测试语音"))
            ), workspaces: [], fingerprintKey: fingerprintKey
        )
        do {
            _ = try await service.submitAudio(.init(
                submissionID: id, threadID: threadID,
                fileURL: recording.fileURL, sha256Hex: recording.sha256Hex
            ))
            XCTFail("A rejected transcript must be a known pre-queue failure")
        } catch { XCTAssertEqual(error as? CodexNativeVoiceError, .responseTooLarge) }
        XCTAssertFalse(try fixture.inputObjects().contains { $0["method"] as? String == "thread/queue/add" })
    }

    @MainActor
    func testPreQueueRateLimitsReleasePersistentCapacityAndAllowManualRetryAfterRestart() async throws {
        let fixture = try FakeCodexAppServer(behavior: repeatingVoiceAuthentication)
        defer { fixture.remove() }
        let recording = try makeVoiceLedgerRecording(in: fixture.directoryURL)
        let ledgerURL = fixture.directoryURL.appendingPathComponent("voice-ledger.json")
        let limits = CodexConversationIdempotencyLedger.Limits(maximumRecordCount: 2, maximumFileBytes: 4_096)
        let transport = StubCodexVoiceTransport(status: 429)
        let client = CodexAppServerClient(
            executableURL: fixture.executableURL, voiceTranscriber: .init(transport: transport)
        )
        let service = try CodexConversationService(
            client: client, workspaces: [], fingerprintKey: fingerprintKey,
            ledger: .init(fileURL: ledgerURL, limits: limits)
        )
        let ids = (0..<4).map { _ in UUID() }
        for id in ids + [ids[0]] {
            await assertVoiceError(.rateLimited) {
                try await service.submitAudio(.init(
                    submissionID: id, threadID: threadID,
                    fileURL: recording.fileURL, sha256Hex: recording.sha256Hex
                ))
            }
        }
        let restarted = try CodexConversationService(
            client: client, workspaces: [], fingerprintKey: fingerprintKey,
            ledger: .init(fileURL: ledgerURL, limits: limits)
        )
        for id in [ids[0], UUID()] {
            await assertVoiceError(.rateLimited) {
                try await restarted.submitAudio(.init(
                    submissionID: id, threadID: threadID,
                    fileURL: recording.fileURL, sha256Hex: recording.sha256Hex
                ))
            }
        }
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 7)
        XCTAssertFalse(try fixture.inputObjects().contains { $0["method"] as? String == "thread/queue/add" })
        XCTAssertFalse(try String(contentsOf: ledgerURL, encoding: .utf8).contains(recording.fileURL.path))
    }

    @MainActor
    func testKnownPreQueueTargetCancellationAndTranscriptFailuresCanBeRetried() async throws {
        for expected in [CodexNativeVoiceError.targetChanged, .cancelled, .responseTooLarge] {
            let fixture = try FakeCodexAppServer(behavior: repeatingVoiceAuthentication)
            defer { fixture.remove() }
            let recording = try makeVoiceLedgerRecording(in: fixture.directoryURL)
            let transport = StubCodexVoiceTransport(text: "测试语音")
            var clientLimits = CodexAppServerClient.Limits()
            if expected == .responseTooLarge { clientLimits.maximumMessageBytes = 3 }
            let service = try CodexConversationService(
                client: CodexAppServerClient(
                    executableURL: fixture.executableURL, limits: clientLimits,
                    voiceTranscriber: .init(transport: transport)
                ), workspaces: [], fingerprintKey: fingerprintKey,
                ledger: .init(
                    fileURL: fixture.directoryURL.appendingPathComponent("ledger.json"),
                    limits: .init(maximumRecordCount: 1, maximumFileBytes: 4_096)
                )
            )
            let request = CodexExistingConversationAudioSubmission(
                submissionID: UUID(), threadID: threadID,
                fileURL: recording.fileURL, sha256Hex: recording.sha256Hex
            )
            for _ in 0..<2 {
                await assertVoiceError(expected) {
                    try await service.submitAudio(request, validateBeforeQueue: {
                        if expected == .targetChanged { throw CodexNativeVoiceError.targetChanged }
                        if expected == .cancelled { throw CancellationError() }
                    })
                }
            }
            let requests = await transport.requests
            XCTAssertEqual(requests.count, 2)
            XCTAssertFalse(try fixture.inputObjects().contains { $0["method"] as? String == "thread/queue/add" })
        }
    }

    @MainActor
    func testAudioQueueWithoutReceiptStaysUnknownAndIsNeverReplayedAfterRestart() async throws {
        let fixture = try FakeCodexAppServer(behavior: """
        record_line
        printf '%s\\n' '{"id":1,"result":{}}'
        record_line
        record_line
        printf '%s\\n' '{"id":2,"result":{"authMethod":"chatgpt","authToken":"fake-test-only-token"}}'
        record_line
        exit 0
        """)
        defer { fixture.remove() }
        let recording = try makeVoiceLedgerRecording(in: fixture.directoryURL)
        let ledgerURL = fixture.directoryURL.appendingPathComponent("unknown-audio-ledger.json")
        let transport = StubCodexVoiceTransport()
        let client = CodexAppServerClient(
            executableURL: fixture.executableURL, voiceTranscriber: .init(transport: transport)
        )
        let service = try CodexConversationService(
            client: client, workspaces: [], fingerprintKey: fingerprintKey,
            ledger: .init(fileURL: ledgerURL)
        )
        let request = CodexExistingConversationAudioSubmission(
            submissionID: UUID(), threadID: threadID,
            fileURL: recording.fileURL, sha256Hex: recording.sha256Hex
        )
        for _ in 0..<2 {
            await assertServiceError(.outcomeUnknown) { try await service.submitAudio(request) }
        }
        let restarted = try CodexConversationService(
            client: client, workspaces: [], fingerprintKey: fingerprintKey,
            ledger: .init(fileURL: ledgerURL)
        )
        await assertServiceError(.outcomeUnknown) { try await restarted.submitAudio(request) }
        XCTAssertEqual(fixture.launchCount(), 1)
        XCTAssertEqual(try fixture.inputObjects().filter { $0["method"] as? String == "thread/queue/add" }.count, 1)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testLedgerAbortRejectsWrongFingerprintInactiveAndCompletedRecords() async throws {
        let ledger = CodexConversationIdempotencyLedger()
        let fingerprint = String(repeating: "a", count: 64)
        let wrongFingerprint = String(repeating: "b", count: 64)
        let activeID = UUID()
        _ = try await ledger.beginExisting(submissionID: activeID, fingerprint: fingerprint)
        await assertServiceError(.idempotencyLedgerUnavailable) {
            try await ledger.abortBeforeQueue(submissionID: activeID, fingerprint: wrongFingerprint)
        }
        let stillActive = try await ledger.beginExisting(submissionID: activeID, fingerprint: fingerprint)
        XCTAssertEqual(stillActive, .inProgress)
        try await ledger.abortBeforeQueue(submissionID: activeID, fingerprint: fingerprint)
        let released = try await ledger.beginExisting(submissionID: activeID, fingerprint: fingerprint)
        XCTAssertEqual(released, .new)
        await ledger.finishWithoutReceipt(submissionID: activeID, fingerprint: fingerprint)
        await assertServiceError(.idempotencyLedgerUnavailable) {
            try await ledger.abortBeforeQueue(submissionID: activeID, fingerprint: fingerprint)
        }
        let stillUnknown = try await ledger.beginExisting(submissionID: activeID, fingerprint: fingerprint)
        XCTAssertEqual(stillUnknown, .unknownAfterSideEffect)

        let completedID = UUID()
        _ = try await ledger.beginExisting(submissionID: completedID, fingerprint: fingerprint)
        let receipt = CodexConversationQueueReceipt(
            submissionID: completedID, threadID: threadID, queuedSubmissionID: "completed-test-only"
        )
        try await ledger.complete(submissionID: completedID, fingerprint: fingerprint, receipt: receipt)
        await assertServiceError(.idempotencyLedgerUnavailable) {
            try await ledger.abortBeforeQueue(submissionID: completedID, fingerprint: fingerprint)
        }
        let stillCompleted = try await ledger.beginExisting(submissionID: completedID, fingerprint: fingerprint)
        XCTAssertEqual(stillCompleted, .completed(receipt))
    }

    func testLedgerAbortPersistenceFailureKeepsReservationAndClearsActiveOwnership() async throws {
        let fixture = try FakeCodexAppServer(behavior: "exit 0")
        defer { fixture.remove() }
        let fileURL = fixture.directoryURL.appendingPathComponent("failed-abort.json")
        let limits = CodexConversationIdempotencyLedger.Limits(maximumRecordCount: 1, maximumFileBytes: 4_096)
        let ledger = CodexConversationIdempotencyLedger(
            fileURL: fileURL, persistenceFault: .failAbort, limits: limits
        )
        let id = UUID()
        let fingerprint = String(repeating: "c", count: 64)
        _ = try await ledger.beginExisting(submissionID: id, fingerprint: fingerprint)
        let original = try Data(contentsOf: fileURL)
        await assertServiceError(.idempotencyLedgerUnavailable) {
            try await ledger.abortBeforeQueue(submissionID: id, fingerprint: fingerprint)
        }
        XCTAssertEqual(try Data(contentsOf: fileURL), original)
        let inMemory = try await ledger.beginExisting(submissionID: id, fingerprint: fingerprint)
        XCTAssertEqual(inMemory, .unknownAfterSideEffect)
        await assertServiceError(.idempotencyLedgerUnavailable) {
            try await ledger.beginExisting(submissionID: UUID(), fingerprint: fingerprint)
        }
        let restarted = CodexConversationIdempotencyLedger(fileURL: fileURL, limits: limits)
        let onDisk = try await restarted.beginExisting(submissionID: id, fingerprint: fingerprint)
        XCTAssertEqual(onDisk, .unknownAfterSideEffect)
        await assertServiceError(.idempotencyLedgerUnavailable) {
            try await restarted.abortBeforeQueue(submissionID: id, fingerprint: fingerprint)
        }
    }

    private var repeatingVoiceAuthentication: String {
        """
        record_line
        printf '%s\\n' '{"id":1,"result":{}}'
        record_line
        response_id=2
        while record_line; do
          printf '{"id":%s,"result":{"authMethod":"chatgpt","authToken":"fake-test-only-token"}}\\n' "$response_id"
          response_id=$((response_id + 1))
        done
        """
    }

    @MainActor
    private func makeVoiceLedgerRecording(in directory: URL) throws -> WatchCodexAudioInbox.FinalizedRecording {
        let inbox = WatchCodexAudioInbox(directoryURL: directory.appendingPathComponent("synthetic-audio"))
        let streamID = UUID()
        try inbox.start(streamID: streamID)
        XCTAssertTrue(inbox.append(samples: Array(repeating: 10, count: 960), streamID: streamID))
        return try inbox.finish(streamID: streamID)
    }

    private func assertVoiceError<T>(
        _ expected: CodexNativeVoiceError,
        operation: () async throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? CodexNativeVoiceError, expected, file: file, line: line)
        }
    }

    func testNewConversationRequestAndSubmissionAreIdempotent() async throws {
        let workspaceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspaceURL) }

        let submissionID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
        let requestID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
        let startResponse = try jsonString([
            "id": 2,
            "result": [
                "thread": [
                    "id": threadID,
                    "name": "New conversation",
                    "cwd": workspaceURL.resolvingSymlinksInPath().path,
                    "forkedFromId": NSNull(),
                    "parentThreadId": NSNull(),
                    "projectId": "project-a",
                    "status": ["type": "idle"],
                    "canAcceptDirectInput": true,
                    "updatedAt": 4567,
                ],
            ],
        ])
        let queueResponse = try jsonString([
            "id": 3,
            "result": [
                "queuedSubmission": [
                    "id": "queue-receipt-new",
                    "clientUserMessageId": submissionID.uuidString.lowercased(),
                    "input": [["type": "text", "text": "新任务"]],
                ],
            ],
        ])
        let fixture = try FakeCodexAppServer(behavior: """
        record_line
        printf '%s\n' '{"id":1,"result":{}}'
        record_line
        record_line
        printf '%s\n' \(shellQuote(startResponse))
        record_line
        printf '%s\n' \(shellQuote(queueResponse))
        """)
        defer { fixture.remove() }

        let client = CodexAppServerClient(executableURL: fixture.executableURL)
        let service = try CodexConversationService(
            client: client,
            workspaces: [
                CodexWorkspaceDescriptor(
                    id: "workspace-a",
                    displayName: "Workspace A",
                    directoryURL: workspaceURL,
                    projectID: "project-a"
                ),
            ],
            fingerprintKey: fingerprintKey
        )
        let request = CodexNewConversationSubmission(
            requestID: requestID,
            submissionID: submissionID,
            workspaceID: "workspace-a",
            message: "新任务"
        )

        let first = try await service.createConversationAndSubmit(request)
        let second = try await service.createConversationAndSubmit(request)
        XCTAssertEqual(first, second)
        XCTAssertEqual(fixture.launchCount(), 1)
        XCTAssertEqual(first.conversation.workspaceLabel, "Workspace A")
        XCTAssertEqual(first.receipt.threadID, threadID)

        let requests = try fixture.inputObjects()
        XCTAssertEqual(requests.count, 4)
        let startParams = try XCTUnwrap(requests[2]["params"] as? [String: Any])
        XCTAssertEqual(startParams["cwd"] as? String, workspaceURL.resolvingSymlinksInPath().path)
        XCTAssertEqual(startParams["projectId"] as? String, "project-a")
        XCTAssertEqual(startParams["sessionStartSource"] as? String, "startup")
        XCTAssertEqual(startParams["threadSource"] as? String, "wristRemote")
        for forbiddenKey in [
            "fork", "forkedFromId", "parentThreadId", "resume", "sourceThread", "sourceThreadId",
        ] {
            XCTAssertNil(startParams[forbiddenKey], "thread/start must not contain \(forbiddenKey)")
        }
        let queueParams = try XCTUnwrap(requests[3]["params"] as? [String: Any])
        XCTAssertEqual(queueParams["threadId"] as? String, threadID)

        let conflicting = CodexNewConversationSubmission(
            requestID: requestID,
            submissionID: submissionID,
            workspaceID: "workspace-a",
            message: "另一条任务"
        )
        await assertServiceError(.idempotencyConflict) {
            try await service.createConversationAndSubmit(conflicting)
        }
        XCTAssertEqual(fixture.launchCount(), 1)
    }

    func testExistingConversationFirstSideEffectFailureIsOutcomeUnknownAndNeverReplayed() async throws {
        let submissionID = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
        let rejectedResponse = try jsonString([
            "id": 2,
            "error": ["code": -32_000, "message": "queue outcome unavailable"],
        ])
        let fixture = try FakeCodexAppServer(behavior: """
        record_line
        printf '%s\n' '{"id":1,"result":{}}'
        record_line
        record_line
        printf '%s\n' \(shellQuote(rejectedResponse))
        """)
        defer { fixture.remove() }

        let service = try CodexConversationService(
            client: CodexAppServerClient(executableURL: fixture.executableURL),
            workspaces: [],
            fingerprintKey: fingerprintKey
        )
        let request = CodexExistingConversationSubmission(
            submissionID: submissionID,
            threadID: threadID,
            message: "只允许尝试一次"
        )

        await assertServiceError(.outcomeUnknown) {
            try await service.submit(request)
        }
        await assertServiceError(.outcomeUnknown) {
            try await service.submit(request)
        }

        XCTAssertEqual(fixture.launchCount(), 1)
        XCTAssertEqual(
            try fixture.inputObjects().filter { $0["method"] as? String == "thread/queue/add" }.count,
            1
        )
    }

    func testNewConversationFirstSideEffectFailureIsOutcomeUnknownAndNeverReplayed() async throws {
        let workspaceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspaceURL) }
        let submissionID = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
        let requestID = UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!
        let startResponse = try jsonString([
            "id": 2,
            "result": [
                "thread": [
                    "id": threadID,
                    "name": "New conversation",
                    "cwd": workspaceURL.resolvingSymlinksInPath().path,
                    "forkedFromId": NSNull(),
                    "parentThreadId": NSNull(),
                    "projectId": NSNull(),
                    "status": ["type": "idle"],
                    "canAcceptDirectInput": true,
                    "updatedAt": 4567,
                ],
            ],
        ])
        let rejectedResponse = try jsonString([
            "id": 3,
            "error": ["code": -32_000, "message": "queue outcome unavailable"],
        ])
        let fixture = try FakeCodexAppServer(behavior: """
        record_line
        printf '%s\n' '{"id":1,"result":{}}'
        record_line
        record_line
        printf '%s\n' \(shellQuote(startResponse))
        record_line
        printf '%s\n' \(shellQuote(rejectedResponse))
        """)
        defer { fixture.remove() }

        let service = try CodexConversationService(
            client: CodexAppServerClient(executableURL: fixture.executableURL),
            workspaces: [CodexWorkspaceDescriptor(
                id: "workspace-a",
                displayName: "Workspace A",
                directoryURL: workspaceURL
            )],
            fingerprintKey: fingerprintKey
        )
        let request = CodexNewConversationSubmission(
            requestID: requestID,
            submissionID: submissionID,
            workspaceID: "workspace-a",
            message: "新会话也只允许尝试一次"
        )

        await assertServiceError(.outcomeUnknown) {
            try await service.createConversationAndSubmit(request)
        }
        await assertServiceError(.outcomeUnknown) {
            try await service.createConversationAndSubmit(request)
        }

        XCTAssertEqual(fixture.launchCount(), 1)
        let requests = try fixture.inputObjects()
        XCTAssertEqual(requests.filter { $0["method"] as? String == "thread/start" }.count, 1)
        XCTAssertEqual(requests.filter { $0["method"] as? String == "thread/queue/add" }.count, 1)
    }

    func testExistingReceiptRemainsSuccessfulWhenLedgerCompletionPersistenceFails() async throws {
        let submissionID = UUID(uuidString: "dddddddd-dddd-4ddd-8ddd-dddddddddddd")!
        let queueResponse = try jsonString([
            "id": 2,
            "result": [
                "queuedSubmission": [
                    "id": "existing-ledger-failure-receipt",
                    "clientUserMessageId": submissionID.uuidString.lowercased(),
                ],
            ],
        ])
        let fixture = try FakeCodexAppServer(behavior: """
        record_line
        printf '%s\n' '{"id":1,"result":{}}'
        record_line
        record_line
        printf '%s\n' \(shellQuote(queueResponse))
        record_line
        """)
        defer { fixture.remove() }
        let ledgerURL = fixture.directoryURL.appendingPathComponent("existing-ledger.json")

        let service = try CodexConversationService(
            client: CodexAppServerClient(executableURL: fixture.executableURL),
            workspaces: [],
            fingerprintKey: fingerprintKey,
            ledger: CodexConversationIdempotencyLedger(
                fileURL: ledgerURL,
                persistenceFault: .failCompletion
            )
        )
        let request = CodexExistingConversationSubmission(
            submissionID: submissionID,
            threadID: threadID,
            message: "真实回执不能被持久化错误覆盖"
        )

        let first = try await service.submit(request)
        let second = try await service.submit(request)
        let restartedService = try CodexConversationService(
            client: CodexAppServerClient(executableURL: fixture.executableURL),
            workspaces: [],
            fingerprintKey: fingerprintKey,
            ledger: CodexConversationIdempotencyLedger(fileURL: ledgerURL)
        )
        await assertServiceError(.outcomeUnknown) {
            try await restartedService.submit(request)
        }

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.queuedSubmissionID, "existing-ledger-failure-receipt")
        XCTAssertEqual(fixture.launchCount(), 1)
        XCTAssertEqual(
            try fixture.inputObjects().filter { $0["method"] as? String == "thread/queue/add" }.count,
            1
        )
    }

    func testNewReceiptRemainsSuccessfulWhenLedgerCompletionPersistenceFails() async throws {
        let workspaceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspaceURL) }
        let submissionID = UUID(uuidString: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee")!
        let requestID = UUID(uuidString: "ffffffff-ffff-4fff-8fff-ffffffffffff")!
        let startResponse = try jsonString([
            "id": 2,
            "result": [
                "thread": [
                    "id": threadID,
                    "name": "New conversation",
                    "cwd": workspaceURL.resolvingSymlinksInPath().path,
                    "forkedFromId": NSNull(),
                    "parentThreadId": NSNull(),
                    "projectId": NSNull(),
                    "status": ["type": "idle"],
                    "canAcceptDirectInput": true,
                    "updatedAt": 4567,
                ],
            ],
        ])
        let queueResponse = try jsonString([
            "id": 3,
            "result": [
                "queuedSubmission": [
                    "id": "new-ledger-failure-receipt",
                    "clientUserMessageId": submissionID.uuidString.lowercased(),
                ],
            ],
        ])
        let fixture = try FakeCodexAppServer(behavior: """
        record_line
        printf '%s\n' '{"id":1,"result":{}}'
        record_line
        record_line
        printf '%s\n' \(shellQuote(startResponse))
        record_line
        printf '%s\n' \(shellQuote(queueResponse))
        record_line
        """)
        defer { fixture.remove() }
        let ledgerURL = fixture.directoryURL.appendingPathComponent("new-ledger.json")

        let service = try CodexConversationService(
            client: CodexAppServerClient(executableURL: fixture.executableURL),
            workspaces: [CodexWorkspaceDescriptor(
                id: "workspace-a",
                displayName: "Workspace A",
                directoryURL: workspaceURL
            )],
            fingerprintKey: fingerprintKey,
            ledger: CodexConversationIdempotencyLedger(
                fileURL: ledgerURL,
                persistenceFault: .failCompletion
            )
        )
        let request = CodexNewConversationSubmission(
            requestID: requestID,
            submissionID: submissionID,
            workspaceID: "workspace-a",
            message: "新会话真实回执也不能被覆盖"
        )

        let first = try await service.createConversationAndSubmit(request)
        let second = try await service.createConversationAndSubmit(request)
        let restartedService = try CodexConversationService(
            client: CodexAppServerClient(executableURL: fixture.executableURL),
            workspaces: [CodexWorkspaceDescriptor(
                id: "workspace-a",
                displayName: "Workspace A",
                directoryURL: workspaceURL
            )],
            fingerprintKey: fingerprintKey,
            ledger: CodexConversationIdempotencyLedger(fileURL: ledgerURL)
        )
        await assertServiceError(.outcomeUnknown) {
            try await restartedService.createConversationAndSubmit(request)
        }

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.receipt.queuedSubmissionID, "new-ledger-failure-receipt")
        XCTAssertEqual(fixture.launchCount(), 1)
        let requests = try fixture.inputObjects()
        XCTAssertEqual(requests.filter { $0["method"] as? String == "thread/start" }.count, 1)
        XCTAssertEqual(requests.filter { $0["method"] as? String == "thread/queue/add" }.count, 1)
    }

    func testStartThreadRejectsAnyNonIndependentOrMismatchedResponse() async throws {
        let workspaceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspaceURL) }
        let descriptor = CodexWorkspaceDescriptor(
            id: "workspace-a",
            displayName: "Workspace A",
            directoryURL: workspaceURL,
            projectID: "project-a"
        )

        enum InvalidResponse {
            case fork
            case parent
            case noncanonicalWorkingDirectory
            case projectMismatch
            case inheritedSession
            case previousTurns
            case malformedTurns
            case previousPreview
        }

        for invalidResponse in [
            InvalidResponse.fork,
            .parent,
            .noncanonicalWorkingDirectory,
            .projectMismatch,
            .inheritedSession,
            .previousTurns,
            .malformedTurns,
            .previousPreview,
        ] {
            var thread: [String: Any] = [
                "id": threadID,
                "name": "Independent conversation",
                "cwd": workspaceURL.resolvingSymlinksInPath().path,
                "forkedFromId": NSNull(),
                "parentThreadId": NSNull(),
                "projectId": "project-a",
                "status": ["type": "idle"],
                "canAcceptDirectInput": true,
                "updatedAt": 4567,
            ]
            switch invalidResponse {
            case .fork:
                thread["forkedFromId"] = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
            case .parent:
                thread["parentThreadId"] = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
            case .noncanonicalWorkingDirectory:
                thread["cwd"] = workspaceURL.resolvingSymlinksInPath().path + "/."
            case .projectMismatch:
                thread["projectId"] = "different-project"
            case .inheritedSession:
                thread["sessionId"] = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
            case .previousTurns:
                thread["turns"] = [["id": "old-turn"]]
            case .malformedTurns:
                thread["turns"] = "old-turn"
            case .previousPreview:
                thread["preview"] = "Content from the previous conversation"
            }
            let response = try jsonString([
                "id": 2,
                "result": ["thread": thread],
            ])
            let fixture = try FakeCodexAppServer(behavior: """
            record_line
            printf '%s\n' '{"id":1,"result":{}}'
            record_line
            record_line
            printf '%s\n' \(shellQuote(response))
            """)
            defer { fixture.remove() }

            await assertClientError(.invalidProtocolResponse) {
                try await CodexAppServerClient(executableURL: fixture.executableURL)
                    .startThread(in: descriptor)
            }
        }
    }

    func testAppServerLaunchPreservesSettingsButNotParentTaskIdentity() {
        let inherited = [
            "HOME": "/example/home", "CODEX_HOME": "/example/codex",
            "PATH": "/example/bin", "CODEX_THREAD_ID": "old-thread",
            "CODEX_SESSION_ID": "old-session", "CODEX_TURN_ID": "old-turn",
            "CODEX_PARENT_THREAD_ID": "parent-thread",
            "CODEX_PARENT_SESSION_ID": "parent-session",
        ]
        XCTAssertEqual(CodexAppServerLaunchContext.environment(from: inherited), [
            "HOME": "/example/home", "CODEX_HOME": "/example/codex", "PATH": "/example/bin",
        ])
    }

    func testStandaloneThreadExplicitlyRequestsNoProjectAndAcceptsEmptyHistory() async throws {
        let workspaceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspaceURL) }
        let response = try jsonString([
            "id": 2, "result": ["thread": [
                "id": threadID, "sessionId": threadID, "name": "Blank task",
                "cwd": workspaceURL.path, "projectId": NSNull(),
                "turns": [], "preview": "", "status": ["type": "idle"],
                "updatedAt": 4567,
            ]],
        ])
        let fixture = try FakeCodexAppServer(behavior: """
        record_line
        printf '%s\\n' '{"id":1,"result":{}}'
        record_line
        record_line
        printf '%s\\n' \(shellQuote(response))
        """)
        defer { fixture.remove() }
        let result = try await CodexAppServerClient(executableURL: fixture.executableURL)
            .startThread(in: CodexWorkspaceDescriptor(
                id: WatchCodexConversationTarget.standaloneWorkspaceID,
                displayName: "独立任务", directoryURL: workspaceURL
            ))
        XCTAssertEqual(result.conversation.threadID, threadID)
        let request = try XCTUnwrap(try fixture.inputObjects().last)
        XCTAssertEqual(request["method"] as? String, "thread/start")
        let params = try XCTUnwrap(request["params"] as? [String: Any])
        XCTAssertTrue(params["projectId"] is NSNull)
        XCTAssertEqual(params["cwd"] as? String, workspaceURL.path)
    }

    func testQueueReceiptDoesNotStopTheLongLivedAppServer() async throws {
        let submissionID = UUID(uuidString: "77777777-7777-4777-8777-777777777777")!
        let queueResponse = try jsonString([
            "id": 2,
            "result": ["queuedSubmission": [
                "id": "long-lived-queue-receipt",
                "clientUserMessageId": submissionID.uuidString.lowercased(),
            ]],
        ])
        let fixture = try FakeCodexAppServer(behavior: """
        record_line
        printf '%s\n' '{"id":1,"result":{}}'
        record_line
        record_line
        printf '%s\n' \(shellQuote(queueResponse))
        record_line
        """)
        defer { fixture.remove() }

        let client = CodexAppServerClient(executableURL: fixture.executableURL)
        _ = try await client.queueMessage(
            threadID: threadID,
            message: "keep the app server alive",
            submissionID: submissionID
        )

        XCTAssertEqual(fixture.launchCount(), 1)
        XCTAssertTrue(fixture.isMostRecentProcessRunning(afterDelayMilliseconds: 100))
        withExtendedLifetime(client) {}
    }

    func testRejectedSideEffectIsNotReplayedAndHealthySessionIsReused() async throws {
        let firstSubmissionID = UUID(uuidString: "88888888-8888-4888-8888-888888888888")!
        let secondSubmissionID = UUID(uuidString: "99999999-9999-4999-8999-999999999999")!
        let rejectedResponse = try jsonString([
            "id": 2,
            "error": ["code": -32_000, "message": "rejected"],
        ])
        let acceptedResponse = try jsonString([
            "id": 3,
            "result": ["queuedSubmission": [
                "id": "explicit-retry-receipt",
                "clientUserMessageId": secondSubmissionID.uuidString.lowercased(),
            ]],
        ])
        let fixture = try FakeCodexAppServer(behavior: """
        record_line
        printf '%s\n' '{"id":1,"result":{}}'
        record_line
        record_line
        printf '%s\n' \(shellQuote(rejectedResponse))
        record_line
        printf '%s\n' \(shellQuote(acceptedResponse))
        record_line
        """)
        defer { fixture.remove() }

        let client = CodexAppServerClient(executableURL: fixture.executableURL)
        await assertClientError(.serverRejected) {
            try await client.queueMessage(
                threadID: threadID,
                message: "must not replay",
                submissionID: firstSubmissionID
            )
        }
        XCTAssertEqual(fixture.launchCount(), 1, "a rejected side effect must not auto-replay")

        let receipt = try await client.queueMessage(
            threadID: threadID,
            message: "explicit later request",
            submissionID: secondSubmissionID
        )
        XCTAssertEqual(receipt.queuedSubmissionID, "explicit-retry-receipt")
        XCTAssertEqual(fixture.launchCount(), 1)
    }

    func testModelListAudioCapabilityProbeReturnsOnlyStructuredCapability() async throws {
        let modelResponse = try jsonString([
            "id": 2,
            "result": [
                "data": [
                    ["id": "text-model", "inputModalities": ["text", "image"]],
                    ["id": "audio-model", "inputModalities": ["text", "audio"]],
                ],
                "nextCursor": NSNull(),
            ],
        ])
        let fixture = try FakeCodexAppServer(behavior: """
        record_line
        printf '%s\n' '{"id":1,"result":{}}'
        record_line
        record_line
        printf '%s\n' \(shellQuote(modelResponse))
        record_line
        """)
        defer { fixture.remove() }

        let capability = try await CodexAppServerClient(executableURL: fixture.executableURL)
            .probeAudioInputCapability()

        XCTAssertEqual(
            capability,
            CodexModelAudioInputCapability(
                supportsAudioInput: true,
                checkedModelCount: 2
            )
        )
        let request = try XCTUnwrap(try fixture.inputObjects().last)
        XCTAssertEqual(request["method"] as? String, "model/list")
        let params = try XCTUnwrap(request["params"] as? [String: Any])
        XCTAssertEqual((params["limit"] as? NSNumber)?.intValue, 100)
        XCTAssertEqual(params["includeHidden"] as? Bool, false)
        XCTAssertNil(params["cursor"])
        XCTAssertFalse(String(describing: capability).contains("audio-model"))
    }

    func testPersistentLedgerSurvivesRestartWithoutTranscriptOrWorkspacePath() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspaceURL = directoryURL.appendingPathComponent("private-workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let ledgerURL = directoryURL.appendingPathComponent("ledger.json")
        let requestID = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
        let submissionID = UUID(uuidString: "66666666-6666-4666-8666-666666666666")!
        let privateMessage = "这段私有语音绝不能写入 ledger"
        let startResponse = try jsonString([
            "id": 2,
            "result": ["thread": [
                "id": threadID,
                "name": "Private request",
                "cwd": workspaceURL.resolvingSymlinksInPath().path,
                "forkedFromId": NSNull(),
                "parentThreadId": NSNull(),
                "projectId": NSNull(),
                "status": ["type": "idle"],
                "canAcceptDirectInput": true,
                "updatedAt": 5678,
            ]],
        ])
        let queueResponse = try jsonString([
            "id": 3,
            "result": ["queuedSubmission": [
                "id": "persistent-queue-receipt",
                "clientUserMessageId": submissionID.uuidString.lowercased(),
                "input": [["type": "text", "text": privateMessage]],
            ]],
        ])
        let fixture = try FakeCodexAppServer(behavior: """
        record_line
        printf '%s\n' '{"id":1,"result":{}}'
        record_line
        record_line
        printf '%s\n' \(shellQuote(startResponse))
        record_line
        printf '%s\n' \(shellQuote(queueResponse))
        """)
        defer { fixture.remove() }
        let descriptor = CodexWorkspaceDescriptor(
            id: "private-workspace",
            displayName: "Private Workspace",
            directoryURL: workspaceURL
        )
        let request = CodexNewConversationSubmission(
            requestID: requestID,
            submissionID: submissionID,
            workspaceID: descriptor.id,
            message: privateMessage
        )

        let firstService = try CodexConversationService(
            client: CodexAppServerClient(executableURL: fixture.executableURL),
            workspaces: [descriptor],
            fingerprintKey: fingerprintKey,
            ledger: CodexConversationIdempotencyLedger(fileURL: ledgerURL)
        )
        let first = try await firstService.createConversationAndSubmit(request)
        XCTAssertEqual(fixture.launchCount(), 1)

        let persisted = String(decoding: try Data(contentsOf: ledgerURL), as: UTF8.self)
        XCTAssertFalse(persisted.contains(privateMessage))
        XCTAssertFalse(persisted.contains(workspaceURL.path))
        let attributes = try FileManager.default.attributesOfItem(atPath: ledgerURL.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
        XCTAssertEqual(permissions & 0o777, 0o600)

        let restartedService = try CodexConversationService(
            client: CodexAppServerClient(executableURL: fixture.executableURL),
            workspaces: [descriptor],
            fingerprintKey: fingerprintKey,
            ledger: CodexConversationIdempotencyLedger(fileURL: ledgerURL)
        )
        let restored = try await restartedService.createConversationAndSubmit(request)
        XCTAssertEqual(restored.receipt, first.receipt)
        XCTAssertEqual(fixture.launchCount(), 1)

        let conflicting = CodexNewConversationSubmission(
            requestID: requestID,
            submissionID: submissionID,
            workspaceID: descriptor.id,
            message: "不同内容"
        )
        await assertServiceError(.idempotencyConflict) {
            try await restartedService.createConversationAndSubmit(conflicting)
        }

        let preparedURL = directoryURL.appendingPathComponent("prepared.json")
        let preparedLedger = CodexConversationIdempotencyLedger(fileURL: preparedURL)
        let preparedFingerprint = String(repeating: "a", count: 64)
        let preparedRequestID = UUID()
        let preparedSubmissionID = UUID()
        let preparedBeginResult = try await preparedLedger.beginNew(
            requestID: preparedRequestID,
            submissionID: preparedSubmissionID,
            fingerprint: preparedFingerprint
        )
        XCTAssertEqual(preparedBeginResult, .new)
        let restartedPreparedLedger = CodexConversationIdempotencyLedger(fileURL: preparedURL)
        let restartedBeginResult = try await restartedPreparedLedger.beginNew(
            requestID: preparedRequestID,
            submissionID: preparedSubmissionID,
            fingerprint: preparedFingerprint
        )
        XCTAssertEqual(restartedBeginResult, .unknownAfterSideEffect)
    }

    func testCompletedSubmissionCacheUsesDeterministicBoundedFIFO() {
        let firstID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let secondID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        let thirdID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
        var cache = CodexConversationCompletedSubmissionCache<String>(maximumCount: 2)

        cache.insert(submissionID: firstID, fingerprint: "first", value: "one")
        cache.insert(submissionID: secondID, fingerprint: "second", value: "two")
        cache.insert(submissionID: firstID, fingerprint: "first-updated", value: "ONE")
        cache.insert(submissionID: thirdID, fingerprint: "third", value: "three")

        XCTAssertEqual(cache.count, 2)
        XCTAssertNil(cache.entry(for: firstID))
        XCTAssertEqual(cache.entry(for: secondID)?.value, "two")
        XCTAssertEqual(cache.entry(for: thirdID)?.value, "three")
    }

    func testIdempotencyLedgerEvictsOnlyOldestCompletedRecords() async throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "CodexIdempotencyLedgerEviction-" + UUID().uuidString,
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let fileURL = rootURL.appendingPathComponent("ledger.json")
        let limits = CodexConversationIdempotencyLedger.Limits(
            maximumRecordCount: 3,
            maximumFileBytes: 16 * 1_024
        )
        let ledger = CodexConversationIdempotencyLedger(
            fileURL: fileURL,
            limits: limits
        )
        let firstID = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
        let uncertainID = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
        let secondID = UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!
        let thirdID = UUID(uuidString: "dddddddd-dddd-4ddd-8ddd-dddddddddddd")!
        let firstFingerprint = String(repeating: "a", count: 64)
        let uncertainFingerprint = String(repeating: "b", count: 64)
        let secondFingerprint = String(repeating: "c", count: 64)
        let thirdFingerprint = String(repeating: "d", count: 64)
        let firstReceipt = CodexConversationQueueReceipt(
            submissionID: firstID,
            threadID: threadID,
            queuedSubmissionID: "queue-first"
        )
        let secondReceipt = CodexConversationQueueReceipt(
            submissionID: secondID,
            threadID: threadID,
            queuedSubmissionID: "queue-second"
        )
        let thirdReceipt = CodexConversationQueueReceipt(
            submissionID: thirdID,
            threadID: threadID,
            queuedSubmissionID: "queue-third"
        )

        let firstBegin = try await ledger.beginExisting(
            submissionID: firstID,
            fingerprint: firstFingerprint
        )
        XCTAssertEqual(firstBegin, .new)
        try await ledger.complete(
            submissionID: firstID,
            fingerprint: firstFingerprint,
            receipt: firstReceipt
        )
        let uncertainBegin = try await ledger.beginExisting(
            submissionID: uncertainID,
            fingerprint: uncertainFingerprint
        )
        XCTAssertEqual(uncertainBegin, .new)
        await ledger.finishWithoutReceipt(
            submissionID: uncertainID,
            fingerprint: uncertainFingerprint
        )
        let secondBegin = try await ledger.beginExisting(
            submissionID: secondID,
            fingerprint: secondFingerprint
        )
        XCTAssertEqual(secondBegin, .new)
        try await ledger.complete(
            submissionID: secondID,
            fingerprint: secondFingerprint,
            receipt: secondReceipt
        )
        let thirdBegin = try await ledger.beginExisting(
            submissionID: thirdID,
            fingerprint: thirdFingerprint
        )
        XCTAssertEqual(thirdBegin, .new)
        try await ledger.complete(
            submissionID: thirdID,
            fingerprint: thirdFingerprint,
            receipt: thirdReceipt
        )

        let data = try Data(contentsOf: fileURL)
        XCTAssertLessThanOrEqual(data.count, limits.maximumFileBytes)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual((object["version"] as? NSNumber)?.intValue, 1)
        let persistedRecords = try XCTUnwrap(object["records"] as? [[String: Any]])
        XCTAssertEqual(persistedRecords.count, 3)
        let persistedIDs = Set(persistedRecords.compactMap {
            ($0["submissionID"] as? String)?.lowercased()
        })
        XCTAssertFalse(persistedIDs.contains(firstID.uuidString.lowercased()))
        XCTAssertTrue(persistedIDs.contains(uncertainID.uuidString.lowercased()))
        XCTAssertTrue(persistedIDs.contains(secondID.uuidString.lowercased()))
        XCTAssertTrue(persistedIDs.contains(thirdID.uuidString.lowercased()))

        let fileAttributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let filePermissions = try XCTUnwrap(
            fileAttributes[.posixPermissions] as? NSNumber
        ).intValue
        XCTAssertEqual(filePermissions & 0o777, 0o600)
        let directoryAttributes = try FileManager.default.attributesOfItem(
            atPath: rootURL.path
        )
        let directoryPermissions = try XCTUnwrap(
            directoryAttributes[.posixPermissions] as? NSNumber
        ).intValue
        XCTAssertEqual(directoryPermissions & 0o777, 0o700)

        let restarted = CodexConversationIdempotencyLedger(
            fileURL: fileURL,
            limits: limits
        )
        let restartedUncertain = try await restarted.beginExisting(
            submissionID: uncertainID,
            fingerprint: uncertainFingerprint
        )
        XCTAssertEqual(restartedUncertain, .unknownAfterSideEffect)
        let restartedSecond = try await restarted.beginExisting(
            submissionID: secondID,
            fingerprint: secondFingerprint
        )
        XCTAssertEqual(restartedSecond, .completed(secondReceipt))
        let restartedThird = try await restarted.beginExisting(
            submissionID: thirdID,
            fingerprint: thirdFingerprint
        )
        XCTAssertEqual(restartedThird, .completed(thirdReceipt))
    }

    func testIdempotencyLedgerFailsClosedWhenAllCapacityIsUncertain() async throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "CodexIdempotencyLedgerPending-" + UUID().uuidString,
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let fileURL = rootURL.appendingPathComponent("ledger.json")
        let limits = CodexConversationIdempotencyLedger.Limits(
            maximumRecordCount: 2,
            maximumFileBytes: 16 * 1_024
        )
        let ledger = CodexConversationIdempotencyLedger(
            fileURL: fileURL,
            limits: limits
        )
        let firstID = UUID(uuidString: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee")!
        let secondID = UUID(uuidString: "ffffffff-ffff-4fff-8fff-ffffffffffff")!
        let rejectedID = UUID(uuidString: "99999999-9999-4999-8999-999999999999")!
        let firstFingerprint = String(repeating: "e", count: 64)
        let secondFingerprint = String(repeating: "f", count: 64)
        let rejectedFingerprint = String(repeating: "9", count: 64)

        let firstBegin = try await ledger.beginExisting(
            submissionID: firstID,
            fingerprint: firstFingerprint
        )
        XCTAssertEqual(firstBegin, .new)
        await ledger.finishWithoutReceipt(
            submissionID: firstID,
            fingerprint: firstFingerprint
        )
        let secondBegin = try await ledger.beginExisting(
            submissionID: secondID,
            fingerprint: secondFingerprint
        )
        XCTAssertEqual(secondBegin, .new)
        await ledger.finishWithoutReceipt(
            submissionID: secondID,
            fingerprint: secondFingerprint
        )
        await assertServiceError(.idempotencyLedgerUnavailable) {
            try await ledger.beginExisting(
                submissionID: rejectedID,
                fingerprint: rejectedFingerprint
            )
        }

        let restarted = CodexConversationIdempotencyLedger(
            fileURL: fileURL,
            limits: limits
        )
        let restartedFirst = try await restarted.beginExisting(
            submissionID: firstID,
            fingerprint: firstFingerprint
        )
        XCTAssertEqual(restartedFirst, .unknownAfterSideEffect)
        let restartedSecond = try await restarted.beginExisting(
            submissionID: secondID,
            fingerprint: secondFingerprint
        )
        XCTAssertEqual(restartedSecond, .unknownAfterSideEffect)

        let tooSmallURL = rootURL.appendingPathComponent("too-small.json")
        let tooSmall = CodexConversationIdempotencyLedger(
            fileURL: tooSmallURL,
            limits: .init(maximumRecordCount: 2, maximumFileBytes: 64)
        )
        await assertServiceError(.idempotencyLedgerUnavailable) {
            try await tooSmall.beginExisting(
                submissionID: rejectedID,
                fingerprint: rejectedFingerprint
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: tooSmallURL.path))
    }

    func testTimeoutOversizedOutputAndServerDetailsFailClosed() async throws {
        let timeoutFixture = try FakeCodexAppServer(behavior: """
        record_line
        sleep 2
        """)
        defer { timeoutFixture.remove() }
        let timeoutClient = CodexAppServerClient(
            executableURL: timeoutFixture.executableURL,
            limits: .init(
                responseTimeoutSeconds: 0.1,
                maximumLineBytes: 128,
                maximumStandardOutputBytes: 512,
                maximumStandardErrorBytes: 128,
                maximumMessageBytes: 1_024
            )
        )
        await assertClientError(.processTimedOut) {
            try await timeoutClient.listThreads()
        }

        let oversizedLine = String(repeating: "x", count: 300)
        let oversizedFixture = try FakeCodexAppServer(behavior: """
        record_line
        printf '%s\n' '{"id":1,"result":{}}'
        record_line
        record_line
        printf '%s\n' \(shellQuote(oversizedLine))
        """)
        defer { oversizedFixture.remove() }
        let oversizedClient = CodexAppServerClient(
            executableURL: oversizedFixture.executableURL,
            limits: .init(
                responseTimeoutSeconds: 1,
                maximumLineBytes: 128,
                maximumStandardOutputBytes: 512,
                maximumStandardErrorBytes: 128,
                maximumMessageBytes: 1_024
            )
        )
        await assertClientError(.outputTooLarge) {
            try await oversizedClient.listThreads()
        }

        let privateServerDetail = "private transcript and /example/secret"
        let errorResponse = try jsonString([
            "id": 2,
            "error": ["code": -32_000, "message": privateServerDetail],
        ])
        let errorFixture = try FakeCodexAppServer(behavior: """
        record_line
        printf '%s\n' '{"id":1,"result":{}}'
        record_line
        record_line
        printf '%s\n' \(shellQuote(errorResponse))
        printf '%s\n' \(shellQuote(privateServerDetail)) >&2
        """)
        defer { errorFixture.remove() }
        let errorClient = CodexAppServerClient(executableURL: errorFixture.executableURL)
        do {
            _ = try await errorClient.listThreads()
            XCTFail("Expected server rejection")
        } catch {
            XCTAssertEqual(error as? CodexAppServerClientError, .serverRejected)
            XCTAssertFalse(error.localizedDescription.contains(privateServerDetail))
            XCTAssertFalse(error.localizedDescription.contains("/example/secret"))
        }
    }

    private func assertClientError<T>(
        _ expected: CodexAppServerClientError,
        operation: () async throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? CodexAppServerClientError, expected, file: file, line: line)
        }
    }

    private func assertServiceError<T>(
        _ expected: CodexConversationServiceError,
        operation: () async throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? CodexConversationServiceError, expected, file: file, line: line)
        }
    }
}

private struct FakeCodexAppServer {
    let directoryURL: URL
    let executableURL: URL
    let argumentsURL: URL
    let inputURL: URL
    let launchesURL: URL
    let processIDsURL: URL

    init(behavior: String) throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        executableURL = directoryURL.appendingPathComponent("fake-codex")
        argumentsURL = directoryURL.appendingPathComponent("arguments.txt")
        inputURL = directoryURL.appendingPathComponent("input.jsonl")
        launchesURL = directoryURL.appendingPathComponent("launches.txt")
        processIDsURL = directoryURL.appendingPathComponent("process-ids.txt")

        let script = """
        #!/bin/sh
        printf '%s\n' "$@" > \(shellQuote(argumentsURL.path))
        printf 'launch\n' >> \(shellQuote(launchesURL.path))
        printf '%s\n' "$$" >> \(shellQuote(processIDsURL.path))
        WRIST_LAUNCH_NUMBER=$(wc -l < \(shellQuote(launchesURL.path)))
        : > \(shellQuote(inputURL.path))
        record_line() {
          IFS= read -r line || exit 91
          printf '%s\n' "$line" >> \(shellQuote(inputURL.path))
        }
        \(behavior)
        """
        try Data(script.utf8).write(to: executableURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: executableURL.path
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }

    func arguments() -> [String] {
        lines(at: argumentsURL)
    }

    func launchCount() -> Int {
        lines(at: launchesURL).count
    }

    func inputObjects() throws -> [[String: Any]] {
        try lines(at: inputURL).map { line in
            let object = try JSONSerialization.jsonObject(with: Data(line.utf8))
            guard let dictionary = object as? [String: Any] else {
                throw CodexAppServerClientError.invalidProtocolResponse
            }
            return dictionary
        }
    }

    func isMostRecentProcessRunning(afterDelayMilliseconds delay: UInt32 = 0) -> Bool {
        if delay > 0 {
            usleep(delay * 1_000)
        }
        guard let rawProcessID = lines(at: processIDsURL).last,
              let processID = Int32(rawProcessID)
        else { return false }
        return Darwin.kill(processID, 0) == 0
    }

    private func lines(at url: URL) -> [String] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
    }
}

private func jsonString(_ object: Any) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
}

private func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
}
