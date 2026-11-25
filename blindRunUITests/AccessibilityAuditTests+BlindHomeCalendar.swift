import XCTest

/// 盲人首页「加入日历」（#660 B-18）：2026-11-25 起是订单卡下面一行白色列表行（稿 `blind-home-calendar-button-20261125/`）。
/// 这里只钉「有人接下的单下面有这一行、整行够大、读屏只念加入日历」，日程内容由单测 `BlindPreRunGapsTests` 钉。
extension AccessibilityAuditTests {

    @MainActor
    func testBlindHomeCalendarRowSitsUnderTheConfirmedOrder() throws {
        guard #available(iOS 17.0, *) else { throw XCTSkip("「加入日历」只在 iOS 17 及以上出现") }
        // 种子单默认把有人接下的单挪到 20 分钟前；这条要「已约好、还没到点」。
        let app = launchBlindHome(
            emptyOrders: false,
            seedOrderStatus: "SCHEDULED_CONFIRMED",
            extraEnvironment: ["AIDRUN_UI_TEST_SEED_FUTURE_START": "1"]
        )
        let card = app.descendants(matching: .any)["blindRunnerHomeOrderCard"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 20), "有订单的盲人首页没起来")

        let row = app.buttons["blindHomeAddToCalendar"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "已确认的单下面没有「加入日历」")
        XCTAssertEqual(row.label, "加入日历", "读屏要只念「加入日历」，小字和日期图标不念")
        XCTAssertGreaterThanOrEqual(row.frame.height, 63.5, "整行可点高度低于 64pt")
        XCTAssertGreaterThan(row.frame.minY, card.frame.maxY, "「加入日历」要在订单卡下面")
        attachScreenshot(app, name: "blind-home-calendar-row")
        try audit(app)
    }
}
