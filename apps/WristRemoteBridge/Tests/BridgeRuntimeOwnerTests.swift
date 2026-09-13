import Foundation
import XCTest
@testable import WristRemoteBridge

final class BridgeRuntimeOwnerTests: XCTestCase {
    private final class RuntimeProbe { }

    func testAllTestHostSignalsSkipRuntimeConstruction() async {
        await MainActor.run {
            let cases: [([String: String], String?, Bool)] = [
                (["XCTestConfigurationFilePath": "/test-only"], nil, false),
                (["XCTestBundlePath": "/test-only"], nil, false),
                ([:], "org.example.wristremote.bridge.testsession", false),
                ([:], nil, true)
            ]
            for (environment, bundleIdentifier, xctestLoaded) in cases {
                var factoryCalls = 0
                let owner = BridgeRuntimeOwner(
                    isUnitTestHost: BridgeLaunchPolicy.isUnitTestHost(
                        environment: environment,
                        bundleIdentifier: bundleIdentifier,
                        xctestLoaded: xctestLoaded
                    ),
                    makeRuntime: {
                        factoryCalls += 1
                        return RuntimeProbe()
                    }
                )
                XCTAssertNil(owner.runtime)
                XCTAssertEqual(factoryCalls, 0)
            }
        }
    }

    func testAppRetainsOneRuntimeAcrossWindowReferenceLifetimes() async throws {
        try await MainActor.run {
            var factoryCalls = 0
            var owner: BridgeRuntimeOwner<RuntimeProbe>? = BridgeRuntimeOwner(
                isUnitTestHost: false,
                makeRuntime: {
                    factoryCalls += 1
                    return RuntimeProbe()
                }
            )
            weak var retainedRuntime = owner?.runtime
            let identity = try ObjectIdentifier(XCTUnwrap(owner?.runtime))

            for _ in 0..<3 {
                var windowReference = owner?.runtime
                XCTAssertEqual(try ObjectIdentifier(XCTUnwrap(windowReference)), identity)
                windowReference = nil
                XCTAssertNotNil(retainedRuntime, "Closing the window must not release the app runtime")
                XCTAssertEqual(factoryCalls, 1)
            }

            owner = nil
            XCTAssertNil(retainedRuntime, "Ownership must not escape the App into a global singleton")
        }
    }

    func testIndependentAppOwnersDoNotShareGlobalRuntime() async {
        await MainActor.run {
            let first = BridgeRuntimeOwner(isUnitTestHost: false, makeRuntime: RuntimeProbe.init)
            let second = BridgeRuntimeOwner(isUnitTestHost: false, makeRuntime: RuntimeProbe.init)
            XCTAssertNotNil(first.runtime)
            XCTAssertNotNil(second.runtime)
            XCTAssertFalse(first.runtime === second.runtime)
        }
    }
}
