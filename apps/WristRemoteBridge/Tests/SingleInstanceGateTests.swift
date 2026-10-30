import Foundation
import XCTest
@testable import WristRemoteBridge

final class SingleInstanceGateTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SingleInstanceGateTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testSecondAcquireFailsWhileTheLockIsHeld() throws {
        let first = try XCTUnwrap(SingleInstanceGate.acquire(directory: directory))
        defer { SingleInstanceGate.release(first) }

        XCTAssertNil(
            SingleInstanceGate.acquire(directory: directory),
            "A second copy must not take the lock while the first holds it"
        )
    }

    func testReleasingTheLockLetsTheNextAcquireSucceed() throws {
        let first = try XCTUnwrap(SingleInstanceGate.acquire(directory: directory))
        SingleInstanceGate.release(first)

        let second = try XCTUnwrap(SingleInstanceGate.acquire(directory: directory))
        SingleInstanceGate.release(second)
    }

    func testAcquireCreatesMissingDirectory() throws {
        let nested = directory.appendingPathComponent("nested/deeper", isDirectory: true)
        let descriptor = try XCTUnwrap(SingleInstanceGate.acquire(directory: nested))
        SingleInstanceGate.release(descriptor)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: nested.appendingPathComponent(SingleInstanceGate.lockFileName).path
            )
        )
    }

    func testActivationFindsNothingWithoutABundleIdentifier() {
        XCTAssertFalse(SingleInstanceGate.activateRunningInstance(bundleIdentifier: nil))
    }

    func testActivationFindsNothingForAnUnusedBundleIdentifier() {
        XCTAssertFalse(
            SingleInstanceGate.activateRunningInstance(
                bundleIdentifier: "org.example.wristremote.bridge.instance.\(UUID().uuidString)"
            )
        )
    }
}
