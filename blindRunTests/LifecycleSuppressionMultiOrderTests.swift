import XCTest
@testable import blindRun

/// #1011：生命周期横幅的压制按订单配对，首页其余几张预约跟着推送走，状态播报的去重键带订单号。
///
/// 后端这 8 种通知的信封不带 `orderId`，但每条后面都紧跟一条带 `orderId` 的 `ORDER_STATUS_CHANGED`。
/// 所以「这条通知属于哪一单」靠那条状态推送认。
@MainActor
final class LifecycleSuppressionMultiOrderTests: XCTestCase {
    private let holdDelay: TimeInterval = 0.05

    private func makeCoordinator() -> (AppRealtimeCoordinator, WebSocketService) {
        let coordinator = AppRealtimeCoordinator(notificationDuration: 60, lifecycleHoldDelay: holdDelay)
        let service = WebSocketService()
        coordinator.attach(to: service, role: .blind)
        return (coordinator, service)
    }

    private func notification(_ eventType: String, body: String, id: Int64 = 1) -> WSAppNotification {
        WSAppNotification(
            type: WSMessageType.appNotification.rawValue, eventId: id, eventType: eventType,
            title: nil, body: body, ttsText: body, priority: "HIGH", timestamp: "2026-11-25T12:00:00Z"
        )
    }

    private func statusEvent(order: Int64, from: String, to: String, id: String) -> WSOrderStatusChanged {
        WSOrderStatusChanged(
            type: WSMessageType.orderStatusChanged.rawValue, messageId: id, orderId: order,
            fromStatus: from, toStatus: to, message: nil, ttsText: nil, priority: "NORMAL",
            timestamp: "2026-11-25T12:00:00Z"
        )
    }

    private func settle() async {
        try? await Task.sleep(nanoseconds: UInt64(holdDelay * 4 * 1_000_000_000))
    }

    /// 两张活跃订单，通知属于第二张：第二张的状态推送到了（订单页 / 首页会播）⇒ 这条横幅只压一次，不重复。
    func testNotificationOfSecondActiveOrderIsPairedWithItsOwnStatusUpdate() async {
        let (coordinator, service) = makeCoordinator()
        coordinator.registerActiveOrder(1, status: .driverEnRoute)
        coordinator.registerActiveOrder(2, status: .pendingMatch)

        service.simulateIncomingEventForTesting(.notification(notification("ORDER_AUTO_CANCELLED", body: "订单已取消")))
        service.simulateIncomingEventForTesting(.orderStatusChanged(statusEvent(
            order: 2, from: "PENDING_MATCH", to: "CANCELLED", id: "A0000000-0000-4000-8000-000000000002"
        )))
        await settle()

        XCTAssertNil(coordinator.currentNotification, "配上了第二张的状态推送，页面会播，横幅不该再弹一遍")
    }

    /// 通知属于一张没人跟着的单（第二张只有通知、没有登记过的状态推送）⇒ 不再被第一张的存在吞掉。
    func testNotificationOfAnOrderNobodyIsFollowingStillAppears() async {
        let (coordinator, service) = makeCoordinator()
        coordinator.registerActiveOrder(1, status: .driverEnRoute)
        coordinator.registerActiveOrder(2, status: .pendingMatch)

        // 只有第一张有状态推送（→ COMPLETED），这条 CANCELLED 通知不属于它。
        service.simulateIncomingEventForTesting(.notification(notification("ORDER_AUTO_CANCELLED", body: "订单已取消")))
        service.simulateIncomingEventForTesting(.orderStatusChanged(statusEvent(
            order: 1, from: "DRIVER_EN_ROUTE", to: "COMPLETED", id: "A0000000-0000-4000-8000-000000000001"
        )))
        await settle()

        XCTAssertEqual(coordinator.currentNotification?.displayText, "订单已取消", "属于别的订单的通知必须照常弹出")
    }

    /// 没有任何登记的单可能迁到这个状态 ⇒ 立刻弹，不扣。
    func testNotificationShowsImmediatelyWhenNoTrackedOrderCouldOwnIt() async {
        let (coordinator, service) = makeCoordinator()
        coordinator.registerActiveOrder(1, status: .inProgress)

        service.simulateIncomingEventForTesting(.notification(notification("ORDER_ACCEPTED", body: "已匹配到陪跑员")))
        await Task.yield()

        XCTAssertEqual(coordinator.currentNotification?.displayText, "已匹配到陪跑员",
                       "进行中的单不可能被『接单』，这条属于别的单，不能等")
    }

    /// 陪跑员手上有一张进行中的单，另一张预约被盲人取消：通知没有对应的状态推送 ⇒ 到点照弹。
    func testVolunteerWithOneActiveOrderStillGetsOtherBookingCancelledBanner() async {
        let (coordinator, service) = makeCoordinator()
        coordinator.registerActiveOrder(1, status: .driverArrived)

        service.simulateIncomingEventForTesting(.notification(notification("ORDER_CANCELLED_BY_BLIND", body: "对方已取消预约")))
        await settle()

        XCTAssertEqual(coordinator.currentNotification?.displayText, "对方已取消预约")
    }

    /// 通知带了 `orderId` 且不是登记的单 ⇒ 立刻弹。
    func testNotificationWithForeignOrderIdIsNotHeld() async {
        let (coordinator, service) = makeCoordinator()
        coordinator.registerActiveOrder(1, status: .driverEnRoute)
        let message = WSAppNotification(
            type: WSMessageType.appNotification.rawValue, eventId: 5, eventType: "ORDER_CANCELLED_BY_BLIND",
            title: nil, body: "对方已取消预约", ttsText: nil, priority: "HIGH", timestamp: nil, orderId: 99
        )

        service.simulateIncomingEventForTesting(.notification(message))
        await Task.yield()

        XCTAssertEqual(coordinator.currentNotification?.displayText, "对方已取消预约")
    }

    /// 一条状态推送只压一条横幅：同一状态来了第二条通知（属于另一单）要弹。
    func testOneStatusUpdateSuppressesAtMostOneBanner() async {
        let (coordinator, service) = makeCoordinator()
        coordinator.registerActiveOrder(1, status: .pendingMatch)
        coordinator.registerActiveOrder(2, status: .pendingMatch)

        service.simulateIncomingEventForTesting(.orderStatusChanged(statusEvent(
            order: 2, from: "PENDING_MATCH", to: "CANCELLED", id: "A0000000-0000-4000-8000-000000000022"
        )))
        service.simulateIncomingEventForTesting(.notification(notification("ORDER_AUTO_CANCELLED", body: "第二张取消", id: 1)))
        service.simulateIncomingEventForTesting(.notification(notification("ORDER_AUTO_CANCELLED", body: "第一张取消", id: 2)))
        await settle()

        XCTAssertEqual(coordinator.currentNotification?.displayText, "第一张取消")
    }

    // MARK: - 第 4 条：去重键

    /// 先取消 A 再取消 B：两句都要念。改前（只比状态）第二句被吞。
    func testSecondOrdersCancelledAnnouncementIsNotDeduplicatedAgainstTheFirst() {
        let speech = SpeechService()

        XCTAssertTrue(speech.speakStatusChange(.cancelled, text: "预约已取消", orderID: 1))
        XCTAssertTrue(speech.speakStatusChange(.cancelled, text: "预约已取消", orderID: 2), "另一张单的同一状态不是重复")
        XCTAssertFalse(speech.speakStatusChange(.cancelled, text: "预约已取消", orderID: 2), "同一张单同一状态仍然只念一次")
    }

    /// 老调用方不带订单号：行为不变，仍按状态去重。
    func testStatusDeduplicationWithoutOrderIDKeepsOldBehaviour() {
        let speech = SpeechService()

        XCTAssertTrue(speech.speakStatusChange(.cancelled, text: "已取消"))
        XCTAssertFalse(speech.speakStatusChange(.cancelled, text: "已取消", orderID: 3))
    }

    // MARK: - 首页其余几张

    /// 第 2 张的状态推送到了：卡片更新，并且出声（带开跑时间或「另一张预约」）。
    func testHomeUpdatesAndSpeaksForSecondOrderRealtimeStatus() {
        let speech = SpeechService()
        let appState = AppState(safety: FakeSafetyService(), orders: FakeOrderService())
        appState.currentEnvironment = .mock
        let viewModel = BlindRunnerHomeViewModel()
        viewModel.configure(with: appState, speechService: speech)
        viewModel.activeOrder = .preview(orderId: 1, status: .pendingAccept)
        viewModel.otherOrders = [.preview(orderId: 2, status: .pendingMatch), .preview(orderId: 3, status: .pendingMatch)]
        viewModel.syncOtherOrderRegistration(appState: appState)

        XCTAssertTrue(appState.realtimeCoordinator.registeredActiveOrderIDsForTesting.isSuperset(of: [2, 3]))

        appState.realtimeCoordinator.simulateIncomingEventForTesting(.orderStatusChanged(statusEvent(
            order: 3, from: "PENDING_MATCH", to: "PENDING_ACCEPT", id: "B0000000-0000-4000-8000-000000000003"
        )))

        XCTAssertEqual(viewModel.otherOrders.first { $0.orderId == 3 }?.status, .pendingAccept)
        XCTAssertEqual(viewModel.otherOrders.first { $0.orderId == 2 }?.status, .pendingMatch)
        XCTAssertEqual(speech.spokenHistoryForTesting.count, 1)

        appState.realtimeCoordinator.simulateIncomingEventForTesting(.orderStatusChanged(statusEvent(
            order: 2, from: "PENDING_MATCH", to: "CANCELLED", id: "B0000000-0000-4000-8000-000000000002"
        )))
        XCTAssertNil(viewModel.otherOrders.first { $0.orderId == 2 }, "取消的预约卡要撤下")
        XCTAssertEqual(speech.spokenHistoryForTesting.count, 2, "第二张被取消也要念，不被去重键吞掉")
        XCTAssertFalse(appState.realtimeCoordinator.registeredActiveOrderIDsForTesting.contains(2))
    }
}
