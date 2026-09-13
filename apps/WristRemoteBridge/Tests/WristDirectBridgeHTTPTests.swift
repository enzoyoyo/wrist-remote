import CryptoKit
import Foundation
import Network
import XCTest
@testable import WristRemoteBridge

final class WristDirectBridgeHTTPTests: XCTestCase {
    func testApprovalReplacementAndDisconnectionAreIdentityScoped() {
        let approved = ["phone", "watch"]
        XCTAssertTrue(WristRemoteClientAdmissionPolicy.canApprove(identity: "tablet", approvedIdentities: approved))
        XCTAssertFalse(WristRemoteClientAdmissionPolicy.replaces(existingIdentity: "phone", newlyApprovedIdentity: "watch"))
        XCTAssertTrue(WristRemoteClientAdmissionPolicy.replaces(existingIdentity: "watch", newlyApprovedIdentity: "watch"))
        XCTAssertFalse(WristRemoteClientAdmissionPolicy.replaces(existingIdentity: nil, newlyApprovedIdentity: nil))
        let full = ["phone", "watch", "tablet", "other"]
        XCTAssertFalse(WristRemoteClientAdmissionPolicy.canApprove(identity: "fifth", approvedIdentities: full))
        XCTAssertTrue(WristRemoteClientAdmissionPolicy.canApprove(identity: "watch", approvedIdentities: full))
        XCTAssertFalse(WristRemoteClientAdmissionPolicy.resetsProfile(wasApproved: true, remainingApprovedCount: 1))
        XCTAssertFalse(WristRemoteClientAdmissionPolicy.resetsProfile(wasApproved: false, remainingApprovedCount: 0))
        XCTAssertTrue(WristRemoteClientAdmissionPolicy.resetsProfile(wasApproved: true, remainingApprovedCount: 0))
        XCTAssertTrue(WristRemoteClientAdmissionPolicy.mayPresentApproval(hasPendingApproval: false))
        XCTAssertFalse(WristRemoteClientAdmissionPolicy.mayPresentApproval(hasPendingApproval: true))
    }

    func testLANRebindingIsLimitedToChangedLocalEndpointsAndRetriesMissingAddresses() {
        let first: NWEndpoint = .hostPort(host: "192.168.1.20", port: 60927)
        let changed: NWEndpoint = .hostPort(host: "192.168.2.20", port: 60927)
        let http: NWEndpoint = .hostPort(host: "192.168.1.20", port: 60929)
        XCTAssertFalse(WristRemoteLocalListenerLifecyclePolicy.needsRebind(previous: first, current: first))
        XCTAssertTrue(WristRemoteLocalListenerLifecyclePolicy.needsRebind(previous: first, current: changed))
        XCTAssertFalse(WristRemoteLocalListenerLifecyclePolicy.needsRebind(previous: http, current: http))
        XCTAssertTrue(WristRemoteLocalListenerLifecyclePolicy.needsRebind(previous: first, current: nil))
        XCTAssertTrue(WristRemoteLocalListenerLifecyclePolicy.needsRebind(previous: nil, current: first))
        XCTAssertEqual(WristRemoteLocalListenerLifecyclePolicy.retryDelaySeconds(hasLANListener: false, hasHTTPListener: true), 5)
        XCTAssertEqual(WristRemoteLocalListenerLifecyclePolicy.retryDelaySeconds(hasLANListener: true, hasHTTPListener: false), 5)
        XCTAssertEqual(WristRemoteLocalListenerLifecyclePolicy.retryDelaySeconds(hasLANListener: true, hasHTTPListener: true), 15)
    }

    func testRawGestureOwnerPreventsCrossDeviceReleaseAndCancelsOnlyItsButtons() {
        let first = NSObject(), second = NSObject()
        let phone = ObjectIdentifier(first), watch = ObjectIdentifier(second)
        var ownership = WristRemoteRawGestureOwnership()
        XCTAssertTrue(ownership.accept(owner: phone, button: .ok, phase: .press))
        XCTAssertFalse(ownership.accept(owner: watch, button: .ok, phase: .release))
        XCTAssertFalse(ownership.accept(owner: watch, button: .up, phase: .press))
        XCTAssertEqual(ownership.release(owner: watch), [])
        XCTAssertEqual(ownership.ownerID, phone)
        XCTAssertTrue(ownership.accept(owner: phone, button: .ok, phase: .release))
        XCTAssertTrue(ownership.pressedButtons.isEmpty)
        XCTAssertEqual(ownership.release(owner: phone), [.ok])
        XCTAssertTrue(ownership.accept(owner: watch, button: .up, phase: .press))
        XCTAssertEqual(ownership.release(owner: watch), [.up])
    }

    func testVoiceOwnerRejectsSameStreamIDFromAnotherConnectionAndStaleRelease() throws {
        let first = NSObject(), second = NSObject()
        let phone = ObjectIdentifier(first), other = ObjectIdentifier(second)
        let stream = UUID().uuidString
        var ownership = WristRemoteVoiceOwnership()
        let originalTicket = try XCTUnwrap(ownership.reserve(owner: phone, session: stream))
        XCTAssertNil(ownership.reserve(owner: other, session: stream))
        XCTAssertFalse(ownership.matches(owner: other, session: stream))
        ownership.release(owner: other, session: stream)
        XCTAssertTrue(ownership.matches(owner: phone, session: stream))
        ownership.release(owner: phone, session: UUID().uuidString)
        XCTAssertTrue(ownership.matches(owner: phone, session: stream))
        ownership.release(owner: phone, session: stream)
        let replacementTicket = try XCTUnwrap(ownership.reserve(owner: phone, session: stream))
        XCTAssertNotEqual(originalTicket, replacementTicket)
        XCTAssertFalse(ownership.matches(owner: phone, session: stream, ticket: originalTicket))
        ownership.release(owner: phone, session: stream, ticket: originalTicket)
        XCTAssertTrue(ownership.matches(owner: phone, session: stream, ticket: replacementTicket))
        ownership.release(owner: phone, session: stream, ticket: replacementTicket)
        XCTAssertNotNil(ownership.reserve(owner: other, session: UUID().uuidString))
    }

    func testHTTPCodecRequiresBoundedUnambiguousPOSTFraming() throws {
        let request = WristDirectBridgeHTTPRequest(sessionID: nil, message: BridgeWireMessage(type: "hello"))
        let body = try JSONEncoder().encode(request)
        let prefix = "POST /v1/bridge HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\n"
        var valid = Data((prefix + "\r\n").utf8)
        valid.append(body)
        XCTAssertEqual(try WristDirectBridgeHTTPCodec.parse(valid), request)
        XCTAssertNil(try WristDirectBridgeHTTPCodec.parse(valid.dropLast()))
        var pipelined = valid
        pipelined.append(0x20)
        XCTAssertThrowsError(try WristDirectBridgeHTTPCodec.parse(pipelined))
        for header in [
            "Content-Length: \(body.count)\r\n", "Transfer-Encoding: chunked\r\n",
            "content-length: \(body.count)\r\n", " Content-Length: 1\r\n",
        ] {
            var data = Data((prefix + header + "\r\n").utf8)
            data.append(body)
            XCTAssertThrowsError(try WristDirectBridgeHTTPCodec.parse(data))
        }
        XCTAssertThrowsError(try WristDirectBridgeHTTPCodec.parse(Data(repeating: 65, count: 8_193)))
        let oversized = Data("POST /v1/bridge HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: 262145\r\n\r\n".utf8)
        XCTAssertThrowsError(try WristDirectBridgeHTTPCodec.parse(oversized))
        XCTAssertThrowsError(try WristDirectBridgeHTTPCodec.parse(Data("GET /v1/bridge HTTP/1.1\r\nContent-Length: 0\r\n\r\n".utf8)))
    }

    func testPublicSessionIDWithoutCiphertextCannotPoll() throws {
        let request = WristDirectBridgeHTTPRequest(
            sessionID: UUID().uuidString, message: BridgeWireMessage(type: "livenessProbe", probeID: UUID().uuidString)
        )
        let body = try JSONEncoder().encode(request)
        var http = Data("POST /v1/bridge HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\n\r\n".utf8)
        http.append(body)
        XCTAssertThrowsError(try WristDirectBridgeHTTPCodec.parse(http))
    }

    func testEncryptedHTTPHandshakeProfileButtonAndLivenessEndToEnd() throws {
        let fixture = HTTPFixture(test: self)
        defer { fixture.close() }
        try fixture.handshake()
        XCTAssertTrue(fixture.client.hasApprovedSession)
        let installed = try fixture.send(BridgeWireMessage(
            type: "watchProfileUpdate", inputSource: "appleWatch", profileRevision: fixture.profile.revision,
            watchProfile: try fixture.profile.encodedBase64()
        ))
        XCTAssertTrue(installed.contains { $0.type == "watchProfileReady" })
        var executionCount = 0
        fixture.client.onWatchButtonTrigger = { button, trigger, revision, issuedAt, completion in
            XCTAssertEqual(button, .ok)
            XCTAssertEqual(trigger, .singleClick)
            XCTAssertEqual(revision, fixture.profile.revision)
            XCTAssertGreaterThan(issuedAt, 0)
            executionCount += 1
            completion(true) // No Accessibility, keyboard, audio, or other real action.
        }
        let requestID = UUID().uuidString
        let button = BridgeWireMessage(
            type: "buttonTrigger", command: "ok", inputSource: "appleWatch", profileRevision: fixture.profile.revision,
            requestID: requestID, buttonTrigger: "singleClick",
            issuedAtEpochMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000)
        )
        let first = try fixture.send(button)
        XCTAssertEqual(first.last?.type, "buttonTriggerResult")
        XCTAssertEqual(first.last?.requestID, requestID)
        XCTAssertEqual(first.last?.accepted, true)
        XCTAssertEqual(executionCount, 1)
        XCTAssertEqual(try fixture.send(button).last?.accepted, false)
        XCTAssertEqual(executionCount, 1)
        let probe = UUID().uuidString
        XCTAssertTrue(try fixture.send(BridgeWireMessage(type: "livenessProbe", probeID: probe)).contains {
            $0.type == "livenessAck" && $0.probeID == probe
        })
        let voice = try fixture.send(BridgeWireMessage(type: "voiceStart"))
        XCTAssertEqual(voice.last?.type, "error")
    }

    func testChangedProfileRejectsPreviouslyAcknowledgedButtonRevision() throws {
        let fixture = HTTPFixture(test: self)
        defer { fixture.close() }
        try fixture.handshake()
        _ = try fixture.send(BridgeWireMessage(
            type: "watchProfileUpdate", inputSource: "appleWatch", profileRevision: fixture.profile.revision,
            watchProfile: try fixture.profile.encodedBase64()
        ))
        let replacement = WatchActionProfileWire(revision: 2, bindings: fixture.profile.bindings)
        fixture.queue.sync { fixture.client.updateWatchProfile(replacement) }
        fixture.client.onWatchButtonTrigger = { _, _, _, _, _ in XCTFail("stale profile executed") }
        let result = try fixture.send(BridgeWireMessage(
            type: "buttonTrigger", command: "ok", inputSource: "appleWatch", profileRevision: 1,
            requestID: UUID().uuidString, buttonTrigger: "singleClick",
            issuedAtEpochMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000)
        ))
        XCTAssertEqual(result.last?.accepted, false)
    }

    func testACommitThatExpiresBeforeDeferredExecutionDoesNotRun() throws {
        let fixture = HTTPFixture(test: self)
        defer { fixture.close() }
        try fixture.handshake()
        _ = try fixture.send(BridgeWireMessage(
            type: "watchProfileUpdate", inputSource: "appleWatch", profileRevision: 1,
            watchProfile: try fixture.profile.encodedBase64()
        ))
        var callbackReached = false
        var executionCount = 0
        fixture.client.onWatchButtonTrigger = { _, _, _, issuedAt, completion in
            callbackReached = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) {
                let now = Int64(Date().timeIntervalSince1970 * 1_000)
                let fresh = issuedAt > 0 && issuedAt <= now
                    && now - issuedAt <= WristDirectBridgeProtocol.buttonCommitLifetimeMilliseconds
                if fresh { executionCount += 1 }
                completion(fresh)
            }
        }
        let result = try fixture.send(BridgeWireMessage(
            type: "buttonTrigger", command: "ok", inputSource: "iPhone", profileRevision: 1,
            requestID: UUID().uuidString, buttonTrigger: "singleClick",
            issuedAtEpochMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000) - 4_500
        ))
        XCTAssertTrue(callbackReached)
        XCTAssertEqual(executionCount, 0)
        XCTAssertEqual(result.last?.accepted, false)
    }

    func testForgedSecureInputCannotDrainQueuedState() throws {
        let fixture = HTTPFixture(test: self)
        defer { fixture.close() }
        try fixture.handshake()
        fixture.queue.sync { fixture.client.updateApplicationTitles(["fixture": "Private fixture title"]) }
        XCTAssertThrowsError(try fixture.rawExchange(BridgeWireMessage(
            type: "secure", payload: "invalid-ciphertext", sequence: 1
        ))) { error in XCTAssertEqual(error as? WristDirectBridgeHTTPError, .gone) }
    }

    func testHTTPTransportAllowsOnlyOnePendingAuthenticatedExchange() {
        let queue = DispatchQueue(label: "WristRemote.HTTP.pending-fixture")
        let transport = WristDirectHTTPSessionTransport(queue: queue)
        var firstClosed = false, secondRejected = false
        queue.sync {
            transport.onData = { [weak transport] _ in transport?.didAuthenticateInput(BridgeWireMessage(type: "clientAuth")) }
            transport.exchange(BridgeWireMessage(type: "secure")) { response in
                if case .failure(.gone) = response { firstClosed = true }
            }
            transport.exchange(BridgeWireMessage(type: "secure")) { response in
                if case .failure(.conflict) = response { secondRejected = true }
            }
            transport.cancel()
        }
        XCTAssertTrue(secondRejected)
        XCTAssertTrue(firstClosed)
    }

    private final class HTTPFixture {
        let queue = DispatchQueue(label: "WristRemote.HTTP.fixture")
        let transport: WristDirectHTTPSessionTransport
        let client: WristRemoteServerClient
        let profile: WatchActionProfileWire
        private let test: XCTestCase
        private let serverIdentity = P256.Signing.PrivateKey()
        private let clientIdentity = P256.Signing.PrivateKey()
        private let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        private var key: SymmetricKey?
        private var channel = WristBridgeSecureChannel()

        init(test: XCTestCase) {
            self.test = test
            transport = WristDirectHTTPSessionTransport(queue: queue)
            let bindings = Dictionary(uniqueKeysWithValues: WatchActionProfileWire.buttonIDs.map { button in
                (button, Dictionary(uniqueKeysWithValues: WatchActionProfileWire.triggerIDs.map {
                    ($0, WatchActionBindingWire(action: .returnKey))
                }))
            })
            profile = WatchActionProfileWire(revision: 1, bindings: bindings)
            client = WristRemoteServerClient(
                transport: transport, queue: queue, serverIdentityPrivateKey: serverIdentity,
                handshakeTimeoutSeconds: 2, macName: "Fixture Mac", appVersion: nil,
                applicationTitles: [:], codexTaskSnapshot: nil, codexTaskStateRevision: 0,
                codexConversationCatalog: nil, speechLocaleIdentifier: "zh-CN", internetRelayProvisioning: nil,
                directBridgeConfiguration: nil, currentWatchProfile: profile
            )
            client.isIdentityTrusted = { _ in true }
            client.canApproveIdentity = { _ in true }
            client.onWatchProfileUpdate = { _, completion in completion(.accepted) }
            queue.sync { client.start() }
        }

        func close() { queue.sync { client.cancel() } }

        func handshake() throws {
            let publicKey = ephemeral.publicKey.rawRepresentation
            let response = try exchange(BridgeWireMessage(
                type: "hello", protocolID: BridgeWireMessage.protocolID,
                clientRole: BridgeWireMessage.clientRole, publicKey: publicKey.base64EncodedString(),
                capabilities: [BridgeWireMessage.secureSequenceCapability, BridgeWireMessage.audioDeliveryReceiptsCapability]
            ))
            XCTAssertEqual(response.messages.count, 1)
            let server = try XCTUnwrap(response.messages.first)
            XCTAssertEqual(server.type, "serverKey")
            let serverEphemeral = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(server.publicKey)))
            let identity = serverIdentity.publicKey.rawRepresentation
            let transcript = try XCTUnwrap(BridgeWireMessage.sessionTranscript(
                clientEphemeralPublicKey: publicKey, serverEphemeralPublicKey: serverEphemeral, serverIdentityPublicKey: identity
            ))
            let shared = try ephemeral.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: serverEphemeral))
            key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(BridgeWireMessage.sessionSalt.utf8),
                                               sharedInfo: Data(SHA256.hash(data: transcript)), outputByteCount: 32)
            let proof = try XCTUnwrap(BridgeWireMessage.clientAuthenticationProof(
                clientEphemeralPublicKey: publicKey, serverEphemeralPublicKey: serverEphemeral,
                serverIdentityPublicKey: identity, clientIdentityPublicKey: clientIdentity.publicKey.rawRepresentation
            ))
            let ready = try send(BridgeWireMessage(
                type: "clientAuth", deviceName: "Fixture Watch",
                identityPublicKey: clientIdentity.publicKey.rawRepresentation.base64EncodedString(),
                identitySignature: try clientIdentity.signature(for: proof).rawRepresentation.base64EncodedString(),
                serverIdentityPinned: true
            ))
            XCTAssertEqual(ready.last?.type, "ready")
            XCTAssertEqual(ready.last?.profileRevision, profile.revision)
        }

        func send(_ message: BridgeWireMessage) throws -> [BridgeWireMessage] {
            let key = try XCTUnwrap(key)
            let envelope = try XCTUnwrap(channel.seal(message, using: key, senderRole: BridgeWireMessage.clientRole))
            return try exchange(envelope).messages.map {
                try XCTUnwrap(channel.open($0, using: key, senderRole: BridgeWireMessage.serverRole))
            }
        }

        func rawExchange(_ message: BridgeWireMessage) throws -> WristDirectBridgeHTTPResponse {
            try exchange(message)
        }

        private func exchange(_ message: BridgeWireMessage) throws -> WristDirectBridgeHTTPResponse {
            let completion = test.expectation(description: "encrypted HTTP response")
            var result: Result<WristDirectBridgeHTTPResponse, WristDirectBridgeHTTPError>?
            queue.sync {
                transport.exchange(message) { response in result = response; completion.fulfill() }
            }
            test.wait(for: [completion], timeout: 3)
            return try XCTUnwrap(result).get()
        }
    }
}
