import XCTest
@testable import WristRemoteBridge

final class BridgePreferencesTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "dev.wristremote.bridge.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testPersistsOnlyBridgeOwnedKeys() {
        let store = BridgePreferences(defaults: defaults)
        let app = BridgeApplicationProfile(
            title: "  Example  ",
            bundleIdentifier: "com.example.App",
            applicationPath: "/Applications/Example.app"
        )
        store.trust("fingerprint")
        store.applicationProfiles = [app]
        store.codexPinnedThreadID = "11111111-1111-4111-8111-111111111111"
        XCTAssertEqual(store.trustedIdentityFingerprints, ["fingerprint"])
        XCTAssertEqual(store.applicationProfiles.first?.title, "Example")
        XCTAssertEqual(
            Set(defaults.persistentDomain(forName: suiteName)?.keys.map { $0 } ?? []),
            [
                BridgePreferences.trustedIdentityFingerprintsKey,
                BridgePreferences.applicationProfilesKey,
                BridgePreferences.codexPinnedThreadIDKey,
            ]
        )
        XCTAssertEqual(
            store.codexPinnedThreadID,
            "11111111-1111-4111-8111-111111111111"
        )
    }

    func testNormalizesAndDeduplicatesApplicationProfiles() {
        let id = UUID()
        let profiles = BridgePreferences.normalizedProfiles([
            BridgeApplicationProfile(
                id: id,
                title: "  Example App ",
                bundleIdentifier: " org.example.primary ",
                applicationPath: " /Applications/Example App.app "
            ),
            BridgeApplicationProfile(
                id: id,
                title: "Duplicate",
                bundleIdentifier: "com.example.duplicate",
                applicationPath: "/Applications/Duplicate.app"
            ),
        ])
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles[0].title, "Example App")
        XCTAssertEqual(profiles[0].bundleIdentifier, "org.example.primary")
        XCTAssertEqual(profiles[0].applicationPath, "/Applications/Example App.app")
    }

    func testCodexTaskStateRevisionPersistsAndAdvancesAcrossInstances() {
        let first = BridgePreferences(defaults: defaults)
        XCTAssertEqual(first.nextCodexTaskStateRevision(), 1)
        XCTAssertEqual(first.nextCodexTaskStateRevision(), 2)

        let relaunched = BridgePreferences(defaults: defaults)
        XCTAssertEqual(relaunched.nextCodexTaskStateRevision(), 3)
    }

    func testPersistsValidatedWatchProfileAndRejectsCorruptData() throws {
        let store = BridgePreferences(defaults: defaults)
        let disabled = WatchActionBindingWire(action: .disabled)
        let bindings = Dictionary(
            uniqueKeysWithValues: WatchActionProfileWire.buttonIDs.map { buttonID in
                (
                    buttonID,
                    Dictionary(
                        uniqueKeysWithValues: WatchActionProfileWire.triggerIDs.map {
                            ($0, disabled)
                        }
                    )
                )
            }
        )
        let profile = WatchActionProfileWire(revision: 7, bindings: bindings)

        store.watchActionProfile = profile
        XCTAssertEqual(store.watchActionProfile, try profile.validatedAndNormalized())

        defaults.set(Data("not-json".utf8), forKey: BridgePreferences.watchActionProfileKey)
        XCTAssertNil(store.watchActionProfile)
    }
}
