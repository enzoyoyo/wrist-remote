import CryptoKit
import Foundation
import XCTest
@testable import WristRemote

@MainActor
final class WristDirectBridgeClientTests: XCTestCase {
    func testHandshakePinsMacAndRequiresExactProfileAcknowledgement() async throws {
        let server = DirectBridgeTestServer()
        let client = server.makeClient()
        client.configure(server.configuration)
        client.setSceneActive(true)
        defer { client.setSceneActive(false) }
        await waitUntil { client.isReady }
        XCTAssertTrue(client.isReady)
        XCTAssertEqual(client.snapshot?.revision, 7)
        XCTAssertEqual(server.messageTypes, ["hello", "clientAuth", "watchProfileUpdate"])
        XCTAssertEqual(server.authenticationTimeout, 40)
        XCTAssertEqual(client.snapshot?.triggers(for: .home), [.singleClick, .doubleClick, .longPress])
    }

    func testMissingProfileAckNeverEnablesButtons() async throws {
        let server = DirectBridgeTestServer()
        server.wrongProfileAcknowledgement = true
        let client = server.makeClient()
        client.configure(server.configuration)
        client.setSceneActive(true)
        defer { client.setSceneActive(false) }
        await waitUntil { server.messageTypes.contains("watchProfileUpdate") }
        await Task.yield()
        XCTAssertFalse(client.isReady)
        XCTAssertNil(client.snapshot)
    }

    func testChangedMacPinIsRejectedBeforeClientAuthentication() async throws {
        let server = DirectBridgeTestServer()
        let wrongIdentity = P256.Signing.PrivateKey()
        let client = server.makeClient()
        client.configure(.init(endpoint: server.configuration.endpoint,
                               serverIdentityPublicKey: wrongIdentity.publicKey.rawRepresentation.base64EncodedString(),
                               serverName: "Mac"))
        client.setSceneActive(true)
        defer { client.setSceneActive(false) }
        await waitUntil { if case .failed = client.state { return true }; return false }
        XCTAssertEqual(server.messageTypes, ["hello"])
        XCTAssertFalse(client.isReady)
    }

    func testAllTwelveCommandsReturnMatchingMacReceipt() async throws {
        let server = DirectBridgeTestServer()
        let client = server.makeClient()
        client.configure(server.configuration)
        client.setSceneActive(true)
        defer { client.setSceneActive(false) }
        await waitUntil { client.isReady }
        for command in WatchRemoteCommand.allCases {
            let receipt = try await client.sendButton(
                command: command, trigger: .singleClick, profileRevision: 7,
                issuedAtEpochMilliseconds: Self.now
            )
            XCTAssertEqual(receipt.accepted, true)
            XCTAssertEqual(server.lastButton?.command, command.wireButtonID)
            XCTAssertEqual(server.lastButton?.inputSource, "appleWatch")
        }
        XCTAssertEqual(server.buttonCount, 12)
    }

    func testExpiredButtonNeverReachesHTTP() async throws {
        let server = DirectBridgeTestServer()
        let client = server.makeClient()
        client.configure(server.configuration)
        client.setSceneActive(true)
        defer { client.setSceneActive(false) }
        await waitUntil { client.isReady }
        do {
            _ = try await client.sendButton(command: .home, trigger: .singleClick,
                                            profileRevision: 7, issuedAtEpochMilliseconds: Self.now - 6_000)
            XCTFail("An expired button must fail before HTTP")
        } catch { XCTAssertEqual(error as? WristDirectBridgeClientError, .expired) }
        XCTAssertEqual(server.buttonCount, 0)
    }

    func testLostButtonReceiptIsNeverReplayed() async throws {
        let server = DirectBridgeTestServer()
        let client = server.makeClient()
        client.configure(server.configuration)
        client.setSceneActive(true)
        defer { client.setSceneActive(false) }
        await waitUntil { client.isReady }
        server.loseButtonReceipt = true
        do {
            _ = try await client.sendButton(command: .home, trigger: .singleClick,
                                            profileRevision: 7, issuedAtEpochMilliseconds: Self.now)
            XCTFail("A lost acknowledgement must not report success")
        } catch {}
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(server.buttonCount, 1)
    }

    func testWrongReceiptIdentifierIsNotAccepted() async throws {
        let server = DirectBridgeTestServer()
        let client = server.makeClient()
        client.configure(server.configuration)
        client.setSceneActive(true)
        defer { client.setSceneActive(false) }
        await waitUntil { client.isReady }
        server.wrongButtonRequestID = true
        do {
            _ = try await client.sendButton(command: .home, trigger: .singleClick,
                                            profileRevision: 7, issuedAtEpochMilliseconds: Self.now)
            XCTFail("An unrelated receipt is not acceptance")
        } catch { XCTAssertEqual(error as? WristDirectBridgeClientError, .operationUnconfirmed) }
    }

    func testBackgroundAndMissingIdentityNeverStartHTTP() async throws {
        let server = DirectBridgeTestServer()
        let client = WristDirectBridgeClient(identityProvider: { nil }, exchange: server.exchange)
        client.configure(server.configuration)
        await Task.yield()
        XCTAssertTrue(server.messageTypes.isEmpty)
        client.setSceneActive(true)
        defer { client.setSceneActive(false) }
        await waitUntil { if case .failed = client.state { return true }; return false }
        XCTAssertTrue(server.messageTypes.isEmpty)
        XCTAssertFalse(client.isReady)
    }

    func testRedirectResponseCannotChangePrivateEndpoint() async throws {
        let server = DirectBridgeTestServer()
        server.redirectResponse = true
        let client = server.makeClient()
        client.configure(server.configuration)
        client.setSceneActive(true)
        defer { client.setSceneActive(false) }
        await waitUntil { if case .failed = client.state { return true }; return false }
        XCTAssertEqual(server.messageTypes, ["hello"])
        XCTAssertFalse(client.isReady)
    }

    func testProfilePushDisablesOldRevisionAndInstallsNewRevisionInSameSession() async throws {
        let server = DirectBridgeTestServer()
        let client = server.makeClient(pollInterval: 0.01)
        client.configure(server.configuration)
        client.setSceneActive(true)
        defer { client.setSceneActive(false) }
        await waitUntil { client.isReady }
        var observedUnavailable = false
        client.onChange = { if client.snapshot == nil { observedUnavailable = true } }
        server.pushNewProfile = true
        await waitUntil { client.snapshot?.revision == 8 }
        XCTAssertTrue(observedUnavailable)
        XCTAssertTrue(client.isReady)
        XCTAssertEqual(client.snapshot?.revision, 8)
        XCTAssertEqual(server.messageTypes.filter { $0 == "hello" }.count, 1)
        XCTAssertEqual(server.messageTypes.filter { $0 == "watchProfileUpdate" }.count, 2)
    }

    func testApprovalTimeoutDoesNotAutomaticallyCreateAnotherApproval() async throws {
        let server = DirectBridgeTestServer()
        server.timeoutApproval = true
        let client = server.makeClient()
        client.configure(server.configuration)
        client.setSceneActive(true)
        defer { client.setSceneActive(false) }
        await waitUntil { if case .failed = client.state { return true }; return false }
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(server.messageTypes, ["hello", "clientAuth"])
        server.timeoutApproval = false
        client.reconnect()
        await waitUntil { client.isReady }
        XCTAssertTrue(client.isReady, "A completed prior loop must not block explicit reconnect")
    }

    func testAuthenticatedFreshInstallWaitsForProfileWithoutAnotherApproval() async throws {
        let server = DirectBridgeTestServer()
        server.hasProfile = false
        let client = server.makeClient(pollInterval: 0.01)
        client.configure(server.configuration)
        client.setSceneActive(true)
        defer { client.setSceneActive(false) }
        await waitUntil { client.state == .waitingForProfile }
        XCTAssertFalse(client.isReady)
        await waitUntil { server.messageTypes.contains("livenessProbe") }
        XCTAssertEqual(server.messageTypes.filter { $0 == "clientAuth" }.count, 1)
        XCTAssertFalse(server.messageTypes.contains("watchProfileUpdate"))
        server.hasProfile = true
        server.pushNewProfile = true
        await waitUntil { client.snapshot?.revision == 8 }
        XCTAssertTrue(client.isReady)
        XCTAssertEqual(server.messageTypes.filter { $0 == "hello" }.count, 1)
        XCTAssertEqual(server.messageTypes.filter { $0 == "clientAuth" }.count, 1)
    }

    func testBackgroundCancelsQueuedButtonsWithoutRevivingThem() async throws {
        let server = DirectBridgeTestServer()
        let client = server.makeClient()
        client.configure(server.configuration)
        client.setSceneActive(true)
        await waitUntil { client.isReady }
        server.holdButtonReceipt = true
        let first = Task { try await client.sendButton(command: .home, trigger: .singleClick,
            profileRevision: 7, issuedAtEpochMilliseconds: Self.now) }
        await waitUntil { server.heldButtonReceipt != nil }
        let second = Task { try await client.sendButton(command: .up, trigger: .singleClick,
            profileRevision: 7, issuedAtEpochMilliseconds: Self.now) }
        await Task.yield()
        client.setSceneActive(false)
        server.heldButtonReceipt?.resume()
        server.heldButtonReceipt = nil
        _ = try? await first.value
        _ = try? await second.value
        XCTAssertEqual(server.buttonCount, 1)
        XCTAssertEqual(client.state, .suspended)
        XCTAssertNil(client.snapshot)
        server.holdButtonReceipt = false
        client.setSceneActive(true)
        defer { client.setSceneActive(false) }
        await waitUntil { client.isReady }
        XCTAssertTrue(client.isReady)
        XCTAssertEqual(server.buttonCount, 1, "Foreground recovery must not replay either old gesture")
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<100 where !condition() {
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    private static var now: Int64 { Int64(Date().timeIntervalSince1970 * 1_000) }
}

@MainActor
private final class DirectBridgeTestServer {
    let identity = P256.Signing.PrivateKey()
    let clientIdentity = P256.Signing.PrivateKey()
    let id = UUID().uuidString
    var key: SymmetricKey?
    var channel = WristBridgeSecureChannel()
    var messageTypes: [String] = []
    var authenticationTimeout: TimeInterval?
    var wrongProfileAcknowledgement = false
    var loseButtonReceipt = false
    var wrongButtonRequestID = false
    var redirectResponse = false
    var buttonCount = 0
    var lastButton: WristBridgeWireMessage?
    var clientEphemeralPublicKey: Data?
    var serverEphemeralPublicKey: Data?
    var profileRevision = 7
    var pushNewProfile = false
    var timeoutApproval = false
    var holdButtonReceipt = false
    var heldButtonReceipt: CheckedContinuation<Void, Never>?
    var hasProfile = true

    var configuration: WristDirectBridgeConfiguration {
        .init(endpoint: "http://192.168.1.9:60929/v1/bridge",
              serverIdentityPublicKey: identity.publicKey.rawRepresentation.base64EncodedString(),
              serverName: "Test Mac")
    }

    var profile: WatchActionProfileWire {
        .init(revision: profileRevision, bindings: Dictionary(uniqueKeysWithValues: WatchActionProfileWire.buttonIDs.map { button in
            (button, Dictionary(uniqueKeysWithValues: WatchActionProfileWire.triggerIDs.map {
                ($0, WatchActionBindingWire(action: .returnKey))
            }))
        }))
    }

    func makeClient(pollInterval: TimeInterval = 3) -> WristDirectBridgeClient {
        WristDirectBridgeClient(identityProvider: { self.clientIdentity }, exchange: exchange,
                                pollInterval: pollInterval)
    }

    func exchange(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let body = try JSONDecoder().decode(WristDirectBridgeHTTPRequest.self, from: XCTUnwrap(request.httpBody))
        var replies: [WristBridgeWireMessage] = []
        if body.message.type == "hello" {
            messageTypes.append("hello")
            channel.reset()
            let clientPublic = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(body.message.publicKey)))
            let ephemeral = Curve25519.KeyAgreement.PrivateKey()
            let serverPublic = ephemeral.publicKey.rawRepresentation
            clientEphemeralPublicKey = clientPublic
            serverEphemeralPublicKey = serverPublic
            let proof = try XCTUnwrap(WristBridgeWireMessage.serverIdentityProof(
                clientEphemeralPublicKey: clientPublic, serverEphemeralPublicKey: serverPublic))
            let transcript = try XCTUnwrap(WristBridgeWireMessage.sessionTranscript(
                clientEphemeralPublicKey: clientPublic, serverEphemeralPublicKey: serverPublic,
                serverIdentityPublicKey: identity.publicKey.rawRepresentation))
            let secret = try ephemeral.sharedSecretFromKeyAgreement(with: .init(rawRepresentation: clientPublic))
            key = secret.hkdfDerivedSymmetricKey(using: SHA256.self,
                salt: Data(WristBridgeWireMessage.sessionSalt.utf8),
                sharedInfo: Data(SHA256.hash(data: transcript)), outputByteCount: 32)
            var server = WristBridgeWireMessage(type: "serverKey")
            server.protocolID = WristBridgeWireMessage.protocolID
            server.serverRole = WristBridgeWireMessage.serverRole
            server.publicKey = serverPublic.base64EncodedString()
            server.serverIdentityVersion = WristBridgeWireMessage.serverIdentityVersion
            server.serverIdentityPublicKey = configuration.serverIdentityPublicKey
            server.serverIdentitySignature = try identity.signature(for: proof).rawRepresentation.base64EncodedString()
            replies = [server]
        } else {
            let key = try XCTUnwrap(key)
            let message = try XCTUnwrap(channel.open(body.message, using: key, senderRole: WristBridgeWireMessage.clientRole))
            messageTypes.append(message.type)
            var response: WristBridgeWireMessage
            var preceding: [WristBridgeWireMessage] = []
            switch message.type {
            case "clientAuth":
                authenticationTimeout = request.timeoutInterval
                if timeoutApproval { throw URLError(.timedOut) }
                XCTAssertEqual(message.serverIdentityPinned, true)
                let clientIdentityData = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(message.identityPublicKey)))
                let proof = try XCTUnwrap(WristBridgeWireMessage.clientAuthenticationProof(
                    clientEphemeralPublicKey: XCTUnwrap(clientEphemeralPublicKey),
                    serverEphemeralPublicKey: XCTUnwrap(serverEphemeralPublicKey),
                    serverIdentityPublicKey: identity.publicKey.rawRepresentation,
                    clientIdentityPublicKey: clientIdentityData))
                let signatureData = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(message.identitySignature)))
                XCTAssertTrue(try P256.Signing.PublicKey(rawRepresentation: clientIdentityData).isValidSignature(
                    P256.Signing.ECDSASignature(rawRepresentation: signatureData), for: proof))
                response = WristBridgeWireMessage(type: "ready")
                response.protocolID = WristBridgeWireMessage.protocolID
                response.serverRole = WristBridgeWireMessage.serverRole
                response.deviceName = "Test Mac"
                if hasProfile {
                    response.watchProfile = try profile.encodedBase64()
                    response.profileRevision = profile.revision
                }
                response.capabilities = [WristDirectBridgeProtocol.capability,
                    WristDirectBridgeProtocol.buttonTriggerCapability,
                    WristBridgeWireMessage.watchActionProfileCapability,
                    WristBridgeWireMessage.secureSequenceCapability]
            case "watchProfileUpdate":
                XCTAssertEqual(try WatchActionProfileWire.decodeBase64(XCTUnwrap(message.watchProfile)), profile)
                response = WristBridgeWireMessage(type: "watchProfileReady")
                response.profileRevision = wrongProfileAcknowledgement ? profileRevision + 1 : profileRevision
            case "buttonTrigger":
                buttonCount += 1
                lastButton = message
                if loseButtonReceipt { throw URLError(.networkConnectionLost) }
                if holdButtonReceipt {
                    await withCheckedContinuation { heldButtonReceipt = $0 }
                }
                response = WristBridgeWireMessage(type: "buttonTriggerResult")
                response.requestID = wrongButtonRequestID ? UUID().uuidString : message.requestID
                response.accepted = true
            case "livenessProbe":
                if pushNewProfile {
                    pushNewProfile = false
                    profileRevision = 8
                    preceding.append(WristBridgeWireMessage(type: "watchProfileRejected", profileRevision: 7))
                    preceding.append(WristBridgeWireMessage(type: "watchProfileSnapshot",
                        profileRevision: 8, watchProfile: try profile.encodedBase64()))
                }
                response = WristBridgeWireMessage(type: "livenessAck", probeID: message.probeID)
            default:
                throw WristDirectBridgeClientError.invalidResponse
            }
            replies = try (preceding + [response]).map {
                try XCTUnwrap(channel.seal($0, using: key, senderRole: WristBridgeWireMessage.serverRole))
            }
        }
        let data = try JSONEncoder().encode(WristDirectBridgeHTTPResponse(sessionID: id, messages: replies))
        let url = redirectResponse ? URL(string: "https://example.com")! : request.url!
        return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
}
