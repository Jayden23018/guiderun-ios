import XCTest

/// #1046：附近没有陪跑员时约跑页的提示卡。Mock 用 `AIDRUN_MOCK_NEARBY_VOLUNTEERS=none`。
@MainActor
extension AccessibilityAuditTests {

    func testBookingNearbyVolunteersCardComesFirstAndPassesAuditInLightAndDark() throws {
        guard #available(iOS 17.0, *) else {
            throw XCTSkip("performAccessibilityAudit 需要 iOS 17+ 运行时")
        }
        for scheme in ["light", "dark"] {
            let app = openBookingWithNobodyNearby(extraEnvironment: ["AIDRUN_UI_TEST_COLOR_SCHEME": scheme])
            let card = app.descendants(matching: .any)["matchFirstNearbyVolunteersNotice"].firstMatch
            XCTAssertTrue(card.waitForExistence(timeout: 15), "附近没人时没有提示卡")
            XCTAssertTrue(card.label.hasPrefix("提示，目前附近无志愿者。"), card.label)
            XCTAssertTrue(card.label.contains("公里内暂时没有可接单的陪跑员"), "卡片没读后端那句：\(card.label)")

            let change = app.buttons["matchFirstNearbyVolunteersChangeStart"].firstMatch
            XCTAssertTrue(change.exists, "卡内没有「换个出发点」")
            XCTAssertGreaterThanOrEqual(change.frame.height, Self.minimumBlindPrimaryButtonHeight)
            XCTAssertTrue(app.buttons["matchFirstSubmitButton"].firstMatch.isEnabled, "提示卡不许拦下单")

            // 无障碍树的先序遍历：标题 → 卡片 → 按钮 → 出发点圆排，标题和卡片之间没有别的可读元素。
            let order = readingOrder(of: try app.snapshot())
            let heading = try XCTUnwrap(order.firstIndex(of: "从哪出发？"), "树里没有标题：\(order)")
            let tail = Array(order[heading...].prefix(8))
            XCTAssertEqual(tail.dropFirst().first, "matchFirstNearbyVolunteersNotice", "标题后第一个不是提示卡：\(tail)")
            let changeIndex = try XCTUnwrap(order.firstIndex(of: "matchFirstNearbyVolunteersChangeStart"), "\(tail)")
            let currentIndex = try XCTUnwrap(order.firstIndex(of: "matchFirstStartCurrent"), "\(tail)")
            XCTAssertLessThan(changeIndex, currentIndex, "按钮应当排在出发点圆排之前：\(tail)")
            print("NEARBY_READING_ORDER \(scheme): \(tail)")

            attachScreenshot(app, name: "nearby-none-\(scheme)")
            try audit(app)
            app.terminate()
        }
    }

    /// 这一单选着常用地点时，从提示卡进添加页选「使用当前定位」（默认本来就是它），约跑页要跟着换回当前定位。
    func testBookingChangeStartPlaceFollowsThePickEvenWhenTheDefaultDoesNotChange() {
        let app = openBookingWithNobodyNearby(extraEnvironment: ["AIDRUN_UI_TEST_SEED_HOME_FAVORITE": "1"])
        let favorite = app.buttons["matchFirstStartFavorite_0"].firstMatch
        XCTAssertTrue(favorite.waitForExistence(timeout: 10), "约跑页没有收藏的圆")
        let current = app.buttons["matchFirstStartCurrent"].firstMatch
        XCTAssertTrue(current.label.contains("这次从这里出发"), "进页应当选着当前定位：\(current.label)")

        favorite.tap()
        XCTAssertTrue(favorite.label.contains("这次从这里出发"), "点常用地点没选上：\(favorite.label)")
        XCTAssertFalse(current.label.contains("这次从这里出发"), current.label)

        let change = app.buttons["matchFirstNearbyVolunteersChangeStart"].firstMatch
        XCTAssertTrue(change.waitForExistence(timeout: 15), "换了出发点后没有提示卡")
        change.tap()
        let useCurrent = app.buttons["blindFavoritePlaceUseCurrentLocation"].firstMatch
        XCTAssertTrue(useCurrent.waitForExistence(timeout: 10), "没进添加地点页")
        useCurrent.tap()

        XCTAssertTrue(waitForBookingScreen(app), "没退回约跑页")
        let followed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "这次从这里出发"), object: current
        )
        XCTAssertEqual(XCTWaiter().wait(for: [followed], timeout: 10), .completed, "约跑页没跟着换回当前定位：\(current.label)")
        attachScreenshot(app, name: "nearby-change-start-back-to-current")
    }

    private func openBookingWithNobodyNearby(extraEnvironment: [String: String]) -> XCUIApplication {
        let environment = extraEnvironment.merging(["AIDRUN_MOCK_NEARBY_VOLUNTEERS": "none"]) { _, new in new }
        let app = launchBlindHome(extraEnvironment: environment)
        let start = app.descendants(matching: .any)["blindRunnerHomeStartBookingButton"].firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 20), "盲人首页没起来")
        start.tap()
        XCTAssertTrue(waitForBookingScreen(app), "约跑页没起来")
        return app
    }

    /// 有 identifier 的记 identifier，否则记 label；两样都空的容器跳过。
    private func readingOrder(of snapshot: XCUIElementSnapshot) -> [String] {
        let name = snapshot.identifier.isEmpty ? snapshot.label : snapshot.identifier
        let own = name.isEmpty || name == "matchFirstBookingPage" ? [] : [name]
        return own + snapshot.children.flatMap { readingOrder(of: $0) }
    }
}
