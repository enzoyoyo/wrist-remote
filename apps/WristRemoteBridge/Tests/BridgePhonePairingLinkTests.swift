import CryptoKit
import XCTest
@testable import WristRemoteBridge

final class BridgePhonePairingLinkTests: XCTestCase {
    func testPairingLinkContainsOnlyPublicMacCoordinates() throws {
        let key = P256.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        let configuration = WristDirectBridgeConfiguration(
            endpoint: "http://192.168.1.42:60929/v1/bridge",
            serverIdentityPublicKey: key,
            serverName: "Enzo 的 Mac & 桥"
        )
        let link = try XCTUnwrap(BridgePhonePairingLink.make(configuration: configuration))
        let components = try XCTUnwrap(URLComponents(url: link, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme, "wristremote")
        XCTAssertEqual(components.host, "pair")
        let items = try XCTUnwrap(components.queryItems)
        XCTAssertEqual(items.count, 5)
        let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value) })
        XCTAssertEqual(values["host"], "192.168.1.42")
        XCTAssertEqual(values["port"], "60927")
        XCTAssertEqual(values["identity"], key)
        XCTAssertEqual(values["name"], configuration.serverName)
        XCTAssertEqual(values["version"], "1")
        XCTAssertNotNil(BridgePhonePairingLink.qrImage(for: link))
    }

    func testUnavailableOrPublicEndpointHasNoPairingLink() {
        XCTAssertNil(BridgePhonePairingLink.make(configuration: nil))
        let configuration = WristDirectBridgeConfiguration(
            endpoint: "http://192.0.2.42:60929/v1/bridge",
            serverIdentityPublicKey: P256.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString(),
            serverName: "Mac"
        )
        XCTAssertNil(BridgePhonePairingLink.make(configuration: configuration))
    }
}
