import XCTest
@testable import WristRemote

final class WatchVoicePressStateTests: XCTestCase {
    func testQuickTapCannotFinishOrStartLater() throws {
        var state = WatchVoicePressState()
        let token = try XCTUnwrap(state.begin())
        XCTAssertFalse(state.end())
        XCTAssertFalse(state.recognize(generation: token, canStart: true))
        XCTAssertEqual(state.phase, .idle)
    }

    func testDeliberateHoldAndReleaseFinishesExactlyOnce() throws {
        var state = WatchVoicePressState()
        let token = try XCTUnwrap(state.begin())
        XCTAssertTrue(state.recognize(generation: token, canStart: true))
        XCTAssertFalse(state.recognize(generation: token, canStart: true))
        XCTAssertTrue(state.end())
        XCTAssertFalse(state.end())
    }

    func testScrollBeforeHoldCancelsUntilFingerLifts() throws {
        var state = WatchVoicePressState()
        let token = try XCTUnwrap(state.begin())
        XCTAssertFalse(state.move(distance: 19))
        XCTAssertEqual(state.phase, .cancelled)
        XCTAssertNil(state.begin())
        XCTAssertFalse(state.recognize(generation: token, canStart: true))
        XCTAssertFalse(state.move(distance: 0))
        XCTAssertFalse(state.end())
        XCTAssertNotNil(state.begin())
    }

    func testDragAfterHoldCancelsRatherThanFinishes() throws {
        var state = WatchVoicePressState()
        let token = try XCTUnwrap(state.begin())
        XCTAssertTrue(state.recognize(generation: token, canStart: true))
        XCTAssertTrue(state.move(distance: 35))
        XCTAssertFalse(state.move(distance: 36), "Cancel only once")
        XCTAssertFalse(state.end(), "Lift after cancelling must not submit")
    }

    func testSmallMovementAllowsNaturalFingerJitter() throws {
        var state = WatchVoicePressState()
        let token = try XCTUnwrap(state.begin())
        XCTAssertFalse(state.move(distance: 10))
        XCTAssertTrue(state.recognize(generation: token, canStart: true))
        XCTAssertFalse(state.move(distance: 30))
        XCTAssertTrue(state.end())
    }

    func testStaleHoldCannotStartNewContact() throws {
        var state = WatchVoicePressState()
        let oldToken = try XCTUnwrap(state.begin())
        state.reset()
        let newToken = try XCTUnwrap(state.begin())
        XCTAssertFalse(state.recognize(generation: oldToken, canStart: true))
        XCTAssertTrue(state.recognize(generation: newToken, canStart: true))
    }

    func testDisconnectDuringArmingDoesNotStartRecording() throws {
        var state = WatchVoicePressState()
        let token = try XCTUnwrap(state.begin())
        XCTAssertFalse(state.recognize(generation: token, canStart: false))
        XCTAssertFalse(state.end())
    }

    func testSystemCancellationResetsActiveContactWithoutFinish() throws {
        var state = WatchVoicePressState()
        let token = try XCTUnwrap(state.begin())
        XCTAssertTrue(state.recognize(generation: token, canStart: true))
        state.reset()
        XCTAssertFalse(state.end())
        XCTAssertFalse(state.recognize(generation: token, canStart: true))
    }

    func testInvalidGeometryFailsClosed() throws {
        for distance in [Double.nan, .infinity] {
            var state = WatchVoicePressState()
            let token = try XCTUnwrap(state.begin())
            XCTAssertTrue(state.recognize(generation: token, canStart: true))
            XCTAssertTrue(state.move(distance: distance))
            XCTAssertFalse(state.end())
        }
    }
}
