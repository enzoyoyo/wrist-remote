import XCTest
@testable import WristRemote

final class WristInternetRelayProtocolTests: XCTestCase {
    private let key = Data(repeating: 0x2A, count: 32)

    func testEncryptedFrameRoundTripsAndAuthenticatesHeader() throws {
        let operation = WristInternetRelayOperation(
            kind: .buttonEvent,
            profileRevision: 7,
            command: .ok,
            buttonTrigger: .singleClick,
            buttonCommittedAtEpochMilliseconds: 1_000
        )
        let frame = try WristInternetRelayFrame.seal(
            operation,
            operationID: operation.operationID,
            senderID: UUID(),
            sequence: 9,
            direction: .deviceToMac,
            keyData: key
        )

        let opened = try frame.open(
            WristInternetRelayOperation.self,
            direction: .deviceToMac,
            operationID: operation.operationID,
            keyData: key
        )
        XCTAssertEqual(opened, operation)

        let tampered = WristInternetRelayFrame(
            protocolVersion: frame.protocolVersion,
            operationID: frame.operationID,
            senderID: frame.senderID,
            sequence: frame.sequence + 1,
            issuedAtEpochMilliseconds: frame.issuedAtEpochMilliseconds,
            expiresAtEpochMilliseconds: frame.expiresAtEpochMilliseconds,
            direction: frame.direction,
            ciphertext: frame.ciphertext
        )
        XCTAssertThrowsError(try tampered.open(
            WristInternetRelayOperation.self,
            direction: .deviceToMac,
            operationID: operation.operationID,
            keyData: key
        ))
    }

    func testReplayWindowRejectsDuplicateAndOlderFrames() throws {
        let sender = UUID()
        let operation = WristInternetRelayOperation(kind: .status)
        let first = try WristInternetRelayFrame.seal(
            operation,
            operationID: operation.operationID,
            senderID: sender,
            sequence: 10,
            direction: .deviceToMac,
            keyData: key
        )
        let older = try WristInternetRelayFrame.seal(
            operation,
            operationID: operation.operationID,
            senderID: sender,
            sequence: 9,
            direction: .deviceToMac,
            keyData: key
        )

        var window = WristInternetReplayWindow()
        XCTAssertTrue(window.accept(first, direction: .deviceToMac))
        XCTAssertFalse(window.accept(first, direction: .deviceToMac))
        XCTAssertFalse(window.accept(older, direction: .deviceToMac))
    }

    func testExpiredAndWrongDirectionFramesFailClosed() throws {
        let operation = WristInternetRelayOperation(kind: .status)
        let issuedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let frame = try WristInternetRelayFrame.seal(
            operation,
            operationID: operation.operationID,
            senderID: UUID(),
            sequence: 1,
            direction: .deviceToMac,
            keyData: key,
            now: issuedAt,
            lifetimeMilliseconds: 1_000
        )

        XCTAssertThrowsError(try frame.open(
            WristInternetRelayOperation.self,
            direction: .macToDevice,
            operationID: operation.operationID,
            keyData: key,
            now: issuedAt
        ))
        XCTAssertThrowsError(try frame.open(
            WristInternetRelayOperation.self,
            direction: .deviceToMac,
            operationID: operation.operationID,
            keyData: key,
            now: issuedAt.addingTimeInterval(40)
        ))
    }

    func testOperationsRejectUnexpectedFields() {
        XCTAssertNotNil(WristInternetRelayOperation(kind: .status).validated())
        XCTAssertNil(WristInternetRelayOperation(
            kind: .status,
            transcript: "unexpected"
        ).validated())
        XCTAssertNotNil(WristInternetRelayOperation(
            kind: .buttonEvent,
            profileRevision: 2,
            command: .home,
            buttonTrigger: .doubleClick,
            buttonCommittedAtEpochMilliseconds: 1_000
        ).validated())
        XCTAssertNil(WristInternetRelayOperation(
            kind: .buttonEvent,
            profileRevision: 2,
            command: .home,
            buttonTrigger: .longPress,
            buttonCommittedAtEpochMilliseconds: 1_000,
            submissionID: UUID()
        ).validated())
    }

    func testProvisioningEncodingDoesNotAcceptInvalidTransport() throws {
        let valid = WristInternetRelayDeviceProvisioning(
            baseURL: try XCTUnwrap(URL(string: "https://relay.example")),
            roomID: UUID(),
            deviceID: UUID(),
            deviceToken: Data(repeating: 1, count: 32),
            encryptionKey: Data(repeating: 2, count: 32)
        )
        XCTAssertEqual(
            WristInternetRelayDeviceProvisioning.decodeBase64(
                try XCTUnwrap(valid.encodedBase64())
            ),
            valid
        )

        let invalid = WristInternetRelayDeviceProvisioning(
            baseURL: try XCTUnwrap(URL(string: "http://relay.example")),
            roomID: UUID(),
            deviceID: UUID(),
            deviceToken: Data(repeating: 1, count: 32),
            encryptionKey: Data(repeating: 2, count: 32)
        )
        XCTAssertFalse(invalid.isValid)
        XCTAssertNil(invalid.encodedBase64())

        let placeholder = WristInternetRelayDeviceProvisioning(
            baseURL: try XCTUnwrap(URL(string: "https://relay.example.invalid")),
            roomID: UUID(),
            deviceID: UUID(),
            deviceToken: Data(repeating: 1, count: 32),
            encryptionKey: Data(repeating: 2, count: 32)
        )
        XCTAssertFalse(placeholder.isValid)
        XCTAssertNil(placeholder.encodedBase64())
    }

    func testOperationalRelayURLRejectsInvalidSentinelWithRepeatedTrailingDots() throws {
        for trailingDotCount in 2...3 {
            let rawValue = "https://relay.example.invalid"
                + String(repeating: ".", count: trailingDotCount)
            let baseURL = try XCTUnwrap(URL(string: rawValue))
            XCTAssertFalse(
                WristInternetRelayConfiguration.isOperationalBaseURL(baseURL),
                rawValue
            )
        }
    }

    func testInternetAudioBatchingAdaptsToBacklogAndFinalTail() {
        XCTAssertFalse(WristInternetAudioBatchingPolicy.shouldFlush(
            bufferedPacketCount: 4,
            isFinal: false
        ))
        XCTAssertTrue(WristInternetAudioBatchingPolicy.shouldFlush(
            bufferedPacketCount: 5,
            isFinal: false
        ))
        XCTAssertTrue(WristInternetAudioBatchingPolicy.shouldFlush(
            bufferedPacketCount: 1,
            isFinal: true
        ))
        XCTAssertEqual(
            WristInternetAudioBatchingPolicy.nextPacketCount(bufferedPacketCount: 7),
            7
        )
        XCTAssertEqual(
            WristInternetAudioBatchingPolicy.nextPacketCount(bufferedPacketCount: 18),
            10
        )
        XCTAssertTrue(WristInternetAudioBatchingPolicy.canBuffer(packetCount: 350))
        XCTAssertFalse(WristInternetAudioBatchingPolicy.canBuffer(packetCount: 351))
    }

    func testInternetVoiceFinalTimeoutScalesWithUnacknowledgedBacklog() {
        XCTAssertEqual(
            WristInternetAudioBatchingPolicy.finalAckTimeoutMilliseconds(
                sentPacketCount: 5,
                contiguousAcknowledgement: 4
            ),
            20_000
        )
        XCTAssertEqual(
            WristInternetAudioBatchingPolicy.finalAckTimeoutMilliseconds(
                sentPacketCount: 35,
                contiguousAcknowledgement: 4
            ),
            86_000
        )
        XCTAssertEqual(
            WristInternetAudioBatchingPolicy.finalAckTimeoutMilliseconds(
                sentPacketCount: 10_000,
                contiguousAcknowledgement: nil
            ),
            WristInternetAudioBatchingPolicy.maximumFinalAckTimeoutMilliseconds
        )
        XCTAssertEqual(WristInternetAudioBatchingPolicy.maximumPendingBatchCount, 36)
        XCTAssertEqual(
            WristInternetAudioBatchingPolicy.maximumFinalAckTimeoutMilliseconds,
            812_000
        )
    }

    func testInternetButtonQueueIsBoundedAndDropsStaleEvents() {
        XCTAssertTrue(WristInternetButtonQueuePolicy.canEnqueue(
            pendingEventCount: WristInternetButtonQueuePolicy.maximumPendingEventCount - 1
        ))
        XCTAssertFalse(WristInternetButtonQueuePolicy.canEnqueue(
            pendingEventCount: WristInternetButtonQueuePolicy.maximumPendingEventCount
        ))

        let committedAt = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(WristInternetButtonQueuePolicy.isFresh(
            committedAt: committedAt,
            now: committedAt.addingTimeInterval(2.999)
        ))
        XCTAssertFalse(WristInternetButtonQueuePolicy.isFresh(
            committedAt: committedAt,
            now: committedAt.addingTimeInterval(3.001)
        ))
    }

    func testPublicRelayBudgetsStayOrdered() {
        XCTAssertEqual(WristInternetRelayConfiguration.protocolVersion, 3)
        XCTAssertTrue(WristInternetRelayConfiguration.supportsServerProtocolVersion(3))
        XCTAssertFalse(WristInternetRelayConfiguration.supportsServerProtocolVersion(2))
        XCTAssertGreaterThan(
            WristInternetVoiceLeasePolicy.timeoutMilliseconds,
            WristInternetRelayRequestBudget.timeoutMilliseconds * 2
        )
        XCTAssertGreaterThan(
            WristInternetVoiceStartPolicy.replyTimeoutMilliseconds,
            WristInternetRelayRequestBudget.timeoutMilliseconds * 2
        )
        let voiceOutcomePollingWindow =
            WristInternetVoiceOutcomePollingPolicy.attemptCount
                * WristInternetVoiceOutcomePollingPolicy.intervalMilliseconds
        XCTAssertGreaterThan(
            voiceOutcomePollingWindow,
            WristInternetRelayRequestBudget.timeoutMilliseconds
        )
        XCTAssertGreaterThanOrEqual(
            voiceOutcomePollingWindow,
            WristInternetVoiceOutcomePollingPolicy.timeoutMilliseconds
        )
        XCTAssertGreaterThanOrEqual(
            WristInternetAudioBatchingPolicy.maximumFinalAckTimeoutMilliseconds,
            WristInternetAudioBatchingPolicy.baseFinalAckTimeoutMilliseconds
                + WristInternetAudioBatchingPolicy.maximumPendingBatchCount
                    * WristInternetRelayRequestBudget.timeoutMilliseconds
        )
    }

    func testVoiceBusyProfileRetryIsExplicitAndBounded() throws {
        let operationID = UUID()
        let busy = WristInternetRelayResult(
            operationID: operationID,
            accepted: false,
            detail: "voice busy",
            profileUpdateRetryReason: .voiceActive
        )
        XCTAssertTrue(busy.isValid(for: operationID))
        XCTAssertEqual(
            try JSONDecoder().decode(
                WristInternetRelayResult.self,
                from: JSONEncoder().encode(busy)
            ),
            busy
        )
        XCTAssertFalse(WristInternetRelayResult(
            operationID: operationID,
            accepted: true,
            profileUpdateRetryReason: .voiceActive
        ).isValid(for: operationID))

        XCTAssertEqual(
            WatchProfileBusyRetryPolicy.delayMilliseconds(afterFailureCount: 0),
            2_000
        )
        XCTAssertEqual(
            WatchProfileBusyRetryPolicy.delayMilliseconds(
                afterFailureCount: WatchProfileBusyRetryPolicy.fastAttemptCount - 1
            ),
            2_000
        )
        XCTAssertEqual(
            WatchProfileBusyRetryPolicy.delayMilliseconds(
                afterFailureCount: WatchProfileBusyRetryPolicy.fastAttemptCount
            ),
            30_000
        )
        XCTAssertEqual(
            WatchProfileBusyRetryPolicy.delayMilliseconds(
                afterFailureCount: WatchProfileBusyRetryPolicy.maximumAttemptCount - 1
            ),
            30_000
        )
        XCTAssertNil(WatchProfileBusyRetryPolicy.delayMilliseconds(
            afterFailureCount: WatchProfileBusyRetryPolicy.maximumAttemptCount
        ))
        XCTAssertNil(WatchProfileBusyRetryPolicy.delayMilliseconds(afterFailureCount: -1))
        XCTAssertTrue(WatchProfileBusyRetryPolicy.shouldSchedule(
            isForeground: true,
            hasValidConnection: true
        ))
        XCTAssertFalse(WatchProfileBusyRetryPolicy.shouldSchedule(
            isForeground: false,
            hasValidConnection: true
        ))
        XCTAssertFalse(WatchProfileBusyRetryPolicy.shouldSchedule(
            isForeground: true,
            hasValidConnection: false
        ))
    }

    func testButtonCommitDeadlineIsCheckedIndependentlyOfFrameIssueTime() {
        let operation = WristInternetRelayOperation(
            kind: .buttonEvent,
            profileRevision: 7,
            command: .ok,
            buttonTrigger: .singleClick,
            buttonCommittedAtEpochMilliseconds: 1_000_000
        )
        XCTAssertTrue(operation.hasFreshButtonCommit(
            now: Date(timeIntervalSince1970: 1_002.999)
        ))
        XCTAssertFalse(operation.hasFreshButtonCommit(
            now: Date(timeIntervalSince1970: 1_003.001)
        ))

        let tooFarInFuture = WristInternetRelayOperation(
            kind: .buttonEvent,
            profileRevision: 7,
            command: .ok,
            buttonTrigger: .singleClick,
            buttonCommittedAtEpochMilliseconds: 1_003_000
        )
        XCTAssertFalse(tooFarInFuture.hasFreshButtonCommit(
            now: Date(timeIntervalSince1970: 1_000)
        ))
    }
}
