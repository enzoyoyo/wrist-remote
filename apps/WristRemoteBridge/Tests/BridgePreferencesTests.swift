import Security
import XCTest
@testable import WristRemoteBridge

private final class InMemoryTrustedIdentityFingerprintStore:
    TrustedIdentityFingerprintStoring
{
    var loadResult: TrustedIdentityFingerprintLoadResult = .notFound
    var allowsSaving = true
    private(set) var saveCallCount = 0

    var fingerprints: Set<String> {
        get {
            guard case let .loaded(fingerprints) = loadResult else { return [] }
            return fingerprints
        }
        set {
            loadResult = .loaded(newValue)
        }
    }

    func load() -> TrustedIdentityFingerprintLoadResult {
        loadResult
    }

    func save(_ fingerprints: Set<String>) -> Bool {
        saveCallCount += 1
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
        XCTAssertTrue(store.trust("fingerprint"))
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

        XCTAssertTrue(store.trust("fingerprint"))

        XCTAssertNil(defaults.object(forKey: BridgePreferences.trustedIdentityFingerprintsKey))
        XCTAssertEqual(trustedIdentityStore.fingerprints, ["fingerprint"])
    }

    func testTrustFailsClosedWhenSecureStoreCannotSave() {
        let trustedIdentityStore = InMemoryTrustedIdentityFingerprintStore()
        trustedIdentityStore.allowsSaving = false
        let store = BridgePreferences(
            defaults: defaults,
            trustedIdentityStore: trustedIdentityStore
        )

        XCTAssertFalse(store.trust("fingerprint"))
        XCTAssertFalse(store.trusts("fingerprint"))
        XCTAssertTrue(trustedIdentityStore.fingerprints.isEmpty)
    }

    func testTrustDoesNotOverwriteUnavailableSecureStore() {
        let trustedIdentityStore = InMemoryTrustedIdentityFingerprintStore()
        trustedIdentityStore.loadResult = .unavailable
        let store = BridgePreferences(
            defaults: defaults,
            trustedIdentityStore: trustedIdentityStore
        )

        XCTAssertFalse(store.trust("fingerprint"))
        XCTAssertFalse(store.trusts("fingerprint"))
        XCTAssertEqual(trustedIdentityStore.saveCallCount, 0)
        XCTAssertEqual(trustedIdentityStore.loadResult, .unavailable)
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

    func testKeepsLegacyTrustedFingerprintsWhenSecureStoreIsUnavailable() {
        defaults.set(
            ["legacy"],
            forKey: BridgePreferences.trustedIdentityFingerprintsKey
        )
        let trustedIdentityStore = InMemoryTrustedIdentityFingerprintStore()
        trustedIdentityStore.loadResult = .unavailable

        _ = BridgePreferences(
            defaults: defaults,
            trustedIdentityStore: trustedIdentityStore
        )

        XCTAssertEqual(
            defaults.stringArray(forKey: BridgePreferences.trustedIdentityFingerprintsKey),
            ["legacy"]
        )
        XCTAssertEqual(trustedIdentityStore.saveCallCount, 0)
        XCTAssertEqual(trustedIdentityStore.loadResult, .unavailable)
    }

    func testKeychainLoadClassificationDistinguishesMissingCorruptAndLoaded() throws {
        let expected = ["fingerprint-a", "fingerprint-b"]
        let encoded = try JSONEncoder().encode(expected)

        switch WristInternetRelayKeychain.classifyLoad(
            [String].self,
            copyStatus: errSecItemNotFound,
            data: nil
        ) {
        case .notFound:
            break
        case .loaded, .unavailable:
            XCTFail("A genuinely missing item must remain distinguishable")
        }

        switch WristInternetRelayKeychain.classifyLoad(
            [String].self,
            copyStatus: errSecSuccess,
            data: Data("not-json".utf8)
        ) {
        case .unavailable:
            break
        case .loaded, .notFound:
            XCTFail("Corrupt JSON must fail closed")
        }

        switch WristInternetRelayKeychain.classifyLoad(
            [String].self,
            copyStatus: errSecInteractionNotAllowed,
            data: encoded
        ) {
        case .unavailable:
            break
        case .loaded, .notFound:
            XCTFail("A Keychain read error must fail closed")
        }

        for unavailableStatus in [errSecNotAvailable, errSecAuthFailed, OSStatus(-1)] {
            switch WristInternetRelayKeychain.classifyLoad(
                [String].self,
                copyStatus: unavailableStatus,
                data: encoded
            ) {
            case .unavailable:
                break
            case .loaded, .notFound:
                XCTFail("Every non-success Keychain status except item-not-found must fail closed")
            }
        }

        switch WristInternetRelayKeychain.classifyLoad(
            [String].self,
            copyStatus: errSecSuccess,
            data: nil
        ) {
        case .unavailable:
            break
        case .loaded, .notFound:
            XCTFail("A non-Data Keychain value must fail closed")
        }

        switch WristInternetRelayKeychain.classifyLoad(
            [String].self,
            copyStatus: errSecSuccess,
            data: encoded
        ) {
        case let .loaded(fingerprints):
            XCTAssertEqual(fingerprints, expected)
        case .notFound, .unavailable:
            XCTFail("Valid JSON from Keychain must remain readable")
        }
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

    func testTailnetAccessIsDefaultOffAndUsesOnlyBridgeOwnedPreference() {
        let store = BridgePreferences(defaults: defaults)
        XCTAssertFalse(store.tailnetAccessEnabled)
        XCTAssertNil(defaults.object(forKey: BridgePreferences.tailnetAccessEnabledKey))

        store.tailnetAccessEnabled = true

        XCTAssertTrue(BridgePreferences(defaults: defaults).tailnetAccessEnabled)
        XCTAssertEqual(
            Set(defaults.persistentDomain(forName: suiteName)?.keys.map { $0 } ?? []),
            [BridgePreferences.tailnetAccessEnabledKey]
        )
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
