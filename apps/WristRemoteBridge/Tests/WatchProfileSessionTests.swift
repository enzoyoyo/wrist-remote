import XCTest
@testable import WristRemoteBridge

final class WatchProfileSessionTests: XCTestCase {
    func testRuntimeProfileUpdateIsRejectedDuringActiveVoiceSession() {
        XCTAssertEqual(
            WatchProfileRuntimeUpdatePolicy.retryReason(hasActiveVoiceSession: true),
            .voiceActive
        )
        XCTAssertFalse(
            WatchProfileRuntimeUpdatePolicy.acceptsUpdate(hasActiveVoiceSession: true),
            "a profile swap must not invalidate a live voice stream revision"
        )
        XCTAssertTrue(
            WatchProfileRuntimeUpdatePolicy.acceptsUpdate(hasActiveVoiceSession: false),
            "the same update must become admissible after voice finishes"
        )
        XCTAssertNil(
            WatchProfileRuntimeUpdatePolicy.retryReason(hasActiveVoiceSession: false)
        )
        XCTAssertEqual(
            WatchProfileRuntimeInstallResult.retryable(.voiceActive).isAccepted,
            false
        )
        XCTAssertTrue(WatchProfileRuntimeInstallResult.accepted.isAccepted)
    }

    func testLANProfileBusyGuardLeavesLiveVoiceSessionUntouched() {
        let sessionID = UUID()
        var voice = BridgeVoiceSession()
        XCTAssertTrue(voice.begin(
            sessionID: sessionID.uuidString,
            inputSource: BridgeWireMessage.appleWatchInputSource,
            profileRevision: 3,
            acceptedProfileRevision: 3
        ))
        XCTAssertNotNil(voice.completeStart(succeeded: true))
        let originalVoice = voice

        XCTAssertEqual(
            WatchProfileRuntimeUpdatePolicy.retryReason(for: voice),
            .voiceActive
        )
        XCTAssertEqual(voice, originalVoice)
        XCTAssertTrue(voice.acceptsAudio(
            sessionID: sessionID.uuidString,
            inputSource: BridgeWireMessage.appleWatchInputSource,
            profileRevision: 3,
            acceptedProfileRevision: 3
        ))
    }

    func testProfileUpdatesRequireAppleWatchSource() {
        XCTAssertTrue(WatchProfileSession.acceptsProfileUpdateSource(
            inputSource: "appleWatch"
        ))
        XCTAssertFalse(WatchProfileSession.acceptsProfileUpdateSource(inputSource: nil))
        XCTAssertFalse(WatchProfileSession.acceptsProfileUpdateSource(
            inputSource: "nearbyPhone"
        ))
    }

    func testAcceptsOnlyAppleWatchWithExactAcknowledgedRevision() throws {
        var session = WatchProfileSession()
        let profile = makeProfile(revision: 7)
        XCTAssertEqual(session.begin(profile), .accept(profile))
        XCTAssertFalse(session.accepts(inputSource: "appleWatch", revision: 7))
        XCTAssertEqual(session.complete(revision: 7, succeeded: true), true)
        XCTAssertTrue(session.accepts(inputSource: "appleWatch", revision: 7))
        XCTAssertFalse(session.accepts(inputSource: nil, revision: 7))
        XCTAssertFalse(session.accepts(inputSource: "nearbyPhone", revision: 7))
        XCTAssertFalse(session.accepts(inputSource: "appleWatch", revision: 6))
    }

    func testStaleAndConflictingProfilesFailClosed() {
        var session = WatchProfileSession()
        let current = makeProfile(revision: 4)
        _ = session.begin(current)
        _ = session.complete(revision: 4, succeeded: true)

        guard case .reject = session.begin(makeProfile(revision: 3)) else {
            return XCTFail("stale revision must be rejected")
        }
        var conflict = current
        conflict.bindings["ok"]?["singleClick"] = WatchActionBindingWire(action: .escape)
        guard case .reject = session.begin(conflict) else {
            return XCTFail("same revision with different content must be rejected")
        }
        XCTAssertTrue(session.accepts(inputSource: "appleWatch", revision: 4))
    }

    func testPendingUpdateBlocksOldRevisionUntilCompletion() {
        var session = WatchProfileSession()
        let old = makeProfile(revision: 1)
        _ = session.begin(old)
        _ = session.complete(revision: 1, succeeded: true)
        _ = session.begin(makeProfile(revision: 2))
        XCTAssertFalse(session.accepts(inputSource: "appleWatch", revision: 1))
        XCTAssertFalse(session.accepts(inputSource: "appleWatch", revision: 2))
    }

    func testPersistedGateRejectsRollbackAndSameRevisionConflict() {
        let current = makeProfile(revision: 9)
        guard case .reject = WatchPersistedProfileGate.decide(
            candidate: makeProfile(revision: 8),
            current: current
        ) else {
            return XCTFail("a reinstalled phone must not roll back the Mac profile")
        }

        var conflict = current
        conflict.bindings["ok"]?["singleClick"] = WatchActionBindingWire(action: .escape)
        guard case .reject = WatchPersistedProfileGate.decide(
            candidate: conflict,
            current: current
        ) else {
            return XCTFail("same-revision conflicts must fail closed")
        }
    }

    func testPersistedGateIsIdempotentAndAcceptsOnlyNewerProfile() {
        let current = makeProfile(revision: 9)
        XCTAssertEqual(
            WatchPersistedProfileGate.decide(candidate: current, current: current),
            .alreadyReady(revision: 9)
        )
        let newer = makeProfile(revision: 10)
        XCTAssertEqual(
            WatchPersistedProfileGate.decide(candidate: newer, current: current),
            .accept(newer)
        )
    }

    func testVoiceFramesRequireUUIDAppleWatchSourceAndExactAcceptedRevision() {
        let streamID = UUID()
        var voice = BridgeVoiceSession()

        XCTAssertFalse(voice.begin(
            sessionID: nil,
            inputSource: "appleWatch",
            profileRevision: 3,
            acceptedProfileRevision: 3
        ))
        XCTAssertFalse(voice.begin(
            sessionID: streamID.uuidString,
            inputSource: "nearbyPhone",
            profileRevision: 3,
            acceptedProfileRevision: 3
        ))
        XCTAssertFalse(voice.begin(
            sessionID: streamID.uuidString,
            inputSource: "appleWatch",
            profileRevision: 2,
            acceptedProfileRevision: 3
        ))
        XCTAssertTrue(voice.begin(
            sessionID: streamID.uuidString,
            inputSource: "appleWatch",
            profileRevision: 3,
            acceptedProfileRevision: 3
        ))
        XCTAssertEqual(
            voice.completeStart(succeeded: true),
            .init(sessionID: streamID, profileRevision: 3)
        )
        XCTAssertTrue(voice.acceptsAudio(
            sessionID: streamID.uuidString,
            inputSource: "appleWatch",
            profileRevision: 3,
            acceptedProfileRevision: 3
        ))
        XCTAssertFalse(voice.acceptsAudio(
            sessionID: streamID.uuidString,
            inputSource: "appleWatch",
            profileRevision: 4,
            acceptedProfileRevision: 4
        ))
        XCTAssertFalse(voice.stop(
            sessionID: streamID.uuidString,
            inputSource: "appleWatch",
            profileRevision: 2,
            acceptedProfileRevision: 3
        ))
        XCTAssertTrue(voice.stop(
            sessionID: streamID.uuidString,
            inputSource: "appleWatch",
            profileRevision: 3,
            acceptedProfileRevision: 3
        ))
    }

    private func makeProfile(revision: Int) -> WatchActionProfileWire {
        WatchActionProfileWire(
            revision: revision,
            bindings: Dictionary(uniqueKeysWithValues: WatchActionProfileWire.buttonIDs.map {
                button in
                (
                    button,
                    Dictionary(uniqueKeysWithValues: WatchActionProfileWire.triggerIDs.map {
                        ($0, WatchActionBindingWire(action: .disabled))
                    })
                )
            })
        )
    }
}
