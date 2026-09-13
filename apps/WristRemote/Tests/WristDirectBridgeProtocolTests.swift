import CryptoKit
import Foundation
import XCTest
@testable import WristRemote

final class WristDirectBridgeProtocolTests: XCTestCase {
    private func configuration(_ endpoint: String) -> WristDirectBridgeConfiguration {
        WristDirectBridgeConfiguration(
            endpoint: endpoint,
            serverIdentityPublicKey: P256.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString(),
            serverName: "Fixture Mac"
        )
    }

    func testConfigurationRoundTripsPublicPairingMaterial() throws {
        let value = configuration("http://192.168.1.20:60929/v1/bridge")
        XCTAssertEqual(try WristDirectBridgeConfiguration.decodeBase64(value.encodeBase64()), value)
        XCTAssertEqual(WristDirectBridgeConfiguration.fromPairingURL(try XCTUnwrap(value.pairingURL)), value)
        XCTAssertNotNil(configuration("http://[fd12:3456::1]:60929/v1/bridge").validated())
    }

    func testConfigurationCannotBroadenThePrivateNetworkOrCarryCredentials() {
        for endpoint in [
            "http://203.0.113.9:60929/v1/bridge", "http://127.0.0.1:60929/v1/bridge",
            "http://100.64.1.2:60929/v1/bridge", "http://mac.local:60929/v1/bridge",
            "http://192.168.1.2:80/v1/bridge", "http://192.168.1.2:60929/other",
            "http://user:password@192.168.1.2:60929/v1/bridge",
            "http://192.168.1.2:60929/v1/bridge?token=example",
            "http://192.168.1.2:60929/v1/bridge#fragment",
            "http://[2001:db8::1]:60929/v1/bridge", "http://[::ffff:192.168.1.2]:60929/v1/bridge",
        ] { XCTAssertNil(configuration(endpoint).validated(), endpoint) }
    }

    func testInvalidPublicKeyCannotBePinned() {
        let value = WristDirectBridgeConfiguration(
            endpoint: "http://192.168.1.2:60929/v1/bridge",
            serverIdentityPublicKey: Data(repeating: 0, count: 64).base64EncodedString(), serverName: "Mac"
        )
        XCTAssertNil(value.validated())
        XCTAssertThrowsError(try value.encodeBase64())
    }

    func testFreshSemanticButtonsRequireExactIDTriggerAndShortLifetime() {
        var button = WristBridgeWireMessage(
            type: "buttonTrigger", requestID: UUID().uuidString,
            buttonTrigger: "singleClick", issuedAtEpochMilliseconds: 10_000
        )
        XCTAssertTrue(WristDirectBridgeProtocol.isFreshButtonCommit(button, nowEpochMilliseconds: 15_000))
        XCTAssertFalse(WristDirectBridgeProtocol.isFreshButtonCommit(button, nowEpochMilliseconds: 15_001))
        XCTAssertFalse(WristDirectBridgeProtocol.isFreshButtonCommit(button, nowEpochMilliseconds: 9_999))
        button.buttonTrigger = "press"
        XCTAssertFalse(WristDirectBridgeProtocol.isFreshButtonCommit(button, nowEpochMilliseconds: 10_000))
        button.buttonTrigger = "singleClick"
        button.requestID = "not-a-uuid"
        XCTAssertFalse(WristDirectBridgeProtocol.isFreshButtonCommit(button, nowEpochMilliseconds: 10_000))
    }
}
