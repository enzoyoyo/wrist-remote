import CoreGraphics
import XCTest
@testable import WristRemoteBridge

@MainActor
final class WatchActionEngineTests: XCTestCase {
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

    func testShowDesktopUsesF11WithoutModifierFlags() {
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
        XCTAssertEqual(received?.1, [])
        XCTAssertFalse(received?.1.contains(.maskSecondaryFn) ?? true)
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
