import XCTest
@testable import WristRemote

#if !SWIFT_PACKAGE
@MainActor
final class WristReadingControllerTests: XCTestCase {
    func testDisconnectedSessionDoesNotPublishOrAcceptCommands() {
        var publications = 0
        let reader = WristReadingController(dependencies: .init(isConnected: { false },
            publish: { _ in publications += 1 }, setReceiver: { _ in XCTFail("No receiver before connection") }))
        reader.start()
        XCTAssertNil(reader.state)
        XCTAssertEqual(publications, 0)
    }

    func testRealControllerAcknowledgesOnlyCurrentFreshNonDuplicateCommands() throws {
        var published: [WristReadingSessionState?] = []
        var receiver: ((WristControlCommand) -> WristControlReceipt)?
        let reader = WristReadingController(dependencies: .init(isConnected: { true },
            publish: { published.append($0) }, setReceiver: { receiver = $0 }))
        reader.text = "First\n\nSecond\n\nThird"
        reader.start()
        let target = try XCTUnwrap(reader.state?.targetID)
        let command = WristControlCommand(targetID: target, action: .nextPage)
        XCTAssertEqual(receiver?(command).accepted, true)
        XCTAssertEqual(reader.state?.page, 1)
        XCTAssertEqual(receiver?(command).accepted, false)
        XCTAssertEqual(reader.state?.page, 1)
        XCTAssertEqual(receiver?(.init(targetID: "reading-other", action: .nextPage)).accepted, false)
        XCTAssertEqual(receiver?(.init(targetID: target, action: .nextPage, issuedAt: 1)).accepted, false)
        XCTAssertEqual(receiver?(.init(targetID: target, action: .sessionPlayPause)).accepted, true)
        XCTAssertEqual(reader.state?.isPlaying, true)
        reader.stop()
        XCTAssertNil(receiver); XCTAssertNil(reader.state)
        XCTAssertNil(published.last!)
    }

    func testConnectionLossEndsSessionAndRemovesReceiver() async throws {
        var connected = true
        var receiver: ((WristControlCommand) -> WristControlReceipt)?
        let reader = WristReadingController(dependencies: .init(isConnected: { connected },
            publish: { _ in }, setReceiver: { receiver = $0 }))
        reader.start()
        XCTAssertNotNil(reader.state)
        connected = false
        try await Task.sleep(for: .milliseconds(1_200))
        XCTAssertNil(reader.state); XCTAssertNil(receiver)
        XCTAssertEqual(reader.detail, "Mac 连接中断，会话已停止")
    }
}
#endif
