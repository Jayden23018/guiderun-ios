import XCTest
@testable import blindRun

/// 陪跑员端求助警报什么时候收起（OpenSpec `volunteer-alert-clears-when-emergency-ends`）。
/// 后端求助结束时不给陪跑员推事件，警报只能靠轮询 `GET /api/emergency/active` 或订单状态收起。
@MainActor
final class VolunteerAlertLifecycleTests: XCTestCase {
    private let orderID: Int64 = 7

    private func coordinatorWithAlert() -> EmergencyCoordinator {
        let coordinator = EmergencyCoordinator()
        var alert = VolunteerEmergencyAlert(eventID: 41, orderID: orderID, message: "", receivedAt: Date())
        alert.isAcknowledged = true
        coordinator.volunteerAlert = alert
        return coordinator
    }

    private static let noOpenEvent = EmergencyActiveEnvelope(success: true, data: nil)
    private static let openEvent = EmergencyActiveEnvelope(success: true, data: EmergencyEventResponse(
        id: 41, orderId: 7, userId: nil, status: EmergencyEventStatus.pending.rawValue, triggerType: "BUTTON", hasGpsLocation: false
    ))

    // MARK: - 轮询

    func testPollingRemovesTheAlertOnceTheBackendHasNoOpenEvent() async {
        let coordinator = coordinatorWithAlert()
        let safety = FakeSafetyService()
        safety.activeEmergencyResult = .success(Self.openEvent)
        var sleeps = 0
        // 经闭包调用（守卫 `unannotated-async-closure` 要求）：第三次醒来前后端结案。
        await coordinator.keepVolunteerAlertFresh(safety: safety, interval: 20) { interval in
            XCTAssertEqual(interval, 20)
            sleeps += 1
            if sleeps == 3 { safety.activeEmergencyResult = .success(Self.noOpenEvent) }
        }

        XCTAssertNil(coordinator.volunteerAlert, "后端说没有未结束的事件，警报要收起")
        XCTAssertEqual(safety.calls, Array(repeating: "activeEmergency()", count: 3), "求助没结束时每隔一段问一次，结束后停")
    }

    func testNoAlertMeansNoRequest() async {
        let coordinator = EmergencyCoordinator()
        let safety = FakeSafetyService()
        var sleeps = 0

        await coordinator.keepVolunteerAlertFresh(safety: safety) { _ in sleeps += 1 }

        XCTAssertEqual(sleeps, 0)
        XCTAssertTrue(safety.calls.isEmpty, "没有警报时不能发请求")
    }

    func testCancelledWaitStopsPollingWithoutARequest() async {
        let coordinator = coordinatorWithAlert()
        let safety = FakeSafetyService()

        await coordinator.keepVolunteerAlertFresh(safety: safety) { _ in throw CancellationError() }

        XCTAssertTrue(safety.calls.isEmpty)
        XCTAssertNotNil(coordinator.volunteerAlert, "只是停了轮询，警报本身不动")
    }

    /// 网络失败不是「求助结束」：警报留着，下一轮再问。
    func testFailedRequestKeepsTheAlert() async {
        let coordinator = coordinatorWithAlert()
        let safety = FakeSafetyService()
        safety.activeEmergencyResult = .failure(URLError(.notConnectedToInternet))
        var sleeps = 0

        await coordinator.keepVolunteerAlertFresh(safety: safety) { _ in
            sleeps += 1
            if sleeps == 3 { throw CancellationError() }
        }

        XCTAssertNotNil(coordinator.volunteerAlert)
        XCTAssertEqual(safety.calls.count, 2)
    }

    // MARK: - 订单状态

    func testLeavingTheOrderRemovesTheAlertAtOnce() async {
        for status in [RunOrderStatus.cancelled, .noVolunteer, .pendingMatch, .rematching] {
            let coordinator = coordinatorWithAlert()
            let safety = FakeSafetyService()

            await coordinator.handleVolunteerAlertOrderStatus(orderID: orderID, status: status, safety: safety)

            XCTAssertNil(coordinator.volunteerAlert, "\(status.rawValue) 后陪跑员已不在这一单上")
            XCTAssertTrue(safety.calls.isEmpty, "\(status.rawValue) 不用等后端")
        }
    }

    /// 完成后 `sosWindowEndsAt` 之前跑者仍能求助（#1016）：「已完成」只问后端，不在本地收起。
    func testCompletedOrderAsksTheBackendAndKeepsAnOpenAlert() async {
        let coordinator = coordinatorWithAlert()
        let safety = FakeSafetyService()
        safety.activeEmergencyResult = .success(Self.openEvent)

        await coordinator.handleVolunteerAlertOrderStatus(orderID: orderID, status: .completed, safety: safety)

        XCTAssertEqual(safety.calls, ["activeEmergency()"])
        XCTAssertNotNil(coordinator.volunteerAlert, "求助还开着，跑完了也要留着")
    }

    func testCompletedOrderRemovesTheAlertWhenTheBackendSaysItEnded() async {
        let coordinator = coordinatorWithAlert()
        let safety = FakeSafetyService()
        safety.activeEmergencyResult = .success(Self.noOpenEvent)

        await coordinator.handleVolunteerAlertOrderStatus(orderID: orderID, status: .completed, safety: safety)

        XCTAssertNil(coordinator.volunteerAlert)
    }

    func testOtherOrdersAndRunningStatesLeaveTheAlertAlone() async {
        let coordinator = coordinatorWithAlert()
        let safety = FakeSafetyService()

        await coordinator.handleVolunteerAlertOrderStatus(orderID: 99, status: .cancelled, safety: safety)
        await coordinator.handleVolunteerAlertOrderStatus(orderID: orderID, status: .inProgress, safety: safety)

        XCTAssertNotNil(coordinator.volunteerAlert)
        XCTAssertTrue(safety.calls.isEmpty)
    }

    func testClearedSentenceNeverClaimsMoreThanTheClientKnows() {
        let text = EmergencySafetyCopy.volunteerAlertCleared
        XCTAssertTrue(text.contains("已不由你陪跑"), "客户端分不清原因时两种都要说到")
        for forbidden in ["已送达", "已通知", "家属", "联系人"] {
            XCTAssertFalse(text.contains(forbidden), "不许宣称「\(forbidden)」（AGENTS.md §6）")
        }
    }
}
