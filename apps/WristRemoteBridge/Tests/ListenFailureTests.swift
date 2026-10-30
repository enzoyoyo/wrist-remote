import Network
import XCTest
@testable import WristRemoteBridge

final class ListenFailureTests: XCTestCase {
    func testAddressInUseNamesThePortAndPromisesARetry() {
        let message = ListenFailure.describe(NWError.posix(.EADDRINUSE), port: 60_927)
        XCTAssertTrue(message.contains("60927"), message)
        XCTAssertTrue(message.contains("已被占用"), message)
        XCTAssertTrue(message.contains("重试"), message)
        XCTAssertFalse(message.contains("NWError"), "The raw Network error is not a user-facing message")
    }

    func testAddressInUseForTheWatchDirectPortIsDistinguished() {
        let lan = ListenFailure.describe(NWError.posix(.EADDRINUSE), port: 60_927)
        let watch = ListenFailure.describe(NWError.posix(.EADDRINUSE), port: 60_929)
        XCTAssertNotEqual(lan, watch)
        XCTAssertTrue(watch.contains("60929"), watch)
    }

    func testOtherErrorsKeepTheirOwnDescription() {
        let error = NWError.posix(.EPERM)
        XCTAssertEqual(ListenFailure.describe(error, port: 60_927), error.localizedDescription)
    }

    func testNonNetworkErrorsKeepTheirOwnDescription() {
        struct Boom: LocalizedError {
            var errorDescription: String? { "boom" }
        }
        XCTAssertEqual(ListenFailure.describe(Boom(), port: 60_927), "boom")
    }
}
