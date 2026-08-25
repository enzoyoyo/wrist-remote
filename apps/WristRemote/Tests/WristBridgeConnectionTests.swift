#if os(iOS)
import Security
import XCTest
@testable import WristRemote

@MainActor
final class WristBridgeConnectionTests: XCTestCase {
    func testTransportIdentityIsDedicatedToWristRemoteBridge() {
        XCTAssertEqual(WristBridgeWireMessage.serviceType, "_wristremote._tcp")
        XCTAssertEqual(
            WristBridgeWireMessage.sessionSalt,
            "WristRemoteBridge nearby session"
        )
        XCTAssertEqual(
            WristBridgeWireMessage.identityProofDomain,
            "WristRemoteBridge nearby identity v1"
        )
        XCTAssertFalse(WristBridgeWireMessage.sessionSalt.contains("Unrelated nearby"))
    }

    func testServerIdentityAndCapabilitiesMustMatchExactly() {
        let valid = WristBridgeWireMessage(
            type: "ready",
            protocolID: WristBridgeWireMessage.protocolID,
            serverRole: WristBridgeWireMessage.serverRole
        )
        XCTAssertTrue(WristBridgeConnection.acceptsServerIdentity(valid))

        var wrongRole = valid
        wrongRole.serverRole = "nearbyPhoneServer"
        XCTAssertFalse(WristBridgeConnection.acceptsServerIdentity(wrongRole))

        XCTAssertTrue(WristBridgeConnection.acceptsCapabilities([
            WristBridgeWireMessage.voiceSessionsCapability,
            WristBridgeWireMessage.watchActionProfileCapability,
            WristBridgeWireMessage.codexTasksCapability,
            WristBridgeWireMessage.voiceOutcomesCapability,
            WristBridgeWireMessage.codexReplyReceiptsCapability,
            WristBridgeWireMessage.connectionLivenessCapability,
        ]))
        XCTAssertFalse(WristBridgeConnection.acceptsCapabilities([
            WristBridgeWireMessage.voiceSessionsCapability,
            WristBridgeWireMessage.watchActionProfileCapability,
            WristBridgeWireMessage.codexTasksCapability,
            WristBridgeWireMessage.voiceOutcomesCapability,
            WristBridgeWireMessage.codexReplyReceiptsCapability,
        ]))
        XCTAssertFalse(WristBridgeConnection.acceptsCapabilities([
            WristBridgeWireMessage.voiceSessionsCapability,
            WristBridgeWireMessage.watchActionProfileCapability,
            WristBridgeWireMessage.voiceOutcomesCapability,
        ]))
    }

    func testWatchProfileUpdateCarriesExactRevisionAndSource() throws {
        let profile = WatchActionProfileStore.defaultProfile(revision: 17)
        let message = try XCTUnwrap(WristBridgeConnection.profileUpdateMessage(profile))
        XCTAssertEqual(message.type, "watchProfileUpdate")
        XCTAssertEqual(message.inputSource, "appleWatch")
        XCTAssertEqual(message.profileRevision, 17)
        XCTAssertEqual(
            try WatchActionProfileWire.decodeBase64(try XCTUnwrap(message.watchProfile)),
            profile
        )
    }

    func testProfileBusyRejectionCarriesTypedRetryReason() throws {
        let message = WristBridgeWireMessage(
            type: "watchProfileRejected",
            detail: "voice busy",
            profileRevision: 17,
            profileUpdateRetryReason: .voiceActive
        )
        let roundTrip = try JSONDecoder().decode(
            WristBridgeWireMessage.self,
            from: JSONEncoder().encode(message)
        )
        XCTAssertEqual(roundTrip.profileUpdateRetryReason, .voiceActive)
        XCTAssertEqual(roundTrip.profileRevision, 17)
    }

    func testVoiceFramesCarryExactSourceRevisionAndSession() throws {
        let sessionID = UUID().uuidString
        let message = try XCTUnwrap(WristBridgeConnection.voiceMessage(
            type: "audio",
            sessionID: sessionID,
            profileRevision: 8,
            samples: Data([0, 0]).base64EncodedString()
        ))
        XCTAssertEqual(message.inputSource, "appleWatch")
        XCTAssertEqual(message.profileRevision, 8)
        XCTAssertEqual(message.sessionID, sessionID)
        XCTAssertEqual(message.voiceIntent, WatchVoiceIntent.foregroundDictation.rawValue)
        XCTAssertNil(message.threadID)
        var partialForeground = message
        partialForeground.threadID = "thr_partial"
        XCTAssertNil(WristBridgeConnection.wireCodexTaskIdentity(from: partialForeground))
        XCTAssertTrue(WristBridgeConnection.hasWireCodexTaskIdentityFields(partialForeground))

        let identity = try XCTUnwrap(WatchCodexTaskIdentity(
            threadID: "thr_voice_123",
            turnID: "turn_voice_123",
            revision: 21
        ))
        let codexStart = try XCTUnwrap(WristBridgeConnection.voiceMessage(
            type: "voiceStart",
            sessionID: sessionID,
            profileRevision: 8,
            intent: .codexTask,
            codexTaskIdentity: identity
        ))
        XCTAssertEqual(codexStart.voiceIntent, WatchVoiceIntent.codexTask.rawValue)
        XCTAssertEqual(codexStart.threadID, identity.threadID)
        XCTAssertEqual(codexStart.turnID, identity.turnID)
        XCTAssertEqual(codexStart.taskRevision, identity.revision)
        XCTAssertNil(codexStart.samples)

        XCTAssertNil(WristBridgeConnection.voiceMessage(
            type: "voiceStart",
            sessionID: "not-a-uuid",
            profileRevision: 8
        ))
        XCTAssertNil(WristBridgeConnection.voiceMessage(
            type: "voiceStart",
            sessionID: sessionID,
            profileRevision: 8,
            intent: .codexTask
        ))
        XCTAssertNil(WristBridgeConnection.voiceMessage(
            type: "voiceStop",
            sessionID: sessionID,
            profileRevision: 8,
            intent: .foregroundDictation,
            codexTaskIdentity: identity
        ))
        XCTAssertNil(WristBridgeConnection.voiceMessage(
            type: "audio",
            sessionID: sessionID,
            profileRevision: 8,
            intent: .codexTask,
            codexTaskIdentity: identity
        ))
    }

    func testCodexVoiceTargetsRequireTheExactCompletedTurnAndRevision() throws {
        let threadID = "thr_task_123"
        let snapshot = WatchCodexTaskSnapshot(
            threadID: threadID,
            turnID: "turn_task_123",
            cwd: "/tmp/wristremote",
            title: "Example task",
            summary: "Example result",
            state: .completed,
            revision: 4,
            updatedAtEpochMilliseconds: 1_777_000_000_000
        )
        let identity = try XCTUnwrap(WatchCodexTaskIdentity(snapshot))

        XCTAssertTrue(WristBridgeConnection.acceptsVoiceTargetShape(
            intent: .foregroundDictation,
            codexTaskIdentity: nil
        ))
        XCTAssertFalse(WristBridgeConnection.acceptsVoiceTargetShape(
            intent: .foregroundDictation,
            codexTaskIdentity: identity
        ))
        XCTAssertFalse(WristBridgeConnection.acceptsVoiceTargetShape(
            intent: .codexTask,
            codexTaskIdentity: nil
        ))
        XCTAssertTrue(WristBridgeConnection.acceptsVoiceTarget(
            intent: .codexTask,
            codexTaskIdentity: identity,
            snapshot: snapshot,
            supportsCodexTasks: true
        ))
        XCTAssertFalse(WristBridgeConnection.acceptsVoiceTarget(
            intent: .codexTask,
            codexTaskIdentity: WatchCodexTaskIdentity(
                threadID: "thr_other_456",
                turnID: identity.turnID,
                revision: identity.revision
            ),
            snapshot: snapshot,
            supportsCodexTasks: true
        ))
        XCTAssertFalse(WristBridgeConnection.acceptsVoiceTarget(
            intent: .codexTask,
            codexTaskIdentity: identity,
            snapshot: WatchCodexTaskSnapshot(
                threadID: threadID,
                turnID: identity.turnID,
                cwd: snapshot.cwd,
                title: snapshot.title,
                state: .running,
                revision: snapshot.revision,
                updatedAtEpochMilliseconds: snapshot.updatedAtEpochMilliseconds
            ),
            supportsCodexTasks: true
        ))
        XCTAssertFalse(WristBridgeConnection.acceptsVoiceTarget(
            intent: .codexTask,
            codexTaskIdentity: identity,
            snapshot: snapshot,
            supportsCodexTasks: false
        ))

        let nextTurn = WatchCodexTaskSnapshot(
            threadID: threadID,
            turnID: "turn_task_124",
            cwd: snapshot.cwd,
            title: snapshot.title,
            state: .completed,
            revision: snapshot.revision + 1,
            updatedAtEpochMilliseconds: snapshot.updatedAtEpochMilliseconds + 1
        )
        XCTAssertFalse(WristBridgeConnection.acceptsVoiceTarget(
            intent: .codexTask,
            codexTaskIdentity: identity,
            snapshot: nextTurn,
            supportsCodexTasks: true
        ))
    }

    func testWireTaskTombstoneIsExplicitAndRejectsAmbiguity() throws {
        let cleared = WristBridgeWireMessage(
            type: "ready",
            codexTaskCleared: true,
            codexTaskStateRevision: 8
        )
        XCTAssertEqual(
            WristBridgeConnection.codexTaskUpdate(from: cleared),
            .cleared(stateRevision: 8)
        )

        let snapshot = WatchCodexTaskSnapshot(
            threadID: "thr_tombstone",
            turnID: "turn_tombstone",
            cwd: "/tmp",
            title: "Task",
            state: .completed,
            revision: 1,
            updatedAtEpochMilliseconds: 1
        )
        XCTAssertEqual(
            WristBridgeConnection.codexTaskUpdate(from: WristBridgeWireMessage(
                type: "ready",
                codexTask: snapshot,
                codexTaskCleared: false,
                codexTaskStateRevision: 9
            )),
            .snapshot(snapshot, stateRevision: 9)
        )
        XCTAssertNil(WristBridgeConnection.codexTaskUpdate(from: WristBridgeWireMessage(
            type: "ready"
        )))
        XCTAssertNil(WristBridgeConnection.codexTaskUpdate(from: WristBridgeWireMessage(
            type: "ready",
            codexTask: snapshot,
            codexTaskCleared: true,
            codexTaskStateRevision: 10
        )))
    }

    func testRapidProfileEditsSerializeAndStaleAckKeepsPendingRevision() {
        var queue = WristBridgeConnection.ProfileRevisionQueue()
        XCTAssertEqual(queue.request(1), 1)
        XCTAssertNil(queue.request(2))
        XCTAssertEqual(queue.desiredRevision, 2)
        XCTAssertEqual(queue.pendingRevision, 1)

        XCTAssertEqual(queue.complete(type: "watchProfileReady", revision: 99), .stale)
        XCTAssertEqual(queue.pendingRevision, 1)

        XCTAssertEqual(
            queue.complete(type: "watchProfileReady", revision: 1),
            .ready(nextRevision: 2)
        )
        XCTAssertEqual(queue.pendingRevision, 2)
        XCTAssertEqual(
            queue.complete(type: "watchProfileRejected", revision: 2),
            .rejected(nextRevision: nil)
        )
        XCTAssertNil(queue.acceptedRevision)
    }

    func testTimeoutOnlyClearsMatchingGenerationRevisionAndCanRetry() {
        var queue = WristBridgeConnection.ProfileRevisionQueue()
        XCTAssertEqual(queue.request(5), 5)
        XCTAssertFalse(queue.timeout(revision: 4))
        XCTAssertEqual(queue.pendingRevision, 5)
        XCTAssertTrue(queue.timeout(revision: 5))
        XCTAssertNil(queue.pendingRevision)
        XCTAssertEqual(queue.request(5), 5)
    }

    func testUnsolicitedRejectionInvalidatesAcceptedRevision() {
        var queue = WristBridgeConnection.ProfileRevisionQueue()
        XCTAssertEqual(queue.request(3), 3)
        XCTAssertEqual(
            queue.complete(type: "watchProfileReady", revision: 3),
            .ready(nextRevision: nil)
        )
        XCTAssertEqual(queue.acceptedRevision, 3)
        XCTAssertEqual(
            queue.complete(type: "watchProfileRejected", revision: 3),
            .invalidated
        )
        XCTAssertNil(queue.acceptedRevision)
    }

    func testReconnectBackoffIsBoundedAndReusableForSameService() {
        XCTAssertEqual(WristBridgeConnection.reconnectDelaySeconds(attempt: 0), 0.5)
        XCTAssertEqual(WristBridgeConnection.reconnectDelaySeconds(attempt: 1), 1)
        XCTAssertEqual(WristBridgeConnection.reconnectDelaySeconds(attempt: 8), 8)
    }

    func testForegroundRecoveryRearmsEveryNonConnectedTransportExceptManualApproval() {
        XCTAssertTrue(WristBridgeConnection.State.searching.shouldRestartDiscoveryOnActivation)
        XCTAssertTrue(WristBridgeConnection.State.connecting.shouldRestartDiscoveryOnActivation)
        XCTAssertTrue(WristBridgeConnection.State.unavailable("offline")
            .shouldRestartDiscoveryOnActivation)
        XCTAssertFalse(WristBridgeConnection.State.awaitingApproval
            .shouldRestartDiscoveryOnActivation)
        XCTAssertFalse(WristBridgeConnection.State.connected
            .shouldRestartDiscoveryOnActivation)
        XCTAssertFalse(WristBridgeConnection.State.connectedWithError("profile")
            .shouldRestartDiscoveryOnActivation)
    }

    func testWatchStatusLivenessProbeUsesABoundedTimeout() {
        XCTAssertEqual(WristBridgeConnection.livenessProbeTimeoutSeconds, 1)
    }

    func testWatchStatusRecoveryJoinsAnExistingDiscoveryGeneration() {
        XCTAssertTrue(WristBridgeConnection.shouldStartDiscoveryForWatchStatusRequest(
            state: .searching,
            hasBrowser: false,
            hasConnection: false
        ))
        XCTAssertFalse(WristBridgeConnection.shouldStartDiscoveryForWatchStatusRequest(
            state: .searching,
            hasBrowser: true,
            hasConnection: false
        ))
        XCTAssertFalse(WristBridgeConnection.shouldStartDiscoveryForWatchStatusRequest(
            state: .connecting,
            hasBrowser: true,
            hasConnection: true
        ))
        XCTAssertTrue(WristBridgeConnection.shouldStartDiscoveryForWatchStatusRequest(
            state: .unavailable("offline"),
            hasBrowser: false,
            hasConnection: false
        ))
        XCTAssertFalse(WristBridgeConnection.shouldStartDiscoveryForWatchStatusRequest(
            state: .awaitingApproval,
            hasBrowser: true,
            hasConnection: true
        ))
    }

    func testConnectionWatchdogOnlyCoversConnectingAndHandshakePhase() {
        XCTAssertTrue(WristBridgeConnection.State.connecting.needsConnectionWatchdog)
        XCTAssertFalse(WristBridgeConnection.State.searching.needsConnectionWatchdog)
        XCTAssertFalse(WristBridgeConnection.State.awaitingApproval.needsConnectionWatchdog)
        XCTAssertFalse(WristBridgeConnection.State.connected.needsConnectionWatchdog)
        XCTAssertEqual(WristBridgeConnection.connectionWatchdogSeconds, 12)
        XCTAssertTrue(WristBridgeConnection.shouldExpireConnectionWatchdog(
            expectedGeneration: 4,
            currentGeneration: 4,
            state: .connecting,
            hasConnection: true
        ))
        XCTAssertFalse(WristBridgeConnection.shouldExpireConnectionWatchdog(
            expectedGeneration: 3,
            currentGeneration: 4,
            state: .connecting,
            hasConnection: true
        ))
        XCTAssertFalse(WristBridgeConnection.shouldExpireConnectionWatchdog(
            expectedGeneration: 4,
            currentGeneration: 4,
            state: .awaitingApproval,
            hasConnection: true
        ))
        XCTAssertFalse(WristBridgeConnection.shouldExpireConnectionWatchdog(
            expectedGeneration: 4,
            currentGeneration: 4,
            state: .connecting,
            hasConnection: false
        ))
    }

    func testIdentityStorageOnlyCreatesForMissingAndNeverForTransientErrors() {
        XCTAssertEqual(
            WristBridgeInstallationIdentity.storageAction(
                copyStatus: errSecSuccess,
                hasStoredData: true,
                hasValidKey: true
            ),
            .useStored
        )
        XCTAssertEqual(
            WristBridgeInstallationIdentity.storageAction(
                copyStatus: errSecSuccess,
                hasStoredData: true,
                hasValidKey: false
            ),
            .replaceCorrupt
        )
        XCTAssertEqual(
            WristBridgeInstallationIdentity.storageAction(
                copyStatus: errSecItemNotFound,
                hasStoredData: false,
                hasValidKey: false
            ),
            .create
        )
        for transientStatus in [errSecInteractionNotAllowed, errSecNotAvailable, errSecAuthFailed] {
            XCTAssertEqual(
                WristBridgeInstallationIdentity.storageAction(
                    copyStatus: transientStatus,
                    hasStoredData: false,
                    hasValidKey: false
                ),
                .retry
            )
        }
        XCTAssertEqual(
            WristBridgeInstallationIdentity.storageAction(
                copyStatus: errSecSuccess,
                hasStoredData: false,
                hasValidKey: false
            ),
            .retry
        )
    }
}
#endif
