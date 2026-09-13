import XCTest
@testable import WristRemote

final class WatchCodexCatalogMaintenanceTests: XCTestCase {
    func testColdStartDefersCatalogUntilCompletePrivateRouteAndOnlyOnce() {
        var gate = WatchCodexCatalogStartupGate()
        XCTAssertFalse(gate.request(routeIsReady: false))
        XCTAssertFalse(gate.consumeReadyStatus(routeIsReady: false, sceneIsActive: true))
        XCTAssertFalse(gate.consumeReadyStatus(routeIsReady: true, sceneIsActive: false))
        XCTAssertTrue(gate.consumeReadyStatus(routeIsReady: true, sceneIsActive: true))
        XCTAssertFalse(gate.consumeReadyStatus(routeIsReady: true, sceneIsActive: true))
    }

    func testReadyRefreshAndBackgroundCancellationLeaveNoDeferredRequest() {
        var gate = WatchCodexCatalogStartupGate()
        XCTAssertFalse(gate.request(routeIsReady: false))
        XCTAssertTrue(gate.request(routeIsReady: true))
        XCTAssertFalse(gate.isWaitingForRoute)
        XCTAssertFalse(gate.request(routeIsReady: false))
        gate.cancel()
        XCTAssertFalse(gate.consumeReadyStatus(routeIsReady: true, sceneIsActive: true))
    }

    func testPreparationCancelledBeforeReceiptStillReconciles() {
        var maintenance = WatchCodexCatalogMaintenance()
        XCTAssertFalse(maintenance.mayUpdateSelection(voiceIsBusy: true))
        XCTAssertFalse(maintenance.mayResume(isSceneActive: true, voiceIsBusy: true))
        XCTAssertTrue(maintenance.mayResume(isSceneActive: true, voiceIsBusy: false))
        XCTAssertTrue(maintenance.mayUpdateSelection(voiceIsBusy: false))
        XCTAssertFalse(maintenance.needsReconciliation)
    }

    func testDeferredCatalogSurvivesBackgroundUntilVoiceAndSceneAreReady() {
        var maintenance = WatchCodexCatalogMaintenance()
        XCTAssertFalse(maintenance.mayUpdateSelection(voiceIsBusy: true))
        XCTAssertFalse(maintenance.mayResume(isSceneActive: false, voiceIsBusy: false))
        XCTAssertTrue(maintenance.needsReconciliation)
        XCTAssertFalse(maintenance.mayResume(isSceneActive: true, voiceIsBusy: true))
        XCTAssertTrue(maintenance.mayResume(isSceneActive: true, voiceIsBusy: false))
    }
}
