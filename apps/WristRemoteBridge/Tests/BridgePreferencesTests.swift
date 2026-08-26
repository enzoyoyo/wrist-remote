import XCTest
@testable import WristRemoteBridge

private final class InMemoryTrustedIdentityFingerprintStore:
    TrustedIdentityFingerprintStoring
{
    var fingerprints: Set<String> = []
    var allowsSaving = true

    func load() -> Set<String> {
        fingerprints
    }

    func save(_ fingerprints: Set<String>) -> Bool {
        guard allowsSaving else { return false }
        self.fingerprints = fingerprints
        return true
    }
}

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
        let trustedIdentityStore = InMemoryTrustedIdentityFingerprintStore()
        let store = BridgePreferences(
            defaults: defaults,
            trustedIdentityStore: trustedIdentityStore
        )
        let app = BridgeApplicationProfile(
            title: "  Example  ",
            bundleIdentifier: "com.example.App",
            applicationPath: "/Applications/Example.app"
        )
        store.trust("fingerprint")
        store.applicationProfiles = [app]
        store.codexPinnedThreadID = "11111111-1111-4111-8111-111111111111"
        XCTAssertEqual(store.trustedIdentityFingerprints, ["fingerprint"])
        XCTAssertEqual(trustedIdentityStore.fingerprints, ["fingerprint"])
        XCTAssertEqual(store.applicationProfiles.first?.title, "Example")
        XCTAssertEqual(
            Set(defaults.persistentDomain(forName: suiteName)?.keys.map { $0 } ?? []),
            [
                BridgePreferences.applicationProfilesKey,
                BridgePreferences.codexPinnedThreadIDKey,
            ]
        )
        XCTAssertEqual(
            store.codexPinnedThreadID,
            "11111111-1111-4111-8111-111111111111"
        )
    }

    func testTrustedIdentityFingerprintsAreNotPersistedInUserDefaults() {
        let trustedIdentityStore = InMemoryTrustedIdentityFingerprintStore()
        let store = BridgePreferences(
            defaults: defaults,
            trustedIdentityStore: trustedIdentityStore
        )

        store.trust("fingerprint")

        XCTAssertNil(defaults.object(forKey: BridgePreferences.trustedIdentityFingerprintsKey))
        XCTAssertEqual(trustedIdentityStore.fingerprints, ["fingerprint"])
    }

    func testMigratesLegacyTrustedFingerprintsIntoSecureStore() {
        defaults.set(
            ["legacy-b", "legacy-a"],
            forKey: BridgePreferences.trustedIdentityFingerprintsKey
        )
        let trustedIdentityStore = InMemoryTrustedIdentityFingerprintStore()
        trustedIdentityStore.fingerprints = ["existing"]

        _ = BridgePreferences(
            defaults: defaults,
            trustedIdentityStore: trustedIdentityStore
        )

        XCTAssertEqual(
            trustedIdentityStore.fingerprints,
            ["existing", "legacy-a", "legacy-b"]
        )
        XCTAssertNil(defaults.object(forKey: BridgePreferences.trustedIdentityFingerprintsKey))
    }

    func testKeepsLegacyTrustedFingerprintsWhenSecureMigrationFails() {
        defaults.set(
            ["legacy"],
            forKey: BridgePreferences.trustedIdentityFingerprintsKey
        )
        let trustedIdentityStore = InMemoryTrustedIdentityFingerprintStore()
        trustedIdentityStore.allowsSaving = false

        _ = BridgePreferences(
            defaults: defaults,
            trustedIdentityStore: trustedIdentityStore
        )

        XCTAssertEqual(
            defaults.stringArray(forKey: BridgePreferences.trustedIdentityFingerprintsKey),
            ["legacy"]
        )
        XCTAssertTrue(trustedIdentityStore.fingerprints.isEmpty)
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
