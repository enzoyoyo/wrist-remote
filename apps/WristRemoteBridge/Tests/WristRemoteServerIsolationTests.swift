import CryptoKit
import Foundation
import Network
import XCTest
@testable import WristRemoteBridge

final class WristRemoteServerIsolationTests: XCTestCase {
    func testUsesDedicatedBonjourAndCryptographicDomains() throws {
        XCTAssertEqual(WristRemoteServer.serviceType, "_wristremote._tcp")
        XCTAssertEqual(WristRemoteServer.port, 60_927)
        XCTAssertNotEqual(WristRemoteServer.port, 60_880)
        XCTAssertEqual(WristRemoteServer.sessionSalt, "WristRemoteBridge nearby session")
        XCTAssertEqual(
            WristRemoteIdentityVerifier.identityProofDomain,
            "WristRemoteBridge nearby identity v1"
        )
        let sessionKey = Data("session-public-key".utf8)
        let proof = WristRemoteIdentityVerifier.proof(for: sessionKey)
        XCTAssertEqual(
            proof,
            Data("WristRemoteBridge nearby identity v1\0".utf8) + sessionKey
        )
        XCTAssertFalse(String(decoding: proof, as: UTF8.self).hasPrefix("Unrelated nearby"))
    }

    func testHandshakeRequiresExactProtocolAndClientRole() {
        let valid = BridgeWireMessage(
            type: "hello",
            protocolID: WristRemoteHandshake.protocolID,
            clientRole: WristRemoteHandshake.clientRole
        )
        XCTAssertTrue(WristRemoteHandshake.acceptsClient(valid))

        XCTAssertFalse(WristRemoteHandshake.acceptsClient(BridgeWireMessage(
            type: "hello",
            protocolID: "org.example.unrelated.protocol",
            clientRole: WristRemoteHandshake.clientRole
        )))
        XCTAssertFalse(WristRemoteHandshake.acceptsClient(BridgeWireMessage(
            type: "hello",
            protocolID: WristRemoteHandshake.protocolID,
            clientRole: "nearbyPhone"
        )))
        XCTAssertFalse(WristRemoteHandshake.acceptsClient(BridgeWireMessage(
            type: "hello",
            protocolID: WristRemoteHandshake.protocolID,
            clientRole: WristRemoteHandshake.clientRole,
            serverRole: WristRemoteHandshake.serverRole
        )))
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

    func testLANPeerGateAllowsOnlySamePhysicalIPv6SubnetForGlobalAddresses() throws {
        let localAddress = try XCTUnwrap(IPv6Address("2001:db8:1:2::1"))
        let locals = [localAddress.rawValue]
        XCTAssertTrue(WristRemotePeerAccessPolicy.permits(
            endpoint("2001:db8:1:2::2"),
            localPhysicalIPv6Addresses: locals
        ))
        XCTAssertFalse(WristRemotePeerAccessPolicy.permits(
            endpoint("2001:db8:1:3::2"),
            localPhysicalIPv6Addresses: locals
        ))
    }

    func testLANPeerGateRejectsPublicIPv4HostnamesAndUnresolvedEndpoints() {
        for rawHost in ["198.51.100.7", "100.64.0.1", "203.0.113.8", "iphone.local"] {
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

    func testIdentitySignatureMustUseBridgeDomain() throws {
        let identity = P256.Signing.PrivateKey()
        let sessionKey = Data("ephemeral".utf8)
        let signature = try identity.signature(
            for: WristRemoteIdentityVerifier.proof(for: sessionKey)
        )
        XCTAssertEqual(
            WristRemoteIdentityVerifier.verify(
                identityPublicKey: identity.publicKey.rawRepresentation.base64EncodedString(),
                identitySignature: signature.rawRepresentation.base64EncodedString(),
                sessionPublicKey: sessionKey
            ),
            .verified(SHA256.hash(data: identity.publicKey.rawRepresentation)
                .map { String(format: "%02x", $0) }
                .joined())
        )
    }

    func testCodexTargetRejectsSameThreadWithDifferentTurnOrRevision() throws {
        let snapshot = WatchCodexTaskSnapshot(
            threadID: "thr_exact",
            turnID: "turn_current",
            cwd: "/tmp",
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
                cwd: snapshot.cwd,
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
