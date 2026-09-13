#if os(iOS)
import CryptoKit
import XCTest
@testable import WristRemote

final class WristPairingLinkTests: XCTestCase {
    private func link(
        host: String = "192.168.2.15",
        port: String = "60927",
        version: String = "1",
        key: String? = nil
    ) -> URL {
        var url = URLComponents()
        url.scheme = "wristremote"
        url.host = "pair"
        url.queryItems = [
            URLQueryItem(name: "version", value: version),
            URLQueryItem(name: "host", value: host),
            URLQueryItem(name: "port", value: port),
            URLQueryItem(name: "identity", value: key
                ?? P256.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()),
            URLQueryItem(name: "name", value: "Enzo 的 Mac"),
        ]
        return url.url!
    }

    func testMacQRRoundTripsPublicIdentityAndPrivateHost() throws {
        let key = P256.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        let parsed = try WristPairingLink.parse(link(key: key))
        XCTAssertEqual(parsed.host, "192.168.2.15")
        XCTAssertEqual(parsed.serverName, "Enzo 的 Mac")
        XCTAssertEqual(parsed.serverIdentityPublicKey, key)
        XCTAssertEqual(parsed.identityFingerprint.count, 64)
        XCTAssertTrue(parsed.matchesIdentity(parsed.identityFingerprint))
        XCTAssertFalse(parsed.matchesIdentity(String(repeating: "0", count: 64)))
    }

    func testOnlyPrivateLiteralAddressesAreAccepted() throws {
        for host in ["10.1.0.1", "172.16.2.1", "192.168.1.1", "169.254.2.1",
                     "100.64.0.1", "100.127.255.254", "fd7a:115c:a1e0::1"] {
            XCTAssertNoThrow(try WristPairingLink.parse(link(host: host)), host)
        }
        for host in ["203.0.113.9", "127.0.0.1", "0.0.0.0", "255.255.255.255",
                     "mac.local", "example.com",
                     "https://example.invalid", "192.168.1.1:60927", "::1",
                     "fe80::1%en0", "2001:db8::1", " 10.0.0.1", "100.64.0.1."] {
            XCTAssertThrowsError(try WristPairingLink.parse(link(host: host)), host)
        }
    }

    func testWrongVersionPortAndInvalidPublicKeyAreRejected() {
        XCTAssertThrowsError(try WristPairingLink.parse(link(port: "80")))
        XCTAssertThrowsError(try WristPairingLink.parse(link(port: "60929")))
        XCTAssertThrowsError(try WristPairingLink.parse(link(version: "2")))
        XCTAssertThrowsError(try WristPairingLink.parse(link(key: "secret")))
        XCTAssertThrowsError(try WristPairingLink.parse(link(key: Data(repeating: 0, count: 64)
            .base64EncodedString())))
    }

    func testAmbiguousAndExpandedLinkShapesAreRejected() {
        let original = link()
        var url = URLComponents(url: original, resolvingAgainstBaseURL: false)!
        url.queryItems?.append(URLQueryItem(name: "host", value: "10.0.0.2"))
        XCTAssertThrowsError(try WristPairingLink.parse(url.url!))
        url = URLComponents(url: original, resolvingAgainstBaseURL: false)!
        url.queryItems?.append(URLQueryItem(name: "secret", value: "not-allowed"))
        XCTAssertThrowsError(try WristPairingLink.parse(url.url!))
        url = URLComponents(url: original, resolvingAgainstBaseURL: false)!
        url.path = "/unexpected"
        XCTAssertThrowsError(try WristPairingLink.parse(url.url!))
        url = URLComponents(url: original, resolvingAgainstBaseURL: false)!
        url.fragment = "redirect"
        XCTAssertThrowsError(try WristPairingLink.parse(url.url!))
        url = URLComponents(url: original, resolvingAgainstBaseURL: false)!
        url.user = "user"
        XCTAssertThrowsError(try WristPairingLink.parse(url.url!))
        url = URLComponents(url: original, resolvingAgainstBaseURL: false)!
        url.scheme = "https"
        XCTAssertThrowsError(try WristPairingLink.parse(url.url!))
        XCTAssertThrowsError(try WristPairingLink.parse(
            URL(string: "wristremote://pair?configuration=not-authorized")!
        ))
    }

    func testStoredAddressKeepsOnlyPublicPairingMaterial() throws {
        let suite = "WristPairingLinkTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let target = try WristPairingLink.parse(link())
        target.save(defaults: defaults)
        XCTAssertEqual(WristPairingLink.load(defaults: defaults), target)
        WristPairingLink.clear(defaults: defaults)
        XCTAssertNil(WristPairingLink.load(defaults: defaults))
    }

    func testStaleQRAddressCannotPermanentlySuppressBonjourDiscovery() throws {
        let target = try WristPairingLink.parse(link())
        var policy = WristPairingRoutePolicy()
        XCTAssertTrue(policy.takeAddressAttempt())
        // Connection failures and watchdogs do not reset the address hint.
        XCTAssertFalse(policy.takeAddressAttempt())
        XCTAssertFalse(policy.takeAddressAttempt())
        XCTAssertTrue(target.matchesIdentity(target.identityFingerprint))
        XCTAssertFalse(target.matchesIdentity(String(repeating: "0", count: 64)))
        policy.resetForImportedLink()
        XCTAssertTrue(policy.takeAddressAttempt())
        XCTAssertFalse(policy.takeAddressAttempt())
    }
}

final class WristPhoneButtonReceiptTests: XCTestCase {
    private let now: Int64 = 1_000_000

    private func message(id: UUID, accepted: Bool?) -> WristBridgeWireMessage {
        var message = WristBridgeWireMessage(type: "buttonTriggerResult")
        message.requestID = id.uuidString
        message.accepted = accepted
        return message
    }

    func testOnlyMatchingSuccessReceiptMeansExecuted() {
        var ledger = WristPhoneButtonReceiptLedger()
        let id = UUID()
        XCTAssertTrue(ledger.begin(id: id, nowEpochMilliseconds: now))
        XCTAssertNil(ledger.resolve(message(id: UUID(), accepted: true),
                                    nowEpochMilliseconds: now + 1))
        XCTAssertNil(ledger.resolve(message(id: id, accepted: nil),
                                    nowEpochMilliseconds: now + 2))
        let receipt = ledger.resolve(message(id: id, accepted: true),
                                     nowEpochMilliseconds: now + 3)
        XCTAssertEqual(receipt?.outcome, .executed)
        XCTAssertEqual(receipt?.requestID, id)
        XCTAssertTrue(receipt?.accepted == true)
        XCTAssertNil(ledger.resolve(message(id: id, accepted: true),
                                    nowEpochMilliseconds: now + 4))
    }

    func testRejectionIsFinalAndDoesNotImplyExecution() {
        var ledger = WristPhoneButtonReceiptLedger()
        let id = UUID()
        XCTAssertTrue(ledger.begin(id: id, nowEpochMilliseconds: now))
        var reply = message(id: id, accepted: false)
        reply.detail = "Mac 辅助功能权限未授权"
        let receipt = ledger.resolve(reply, nowEpochMilliseconds: now + 50)
        XCTAssertEqual(receipt?.outcome, .rejected)
        XCTAssertEqual(receipt?.detail, reply.detail)
        XCTAssertFalse(receipt?.accepted ?? true)
        XCTAssertNil(ledger.resolve(message(id: id, accepted: true),
                                    nowEpochMilliseconds: now + 100))
    }

    func testTimeoutAndLateSuccessRemainUnconfirmedWithoutRetry() {
        var ledger = WristPhoneButtonReceiptLedger()
        let id = UUID()
        XCTAssertTrue(ledger.begin(id: id, nowEpochMilliseconds: now))
        XCTAssertNil(ledger.expire(id: id, nowEpochMilliseconds: now + 4_999))
        XCTAssertEqual(ledger.expire(id: id, nowEpochMilliseconds: now + 5_000)?.outcome,
                       .unconfirmed)
        XCTAssertNil(ledger.resolve(message(id: id, accepted: true),
                                    nowEpochMilliseconds: now + 5_001))
        XCTAssertTrue(ledger.pendingIDs.isEmpty)
    }

    func testLateReceiptCannotBeatTimeoutTaskScheduling() {
        var ledger = WristPhoneButtonReceiptLedger()
        let id = UUID()
        XCTAssertTrue(ledger.begin(id: id, nowEpochMilliseconds: now))
        XCTAssertEqual(ledger.resolve(message(id: id, accepted: true),
                                      nowEpochMilliseconds: now + 5_000)?.outcome,
                       .unconfirmed)
    }

    func testDisconnectSettlesEveryRequestOnceWithoutClaimingFailureToExecute() {
        var ledger = WristPhoneButtonReceiptLedger()
        let first = UUID(), second = UUID()
        XCTAssertTrue(ledger.begin(id: first, nowEpochMilliseconds: now))
        XCTAssertFalse(ledger.begin(id: first, nowEpochMilliseconds: now))
        XCTAssertTrue(ledger.begin(id: second, nowEpochMilliseconds: now + 1))
        let receipts = ledger.disconnect()
        XCTAssertEqual(Set(receipts.map(\.requestID)), [first, second])
        XCTAssertTrue(receipts.allSatisfy { $0.outcome == .unconfirmed })
        XCTAssertTrue(ledger.disconnect().isEmpty)
    }

    func testWrongTypeAndNoncanonicalUUIDCannotConsumeReceipt() {
        var ledger = WristPhoneButtonReceiptLedger()
        let id = UUID()
        XCTAssertTrue(ledger.begin(id: id, nowEpochMilliseconds: now))
        var wrongCase = message(id: id, accepted: true)
        wrongCase.requestID = id.uuidString.lowercased()
        XCTAssertNil(ledger.resolve(wrongCase, nowEpochMilliseconds: now + 1))
        let wrongType = WristBridgeWireMessage(type: "ready", requestID: id.uuidString,
                                               accepted: true)
        XCTAssertNil(ledger.resolve(wrongType, nowEpochMilliseconds: now + 2))
        XCTAssertEqual(ledger.pendingIDs, [id])
    }

    func testOutOfOrderRepliesDoNotConfirmTheWrongCommand() {
        var ledger = WristPhoneButtonReceiptLedger()
        let first = UUID(), second = UUID()
        XCTAssertTrue(ledger.begin(id: first, nowEpochMilliseconds: now))
        XCTAssertTrue(ledger.begin(id: second, nowEpochMilliseconds: now + 1))
        XCTAssertEqual(ledger.resolve(message(id: second, accepted: true),
                                      nowEpochMilliseconds: now + 2)?.requestID, second)
        XCTAssertEqual(ledger.resolve(message(id: first, accepted: false),
                                      nowEpochMilliseconds: now + 3)?.requestID, first)
    }
}
#endif
