import XCTest

@MainActor
final class WristRemoteWatchUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        addUIInterruptionMonitor(withDescription: "首次系统权限") { alert in
            for label in ["允许", "Allow"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        app = XCUIApplication()
        app.launch()
        // A harmless title-area interaction gives XCTest a chance to handle
        // the first-launch notification alert without activating a control.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()
    }

    func testCodexHomeIsFirstAndAllRemotePagesRemainReachable() throws {
        XCTAssertTrue(app.staticTexts["Codex"].waitForExistence(timeout: 15), "Codex 首屏没有出现")
        XCTAssertTrue(app.buttons.matching(identifier: "remote-deck-entry").firstMatch.waitForExistence(timeout: 5), "首屏缺少遥控器入口")

        app.buttons.matching(identifier: "remote-deck-entry").firstMatch.tap()

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

    func testCodexConversationDestinationIsExplicitlySelectable() throws {
        XCTAssertTrue(app.staticTexts["Codex"].waitForExistence(timeout: 15), "Codex 首屏没有出现")

        let destination = app.buttons.matching(identifier: "codex-destination-entry").firstMatch
        XCTAssertTrue(destination.waitForExistence(timeout: 5), "首屏缺少明确的会话目标入口")
        XCTAssertEqual(destination.value as? String, "尚未选择", "未选择目标时不应暗中发送到当前会话")
        destination.tap()

        XCTAssertTrue(app.staticTexts["选择会话"].waitForExistence(timeout: 5), "无法进入会话选择页")
        let hasNewConversationSection = app.staticTexts["新建会话"].exists
        let hasConnectionIssueSection = app.staticTexts["无法同步"].exists
        let hasUnavailableSection = app.staticTexts["会话不可用"].exists
        XCTAssertTrue(
            hasNewConversationSection || hasConnectionIssueSection || hasUnavailableSection,
            "会话选择页既没有新建入口，也没有明确说明当前连接或目录状态"
        )
    }

    func testConversationPickerAlwaysHasAnAppOwnedEscapePath() throws {
        XCTAssertTrue(app.staticTexts["Codex"].waitForExistence(timeout: 15))

        let destination = app.buttons.matching(identifier: "codex-destination-entry").firstMatch
        XCTAssertTrue(destination.waitForExistence(timeout: 5))
        destination.tap()

        XCTAssertTrue(app.staticTexts["选择会话"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.searchFields.firstMatch.exists, "会话目录不应再打开腕上键盘")

        // watchOS exposes the toolbar button through several nested
        // accessibility proxies. `firstMatch` targets the single visible
        // control without requiring a unique proxy count.
        let close = app.buttons.matching(identifier: "codex-conversation-picker-close").firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 5), "会话选择页缺少 App 自有关闭入口")
        close.tap()

        XCTAssertTrue(destination.waitForExistence(timeout: 5), "关闭会话选择后没有返回 Codex 首屏")
        XCTAssertFalse(close.exists, "会话选择页关闭后仍残留")
    }

    func testLiveCatalogRefreshAndNewConversationCancel() throws {
        let destination = app.buttons.matching(identifier: "codex-destination-entry").firstMatch
        XCTAssertTrue(destination.waitForExistence(timeout: 15))
        if !destination.isHittable { app.swipeDown() }
        destination.tap()
        XCTAssertTrue(app.staticTexts["选择会话"].waitForExistence(timeout: 5))
        let refresh = app.buttons["刷新会话"].firstMatch
        if refresh.exists && refresh.isEnabled { refresh.tap() }
        let newEntry = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "新建会话，")).firstMatch
        let hasCatalog = newEntry.waitForExistence(timeout: 25)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Live conversation catalog"
        attachment.lifetime = .keepAlways
        add(attachment)
        if !hasCatalog { print(app.debugDescription) }
        XCTAssertTrue(hasCatalog, "Mac did not return a live conversation catalog")
        if !newEntry.isHittable { app.swipeUp() }
        newEntry.tap()
        XCTAssertTrue(app.buttons["取消"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        app.buttons["取消"].tap()
        let close = app.buttons.matching(identifier: "codex-conversation-picker-close").firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()
        XCTAssertTrue(destination.waitForExistence(timeout: 5))
    }

    func testColdStartCatalogLoadsWithoutManualRefresh() throws {
        let destination = app.buttons.matching(identifier: "codex-destination-entry").firstMatch
        XCTAssertTrue(destination.waitForExistence(timeout: 15))
        if !destination.isHittable { app.swipeDown() }
        destination.tap()
        let entry = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "新建会话，")).firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 25), "Cold start must not require manual reconnect/refresh")
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        let close = app.buttons.matching(identifier: "codex-conversation-picker-close").firstMatch
        close.tap()
        XCTAssertTrue(destination.waitForExistence(timeout: 5))
    }

    func testPopulatedLongTitleLayoutKeepsVoiceAndRepeatedCloseReachable() throws {
        try assertPopulatedHomeCanClosePicker(largeType: false)
    }

    func testLargeTypeKeepsVoiceAndPickerEscapeReachable() throws {
        try assertPopulatedHomeCanClosePicker(largeType: true)
    }

    func testVoiceFailureIsVisibleInlineAndInAccessibleStatus() throws {
        app.terminate()
        app.launchArguments = ["--presentation-fixture", "--voice-failure-fixture"]
        app.launch()
        let status = app.buttons.matching(identifier: "codex-voice-status-entry").firstMatch
        for _ in 0..<4 where !status.isHittable { app.swipeUp() }
        XCTAssertTrue(status.isHittable)
        // A full Watch flick can leave a hittable row partly under the clock.
        // Position it explicitly before judging the actual small-screen text.
        for _ in 0..<4 where status.frame.minY < app.frame.minY + 44 {
            let delta = max(24, min(55, app.frame.minY + 48 - status.frame.minY))
            let origin = app.coordinate(withNormalizedOffset: .zero)
            origin.withOffset(CGVector(dx: app.frame.midX, dy: app.frame.height * 0.44))
                .press(forDuration: 0.05, thenDragTo: origin.withOffset(
                    CGVector(dx: app.frame.midX, dy: app.frame.height * 0.44 + delta)),
                    withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        XCTAssertGreaterThanOrEqual(status.frame.minY, app.frame.minY + 40)
        XCTAssertTrue((status.value as? String ?? "").contains("本次未发送"))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "Codex 转写未成功"
        )).firstMatch.exists, "结果必须直接显示，不能只藏在弹窗里")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Voice failure is visible on Watch home"
        attachment.lifetime = .keepAlways
        add(attachment)
        status.tap()
        XCTAssertTrue(app.buttons["知道了"].waitForExistence(timeout: 5))
        app.buttons["知道了"].tap()
    }

    func testBlankTaskIsSeparateFromProjectTaskAndCancelIsSafe() throws {
        app.terminate()
        app.launchArguments = ["--presentation-fixture"]
        app.launch()
        let destination = app.buttons.matching(identifier: "codex-destination-entry").firstMatch
        XCTAssertTrue(destination.waitForExistence(timeout: 15))
        destination.tap()
        let blank = app.buttons.matching(identifier: "codex-new-blank-task").firstMatch
        for _ in 0..<4 where !blank.isHittable { app.swipeUp() }
        XCTAssertTrue(blank.isHittable)
        XCTAssertTrue(blank.label.contains("完全空白任务"))
        blank.tap()
        XCTAssertTrue(app.staticTexts["新建空白任务？"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "不带旧会话消息或旧项目文件"
        )).firstMatch.exists)
        app.buttons["取消"].firstMatch.tap()
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "Picker accessibility after cancellation"
        tree.lifetime = .keepAlways
        add(tree)
        let project = app.buttons.matching(identifier: "codex-new-project-task").firstMatch
        for _ in 0..<4 where !project.isHittable {
            // Short drags keep adjacent rows from being skipped on a 40mm screen.
            let origin = app.coordinate(withNormalizedOffset: .zero)
            origin.withOffset(CGVector(dx: app.frame.midX, dy: app.frame.height * 0.78))
                .press(forDuration: 0.05, thenDragTo: origin.withOffset(
                    CGVector(dx: app.frame.midX, dy: app.frame.height * 0.48)),
                    withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        let picker = XCTAttachment(screenshot: app.screenshot())
        picker.name = "After blank-task cancellation"
        picker.lifetime = .keepAlways
        add(picker)
        XCTAssertTrue(project.isHittable)
        XCTAssertTrue(project.label.contains("在项目中新建"))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Blank task and existing-project task are distinct"
        attachment.lifetime = .keepAlways
        add(attachment)
        // Cancel never sends a creation request or replaces the selected task.
        let close = app.buttons.matching(identifier: "codex-conversation-picker-close").firstMatch
        close.tap()
        XCTAssertTrue(destination.waitForExistence(timeout: 5))
        XCTAssertTrue((destination.value as? String)?.contains("检查长标题") == true)
    }

    private func assertPopulatedHomeCanClosePicker(largeType: Bool) throws {
        app.terminate()
        app.launchArguments = ["--presentation-fixture"]
        if largeType { app.launchArguments.append("--large-type-fixture") }
        app.launch()
        XCTAssertTrue(app.staticTexts["Codex"].waitForExistence(timeout: 15))
        let voice = app.buttons.matching(identifier: "codex-voice-control").firstMatch
        XCTAssertTrue(voice.waitForExistence(timeout: 5))
        XCTAssertTrue(voice.isHittable, "40mm 首屏语音控件必须可见")
        let remote = app.buttons.matching(identifier: "remote-deck-entry").firstMatch
        XCTAssertTrue(remote.waitForExistence(timeout: 5))
        XCTAssertTrue(remote.isHittable, "有任务和大字号时也必须能进入独立遥控页")
        let target = app.buttons.matching(identifier: "codex-destination-entry").firstMatch
        XCTAssertGreaterThan(target.frame.height, 44, "长标题应使用多行，而不是被挤成单行")
        for _ in 0..<3 {
            let destination = app.buttons.matching(identifier: "codex-destination-entry").firstMatch
            if !destination.isHittable { app.swipeUp() }
            XCTAssertTrue(destination.isHittable)
            destination.tap()
            XCTAssertTrue(app.staticTexts["新建会话"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.keyboards.firstMatch.exists)
            XCTAssertFalse(app.searchFields.firstMatch.exists)
            let close = app.buttons.matching(identifier: "codex-conversation-picker-close").firstMatch
            XCTAssertTrue(close.isHittable)
            close.tap()
            XCTAssertTrue(voice.waitForExistence(timeout: 5))
            XCTAssertTrue(voice.isHittable)
        }
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = largeType ? "40mm large-type home" : "40mm populated home"
        attachment.lifetime = .keepAlways
        add(attachment)

        let status = app.buttons.matching(identifier: "codex-voice-status-entry").firstMatch
        for _ in 0..<8 where !status.isHittable { scrollHomeContentAboveVoice(voice) }
        XCTAssertTrue(status.isHittable, "完整语音状态必须有可达入口")
        XCTAssertGreaterThanOrEqual(status.frame.height, 44, "状态入口不能是微小的信息图标")
        status.tap()
        XCTAssertTrue(app.staticTexts["布局预览 · 不连接设备"].waitForExistence(timeout: 5))
        let dismissStatus = app.buttons["知道了"].firstMatch
        XCTAssertTrue(dismissStatus.isHittable, "语音状态必须可以关闭")
        dismissStatus.tap()
        XCTAssertTrue(voice.isHittable, "关闭语音状态后必须仍可操作录音控件")
    }

    private func scrollHomeContentAboveVoice(_ voice: XCUIElement) {
        // A whole-screen swipe starts inside the pinned hold-to-record control.
        // Use only the visible scrolling region, never the recording surface.
        let top = app.navigationBars.firstMatch.frame.maxY + 6
        let bottom = voice.frame.minY - 6
        XCTAssertGreaterThan(bottom - top, 24, "固定录音控件不能挤掉内容滚动区")
        let origin = app.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(CGVector(dx: app.frame.midX, dy: bottom))
            .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: app.frame.midX, dy: top)))
    }

    func testSelectedDestinationKeepsItsFullReadableIdentity() throws {
        app.terminate()
        app.launchArguments = ["--presentation-fixture", "--large-type-fixture"]
        app.launch()
        let destination = app.buttons.matching(identifier: "codex-destination-entry").firstMatch
        XCTAssertTrue(destination.waitForExistence(timeout: 15))
        destination.tap()
        let selected = app.descendants(matching: .any)
            .matching(identifier: "codex-selected-target-summary").firstMatch
        for _ in 0..<5 where !selected.isHittable { app.swipeUp() }
        XCTAssertTrue(selected.isHittable)
        XCTAssertEqual(selected.label, "已选目标：检查长标题下的会话选择、中文阅读与返回体验，示例项目")
        XCTAssertGreaterThan(selected.frame.height, 60, "完整目标不能退回两行截断布局")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "40mm full selected destination"
        attachment.lifetime = .keepAlways
        add(attachment)
        let close = app.buttons.matching(identifier: "codex-conversation-picker-close").firstMatch
        XCTAssertTrue(close.isHittable)
        close.tap()
        XCTAssertTrue(app.buttons.matching(identifier: "codex-voice-control").firstMatch.isHittable)
    }

    func testExplicitPagePickerNeverStartsFromARemoteButton() throws {
        let remote = app.buttons.matching(identifier: "remote-deck-entry").firstMatch
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

    // Physical-device run only, with the dedicated Mac test pad frontmost.
    // Keep destructive text editing before any desktop/application switch.
    func testLiveTwelveButtonsWithMacEffectCapture() throws {
        try openRemoteDeckAndWaitForLiveConnection()
        for label in ["上键", "左键", "右键", "下键", "确定键"] {
            print("LIVE_BUTTON", label)
            app.buttons[label].tap()
            Thread.sleep(forTimeInterval: 1.5)
        }
        selectRemotePage("功能")
        for label in ["返回键", "菜单键", "电源键", "音量加键", "音量减键", "主页键", "主页键", "TV 键"] {
            let button = app.buttons[label]
            XCTAssertTrue(button.waitForExistence(timeout: 5))
            XCTAssertTrue(button.isEnabled)
            print("LIVE_BUTTON", label)
            button.tap()
            Thread.sleep(forTimeInterval: 1.5)
        }
    }

    func testLiveBlankTaskEntryAndCancel() throws {
        let destination = app.buttons.matching(identifier: "codex-destination-entry").firstMatch
        XCTAssertTrue(destination.waitForExistence(timeout: 15))
        destination.tap()
        let blank = app.buttons.matching(identifier: "codex-new-blank-task").firstMatch
        XCTAssertTrue(blank.waitForExistence(timeout: 30), "Live Mac catalog did not include a blank task")
        for _ in 0..<5 where !blank.isHittable { app.swipeUp() }
        XCTAssertTrue(blank.isHittable)
        blank.tap()
        XCTAssertTrue(app.staticTexts["新建空白任务？"].waitForExistence(timeout: 5))
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "Physical Watch blank task confirmation"
        capture.lifetime = .keepAlways
        add(capture)
        app.buttons["取消"].firstMatch.tap()
        app.buttons.matching(identifier: "codex-conversation-picker-close").firstMatch.tap()
        XCTAssertTrue(destination.waitForExistence(timeout: 5))
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

    // Run only with a benign profile and a separate Mac-side receipt probe.
    // The UI assertions alone do not establish delivery to the Mac.
    func testMenuSwitcherAndVolumeWithoutDesktopFocusChange() throws {
        try openRemoteDeckAndWaitForLiveConnection()
        selectRemotePage("功能")
        for label in ["菜单键", "TV 键", "音量加键", "音量减键"] {
            let button = app.buttons[label]
            XCTAssertTrue(button.waitForExistence(timeout: 5))
            XCTAssertTrue(button.isEnabled)
            button.tap()
            Thread.sleep(forTimeInterval: 1.0)
        }
    }

    private func openRemoteDeckAndWaitForLiveConnection() throws {
        let remote = app.buttons.matching(identifier: "remote-deck-entry").firstMatch
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
        let picker = app.buttons.matching(identifier: "remote-page-picker").firstMatch
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
