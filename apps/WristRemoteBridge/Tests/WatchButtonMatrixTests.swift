import XCTest
@testable import WristRemoteBridge

@MainActor
final class WatchButtonMatrixTests: XCTestCase {
    private func triggers(_ commands: [WatchGestureRecognizer.Command]) -> [WatchGestureRecognizer.Command] {
        commands.filter { if case .trigger = $0 { return true }; return false }
    }

    func testEveryButtonSingleAndDoubleClickExactlyOnce() {
        XCTAssertEqual(WristRemoteButton.allCases.count, 12)
        for button in WristRemoteButton.allCases {
            var single = WatchGestureRecognizer()
            _ = single.handle(.press, button: button, recognizesDoubleClick: true, recognizesLongPress: true)
            XCTAssertTrue(triggers(single.handle(.release, button: button, recognizesDoubleClick: true, recognizesLongPress: true)).isEmpty)
            XCTAssertEqual(single.doubleClickTimedOut(button), [.trigger(button, .singleClick)], button.rawValue)
            XCTAssertTrue(single.doubleClickTimedOut(button).isEmpty)
            XCTAssertTrue(single.longPressTimedOut(button).isEmpty)

            var double = WatchGestureRecognizer()
            for phase in [WristRemoteButtonPhase.press, .release, .press] {
                XCTAssertTrue(triggers(double.handle(phase, button: button, recognizesDoubleClick: true, recognizesLongPress: true)).isEmpty)
            }
            XCTAssertEqual(triggers(double.handle(.release, button: button, recognizesDoubleClick: true, recognizesLongPress: true)), [.trigger(button, .doubleClick)], button.rawValue)
            XCTAssertTrue(double.doubleClickTimedOut(button).isEmpty)
            XCTAssertTrue(double.longPressTimedOut(button).isEmpty)
        }
    }

    func testEveryButtonLongPressRejectsRepeatedTimeoutAndRelease() {
        for button in WristRemoteButton.allCases {
            var recognizer = WatchGestureRecognizer()
            _ = recognizer.handle(.press, button: button, recognizesDoubleClick: true, recognizesLongPress: true)
            XCTAssertEqual(recognizer.longPressTimedOut(button), [.trigger(button, .longPress)])
            XCTAssertTrue(recognizer.longPressTimedOut(button).isEmpty, "Repeated timeout must not repeat \(button.rawValue)")
            XCTAssertTrue(triggers(recognizer.handle(.release, button: button, recognizesDoubleClick: true, recognizesLongPress: true)).isEmpty)
            XCTAssertTrue(recognizer.doubleClickTimedOut(button).isEmpty)
        }
    }

    func testAllThirtySixBindingsRouteToTheirOwnSlotWithoutSystemEvents() {
        let dispatcher = WatchGestureDispatcher()
        var received: [WatchActionBindingWire] = []
        dispatcher.onBinding = { received.append($0); return true }
        var bindings: [String: [String: WatchActionBindingWire]] = [:]
        var index: UInt16 = 0
        for button in WristRemoteButton.allCases {
            for trigger in WristRemoteTrigger.allCases {
                bindings[button.rawValue, default: [:]][trigger.rawValue] = .init(action: .customShortcut,
                    shortcut: .init(keyCode: index, modifierFlagsRawValue: 0, keyLabel: "Test \(index)"))
                index += 1
            }
        }
        XCTAssertEqual(index, 36)
        XCTAssertTrue(dispatcher.install(.init(revision: 1, bindings: bindings)))
        for button in WristRemoteButton.allCases {
            for trigger in WristRemoteTrigger.allCases {
                let before = received.count
                XCTAssertTrue(dispatcher.trigger(trigger, button: button))
                XCTAssertEqual(received.count, before + 1)
                XCTAssertEqual(received.last, bindings[button.rawValue]?[trigger.rawValue])
            }
        }
        XCTAssertEqual(received.count, 36)
        dispatcher.reset()
        for button in WristRemoteButton.allCases {
            for trigger in WristRemoteTrigger.allCases {
                XCTAssertFalse(dispatcher.trigger(trigger, button: button))
            }
        }
        XCTAssertEqual(received.count, 36, "Disconnected/reset profiles must not emit more actions")
    }

    func testEveryButtonCancelDropsAllPendingGestures() {
        for button in WristRemoteButton.allCases {
            var recognizer = WatchGestureRecognizer()
            _ = recognizer.handle(.press, button: button, recognizesDoubleClick: true, recognizesLongPress: true)
            recognizer.cancel(button)
            XCTAssertTrue(recognizer.longPressTimedOut(button).isEmpty)
            XCTAssertTrue(recognizer.doubleClickTimedOut(button).isEmpty)
            XCTAssertTrue(recognizer.handle(.release, button: button, recognizesDoubleClick: true, recognizesLongPress: true).isEmpty)
        }
    }
}
