import XCTest

@MainActor
final class WatchControlCenterUITests: XCTestCase {
    private var app: XCUIApplication!
    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--presentation-fixture"]
        app.launch()
    }
    private func capture(_ name: String) {
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name; image.lifetime = .keepAlways; add(image)
    }
    private func openMode(_ title: String) {
        app.buttons["control-mode-picker"].tap()
        let button = app.buttons[title]
        for _ in 0..<12 where !button.isHittable {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.78))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.54))
            start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
        }
        if !button.isHittable { capture("unreachable-mode-\(title)") }
        XCTAssertTrue(button.isHittable, "Mode must remain reachable: \(title)")
        button.tap()
    }
    func testHomeOfflineStateAndDeviceEscape() {
        XCTAssertTrue(app.buttons["control-mode-picker"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["control-device-picker"].firstMatch.isHittable)
        XCTAssertTrue(app.staticTexts["control-connection-state"].label.contains("未连接"))
        capture("40mm-control-home-offline")
        app.buttons["control-device-picker"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["还没有连接的设备"].waitForExistence(timeout: 5))
        capture("device-picker-offline")
        app.buttons["关闭"].tap()
        XCTAssertTrue(app.buttons["control-mode-picker"].isHittable)
    }
    /// The first screen must show whole controls, not ones hidden under the mode row.
    private func assertAboveBottomRow(_ element: XCUIElement, _ name: String) {
        XCTAssertTrue(element.exists, "Missing control: \(name)")
        let bottomRow = app.buttons["control-more"]
        if bottomRow.exists {
            XCTAssertLessThanOrEqual(element.frame.maxY, bottomRow.frame.minY + 1, "Control overlaps the bottom row: \(name)")
        }
        XCTAssertTrue(app.frame.contains(element.frame), "Control clipped: \(name)")
    }

    func testAllModesAreReachableAndDisconnectedActionsStayDisabled() {
        for mode in ["媒体", "语音输入", "保存录音", "无线麦", "Codex 听写", "演示", "电视", "提词与阅读"] {
            openMode(mode)
            capture("mode-\(mode)")
            if mode == "电视" {
                for title in ["上", "左", "确认", "右", "下", "返回", "播放或暂停"] {
                    let button = app.buttons[title]
                    XCTAssertTrue(button.exists, "Missing television control: \(title)")
                    XCTAssertTrue(app.frame.contains(button.frame), "Television control clipped: \(title)")
                }
            }
            if mode == "媒体" {
                for title in ["上一首", "播放或暂停", "下一首", "静音"] {
                    let button = app.buttons[title]
                    XCTAssertTrue(button.exists, "Missing media control: \(title)")
                    XCTAssertTrue(app.frame.contains(button.frame), "Media control clipped: \(title)")
                }
            }
            if mode == "提词与阅读" {
                for title in ["上一段", "播放或暂停", "下一段"] {
                    let button = app.buttons[title]
                    XCTAssertTrue(button.exists, "Missing reading control: \(title)")
                    XCTAssertTrue(app.frame.contains(button.frame), "Reading control clipped: \(title)")
                }
            }
            if mode == "演示" {
                for title in ["上一页", "下一页", "开始 Keynote", "退出演示"] {
                    assertAboveBottomRow(app.buttons[title], title)
                }
            }
            if ["语音输入", "保存录音", "无线麦", "Codex 听写"].contains(mode) {
                assertAboveBottomRow(app.buttons["control-voice-toggle"], "voice toggle")
                assertAboveBottomRow(app.staticTexts["control-audio-status"], "audio status")
                XCTAssertLessThanOrEqual(app.buttons["control-voice-toggle"].frame.maxY,
                                         app.staticTexts["control-audio-status"].frame.minY + 1, "Voice status overlaps its button")
                XCTAssertFalse(app.buttons["control-voice-toggle"].isEnabled)
                XCTAssertEqual(app.staticTexts["control-connection-state"].label, "语音链路未就绪")
                XCTAssertTrue(app.staticTexts["control-audio-status"].label.contains("iPhone 中继"))
            }
            XCTAssertTrue(app.buttons["control-mode-picker"].isHittable)
        }
    }
    func testLargestTypeKeepsNavigationAndVoiceAccessible() {
        app.terminate()
        app.launchArguments = ["--presentation-fixture", "--largest-type-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons["control-mode-picker"].waitForExistence(timeout: 8))
        capture("largest-type-home")
        openMode("保存录音")
        XCTAssertTrue(app.buttons["control-mode-picker"].isHittable)
        XCTAssertTrue(app.buttons["control-voice-toggle"].isHittable)
        let voiceFrame = app.buttons["control-voice-toggle"].frame
        let navigationFrame = app.buttons["control-mode-picker"].frame
        XCTAssertGreaterThanOrEqual(voiceFrame.minY, navigationFrame.maxY - 1, "The recording control must not cover the mode navigation")
        XCTAssertTrue(app.frame.contains(voiceFrame), "The complete recording control must stay on screen")
        capture("largest-type-recording")
        app.buttons["control-device-picker"].firstMatch.tap()
        XCTAssertTrue(app.buttons["关闭"].waitForExistence(timeout: 5))
        app.buttons["关闭"].tap()
        for (mode, titles) in [("媒体", ["上一首", "播放或暂停", "下一首", "静音"]),
                               ("电视", ["上", "左", "确认", "右", "下", "返回", "播放或暂停"]),
                               ("提词与阅读", ["上一段", "播放或暂停", "下一段"])] {
            openMode(mode)
            capture("largest-type-\(mode)")
            XCTAssertTrue(app.buttons["control-mode-picker"].isHittable)
            for title in titles {
                let button = app.buttons[title]
                XCTAssertTrue(button.exists, "Missing \(mode) control: \(title)")
                XCTAssertTrue(app.frame.contains(button.frame), "Clipped \(mode) control: \(title)")
            }
        }
    }
    func testMoreRetainsCustomRemoteAndCodex() {
        app.buttons["control-more"].tap()
        XCTAssertTrue(app.buttons["自定义遥控"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Codex"].exists)
        capture("more-actions")
    }
}
