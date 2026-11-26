import SwiftUI
import XCTest
@testable import blindRun

/// 陪跑员端 App 语音默认关（backend#1064）。盲人端与角色未定时照念；安全提醒和用户自己点的朗读照念。
@MainActor
final class VolunteerVoicePreferenceTests: XCTestCase {

    private let suiteName = "VolunteerVoicePreferenceTests"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        // 接管提示音与震动：`.alert` / `.onDemand` / `.perKilometer` 档会响提示音。
        AnnouncementCue.observerForTesting = { _ in }
    }

    override func tearDown() {
        AnnouncementCue.observerForTesting = nil
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func makeAppState(role: UserRole?) -> AppState {
        let appState = AppState(
            persistence: AppStatePersistenceFactory.makeIsolatedTest(), tokenStore: InMemoryTokenStore()
        )
        appState.activeRole = role
        return appState
    }

    func makeSilencedSpeech() -> SpeechService {
        let speech = SpeechService()
        speech.isCallActive = { false }
        speech.isRoutineSpeechSilenced = { true }
        return speech
    }

    func makeVolunteerAppState(
        safety: FakeSafetyService = FakeSafetyService(), orders: FakeOrderService = FakeOrderService()
    ) -> AppState {
        let appState = AppState(
            safety: safety, orders: orders,
            persistence: AppStatePersistenceFactory.makeIsolatedTest(), tokenStore: InMemoryTokenStore()
        )
        appState.activeRole = .volunteer
        return appState
    }

    func makePage(_ appState: AppState, _ speech: SpeechService) -> VolunteerInServiceViewModel {
        let viewModel = VolunteerInServiceViewModel(voiceBroadcastEnabled: { false })
        viewModel.configure(
            with: appState, speechService: speech, initialOrder: EmergencySOSFixtures.makeOrder(status: .inProgress)
        )
        return viewModel
    }

    func notification(_ eventType: String, body: String, until: Date? = nil) -> WSAppNotification {
        let formatter = DateFormatter.aidRunBackendLocalDateTime
        return WSAppNotification(
            type: WSMessageType.appNotification.rawValue, eventId: nil, messageId: UUID().uuidString,
            eventType: eventType, title: nil, body: body, ttsText: body, priority: "HIGH",
            timestamp: formatter.string(from: Date()), orderId: 7, until: until.map(formatter.string(from:))
        )
    }

    func host(_ view: some View) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        return window
    }

    func settle() async throws {
        try await Task.sleep(nanoseconds: 600_000_000)
    }

    // MARK: - 谁被静音

    func testOnlyAVolunteerWithTheToggleOffIsSilenced() {
        XCTAssertTrue(VolunteerVoicePreference.silencesRoutineSpeech(role: .volunteer, defaults: defaults), "默认就是关")
        XCTAssertFalse(VolunteerVoicePreference.silencesRoutineSpeech(role: .blind, defaults: defaults))
        XCTAssertFalse(VolunteerVoicePreference.silencesRoutineSpeech(role: nil, defaults: defaults), "登录页、选角色页")

        defaults.set(true, forKey: VolunteerVoicePreference.defaultsKey)
        XCTAssertFalse(VolunteerVoicePreference.silencesRoutineSpeech(role: .volunteer, defaults: defaults))
    }

    /// 走根视图用的那条接线：同一个播报器，换角色、拨开关立即生效。
    func testTheWiredServiceFollowsRoleAndToggle() {
        let appState = makeAppState(role: .blind)
        let speech = SpeechService()
        speech.isCallActive = { false }
        speech.followVolunteerVoicePreference(of: appState, defaults: defaults)

        speech.speak("盲人端的一句")
        appState.activeRole = .volunteer
        speech.speak("陪跑员关着时的一句")
        defaults.set(true, forKey: VolunteerVoicePreference.defaultsKey)
        speech.speak("陪跑员打开后的一句")

        XCTAssertEqual(speech.spokenHistoryForTesting, ["盲人端的一句", "陪跑员打开后的一句"])
    }

    // MARK: - 播报器

    func testSilencedRoutineSpeechOnlyPostsTheVoiceOverAnnouncement() {
        let speech = makeSilencedSpeech()

        speech.speak("操作反馈")
        speech.speakError("出错提示")
        speech.speak("按需", priority: .onDemand)
        speech.speak("里程", priority: .perKilometer)

        XCTAssertEqual(speech.spokenHistoryForTesting, [])
        XCTAssertFalse(speech.isSpeaking)
        XCTAssertEqual(speech.lastVoiceOverAnnouncement, "里程", "VoiceOver 通告不受开关影响")
    }

    func testSilencedServiceStillSpeaksAlertsAndEssentialSentences() {
        for (priority, essential) in [(AnnouncementPriority.alert, false), (.emergency, false), (.counterpartAction, true)] {
            let speech = makeSilencedSpeech()
            speech.speak("安全提醒", priority: priority, essential: essential)
            XCTAssertEqual(speech.spokenHistoryForTesting, ["安全提醒"], "priority=\(priority) essential=\(essential)")
        }
        let speech = makeSilencedSpeech()
        speech.speakError("求助未发出", essential: true)
        XCTAssertEqual(speech.spokenHistoryForTesting, ["求助未发出"])
    }

    /// 静音的那句不能把正在念的安全提醒切断（同档来者本来会打断）。
    func testSilencedSentenceDoesNotInterruptAnEssentialOne() {
        let speech = makeSilencedSpeech()
        speech.speak("跑者在找你", essential: true)

        speech.speak("订单状态有更新")

        XCTAssertEqual(speech.spokenHistoryForTesting, ["跑者在找你"])
        XCTAssertTrue(speech.isSpeaking)
    }

    /// 警示正在念时，静音句子的 VoiceOver 通告照发：丢掉的话读屏用户永远听不到这一句。
    func testSilencedSentenceStillPostsItsAnnouncementWhileAnAlertIsPlaying() {
        let speech = makeSilencedSpeech()
        speech.speak("你和跑者走散了", priority: .alert)

        speech.speak("订单状态有更新")
        speech.speak("按需的一句", priority: .onDemand)

        XCTAssertEqual(speech.lastVoiceOverAnnouncement, "按需的一句")
        XCTAssertEqual(speech.spokenHistoryForTesting, ["你和跑者走散了"])
    }

    func testSilencedSentenceIsNotAnnouncedDuringACall() {
        let speech = makeSilencedSpeech()
        speech.isCallActive = { true }

        speech.speak("订单状态有更新")

        XCTAssertNil(speech.lastVoiceOverAnnouncement, "通话中只保留警示")
    }

    // MARK: - 哪些通知照念

    func testSafetyAndRingEventTypesKeepSpeech() {
        for type in [
            "EMERGENCY_TRIGGERED", "EMERGENCY_VOLUNTEER_ACK", "EMERGENCY_UNATTENDED",
            "ESCORT_DISTANCE_ALERT", "ESCORT_SIGNAL_LOST",
            "VOLUNTEER_RING", "VOLUNTEER_RING_LOST", "ORDER_VOLUNTEER_LOST",
            "ORDER_OVERDUE", "RUN_RHYTHM", "RUNNER_BATTERY_LOW", ""
        ] {
            XCTAssertTrue(AppRealtimeCoordinator.keepsVolunteerSpeech(forEventType: type), type)
        }
        for type in ["NEW_ORDER", "ORDER_ACCEPTED", "ORDER_CANCELLED_BY_BLIND", "DEPART_REMINDER", "CERT_APPROVED"] {
            XCTAssertFalse(AppRealtimeCoordinator.keepsVolunteerSpeech(forEventType: type), type)
        }
    }

    func testRealtimeNotificationsCarryTheKeptSpeechMark() {
        for (eventType, kept) in [("ORDER_OVERDUE", true), ("CERT_APPROVED", false)] {
            let coordinator = AppRealtimeCoordinator(notificationDuration: 60)
            coordinator.simulateIncomingEventForTesting(.notification(notification(eventType, body: "一句通知")))
            XCTAssertEqual(coordinator.currentNotification?.keepsVolunteerSpeech, kept, eventType)
        }
    }

    /// 重连补读走另一条构造路径。
    func testCatchUpNotificationsCarryTheKeptSpeechMark() {
        let cases: [(String?, Bool)] = [("EMERGENCY_VOLUNTEER_ACK", true), (nil, true), ("CERT_APPROVED", false)]
        for (eventType, kept) in cases {
            let coordinator = AppRealtimeCoordinator(notificationDuration: 60)
            coordinator.ingestCatchUp([
                MissedNotificationResponse(
                    id: 9101, eventType: eventType, body: "一句通知", ttsText: nil,
                    priority: "HIGH", sentAt: "2026-11-26T12:00:00Z", orderId: 7
                )
            ])
            XCTAssertEqual(coordinator.currentNotification?.keepsVolunteerSpeech, kept, eventType ?? "nil")
        }
    }
}
