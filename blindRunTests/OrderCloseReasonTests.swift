import XCTest
@testable import blindRun

/// 跑者端结束原因、重新匹配、最晚结果时刻、晚到几分钟（#1021，关 #653）。
/// ⚠️ 本文件在仓库里只编译过；单测只能真机跑（高德没有 arm64-sim slice），PR 交接里如实写「单测未实跑」。
final class OrderCloseReasonTests: XCTestCase, BlindRunTestSupport {

    /// 后端 #1047 表里每个值属于哪个终态。
    private static let table: [(OrderCloseReason, RunOrderStatus)] = [
        (.finishedBlindConfirmed, .completed), (.finishedByVolunteer, .completed),
        (.finishedByVolunteerUnconfirmed, .completed), (.finishedByBlindVolunteerOffline, .completed),
        (.autoCompleted, .completed), (.csCompleted, .completed),
        (.blindCancelled, .cancelled), (.blindCancelledAfterArrival, .cancelled), (.blindNoShow, .cancelled),
        (.matchTimeout, .cancelled), (.rematchLimitReached, .cancelled), (.emergencyUnresolved, .cancelled),
        (.csCancelled, .cancelled), (.startTimeLongPassed, .cancelled), (.systemForceClosed, .cancelled),
        (.accountSuspended, .cancelled),
        (.dispatchWindowExpired, .noVolunteer), (.introCallWindowTooShort, .noVolunteer),
        (.introCallFailedWindowTooShort, .noVolunteer), (.introCallRoundsExhausted, .noVolunteer),
        (.startTimeLongPassed, .noVolunteer),
    ]

    private func decode(_ extra: String) throws -> OrderDetailResponse {
        let json = "{\"orderId\":1,\"status\":\"CANCELLED\"\(extra)}"
        return try JSONDecoder().decode(OrderDetailResponse.self, from: Data(json.utf8))
    }

    // MARK: - 解码

    func testKnownReasonAndClosedByDecode() throws {
        let order = try decode(",\"closeReason\":\"MATCH_TIMEOUT\",\"closedBy\":\"SYSTEM\"")
        XCTAssertEqual(order.closeReason, .matchTimeout)
        XCTAssertEqual(order.closedBy, .system)
    }

    /// 后端往枚举加值：不认识的值落到 `.unknown`，整张订单照常解出来。
    func testUnknownValuesFallBackWithoutFailingTheWholeOrder() throws {
        let order = try decode(",\"closeReason\":\"SOMETHING_NEW\",\"closedBy\":\"ROBOT\"")
        XCTAssertEqual(order.closeReason, .unknown)
        XCTAssertEqual(order.closedBy, .unknown)
        XCTAssertNil(order.blindCloseReasonCopy)
    }

    /// 旧单（2026-11-25 之前）是 null，缺键、类型不对同样不许抛。
    func testNullMissingAndWrongTypeAreAllNil() throws {
        XCTAssertNil(try decode(",\"closeReason\":null,\"closedBy\":null").closeReason)
        XCTAssertNil(try decode("").closeReason)
        let wrong = try decode(",\"closeReason\":42,\"closedBy\":{\"a\":1},\"rematchedMidRun\":\"x\",\"matchResultLatestAt\":7")
        XCTAssertNil(wrong.closeReason)
        XCTAssertNil(wrong.closedBy)
        XCTAssertNil(wrong.rematchedMidRun)
        XCTAssertNil(wrong.matchResultLatestAt)
    }

    func testRematchedMidRunAndResultDeadlineDecode() throws {
        let order = try decode(",\"rematchedMidRun\":true,\"matchResultLatestAt\":\"2026-11-25T15:20:00\"")
        XCTAssertEqual(order.rematchedMidRun, true)
        XCTAssertEqual(order.matchResultLatestAt, "2026-11-25T15:20:00")
    }

    func testReplacingStatusKeepsTheNewFields() throws {
        var order = makeOrder(orderId: 1, status: .rematching)
        order.closeReason = .blindCancelled
        order.closedBy = .blind
        order.rematchedMidRun = true
        order.matchResultLatestAt = "2026-11-25T15:20:00"
        let next = order.replacingStatus(with: .rematching)
        XCTAssertEqual(next.closeReason, .blindCancelled)
        XCTAssertEqual(next.closedBy, .blind)
        XCTAssertEqual(next.rematchedMidRun, true)
        XCTAssertEqual(next.matchResultLatestAt, "2026-11-25T15:20:00")
    }

    // MARK: - 终态文案

    /// 契约表里每个值都有文案；不带英文字母（读屏会逐字母念）；两句都不空。
    func testEveryReasonHasTwoPlainSentences() throws {
        for (reason, status) in Self.table {
            let copy = try XCTUnwrap(BlindCloseReasonCopy.make(reason: reason, status: status), "\(reason) / \(status)")
            XCTAssertFalse(copy.reason.isEmpty, "\(reason)")
            XCTAssertFalse(copy.nextStep.isEmpty, "\(reason)")
            XCTAssertNil(copy.spoken.range(of: "[A-Za-z]", options: .regularExpression), "\(reason): \(copy.spoken)")
            XCTAssertTrue(copy.reason.hasSuffix("。"), "\(reason)")
            XCTAssertTrue(copy.nextStep.hasSuffix("。"), "\(reason)")
        }
    }

    /// 表之外不应有遗漏：每个非 unknown 的值都在表里出现过。
    func testTheTableCoversEveryNonUnknownReason() {
        let covered = Set(Self.table.map { $0.0.rawValue })
        for raw in ["FINISHED_BLIND_CONFIRMED", "ACCOUNT_SUSPENDED", "INTRO_CALL_ROUNDS_EXHAUSTED"] {
            XCTAssertTrue(covered.contains(raw), raw)
        }
        XCTAssertEqual(covered.count, 20)
    }

    /// 兜底终止这一单可能已经跑完：不许说「没跑成」「失败」。
    func testSystemForceClosedNeverSaysTheRunFailed() throws {
        let copy = try XCTUnwrap(BlindCloseReasonCopy.make(reason: .systemForceClosed, status: .cancelled))
        for banned in ["没跑成", "失败", "没有跑", "没跑"] {
            XCTAssertFalse(copy.spoken.contains(banned), banned)
        }
    }

    func testAccountSuspendedGivesTheSupportPath() throws {
        let copy = try XCTUnwrap(BlindCloseReasonCopy.make(reason: .accountSuspended, status: .cancelled))
        XCTAssertTrue(copy.nextStep.contains("联系客服"))
        XCTAssertTrue(copy.nextStep.contains("我的"))
    }

    /// 无声拒绝：通话没成的几种原因不说「拒绝」，也不说轮次。
    func testIntroCallReasonsDoNotRevealWhoDeclined() throws {
        for reason in [OrderCloseReason.introCallWindowTooShort, .introCallFailedWindowTooShort, .introCallRoundsExhausted] {
            let copy = try XCTUnwrap(BlindCloseReasonCopy.make(reason: reason, status: .noVolunteer))
            for banned in ["拒绝", "谈崩", "没谈成", "第几", "第 "] {
                XCTAssertFalse(copy.spoken.contains(banned), "\(reason): \(banned)")
            }
        }
    }

    /// 同一个值在两个终态里说法不同。
    func testStartTimeLongPassedDiffersByStatus() throws {
        let cancelled = try XCTUnwrap(BlindCloseReasonCopy.make(reason: .startTimeLongPassed, status: .cancelled))
        let none = try XCTUnwrap(BlindCloseReasonCopy.make(reason: .startTimeLongPassed, status: .noVolunteer))
        XCTAssertNotEqual(cancelled, none)
        XCTAssertTrue(none.reason.contains("没有找到陪跑员"))
    }

    /// 状态与原因对不上、非终态、没有原因：都当「原因不详」，不对盲人说错一句。
    func testMismatchedOrMissingReasonGivesNoCopy() {
        XCTAssertNil(BlindCloseReasonCopy.make(reason: .finishedBlindConfirmed, status: .cancelled))
        XCTAssertNil(BlindCloseReasonCopy.make(reason: .matchTimeout, status: .completed))
        XCTAssertNil(BlindCloseReasonCopy.make(reason: .blindCancelled, status: .inProgress))
        XCTAssertNil(BlindCloseReasonCopy.make(reason: nil, status: .cancelled))
        XCTAssertNil(BlindCloseReasonCopy.make(reason: .unknown, status: .cancelled))
    }

    // MARK: - 终态页读屏头

    /// 原因和下一步在头部那一个读屏元素里，紧跟状态与标题。
    func testTerminalHeaderReadsTheReasonRightAfterTheTitle() throws {
        var order = makeOrder(orderId: 1, status: .noVolunteer)
        order.closeReason = .dispatchWindowExpired
        let page = try XCTUnwrap(BlindOrderTerminalPresentation.make(order: order, logs: []))
        let label = page.headerAccessibilityLabel
        XCTAssertTrue(label.hasPrefix("\(page.eyebrow)。\(page.title)。没有陪跑员接下这次预约。"), label)
        XCTAssertTrue(label.contains("可以重新预约"))
    }

    /// 原因不详时与改版前逐字相同。
    func testTerminalHeaderIsUnchangedWithoutAReason() throws {
        let order = makeOrder(orderId: 1, status: .cancelled)
        let page = try XCTUnwrap(BlindOrderTerminalPresentation.make(order: order, logs: []))
        XCTAssertNil(page.closeCopy)
        XCTAssertEqual(page.headerAccessibilityLabel, "\(page.eyebrow)。\(page.title)")
    }

    // MARK: - 重新匹配

    private func rematchingOrder(midRun: Bool?) -> OrderDetailResponse {
        var order = makeOrder(orderId: 77, status: .rematching)
        order.rematchedMidRun = midRun
        return order
    }

    /// 出发前：先别出门；跑步途中：先停下来走到安全的地方。页面卡片、语音、重复状态三处一致。
    func testRematchingBeforeAndAfterSettingOutSayDifferentThings() throws {
        let before = rematchingOrder(midRun: false)
        XCTAssertEqual(before.rematchKind, .beforeSettingOut)
        XCTAssertEqual(before.blindRunnerRematchingTitle, "陪跑员来不了了")
        XCTAssertEqual(before.blindRunnerRematchingCard.lead, "先别出门")
        XCTAssertTrue(before.blindRunnerAnnouncementUnlessLeftAlone.contains("先别出门"))
        XCTAssertTrue(before.blindRunnerStatusAnswer.contains("先别出门"))

        let during = rematchingOrder(midRun: true)
        XCTAssertEqual(during.rematchKind, .leftAloneMidRun)
        XCTAssertTrue(during.blindRunnerRematchingCard.lead.contains("先停下来"))
        XCTAssertTrue(during.blindRunnerRematchingCard.lead.contains("安全的地方"))
        XCTAssertTrue(during.blindRunnerAnnouncementUnlessLeftAlone.contains("先停下来"))
        XCTAssertTrue(during.blindRunnerStatusAnswer.contains("走到安全的地方"))
    }

    /// 后端没给（老后端）且本机没记录：不下「别出门」，也不再出现「可以先离开这个页面」。
    func testRematchingWithUnknownTimingGivesNoCommand() {
        let order = rematchingOrder(midRun: nil)
        XCTAssertEqual(order.rematchKind, .unknownWhen)
        XCTAssertFalse(order.blindRunnerAnnouncementUnlessLeftAlone.contains("别出门"))
        XCTAssertFalse(order.blindRunnerRematchingCard.lead.contains("离开这个页面"))
    }

    /// 后端的 `rematchedMidRun` 盖过本机记录：本机记着出发后退出，后端说是出发前，就按出发前。
    func testBackendFlagBeatsTheLocalRecord() {
        let suite = "OrderCloseReasonTests.record"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let record = BlindMidRunDepartureRecord(defaults: defaults)
        let original = BlindMidRunDepartureRecord.shared
        BlindMidRunDepartureRecord.shared = record
        defer {
            BlindMidRunDepartureRecord.shared = original
            defaults.removePersistentDomain(forName: suite)
        }
        record.observe(orderID: 77, status: .inProgress)
        XCTAssertEqual(rematchingOrder(midRun: nil).rematchKind, .leftAloneMidRun)
        XCTAssertEqual(rematchingOrder(midRun: false).rematchKind, .beforeSettingOut)
    }

    /// ① 页：重新匹配的深色卡不再写「可以先离开这个页面」；排队中的 `PENDING_MATCH` 保持原样。
    func testMatchingCardsPerState() throws {
        let rematching = try XCTUnwrap(BlindOrderStagePresentation.make(order: rematchingOrder(midRun: false), canKeepWaiting: false))
        XCTAssertEqual(rematching.title, "陪跑员来不了了")
        XCTAssertEqual(rematching.cardLead, "先别出门")
        XCTAssertFalse(rematching.cardLead.contains("离开这个页面"))

        let pending = try XCTUnwrap(BlindOrderStagePresentation.make(order: makeOrder(orderId: 1, status: .pendingMatch), canKeepWaiting: false))
        XCTAssertEqual(pending.cardLead, BlindOrderStageCopy.matchingCardLead)
        XCTAssertEqual(pending.cardBody, BlindOrderStageCopy.matchingCardBody)
    }

    // MARK: - 最晚几点有结果

    func testMatchResultDeadlineIsAppendedToTheCard() throws {
        var order = makeOrder(orderId: 1, status: .pendingMatch)
        order.matchResultLatestAt = "2026-11-25T15:20:00"
        let now = try XCTUnwrap("2026-11-25T10:00:00".backendTimestamp)
        let page = try XCTUnwrap(BlindOrderStagePresentation.make(order: order, canKeepWaiting: false, now: now))
        XCTAssertEqual(page.cardBody, "\(BlindOrderStageCopy.matchingCardBody)。最晚今天下午 3 点 20 分会有结果")
    }

    func testNoDeadlineFieldShowsNothingExtra() throws {
        let page = try XCTUnwrap(BlindOrderStagePresentation.make(order: makeOrder(orderId: 1, status: .pendingMatch), canKeepWaiting: false))
        XCTAssertEqual(page.cardBody, BlindOrderStageCopy.matchingCardBody)
    }

    /// 后端只在匹配中两态下发；别的状态带着旧值也不显示。
    func testDeadlineIsIgnoredOutsideMatching() {
        var order = makeOrder(orderId: 1, status: .scheduledConfirmed)
        order.matchResultLatestAt = "2026-11-25T15:20:00"
        XCTAssertNil(order.matchResultLatestSpoken())
    }

    func testSpokenClockUsesPeriodWordsAndNoTwentyFourHour() throws {
        func spoken(_ stamp: String) throws -> String { BlindSpokenClock.text(try XCTUnwrap(stamp.backendTimestamp)) }
        XCTAssertEqual(try spoken("2026-11-25T15:20:00"), "下午 3 点 20 分")
        XCTAssertEqual(try spoken("2026-11-25T09:00:00"), "上午 9 点整")
        XCTAssertEqual(try spoken("2026-11-25T12:05:00"), "中午 12 点 5 分")
        XCTAssertEqual(try spoken("2026-11-25T19:45:00"), "晚上 7 点 45 分")
        XCTAssertEqual(try spoken("2026-11-25T00:30:00"), "凌晨 12 点 30 分")
    }

    // MARK: - 晚到几分钟

    func testLateSentenceOnlyWhenBackendSaysLate() {
        var order = makeOrder(orderId: 1, status: .driverEnRoute)
        order.eta = EtaView(remainingMinutes: 9, arriveAt: nil, deltaVsStartMinutes: 6, late: true, progress: 0.4)
        XCTAssertEqual(order.blindRunnerLateSentence, "预计比约定的时间晚到约 6 分钟。")
        XCTAssertTrue(order.blindRunnerAnnouncement().contains("晚到约 6 分钟"))

        // delta 超过 3 但后端没说 late：不自己判。
        order.eta = EtaView(remainingMinutes: 9, arriveAt: nil, deltaVsStartMinutes: 6, late: false, progress: 0.4)
        XCTAssertNil(order.blindRunnerLateSentence)
        order.eta = EtaView(remainingMinutes: 9, arriveAt: nil, deltaVsStartMinutes: nil, late: true, progress: 0.4)
        XCTAssertNil(order.blindRunnerLateSentence)
        order.eta = nil
        XCTAssertNil(order.blindRunnerLateSentence)
        XCTAssertFalse(order.blindRunnerAnnouncement().contains("晚到"))
    }

    func testLateSentenceIsIgnoredOutsideEnRoute() {
        var order = makeOrder(orderId: 1, status: .driverArrived)
        order.eta = EtaView(remainingMinutes: 0, arriveAt: nil, deltaVsStartMinutes: 6, late: true, progress: 0.8)
        XCTAssertNil(order.blindRunnerLateSentence)
    }

    // MARK: - Mock

    func testMockClosedByFollowsTheBackendTable() {
        XCTAssertEqual(MockAPIClient.mockClosedBy(for: .blindNoShow), .volunteer)
        XCTAssertEqual(MockAPIClient.mockClosedBy(for: .blindCancelledAfterArrival), .blind)
        XCTAssertEqual(MockAPIClient.mockClosedBy(for: .accountSuspended), .cs)
        XCTAssertEqual(MockAPIClient.mockClosedBy(for: .matchTimeout), .system)
    }
}
