import XCTest

/// #1028：订单页上的前台通知横幅点「关闭」要消失，到点（`notificationDuration` 5 秒）也要自己消失。
///
/// 首页的同类用例（`testForegroundBannerDismissReachesWellBelowItsTextLine`）一直是绿的，订单页却关不掉：
/// 横幅挂在 `ContentView` 上，而 `ContentView` 没订阅 `realtimeCoordinator`，订单页上没有别的东西让它重画。
/// 两端订单页各一条。陪跑员端冷启动直接落在跑步中页，`AIDRUN_UI_TEST_REALTIME_PRIORITY` 推一条普通、一条高优先级。
extension blindRunUITests {
    /// 跑者端：横幅要在订单页上出现才验得到（启动时那两条到点就自己走了，等不到订单页）。
    /// 借 `AIDRUN_UI_TEST_VOLUNTEER_LOST_AFTER_SECONDS`：已到达的单 12 秒后被转走，订单页上弹一条横幅。
    /// 这里只验「不碰它，到点自己消失」；同一页上「点关闭」由 `testWalk_MidRunDepartureRematchPage` 验。
    @MainActor
    func testRunnerOrderPageBannerTimesOut() {
        let app = launchApp(
            apiEnvironment: "mock",
            accessToken: "mock_jwt_token_for_testing",
            activeRole: "blind_runner",
            preseedBlindProfile: true,
            seedOrderStatus: "DRIVER_ARRIVED"
        )
        // 开关只给这一条用：不往 `launchApp` 加参数（那个函数已超长），带上开关重启一次。
        app.terminate()
        app.launchEnvironment["AIDRUN_UI_TEST_VOLUNTEER_LOST_AFTER_SECONDS"] = "12"
        app.launch()
        let card = app.descendants(matching: .any)["blindRunnerHomeOrderCard"].firstMatch
        if card.waitForExistence(timeout: 10) { card.tap() }
        let banner = app.descendants(matching: .any)["realtimeForegroundNotification"].firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 30), "前提：订单页上没有横幅")
        attachScreenshot(named: "runner-order-page-banner", app: app)
        let timedOut = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: banner)
        wait(for: [timedOut], timeout: 9)
        attachScreenshot(named: "runner-order-page-banner-after", app: app)
    }

    @MainActor
    func testVolunteerOrderPageBannerClosesOnTapAndTimesOut() {
        let app = launchApp(
            apiEnvironment: "mock",
            accessToken: "mock_jwt_token_for_testing",
            activeRole: "volunteer",
            preseedVolunteerProfile: true,
            preseedVolunteerAvailable: true,
            preseedVolunteerActiveOrder: true,
            seedOrderStatus: "IN_PROGRESS",
            realtimePriorityTest: true
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["volunteerRunningStatsCard"].firstMatch.waitForExistence(timeout: 25),
            "前提：冷启动没有直接进陪跑员跑步中页"
        )
        assertOrderPageBannerClosesAndTimesOut(app)
    }

    /// 高优先级那条点「关闭」后 2 秒内消失；接着露出的普通那条不碰它，5 秒加余量内自己消失。
    @MainActor
    private func assertOrderPageBannerClosesAndTimesOut(_ app: XCUIApplication) {
        let banner = app.descendants(matching: .any)["realtimeForegroundNotification"].firstMatch
        let highPriority = app.staticTexts["高优先级前台通知"]
        XCTAssertTrue(banner.waitForExistence(timeout: 15), "前提：订单页上没有横幅")
        XCTAssertTrue(highPriority.waitForExistence(timeout: 5), "前提：高优先级那条没顶上来")
        attachScreenshot(named: "order-page-banner-before-close", app: app)

        // 「关闭」不在无障碍树里（整条横幅合成一个元素），按坐标点，写法同首页那条用例。
        banner.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: banner.frame.width - 46, dy: 48)).tap()
        let closed = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: highPriority)
        wait(for: [closed], timeout: 2)

        let normal = app.staticTexts["普通前台通知"]
        XCTAssertTrue(normal.waitForExistence(timeout: 2), "前提：关掉高优先级后普通那条要顶上来，否则验不到「到点消失」")
        let timedOut = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: normal)
        wait(for: [timedOut], timeout: 9)
        XCTAssertFalse(banner.exists, "横幅到点没有自己消失")
        attachScreenshot(named: "order-page-banner-after", app: app)
    }

}
