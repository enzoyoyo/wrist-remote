import XCTest
@testable import WristRemoteBridge

@MainActor
final class WatchGestureRecognizerTests: XCTestCase {
    func testSingleClickWithoutOtherGesturesTriggersOnRelease() {
        var recognizer = WatchGestureRecognizer()
        XCTAssertEqual(
            recognizer.handle(
                .press,
                button: .ok,
                recognizesDoubleClick: false,
                recognizesLongPress: false
            ),
            []
        )
        XCTAssertEqual(
            recognizer.handle(
                .release,
                button: .ok,
                recognizesDoubleClick: false,
                recognizesLongPress: false
            ),
            [.trigger(.ok, .singleClick)]
        )
    }

    func testDoubleClickSuppressesSingleClick() {
        var recognizer = WatchGestureRecognizer()
        _ = recognizer.handle(
            .press,
            button: .tv,
            recognizesDoubleClick: true,
            recognizesLongPress: false
        )
        XCTAssertEqual(
            recognizer.handle(
                .release,
                button: .tv,
                recognizesDoubleClick: true,
                recognizesLongPress: false
            ),
            [.scheduleDoubleClickTimeout(.tv)]
        )
        XCTAssertEqual(
            recognizer.handle(
                .press,
                button: .tv,
                recognizesDoubleClick: true,
                recognizesLongPress: false
            ),
            [.cancelDoubleClickTimeout(.tv)]
        )
        XCTAssertEqual(
            recognizer.handle(
                .release,
                button: .tv,
                recognizesDoubleClick: true,
                recognizesLongPress: false
            ),
            [.trigger(.tv, .doubleClick)]
        )
    }

    func testLongPressSuppressesClickOnRelease() {
        var recognizer = WatchGestureRecognizer()
        _ = recognizer.handle(
            .press,
            button: .menu,
            recognizesDoubleClick: false,
            recognizesLongPress: true
        )
        XCTAssertEqual(
            recognizer.longPressTimedOut(.menu),
            [.trigger(.menu, .longPress)]
        )
        XCTAssertEqual(
            recognizer.handle(
                .release,
                button: .menu,
                recognizesDoubleClick: false,
                recognizesLongPress: true
            ),
            [.cancelLongPressTimeout(.menu)]
        )
    }

    func testResetCancelsDelayedSingleClickFromOldGeneration() async {
        let dispatcher = WatchGestureDispatcher()
        var actions: [WatchActionKindWire] = []
        dispatcher.onBinding = { binding in
            actions.append(binding.action)
            return true
        }
        XCTAssertTrue(dispatcher.install(makeProfile(
            single: .escape,
            double: .returnKey,
            long: .disabled
        )))
        XCTAssertTrue(dispatcher.handle(.press, button: .ok))
        XCTAssertTrue(dispatcher.handle(.release, button: .ok))
        dispatcher.reset()

        try? await Task.sleep(for: .milliseconds(450))
        XCTAssertTrue(actions.isEmpty)
    }

    func testInstallingNewProfileCancelsOldLongPressGeneration() async {
        let dispatcher = WatchGestureDispatcher()
        var actions: [WatchActionKindWire] = []
        dispatcher.onBinding = { binding in
            actions.append(binding.action)
            return true
        }
        XCTAssertTrue(dispatcher.install(makeProfile(
            single: .disabled,
            double: .disabled,
            long: .commandQuit
        )))
        XCTAssertTrue(dispatcher.handle(.press, button: .ok))
        XCTAssertTrue(dispatcher.install(makeProfile(
            single: .returnKey,
            double: .disabled,
            long: .disabled,
            revision: 2
        )))

        try? await Task.sleep(for: .milliseconds(750))
        XCTAssertTrue(actions.isEmpty)
    }

    func testCancellingDisconnectedPressHasNoActionAndKeepsProfile() async {
        let dispatcher = WatchGestureDispatcher()
        var actions: [WatchActionKindWire] = []
        dispatcher.onBinding = { binding in
            actions.append(binding.action)
            return true
        }
        let profile = makeProfile(
            single: .escape,
            double: .returnKey,
            long: .commandQuit
        )
        XCTAssertTrue(dispatcher.install(profile))
        XCTAssertTrue(dispatcher.handle(.press, button: .ok))
        dispatcher.cancel(.ok)

        try? await Task.sleep(for: .milliseconds(750))
        XCTAssertTrue(actions.isEmpty)
        XCTAssertEqual(dispatcher.profile, profile)
        XCTAssertTrue(dispatcher.handle(.release, button: .ok))
        XCTAssertTrue(actions.isEmpty)
    }

    func testResolvedInternetTriggerExecutesExactlyTheSelectedBinding() {
        let dispatcher = WatchGestureDispatcher()
        var actions: [WatchActionKindWire] = []
        dispatcher.onBinding = { binding in
            actions.append(binding.action)
            return true
        }
        XCTAssertTrue(dispatcher.install(makeProfile(
            single: .escape,
            double: .returnKey,
            long: .commandQuit
        )))

        XCTAssertTrue(dispatcher.trigger(.doubleClick, button: .ok))
        XCTAssertEqual(actions, [.returnKey])
        XCTAssertFalse(dispatcher.trigger(.singleClick, button: .tv))
        XCTAssertEqual(actions, [.returnKey])
    }

    private func makeProfile(
        single: WatchActionKindWire,
        double: WatchActionKindWire,
        long: WatchActionKindWire,
        revision: Int = 1
    ) -> WatchActionProfileWire {
        var bindings = Dictionary(uniqueKeysWithValues: WatchActionProfileWire.buttonIDs.map {
            button in
            (
                button,
                Dictionary(uniqueKeysWithValues: WatchActionProfileWire.triggerIDs.map {
                    ($0, WatchActionBindingWire(action: .disabled))
                })
            )
        })
        bindings["ok"]?["singleClick"] = WatchActionBindingWire(action: single)
        bindings["ok"]?["doubleClick"] = WatchActionBindingWire(action: double)
        bindings["ok"]?["longPress"] = WatchActionBindingWire(action: long)
        return WatchActionProfileWire(revision: revision, bindings: bindings)
    }
}
