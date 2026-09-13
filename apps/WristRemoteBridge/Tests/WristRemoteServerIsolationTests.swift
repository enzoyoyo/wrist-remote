import CryptoKit
import Foundation
import Network
import Security
import XCTest
@testable import WristRemoteBridge

final class WristRemoteServerIsolationTests: XCTestCase {
    private func isolatedServer(
        identityLoader: @escaping WristRemoteServer.IdentityLoader
    ) -> WristRemoteServer {
        WristRemoteServer(
            identityLoader: identityLoader,
            localEndpointProvider: { _ in .hostPort(host: .ipv4(.loopback), port: .any) },
            advertisesBonjour: false
        )
    }

    func testServerIdentityLoaderIsDeferredUntilStartAndRunsOffMainThread() {
        let loaderCalled = expectation(description: "identity loader called")
        let identityFailure = expectation(description: "identity failure published")
        var loaderCallCount = 0
        var statuses: [WristRemoteServer.Status] = []
        let lock = NSLock()
        let server = isolatedServer(identityLoader: {
            XCTAssertFalse(Thread.isMainThread)
            lock.lock()
            loaderCallCount += 1
            lock.unlock()
            loaderCalled.fulfill()
            return nil
        })
        server.onStatus = { status in
            statuses.append(status)
            if case .identityUnavailable = status {
                identityFailure.fulfill()
            }
        }

        lock.lock()
        XCTAssertEqual(loaderCallCount, 0)
        lock.unlock()
        server.start()

        wait(for: [loaderCalled, identityFailure], timeout: 2)
        lock.lock()
        XCTAssertEqual(loaderCallCount, 1)
        lock.unlock()
        XCTAssertEqual(statuses.first, .loadingIdentity)
        XCTAssertEqual(
            statuses.last,
            .identityUnavailable(WristRemoteServer.identityUnavailableDetail)
        )
        XCTAssertFalse(statuses.contains(.starting))
    }

    func testServerDoesNotStartListenerUntilBackgroundIdentityLoadCompletes() {
        let loaderEntered = expectation(description: "identity loader entered")
        let loadingPublished = expectation(description: "loading published")
        let listenerStarting = expectation(description: "listener starts after identity")
        let releaseLoader = DispatchSemaphore(value: 0)
        var statuses: [WristRemoteServer.Status] = []
        let server = isolatedServer(identityLoader: {
            loaderEntered.fulfill()
            XCTAssertEqual(releaseLoader.wait(timeout: .now() + 2), .success)
            return P256.Signing.PrivateKey()
        })
        server.onStatus = { status in
            statuses.append(status)
            switch status {
            case .loadingIdentity:
                loadingPublished.fulfill()
            case .starting:
                listenerStarting.fulfill()
            default:
                break
            }
        }

        server.start()
        wait(for: [loaderEntered, loadingPublished], timeout: 2)
        XCTAssertFalse(statuses.contains(.starting))

        releaseLoader.signal()
        wait(for: [listenerStarting], timeout: 2)
        server.stop()
    }

    func testServerCanRetryIdentityAfterTransientFailure() {
        let firstFailure = expectation(description: "first identity failure")
        let secondLoad = expectation(description: "second identity load")
        let listenerStarting = expectation(description: "listener starts after retry")
        let lock = NSLock()
        var attempt = 0
        let server = isolatedServer(identityLoader: {
            lock.lock()
            attempt += 1
            let currentAttempt = attempt
            lock.unlock()
            if currentAttempt == 1 { return nil }
            secondLoad.fulfill()
            return P256.Signing.PrivateKey()
        })
        server.onStatus = { status in
            switch status {
            case .identityUnavailable:
                firstFailure.fulfill()
            case .starting:
                listenerStarting.fulfill()
            default:
                break
            }
        }

        server.start()
        wait(for: [firstFailure], timeout: 2)
        server.start()
        wait(for: [secondLoad, listenerStarting], timeout: 2)
        lock.lock()
        XCTAssertEqual(attempt, 2)
        lock.unlock()
        server.stop()
    }

    func testUsesDedicatedBonjourAndCryptographicDomains() throws {
        XCTAssertEqual(WristRemoteServer.serviceType, "_wristremote._tcp")
        XCTAssertEqual(WristRemoteServer.port, 60_927)
        XCTAssertNotEqual(WristRemoteServer.port, 60_880)
        XCTAssertEqual(WristRemoteServer.sessionSalt, "WristRemoteBridge nearby session")
        XCTAssertEqual(
            BridgeWireMessage.serverIdentityProofDomain,
            "WristRemoteBridge server identity v1"
        )
        XCTAssertEqual(
            BridgeWireMessage.clientAuthenticationProofDomain,
            "WristRemoteBridge client auth v1"
        )
        XCTAssertEqual(
            BridgeWireMessage.secureEnvelopeDomain,
            "WristRemoteBridge secure envelope v1"
        )
        XCTAssertNotEqual(
            BridgeWireMessage.serverIdentityProofDomain,
            BridgeWireMessage.clientAuthenticationProofDomain
        )
    }

    func testHandshakeRequiresExactProtocolAndClientRole() {
        let valid = BridgeWireMessage(
            type: "hello",
            protocolID: WristRemoteHandshake.protocolID,
            clientRole: WristRemoteHandshake.clientRole,
            publicKey: Data(repeating: 1, count: 32).base64EncodedString(),
            capabilities: [
                BridgeWireMessage.secureSequenceCapability,
                BridgeWireMessage.audioDeliveryReceiptsCapability,
            ]
        )
        XCTAssertTrue(WristRemoteHandshake.acceptsClient(valid))

        var missingSecureSequenceCapability = valid
        missingSecureSequenceCapability.capabilities = nil
        XCTAssertFalse(WristRemoteHandshake.acceptsClient(missingSecureSequenceCapability))

        var legacyClientWithoutAudioReceipts = valid
        legacyClientWithoutAudioReceipts.capabilities = [
            BridgeWireMessage.secureSequenceCapability,
        ]
        XCTAssertFalse(WristRemoteHandshake.acceptsClient(legacyClientWithoutAudioReceipts))

        XCTAssertFalse(WristRemoteHandshake.acceptsClient(BridgeWireMessage(
            type: "hello",
            protocolID: "org.example.unrelated.protocol",
            clientRole: WristRemoteHandshake.clientRole,
            publicKey: valid.publicKey
        )))
        XCTAssertFalse(WristRemoteHandshake.acceptsClient(BridgeWireMessage(
            type: "hello",
            protocolID: WristRemoteHandshake.protocolID,
            clientRole: "nearbyPhone",
            publicKey: valid.publicKey
        )))
        XCTAssertFalse(WristRemoteHandshake.acceptsClient(BridgeWireMessage(
            type: "hello",
            protocolID: WristRemoteHandshake.protocolID,
            clientRole: WristRemoteHandshake.clientRole,
            serverRole: WristRemoteHandshake.serverRole,
            publicKey: valid.publicKey
        )))
        var leakedStableIdentity = valid
        leakedStableIdentity.deviceName = "iPhone"
        leakedStableIdentity.identityPublicKey = "stable-key"
        XCTAssertFalse(WristRemoteHandshake.acceptsClient(leakedStableIdentity))
        var missingEphemeral = valid
        missingEphemeral.publicKey = nil
        XCTAssertFalse(WristRemoteHandshake.acceptsClient(missingEphemeral))

        XCTAssertTrue(WristRemoteHandshake.acceptsPersistedClientApproval(
            identityFingerprint: "fingerprint",
            persistenceSucceeded: true
        ))
        XCTAssertFalse(WristRemoteHandshake.acceptsPersistedClientApproval(
            identityFingerprint: "fingerprint",
            persistenceSucceeded: false
        ))
        XCTAssertFalse(WristRemoteHandshake.acceptsPersistedClientApproval(
            identityFingerprint: nil,
            persistenceSucceeded: true
        ))
    }

    func testAudioDeliveryReceiptIsConsumerBackedAndContiguous() {
        var gate = WristBridgeAudioReceiveGate()
        XCTAssertEqual(
            gate.receive(sequence: 0) { true },
            WristBridgeAudioDeliveryReceipt(
                sequence: 0,
                accepted: true,
                contiguousThrough: 0
            )
        )
        XCTAssertEqual(
            gate.receive(sequence: 2) { true },
            WristBridgeAudioDeliveryReceipt(
                sequence: 2,
                accepted: false,
                contiguousThrough: 0
            )
        )
        XCTAssertEqual(
            gate.receive(sequence: 1) { false },
            WristBridgeAudioDeliveryReceipt(
                sequence: 1,
                accepted: false,
                contiguousThrough: 0
            )
        )
    }

    func testSecureEnvelopeAADBindsProtocolDomainRoleAndSequence() throws {
        let clientZero = try XCTUnwrap(
            BridgeWireMessage.secureEnvelopeAuthenticatedData(
                senderRole: BridgeWireMessage.clientRole,
                sequence: 0
            )
        )
        let clientOne = try XCTUnwrap(
            BridgeWireMessage.secureEnvelopeAuthenticatedData(
                senderRole: BridgeWireMessage.clientRole,
                sequence: 1
            )
        )
        let serverZero = try XCTUnwrap(
            BridgeWireMessage.secureEnvelopeAuthenticatedData(
                senderRole: BridgeWireMessage.serverRole,
                sequence: 0
            )
        )

        XCTAssertTrue(clientZero.starts(with: Data(
            (BridgeWireMessage.secureEnvelopeDomain + "\0").utf8
        )))
        XCTAssertNotNil(clientZero.range(of: Data(BridgeWireMessage.protocolID.utf8)))
        XCTAssertNotEqual(clientZero, clientOne)
        XCTAssertNotEqual(clientZero, serverZero)
        XCTAssertNil(BridgeWireMessage.secureEnvelopeAuthenticatedData(
            senderRole: "unexpectedRole",
            sequence: 0
        ))
        XCTAssertTrue(BridgeWireMessage.acceptsSecureSequence(0, expected: 0))
        XCTAssertFalse(BridgeWireMessage.acceptsSecureSequence(nil, expected: 0))
        XCTAssertFalse(BridgeWireMessage.acceptsSecureSequence(1, expected: 0))
    }

    func testRelayProvisioningRequiresExplicitInstallOrClearTombstone() throws {
        let encoded = "encoded-provisioning"
        XCTAssertEqual(
            BridgeWireMessage.internetRelayProvisioningDirective(
                encoded: encoded,
                cleared: false
            ),
            .install(encoded)
        )
        XCTAssertEqual(
            BridgeWireMessage.internetRelayProvisioningDirective(
                encoded: nil,
                cleared: true
            ),
            .clear
        )
        XCTAssertNil(BridgeWireMessage.internetRelayProvisioningDirective(
            encoded: encoded,
            cleared: true
        ))
        XCTAssertNil(BridgeWireMessage.internetRelayProvisioningDirective(
            encoded: encoded,
            cleared: nil
        ))
        XCTAssertNil(BridgeWireMessage.internetRelayProvisioningDirective(
            encoded: nil,
            cleared: false
        ))
        XCTAssertNil(BridgeWireMessage.internetRelayProvisioningDirective(
            encoded: nil,
            cleared: nil
        ))

        let clearMessage = BridgeWireMessage(
            type: "internetRelayProvisioning",
            internetRelayProvisioningCleared: true
        )
        let roundTrip = try JSONDecoder().decode(
            BridgeWireMessage.self,
            from: JSONEncoder().encode(clearMessage)
        )
        XCTAssertNil(roundTrip.internetRelayProvisioning)
        XCTAssertEqual(roundTrip.internetRelayProvisioningCleared, true)
    }

    func testSecureChannelRejectsReplayGapTamperingAndWrongDirection() throws {
        let key = SymmetricKey(size: .bits256)
        let firstMessage = BridgeWireMessage(type: "command", command: "first")
        let secondMessage = BridgeWireMessage(type: "command", command: "second")
        var sender = WristBridgeSecureChannel()
        let first = try XCTUnwrap(sender.seal(
            firstMessage,
            using: key,
            senderRole: BridgeWireMessage.clientRole
        ))
        let second = try XCTUnwrap(sender.seal(
            secondMessage,
            using: key,
            senderRole: BridgeWireMessage.clientRole
        ))
        XCTAssertEqual(first.sequence, 0)
        XCTAssertEqual(second.sequence, 1)
        XCTAssertEqual(sender.nextOutboundSequence, 2)

        var gapReceiver = WristBridgeSecureChannel()
        XCTAssertNil(gapReceiver.open(
            second,
            using: key,
            senderRole: BridgeWireMessage.clientRole
        ))
        XCTAssertEqual(gapReceiver.nextInboundSequence, 0)
        XCTAssertEqual(gapReceiver.open(
            first,
            using: key,
            senderRole: BridgeWireMessage.clientRole
        ), firstMessage)
        XCTAssertEqual(gapReceiver.nextInboundSequence, 1)
        XCTAssertNil(gapReceiver.open(
            first,
            using: key,
            senderRole: BridgeWireMessage.clientRole
        ))
        XCTAssertEqual(gapReceiver.nextInboundSequence, 1)

        var authenticatedDataTamper = first
        authenticatedDataTamper.sequence = 1
        XCTAssertNil(gapReceiver.open(
            authenticatedDataTamper,
            using: key,
            senderRole: BridgeWireMessage.clientRole
        ))
        XCTAssertEqual(gapReceiver.nextInboundSequence, 1)
        XCTAssertEqual(gapReceiver.open(
            second,
            using: key,
            senderRole: BridgeWireMessage.clientRole
        ), secondMessage)

        var ciphertextTamper = first
        var tamperedPayload = try XCTUnwrap(Data(
            base64Encoded: try XCTUnwrap(first.payload)
        ))
        tamperedPayload[tamperedPayload.index(before: tamperedPayload.endIndex)] ^= 0x01
        ciphertextTamper.payload = tamperedPayload.base64EncodedString()
        var ciphertextReceiver = WristBridgeSecureChannel()
        XCTAssertNil(ciphertextReceiver.open(
            ciphertextTamper,
            using: key,
            senderRole: BridgeWireMessage.clientRole
        ))
        XCTAssertEqual(ciphertextReceiver.nextInboundSequence, 0)
        XCTAssertEqual(ciphertextReceiver.open(
            first,
            using: key,
            senderRole: BridgeWireMessage.clientRole
        ), firstMessage)

        var wrongDirectionReceiver = WristBridgeSecureChannel()
        XCTAssertNil(wrongDirectionReceiver.open(
            first,
            using: key,
            senderRole: BridgeWireMessage.serverRole
        ))
        XCTAssertEqual(wrongDirectionReceiver.nextInboundSequence, 0)
        XCTAssertEqual(wrongDirectionReceiver.open(
            first,
            using: key,
            senderRole: BridgeWireMessage.clientRole
        ), firstMessage)
    }

    func testSecureChannelResetStartsBothDirectionsAtZero() throws {
        let key = SymmetricKey(size: .bits256)
        var channel = WristBridgeSecureChannel()
        let envelope = try XCTUnwrap(channel.seal(
            BridgeWireMessage(type: "command", command: "first"),
            using: key,
            senderRole: BridgeWireMessage.clientRole
        ))
        XCTAssertEqual(channel.open(
            envelope,
            using: key,
            senderRole: BridgeWireMessage.clientRole
        )?.command, "first")
        XCTAssertEqual(channel.nextOutboundSequence, 1)
        XCTAssertEqual(channel.nextInboundSequence, 1)

        channel.reset()
        XCTAssertEqual(channel.nextOutboundSequence, 0)
        XCTAssertEqual(channel.nextInboundSequence, 0)
        XCTAssertEqual(try XCTUnwrap(channel.seal(
            BridgeWireMessage(type: "command", command: "after-reset"),
            using: key,
            senderRole: BridgeWireMessage.clientRole
        )).sequence, 0)
    }

    func testLANPeerGateAllowsPrivateLoopbackAndCurrentLinkLocalPeer() {
        let permittedHosts = [
            "10.23.4.5",
            "127.0.0.1",
            "169.254.8.9",
            "172.16.0.1",
            "172.31.255.254",
            "192.168.1.20",
            "::1",
            "fe80::1",
            "fd12:3456:789a::2",
            "::ffff:192.168.1.20",
        ]
        for rawHost in permittedHosts {
            XCTAssertTrue(
                WristRemotePeerAccessPolicy.permits(
                    endpoint(rawHost),
                    localPhysicalIPv6Addresses: []
                ),
                "expected local peer to be allowed: \(rawHost)"
            )
        }
    }

    func testLANPeerGateRejectsGlobalIPv6EvenOnSamePhysicalSubnet() throws {
        let localAddress = try XCTUnwrap(IPv6Address("2001:db8:1:2::1"))
        let locals = [localAddress.rawValue]
        XCTAssertFalse(WristRemotePeerAccessPolicy.permits(
            endpoint("2001:db8:1:2::2"),
            localPhysicalIPv6Addresses: locals
        ))
        XCTAssertFalse(WristRemotePeerAccessPolicy.permits(
            endpoint("2001:db8:1:3::2"),
            localPhysicalIPv6Addresses: locals
        ))
    }

    func testLANPeerGateRejectsPublicIPv4HostnamesAndUnresolvedEndpoints() {
        for rawHost in [
            "198.51.100.7",
            "100.64.0.1",
            "203.0.113.8",
            "fd7a:115c:a1e0::1",
            "iphone.local",
        ] {
            XCTAssertFalse(
                WristRemotePeerAccessPolicy.permits(
                    endpoint(rawHost),
                    localPhysicalIPv6Addresses: []
                ),
                "expected non-local peer to be rejected: \(rawHost)"
            )
        }
        XCTAssertFalse(WristRemotePeerAccessPolicy.permits(
            .service(
                name: "Unresolved",
                type: WristRemoteServer.serviceType,
                domain: "local",
                interface: nil
            ),
            localPhysicalIPv6Addresses: []
        ))
    }

    func testListenerBindingSelectsPrivateIPv4OnAnApprovedNonTunnelInterface() {
        let selected = WristRemoteListenerBindingPolicy.endpoint(
            from: [
                bindCandidate(interfaceName: "utun8", host: "192.168.50.2"),
                bindCandidate(interfaceName: "en0", host: "203.0.113.9"),
                bindCandidate(interfaceName: "en0", host: "2001:db8::9"),
                bindCandidate(interfaceName: "en1", host: "192.168.50.3"),
            ],
            port: WristRemoteServer.port
        )
        XCTAssertEqual(selected, endpoint("192.168.50.3"))
    }

    func testListenerBindingUsesUniqueLocalIPv6WhenPrivateIPv4IsUnavailable() {
        let selected = WristRemoteListenerBindingPolicy.endpoint(
            from: [bindCandidate(interfaceName: "en0", host: "fd12:3456:789a::4")],
            port: WristRemoteServer.port
        )
        XCTAssertEqual(selected, endpoint("fd12:3456:789a::4"))
    }

    func testListenerBindingFailsClosedWithoutANonPublicPhysicalAddress() {
        let selected = WristRemoteListenerBindingPolicy.endpoint(
            from: [
                bindCandidate(interfaceName: "lo0", host: "127.0.0.1"),
                bindCandidate(interfaceName: "en0", host: "198.51.100.4"),
                bindCandidate(interfaceName: "en0", host: "2001:db8::4"),
                bindCandidate(interfaceName: "en0", host: "mac.example.invalid"),
            ],
            port: WristRemoteServer.port
        )
        XCTAssertNil(selected)
    }

    func testTailnetBindingRequiresUtunAndOfficialTailscaleAddressSpace() {
        let selected = WristRemoteTailnetBindingPolicy.endpoint(
            from: [
                tailnetCandidate(interfaceName: "en0", host: "100.70.1.2"),
                tailnetCandidate(interfaceName: "utun2", host: "192.168.1.2"),
                tailnetCandidate(interfaceName: "utun3", host: "fd12:3456::1"),
                tailnetCandidate(interfaceName: "utun8", host: "fd7a:115c:a1e0::8"),
                tailnetCandidate(interfaceName: "utun9", host: "100.90.1.4"),
            ],
            port: WristRemoteServer.port
        )
        XCTAssertEqual(selected, endpoint("100.90.1.4"))

        XCTAssertNil(WristRemoteTailnetBindingPolicy.endpoint(
            from: [
                tailnetCandidate(interfaceName: "en0", host: "100.70.1.2"),
                tailnetCandidate(interfaceName: "utun2", host: "10.0.0.2"),
                tailnetCandidate(interfaceName: "utun3", host: "fd12:3456::1"),
                tailnetCandidate(interfaceName: "utun4", host: "203.0.113.2"),
            ],
            port: WristRemoteServer.port
        ))
    }

    func testTailnetPeerGateCannotBypassLANPeerGate() {
        for rawHost in [
            "100.64.0.1",
            "100.127.255.254",
            "fd7a:115c:a1e0::1",
            "::ffff:100.90.1.2",
        ] {
            XCTAssertTrue(
                WristRemoteTailnetBindingPolicy.permitsPeer(endpoint(rawHost)),
                "expected tailnet peer to be allowed: \(rawHost)"
            )
            XCTAssertFalse(
                WristRemotePeerAccessPolicy.permits(
                    endpoint(rawHost),
                    localPhysicalIPv6Addresses: []
                ),
                "expected tailnet peer to remain rejected by LAN gate: \(rawHost)"
            )
        }

        for rawHost in [
            "10.0.0.2",
            "192.168.1.2",
            [100, 63, 255, 255].map(String.init).joined(separator: "."),
            [100, 128, 0, 1].map(String.init).joined(separator: "."),
            "fd12:3456::1",
            "2001:db8::1",
            "mac.example.ts.net",
        ] {
            XCTAssertFalse(
                WristRemoteTailnetBindingPolicy.permitsPeer(endpoint(rawHost)),
                "expected non-tailnet peer to be rejected: \(rawHost)"
            )
        }
    }

    @MainActor
    func testPlaceholderRelayNeverStartsANetworkRequest() async throws {
        RecordingURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecordingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let credentials = WristInternetRelayMacCredentials(
            provisioning: WristInternetRelayDeviceProvisioning(
                baseURL: URL(string: "https://relay.example.invalid")!,
                roomID: UUID(),
                deviceID: UUID(),
                deviceToken: Data(repeating: 1, count: 32),
                encryptionKey: Data(repeating: 2, count: 32)
            ),
            macToken: Data(repeating: 3, count: 32)
        )
        let client = InternetRelayClient(credentials: credentials, urlSession: session)
        defer {
            client.stop()
            session.invalidateAndCancel()
        }

        client.start()
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(RecordingURLProtocol.requestCount, 0)
        XCTAssertEqual(client.status, .stopped)
    }

    func testLivenessProbeIdentifierIsCanonicalAndCapabilityIsDedicated() {
        let probeID = UUID().uuidString
        XCTAssertTrue(BridgeWireMessage.isValidProbeID(probeID))
        XCTAssertFalse(BridgeWireMessage.isValidProbeID(probeID.lowercased()))
        XCTAssertEqual(
            BridgeWireMessage.connectionLivenessCapability,
            "connectionLivenessV1"
        )
    }

    func testServerAndClientSignaturesBindDifferentTranscriptDomains() throws {
        let clientEphemeral = Data(repeating: 1, count: 32)
        let serverEphemeral = Data(repeating: 2, count: 32)
        let serverIdentity = P256.Signing.PrivateKey()
        let clientIdentity = P256.Signing.PrivateKey()
        let serverProof = try XCTUnwrap(BridgeWireMessage.serverIdentityProof(
            clientEphemeralPublicKey: clientEphemeral,
            serverEphemeralPublicKey: serverEphemeral
        ))
        let signature = try serverIdentity.signature(for: serverProof)
        XCTAssertTrue(serverIdentity.publicKey.isValidSignature(signature, for: serverProof))

        let clientProof = try XCTUnwrap(BridgeWireMessage.clientAuthenticationProof(
            clientEphemeralPublicKey: clientEphemeral,
            serverEphemeralPublicKey: serverEphemeral,
            serverIdentityPublicKey: serverIdentity.publicKey.rawRepresentation,
            clientIdentityPublicKey: clientIdentity.publicKey.rawRepresentation
        ))
        XCTAssertNotEqual(serverProof, clientProof)
        XCTAssertFalse(serverIdentity.publicKey.isValidSignature(signature, for: clientProof))
    }

    func testServerIdentityStorageNeverRotatesOnCorruptOrTransientReads() {
        XCTAssertEqual(
            WristRemoteServerIdentityStore.storageAction(
                copyStatus: errSecSuccess,
                hasStoredData: true,
                hasValidKey: true
            ),
            .useStored
        )
        XCTAssertEqual(
            WristRemoteServerIdentityStore.storageAction(
                copyStatus: errSecItemNotFound,
                hasStoredData: false,
                hasValidKey: false
            ),
            .create
        )
        XCTAssertEqual(
            WristRemoteServerIdentityStore.storageAction(
                copyStatus: errSecSuccess,
                hasStoredData: true,
                hasValidKey: false
            ),
            .reject
        )
        XCTAssertEqual(
            WristRemoteServerIdentityStore.storageAction(
                copyStatus: errSecInteractionNotAllowed,
                hasStoredData: false,
                hasValidKey: false
            ),
            .reject
        )
        XCTAssertEqual(WristRemoteServer.maximumUnauthenticatedClientCount, 8)
        XCTAssertEqual(WristRemoteServer.handshakeTimeoutSeconds, 30)
    }

    func testCodexTargetRejectsSameThreadWithDifferentTurnOrRevision() throws {
        let snapshot = WatchCodexTaskSnapshot(
            threadID: "thr_exact",
            turnID: "turn_current",
            workspaceLabel: "tmp",
            title: "Current task",
            state: .completed,
            revision: 7,
            updatedAtEpochMilliseconds: 7
        )
        let current = try XCTUnwrap(WatchCodexTaskIdentity(snapshot))
        XCTAssertTrue(WristRemoteCodexTargetValidator.accepts(current, snapshot: snapshot))
        XCTAssertFalse(WristRemoteCodexTargetValidator.accepts(
            WatchCodexTaskIdentity(
                threadID: current.threadID,
                turnID: "turn_old",
                revision: current.revision
            ),
            snapshot: snapshot
        ))
        XCTAssertFalse(WristRemoteCodexTargetValidator.accepts(
            WatchCodexTaskIdentity(
                threadID: current.threadID,
                turnID: current.turnID,
                revision: current.revision - 1
            ),
            snapshot: snapshot
        ))
        XCTAssertFalse(WristRemoteCodexTargetValidator.accepts(
            current,
            snapshot: WatchCodexTaskSnapshot(
                threadID: snapshot.threadID,
                turnID: snapshot.turnID,
                workspaceLabel: snapshot.workspaceLabel,
                title: snapshot.title,
                state: .running,
                revision: snapshot.revision,
                updatedAtEpochMilliseconds: snapshot.updatedAtEpochMilliseconds
            )
        ))
    }

    private func bindCandidate(
        interfaceName: String,
        host rawHost: String
    ) -> WristRemoteLocalBindCandidate {
        WristRemoteLocalBindCandidate(
            interfaceName: interfaceName,
            host: NWEndpoint.Host(rawHost)
        )
    }

    private func tailnetCandidate(
        interfaceName: String,
        host rawHost: String
    ) -> WristRemoteTailnetBindCandidate {
        WristRemoteTailnetBindCandidate(
            interfaceName: interfaceName,
            host: NWEndpoint.Host(rawHost)
        )
    }

    private func endpoint(_ rawHost: String) -> NWEndpoint {
        .hostPort(host: NWEndpoint.Host(rawHost), port: 60_927)
    }
}

private final class RecordingURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var count = 0

    static var requestCount: Int {
        lock.withLock { count }
    }

    static func reset() {
        lock.withLock { count = 0 }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.withLock { Self.count += 1 }
        client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
    }

    override func stopLoading() {}
}
