import XCTest

@MainActor
final class WristRemoteWatchUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    func testCodexHomeIsFirstAndAllRemotePagesRemainReachable() throws {
        XCTAssertTrue(app.staticTexts["Codex"].waitForExistence(timeout: 15), "Codex 首屏没有出现")
        XCTAssertTrue(app.buttons["遥控器"].waitForExistence(timeout: 5), "首屏缺少遥控器入口")

        app.buttons["遥控器"].tap()

        assertButtons(["上键", "左键", "确定键", "右键", "下键"])

        selectRemotePage("功能")
        assertButtons([
            "电源键", "返回键", "主页键", "菜单键", "TV 键",
            "语音", "音量减键", "音量加键",
        ])

        selectRemotePage("收藏")
        XCTAssertTrue(app.buttons["收藏与手感"].waitForExistence(timeout: 5), "收藏页没有出现")

        selectRemotePage("功能")
        XCTAssertTrue(app.buttons["电源键"].waitForExistence(timeout: 5), "无法返回功能键页")
        selectRemotePage("方向")
        XCTAssertTrue(app.buttons["确定键"].waitForExistence(timeout: 5), "无法返回方向键页")
    }

    func testExplicitPagePickerNeverStartsFromARemoteButton() throws {
        let remote = app.buttons["遥控器"]
        XCTAssertTrue(remote.waitForExistence(timeout: 15), "首屏缺少遥控器入口")
        remote.tap()

        XCTAssertTrue(app.buttons["确定键"].waitForExistence(timeout: 5))
        selectRemotePage("功能")
        XCTAssertFalse(app.buttons["确定键"].exists, "切页后方向键仍覆盖交互面")
        XCTAssertTrue(app.buttons["语音"].waitForExistence(timeout: 5))
        selectRemotePage("收藏")
        XCTAssertFalse(app.buttons["语音"].exists, "切页后语音键仍覆盖交互面")
        XCTAssertTrue(app.buttons["收藏与手感"].waitForExistence(timeout: 5))
    }

    func testSingleDoubleAndLongPressSurface() throws {
        try openRemoteDeckAndWaitForLiveConnection()

        let up = app.buttons["上键"]
        XCTAssertTrue(up.waitForExistence(timeout: 15), "上键没有出现")
        XCTAssertTrue(up.isHittable, "上键不可点击")

        up.tap()
        up.doubleTap()
        up.press(forDuration: 1.0)

        XCTAssertTrue(up.exists, "手势完成后按键界面异常退出")
    }

    func testAllTwelvePhysicalButtonsForwardSinglePress() throws {
        try openRemoteDeckAndWaitForLiveConnection()

        for label in ["上键", "左键", "确定键", "右键", "下键"] {
            app.buttons[label].tap()
        }

        selectRemotePage("功能")
        for label in [
            "电源键", "返回键", "主页键", "菜单键", "TV 键",
            "音量减键", "音量加键",
        ] {
            let button = app.buttons[label]
            XCTAssertTrue(button.waitForExistence(timeout: 5), "缺少按键：\(label)")
            button.tap()
        }
    }

    func testConfiguredHomeAndMenuGestureVariants() throws {
        try openRemoteDeckAndWaitForLiveConnection()
        selectRemotePage("功能")

        for label in ["主页键", "菜单键"] {
            let button = app.buttons[label]
            XCTAssertTrue(button.waitForExistence(timeout: 5), "缺少按键：\(label)")
            button.tap()
            Thread.sleep(forTimeInterval: 1.0)
            button.doubleTap()
            Thread.sleep(forTimeInterval: 1.0)
            button.press(forDuration: 1.0)
            Thread.sleep(forTimeInterval: 1.0)
        }
    }

    private func openRemoteDeckAndWaitForLiveConnection() throws {
        let remote = app.buttons["遥控器"]
        XCTAssertTrue(remote.waitForExistence(timeout: 15), "首屏缺少遥控器入口")
        remote.tap()

        let up = app.buttons["上键"]
        XCTAssertTrue(up.waitForExistence(timeout: 10), "方向键页没有出现")
        if !up.isEnabled {
            let status = app.buttons.matching(
                NSPredicate(format: "label BEGINSWITH %@", "连接状态：")
            ).firstMatch
            if status.waitForExistence(timeout: 3) {
                status.tap()
            }
        }
        if !up.isEnabled {
            let enabled = NSPredicate(format: "enabled == true")
            expectation(for: enabled, evaluatedWith: up)
            waitForExpectations(timeout: 30)
        }
        XCTAssertTrue(up.isEnabled, "遥控器未恢复实时连接")
    }

    private func selectRemotePage(
        _ page: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let picker = app.buttons["选择遥控页"]
        XCTAssertTrue(
            picker.waitForExistence(timeout: 5),
            "缺少明确的遥控分页控件",
            file: file,
            line: line
        )
        picker.tap()
        let destination = app.buttons["\(page)页"]
        XCTAssertTrue(
            destination.waitForExistence(timeout: 5),
            "分页菜单缺少：\(page)",
            file: file,
            line: line
        )
        destination.tap()
    }

    private func assertButtons(_ labels: [String], file: StaticString = #filePath, line: UInt = #line) {
        for label in labels {
            XCTAssertTrue(
                app.buttons[label].waitForExistence(timeout: 5),
                "缺少按键：\(label)",
                file: file,
                line: line
            )
        }
    }
}
