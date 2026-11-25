import XCTest

/// #1024：11-25 合并的六个 PR 在真机上走一遍、截图、对新页面跑整页审计。全部走进程内 Mock，地图关。
///
/// 挂在 `AccessibilityAuditTests` 上是为了用同一个 `audit(_:)`（带遮挡栏、Mock 横幅的放行判据）。
/// 每屏另记一份附件 `*-a11y-order`：无障碍树里排在最前的几个元素的读屏文字，按树序 ——
/// 树序就是 VoiceOver 从上往下念的顺序。XCUITest 开不了 VoiceOver，听感仍要人耳验。
extension AccessibilityAuditTests {
    // MARK: - #1013 通话页「取消这次预约」→ 取消终态页（#1022 原因行）

    @MainActor
    func testWalk_IntroCallCancelBookingLandsOnCancelledPage() throws {
        guard #available(iOS 17.0, *) else { throw XCTSkip("performAccessibilityAudit 需要 iOS 17+ 运行时") }
        let app = walkthroughLaunchBlind(seed: "PENDING_INTRO_CALL")
        _ = walkthroughTapIfAppears(app, "blindRunnerHomeOrderCard")
        XCTAssertTrue(walkthroughElement(app, "blindIntroCallTitle").waitForExistence(timeout: 20), "没进通话页")
        let more = app.buttons["更多操作"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 10), "通话页顶栏没有「更多操作」")
        more.tap()
        let cancel = app.buttons["取消这次预约"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5), "通话页菜单里没有「取消这次预约」")
        walkthroughAttach(app, "W1-intro-call-menu")
        cancel.tap()
        let confirm = app.buttons["确认取消"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "取消没有二次确认")
        walkthroughAttach(app, "W1-cancel-confirmation")
        confirm.tap()
        let reason = walkthroughElement(app, "blindOrderTerminalCloseReason")
        XCTAssertTrue(reason.waitForExistence(timeout: 20), "取消后没到终态页的原因行")
        sleep(1)
        walkthroughAttach(app, "W1-terminal-cancelled")
        walkthroughRecordA11yOrder(app, "W1-terminal-cancelled")
        try audit(app)
    }

    // MARK: - #1022 已完成 / 没人接 终态页

    @MainActor
    func testWalk_CompletedPageSaysWhyItEnded() throws {
        guard #available(iOS 17.0, *) else { throw XCTSkip("performAccessibilityAudit 需要 iOS 17+ 运行时") }
        let app = walkthroughLaunchBlind(seed: "IN_PROGRESS")
        _ = walkthroughTapIfAppears(app, "blindRunnerHomeOrderCard", timeout: 15)
        guard let finish = walkthroughScrollTo(app, app.buttons["模拟服务完成"].firstMatch) else {
            return XCTFail("跑步中页找不到 Mock「模拟服务完成」")
        }
        finish.tap()
        sleep(3)
        app.swipeDown()
        app.swipeDown()
        sleep(1)
        walkthroughAttach(app, "W2-terminal-completed")
        walkthroughRecordA11yOrder(app, "W2-terminal-completed")
        try audit(app)
    }

    /// 首页不列终态单（`ScreenTourTests` 注释）：种 `NO_VOLUNTEER` 看冷启动能不能到这一屏，到不了截图里看得出来。不审计。
    @MainActor
    func testWalk_NoVolunteerPage() {
        let app = walkthroughLaunchBlind(seed: "NO_VOLUNTEER")
        _ = walkthroughTapIfAppears(app, "blindRunnerHomeOrderCard", timeout: 10)
        sleep(2)
        walkthroughAttach(app, "W3-terminal-no-volunteer")
        walkthroughRecordA11yOrder(app, "W3-terminal-no-volunteer")
    }

    // MARK: - #1022 跑步途中陪跑员退出 → 重新匹配页

    @MainActor
    func testWalk_MidRunDepartureRematchPage() throws {
        guard #available(iOS 17.0, *) else { throw XCTSkip("performAccessibilityAudit 需要 iOS 17+ 运行时") }
        let app = walkthroughLaunchBlind(seed: "DRIVER_ARRIVED", env: ["AIDRUN_UI_TEST_VOLUNTEER_LOST_AFTER_SECONDS": "12"])
        _ = walkthroughTapIfAppears(app, "blindRunnerHomeOrderCard", timeout: 15)
        let title = app.staticTexts["陪跑员已退出"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 30), "陪跑员出发后退出，重新匹配页没说「陪跑员已退出」")
        sleep(1)
        walkthroughAttach(app, "W4-rematch-mid-run")
        walkthroughRecordA11yOrder(app, "W4-rematch-mid-run")
        try audit(app)
    }

    // MARK: - #1020 闸开着：陪跑员请求结束，跑者确认安全

    @MainActor
    func testWalk_FinishSafetyGateOpenRunnerConfirmsSafe() throws {
        guard #available(iOS 17.0, *) else { throw XCTSkip("performAccessibilityAudit 需要 iOS 17+ 运行时") }
        let app = walkthroughLaunchBlind(seed: "IN_PROGRESS")
        _ = walkthroughTapIfAppears(app, "blindRunnerHomeOrderCard", timeout: 15)
        guard let gate = walkthroughScrollTo(app, app.buttons["切换 Mock 确认安全闸"].firstMatch) else {
            return XCTFail("跑步中页找不到 Mock「切换 Mock 确认安全闸」")
        }
        gate.tap()
        guard let request = walkthroughScrollTo(app, app.buttons["模拟陪跑员请求结束"].firstMatch) else {
            return XCTFail("跑步中页找不到 Mock「模拟陪跑员请求结束」")
        }
        request.tap()
        app.swipeDown()
        app.swipeDown()
        let card = walkthroughElement(app, "blindFinishSafetyCard")
        XCTAssertTrue(card.waitForExistence(timeout: 15), "陪跑员请求结束后，跑者端没出现确认安全卡")
        sleep(1)
        walkthroughAttach(app, "W5-runner-finish-safety-card")
        walkthroughRecordA11yOrder(app, "W5-runner-finish-safety-card")
        try audit(app)
        walkthroughElement(app, "blindFinishSafetyConfirmButton").tap()
        sleep(1)
        walkthroughAttach(app, "W5-runner-after-confirm-tap")
        // 确认若带二次确认框，点框里最后一个按钮（确认类按钮排在取消之后）。
        let alert = app.alerts.firstMatch
        if alert.waitForExistence(timeout: 3) { alert.buttons.element(boundBy: alert.buttons.count - 1).tap() }
        sleep(4)
        walkthroughAttach(app, "W5-runner-confirmed-safe")
        walkthroughRecordA11yOrder(app, "W5-runner-confirmed-safe")
    }

    @MainActor
    func testWalk_FinishSafetyGateOpenVolunteerRequestsFinish() throws {
        guard #available(iOS 17.0, *) else { throw XCTSkip("performAccessibilityAudit 需要 iOS 17+ 运行时") }
        let app = walkthroughLaunchVolunteer(seed: "IN_PROGRESS", env: ["AIDRUN_MOCK_FINISH_BLIND_CONFIRM_SECONDS": "600"])
        let finish = walkthroughElement(app, "volunteerFinishEscortButton")
        XCTAssertTrue(finish.waitForExistence(timeout: 25), "陪跑员跑步中页没有结束按钮")
        finish.press(forDuration: 2.6)
        let notice = walkthroughElement(app, "volunteerFinishSafetyNotice")
        XCTAssertTrue(notice.waitForExistence(timeout: 15), "闸开着时请求结束后，没说在等跑者确认")
        sleep(1)
        walkthroughAttach(app, "W6-volunteer-waiting-runner-confirm")
        walkthroughRecordA11yOrder(app, "W6-volunteer-waiting-runner-confirm")
        try audit(app)
    }

    // MARK: - #1014 陪跑员不在订单页时收到求助

    @MainActor
    func testWalk_VolunteerGlobalEmergencyAlertOffTheOrderPage() throws {
        guard #available(iOS 17.0, *) else { throw XCTSkip("performAccessibilityAudit 需要 iOS 17+ 运行时") }
        let app = walkthroughLaunchVolunteer(
            seed: "SCHEDULED_CONFIRMED",
            env: ["AIDRUN_UI_TEST_SEED_HISTORY": "1", "AIDRUN_UI_TEST_VOLUNTEER_EMERGENCY_AFTER_SECONDS": "15"]
        )
        // 先离开订单页：进「记录」里的一条详情，那一页有导航栏返回按钮，用来看常驻红条挡不挡它。
        walkthroughTapTab(app, "记录")
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "月", "公里")).firstMatch
        if row.waitForExistence(timeout: 10) { row.tap() }
        let alert = walkthroughElement(app, "volunteerEmergencyAlert")
        XCTAssertTrue(alert.waitForExistence(timeout: 30), "不在订单页时，求助警报没弹出")
        sleep(1)
        walkthroughAttach(app, "W7-volunteer-alert-full")
        walkthroughRecordA11yOrder(app, "W7-volunteer-alert-full")
        try audit(app)
        walkthroughElement(app, "volunteerEmergencyAlertAcknowledge").tap()
        let bar = walkthroughElement(app, "volunteerEmergencyBar")
        XCTAssertTrue(bar.waitForExistence(timeout: 10), "确认后顶部常驻入口没出现")
        sleep(1)
        walkthroughAttach(app, "W7-volunteer-alert-bar")
        let navButtons = app.navigationBars.buttons.allElementsBoundByIndex.filter(\.exists)
        XCTAssertFalse(navButtons.isEmpty, "这一页没有导航栏按钮，验不了遮挡")
        for button in navButtons {
            XCTAssertFalse(bar.frame.intersects(button.frame), "常驻红条挡住了导航栏按钮「\(button.label)」")
            XCTAssertTrue(button.isHittable, "导航栏按钮「\(button.label)」点不到")
        }
        bar.tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "点顶部入口没回到警报")
        walkthroughAttach(app, "W7-volunteer-alert-reopened")
    }

    // MARK: - 启动与小工具（写法同 `ScreenTourTests`；带 `walkthrough` 前缀，免得和本类别的扩展重名）

    @MainActor private func walkthroughLaunchBlind(seed: String, env: [String: String] = [:]) -> XCUIApplication {
        walkthroughLaunch(role: "blind_runner", env: [
            "AIDRUN_UI_TEST_PRESEEDED_BLIND_PROFILE": "1",
            "AIDRUN_UI_TEST_SEED_ORDER_STATUS": seed,
        ].merging(env) { _, new in new })
    }

    @MainActor private func walkthroughLaunchVolunteer(seed: String, env: [String: String] = [:]) -> XCUIApplication {
        walkthroughLaunch(role: "volunteer", env: [
            "AIDRUN_UI_TEST_PRESEEDED_VOLUNTEER_PROFILE": "1",
            "AIDRUN_MOCK_VOLUNTEER_TRAINING_COMPLETED": "1",
            "AIDRUN_UI_TEST_PRESEEDED_VOLUNTEER_AVAILABLE": "1",
            "AIDRUN_UI_TEST_PRESEEDED_VOLUNTEER_ACTIVE_ORDER": "1",
            "AIDRUN_UI_TEST_SEED_ORDER_STATUS": seed,
        ].merging(env) { _, new in new })
    }

    @MainActor private func walkthroughLaunch(role: String, env: [String: String]) -> XCUIApplication {
        let app = XCUIApplication()
        addTeardownBlock { await MainActor.run { app.terminate() } }
        app.launchEnvironment = [
            "AIDRUN_UI_TEST_RESET_STATE": "1",
            "AIDRUN_UI_TEST_RESET_TOKEN": UUID().uuidString,
            "AIDRUN_UI_TEST_BLOCK_TEL_DIAL": "1",
            "AIDRUN_UI_TEST_FORCE_DEMO_LOCATION": "1",
            "AIDRUN_UI_TEST_API_ENV": "mock",
            "AIDRUN_UI_TEST_PREFILL_PROFILE_FORM": "1",
            "AIDRUN_UI_TEST_DISABLE_WEBSOCKET": "1",
            "AIDRUN_UI_TEST_DISABLE_MAP": "1",
            "AIDRUN_UI_TEST_ACTIVE_ROLE": role,
            "AIDRUN_UI_TEST_ACCESS_TOKEN": "mock_jwt_token_for_testing",
        ].merging(env) { _, new in new }
        app.launch()
        walkthroughDismissSystemAlerts()
        return app
    }

    @MainActor private func walkthroughDismissSystemAlerts() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<3 {
            let alert = springboard.alerts.firstMatch
            guard alert.waitForExistence(timeout: 2) else { return }
            let allow = ["允许", "使用App时允许", "好", "OK", "Allow", "Allow While Using App"]
                .map { alert.buttons[$0] }
                .first { $0.exists }
            guard let allow else { return }
            allow.tap()
        }
    }

    @MainActor private func walkthroughElement(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    @MainActor private func walkthroughTapIfAppears(_ app: XCUIApplication, _ identifier: String, timeout: TimeInterval = 20) -> Bool {
        let target = walkthroughElement(app, identifier)
        guard target.waitForExistence(timeout: timeout) else { return false }
        target.tap()
        return true
    }

    @MainActor private func walkthroughTapTab(_ app: XCUIApplication, _ title: String) {
        let bar = app.tabBars.firstMatch
        let button = bar.waitForExistence(timeout: 20) ? bar.buttons[title] : app.buttons[title].firstMatch
        if button.waitForExistence(timeout: 5) { button.tap() } else { XCTFail("标签「\(title)」不在") }
    }

    /// SwiftUI 不渲染屏外的行：先上划找，找到且点得到才返回。
    @MainActor private func walkthroughScrollTo(_ app: XCUIApplication, _ target: XCUIElement) -> XCUIElement? {
        for attempt in 0..<8 {
            if target.waitForExistence(timeout: attempt == 0 ? 10 : 1), target.isHittable { return target }
            app.swipeUp()
        }
        return nil
    }

    @MainActor private func walkthroughAttach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// 无障碍树里排在最前、带读屏文字的 10 个元素，按树序。有文字的容器算一个元素，不再往下数它的子元素。
    @MainActor private func walkthroughRecordA11yOrder(_ app: XCUIApplication, _ name: String) {
        guard let root = try? app.snapshot() else { return }
        var labels: [String] = []
        func visit(_ node: XCUIElementSnapshot) {
            guard labels.count < 10 else { return }
            if !node.label.isEmpty, node.elementType != .application, node.elementType != .window {
                labels.append("[\(node.elementType.rawValue)] \(node.label)")
                return
            }
            node.children.forEach(visit)
        }
        visit(root)
        let attachment = XCTAttachment(string: labels.joined(separator: "\n"))
        attachment.name = name + "-a11y-order"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
