import XCTest
@testable import WristRemote

final class WatchRemoteProtocolTests: XCTestCase {
    func testProtocolVersionIsSeven() {
        XCTAssertEqual(WatchRemoteProtocol.version, 7)
    }

    func testAllPhysicalRemoteCommandsHaveStableWireNames() {
        let expected: [(WatchRemoteCommand, String)] = [
            (.power, "power"),
            (.up, "up"),
            (.down, "down"),
            (.left, "left"),
            (.right, "right"),
            (.ok, "ok"),
            (.back, "back"),
            (.home, "home"),
            (.menu, "menu"),
            (.tv, "tv"),
            (.volumeUp, "volumeUp"),
            (.volumeDown, "volumeDown"),
        ]

        XCTAssertEqual(WatchRemoteCommand.allCases.count, 12)
        XCTAssertEqual(WatchRemoteCommand.allCases.map(\.rawValue), expected.map { $0.1 })
        for (command, rawValue) in expected {
            XCTAssertEqual(command.rawValue, rawValue)
            XCTAssertEqual(WatchRemoteCommand(rawValue: rawValue), command)
        }
    }

    func testButtonMessagesPreservePressAndReleasePhases() {
        for command in WatchRemoteCommand.allCases {
            for phase in [
                WatchRemoteProtocol.ButtonPhase.press,
                WatchRemoteProtocol.ButtonPhase.release,
            ] {
                let message = WatchRemoteProtocol.buttonMessage(
                    command: command,
                    phase: phase,
                    profileRevision: 17
                )

                XCTAssertEqual(
                    message[WatchRemoteProtocol.Key.protocolVersion.rawValue] as? Int,
                    WatchRemoteProtocol.version
                )
                XCTAssertEqual(
                    message[WatchRemoteProtocol.Key.kind.rawValue] as? String,
                    WatchRemoteProtocol.Kind.buttonEvent.rawValue
                )
                XCTAssertEqual(
                    message[WatchRemoteProtocol.Key.command.rawValue] as? String,
                    command.rawValue
                )
                XCTAssertEqual(
                    message[WatchRemoteProtocol.Key.phase.rawValue] as? String,
                    phase.rawValue
                )
                XCTAssertEqual(
                    message[WatchRemoteProtocol.Key.profileRevision.rawValue] as? Int,
                    17
                )
                let decoded = WatchRemoteProtocol.buttonEvent(from: message)
                XCTAssertEqual(decoded?.command, command)
                XCTAssertEqual(decoded?.phase, phase)
                XCTAssertEqual(decoded?.profileRevision, 17)
            }
        }
    }

    func testButtonEventsWithoutAnExactNonnegativeProfileRevisionFailClosed() {
        var missing = WatchRemoteProtocol.buttonMessage(
            command: .ok,
            phase: .release,
            profileRevision: 4
        )
        missing.removeValue(forKey: WatchRemoteProtocol.Key.profileRevision.rawValue)
        XCTAssertNil(WatchRemoteProtocol.buttonEvent(from: missing))

        let negative = WatchRemoteProtocol.buttonMessage(
            command: .ok,
            phase: .release,
            profileRevision: -1
        )
        XCTAssertNil(WatchRemoteProtocol.buttonEvent(from: negative))
    }

    func testControlMessagesCarryVersionAndExpectedKinds() throws {
        let streamID = UUID()
        let requestID = UUID()
        let cases: [([String: Any], WatchRemoteProtocol.Kind)] = [
            (try XCTUnwrap(WatchRemoteProtocol.voiceStartMessage(
                streamID: streamID,
                profileRevision: 7
            )), .voiceStart),
            (try XCTUnwrap(WatchRemoteProtocol.voiceStopMessage(
                streamID: streamID,
                profileRevision: 7
            )), .voiceStop),
            (WatchRemoteProtocol.requestStatusMessage(requestID: requestID), .requestStatus),
        ]

        for (message, kind) in cases {
            XCTAssertEqual(
                message[WatchRemoteProtocol.Key.protocolVersion.rawValue] as? Int,
                WatchRemoteProtocol.version
            )
            XCTAssertEqual(
                message[WatchRemoteProtocol.Key.kind.rawValue] as? String,
                kind.rawValue
            )
        }
        XCTAssertEqual(
            WatchRemoteProtocol.streamID(
                from: try XCTUnwrap(WatchRemoteProtocol.voiceStartMessage(
                    streamID: streamID,
                    profileRevision: 7
                )),
                kind: .voiceStart
            ),
            streamID
        )
        XCTAssertEqual(
            WatchRemoteProtocol.voiceEvent(
                from: try XCTUnwrap(WatchRemoteProtocol.voiceStartMessage(
                    streamID: streamID,
                    profileRevision: 7
                )),
                kind: .voiceStart
            )?.profileRevision,
            7
        )
        XCTAssertEqual(
            WatchRemoteProtocol.voiceEvent(
                from: try XCTUnwrap(WatchRemoteProtocol.voiceStartMessage(
                    streamID: streamID,
                    profileRevision: 7
                )),
                kind: .voiceStart
            )?.intent,
            .foregroundDictation
        )
        XCTAssertEqual(
            WatchRemoteProtocol.requestID(
                from: WatchRemoteProtocol.requestStatusMessage(requestID: requestID)
            ),
            requestID
        )
    }

    func testVoiceStartReplyRequiresMatchingProtocolAndCarriesDecision() throws {
        let streamID = UUID()
        let identity = try XCTUnwrap(WatchCodexTaskIdentity(
            threadID: "thr_reply_123",
            turnID: "turn_reply_456",
            revision: 8
        ))
        let accepted = WatchRemoteProtocol.voiceStartReply(
            from: try XCTUnwrap(WatchRemoteProtocol.voiceStartReply(
                accepted: true,
                streamID: streamID,
                profileRevision: 8,
                intent: .codexTask,
                codexTaskIdentity: identity
            ))
        )
        XCTAssertEqual(accepted?.accepted, true)
        XCTAssertEqual(accepted?.streamID, streamID)
        XCTAssertEqual(accepted?.profileRevision, 8)
        XCTAssertEqual(accepted?.intent, .codexTask)
        XCTAssertEqual(accepted?.codexTaskIdentity, identity)

        let rejected = WatchRemoteProtocol.voiceStartReply(
            from: try XCTUnwrap(WatchRemoteProtocol.voiceStartReply(
                accepted: false,
                streamID: streamID,
                profileRevision: 8
            ))
        )
        XCTAssertEqual(rejected?.accepted, false)
        XCTAssertEqual(rejected?.streamID, streamID)

        var wrongVersion = try XCTUnwrap(WatchRemoteProtocol.voiceStartReply(
            accepted: true,
            streamID: streamID,
            profileRevision: 8
        ))
        wrongVersion[WatchRemoteProtocol.Key.protocolVersion.rawValue] = 99
        XCTAssertNil(WatchRemoteProtocol.voiceStartReply(from: wrongVersion))
    }

    func testVoiceEventsBindIntentThreadAndFinalAudioSequence() throws {
        let streamID = UUID()
        let identity = try XCTUnwrap(WatchCodexTaskIdentity(
            threadID: "thr_voice_123",
            turnID: "turn_voice_123",
            revision: 19
        ))
        let start = try XCTUnwrap(WatchRemoteProtocol.voiceStartMessage(
            streamID: streamID,
            profileRevision: 12,
            intent: .codexTask,
            codexTaskIdentity: identity
        ))
        let decodedStart = try XCTUnwrap(WatchRemoteProtocol.voiceEvent(
            from: start,
            kind: .voiceStart
        ))
        XCTAssertEqual(decodedStart.streamID, streamID)
        XCTAssertEqual(decodedStart.profileRevision, 12)
        XCTAssertEqual(decodedStart.intent, .codexTask)
        XCTAssertEqual(decodedStart.codexTaskIdentity, identity)
        XCTAssertNil(decodedStart.finalSequence)

        var missingTurn = start
        missingTurn.removeValue(forKey: WatchRemoteProtocol.Key.turnID.rawValue)
        XCTAssertNil(WatchRemoteProtocol.voiceEvent(from: missingTurn, kind: .voiceStart))

        var foregroundWithPartialIdentity = try XCTUnwrap(
            WatchRemoteProtocol.voiceStartMessage(
                streamID: streamID,
                profileRevision: 12
            )
        )
        foregroundWithPartialIdentity[WatchRemoteProtocol.Key.threadID.rawValue] = identity.threadID
        XCTAssertNil(WatchRemoteProtocol.voiceEvent(
            from: foregroundWithPartialIdentity,
            kind: .voiceStart
        ))

        let stop = try XCTUnwrap(WatchRemoteProtocol.voiceStopMessage(
            streamID: streamID,
            profileRevision: 12,
            intent: .codexTask,
            codexTaskIdentity: identity,
            finalSequence: 42
        ))
        let decodedStop = try XCTUnwrap(WatchRemoteProtocol.voiceEvent(
            from: stop,
            kind: .voiceStop
        ))
        XCTAssertEqual(decodedStop.streamID, streamID)
        XCTAssertEqual(decodedStop.intent, .codexTask)
        XCTAssertEqual(decodedStop.codexTaskIdentity, identity)
        XCTAssertEqual(decodedStop.finalSequence, 42)

        XCTAssertNil(WatchRemoteProtocol.voiceStartMessage(
            streamID: streamID,
            profileRevision: 12,
            intent: .codexTask
        ))
        XCTAssertNil(WatchRemoteProtocol.voiceStopMessage(
            streamID: streamID,
            profileRevision: 12,
            intent: .foregroundDictation,
            codexTaskIdentity: identity,
            finalSequence: 42
        ))

        var startWithFinalSequence = start
        startWithFinalSequence[WatchRemoteProtocol.Key.finalSequence.rawValue] = UInt64(1)
        XCTAssertNil(WatchRemoteProtocol.voiceEvent(
            from: startWithFinalSequence,
            kind: .voiceStart
        ))

        for malformedFinalSequence: Any in [-1, true, 1.5, "42"] {
            var malformedStop = stop
            malformedStop[WatchRemoteProtocol.Key.finalSequence.rawValue] = malformedFinalSequence
            XCTAssertNil(
                WatchRemoteProtocol.voiceEvent(from: malformedStop, kind: .voiceStop),
                "finalSequence must reject \(malformedFinalSequence)"
            )
        }
    }

    func testVoiceStartHandshakeCancellationRejectsLateReply() {
        XCTAssertEqual(WatchRemoteProtocol.voiceStartReplyTimeoutMilliseconds, 6_000)

        let cancelledStreamID = UUID()
        let nextStreamID = UUID()
        var handshake = WatchRemoteVoiceStartHandshake()
        handshake.begin(requestID: 41, streamID: cancelledStreamID, profileRevision: 1)

        XCTAssertTrue(handshake.isPending(
            requestID: 41,
            streamID: cancelledStreamID,
            profileRevision: 1
        ))
        XCTAssertTrue(handshake.cancel(
            requestID: 41,
            streamID: cancelledStreamID,
            profileRevision: 1
        ))
        XCTAssertFalse(handshake.consumeCompletion(
            requestID: 41,
            streamID: cancelledStreamID,
            profileRevision: 1
        ))

        handshake.begin(requestID: 42, streamID: nextStreamID, profileRevision: 2)
        XCTAssertFalse(handshake.consumeCompletion(
            requestID: 41,
            streamID: cancelledStreamID,
            profileRevision: 1
        ))
        XCTAssertTrue(handshake.isPending(
            requestID: 42,
            streamID: nextStreamID,
            profileRevision: 2
        ))
        XCTAssertFalse(handshake.consumeCompletion(
            requestID: 42,
            streamID: nextStreamID,
            profileRevision: 1
        ))
        XCTAssertTrue(handshake.consumeCompletion(
            requestID: 42,
            streamID: nextStreamID,
            profileRevision: 2
        ))
        XCTAssertNil(handshake.pendingRequestID)
        XCTAssertNil(handshake.pendingStreamID)
    }

    func testRelayVoiceStopBeforeStartCannotResurrectReleasedStream() {
        var reservation = WatchRemoteVoiceRelayReservation()
        let releasedStream = UUID()

        reservation.stop(streamID: releasedStream, profileRevision: 1)
        XCTAssertFalse(reservation.reserve(streamID: releasedStream, profileRevision: 1))
        XCTAssertTrue(reservation.reserve(streamID: releasedStream, profileRevision: 2))
        reservation.clear()
        XCTAssertNil(reservation.pendingStreamID)

        let nextStream = UUID()
        XCTAssertTrue(reservation.reserve(streamID: nextStream, profileRevision: 3))
        reservation.stop(streamID: nextStream, profileRevision: 3)
        XCTAssertFalse(reservation.consumeCompletion(
            streamID: nextStream,
            profileRevision: 3
        ))
        XCTAssertFalse(reservation.reserve(streamID: nextStream, profileRevision: 3))
    }

    func testRelayVoiceReservationBoundsStoppedStreamTombstones() {
        var reservation = WatchRemoteVoiceRelayReservation()
        for _ in 0..<40 {
            reservation.stop(streamID: UUID(), profileRevision: 1)
        }
        XCTAssertEqual(reservation.stoppedStreamIDs.count, 32)

        reservation.clear()
        XCTAssertTrue(reservation.stoppedStreamIDs.isEmpty)
        XCTAssertNil(reservation.pendingStreamID)
    }

    func testFavoritesRequireExactlyFourUniqueKnownCommands() throws {
        let favorites: [WatchRemoteCommand] = [.back, .home, .volumeUp, .volumeDown]
        let message = try XCTUnwrap(
            WatchRemoteProtocol.favoritesUpdateMessage(favorites)
        )

        XCTAssertEqual(
            message[WatchRemoteProtocol.Key.kind.rawValue] as? String,
            WatchRemoteProtocol.Kind.favoritesUpdate.rawValue
        )
        XCTAssertEqual(WatchRemoteProtocol.favorites(from: message), favorites)

        XCTAssertNil(WatchRemoteProtocol.favoritesUpdateMessage([.back, .home, .volumeUp]))
        XCTAssertNil(WatchRemoteProtocol.favoritesUpdateMessage([
            .back, .home, .volumeUp, .volumeUp,
        ]))
        XCTAssertNil(WatchRemoteProtocol.favorites(from: [
            WatchRemoteProtocol.Key.favorites.rawValue: [
                "back", "home", "volumeUp", "unknown",
            ],
        ]))
    }

    func testStatusAndApplicationContextRoundTrip() throws {
        let status = WatchRemoteStatus(
            isMacConnected: true,
            macName: "Example Mac",
            voiceOwner: .watch,
            detail: "ready",
            buttonTitles: [
                .power: "Escape",
                .ok: "Return",
                .tv: "Command-Tab",
            ],
            isActionProfileReady: true,
            profileRevision: 8
        )
        let favorites: [WatchRemoteCommand] = [.back, .home, .menu, .tv]
        let context = WatchRemoteProtocol.applicationContext(
            status: status,
            favorites: favorites,
            codexTaskStateRevision: 0
        )

        XCTAssertEqual(WatchRemoteProtocol.status(from: context), status)
        XCTAssertEqual(
            context[WatchRemoteProtocol.Key.actionProfileReady.rawValue] as? Bool,
            true
        )
        XCTAssertEqual(
            context[WatchRemoteProtocol.Key.profileRevision.rawValue] as? Int,
            8
        )
        XCTAssertEqual(WatchRemoteProtocol.favorites(from: context), favorites)
        XCTAssertEqual(
            context[WatchRemoteProtocol.Key.kind.rawValue] as? String,
            WatchRemoteProtocol.Kind.status.rawValue
        )
        XCTAssertNil(WatchRemoteProtocol.requestID(from: context))
    }

    func testCodexTaskSnapshotRoundTripsAsLiveMessageAndPersistedContext() throws {
        let snapshot = WatchCodexTaskSnapshot(
            threadID: "thr_task_123",
            turnID: "turn-42",
            cwd: "/workspace/wrist-remote-example",
            title: "Example task",
            summary: "Example result",
            state: .completed,
            revision: 9,
            updatedAtEpochMilliseconds: 1_777_000_000_123
        )
        let live = try XCTUnwrap(WatchRemoteProtocol.codexTaskMessage(
            snapshot,
            stateRevision: 12
        ))
        XCTAssertEqual(WatchRemoteProtocol.kind(from: live), .codexTaskSnapshot)
        XCTAssertEqual(WatchRemoteProtocol.codexTask(from: live), snapshot)

        let context = WatchRemoteProtocol.applicationContext(
            status: .unavailable,
            favorites: WatchRemoteCommand.defaultFavorites,
            codexTask: snapshot,
            codexTaskStateRevision: 12
        )
        XCTAssertEqual(WatchRemoteProtocol.kind(from: context), .status)
        XCTAssertEqual(WatchRemoteProtocol.codexTask(from: context), snapshot)
        XCTAssertEqual(
            WatchRemoteProtocol.codexTaskUpdate(from: context),
            .snapshot(snapshot, stateRevision: 12)
        )

        var wrongVersion = live
        wrongVersion[WatchRemoteProtocol.Key.protocolVersion.rawValue] = 3
        XCTAssertNil(WatchRemoteProtocol.codexTask(from: wrongVersion))

        var malformed = live
        malformed[WatchRemoteProtocol.Key.codexTaskPayload.rawValue] = "not-base64"
        XCTAssertNil(WatchRemoteProtocol.codexTask(from: malformed))
    }

    func testCodexTaskTombstoneClearsPersistedAndLiveTaskState() {
        let live = WatchRemoteProtocol.codexTaskClearedMessage(stateRevision: 13)
        XCTAssertEqual(WatchRemoteProtocol.kind(from: live), .codexTaskSnapshot)
        XCTAssertEqual(
            WatchRemoteProtocol.codexTaskUpdate(from: live),
            .cleared(stateRevision: 13)
        )
        XCTAssertNil(WatchRemoteProtocol.codexTask(from: live))

        let context = WatchRemoteProtocol.applicationContext(
            status: .unavailable,
            favorites: WatchRemoteCommand.defaultFavorites,
            codexTask: nil,
            codexTaskStateRevision: 13
        )
        XCTAssertEqual(
            WatchRemoteProtocol.codexTaskUpdate(from: context),
            .cleared(stateRevision: 13)
        )

        var contradictory = live
        contradictory[WatchRemoteProtocol.Key.codexTaskPayload.rawValue] = "payload"
        XCTAssertNil(WatchRemoteProtocol.codexTaskUpdate(from: contradictory))
    }

    func testVoiceOutcomeRoundTripsAsLiveMessageAndPersistedContext() throws {
        let outcome = WatchVoiceOutcome(
            sessionID: UUID().uuidString,
            intent: .codexTask,
            threadID: "thr_task_123",
            turnID: "turn-42",
            taskRevision: 9,
            kind: .draft,
            text: "示例回复",
            detail: "请确认示例内容",
            localeIdentifier: "zh-CN"
        )
        let live = try XCTUnwrap(WatchRemoteProtocol.voiceOutcomeMessage(outcome))
        XCTAssertEqual(WatchRemoteProtocol.kind(from: live), .voiceOutcome)
        XCTAssertEqual(WatchRemoteProtocol.voiceOutcome(from: live), outcome)

        let context = WatchRemoteProtocol.applicationContext(
            status: .unavailable,
            favorites: WatchRemoteCommand.defaultFavorites,
            codexTaskStateRevision: 0,
            voiceOutcome: outcome
        )
        XCTAssertEqual(WatchRemoteProtocol.kind(from: context), .status)
        XCTAssertEqual(WatchRemoteProtocol.voiceOutcome(from: context), outcome)

        var wrongVersion = live
        wrongVersion[WatchRemoteProtocol.Key.protocolVersion.rawValue] = 3
        XCTAssertNil(WatchRemoteProtocol.voiceOutcome(from: wrongVersion))

        var malformed = live
        malformed[WatchRemoteProtocol.Key.voiceOutcomePayload.rawValue] = "not-base64"
        XCTAssertNil(WatchRemoteProtocol.voiceOutcome(from: malformed))
    }

    func testCodexThreadIdentifierAcceptsSafeNonUUIDValuesAndRejectsShellLikeInput() {
        XCTAssertTrue(CodexThreadIdentifier.isValid("thr_123"))
        XCTAssertTrue(CodexThreadIdentifier.isValid("not-a-uuid"))
        XCTAssertTrue(CodexThreadIdentifier.isValid(UUID().uuidString))
        XCTAssertFalse(CodexThreadIdentifier.isValid(nil))
        XCTAssertFalse(CodexThreadIdentifier.isValid(""))
        XCTAssertFalse(CodexThreadIdentifier.isValid("   "))
        XCTAssertFalse(CodexThreadIdentifier.isValid(" padded"))
        XCTAssertFalse(CodexThreadIdentifier.isValid("padded "))
        XCTAssertFalse(CodexThreadIdentifier.isValid("-option"))
        XCTAssertFalse(CodexThreadIdentifier.isValid("thread\nnext"))
        XCTAssertFalse(CodexThreadIdentifier.isValid("thread\u{0000}next"))
        XCTAssertFalse(CodexThreadIdentifier.isValid(String(repeating: "a", count: 129)))
    }

    func testCodexReplySubmissionAndAckRequireExactTaskIdentity() throws {
        let identity = try XCTUnwrap(WatchCodexTaskIdentity(
            threadID: "thr_reply_456",
            turnID: "turn_reply_789",
            revision: 12
        ))
        let submissionID = UUID()
        let message = try XCTUnwrap(WatchRemoteProtocol.codexReplySubmitMessage(
            codexTaskIdentity: identity,
            submissionID: submissionID,
            transcript: "  示例回复  \n"
        ))
        XCTAssertEqual(WatchRemoteProtocol.kind(from: message), .codexReplySubmit)
        let decoded = try XCTUnwrap(WatchRemoteProtocol.codexReplySubmit(from: message))
        XCTAssertEqual(decoded.codexTaskIdentity, identity)
        XCTAssertEqual(decoded.submissionID, submissionID)
        XCTAssertEqual(decoded.transcript, "示例回复")

        XCTAssertNil(WatchRemoteProtocol.codexReplySubmitMessage(
            codexTaskIdentity: identity,
            submissionID: submissionID,
            transcript: "  \n"
        ))
        XCTAssertNil(WatchRemoteProtocol.codexReplySubmitMessage(
            codexTaskIdentity: identity,
            submissionID: submissionID,
            transcript: String(repeating: "中", count: 2_001)
        ))

        let ack = WatchRemoteProtocol.codexReplyAckMessage(
            accepted: true,
            codexTaskIdentity: identity,
            submissionID: submissionID
        )
        let decodedAck = try XCTUnwrap(WatchRemoteProtocol.codexReplyAck(from: ack))
        XCTAssertTrue(decodedAck.accepted)
        XCTAssertEqual(decodedAck.codexTaskIdentity, identity)
        XCTAssertEqual(decodedAck.submissionID, submissionID)
        XCTAssertNil(WatchRemoteProtocol.codexReplySubmit(from: ack))

        var wrongVersion = message
        wrongVersion[WatchRemoteProtocol.Key.protocolVersion.rawValue] = 3
        XCTAssertNil(WatchRemoteProtocol.codexReplySubmit(from: wrongVersion))

        var wrongKind = message
        wrongKind[WatchRemoteProtocol.Key.kind.rawValue] = WatchRemoteProtocol.Kind.status.rawValue
        XCTAssertNil(WatchRemoteProtocol.codexReplySubmit(from: wrongKind))

        var replayedForNewRevision = message
        replayedForNewRevision[WatchRemoteProtocol.Key.taskRevision.rawValue] = 13
        XCTAssertNotEqual(
            WatchRemoteProtocol.codexReplySubmit(from: replayedForNewRevision)?.codexTaskIdentity,
            identity
        )
    }

    func testLiveStatusHandshakeRejectsPersistedAndStaleStatus() throws {
        let status = WatchRemoteStatus(
            isMacConnected: true,
            macName: "Example Mac",
            voiceOwner: .none,
            detail: nil,
            buttonTitles: [:],
            isActionProfileReady: true,
            profileRevision: 3
        )
        let persistedContext = WatchRemoteProtocol.applicationContext(
            status: status,
            favorites: WatchRemoteCommand.defaultFavorites,
            codexTaskStateRevision: 0
        )
        var handshake = WatchRemoteStatusHandshake()

        XCTAssertNil(handshake.acceptReply(persistedContext))
        XCTAssertFalse(handshake.hasFreshStatus)

        let requestID = UUID()
        XCTAssertEqual(handshake.begin(requestID: requestID), requestID)
        XCTAssertFalse(handshake.hasFreshStatus)

        let staleReply = WatchRemoteProtocol.statusReplyMessage(
            status,
            requestID: UUID()
        )
        XCTAssertNil(handshake.acceptReply(staleReply))
        XCTAssertEqual(handshake.pendingRequestID, requestID)
        XCTAssertFalse(handshake.hasFreshStatus)

        let liveReply = WatchRemoteProtocol.statusReplyMessage(
            status,
            requestID: requestID
        )
        XCTAssertEqual(try XCTUnwrap(handshake.acceptReply(liveReply)), status)
        XCTAssertTrue(handshake.hasFreshStatus)
        XCTAssertNil(handshake.pendingRequestID)

        handshake.invalidate()
        XCTAssertFalse(handshake.hasFreshStatus)
    }

    func testInteractiveStatusPushBecomesFreshWithoutAcceptingReplyEnvelope() throws {
        let status = WatchRemoteStatus(
            isMacConnected: true,
            macName: "Example Mac",
            voiceOwner: .none,
            detail: nil,
            buttonTitles: [:],
            isActionProfileReady: true,
            profileRevision: 9
        )
        var handshake = WatchRemoteStatusHandshake()
        _ = handshake.begin()

        XCTAssertEqual(
            try XCTUnwrap(handshake.acceptLivePush(WatchRemoteProtocol.statusMessage(status))),
            status
        )
        XCTAssertTrue(handshake.hasFreshStatus)
        XCTAssertNil(handshake.pendingRequestID)

        XCTAssertNil(handshake.acceptLivePush(WatchRemoteProtocol.statusReplyMessage(
            status,
            requestID: UUID()
        )))
    }

    func testConnectivityRecoveryPolicyRetriesActivationAndUsesCappedContinuousDelays() {
        XCTAssertTrue(WatchConnectivityRecoveryPolicy.shouldRequestActivation(
            isActivated: false,
            isInactive: false,
            requestInFlight: false
        ))
        XCTAssertFalse(WatchConnectivityRecoveryPolicy.shouldRequestActivation(
            isActivated: true,
            isInactive: false,
            requestInFlight: false
        ))
        XCTAssertFalse(WatchConnectivityRecoveryPolicy.shouldRequestActivation(
            isActivated: false,
            isInactive: true,
            requestInFlight: false
        ))
        XCTAssertFalse(WatchConnectivityRecoveryPolicy.shouldRequestActivation(
            isActivated: false,
            isInactive: false,
            requestInFlight: true
        ))

        let expectedDelays: [TimeInterval?] = [nil, 1, 2, 4, 8, 15, 15, 15]
        XCTAssertEqual(
            (-1...6).map(WatchConnectivityRecoveryPolicy.statusRetryDelay(attempt:)),
            expectedDelays
        )
        XCTAssertEqual(WatchConnectivityRecoveryPolicy.steadyStateStatusRetryDelay, 15)
        XCTAssertEqual(WatchConnectivityRecoveryPolicy.healthyStatusRefreshInterval, 8)

        var cursor = WatchStatusRetryCursor()
        XCTAssertEqual((0..<7).map { _ in cursor.nextDelay() }, [1, 2, 4, 8, 15, 15, 15])
        cursor.reset()
        XCTAssertEqual(cursor.nextDelay(), 1)
    }

    func testBridgeLivenessProbeRequiresCanonicalUUID() {
        let valid = UUID().uuidString
        XCTAssertTrue(WristBridgeWireMessage.isValidProbeID(valid))
        XCTAssertFalse(WristBridgeWireMessage.isValidProbeID(valid.lowercased()))
        XCTAssertFalse(WristBridgeWireMessage.isValidProbeID("probe"))
        XCTAssertFalse(WristBridgeWireMessage.isValidProbeID(nil))
    }

    func testStatusRejectsWrongVersionKindAndMissingRequiredFields() {
        let valid = WatchRemoteProtocol.statusMessage(.unavailable)

        var wrongVersion = valid
        wrongVersion[WatchRemoteProtocol.Key.protocolVersion.rawValue] = 99
        XCTAssertNil(WatchRemoteProtocol.status(from: wrongVersion))

        var wrongKind = valid
        wrongKind[WatchRemoteProtocol.Key.kind.rawValue] = WatchRemoteProtocol.Kind.voiceStart.rawValue
        XCTAssertNil(WatchRemoteProtocol.status(from: wrongKind))

        var missingConnectionState = valid
        missingConnectionState.removeValue(
            forKey: WatchRemoteProtocol.Key.macConnected.rawValue
        )
        XCTAssertNil(WatchRemoteProtocol.status(from: missingConnectionState))

        var unknownVoiceOwner = valid
        unknownVoiceOwner[WatchRemoteProtocol.Key.voiceOwner.rawValue] = "another-device"
        XCTAssertNil(WatchRemoteProtocol.status(from: unknownVoiceOwner))

        var legacyStatus = valid
        legacyStatus.removeValue(forKey: WatchRemoteProtocol.Key.actionProfileReady.rawValue)
        legacyStatus.removeValue(forKey: WatchRemoteProtocol.Key.profileRevision.rawValue)
        XCTAssertEqual(
            WatchRemoteProtocol.status(from: legacyStatus)?.isActionProfileReady,
            false
        )
        XCTAssertNil(WatchRemoteProtocol.status(from: legacyStatus)?.profileRevision)
    }

    func testStatusDropsUnknownAndBlankButtonTitlesWithoutRejectingSnapshot() throws {
        var message = WatchRemoteProtocol.statusMessage(.unavailable)
        message[WatchRemoteProtocol.Key.buttonTitles.rawValue] = [
            "ok": "  Return  ",
            "menu": "   ",
            "notACommand": "Ignore",
        ]

        let status = try XCTUnwrap(WatchRemoteProtocol.status(from: message))
        XCTAssertEqual(status.buttonTitles, [.ok: "Return"])
    }

    func testProfileReadinessOrRevisionChangeRequiresHeldInteractionReset() {
        let readyRevisionOne = WatchRemoteStatus(
            isMacConnected: true,
            macName: "Mac",
            voiceOwner: .none,
            detail: nil,
            buttonTitles: [:],
            isActionProfileReady: true,
            profileRevision: 1
        )
        let same = readyRevisionOne
        let readyRevisionTwo = WatchRemoteStatus(
            isMacConnected: true,
            macName: "Mac",
            voiceOwner: .none,
            detail: nil,
            buttonTitles: [:],
            isActionProfileReady: true,
            profileRevision: 2
        )
        let syncing = WatchRemoteStatus(
            isMacConnected: true,
            macName: "Mac",
            voiceOwner: .none,
            detail: "正在同步",
            buttonTitles: [:],
            isActionProfileReady: false,
            profileRevision: nil
        )

        XCTAssertFalse(same.requiresInteractionReset(from: readyRevisionOne))
        XCTAssertTrue(readyRevisionTwo.requiresInteractionReset(from: readyRevisionOne))
        XCTAssertTrue(syncing.requiresInteractionReset(from: readyRevisionOne))
        XCTAssertTrue(readyRevisionOne.requiresInteractionReset(from: syncing))
    }

    func testPCM16EncodingIsLittleEndianAndRoundTripsSignedExtremes() throws {
        let samples: [Int16] = [
            .min,
            -1,
            0,
            1,
            .max,
            Int16(bitPattern: 0x1234),
        ]
        let data = WatchRemoteProtocol.pcm16Data(samples: samples)

        XCTAssertEqual(
            Array(data),
            [0x00, 0x80, 0xFF, 0xFF, 0x00, 0x00, 0x01, 0x00, 0xFF, 0x7F, 0x34, 0x12]
        )
        XCTAssertEqual(try XCTUnwrap(WatchRemoteProtocol.decodePCM16(data)), samples)
    }

    func testPCM16PacketSizeAndMalformedPayloadRejection() throws {
        let samples = Array(
            repeating: Int16(321),
            count: WatchRemoteProtocol.audioPacketSampleCount
        )
        let data = WatchRemoteProtocol.pcm16Data(samples: samples)

        XCTAssertEqual(data.count, WatchRemoteProtocol.audioPacketSampleCount * 2)
        XCTAssertEqual(try XCTUnwrap(WatchRemoteProtocol.decodePCM16(data)), samples)
        XCTAssertNil(WatchRemoteProtocol.decodePCM16(Data()))
        XCTAssertNil(WatchRemoteProtocol.decodePCM16(Data([0x01])))
    }

    func testAudioEnvelopeCarriesStreamSequenceAndEightyMillisecondsOfPCM() throws {
        XCTAssertEqual(WatchRemoteProtocol.audioPacketDurationMilliseconds, 80)
        XCTAssertEqual(WatchRemoteProtocol.audioPacketSampleCount, 1_280)

        let streamID = UUID()
        let samples = Array(
            repeating: Int16(-1_234),
            count: WatchRemoteProtocol.audioPacketSampleCount
        )
        let pcmData = WatchRemoteProtocol.pcm16Data(samples: samples)
        let encoded = try XCTUnwrap(WatchRemoteProtocol.audioEnvelopeData(
            streamID: streamID,
            profileRevision: 12,
            sequence: 42,
            pcm16Data: pcmData
        ))
        let decoded = try XCTUnwrap(WatchRemoteProtocol.audioEnvelope(from: encoded))

        XCTAssertEqual(decoded.protocolVersion, WatchRemoteProtocol.version)
        XCTAssertEqual(decoded.streamID, streamID)
        XCTAssertEqual(decoded.profileRevision, 12)
        XCTAssertEqual(decoded.sequence, 42)
        XCTAssertEqual(decoded.pcm16Data, pcmData)
        XCTAssertEqual(
            WatchRemoteProtocol.decodePCM16(decoded.pcm16Data),
            samples
        )
        XCTAssertNil(WatchRemoteProtocol.audioEnvelopeData(
            streamID: streamID,
            profileRevision: 12,
            sequence: 0,
            pcm16Data: Data()
        ))
        XCTAssertNil(WatchRemoteProtocol.audioEnvelopeData(
            streamID: streamID,
            profileRevision: 12,
            sequence: 0,
            pcm16Data: WatchRemoteProtocol.pcm16Data(samples: [1, 2])
        ))
        XCTAssertNil(WatchRemoteProtocol.audioEnvelope(from: Data([0x01])))
    }

    func testAudioStreamGateBuffersOutOfOrderAndAdvancesOnlyContinuousWatermark() {
        let firstStreamID = UUID()
        let secondStreamID = UUID()
        let pcmData = WatchRemoteProtocol.pcm16Data(samples: [1, 2])
        var gate = WatchRemoteAudioStreamGate()

        func envelope(
            streamID: UUID,
            profileRevision: Int = 5,
            sequence: UInt64
        ) -> WatchRemoteAudioEnvelope {
            WatchRemoteAudioEnvelope(
                protocolVersion: WatchRemoteProtocol.version,
                streamID: streamID,
                profileRevision: profileRevision,
                sequence: sequence,
                pcm16Data: pcmData
            )
        }

        XCTAssertFalse(gate.insert(envelope(streamID: firstStreamID, sequence: 0)).accepted)
        gate.start(streamID: firstStreamID, profileRevision: 5)
        let zero = gate.insert(envelope(streamID: firstStreamID, sequence: 0))
        XCTAssertTrue(zero.accepted)
        XCTAssertEqual(zero.readyEnvelopes.map(\.sequence), [0])
        XCTAssertEqual(zero.contiguousThrough, 0)

        XCTAssertFalse(gate.insert(envelope(
            streamID: firstStreamID,
            profileRevision: 6,
            sequence: 1
        )).accepted)
        XCTAssertFalse(gate.insert(envelope(streamID: firstStreamID, sequence: 0)).accepted)

        // This models packet 0, then packet 2, then voiceStop(final: 2).
        // Packet 2 is retained but the stop is not drained because the
        // continuous watermark remains at 0 until packet 1 arrives.
        let two = gate.insert(envelope(streamID: firstStreamID, sequence: 2))
        XCTAssertTrue(two.accepted)
        XCTAssertTrue(two.readyEnvelopes.isEmpty)
        XCTAssertEqual(two.contiguousThrough, 0)
        XCTAssertLessThan(try XCTUnwrap(gate.contiguousThrough), 2)

        let one = gate.insert(envelope(streamID: firstStreamID, sequence: 1))
        XCTAssertTrue(one.accepted)
        XCTAssertEqual(one.readyEnvelopes.map(\.sequence), [1, 2])
        XCTAssertEqual(one.contiguousThrough, 2)
        XCTAssertEqual(gate.lastAcceptedSequence, 2)
        XCTAssertFalse(gate.insert(envelope(streamID: firstStreamID, sequence: 1)).accepted)
        XCTAssertFalse(gate.insert(envelope(streamID: secondStreamID, sequence: 3)).accepted)
        XCTAssertFalse(gate.stop(streamID: secondStreamID, profileRevision: 5))
        XCTAssertFalse(gate.stop(streamID: firstStreamID, profileRevision: 6))
        XCTAssertEqual(gate.activeStreamID, firstStreamID)
        XCTAssertTrue(gate.stop(streamID: firstStreamID, profileRevision: 5))
        XCTAssertNil(gate.activeStreamID)
        XCTAssertNil(gate.activeProfileRevision)
        XCTAssertNil(gate.lastAcceptedSequence)
        XCTAssertFalse(gate.insert(envelope(streamID: firstStreamID, sequence: 3)).accepted)

        gate.start(streamID: secondStreamID, profileRevision: 5)
        XCTAssertTrue(gate.insert(envelope(streamID: secondStreamID, sequence: 0)).accepted)
        XCTAssertFalse(gate.insert(envelope(
            streamID: secondStreamID,
            sequence: UInt64(WatchRemoteProtocol.audioReorderWindowPackets + 2)
        )).accepted)
    }

    func testAudioAcknowledgementRoundTripAndFinalWatermarkTracking() throws {
        let streamID = UUID()
        let encoded = try XCTUnwrap(WatchRemoteProtocol.audioAckData(
            streamID: streamID,
            profileRevision: 7,
            sequence: 2,
            accepted: true,
            contiguousThrough: 0
        ))
        let acknowledgement = try XCTUnwrap(
            WatchRemoteProtocol.audioAcknowledgement(from: encoded)
        )
        XCTAssertEqual(acknowledgement.streamID, streamID)
        XCTAssertEqual(acknowledgement.profileRevision, 7)
        XCTAssertEqual(acknowledgement.sequence, 2)
        XCTAssertTrue(acknowledgement.accepted)
        XCTAssertEqual(acknowledgement.contiguousThrough, 0)
        XCTAssertNil(WatchRemoteProtocol.audioAckData(
            streamID: streamID,
            profileRevision: -1,
            sequence: 1,
            accepted: true,
            contiguousThrough: 2
        ))

        var tracker = WatchRemoteAudioAckTracker()
        tracker.start(streamID: streamID, profileRevision: 7)
        tracker.recordSent(sequence: 0)
        tracker.recordSent(sequence: 1)
        tracker.recordSent(sequence: 2)
        XCTAssertEqual(tracker.beginFinalization(finalSequence: 2), .waiting)
        XCTAssertEqual(tracker.accept(acknowledgement), .waiting)

        let finalAck = WatchRemoteAudioAcknowledgement(
            protocolVersion: WatchRemoteProtocol.version,
            streamID: streamID,
            profileRevision: 7,
            sequence: 1,
            accepted: true,
            contiguousThrough: 2
        )
        XCTAssertEqual(tracker.accept(finalAck), .finalized)
        XCTAssertEqual(tracker.contiguousThrough, 2)

        let rejected = WatchRemoteAudioAcknowledgement(
            protocolVersion: WatchRemoteProtocol.version,
            streamID: streamID,
            profileRevision: 7,
            sequence: 2,
            accepted: false,
            contiguousThrough: 2
        )
        XCTAssertEqual(tracker.accept(rejected), .rejected)
    }

    func testAudioMailboxAtomicallyIncludesCapturedTailBeforeClosing() {
        let mailbox = WatchRemoteAudioMailbox()
        mailbox.begin()
        XCTAssertTrue(mailbox.enqueue(Data([0])))
        XCTAssertTrue(mailbox.enqueue(Data([1])))
        XCTAssertEqual(mailbox.drain(), [Data([0]), Data([1])])

        XCTAssertTrue(mailbox.enqueue(Data([2])))
        XCTAssertEqual(
            mailbox.finishAndDrain(finalPacket: Data([3])),
            [Data([2]), Data([3])]
        )
        XCTAssertFalse(mailbox.enqueue(Data([4])))
        XCTAssertTrue(mailbox.drain().isEmpty)
    }
}
