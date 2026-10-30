import XCTest

@MainActor
final class WristReadingUITests: XCTestCase {
    func testLandscapeRetainsParagraphAndVisibleControls() {
        let app = XCUIApplication()
        app.launchArguments = ["--reading-session-preview"]
        app.launch()
        XCTAssertTrue(app.staticTexts["1 / 3"].waitForExistence(timeout: 10))
        app.buttons["reading-next"].tap()
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        XCTAssertTrue(app.staticTexts["2 / 3"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.buttons["reading-play"].isHittable)
        XCTAssertTrue(app.buttons["结束会话"].isHittable)
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        image.name = "ipad-reading-landscape"; image.lifetime = .keepAlways; add(image)
    }

    func testReadingControlsAdvanceMirrorAndEndTheSession() {
        let app = XCUIApplication()
        app.launchArguments = ["--reading-session-preview"]
        app.launch()
        XCTAssertTrue(app.staticTexts["1 / 3"].waitForExistence(timeout: 10))
        let before = XCTAttachment(screenshot: app.screenshot())
        before.name = "ipad-reading-session"; before.lifetime = .keepAlways; add(before)
        app.buttons["reading-next"].tap()
        XCTAssertTrue(app.staticTexts["2 / 3"].waitForExistence(timeout: 4))
        app.buttons["reading-previous"].tap()
        XCTAssertTrue(app.staticTexts["1 / 3"].exists)
        app.buttons["reading-play"].tap()
        XCTAssertTrue(app.buttons["reading-play"].label.contains("暂停"))
        app.buttons["reading-play"].tap()
        app.switches["镜像提词"].firstMatch.tap()
        let mirror = XCTAttachment(screenshot: app.screenshot())
        mirror.name = "ipad-mirrored-reading"; mirror.lifetime = .keepAlways; add(mirror)
        app.buttons["结束会话"].tap()
        XCTAssertTrue(app.buttons["reading-start"].waitForExistence(timeout: 4))
    }
}
