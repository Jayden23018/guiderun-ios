import SwiftUI

// MARK: - 跑者在找你（`VOLUNTEER_RING` / `VOLUNTEER_RING_LOST`，后端 #1046，iOS #1023）

/// `RUNNER_RING` 的反方向：跑者在汇合时或陪跑中走散时按「让陪跑员的手机响」，陪跑员的手机出声并震动。
///
/// 播放、起止、遮罩全部复用跑者端那一套（`RunnerRingController` / `RunnerRingTone` / `RunnerRingOverlay`），
/// 只有文案按 `RunnerRingRequest.Kind` 换成陪跑员的话，停止按钮写「知道了」。挂在根容器上：
/// 陪跑员在哪个 tab、哪一层页面都得响。汇合期和陪跑中各一句话，不能混用：跑步中说「在出发点找你」是错的。
private struct VolunteerFindMeRingModifier: ViewModifier {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var speechService: SpeechService
    @StateObject private var ringController = RunnerRingController()

    func body(content: Content) -> some View {
        content
            // 遮罩盖住整屏时，背后的 TabView 对读屏藏起来（同跑者端，SwiftUI hidden 跨不过 UIKit 容器，要两层一起挂）。
            .accessibilityHidden(ringController.active != nil)
            .background(HostedContainersAccessibilityHider(isHidden: ringController.active != nil))
            .overlay {
                if let ring = ringController.active {
                    RunnerRingOverlay(kind: ring.kind, onStop: { ringController.stop() })
                }
            }
            .onAppear { configure() }
            // 协调器是 AppState 上的嵌套对象，改它不会让这一层重绘，只能订阅。
            // 重新订阅会回放当前值，控制器自己去重。协调器只把陪跑员那两种发出来，这里再认一次，防它改了判据。
            .onReceive(appState.realtimeCoordinator.$runnerRing) { ring in
                guard ring?.kind.isForVolunteer == true else { return }
                ringController.handle(ring)
            }
    }

    private func configure() {
        let speech = speechService
        let coordinator = appState.realtimeCoordinator
        ringController.speak = { speech.speak($0) }
        ringController.isSpeaking = { speech.isSpeaking }
        ringController.onFinish = { coordinator.dismissRunnerRing() }
        #if DEBUG
        simulateRingForUITestIfNeeded()
        #endif
    }

    #if DEBUG
    private static var didSimulate = false

    /// UI 测试与真机人耳验证用：启动后注入一条 10 秒的响铃，不用另找一台跑者手机。
    /// `1` = 汇合期 `VOLUNTEER_RING`，`lost` = 陪跑中走散 `VOLUNTEER_RING_LOST`。
    private func simulateRingForUITestIfNeeded() {
        let flag = ProcessInfo.processInfo.environment["AIDRUN_UI_TEST_VOLUNTEER_RING"]
        guard flag == "1" || flag == "lost", !Self.didSimulate else { return }
        Self.didSimulate = true
        let kind: RunnerRingRequest.Kind = flag == "lost" ? .runnerLost : .runnerSeeking
        let formatter = DateFormatter.aidRunBackendLocalDateTime
        let sentAt = Date()
        appState.realtimeCoordinator.simulateIncomingEventForTesting(.notification(WSAppNotification(
            type: WSMessageType.appNotification.rawValue,
            eventId: nil,
            messageId: UUID().uuidString,
            eventType: kind == .runnerLost ? "VOLUNTEER_RING_LOST" : "VOLUNTEER_RING",
            title: nil,
            body: RunnerRingCopy.fallbackSpeech(kind),
            ttsText: RunnerRingCopy.fallbackSpeech(kind),
            priority: "HIGH",
            timestamp: formatter.string(from: sentAt),
            orderId: 1,
            until: formatter.string(from: sentAt.addingTimeInterval(10))
        )))
    }
    #endif
}

extension View {
    /// 陪跑员端根容器上挂一次：收到跑者的响铃时出声、震动、念一句，任意操作即停。
    func volunteerFindMeRing() -> some View {
        modifier(VolunteerFindMeRingModifier())
    }
}
