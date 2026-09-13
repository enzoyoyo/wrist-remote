#if os(iOS)
import CryptoKit
import Security
import XCTest
@testable import WristRemote

@MainActor
final class WristBridgeConnectionTests: XCTestCase {
    func testTransportIdentityIsDedicatedToWristRemoteBridge() {
        XCTAssertEqual(WristBridgeWireMessage.serviceType, "_wristremote._tcp")
        XCTAssertEqual(
            WristBridgeWireMessage.sessionSalt,
            "WristRemoteBridge nearby session"
        )
        XCTAssertEqual(
            WristBridgeWireMessage.serverIdentityProofDomain,
            "WristRemoteBridge server identity v1"
        )
        XCTAssertEqual(
            WristBridgeWireMessage.clientAuthenticationProofDomain,
            "WristRemoteBridge client auth v1"
        )
        XCTAssertEqual(
            WristBridgeWireMessage.secureEnvelopeDomain,
            "WristRemoteBridge secure envelope v1"
        )
        XCTAssertFalse(WristBridgeWireMessage.sessionSalt.contains("Unrelated nearby"))
    }

    func testServerIdentityAndCapabilitiesMustMatchExactly() {
        let valid = WristBridgeWireMessage(
            type: "ready",
            protocolID: WristBridgeWireMessage.protocolID,
            serverRole: WristBridgeWireMessage.serverRole
        )
        XCTAssertTrue(WristBridgeConnection.acceptsServerIdentity(valid))

        var wrongRole = valid
        wrongRole.serverRole = "nearbyPhoneServer"
        XCTAssertFalse(WristBridgeConnection.acceptsServerIdentity(wrongRole))

        XCTAssertTrue(WristBridgeConnection.acceptsCapabilities([
            WristBridgeWireMessage.voiceSessionsCapability,
            WristBridgeWireMessage.watchActionProfileCapability,
            WristBridgeWireMessage.codexTasksCapability,
            WristBridgeWireMessage.voiceOutcomesCapability,
            WristBridgeWireMessage.codexReplyReceiptsCapability,
            WristBridgeWireMessage.connectionLivenessCapability,
            WristBridgeWireMessage.serverIdentityCapability,
            WristBridgeWireMessage.secureSequenceCapability,
            WristBridgeWireMessage.audioDeliveryReceiptsCapability,
        ]))
        XCTAssertFalse(WristBridgeConnection.acceptsCapabilities([
            WristBridgeWireMessage.voiceSessionsCapability,
            WristBridgeWireMessage.watchActionProfileCapability,
            WristBridgeWireMessage.codexTasksCapability,
            WristBridgeWireMessage.voiceOutcomesCapability,
            WristBridgeWireMessage.codexReplyReceiptsCapability,
            WristBridgeWireMessage.connectionLivenessCapability,
            WristBridgeWireMessage.serverIdentityCapability,
        ]))
        XCTAssertFalse(WristBridgeConnection.supportsCodexConversationCapability([
            WristBridgeWireMessage.voiceSessionsCapability,
            WristBridgeWireMessage.watchActionProfileCapability,
        ]))
        XCTAssertTrue(WristBridgeConnection.supportsCodexConversationCapability([
            WristBridgeWireMessage.codexConversationsCapability,
        ]))
        XCTAssertFalse(WristBridgeConnection.acceptsCapabilities([
            WristBridgeWireMessage.voiceSessionsCapability,
            WristBridgeWireMessage.watchActionProfileCapability,
            WristBridgeWireMessage.codexTasksCapability,
            WristBridgeWireMessage.voiceOutcomesCapability,
            WristBridgeWireMessage.codexReplyReceiptsCapability,
        ]))
        XCTAssertFalse(WristBridgeConnection.acceptsCapabilities([
            WristBridgeWireMessage.voiceSessionsCapability,
            WristBridgeWireMessage.watchActionProfileCapability,
            WristBridgeWireMessage.voiceOutcomesCapability,
        ]))

        XCTAssertTrue(WristBridgeConnection.acceptsSecureMessageBeforeReady("ready"))
        XCTAssertTrue(WristBridgeConnection.acceptsSecureMessageBeforeReady("denied"))
        XCTAssertFalse(WristBridgeConnection.acceptsSecureMessageBeforeReady("error"))
        XCTAssertFalse(WristBridgeConnection.acceptsSecureMessageBeforeReady("watchProfileReady"))
    }

    func testRelayProvisioningCannotSilentlyRetainLegacyCredentials() {
        let encoded = "encoded-provisioning"
        XCTAssertEqual(
            WristBridgeWireMessage.internetRelayProvisioningDirective(
                encoded: encoded,
                cleared: false
            ),
            .install(encoded)
        )
        XCTAssertEqual(
            WristBridgeWireMessage.internetRelayProvisioningDirective(
                encoded: nil,
                cleared: true
            ),
            .clear
        )
        XCTAssertNil(WristBridgeWireMessage.internetRelayProvisioningDirective(
            encoded: encoded,
            cleared: true
        ))
        XCTAssertNil(WristBridgeWireMessage.internetRelayProvisioningDirective(
            encoded: nil,
            cleared: nil
        ))

        XCTAssertTrue(WristBridgeConnection.permitsInternetRelayKeychainRecovery(
            relayEnabledForCurrentBuild: true,
            privateNetworkEnabled: false,
            explicitlyCleared: false
        ))
        XCTAssertFalse(WristBridgeConnection.permitsInternetRelayKeychainRecovery(
            relayEnabledForCurrentBuild: true,
            privateNetworkEnabled: true,
            explicitlyCleared: false
        ))
        XCTAssertFalse(WristBridgeConnection.permitsInternetRelayKeychainRecovery(
            relayEnabledForCurrentBuild: true,
            privateNetworkEnabled: false,
            explicitlyCleared: true
        ))
        XCTAssertFalse(WristBridgeConnection.permitsInternetRelayKeychainRecovery(
            relayEnabledForCurrentBuild: false,
            privateNetworkEnabled: false,
            explicitlyCleared: false
        ))
        XCTAssertEqual(
            WatchRelayController.internetRelayStatusDetail(
                relayEnabledForCurrentBuild: false,
                state: .unavailable
            ),
            "当前构建已禁用并清除公网 Relay"
        )
    }

    func testRelayClearMarkerPersistsUntilExplicitlyRemoved() throws {
        let suiteName = "WristBridgeConnectionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var keychainCleared = false
        let updateKeychain: (Bool) -> Bool = { cleared in
            keychainCleared = cleared
            return true
        }

        XCTAssertFalse(WristInternetRelayClearMarker.isSet(
            defaults: defaults,
            keychainCleared: keychainCleared
        ))
        XCTAssertFalse(WristInternetRelayClearMarker.setCleared(
            true,
            defaults: defaults,
            updateKeychain: { _ in false }
        ))
        XCTAssertTrue(WristInternetRelayClearMarker.isSet(
            defaults: defaults,
            keychainCleared: false
        ))
        defaults.removePersistentDomain(forName: suiteName)

        XCTAssertTrue(WristInternetRelayClearMarker.setCleared(
            true,
            defaults: defaults,
            updateKeychain: updateKeychain
        ))
        XCTAssertTrue(WristInternetRelayClearMarker.isSet(
            defaults: try XCTUnwrap(UserDefaults(suiteName: suiteName)),
            keychainCleared: keychainCleared
        ))

        defaults.removePersistentDomain(forName: suiteName)
        XCTAssertTrue(WristInternetRelayClearMarker.isSet(
            defaults: try XCTUnwrap(UserDefaults(suiteName: suiteName)),
            keychainCleared: keychainCleared
        ))
        XCTAssertTrue(WristInternetRelayClearMarker.setCleared(
            true,
            defaults: defaults,
            updateKeychain: updateKeychain
        ))

        XCTAssertFalse(WristInternetRelayClearMarker.setCleared(
            false,
            defaults: defaults,
            updateKeychain: { _ in false }
        ))
        XCTAssertTrue(keychainCleared)
        XCTAssertTrue(WristInternetRelayClearMarker.isSet(
            defaults: defaults,
            keychainCleared: false
        ))

        XCTAssertTrue(WristInternetRelayClearMarker.setCleared(
            false,
            defaults: defaults,
            updateKeychain: updateKeychain
        ))
        XCTAssertFalse(WristInternetRelayClearMarker.isSet(
            defaults: try XCTUnwrap(UserDefaults(suiteName: suiteName)),
            keychainCleared: keychainCleared
        ))
    }

    func testServerKeyRequiresExactVersionRolesAndIdentityProofFields() {
        let valid = WristBridgeWireMessage(
            type: "serverKey",
            protocolID: WristBridgeWireMessage.protocolID,
            serverRole: WristBridgeWireMessage.serverRole,
            publicKey: Data(repeating: 1, count: 32).base64EncodedString(),
            serverIdentityVersion: WristBridgeWireMessage.serverIdentityVersion,
            serverIdentityPublicKey: Data(repeating: 2, count: 64).base64EncodedString(),
            serverIdentitySignature: Data(repeating: 3, count: 64).base64EncodedString()
        )
        XCTAssertTrue(WristBridgeConnection.acceptsServerKey(valid))

        var unknownVersion = valid
        unknownVersion.serverIdentityVersion = 2
        XCTAssertFalse(WristBridgeConnection.acceptsServerKey(unknownVersion))

        var wrongRole = valid
        wrongRole.clientRole = WristBridgeWireMessage.clientRole
        XCTAssertFalse(WristBridgeConnection.acceptsServerKey(wrongRole))

        var leakedClientIdentity = valid
        leakedClientIdentity.identityPublicKey = "unexpected"
        XCTAssertFalse(WristBridgeConnection.acceptsServerKey(leakedClientIdentity))
    }

    func testServerAndClientProofsAreDomainSeparatedAndBindTranscript() throws {
        let clientEphemeral = Data(repeating: 1, count: 32)
        let serverEphemeral = Data(repeating: 2, count: 32)
        let serverIdentity = P256.Signing.PrivateKey()
        let clientIdentity = P256.Signing.PrivateKey()

        let serverProof = try XCTUnwrap(WristBridgeWireMessage.serverIdentityProof(
            clientEphemeralPublicKey: clientEphemeral,
            serverEphemeralPublicKey: serverEphemeral
        ))
        let serverSignature = try serverIdentity.signature(for: serverProof)
        XCTAssertTrue(serverIdentity.publicKey.isValidSignature(serverSignature, for: serverProof))
        let swappedServerProof = try XCTUnwrap(WristBridgeWireMessage.serverIdentityProof(
            clientEphemeralPublicKey: serverEphemeral,
            serverEphemeralPublicKey: clientEphemeral
        ))
        XCTAssertFalse(
            serverIdentity.publicKey.isValidSignature(serverSignature, for: swappedServerProof)
        )

        let clientProof = try XCTUnwrap(WristBridgeWireMessage.clientAuthenticationProof(
            clientEphemeralPublicKey: clientEphemeral,
            serverEphemeralPublicKey: serverEphemeral,
            serverIdentityPublicKey: serverIdentity.publicKey.rawRepresentation,
            clientIdentityPublicKey: clientIdentity.publicKey.rawRepresentation
        ))
        XCTAssertNotEqual(serverProof, clientProof)
        let clientSignature = try clientIdentity.signature(for: clientProof)
        XCTAssertTrue(clientIdentity.publicKey.isValidSignature(clientSignature, for: clientProof))

        let otherClientIdentity = P256.Signing.PrivateKey()
        let changedClientProof = try XCTUnwrap(WristBridgeWireMessage.clientAuthenticationProof(
            clientEphemeralPublicKey: clientEphemeral,
            serverEphemeralPublicKey: serverEphemeral,
            serverIdentityPublicKey: serverIdentity.publicKey.rawRepresentation,
            clientIdentityPublicKey: otherClientIdentity.publicKey.rawRepresentation
        ))
        XCTAssertFalse(
            clientIdentity.publicKey.isValidSignature(clientSignature, for: changedClientProof)
        )
    }

    func testServerTrustIsTOFUAndPinnedMismatchFailsClosed() {
        let fingerprint = String(repeating: "a", count: 64)
        XCTAssertEqual(
            WristBridgeConnection.serverTrustDecision(
                storedFingerprint: nil,
                storeAvailable: true,
                presentedFingerprint: fingerprint
            ),
            .requiresApproval
        )
        XCTAssertEqual(
            WristBridgeConnection.serverTrustDecision(
                storedFingerprint: fingerprint,
                storeAvailable: true,
                presentedFingerprint: fingerprint
            ),
            .trusted
        )
        XCTAssertEqual(
            WristBridgeConnection.serverTrustDecision(
                storedFingerprint: String(repeating: "b", count: 64),
                storeAvailable: true,
                presentedFingerprint: fingerprint
            ),
            .mismatch
        )
        XCTAssertEqual(
            WristBridgeConnection.serverTrustDecision(
                storedFingerprint: nil,
                storeAvailable: false,
                presentedFingerprint: fingerprint
            ),
            .storageUnavailable
        )
        XCTAssertTrue(WristBridgeTrustedServerIdentityStore.isValidFingerprint(fingerprint))
        XCTAssertFalse(WristBridgeTrustedServerIdentityStore.isValidFingerprint(fingerprint.uppercased()))
        XCTAssertFalse(WristBridgeTrustedServerIdentityStore.isValidFingerprint("abc"))
    }

    func testWatchProfileUpdateCarriesExactRevisionAndSource() throws {
        let profile = WatchActionProfileStore.defaultProfile(revision: 17)
        let message = try XCTUnwrap(WristBridgeConnection.profileUpdateMessage(profile))
        XCTAssertEqual(message.type, "watchProfileUpdate")
        XCTAssertEqual(message.inputSource, "appleWatch")
        XCTAssertEqual(message.profileRevision, 17)
        XCTAssertEqual(
            try WatchActionProfileWire.decodeBase64(try XCTUnwrap(message.watchProfile)),
            profile
        )
    }

    func testProfileBusyRejectionCarriesTypedRetryReason() throws {
        let message = WristBridgeWireMessage(
            type: "watchProfileRejected",
            detail: "voice busy",
            profileRevision: 17,
            profileUpdateRetryReason: .voiceActive
        )
        let roundTrip = try JSONDecoder().decode(
            WristBridgeWireMessage.self,
            from: JSONEncoder().encode(message)
        )
        XCTAssertEqual(roundTrip.profileUpdateRetryReason, .voiceActive)
        XCTAssertEqual(roundTrip.profileRevision, 17)
    }

    func testVoiceFramesCarryExactSourceRevisionAndSession() throws {
        let sessionID = UUID().uuidString
        let message = try XCTUnwrap(WristBridgeConnection.voiceMessage(
            type: "audio",
            sessionID: sessionID,
            profileRevision: 8,
            samples: Data([0, 0]).base64EncodedString(),
            audioSequence: 0
        ))
        XCTAssertEqual(message.inputSource, "appleWatch")
        XCTAssertEqual(message.profileRevision, 8)
        XCTAssertEqual(message.sessionID, sessionID)
        XCTAssertEqual(message.voiceIntent, WatchVoiceIntent.foregroundDictation.rawValue)
        XCTAssertEqual(message.audioSequence, 0)
        XCTAssertNil(message.threadID)
        var partialForeground = message
        partialForeground.threadID = "thr_partial"
        XCTAssertNil(WristBridgeConnection.wireCodexTaskIdentity(from: partialForeground))
        XCTAssertTrue(WristBridgeConnection.hasWireCodexTaskIdentityFields(partialForeground))

        let identity = try XCTUnwrap(WatchCodexTaskIdentity(
            threadID: "thr_voice_123",
            turnID: "turn_voice_123",
            revision: 21
        ))
        let codexStart = try XCTUnwrap(WristBridgeConnection.voiceMessage(
            type: "voiceStart",
            sessionID: sessionID,
            profileRevision: 8,
            intent: .codexTask,
            codexTaskIdentity: identity
        ))
        XCTAssertEqual(codexStart.voiceIntent, WatchVoiceIntent.codexTask.rawValue)
        XCTAssertEqual(codexStart.threadID, identity.threadID)
        XCTAssertEqual(codexStart.turnID, identity.turnID)
        XCTAssertEqual(codexStart.taskRevision, identity.revision)
        XCTAssertNil(codexStart.samples)

        XCTAssertNil(WristBridgeConnection.voiceMessage(
            type: "voiceStart",
            sessionID: "not-a-uuid",
            profileRevision: 8
        ))
        XCTAssertNil(WristBridgeConnection.voiceMessage(
            type: "voiceStart",
            sessionID: sessionID,
            profileRevision: 8,
            intent: .codexTask
        ))
        XCTAssertNil(WristBridgeConnection.voiceMessage(
            type: "voiceStop",
            sessionID: sessionID,
            profileRevision: 8,
            intent: .foregroundDictation,
            codexTaskIdentity: identity
        ))
        XCTAssertNil(WristBridgeConnection.voiceMessage(
            type: "audio",
            sessionID: sessionID,
            profileRevision: 8,
            intent: .codexTask,
            codexTaskIdentity: identity
        ))
        XCTAssertNil(WristBridgeConnection.voiceMessage(
            type: "audio",
            sessionID: sessionID,
            profileRevision: 8,
            samples: Data([0, 0]).base64EncodedString()
        ))
    }

    func testMacAudioReceiptMustConfirmTheExactPacketAndVoiceTarget() throws {
        let sessionID = UUID().uuidString
        let valid = WristBridgeWireMessage(
            type: "audioAck",
            audioSequence: 7,
            audioAccepted: true,
            audioContiguousThrough: 7,
            sessionID: sessionID,
            inputSource: WristBridgeWireMessage.appleWatchInputSource,
            profileRevision: 8,
            voiceIntent: WatchVoiceIntent.foregroundDictation.rawValue
        )
        XCTAssertEqual(
            WristBridgeConnection.audioDeliveryReceipt(
                from: valid,
                expectedSessionID: sessionID,
                expectedProfileRevision: 8,
                expectedSequence: 7,
                expectedIntent: .foregroundDictation,
                expectedCodexTaskIdentity: nil,
                expectedCodexConversationTarget: nil
            ),
            WristBridgeAudioDeliveryReceipt(
                sequence: 7,
                accepted: true,
                contiguousThrough: 7
            )
        )

        var onlyReceivedByTransport = valid
        onlyReceivedByTransport.audioContiguousThrough = 6
        XCTAssertNil(WristBridgeConnection.audioDeliveryReceipt(
            from: onlyReceivedByTransport,
            expectedSessionID: sessionID,
            expectedProfileRevision: 8,
            expectedSequence: 7,
            expectedIntent: .foregroundDictation,
            expectedCodexTaskIdentity: nil,
            expectedCodexConversationTarget: nil
        ))

        var wrongSession = valid
        wrongSession.sessionID = UUID().uuidString
        XCTAssertNil(WristBridgeConnection.audioDeliveryReceipt(
            from: wrongSession,
            expectedSessionID: sessionID,
            expectedProfileRevision: 8,
            expectedSequence: 7,
            expectedIntent: .foregroundDictation,
            expectedCodexTaskIdentity: nil,
            expectedCodexConversationTarget: nil
        ))
    }

    func testCodexVoiceTargetsRequireTheExactCompletedTurnAndRevision() throws {
        let threadID = "thr_task_123"
        let snapshot = WatchCodexTaskSnapshot(
            threadID: threadID,
            turnID: "turn_task_123",
            workspaceLabel: "wristremote",
            title: "Example task",
            summary: "Example result",
            state: .completed,
            revision: 4,
            updatedAtEpochMilliseconds: 1_777_000_000_000
        )
        let identity = try XCTUnwrap(WatchCodexTaskIdentity(snapshot))

        XCTAssertTrue(WristBridgeConnection.acceptsVoiceTargetShape(
            intent: .foregroundDictation,
            codexTaskIdentity: nil
        ))
        XCTAssertFalse(WristBridgeConnection.acceptsVoiceTargetShape(
            intent: .foregroundDictation,
            codexTaskIdentity: identity
        ))
        XCTAssertFalse(WristBridgeConnection.acceptsVoiceTargetShape(
            intent: .codexTask,
            codexTaskIdentity: nil
        ))
        XCTAssertTrue(WristBridgeConnection.acceptsVoiceTarget(
            intent: .codexTask,
            codexTaskIdentity: identity,
            snapshot: snapshot,
            supportsCodexTasks: true
        ))
        XCTAssertFalse(WristBridgeConnection.acceptsVoiceTarget(
            intent: .codexTask,
            codexTaskIdentity: WatchCodexTaskIdentity(
                threadID: "thr_other_456",
                turnID: identity.turnID,
                revision: identity.revision
            ),
            snapshot: snapshot,
            supportsCodexTasks: true
        ))
        XCTAssertFalse(WristBridgeConnection.acceptsVoiceTarget(
            intent: .codexTask,
            codexTaskIdentity: identity,
            snapshot: WatchCodexTaskSnapshot(
                threadID: threadID,
                turnID: identity.turnID,
                workspaceLabel: snapshot.workspaceLabel,
                title: snapshot.title,
                state: .running,
                revision: snapshot.revision,
                updatedAtEpochMilliseconds: snapshot.updatedAtEpochMilliseconds
            ),
            supportsCodexTasks: true
        ))
        XCTAssertFalse(WristBridgeConnection.acceptsVoiceTarget(
            intent: .codexTask,
            codexTaskIdentity: identity,
            snapshot: snapshot,
            supportsCodexTasks: false
        ))

        let nextTurn = WatchCodexTaskSnapshot(
            threadID: threadID,
            turnID: "turn_task_124",
            workspaceLabel: snapshot.workspaceLabel,
            title: snapshot.title,
            state: .completed,
            revision: snapshot.revision + 1,
            updatedAtEpochMilliseconds: snapshot.updatedAtEpochMilliseconds + 1
        )
        XCTAssertFalse(WristBridgeConnection.acceptsVoiceTarget(
            intent: .codexTask,
            codexTaskIdentity: identity,
            snapshot: nextTurn,
            supportsCodexTasks: true
        ))
    }

    func testConversationVoiceCarriesOneExactMacIssuedTarget() throws {
        let fixture = try makeConversationFixture()
        let sessionID = UUID()
        let message = try XCTUnwrap(WristBridgeConnection.voiceMessage(
            type: "voiceStart",
            sessionID: sessionID.uuidString,
            profileRevision: 5,
            intent: .codexConversation,
            codexConversationTarget: fixture.target
        ))
        XCTAssertEqual(message.codexConversationTarget, fixture.target)
        XCTAssertNil(message.threadID)
        XCTAssertNil(message.turnID)
        XCTAssertNil(message.taskRevision)
        XCTAssertTrue(WristBridgeConnection.acceptsVoiceTarget(
            intent: .codexConversation,
            codexTaskIdentity: nil,
            codexConversationTarget: fixture.target,
            snapshot: nil,
            catalog: fixture.catalog,
            supportsCodexTasks: false,
            supportsCodexConversations: true,
            nowEpochMilliseconds: 1_000
        ))
        XCTAssertFalse(WristBridgeConnection.acceptsVoiceTarget(
            intent: .codexConversation,
            codexTaskIdentity: nil,
            codexConversationTarget: fixture.target,
            snapshot: nil,
            catalog: fixture.catalog,
            supportsCodexTasks: false,
            supportsCodexConversations: false,
            nowEpochMilliseconds: 1_000
        ))
        XCTAssertNil(WristBridgeConnection.voiceMessage(
            type: "audio",
            sessionID: sessionID.uuidString,
            profileRevision: 5,
            intent: .codexConversation,
            samples: "AA=="
        ))
        XCTAssertNil(WristBridgeConnection.voiceMessage(
            type: "audio",
            sessionID: sessionID.uuidString,
            profileRevision: 5,
            intent: .codexConversation,
            codexTaskIdentity: WatchCodexTaskIdentity(
                threadID: "thread",
                turnID: "turn",
                revision: 1
            ),
            codexConversationTarget: fixture.target,
            samples: "AA=="
        ))
    }

    func testConversationCatalogAndReceiptsRejectMismatchedIdentifiersAndTargets() throws {
        let fixture = try makeConversationFixture()
        let requestID = try XCTUnwrap(
            UUID(uuidString: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE")
        )
        let catalogEnvelope = try XCTUnwrap(
            WristBridgeConnection.codexConversationCatalogEnvelope(from: WristBridgeWireMessage(
                type: "codexConversationCatalogSnapshot",
                requestID: requestID.uuidString,
                codexConversationCatalog: fixture.catalog
            ))
        )
        XCTAssertEqual(catalogEnvelope.catalog, fixture.catalog)
        XCTAssertEqual(catalogEnvelope.requestID, requestID)
        XCTAssertNil(WristBridgeConnection.codexConversationCatalogEnvelope(
            from: WristBridgeWireMessage(
                type: "codexConversationCatalogSnapshot",
                requestID: requestID.uuidString.lowercased(),
                codexConversationCatalog: fixture.catalog
            )
        ))

        let targetResult = WristBridgeWireMessage(
            type: "codexConversationTargetResult",
            requestID: requestID.uuidString,
            codexConversationTarget: fixture.target,
            accepted: true
        )
        XCTAssertNotNil(WristBridgeConnection.codexConversationTargetReceipt(
            from: targetResult,
            expectedRequestID: requestID,
            expectedTarget: fixture.target
        ))
        XCTAssertNil(WristBridgeConnection.codexConversationTargetReceipt(
            from: targetResult,
            expectedRequestID: UUID(),
            expectedTarget: fixture.target
        ))

        let requestedNew = try XCTUnwrap(WatchCodexConversationTarget(
            leaseID: UUID(),
            kind: .newConversation,
            serverEpoch: fixture.target.serverEpoch,
            catalogRevision: fixture.target.catalogRevision,
            entryRevision: 10,
            threadID: nil,
            displayTitle: "新建 Codex 会话",
            workspaceID: fixture.target.workspaceID,
            workspaceLabel: fixture.target.workspaceLabel,
            expiresAtEpochMilliseconds: fixture.target.expiresAtEpochMilliseconds
        ))
        let created = try XCTUnwrap(WatchCodexConversationTarget(
            leaseID: UUID(),
            kind: .existing,
            serverEpoch: requestedNew.serverEpoch,
            catalogRevision: requestedNew.catalogRevision,
            entryRevision: 11,
            threadID: "thread_created_independently",
            displayTitle: "独立任务",
            workspaceID: requestedNew.workspaceID,
            workspaceLabel: requestedNew.workspaceLabel,
            expiresAtEpochMilliseconds: requestedNew.expiresAtEpochMilliseconds
        ))
        let createdResult = WristBridgeWireMessage(
            type: "codexConversationTargetResult",
            requestID: requestID.uuidString,
            codexConversationTarget: created,
            accepted: true
        )
        XCTAssertEqual(
            WristBridgeConnection.codexConversationTargetReceipt(
                from: createdResult,
                expectedRequestID: requestID,
                expectedTarget: requestedNew
            )?.selectedTarget,
            created
        )

        let submissionID = UUID()
        let draftID = UUID()
        let draftResult = WristBridgeWireMessage(
            type: "codexConversationDraftReceipt",
            submissionID: submissionID.uuidString,
            draftID: draftID.uuidString,
            codexConversationTarget: fixture.target,
            resolvedCodexConversationTarget: fixture.target,
            accepted: true
        )
        XCTAssertNotNil(WristBridgeConnection.codexConversationDraftReceipt(
            from: draftResult,
            expectedSubmissionID: submissionID,
            expectedDraftID: draftID,
            expectedTarget: fixture.target
        ))
        XCTAssertNil(WristBridgeConnection.codexConversationDraftReceipt(
            from: draftResult,
            expectedSubmissionID: submissionID,
            expectedDraftID: UUID(),
            expectedTarget: fixture.target
        ))
        let differentLeaseForSameThread = try XCTUnwrap(WatchCodexConversationTarget(
            leaseID: UUID(),
            kind: .existing,
            serverEpoch: fixture.target.serverEpoch,
            catalogRevision: fixture.target.catalogRevision,
            entryRevision: fixture.target.entryRevision,
            threadID: fixture.target.threadID,
            displayTitle: fixture.target.displayTitle,
            workspaceID: fixture.target.workspaceID,
            workspaceLabel: fixture.target.workspaceLabel,
            expiresAtEpochMilliseconds: fixture.target.expiresAtEpochMilliseconds
        ))
        XCTAssertNil(WristBridgeConnection.codexConversationDraftReceipt(
            from: WristBridgeWireMessage(
                type: "codexConversationDraftReceipt",
                submissionID: submissionID.uuidString,
                draftID: draftID.uuidString,
                codexConversationTarget: fixture.target,
                resolvedCodexConversationTarget: differentLeaseForSameThread,
                accepted: true
            ),
            expectedSubmissionID: submissionID,
            expectedDraftID: draftID,
            expectedTarget: fixture.target
        ))
        XCTAssertFalse(WristBridgeConnection.acceptsVoiceTargetShape(
            intent: .codexConversation,
            codexTaskIdentity: nil,
            codexConversationTarget: requestedNew
        ))
        XCTAssertEqual(WristBridgeConnection.codexConversationRequestTimeoutSeconds, 13)
    }

    func testWireTaskTombstoneIsExplicitAndRejectsAmbiguity() throws {
        let cleared = WristBridgeWireMessage(
            type: "ready",
            codexTaskCleared: true,
            codexTaskStateRevision: 8
        )
        XCTAssertEqual(
            WristBridgeConnection.codexTaskUpdate(from: cleared),
            .cleared(stateRevision: 8)
        )

        let snapshot = WatchCodexTaskSnapshot(
            threadID: "thr_tombstone",
            turnID: "turn_tombstone",
            workspaceLabel: "tmp",
            title: "Task",
            state: .completed,
            revision: 1,
            updatedAtEpochMilliseconds: 1
        )
        XCTAssertEqual(
            WristBridgeConnection.codexTaskUpdate(from: WristBridgeWireMessage(
                type: "ready",
                codexTask: snapshot,
                codexTaskCleared: false,
                codexTaskStateRevision: 9
            )),
            .snapshot(snapshot, stateRevision: 9)
        )
        XCTAssertNil(WristBridgeConnection.codexTaskUpdate(from: WristBridgeWireMessage(
            type: "ready"
        )))
        XCTAssertNil(WristBridgeConnection.codexTaskUpdate(from: WristBridgeWireMessage(
            type: "ready",
            codexTask: snapshot,
            codexTaskCleared: true,
            codexTaskStateRevision: 10
        )))
    }

    func testRapidProfileEditsSerializeAndStaleAckKeepsPendingRevision() {
        var queue = WristBridgeConnection.ProfileRevisionQueue()
        XCTAssertEqual(queue.request(1), 1)
        XCTAssertNil(queue.request(2))
        XCTAssertEqual(queue.desiredRevision, 2)
        XCTAssertEqual(queue.pendingRevision, 1)

        XCTAssertEqual(queue.complete(type: "watchProfileReady", revision: 99), .stale)
        XCTAssertEqual(queue.pendingRevision, 1)

        XCTAssertEqual(
            queue.complete(type: "watchProfileReady", revision: 1),
            .ready(nextRevision: 2)
        )
        XCTAssertEqual(queue.pendingRevision, 2)
        XCTAssertEqual(
            queue.complete(type: "watchProfileRejected", revision: 2),
            .rejected(nextRevision: nil)
        )
        XCTAssertNil(queue.acceptedRevision)
    }

    func testTimeoutOnlyClearsMatchingGenerationRevisionAndCanRetry() {
        var queue = WristBridgeConnection.ProfileRevisionQueue()
        XCTAssertEqual(queue.request(5), 5)
        XCTAssertFalse(queue.timeout(revision: 4))
        XCTAssertEqual(queue.pendingRevision, 5)
        XCTAssertTrue(queue.timeout(revision: 5))
        XCTAssertNil(queue.pendingRevision)
        XCTAssertEqual(queue.request(5), 5)
    }

    func testUnsolicitedRejectionInvalidatesAcceptedRevision() {
        var queue = WristBridgeConnection.ProfileRevisionQueue()
        XCTAssertEqual(queue.request(3), 3)
        XCTAssertEqual(
            queue.complete(type: "watchProfileReady", revision: 3),
            .ready(nextRevision: nil)
        )
        XCTAssertEqual(queue.acceptedRevision, 3)
        XCTAssertEqual(
            queue.complete(type: "watchProfileRejected", revision: 3),
            .invalidated
        )
        XCTAssertNil(queue.acceptedRevision)
    }

    func testReconnectBackoffIsBoundedAndReusableForSameService() {
        XCTAssertEqual(WristBridgeConnection.reconnectDelaySeconds(attempt: 0), 0.5)
        XCTAssertEqual(WristBridgeConnection.reconnectDelaySeconds(attempt: 1), 1)
        XCTAssertEqual(WristBridgeConnection.reconnectDelaySeconds(attempt: 8), 8)
    }

    func testForegroundRecoveryRearmsEveryNonConnectedTransportExceptManualApproval() {
        XCTAssertTrue(WristBridgeConnection.State.searching.shouldRestartDiscoveryOnActivation)
        XCTAssertTrue(WristBridgeConnection.State.connecting.shouldRestartDiscoveryOnActivation)
        XCTAssertTrue(WristBridgeConnection.State.unavailable("offline")
            .shouldRestartDiscoveryOnActivation)
        XCTAssertFalse(WristBridgeConnection.State.awaitingApproval
            .shouldRestartDiscoveryOnActivation)
        XCTAssertFalse(WristBridgeConnection.State.connected
            .shouldRestartDiscoveryOnActivation)
        XCTAssertFalse(WristBridgeConnection.State.connectedWithError("profile")
            .shouldRestartDiscoveryOnActivation)
    }

    func testWatchStatusLivenessProbeUsesABoundedTimeout() {
        XCTAssertEqual(WristBridgeConnection.livenessProbeTimeoutSeconds, 1)
    }

    func testWatchStatusRecoveryJoinsAnExistingDiscoveryGeneration() {
        XCTAssertTrue(WristBridgeConnection.shouldStartDiscoveryForWatchStatusRequest(
            state: .searching,
            hasBrowser: false,
            hasConnection: false
        ))
        XCTAssertFalse(WristBridgeConnection.shouldStartDiscoveryForWatchStatusRequest(
            state: .searching,
            hasBrowser: true,
            hasConnection: false
        ))
        XCTAssertFalse(WristBridgeConnection.shouldStartDiscoveryForWatchStatusRequest(
            state: .connecting,
            hasBrowser: true,
            hasConnection: true
        ))
        XCTAssertTrue(WristBridgeConnection.shouldStartDiscoveryForWatchStatusRequest(
            state: .unavailable("offline"),
            hasBrowser: false,
            hasConnection: false
        ))
        XCTAssertFalse(WristBridgeConnection.shouldStartDiscoveryForWatchStatusRequest(
            state: .awaitingApproval,
            hasBrowser: true,
            hasConnection: true
        ))
    }

    func testConnectionWatchdogOnlyCoversConnectingAndHandshakePhase() {
        XCTAssertTrue(WristBridgeConnection.State.connecting.needsConnectionWatchdog)
        XCTAssertFalse(WristBridgeConnection.State.searching.needsConnectionWatchdog)
        XCTAssertFalse(WristBridgeConnection.State.awaitingApproval.needsConnectionWatchdog)
        XCTAssertFalse(WristBridgeConnection.State.connected.needsConnectionWatchdog)
        XCTAssertEqual(WristBridgeConnection.connectionWatchdogSeconds, 12)
        XCTAssertEqual(
            WristBridgeConnection.connectionWatchdogSeconds(for: .lan),
            2.5
        )
        XCTAssertEqual(
            WristBridgeConnection.connectionWatchdogSeconds(for: .tailnet),
            6
        )
        XCTAssertLessThan(
            (WristBridgeConnection.lanConnectionWatchdogSeconds
                + WristBridgeConnection.tailnetConnectionWatchdogSeconds) * 1_000,
            Double(WatchRelayController.liveStatusRecoveryMilliseconds)
        )
        XCTAssertTrue(WristBridgeConnection.shouldExpireConnectionWatchdog(
            expectedGeneration: 4,
            currentGeneration: 4,
            state: .connecting,
            hasConnection: true
        ))
        XCTAssertFalse(WristBridgeConnection.shouldExpireConnectionWatchdog(
            expectedGeneration: 3,
            currentGeneration: 4,
            state: .connecting,
            hasConnection: true
        ))
        XCTAssertFalse(WristBridgeConnection.shouldExpireConnectionWatchdog(
            expectedGeneration: 4,
            currentGeneration: 4,
            state: .awaitingApproval,
            hasConnection: true
        ))
        XCTAssertFalse(WristBridgeConnection.shouldExpireConnectionWatchdog(
            expectedGeneration: 4,
            currentGeneration: 4,
            state: .connecting,
            hasConnection: false
        ))
    }

    func testPrivateNetworkTargetOnlyAcceptsFullMagicDNSOrTailscaleAddresses() throws {
        XCTAssertEqual(
            WristPrivateNetworkHostValidator.normalizedHost(
                "  My-Mac.Example.ts.net.  "
            ),
            "my-mac.example.ts.net"
        )
        XCTAssertEqual(
            WristPrivateNetworkHostValidator.normalizedHost("100.64.0.1"),
            "100.64.0.1"
        )
        XCTAssertEqual(
            WristPrivateNetworkHostValidator.normalizedHost("100.127.255.254"),
            "100.127.255.254"
        )
        XCTAssertEqual(
            WristPrivateNetworkHostValidator.normalizedHost("fd7a:115c:a1e0::9"),
            "fd7a:115c:a1e0::9"
        )

        for rejected in [
            "mac.ts.net",
            "https://mac.example.invalid",
            "mac.example.ts.net:60927",
            "mac.example.ts.net/path",
            "user@example.invalid",
            "192.168.1.2",
            [100, 63, 255, 255].map(String.init).joined(separator: "."),
            [100, 128, 0, 1].map(String.init).joined(separator: "."),
            "192.0.2.8",
            "fd12:3456::1",
            "example.com",
        ] {
            XCTAssertNil(
                WristPrivateNetworkHostValidator.normalizedHost(rejected),
                "expected private-network target to be rejected: \(rejected)"
            )
        }

        let configuration = try WristPrivateNetworkConfiguration.validated(
            isEnabled: true,
            host: "mac.example.ts.net",
            privateOnly: false
        ).get()
        XCTAssertTrue(configuration.isEnabled)
        XCTAssertEqual(
            configuration.endpoint,
            .hostPort(host: "mac.example.ts.net", port: 60_927)
        )
        XCTAssertThrowsError(try WristPrivateNetworkConfiguration.validated(
            isEnabled: true,
            host: "mac.example.ts.net",
            privateOnly: true
        ).get())
        let privateOnlyIP = try WristPrivateNetworkConfiguration.validated(
            isEnabled: true,
            host: "100.64.0.1",
            privateOnly: true
        ).get()
        XCTAssertEqual(
            privateOnlyIP.endpoint,
            .hostPort(host: "100.64.0.1", port: 60_927)
        )
        XCTAssertEqual(
            try WristPrivateNetworkConfiguration.validated(
                isEnabled: false,
                host: "not a host"
            ).get(),
            .disabled
        )
    }

    func testIdentityStorageOnlyCreatesForMissingAndNeverForTransientErrors() {
        XCTAssertEqual(
            WristBridgeInstallationIdentity.storageAction(
                copyStatus: errSecSuccess,
                hasStoredData: true,
                hasValidKey: true
            ),
            .useStored
        )
        XCTAssertEqual(
            WristBridgeInstallationIdentity.storageAction(
                copyStatus: errSecSuccess,
                hasStoredData: true,
                hasValidKey: false
            ),
            .reject
        )
        XCTAssertEqual(
            WristBridgeInstallationIdentity.storageAction(
                copyStatus: errSecItemNotFound,
                hasStoredData: false,
                hasValidKey: false
            ),
            .create
        )
        for transientStatus in [errSecInteractionNotAllowed, errSecNotAvailable, errSecAuthFailed] {
            XCTAssertEqual(
                WristBridgeInstallationIdentity.storageAction(
                    copyStatus: transientStatus,
                    hasStoredData: false,
                    hasValidKey: false
                ),
                .reject
            )
        }
        XCTAssertEqual(
            WristBridgeInstallationIdentity.storageAction(
                copyStatus: errSecSuccess,
                hasStoredData: false,
                hasValidKey: false
            ),
            .reject
        )
    }

    private func makeConversationFixture() throws -> (
        target: WatchCodexConversationTarget,
        catalog: WatchCodexConversationCatalog
    ) {
        let serverEpoch = UUID()
        let target = try XCTUnwrap(WatchCodexConversationTarget(
            leaseID: UUID(),
            kind: .existing,
            serverEpoch: serverEpoch,
            catalogRevision: 4,
            entryRevision: 9,
            threadID: "thread_conversation_fixture",
            displayTitle: "会话",
            workspaceID: "workspace-project",
            workspaceLabel: "项目",
            expiresAtEpochMilliseconds: 4_000_000_000_000
        ))
        let entry = try XCTUnwrap(WatchCodexConversationEntry(
            threadID: target.threadID,
            title: target.displayTitle,
            workspaceLabel: target.workspaceLabel,
            state: .idle,
            updatedAtEpochMilliseconds: 900,
            canAcceptInput: true,
            entryRevision: target.entryRevision,
            target: target
        ))
        let catalog = try XCTUnwrap(WatchCodexConversationCatalog(
            serverEpoch: serverEpoch,
            revision: target.catalogRevision,
            entries: [entry],
            hasMore: false,
            refreshedAtEpochMilliseconds: 1_000
        ))
        return (target, catalog)
    }
}
#endif
