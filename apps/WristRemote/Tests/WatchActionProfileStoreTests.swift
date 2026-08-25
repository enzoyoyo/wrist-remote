#if os(iOS)
import XCTest
@testable import WristRemote

@MainActor
final class WatchActionProfileStoreTests: XCTestCase {
    func testDefaultProfileContainsTwelveButtonsAndThirtySixBindings() throws {
        let store = makeStore()
        let legacyFunctionFlag = UInt(1 << 23)

        XCTAssertEqual(store.profile.bindings.count, 12)
        XCTAssertEqual(
            store.profile.bindings.values.reduce(0) { $0 + $1.count },
            36
        )
        XCTAssertEqual(
            store.binding(for: .power, trigger: .singleClick).action,
            .escape
        )
        XCTAssertEqual(
            store.binding(for: .tv, trigger: .singleClick).action,
            .appSwitcher
        )
        XCTAssertEqual(
            store.binding(for: .ok, trigger: .doubleClick).action,
            .disabled
        )
        XCTAssertNoThrow(try store.profile.validatedAndNormalized())
        XCTAssertTrue(
            store.profile.bindings.values
                .flatMap(\.values)
                .allSatisfy {
                    ($0.shortcut?.modifierFlagsRawValue ?? 0) & legacyFunctionFlag == 0
                }
        )
        XCTAssertTrue(
            WatchShortcutModifier.allCases.allSatisfy {
                $0.rawValue & legacyFunctionFlag == 0
            }
        )
    }

    func testLegacyFunctionModifierIsRemovedWithoutChangingOtherModifiers() throws {
        let suiteName = "WristRemote.tests.legacy-modifier.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let legacyFunctionFlag = UInt(1 << 23)
        let expectedFlags = WatchShortcutModifier.command.rawValue
            | WatchShortcutModifier.option.rawValue
        var profile = WatchActionProfileStore.defaultProfile(revision: 14)
        profile.bindings["tv"]?["longPress"] = WatchActionBindingWire(
            action: .customShortcut,
            shortcut: WatchShortcutWire(
                keyCode: 8,
                modifierFlagsRawValue: expectedFlags | legacyFunctionFlag,
                keyLabel: "C"
            )
        )
        defaults.set(try JSONEncoder().encode(profile), forKey: WatchActionProfileStore.storageKey)

        let store = WatchActionProfileStore(defaults: defaults)
        let shortcut = try XCTUnwrap(
            store.binding(for: .tv, trigger: .longPress).shortcut
        )
        XCTAssertEqual(store.revision, 15)
        XCTAssertEqual(shortcut.modifierFlagsRawValue, expectedFlags)
        XCTAssertEqual(shortcut.modifierFlagsRawValue & legacyFunctionFlag, 0)

        let persistedData = try XCTUnwrap(
            defaults.data(forKey: WatchActionProfileStore.storageKey)
        )
        let persisted = try JSONDecoder().decode(
            WatchActionProfileWire.self,
            from: persistedData
        )
        XCTAssertEqual(
            persisted.bindings["tv"]?["longPress"]?.shortcut?.modifierFlagsRawValue,
            expectedFlags
        )
    }

    func testEveryEditAdvancesRevisionAndPersistsTheIndependentProfile() throws {
        let suiteName = "WristRemote.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = WatchActionProfileStore(defaults: defaults)
        let initialRevision = store.revision
        store.setAction(.playPause, for: .menu, trigger: .doubleClick)
        XCTAssertEqual(store.revision, initialRevision + 1)

        store.setAction(.customShortcut, for: .tv, trigger: .longPress)
        let shortcutRevision = store.revision
        store.setShortcut(
            WatchShortcutWire(
                keyCode: 8,
                modifierFlagsRawValue: WatchShortcutModifier.command.rawValue,
                keyLabel: "C"
            ),
            for: .tv,
            trigger: .longPress
        )
        XCTAssertEqual(store.revision, shortcutRevision + 1)

        let restored = WatchActionProfileStore(defaults: defaults)
        XCTAssertEqual(restored.profile, store.profile)
        XCTAssertEqual(
            restored.binding(for: .tv, trigger: .longPress).shortcut?.displayTitle,
            "⌘C"
        )
    }

    func testPersistenceDoesNotTouchAnotherDefaultsDomain() throws {
        let localSuite = "WristRemote.tests.local.\(UUID().uuidString)"
        let protectedSuite = "org.example.unrelated.tests.\(UUID().uuidString)"
        let localDefaults = try XCTUnwrap(UserDefaults(suiteName: localSuite))
        let protectedDefaults = try XCTUnwrap(UserDefaults(suiteName: protectedSuite))
        localDefaults.removePersistentDomain(forName: localSuite)
        protectedDefaults.removePersistentDomain(forName: protectedSuite)
        defer {
            localDefaults.removePersistentDomain(forName: localSuite)
            protectedDefaults.removePersistentDomain(forName: protectedSuite)
        }

        protectedDefaults.set(Data([0x01, 0x02, 0x03]), forKey: "unrelatedSettings")
        let protectedSnapshot = protectedDefaults.persistentDomain(forName: protectedSuite)

        let store = WatchActionProfileStore(defaults: localDefaults)
        store.setAction(.commandCopy, for: .home, trigger: .doubleClick)

        XCTAssertEqual(
            protectedDefaults.persistentDomain(forName: protectedSuite) as NSDictionary?,
            protectedSnapshot as NSDictionary?
        )
        XCTAssertNotNil(localDefaults.data(forKey: WatchActionProfileStore.storageKey))
        XCTAssertTrue(WatchActionProfileStore.storageKey.hasPrefix("WristRemote."))
    }

    func testOnlyBridgeSupportedActionsAppearInExactlyOneSelectionCategory() {
        let categorized = WatchActionCategory.allCases.flatMap { category in
            WatchActionKindWire.wristRemoteBridgeActions.filter { $0.category == category }
        }
        XCTAssertEqual(categorized.count, WatchActionKindWire.allCases.count)
        XCTAssertEqual(Set(categorized.map(\.rawValue)).count, categorized.count)
    }

    func testRelayNeverRelabelsDelayedWatchEventsWithTheCurrentRevision() {
        let oldEvent = WatchRemoteProtocol.buttonMessage(
            command: .home,
            phase: .release,
            profileRevision: 3
        )
        XCTAssertNil(WatchRelayController.validatedButtonEvent(
            from: oldEvent,
            currentProfileRevision: 4,
            acceptedProfileRevision: 4
        ))
        XCTAssertNil(WatchRelayController.validatedButtonEvent(
            from: oldEvent,
            currentProfileRevision: 3,
            acceptedProfileRevision: nil
        ))

        let accepted = WatchRelayController.validatedButtonEvent(
            from: oldEvent,
            currentProfileRevision: 3,
            acceptedProfileRevision: 3
        )
        XCTAssertEqual(accepted?.command, .home)
        XCTAssertEqual(accepted?.phase, .release)
        XCTAssertEqual(accepted?.profileRevision, 3)
    }

    func testRelayNeverRelabelsDelayedWatchVoiceWithTheCurrentRevision() throws {
        let streamID = UUID()
        let oldStart = try XCTUnwrap(WatchRemoteProtocol.voiceStartMessage(
            streamID: streamID,
            profileRevision: 3
        ))
        XCTAssertNil(WatchRelayController.validatedVoiceEvent(
            from: oldStart,
            kind: .voiceStart,
            currentProfileRevision: 4,
            acceptedProfileRevision: 4
        ))
        XCTAssertNil(WatchRelayController.validatedVoiceEvent(
            from: oldStart,
            kind: .voiceStart,
            currentProfileRevision: 3,
            acceptedProfileRevision: nil
        ))
        let accepted = WatchRelayController.validatedVoiceEvent(
            from: oldStart,
            kind: .voiceStart,
            currentProfileRevision: 3,
            acceptedProfileRevision: 3
        )
        XCTAssertEqual(accepted?.streamID, streamID)
        XCTAssertEqual(accepted?.profileRevision, 3)
        XCTAssertEqual(accepted?.intent, .foregroundDictation)
        XCTAssertNil(accepted?.codexTaskIdentity)
        XCTAssertNil(accepted?.finalSequence)

        let codexIdentity = try XCTUnwrap(WatchCodexTaskIdentity(
            threadID: "thr_action_123",
            turnID: "turn_action_123",
            revision: 5
        ))
        let codexStop = try XCTUnwrap(WatchRemoteProtocol.voiceStopMessage(
            streamID: streamID,
            profileRevision: 3,
            intent: .codexTask,
            codexTaskIdentity: codexIdentity,
            finalSequence: 19
        ))
        let acceptedCodexStop = WatchRelayController.validatedVoiceEvent(
            from: codexStop,
            kind: .voiceStop,
            currentProfileRevision: 3,
            acceptedProfileRevision: 3
        )
        XCTAssertEqual(acceptedCodexStop?.streamID, streamID)
        XCTAssertEqual(acceptedCodexStop?.intent, .codexTask)
        XCTAssertEqual(acceptedCodexStop?.codexTaskIdentity, codexIdentity)
        XCTAssertEqual(acceptedCodexStop?.finalSequence, 19)
    }

    func testRelayClearsHeldInteractionsAsSoonAsProfileBecomesUnready() {
        XCTAssertTrue(WatchRelayController.shouldClearInteractions(
            wasReady: true,
            isReady: false
        ))
        XCTAssertFalse(WatchRelayController.shouldClearInteractions(
            wasReady: false,
            isReady: false
        ))
        XCTAssertFalse(WatchRelayController.shouldClearInteractions(
            wasReady: false,
            isReady: true
        ))
    }

    func testProfileSyncRouteSelectsExactlyOneTransport() {
        XCTAssertEqual(
            WatchRelayController.profileSyncRoute(
                localChannelAvailable: true,
                localAcceptedRevision: 6,
                internetProvisioned: true,
                internetAcceptedRevision: nil,
                failedInternetRevision: nil,
                desiredRevision: 7,
                internetRequestInFlight: false
            ),
            .local
        )
        XCTAssertEqual(
            WatchRelayController.profileSyncRoute(
                localChannelAvailable: true,
                localAcceptedRevision: 7,
                internetProvisioned: true,
                internetAcceptedRevision: nil,
                failedInternetRevision: nil,
                desiredRevision: 7,
                internetRequestInFlight: false
            ),
            .internetVerification
        )
        XCTAssertEqual(
            WatchRelayController.profileSyncRoute(
                localChannelAvailable: false,
                localAcceptedRevision: nil,
                internetProvisioned: true,
                internetAcceptedRevision: nil,
                failedInternetRevision: nil,
                desiredRevision: 7,
                internetRequestInFlight: false
            ),
            .internetUpdate
        )
        XCTAssertEqual(
            WatchRelayController.profileSyncRoute(
                localChannelAvailable: false,
                localAcceptedRevision: nil,
                internetProvisioned: true,
                internetAcceptedRevision: nil,
                failedInternetRevision: nil,
                desiredRevision: 7,
                internetRequestInFlight: true
            ),
            .none
        )
        XCTAssertEqual(
            WatchRelayController.profileSyncRoute(
                localChannelAvailable: false,
                localAcceptedRevision: nil,
                internetProvisioned: true,
                internetAcceptedRevision: nil,
                failedInternetRevision: 7,
                desiredRevision: 7,
                internetRequestInFlight: false
            ),
            .none
        )
    }

    func testInternetProfileReadyRequiresAcceptedMatchingRevision() {
        let operationID = UUID()
        let expectedStatus = makeInternetStatus(profileRevision: 7)
        XCTAssertEqual(
            WatchRelayController.acceptedInternetProfileRevision(
                from: WristInternetRelayResult(
                    operationID: operationID,
                    accepted: true,
                    status: expectedStatus
                ),
                expectedRevision: 7
            ),
            7
        )
        XCTAssertNil(WatchRelayController.acceptedInternetProfileRevision(
            from: WristInternetRelayResult(
                operationID: operationID,
                accepted: false,
                status: expectedStatus
            ),
            expectedRevision: 7
        ))
        XCTAssertNil(WatchRelayController.acceptedInternetProfileRevision(
            from: WristInternetRelayResult(
                operationID: operationID,
                accepted: true,
                status: makeInternetStatus(profileRevision: 6)
            ),
            expectedRevision: 7
        ))
        XCTAssertNil(WatchRelayController.acceptedInternetProfileRevision(
            from: WristInternetRelayResult(
                operationID: operationID,
                accepted: true,
                status: nil
            ),
            expectedRevision: 7
        ))
    }

    func testInternetVoiceBusyRetryUsesOnlyBoundedExplicitReason() {
        XCTAssertEqual(
            WatchRelayController.profileBusyRetryDelayMilliseconds(
                reason: .voiceActive,
                failureCount: 0
            ),
            WatchProfileBusyRetryPolicy.retryDelayMilliseconds
        )
        XCTAssertNil(WatchRelayController.profileBusyRetryDelayMilliseconds(
            reason: nil,
            failureCount: 0
        ))
        XCTAssertEqual(
            WatchRelayController.profileBusyRetryDelayMilliseconds(
                reason: .voiceActive,
                failureCount: WatchProfileBusyRetryPolicy.fastAttemptCount
            ),
            WatchProfileBusyRetryPolicy.sustainedRetryDelayMilliseconds
        )
        XCTAssertNil(WatchRelayController.profileBusyRetryDelayMilliseconds(
            reason: .voiceActive,
            failureCount: WatchProfileBusyRetryPolicy.maximumAttemptCount
        ))
        XCTAssertTrue(WatchRelayController.busyResultMatchesCurrentProfile(
            expectedRevision: 7,
            currentRevision: 7
        ))
        XCTAssertFalse(WatchRelayController.busyResultMatchesCurrentProfile(
            expectedRevision: 7,
            currentRevision: 8
        ))
    }

    func testIndependentTitlesUseShortcutAndCustomApplicationNames() throws {
        let store = makeStore()
        store.setAction(.customShortcut, for: .menu, trigger: .singleClick)
        store.setShortcut(
            WatchShortcutWire(
                keyCode: 1,
                modifierFlagsRawValue: WatchShortcutModifier.command.rawValue,
                keyLabel: "S"
            ),
            for: .menu,
            trigger: .singleClick
        )
        XCTAssertEqual(store.title(for: .menu, applicationTitles: [:]), "⌘S")

        let profileID = UUID().uuidString
        store.setAction(
            .openCustomApplication,
            for: .tv,
            trigger: .singleClick,
            defaultApplicationProfileID: profileID
        )
        XCTAssertEqual(
            store.title(for: .tv, applicationTitles: [profileID: "Example App"]),
            "Example App"
        )
    }

    private func makeStore() -> WatchActionProfileStore {
        let suiteName = "WristRemote.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return WatchActionProfileStore(defaults: defaults)
    }

    private func makeInternetStatus(profileRevision: Int?) -> WristInternetRelayStatus {
        WristInternetRelayStatus(
            macName: "Example Mac",
            profileRevision: profileRevision,
            buttonTitles: [:],
            buttonTriggers: [:],
            voiceOwner: .none,
            codexTask: nil,
            codexTaskStateRevision: 0,
            voiceOutcome: nil,
            speechLocaleIdentifier: "zh-CN"
        )
    }
}
#endif
