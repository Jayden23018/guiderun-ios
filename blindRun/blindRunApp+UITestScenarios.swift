import Foundation

// UI 用例演实时事件的开关。单独成文件：`blindRunApp.swift` 已超 SwiftLint 长度上限，棘轮不许它再变长。
extension blindRunApp {
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
            appState.realtimeCoordinator.simulateIncomingEventForTesting(
                .emergencyAlert(WSEmergencyVolunteerAlert(
                    type: WSMessageType.emergencyVolunteerAlert.rawValue,
                    eventId: 9001,
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
        }
        #endif
    }
}
