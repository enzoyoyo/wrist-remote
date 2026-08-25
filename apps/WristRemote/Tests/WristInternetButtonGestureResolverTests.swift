import XCTest
@testable import WristRemote

final class WristInternetButtonGestureResolverTests: XCTestCase {
    func testSingleClickCommitsImmediatelyWhenDoubleClickIsDisabled() {
        var resolver = WristInternetButtonGestureResolver()
        XCTAssertEqual(
            resolver.press(
                .ok,
                profileRevision: 7,
                recognizesDoubleClick: false,
                recognizesLongPress: false
            ),
            .init(shouldCancelSingleClick: false, shouldScheduleLongPress: false)
        )
        XCTAssertEqual(
            resolver.release(.ok, profileRevision: 7),
            .commit(.singleClick)
        )
    }

    func testDoubleClickIsResolvedWithoutNetworkTiming() {
        var resolver = WristInternetButtonGestureResolver()
        _ = resolver.press(
            .ok,
            profileRevision: 7,
            recognizesDoubleClick: true,
            recognizesLongPress: true
        )
        XCTAssertEqual(
            resolver.release(.ok, profileRevision: 7),
            .scheduleSingleClick
        )
        XCTAssertEqual(
            resolver.press(
                .ok,
                profileRevision: 7,
                recognizesDoubleClick: true,
                recognizesLongPress: true
            ),
            .init(shouldCancelSingleClick: true, shouldScheduleLongPress: true)
        )
        XCTAssertEqual(
            resolver.release(.ok, profileRevision: 7),
            .commit(.doubleClick)
        )
        XCTAssertNil(resolver.singleClickTimedOut(.ok, profileRevision: 7))
    }

    func testLongPressRequiresExplicitLocalThreshold() {
        var resolver = WristInternetButtonGestureResolver()
        _ = resolver.press(
            .ok,
            profileRevision: 7,
            recognizesDoubleClick: true,
            recognizesLongPress: true
        )
        XCTAssertEqual(
            resolver.longPressTimedOut(.ok, profileRevision: 7),
            .longPress
        )
        XCTAssertNil(resolver.longPressTimedOut(.ok, profileRevision: 7))
        XCTAssertEqual(
            resolver.release(.ok, profileRevision: 7),
            WristInternetButtonGestureResolver.ReleaseOutcome.none
        )
        XCTAssertNil(resolver.singleClickTimedOut(.ok, profileRevision: 7))
    }

    func testFirstClickTimerCommitsSingleAndRejectsStaleRevision() {
        var resolver = WristInternetButtonGestureResolver()
        _ = resolver.press(
            .home,
            profileRevision: 4,
            recognizesDoubleClick: true,
            recognizesLongPress: false
        )
        XCTAssertEqual(
            resolver.release(.home, profileRevision: 4),
            .scheduleSingleClick
        )
        XCTAssertNil(resolver.singleClickTimedOut(.home, profileRevision: 5))
        XCTAssertEqual(
            resolver.singleClickTimedOut(.home, profileRevision: 4),
            .singleClick
        )
    }

    func testCancellationNeverCommitsAnAction() {
        var resolver = WristInternetButtonGestureResolver()
        _ = resolver.press(
            .power,
            profileRevision: 1,
            recognizesDoubleClick: true,
            recognizesLongPress: true
        )
        resolver.cancel(.power)
        XCTAssertNil(resolver.release(.power, profileRevision: 1))
        XCTAssertNil(resolver.longPressTimedOut(.power, profileRevision: 1))
    }
}
