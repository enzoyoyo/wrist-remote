import CoreGraphics
import XCTest
@testable import WristRemoteBridge

@MainActor
final class WatchActionEngineTests: XCTestCase {
    func testEveryBuiltinKeyAndMediaActionUsesItsExactEvent() {
        let keyboard: [WatchActionKindWire: (CGKeyCode, CGEventFlags)] = [
            .escape: (53, []), .returnKey: (36, []),
            .commandReturn: (36, .maskCommand), .shiftReturn: (36, .maskShift),
            .commandCopy: (8, .maskCommand), .commandPaste: (9, .maskCommand),
            .commandQuit: (12, .maskCommand),
            .arrowUp: (126, []), .arrowDown: (125, []),
            .arrowLeft: (123, []), .arrowRight: (124, []),
            .deleteBackward: (51, []), .showDesktop: (103, .maskSecondaryFn),
            .appSwitcher: (48, .maskCommand),
            .previousCommandLeft: (123, .maskCommand), .nextCommandRight: (124, .maskCommand),
        ]
        let media: [WatchActionKindWire: Int32] = [
            .volumeUp: 0, .volumeDown: 1, .volumeMute: 7, .playPause: 16,
        ]
        XCTAssertEqual(keyboard.count + media.count + 4, WatchActionKindWire.allCases.count)
        for (action, expected) in keyboard {
            var events: [(CGKeyCode, CGEventFlags)] = []
            var dependencies = inertDependencies()
            dependencies.isAccessibilityTrusted = { true }
            dependencies.postKey = { events.append(($0, $1)); return true }
            let engine = WatchActionEngine(dependencies: dependencies)
            XCTAssertTrue(engine.perform(.init(action: action)), action.rawValue)
            XCTAssertEqual(events.count, 1, action.rawValue)
            XCTAssertEqual(events.first?.0, expected.0, action.rawValue)
            XCTAssertEqual(events.first?.1, expected.1, action.rawValue)
        }
        for (action, expected) in media {
            var events: [Int32] = []
            var dependencies = inertDependencies()
            dependencies.isAccessibilityTrusted = { true }
            dependencies.postSystemKey = { events.append($0); return true }
            let engine = WatchActionEngine(dependencies: dependencies)
            XCTAssertTrue(engine.perform(.init(action: action)), action.rawValue)
            XCTAssertEqual(events, [expected])
        }
        let denied = WatchActionEngine(dependencies: inertDependencies())
        for action in keyboard.keys { XCTAssertFalse(denied.perform(.init(action: action))) }
        for action in media.keys { XCTAssertFalse(denied.perform(.init(action: action))) }
        XCTAssertTrue(denied.perform(.init(action: .disabled)))
    }

    func testCustomAppRequiresBridgeOwnedCatalogEntry() {
        let id = UUID()
        let engine = WatchActionEngine(dependencies: inertDependencies())
        let profile = makeProfile(
            replacing: WatchActionBindingWire(
                action: .openCustomApplication,
                applicationProfileID: id.uuidString
            )
        )
        XCTAssertFalse(engine.canInstall(profile))
        engine.updateApplicationProfiles([
            BridgeApplicationProfile(
                id: id,
                title: "Example",
                bundleIdentifier: "com.example.App",
                applicationPath: "/Applications/Example.app"
            ),
        ])
        XCTAssertTrue(engine.canInstall(profile))
    }

    func testCustomShortcutUsesWireKeyAndModifiers() {
        var received: (CGKeyCode, CGEventFlags)?
        var dependencies = inertDependencies()
        dependencies.isAccessibilityTrusted = { true }
        dependencies.postKey = { key, flags in
            received = (key, flags)
            return true
        }
        let engine = WatchActionEngine(dependencies: dependencies)
        let binding = WatchActionBindingWire(
            action: .customShortcut,
            shortcut: WatchShortcutWire(
                keyCode: 8,
                modifierFlagsRawValue: UInt(1 << 20) | UInt(1 << 23),
                keyLabel: "C"
            )
        )
        XCTAssertTrue(engine.perform(binding))
        XCTAssertEqual(received?.0, 8)
        XCTAssertEqual(received?.1, .maskCommand)
        XCTAssertFalse(received?.1.contains(.maskSecondaryFn) ?? true)
    }

    func testShowDesktopUsesTheSystemFnF11Shortcut() {
        var received: (CGKeyCode, CGEventFlags)?
        var dependencies = inertDependencies()
        dependencies.isAccessibilityTrusted = { true }
        dependencies.postKey = { key, flags in
            received = (key, flags)
            return true
        }
        let engine = WatchActionEngine(dependencies: dependencies)

        XCTAssertTrue(engine.perform(WatchActionBindingWire(action: .showDesktop)))
        XCTAssertEqual(received?.0, 103)
        XCTAssertEqual(received?.1, .maskSecondaryFn)
    }

    func testContextMenuUsesNativeActionAndRespectsPermissionAndFailure() {
        var count = 0
        var dependencies = inertDependencies()
        dependencies.showContextMenu = { count += 1; return true }
        XCTAssertFalse(WatchActionEngine(dependencies: dependencies).perform(.init(action: .contextMenu)))
        XCTAssertEqual(count, 0)
        dependencies.isAccessibilityTrusted = { true }
        XCTAssertTrue(WatchActionEngine(dependencies: dependencies).perform(.init(action: .contextMenu)))
        XCTAssertEqual(count, 1)
        dependencies.showContextMenu = { false }
        XCTAssertFalse(WatchActionEngine(dependencies: dependencies).perform(.init(action: .contextMenu)))
    }

    func testSystemChordsReleaseTheirAddedModifiers() {
        for (key, flag, modifier) in [(CGKeyCode(48), CGEventFlags.maskCommand, CGKeyCode(55)),
                                     (103, .maskSecondaryFn, 63)] {
            let steps = WatchActionEngine.keyboardSequence(keyCode: key, flags: flag, heldFlags: [])
            XCTAssertEqual(steps.map(\.keyCode), [modifier, key, key, modifier])
            XCTAssertEqual(steps.map(\.isDown), [true, true, false, false])
            XCTAssertEqual(steps.map(\.isModifier), [true, false, false, true])
            XCTAssertEqual(steps.map(\.flags), [flag, flag, flag, []])
        }
        let held = WatchActionEngine.keyboardSequence(keyCode: 48, flags: .maskCommand, heldFlags: .maskCommand)
        XCTAssertEqual(held.map(\.keyCode), [48, 48])
        XCTAssertTrue(held.allSatisfy { $0.flags == .maskCommand && !$0.isModifier })
        let shift = WatchActionEngine.keyboardSequence(keyCode: 48, flags: .maskCommand, heldFlags: .maskShift)
        XCTAssertEqual(shift.last?.flags, .maskShift)
        XCTAssertFalse(shift.contains { $0.keyCode == 56 })
        let afterFunctionKey = WatchActionEngine.keyboardSequence(
            keyCode: 48, flags: .maskCommand,
            heldFlags: CGEventFlags(rawValue: 0x20800000)
        )
        XCTAssertEqual(afterFunctionKey.map(\.flags), [.maskCommand, .maskCommand, .maskCommand, []])
    }

    private func inertDependencies() -> WatchActionEngine.Dependencies {
        WatchActionEngine.Dependencies(
            isAccessibilityTrusted: { false },
            postKey: { _, _ in false },
            postSystemKey: { _ in false },
            openCustomApplication: { _ in false }
        )
    }

    private func makeProfile(
        replacing binding: WatchActionBindingWire
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
        bindings["ok"]?["singleClick"] = binding
        return WatchActionProfileWire(revision: 1, bindings: bindings)
    }
}
