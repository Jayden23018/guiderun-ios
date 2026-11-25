import XCTest
@testable import blindRun

/// 结束前确认跑者安全（后端 #902，iOS #1016）。issue 的 7 条完成标准逐条对应下面几组用例：
/// ① 闸关着行为不变 ② 陪跑员请求与单方面结束 ③ 跑者确认按钮与冷启动 ④ 请求作废 ⑤ 完成后求助窗口 ⑥ Mock 开闸 / 关闸。
@MainActor
final class FinishSafetyConfirmationTests: XCTestCase {

    // MARK: - ① 闸关着：响应解码与陪跑员页行为不变

    func testFinishResponseWithoutCompletedKeyCountsAsCompleted() throws {
        let decoded = try JSONDecoder().decode(FinishOrderResponse.self, from: Data(#"{"success":true,"orderId":1}"#.utf8))
        XCTAssertTrue(decoded.completed, "闸关着的旧形状必须当成已完成，否则陪跑员会停在等对方确认上")
    }

    func testFinishResponseDecodesTheRequestShape() throws {
        let json = #"{"success":true,"orderId":1,"completed":false,"unilateralFinishOpensAt":"2026-11-25T10:10:00"}"#
        let decoded = try JSONDecoder().decode(FinishOrderResponse.self, from: Data(json.utf8))
        XCTAssertFalse(decoded.completed)
        XCTAssertEqual(decoded.unilateralFinishOpensAt, "2026-11-25T10:10:00")
    }

    func testClosedGateFinishStillGoesThroughTheStatusConfirmationPath() async throws {
        let (viewModel, service) = try makeVolunteer(detail: Self.order(status: "IN_PROGRESS"))
        service.finishResult = .success(FinishOrderResponse(completed: true))

        await viewModel.complete()

        XCTAssertEqual(viewModel.transitionState.targetStatus, .completed, "闸关着时与改动前一样等状态确认")
        XCTAssertNil(viewModel.order?.unilateralFinishOpensAt)
    }

    // MARK: - ② 陪跑员：请求、到点前 409、提示卡

    func testOpenGateFirstPressRecordsTheBackendTimeInsteadOfAwaitingCompletion() async throws {
        let opensAt = "2026-11-25T10:10:00"
        let (viewModel, service) = try makeVolunteer(
            detail: Self.order(status: "IN_PROGRESS", extra: #","unilateralFinishOpensAt":"\#(opensAt)""#)
        )
        service.finishResult = .success(FinishOrderResponse(completed: false, unilateralFinishOpensAt: opensAt))

        await viewModel.complete()

        XCTAssertEqual(viewModel.transitionState, .idle, "只记了请求：不能进「已提交，正在确认状态」")
        XCTAssertFalse(viewModel.isTransitionPending, "按钮不能被锁住，到点后还要再按一次")
        XCTAssertEqual(viewModel.order?.unilateralFinishOpensAt, opensAt, "时刻用后端给的，不自己加分钟数")
        XCTAssertGreaterThanOrEqual(service.callCount("orderDetail(orderId:)"), 1, "要重拉一次详情对齐")
    }

    func testPressBeforeTheUnilateralTimeSpeaksTheBackendMessage() async throws {
        let (viewModel, service) = try makeVolunteer(detail: Self.order(status: "IN_PROGRESS"))
        let message = "已请对方确认是否在安全的地方，请等对方确认；若一直联系不上，10:10之后可以直接结束"
        service.finishResult = .failure(APIError.serverError(
            ErrorResponse(code: "BLIND_SAFETY_CONFIRMATION_PENDING", message: message)
        ))

        await viewModel.complete()

        XCTAssertEqual(ErrorCode(rawValue: "BLIND_SAFETY_CONFIRMATION_PENDING"), .blindSafetyConfirmationPending)
        XCTAssertEqual(viewModel.errorMessage, message, "后端 message 带着时刻，必须照念")
    }

    func testVolunteerNoticeFollowsTheBackendUnilateralTime() throws {
        let opensAt = Date().addingTimeInterval(600)
        let order = try Self.order(status: "IN_PROGRESS", extra: #","unilateralFinishOpensAt":"\#(Self.stamp(opensAt))""#)

        let waiting = VolunteerFinishSafetyNotice.resolve(order: order, now: opensAt.addingTimeInterval(-1))
        let open = VolunteerFinishSafetyNotice.resolve(order: order, now: opensAt.addingTimeInterval(1))

        XCTAssertEqual(waiting?.canFinishNow, false)
        XCTAssertTrue(waiting?.text.contains(DateFormatter.aidRunDisplayClock.string(from: opensAt)) == true)
        XCTAssertEqual(open?.canFinishNow, true)
        XCTAssertNil(VolunteerFinishSafetyNotice.resolve(order: try Self.order(status: "IN_PROGRESS"), now: Date()))
    }

    // MARK: - ③ 跑者：确认按钮、冷启动播报、确认请求

    func testRunnerSeesTheConfirmButtonOnlyWhileInProgressWithARequest() throws {
        let pending = #","finishRequestedAt":"2026-11-25T10:00:00""#
        XCTAssertTrue(try Self.order(status: "IN_PROGRESS", extra: pending).isAwaitingBlindSafetyConfirmation)
        XCTAssertFalse(try Self.order(status: "IN_PROGRESS").isAwaitingBlindSafetyConfirmation)
        XCTAssertFalse(
            try Self.order(status: "IN_PROGRESS", extra: pending).replacingStatus(with: .completed).isAwaitingBlindSafetyConfirmation,
            "状态推到完成时旧的请求时刻被带过去，按钮不能跟着留下"
        )
    }

    func testRequestTimesSurviveAStatusPushBetweenPolls() throws {
        let order = try Self.order(
            status: "IN_PROGRESS",
            extra: #","finishRequestedAt":"2026-11-25T10:00:00","unilateralFinishOpensAt":"2026-11-25T10:10:00""#
        )
        let replaced = order.replacingStatus(with: .inProgress)
        XCTAssertEqual(replaced.finishRequestedAt, "2026-11-25T10:00:00")
        XCTAssertEqual(replaced.unilateralFinishOpensAt, "2026-11-25T10:10:00")
    }

    func testColdStartSpeaksThePendingRequestOnceButNotOnLaterPolls() throws {
        let pending = try Self.order(status: "IN_PROGRESS", extra: #","finishRequestedAt":"2026-11-25T10:00:00""#)
        typealias VM = BlindOrderStatusViewModel

        XCTAssertTrue(VM.announcesFinishRequestOnLoad(previousStatus: nil, updated: pending, speakChanges: true),
                      "杀掉重开的跑者要听得到确认按钮")
        XCTAssertFalse(VM.announcesFinishRequestOnLoad(previousStatus: .inProgress, updated: pending, speakChanges: true),
                       "页面开着时由全局横幅念，轮询不再念第二遍")
        XCTAssertFalse(VM.announcesFinishRequestOnLoad(previousStatus: nil, updated: try Self.order(status: "IN_PROGRESS"),
                                                       speakChanges: true))
        XCTAssertTrue(FinishSafetyCopy.blindStatusSuffix.contains(FinishSafetyCopy.blindConfirmButton))
    }

    func testRunnerConfirmCallsConfirmSafeOnce() async throws {
        let service = FakeOrderService()
        service.confirmSafeResult = .success(())
        service.orderDetailResult = .success(try Self.order(status: "COMPLETED"))
        let appState = AppState(orders: service)
        retainedAppState = appState
        let viewModel = BlindOrderStatusViewModel()
        viewModel.configure(appState: appState, speechService: SpeechService())
        viewModel.order = try Self.order(status: "IN_PROGRESS", extra: #","finishRequestedAt":"2026-11-25T10:00:00""#)

        await viewModel.confirmSafe()

        XCTAssertEqual(service.callCount("confirmSafe(orderId:)"), 1)
        XCTAssertEqual(service.lastOrderId, 4_902)
    }

    func testRunnerConfirmDoesNothingWithoutARequest() async throws {
        let service = FakeOrderService()
        let appState = AppState(orders: service)
        retainedAppState = appState
        let viewModel = BlindOrderStatusViewModel()
        viewModel.configure(appState: appState, speechService: SpeechService())
        viewModel.order = try Self.order(status: "IN_PROGRESS")

        await viewModel.confirmSafe()

        XCTAssertEqual(service.callCount("confirmSafe(orderId:)"), 0)
    }

    func testRealtimeRequestIsASafetyNoticeThatRefreshesTheOrder() {
        let type = AppRealtimeCoordinator.finishSafetyConfirmRequestedEventType
        XCTAssertEqual(type, "FINISH_SAFETY_CONFIRM_REQUESTED")
        XCTAssertTrue(AppRealtimeCoordinator.isSafetyEventType(type), "要在任何页面抢占播报")
        XCTAssertTrue(AppRealtimeCoordinator.orderRefreshingEventTypes.contains(type), "确认按钮靠重拉详情出现")
        XCTAssertNil(AppRealtimeCoordinator.lifecycleStatus(forEventType: type), "进生命周期表会被有活跃订单时整条吞掉")
    }

    // MARK: - ⑤ 完成后求助窗口

    func testRunnerHelpStaysOnTheCloudUntilThePostFinishWindowEnds() throws {
        let until = Date().addingTimeInterval(600)
        let order = try Self.order(status: "COMPLETED", extra: #","sosWindowEndsAt":"\#(Self.stamp(until))""#)

        XCTAssertEqual(BlindHomeSOSMode.resolve(order: order, role: .blind, now: until.addingTimeInterval(-1)), .cloudTrigger)
        XCTAssertEqual(BlindHomeSOSMode.resolve(order: order, role: .blind, now: until.addingTimeInterval(1)), .localCall)
        XCTAssertEqual(
            BlindHomeSOSMode.resolve(order: order, role: .blind, isSessionExpired: true, now: until.addingTimeInterval(-1)),
            .localCallSessionExpired
        )
        XCTAssertFalse(order.canTriggerEmergency(as: .volunteer, now: until.addingTimeInterval(-1)), "陪跑员仍只在跑步中")
        XCTAssertEqual(
            BlindHomeSOSMode.resolve(order: try Self.order(status: "COMPLETED"), role: .blind),
            .localCall,
            "没有窗口字段（闸关着的旧后端）时与改动前一样"
        )
    }

    // MARK: - ④ ⑥ Mock：关闸、开闸、单方面结束、确认、作废

    func testMockClosedGateFinishesAtOnce() async throws {
        let (mock, orders) = makeMock(timeout: 0, role: .volunteer)

        let response = try await orders.finish(orderId: Self.mockOrderId)

        XCTAssertTrue(response.completed)
        XCTAssertEqual(mock.orders.first?.status, .completed)
    }

    func testMockOpenGateRequestsThenRejectsThenFinishesUnilaterally() async throws {
        let (mock, orders) = makeMock(timeout: 10, role: .volunteer)

        let first = try await orders.finish(orderId: Self.mockOrderId)
        XCTAssertFalse(first.completed)
        XCTAssertNotNil(first.unilateralFinishOpensAt)
        XCTAssertNotNil(mock.orders.first?.finishRequestedAt)
        XCTAssertEqual(mock.orders.first?.status, .inProgress)

        do {
            _ = try await orders.finish(orderId: Self.mockOrderId)
            XCTFail("到点前再按应回 409")
        } catch let error as APIError {
            XCTAssertEqual(error.errorCode, .blindSafetyConfirmationPending)
        }

        // 不靠睡眠：把请求时刻拨到超时之前、作废之前（计时测试在慢设备上会越过作废点）。
        mock.finishRequestTimes[Self.mockOrderId] = Date().addingTimeInterval(-11)
        let last = try await orders.finish(orderId: Self.mockOrderId)
        XCTAssertTrue(last.completed)
        XCTAssertEqual(mock.orders.first?.status, .completed)
    }

    func testMockRunnerConfirmCompletesAndOpensThePostFinishWindow() async throws {
        let (mock, orders) = makeMock(timeout: 60, role: .blind)
        _ = try mock.simulateVolunteerFinishForTesting(orderId: Self.mockOrderId)
        XCTAssertNil(mock.orders.first?.unilateralFinishOpensAt, "这个时刻后端只给陪跑员")

        try await orders.confirmSafe(orderId: Self.mockOrderId)

        let order = try XCTUnwrap(mock.orders.first)
        XCTAssertEqual(order.status, .completed)
        XCTAssertTrue(order.isWithinPostFinishSOSWindow(now: Date()))
    }

    func testMockRequestExpiresAndTheButtonGoesAway() async throws {
        let (mock, orders) = makeMock(timeout: 10, role: .blind)
        _ = try mock.simulateVolunteerFinishForTesting(orderId: Self.mockOrderId)

        mock.finishRequestTimes[Self.mockOrderId] = Date().addingTimeInterval(-21) // 过了 2 × 超时
        let detail = try await orders.orderDetail(orderId: Self.mockOrderId)

        XCTAssertNil(detail.finishRequestedAt, "请求在 2 × 超时后作废")
        XCTAssertFalse(detail.isAwaitingBlindSafetyConfirmation)
        XCTAssertEqual(detail.status, .inProgress)
    }

    func testMockRunnerFinishIsNeverGated() async throws {
        let (mock, orders) = makeMock(timeout: 60, role: .blind)

        let response = try await orders.finish(orderId: Self.mockOrderId)

        XCTAssertTrue(response.completed, "跑者结束（陪跑员掉线时）后端不走确认闸")
        XCTAssertEqual(mock.orders.first?.status, .completed)
    }

    // MARK: - Fixture

    private var retainedAppState: AppState?
    private static let mockOrderId: Int64 = 4_902

    private func makeVolunteer(detail: OrderDetailResponse) throws -> (VolunteerInServiceViewModel, FakeOrderService) {
        let service = FakeOrderService()
        service.orderDetailResult = .success(detail)
        let appState = AppState(orders: service)
        retainedAppState = appState
        let viewModel = VolunteerInServiceViewModel()
        viewModel.configure(with: appState, speechService: SpeechService(), initialOrder: try Self.order(status: "IN_PROGRESS"))
        return (viewModel, service)
    }

    private func makeMock(timeout: TimeInterval, role: UserRole) -> (MockAPIClient, OrderService) {
        let mock = MockAPIClient()
        mock.mockRole = role
        mock.finishBlindConfirmTimeout = timeout
        mock.orders = [.preview(orderId: Self.mockOrderId, status: .inProgress)]
        return (mock, OrderService(transport: mock))
    }

    private static func order(status: String, extra: String = "") throws -> OrderDetailResponse {
        try JSONDecoder().decode(
            OrderDetailResponse.self,
            from: Data(#"{"orderId":4902,"status":"\#(status)"\#(extra)}"#.utf8)
        )
    }

    private static func stamp(_ date: Date) -> String {
        DateFormatter.aidRunBackendLocalDateTime.string(from: date)
    }
}
