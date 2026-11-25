import XCTest
@testable import blindRun

/// #1012：陪跑员端接住跑者的操作 —— 留言原文、已到达退出入口、已到达的快捷消息、求助警报对象。
final class VolunteerReceiveRunnerActionsTests: XCTestCase {
    private func order(_ status: RunOrderStatus, message: String?) -> OrderDetailResponse {
        var order = OrderDetailResponse.preview(status: status, blindName: "李*")
        order.messageToVolunteer = message
        return order
    }

    // MARK: 1 跑者留言

    func testMessageRowShowsVerbatimInEveryPreRunStage() {
        for status in [RunOrderStatus.scheduledConfirmed, .pendingAccept, .driverEnRoute, .driverArrived] {
            let presentation = VolunteerOrderFlowPresentation.make(
                order: order(status, message: "明天见，谢谢你陪我跑！"), distanceText: nil, peerDistanceText: "40 米"
            )
            let row = presentation?.rows.first { $0.id == VolunteerRunnerMessage.rowID }
            XCTAssertEqual(row?.value, "明天见，谢谢你陪我跑！", "\(status.rawValue) 看不到留言原文")
            XCTAssertEqual(row?.accessibilityLabel, "跑者留言，明天见，谢谢你陪我跑！")
        }
    }

    func testClearedMessageShowsNoRow() {
        for message in [nil, "", "   "] {
            for status in [RunOrderStatus.scheduledConfirmed, .driverEnRoute, .driverArrived] {
                let presentation = VolunteerOrderFlowPresentation.make(
                    order: order(status, message: message), distanceText: nil, peerDistanceText: "40 米"
                )
                XCTAssertNil(presentation?.rows.first { $0.id == VolunteerRunnerMessage.rowID })
            }
        }
    }

    func testChangedMessageIsAnnouncedOnceWithItsText() {
        let before = order(.scheduledConfirmed, message: "我穿蓝衣服")
        let after = order(.scheduledConfirmed, message: "我穿红衣服")
        XCTAssertEqual(VolunteerRunnerMessage.announcement(previous: before, current: after), "跑者留言：我穿红衣服")
        // 同一份订单再来一次（轮询）不重复念。
        XCTAssertNil(VolunteerRunnerMessage.announcement(previous: after, current: after))
    }

    func testAnnouncementStaysSilentOnFirstLoadClearingAndRunning() {
        let withMessage = order(.scheduledConfirmed, message: "我穿红衣服")
        XCTAssertNil(VolunteerRunnerMessage.announcement(previous: nil, current: withMessage))
        XCTAssertNil(VolunteerRunnerMessage.announcement(previous: withMessage, current: order(.scheduledConfirmed, message: nil)))
        XCTAssertNil(VolunteerRunnerMessage.announcement(previous: order(.inProgress, message: "a"), current: order(.inProgress, message: "b")))
    }

    // MARK: 3 已到达退出入口

    func testArrivedPageOffersReleaseButRunningStillDoesNot() {
        let arrived = VolunteerOrderFlowPresentation.make(
            order: order(.driverArrived, message: nil), distanceText: nil, peerDistanceText: "40 米"
        )
        XCTAssertTrue(arrived?.rows.contains { $0.action == .releaseOrder } == true)
        // 跑步中不放取消入口（#962，负责人 2026-11-12）。
        XCTAssertNil(VolunteerOrderFlowPresentation.make(order: order(.inProgress, message: nil), distanceText: nil))
    }

    func testArrivedCancelSheetSaysRunnerWillBeTold() {
        let copy = VolunteerOrderFlowCopy.cancelSheet(
            for: .driverArrived, plannedStart: nil, lateCancelWindowHours: 12
        )
        XCTAssertEqual(copy.message, "此订单将转给其他陪跑员，跑者会被告知。")
        XCTAssertEqual(copy.title, "取消这次陪跑？")
        // 其他阶段口径不变。
        XCTAssertEqual(
            VolunteerOrderFlowCopy.cancelSheet(for: .driverEnRoute, plannedStart: nil, lateCancelWindowHours: 12).message,
            "此订单将转给其他陪跑员，之后不一定还能接回来。"
        )
    }

    // MARK: 4 快捷消息

    func testQuickMessagesAreOfferedWhenDepartedAndArrivedOnly() {
        XCTAssertEqual(VolunteerOrderPhase.departed(late: false).quickMessageCodes, [.almostThere, .waitFiveMinutes])
        XCTAssertEqual(VolunteerOrderPhase.arrived(canEndWait: false).quickMessageCodes, [.waitFiveMinutes])
        XCTAssertEqual(VolunteerOrderPhase.arrived(canEndWait: true).quickMessageCodes, [.waitFiveMinutes])
        XCTAssertTrue(VolunteerOrderPhase.completed.quickMessageCodes.isEmpty)
    }

    // MARK: 2 求助警报对象

    func testAlertPeerComesFromTheAlertOrder() {
        var detail = OrderDetailResponse.preview(status: .inProgress, blindName: "李*", blindPhone: "13800001111")
        detail.messageToVolunteer = nil
        XCTAssertEqual(VolunteerEmergencyAlertPeer.make(from: detail), VolunteerEmergencyAlertPeer(name: "李*", phone: "13800001111"))
        XCTAssertNil(VolunteerEmergencyAlertPeer.make(from: nil))
    }

    // MARK: 2 警报形态

    func testAlertWindowModeFollowsAcknowledgementAndReview() {
        let fresh = VolunteerEmergencyAlert(eventID: 1, orderID: 7, message: "", receivedAt: Date())
        var acked = fresh
        acked.isAcknowledged = true
        XCTAssertEqual(VolunteerEmergencyWindowMode.resolve(alert: nil, isReviewing: false), .none)
        // 未确认：整屏，且点不掉（回看标志无关）。
        XCTAssertEqual(VolunteerEmergencyWindowMode.resolve(alert: fresh, isReviewing: false), .full)
        // 已确认：常驻条；点它回看时又是整屏；求助结束（nil）条消失。
        XCTAssertEqual(VolunteerEmergencyWindowMode.resolve(alert: acked, isReviewing: false), .bar)
        XCTAssertEqual(VolunteerEmergencyWindowMode.resolve(alert: acked, isReviewing: true), .full)
        XCTAssertEqual(VolunteerEmergencyWindowMode.resolve(alert: nil, isReviewing: true), .none)
    }
}
