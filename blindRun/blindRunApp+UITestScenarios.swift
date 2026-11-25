import Foundation

// UI 用例演实时事件的开关。单独成文件：`blindRunApp.swift` 已超 SwiftLint 长度上限，棘轮不许它再变长。
// 编译条件与 `blindRunApp.swift` 里被调用的 `injectUITestVolunteerLostIfNeeded`、调用处一致：Release 里两者都不存在（#1029 漏了这层，Release 编不过）。
#if DEBUG || DEMO
extension blindRunApp {
    /// 测试开关推的那条求助的事件号。随便取的，只要和 Mock 里别的事件号不撞。
    private static let uiTestVolunteerEmergencyEventID: Int64 = 9001

    func injectUITestScenariosIfNeeded() {
        injectUITestVolunteerLostIfNeeded()
        injectUITestVolunteerEmergencyIfNeeded()
    }

    /// `AIDRUN_UI_TEST_VOLUNTEER_EMERGENCY_AFTER_SECONDS`（#1024）：启动 N 秒后给陪跑员推一条 `EMERGENCY_VOLUNTEER_ALERT`，
    /// 挂在 Mock 第一张单上。走查「陪跑员不在订单页时收到求助」用：全局警报是独立 `UIWindow`，只有真机上看得到层级。
    private func injectUITestVolunteerEmergencyIfNeeded() {
        #if DEBUG
        guard let raw = ProcessInfo.processInfo.environment["AIDRUN_UI_TEST_VOLUNTEER_EMERGENCY_AFTER_SECONDS"],
              let seconds = Double(raw) else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            guard let mock = appState.sessionUnawareAPIClient as? MockAPIClient,
                  let orderId = mock.orders.first?.orderId else { return }
            // Mock 里同时记一条未结束的事件：回前台的恢复（`refreshVolunteerAlert`）读不到它会把警报收掉。
            mock.activeEmergencyEvent = EmergencyEventResponse(
                id: Self.uiTestVolunteerEmergencyEventID, orderId: orderId, userId: nil,
                status: EmergencyEventStatus.pending.rawValue, triggerType: "BUTTON", hasGpsLocation: false
            )
            appState.realtimeCoordinator.simulateIncomingEventForTesting(
                .emergencyAlert(WSEmergencyVolunteerAlert(
                    type: WSMessageType.emergencyVolunteerAlert.rawValue,
                    eventId: Self.uiTestVolunteerEmergencyEventID,
                    orderId: orderId,
                    userId: nil,
                    message: "跑者发起了求助",
                    ttsText: "跑者发起了求助，请立即查看。",
                    priority: "HIGH",
                    gpsLat: nil,
                    gpsLng: nil,
                    timestamp: nil
                ))
            )
            // `AIDRUN_UI_TEST_VOLUNTEER_EMERGENCY_ENDS_AFTER_SECONDS`：再过 N 秒在 Mock 里结案（同后端：不推任何事件），
            // 看警报能不能靠轮询自己收起。
            guard let endRaw = ProcessInfo.processInfo.environment["AIDRUN_UI_TEST_VOLUNTEER_EMERGENCY_ENDS_AFTER_SECONDS"],
                  let endSeconds = Double(endRaw) else { return }
            try? await Task.sleep(nanoseconds: UInt64(max(0, endSeconds) * 1_000_000_000))
            mock.activeEmergencyEvent = nil
        }
        #endif
    }
}
#endif
